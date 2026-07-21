import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../fly_name.dart';
import '../log.dart';
import 'adapter.dart';
import 'auth_helpers.dart';

/// Azure Container Apps — Docker → ACR → env + container app.
///
/// Stateless Serverpod API for v1 (mirrors Cloud Run / App Runner api_only).
/// Requires `az` CLI + Docker. Creates resource group, ACR (admin), Container
/// Apps environment, and the app when missing.
class AzureHost extends HostAdapter {
  @override
  String get id => 'azure';

  @override
  String get label => 'Azure Container Apps';

  @override
  List<String> get cliBinaries => const ['az'];

  @override
  String get installHint =>
      'https://learn.microsoft.com/cli/azure/install-azure-cli';

  @override
  List<String> get idAliases => const ['aca', 'containerapps', 'container_apps'];

  @override
  List<CliInstallRecipe> get installRecipes => const [
        CliInstallRecipe(
          label: 'brew install azure-cli',
          executable: 'brew',
          args: ['install', 'azure-cli'],
        ),
      ];

  @override
  bool get canDeploy => true;

  @override
  AppHost get appHost => AppHost.azure;

  @override
  String get configKey => 'azure';

  @override
  List<DatabaseProvider> get supportedDatabases => const [
        DatabaseProvider.none,
        DatabaseProvider.neon,
      ];

  @override
  String defaultApiUrl({
    required String name,
    required String sanitizedName,
  }) =>
      'https://$sanitizedName.REGION.azurecontainerapps.io/';

  @override
  String? publicApiBase(PodflyConfig config) {
    final c = config.azure;
    if (c == null) return null;
    final h = c.publicHost;
    if (h != null && h.isNotEmpty) {
      return h.startsWith('http')
          ? (h.endsWith('/') ? h : '$h/')
          : 'https://$h/';
    }
    return null;
  }

  @override
  String secretSetHint(String secretName, PodflyConfig config) {
    final app = config.azure?.app ?? '<app>';
    final rg = config.azure?.resourceGroup ?? '<resource-group>';
    return 'az containerapp update -n $app -g $rg '
        '--set-env-vars $secretName=<value>';
  }

  @override
  Future<bool> checkAuth(DoctorContext ctx) async {
    final bin = ctx.cliPath;
    if (ctx.dryRun) {
      ctx.log.ok('$bin  (auth check skipped in dry-run)');
      return true;
    }
    final r = await ctx.runner.runCapture(
      bin,
      ['account', 'show', '--output', 'json'],
      allowDryRun: false,
    );
    if (r.ok && r.stdout.contains('id')) {
      final name = _jsonString(r.stdout, 'name') ?? '?';
      final state = _jsonString(r.stdout, 'state') ?? '';
      ctx.log.ok('$bin  subscription $name'
          '${state.isNotEmpty ? " ($state)" : ""}');
      return true;
    }
    return authViaWhoami(
      ctx: ctx,
      whoamiArgs: const ['account', 'show'],
      loginCommand: 'az login',
      loginArgs: const ['login'],
      failSubstrings: const [
        'please run',
        'az login',
        'not logged',
        'no subscription',
        'authentication failed',
      ],
    );
  }

  @override
  void configWarnings(PodflyConfig config, Log log) {
    log.detail(
      'Azure Container Apps: Docker → ACR → env/app. Scale-to-zero when '
      'min_replicas=0. Delete resource group when done. See doc/azure.md.',
    );
  }

  @override
  Future<HostDeployResult> deployApi(DeployContext ctx) async {
    final config = ctx.config;
    final runner = ctx.runner;
    final log = ctx.log;

    final acfg = config.azure ??
        AzureConfig(app: sanitizeFlyAppName(config.name));
    final app = _sanitizeContainerAppName(acfg.app);
    final rg = acfg.resourceGroup ?? '$app-rg';
    final location = acfg.location;
    final envName = acfg.environment ?? '$app-env';
    final registry = _sanitizeAcrName(acfg.registry ?? app);
    final repo = acfg.repository ?? app;
    final tag = acfg.imageTag == 'latest'
        ? DateTime.now().toUtc().millisecondsSinceEpoch.toString()
        : acfg.imageTag;

    log.step('Deploy Azure Container Apps ($app)');

    final az = await runner.resolve('az');
    if (az == null) throw StateError('az not found — $installHint');

    final docker = await runner.resolve('docker');
    if (docker == null) {
      throw StateError(
        'docker not found — Azure deploy builds images locally then pushes to ACR',
      );
    }

    await _ensureResourceGroup(ctx, az, name: rg, location: location);
    await _ensureAcr(
      ctx,
      az,
      name: registry,
      resourceGroup: rg,
      location: location,
    );
    await _acrLogin(ctx, az, docker, registry: registry);

    final imageUri = '$registry.azurecr.io/$repo:$tag';
    await _dockerBuildAndPush(
      ctx,
      docker: docker,
      imageUri: imageUri,
      platform: acfg.platform,
    );

    await _ensureEnvironment(
      ctx,
      az,
      name: envName,
      resourceGroup: rg,
      location: location,
    );

    final env = <String, String>{
      'runmode': 'production',
      'SERVERPOD_RUN_MODE': 'production',
      ...acfg.extraEnv,
    };

    final exists = await _appExists(ctx, az, name: app, resourceGroup: rg);
    if (!exists) {
      await _createApp(
        ctx,
        az,
        name: app,
        resourceGroup: rg,
        environment: envName,
        imageUri: imageUri,
        registry: registry,
        acfg: acfg,
        env: env,
      );
    } else {
      await _updateApp(
        ctx,
        az,
        name: app,
        resourceGroup: rg,
        imageUri: imageUri,
        acfg: acfg,
        env: env,
      );
    }

    final fqdn = await _appFqdn(ctx, az, name: app, resourceGroup: rg);
    final host = fqdn
        .replaceFirst(RegExp(r'^https?://'), '')
        .split('/')
        .first;

    await ctx.patchPublicHosts(host);
    if (!runner.dryRun) {
      await _persist(
        ctx,
        acfg,
        app: app,
        resourceGroup: rg,
        environment: envName,
        registry: registry,
        repository: repo,
        publicHost: host,
      );
    }

    final url = 'https://$host';
    log.ok('Azure Container Apps: $url');
    return HostDeployResult(publicHost: host, displayUrl: url);
  }

  Future<void> _ensureResourceGroup(
    DeployContext ctx,
    String az, {
    required String name,
    required String location,
  }) async {
    final log = ctx.log;
    if (ctx.runner.dryRun) {
      log.dry('az group create -n $name -l $location');
      return;
    }
    final show = await ctx.runner.runCapture(
      az,
      ['group', 'show', '--name', name, '--output', 'json'],
      allowDryRun: false,
    );
    if (show.ok) {
      log.detail('resource group: $name');
      return;
    }
    log.detail('creating resource group $name ($location)');
    final create = await ctx.runner.run(
      az,
      [
        'group',
        'create',
        '--name',
        name,
        '--location',
        location,
        '--output',
        'none',
      ],
      allowDryRun: false,
    );
    if (!create.ok) {
      throw StateError(
        'az group create failed (exit ${create.exitCode})',
      );
    }
  }

  Future<void> _ensureAcr(
    DeployContext ctx,
    String az, {
    required String name,
    required String resourceGroup,
    required String location,
  }) async {
    final log = ctx.log;
    if (ctx.runner.dryRun) {
      log.dry('az acr create -n $name -g $resourceGroup --sku Basic');
      return;
    }
    final show = await ctx.runner.runCapture(
      az,
      [
        'acr',
        'show',
        '--name',
        name,
        '--resource-group',
        resourceGroup,
        '--output',
        'json',
      ],
      allowDryRun: false,
    );
    if (show.ok) {
      log.detail('ACR: $name');
      // Ensure admin is on for registry username/password pull.
      await ctx.runner.run(
        az,
        [
          'acr',
          'update',
          '--name',
          name,
          '--resource-group',
          resourceGroup,
          '--admin-enabled',
          'true',
          '--output',
          'none',
        ],
        allowDryRun: false,
      );
      return;
    }
    log.detail('creating ACR $name (Basic, admin-enabled)');
    final create = await ctx.runner.run(
      az,
      [
        'acr',
        'create',
        '--name',
        name,
        '--resource-group',
        resourceGroup,
        '--location',
        location,
        '--sku',
        'Basic',
        '--admin-enabled',
        'true',
        '--output',
        'none',
      ],
      allowDryRun: false,
    );
    if (!create.ok) {
      throw StateError(
        'az acr create failed (exit ${create.exitCode}). '
        'ACR names must be globally unique alphanumeric (5–50 chars).',
      );
    }
  }

  Future<void> _acrLogin(
    DeployContext ctx,
    String az,
    String docker, {
    required String registry,
  }) async {
    final log = ctx.log;
    if (ctx.runner.dryRun) {
      log.dry('az acr login -n $registry');
      return;
    }
    final login = await ctx.runner.run(
      az,
      ['acr', 'login', '--name', registry],
      allowDryRun: false,
    );
    if (!login.ok) {
      throw StateError(
        'az acr login failed (exit ${login.exitCode}) — is Docker running?',
      );
    }
    log.detail('docker logged in to $registry.azurecr.io');
  }

  Future<void> _dockerBuildAndPush(
    DeployContext ctx, {
    required String docker,
    required String imageUri,
    required String platform,
  }) async {
    final config = ctx.config;
    final runner = ctx.runner;
    final log = ctx.log;
    final rootDocker = File(p.join(config.root, 'Dockerfile'));
    final serverDocker = File(p.join(config.root, config.server, 'Dockerfile'));
    final df = await rootDocker.exists()
        ? 'Dockerfile'
        : (await serverDocker.exists()
            ? p.join(config.server, 'Dockerfile')
            : 'Dockerfile');

    if (runner.dryRun) {
      log.dry('docker build --platform $platform -t $imageUri -f $df .');
      log.dry('docker push $imageUri');
      return;
    }

    log.detail('docker build $imageUri ($platform)');
    final build = await runner.run(
      docker,
      [
        'build',
        '--platform',
        platform,
        '-t',
        imageUri,
        '-f',
        df,
        '.',
      ],
      workingDirectory: config.root,
      allowDryRun: false,
    );
    if (!build.ok) {
      throw StateError('docker build failed (exit ${build.exitCode})');
    }
    log.detail('docker push $imageUri');
    final push = await runner.run(
      docker,
      ['push', imageUri],
      workingDirectory: config.root,
      allowDryRun: false,
    );
    if (!push.ok) {
      throw StateError('docker push failed (exit ${push.exitCode})');
    }
  }

  Future<void> _ensureEnvironment(
    DeployContext ctx,
    String az, {
    required String name,
    required String resourceGroup,
    required String location,
  }) async {
    final log = ctx.log;
    if (ctx.runner.dryRun) {
      log.dry('az containerapp env create -n $name -g $resourceGroup');
      return;
    }
    final show = await ctx.runner.runCapture(
      az,
      [
        'containerapp',
        'env',
        'show',
        '--name',
        name,
        '--resource-group',
        resourceGroup,
        '--output',
        'json',
      ],
      allowDryRun: false,
    );
    if (show.ok) {
      log.detail('Container Apps environment: $name');
      return;
    }
    log.detail('creating Container Apps environment $name');
    final create = await ctx.runner.run(
      az,
      [
        'containerapp',
        'env',
        'create',
        '--name',
        name,
        '--resource-group',
        resourceGroup,
        '--location',
        location,
        '--output',
        'none',
      ],
      allowDryRun: false,
    );
    if (!create.ok) {
      throw StateError(
        'az containerapp env create failed (exit ${create.exitCode})',
      );
    }
  }

  Future<bool> _appExists(
    DeployContext ctx,
    String az, {
    required String name,
    required String resourceGroup,
  }) async {
    if (ctx.runner.dryRun) return false;
    final r = await ctx.runner.runCapture(
      az,
      [
        'containerapp',
        'show',
        '--name',
        name,
        '--resource-group',
        resourceGroup,
        '--output',
        'json',
      ],
      allowDryRun: false,
    );
    return r.ok;
  }

  Future<({String username, String password})> _acrCredentials(
    DeployContext ctx,
    String az, {
    required String registry,
    required String resourceGroup,
  }) async {
    if (ctx.runner.dryRun) {
      return (username: registry, password: 'dry-run');
    }
    final r = await ctx.runner.runCapture(
      az,
      [
        'acr',
        'credential',
        'show',
        '--name',
        registry,
        '--resource-group',
        resourceGroup,
        '--output',
        'json',
      ],
      allowDryRun: false,
    );
    if (!r.ok) {
      throw StateError('az acr credential show failed');
    }
    try {
      final m = jsonDecode(r.stdout) as Map<String, dynamic>;
      final username = m['username']?.toString() ?? registry;
      final passwords = m['passwords'];
      String? password;
      if (passwords is List && passwords.isNotEmpty) {
        final first = passwords.first;
        if (first is Map) password = first['value']?.toString();
      }
      if (password == null || password.isEmpty) {
        throw StateError('ACR admin password empty — enable admin on the registry');
      }
      return (username: username, password: password);
    } catch (e) {
      throw StateError('could not parse ACR credentials: $e');
    }
  }

  Future<void> _createApp(
    DeployContext ctx,
    String az, {
    required String name,
    required String resourceGroup,
    required String environment,
    required String imageUri,
    required String registry,
    required AzureConfig acfg,
    required Map<String, String> env,
  }) async {
    final log = ctx.log;
    if (ctx.runner.dryRun) {
      log.dry('az containerapp create -n $name -g $resourceGroup');
      return;
    }
    final creds = await _acrCredentials(
      ctx,
      az,
      registry: registry,
      resourceGroup: resourceGroup,
    );
    log.detail('creating container app $name');
    // Registry password must not appear in process-runner logs.
    final args = <String>[
      'containerapp',
      'create',
      '--name',
      name,
      '--resource-group',
      resourceGroup,
      '--environment',
      environment,
      '--image',
      imageUri,
      '--registry-server',
      '$registry.azurecr.io',
      '--registry-username',
      creds.username,
      '--registry-password',
      creds.password,
      '--target-port',
      '${acfg.port}',
      '--ingress',
      'external',
      '--transport',
      'auto',
      '--cpu',
      acfg.cpu,
      '--memory',
      acfg.memory,
      '--min-replicas',
      '${acfg.minReplicas}',
      '--max-replicas',
      '${acfg.maxReplicas}',
      '--output',
      'none',
    ];
    if (env.isNotEmpty) {
      args.add('--env-vars');
      for (final e in env.entries) {
        args.add('${e.key}=${e.value}');
      }
    }
    final redacted = args
        .map((a) => a == creds.password ? '***' : a)
        .join(' ');
    log.detail('→ $az $redacted');
    final proc = await Process.run(az, args);
    if (proc.exitCode != 0) {
      final err = '${proc.stderr}\n${proc.stdout}'.trim();
      throw StateError(
        'az containerapp create failed (exit ${proc.exitCode}): $err',
      );
    }
  }

  Future<void> _updateApp(
    DeployContext ctx,
    String az, {
    required String name,
    required String resourceGroup,
    required String imageUri,
    required AzureConfig acfg,
    required Map<String, String> env,
  }) async {
    final log = ctx.log;
    if (ctx.runner.dryRun) {
      log.dry('az containerapp update -n $name --image $imageUri');
      return;
    }
    log.detail('updating container app $name');
    final args = <String>[
      'containerapp',
      'update',
      '--name',
      name,
      '--resource-group',
      resourceGroup,
      '--image',
      imageUri,
      '--cpu',
      acfg.cpu,
      '--memory',
      acfg.memory,
      '--min-replicas',
      '${acfg.minReplicas}',
      '--max-replicas',
      '${acfg.maxReplicas}',
      '--output',
      'none',
    ];
    if (env.isNotEmpty) {
      args.add('--set-env-vars');
      for (final e in env.entries) {
        args.add('${e.key}=${e.value}');
      }
    }
    final r = await ctx.runner.run(az, args, allowDryRun: false);
    if (!r.ok) {
      throw StateError(
        'az containerapp update failed (exit ${r.exitCode})',
      );
    }
  }

  Future<String> _appFqdn(
    DeployContext ctx,
    String az, {
    required String name,
    required String resourceGroup,
  }) async {
    if (ctx.runner.dryRun) {
      return '$name.dryrun.azurecontainerapps.io';
    }
    // Brief settle after create/update before FQDN is reliable.
    for (var i = 0; i < 30; i++) {
      final r = await ctx.runner.runCapture(
        az,
        [
          'containerapp',
          'show',
          '--name',
          name,
          '--resource-group',
          resourceGroup,
          '--query',
          'properties.configuration.ingress.fqdn',
          '--output',
          'tsv',
        ],
        allowDryRun: false,
      );
      final fqdn = r.stdout.trim();
      if (r.ok && fqdn.isNotEmpty && fqdn != 'None' && fqdn != 'null') {
        return fqdn;
      }
      await Future<void>.delayed(const Duration(seconds: 5));
    }
    throw StateError(
      'could not resolve Container Apps FQDN for $name',
    );
  }

  Future<void> _persist(
    DeployContext ctx,
    AzureConfig base, {
    required String app,
    required String resourceGroup,
    required String environment,
    required String registry,
    required String repository,
    required String publicHost,
  }) async {
    final cfg = ctx.config;
    final updated = PodflyConfig(
      root: cfg.root,
      host: cfg.host,
      mode: cfg.mode,
      name: cfg.name,
      server: cfg.server,
      flutter: cfg.flutter,
      fly: cfg.fly,
      railway: cfg.railway,
      digitalOcean: cfg.digitalOcean,
      render: cfg.render,
      cloudRun: cfg.cloudRun,
      aws: cfg.aws,
      awsEcs: cfg.awsEcs,
      azure: AzureConfig(
        app: app,
        resourceGroup: resourceGroup,
        location: base.location,
        environment: environment,
        registry: registry,
        repository: repository,
        cpu: base.cpu,
        memory: base.memory,
        port: base.port,
        minReplicas: base.minReplicas,
        maxReplicas: base.maxReplicas,
        imageTag: base.imageTag,
        platform: base.platform,
        extraEnv: base.extraEnv,
        publicHost: publicHost,
      ),
      cloudflare: cfg.cloudflare,
      database: cfg.database,
      web: WebConfig(
        enabled: cfg.web.enabled,
        serverUrlDefine: cfg.web.serverUrlDefine,
        apiUrl: 'https://$publicHost/',
        patchBootstrap: cfg.web.patchBootstrap,
        writeHeaders: cfg.web.writeHeaders,
        baseHref: cfg.web.baseHref,
        staticDir: cfg.web.staticDir,
      ),
      smoke: cfg.smoke,
    );
    await updated.save();
    ctx.log.detail('saved azure.app + public_host');
  }

  /// Container Apps name: lowercase alnum/hyphen, start letter, end alnum,
  /// no `--`, length &lt; 32.
  static String _sanitizeContainerAppName(String raw) {
    var n = sanitizeFlyAppName(raw);
    n = n.replaceAll(RegExp(r'-{2,}'), '-');
    if (n.isEmpty || !RegExp(r'^[a-z]').hasMatch(n)) {
      n = 'a$n';
    }
    if (n.endsWith('-')) n = n.substring(0, n.length - 1);
    if (n.isEmpty) n = 'app';
    if (n.length >= 32) n = n.substring(0, 31);
    if (n.endsWith('-')) n = n.substring(0, n.length - 1);
    return n;
  }

  /// ACR name: 5–50 alphanumeric, globally unique.
  static String _sanitizeAcrName(String raw) {
    var n = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (n.length < 5) {
      n = 'podfly$n';
    }
    if (n.length > 50) n = n.substring(0, 50);
    // Still short? pad with digits (deterministic-ish for dry-run stability)
    if (n.length < 5) {
      n = '${n}acr${Random().nextInt(999)}';
    }
    return n;
  }

  static String? _jsonString(String raw, String key) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return m[key]?.toString();
    } catch (_) {
      return null;
    }
  }
}
