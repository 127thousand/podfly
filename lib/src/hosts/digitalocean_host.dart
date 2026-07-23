import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../fly_name.dart';
import '../log.dart';
import '../templates.dart';
import 'adapter.dart';
import 'auth_helpers.dart';

/// DigitalOcean App Platform via `doctl` + DOCR images.
///
/// Local Docker builds Serverpod / nginx images → push to DOCR →
/// `doctl apps create --upsert --spec`. Managed Postgres is provisioned
/// separately (`doctl databases`) so credentials can be baked into the image.
class DigitalOceanHost extends HostAdapter {
  @override
  String get id => 'digitalocean';

  @override
  String get label => 'DigitalOcean App Platform';

  @override
  List<String> get cliBinaries => const ['doctl'];

  @override
  String get installHint =>
      'https://docs.digitalocean.com/reference/doctl/how-to/install/';

  @override
  List<String> get idAliases => const ['do'];

  @override
  List<CliInstallRecipe> get installRecipes => const [
        CliInstallRecipe(
          label: 'brew install doctl',
          executable: 'brew',
          args: ['install', 'doctl'],
        ),
      ];

  @override
  bool get canDeploy => true;

  @override
  AppHost get appHost => AppHost.digitalOcean;

  @override
  String get configKey => 'digitalocean';

  @override
  bool get supportsAllInOneWeb => false;

  @override
  bool get deploysWebNatively => true;

  @override
  List<DatabaseProvider> get supportedDatabases => const [
        DatabaseProvider.none,
        DatabaseProvider.digitalOceanPostgres,
        DatabaseProvider.neon,
        DatabaseProvider.supabase,
      ];

  @override
  String defaultApiUrl({
    required String name,
    required String sanitizedName,
  }) =>
      'https://$sanitizedName.ondigitalocean.app/';

  @override
  String? publicApiBase(PodflyConfig config) {
    final h = config.digitalOcean?.publicHost;
    if (h == null || h.isEmpty) return null;
    return h.startsWith('http') ? (h.endsWith('/') ? h : '$h/') : 'https://$h/';
  }

  @override
  String secretSetHint(String secretName, PodflyConfig config) =>
      'doctl apps update ${config.digitalOcean?.appId ?? '<app-id>'} '
      '(set $secretName in app spec envs)';

  @override
  Future<bool> checkAuth(DoctorContext ctx) {
    return authViaWhoami(
      ctx: ctx,
      whoamiArgs: const ['account', 'get'],
      loginCommand: 'doctl auth init',
      loginArgs: const ['auth', 'init'],
      tokenEnv: 'DIGITALOCEAN_ACCESS_TOKEN',
    );
  }

  @override
  void configWarnings(PodflyConfig config, Log log) {
    if (config.database.provider == DatabaseProvider.flyPostgres) {
      log.warn('fly_postgres is only available when host: fly');
    }
    if (config.database.provider == DatabaseProvider.railwayPostgres) {
      log.warn('railway_postgres is only available when host: railway');
    }
  }

  DigitalOceanConfig _cfg(PodflyConfig config) =>
      config.digitalOcean ??
      DigitalOceanConfig(app: sanitizeFlyAppName(config.name));

  @override
  Future<String?> ensureApiApp(DeployContext ctx) async {
    final doctl = await ctx.runner.resolve('doctl');
    if (doctl == null) throw StateError('doctl not found');
    await _ensureRegistry(ctx, doctl);
    return _cfg(ctx.config).app;
  }

  @override
  Future<HostDeployResult> deployApi(DeployContext ctx) async {
    final config = ctx.config;
    final runner = ctx.runner;
    final log = ctx.log;
    final dcfg = _cfg(config);
    final app = sanitizeFlyAppName(dcfg.app);

    log.step('Deploy DigitalOcean API ($app)');
    final doctl = await runner.resolve('doctl');
    if (doctl == null) {
      throw StateError('doctl not found — install: $installHint');
    }

    final registry = await _ensureRegistry(ctx, doctl);
    // Starter DOCR allows one repository — use one repo + tags (api/web).
    final apiRepo = dcfg.apiRepository ?? app;
    final tag = dcfg.apiRepository != null ? dcfg.imageTag : 'api';
    final imageRef = 'registry.digitalocean.com/$registry/$apiRepo:$tag';

    await _dockerBuildAndPush(
      ctx,
      imageRef: imageRef,
      dockerfile: p.join(config.server, 'Dockerfile'),
      context: config.root,
      platform: dcfg.platform,
    );

    final specPath = await _writeAppSpec(
      ctx,
      appName: app,
      registry: registry,
      apiRepo: apiRepo,
      tag: tag,
      includeWeb: false,
    );

    final appId = await _upsertApp(
      ctx,
      doctl,
      specPath,
      dcfg,
      idField: 'app_id',
      existingId: dcfg.appId,
      appName: app,
    );
    await _waitActive(ctx, doctl, appId);

    // Allow app → managed DB if we have a cluster id.
    final dbId = config.database.digitalOceanPostgres?.clusterId;
    if (dbId != null && dbId.isNotEmpty) {
      await _trustAppForDatabase(ctx, doctl, dbId, appId);
    }

    final ingress = await _defaultIngress(ctx, doctl, appId);
    if (ingress != null) {
      final host = ingress
          .replaceFirst(RegExp(r'^https?://'), '')
          .split('/')
          .first;
      await ctx.patchPublicHosts(host);
      await _persistDoField(ctx, 'public_host', host);
    }

    final url = ingress ?? 'https://$app.ondigitalocean.app';
    log.ok('DigitalOcean API: $url');
    return HostDeployResult(
      publicHost: ingress
          ?.replaceFirst(RegExp(r'^https?://'), '')
          .split('/')
          .first,
      displayUrl: url.endsWith('/') ? url : '$url/',
    );
  }

  @override
  Future<HostDeployResult?> deployWeb(DeployContext ctx) async {
    final config = ctx.config;
    final runner = ctx.runner;
    final log = ctx.log;
    final dcfg = _cfg(config);
    final app = sanitizeFlyAppName('${dcfg.app}-web');

    log.step('Deploy DigitalOcean web ($app)');
    final doctl = await runner.resolve('doctl');
    if (doctl == null) throw StateError('doctl not found');

    final registry = await _ensureRegistry(ctx, doctl);
    final base = sanitizeFlyAppName(dcfg.app);
    final webRepo = dcfg.webRepository ?? dcfg.apiRepository ?? base;
    final tag = dcfg.webRepository != null ? dcfg.imageTag : 'web';
    final imageRef = 'registry.digitalocean.com/$registry/$webRepo:$tag';

    // Stage nginx context: build/do_web/{public,nginx.conf,Dockerfile}
    final stage = p.join(config.root, 'build', 'do_web');
    await _stageWebImage(ctx, stage);

    await _dockerBuildAndPush(
      ctx,
      imageRef: imageRef,
      dockerfile: p.join(stage, 'Dockerfile'),
      context: stage,
      platform: dcfg.platform,
    );

    final specPath = await _writeWebAppSpec(
      ctx,
      appName: app,
      registry: registry,
      webRepo: webRepo,
      tag: tag,
    );

    final appId = await _upsertApp(
      ctx,
      doctl,
      specPath,
      dcfg,
      idField: 'web_app_id',
      existingId: dcfg.webAppId,
      appName: app,
    );
    await _waitActive(ctx, doctl, appId);
    final ingress = await _defaultIngress(ctx, doctl, appId);
    if (ingress != null) {
      final host = ingress
          .replaceFirst(RegExp(r'^https?://'), '')
          .split('/')
          .first;
      await _persistDoField(ctx, 'web_public_host', host);
    }
    final url = ingress ?? 'https://$app.ondigitalocean.app';
    log.ok('DigitalOcean web: $url');
    return HostDeployResult(
      publicHost: ingress
          ?.replaceFirst(RegExp(r'^https?://'), '')
          .split('/')
          .first,
      displayUrl: url.endsWith('/') ? url : '$url/',
    );
  }

  Future<void> _stageWebImage(DeployContext ctx, String stage) async {
    final config = ctx.config;
    final runner = ctx.runner;
    final log = ctx.log;
    final flutterBuild = p.join(config.flutterPath, 'build', 'web');
    if (!runner.dryRun && !Directory(flutterBuild).existsSync()) {
      throw StateError(
        'Flutter web build missing at $flutterBuild — run web build first',
      );
    }
    if (runner.dryRun) {
      log.dry('stage DO web image context at $stage');
      return;
    }
    final stageDir = Directory(stage);
    if (await stageDir.exists()) {
      await stageDir.delete(recursive: true);
    }
    await Directory(p.join(stage, 'public')).create(recursive: true);
    // Copy built web assets
    final copy = await Process.run('cp', ['-R', '$flutterBuild/.', p.join(stage, 'public')]);
    if (copy.exitCode != 0) {
      throw StateError('failed to stage flutter web: ${copy.stderr}');
    }
    await File(p.join(stage, 'nginx.conf')).writeAsString(
      readTemplate('nginx.railway_web.conf'),
    );
    await File(p.join(stage, 'Dockerfile')).writeAsString(
      readTemplate('Dockerfile.railway_web'),
    );
    log.detail('staged web image context → build/do_web');
  }

  Future<String> _ensureRegistry(DeployContext ctx, String doctl) async {
    final runner = ctx.runner;
    final log = ctx.log;
    final configured = ctx.config.digitalOcean?.registry;
    if (configured != null && configured.isNotEmpty) {
      return configured;
    }
    if (runner.dryRun) {
      log.dry('$doctl registry get');
      return 'registry';
    }
    final r = await runner.runCapture(
      doctl,
      ['registry', 'get', '-o', 'json'],
      allowDryRun: false,
    );
    if (!r.ok) {
      throw StateError(
        'No DigitalOcean Container Registry. Create one:\n'
        '  doctl registry create <name> --subscription-tier starter',
      );
    }
    final name = _jsonFirstString(r.stdout, 'name');
    if (name == null || name.isEmpty) {
      throw StateError('could not parse DOCR registry name from: ${r.stdout}');
    }
    log.detail('DOCR registry: $name');
    await _persistDoField(ctx, 'registry', name);
    // docker login
    await runner.run(doctl, ['registry', 'login'], allowDryRun: false);
    return name;
  }

  Future<void> _dockerBuildAndPush(
    DeployContext ctx, {
    required String imageRef,
    required String dockerfile,
    required String context,
    required String platform,
  }) async {
    final runner = ctx.runner;
    final log = ctx.log;
    if (runner.dryRun) {
      log.dry('docker build --platform $platform -t $imageRef -f $dockerfile $context');
      log.dry('docker push $imageRef');
      return;
    }
    final docker = await runner.resolve('docker');
    if (docker == null) {
      throw StateError(
        'docker not found — DigitalOcean deploy builds images locally then pushes to DOCR',
      );
    }
    log.detail('docker build $imageRef');
    final build = await runner.run(
      docker,
      [
        'build',
        '--platform',
        platform,
        '-t',
        imageRef,
        '-f',
        dockerfile,
        context,
      ],
      workingDirectory: ctx.config.root,
      allowDryRun: false,
    );
    if (!build.ok) {
      throw StateError('docker build failed (exit ${build.exitCode})');
    }
    log.detail('docker push $imageRef');
    final push = await runner.run(
      docker,
      ['push', imageRef],
      allowDryRun: false,
    );
    if (!push.ok) {
      throw StateError(
        'docker push failed (exit ${push.exitCode}). '
        'Run: doctl registry login',
      );
    }
    log.ok('pushed $imageRef');
  }

  Future<String> _writeAppSpec(
    DeployContext ctx, {
    required String appName,
    required String registry,
    required String apiRepo,
    required String tag,
    required bool includeWeb,
  }) async {
    final dcfg = _cfg(ctx.config);
    final path = p.join(ctx.config.root, dcfg.specFile);
    final region = dcfg.region;
    final size = dcfg.instanceSize;
    final buf = StringBuffer()
      ..writeln('name: $appName')
      ..writeln('region: $region')
      ..writeln('services:')
      ..writeln('- name: api')
      ..writeln('  http_port: ${dcfg.httpPort}')
      ..writeln('  instance_count: 1')
      ..writeln('  instance_size_slug: $size')
      ..writeln('  image:')
      ..writeln('    registry_type: DOCR')
      ..writeln('    repository: $apiRepo')
      ..writeln('    tag: "$tag"')
      ..writeln('    deploy_on_push:')
      ..writeln('      enabled: true')
      ..writeln('  health_check:')
      ..writeln('    http_path: /')
      ..writeln('    initial_delay_seconds: 30')
      ..writeln('    period_seconds: 10')
      ..writeln('    timeout_seconds: 5')
      ..writeln('    failure_threshold: 12')
      ..writeln('  envs:')
      ..writeln('  - key: runmode')
      ..writeln('    scope: RUN_TIME')
      ..writeln('    value: production')
      ..writeln('  - key: SERVERPOD_RUN_MODE')
      ..writeln('    scope: RUN_TIME')
      ..writeln('    value: production')
      ..writeln('ingress:')
      ..writeln('  rules:')
      ..writeln('  - component:')
      ..writeln('      name: api')
      ..writeln('    match:')
      ..writeln('      path:')
      ..writeln('        prefix: /');

    if (ctx.runner.dryRun) {
      ctx.log.dry('write $path');
      return path;
    }
    await File(path).writeAsString(buf.toString());
    ctx.log.detail('wrote $path');
    return path;
  }

  Future<String> _writeWebAppSpec(
    DeployContext ctx, {
    required String appName,
    required String registry,
    required String webRepo,
    required String tag,
  }) async {
    final dcfg = _cfg(ctx.config);
    final path = p.join(ctx.config.root, 'do-app.web.yaml');
    final buf = StringBuffer()
      ..writeln('name: $appName')
      ..writeln('region: ${dcfg.region}')
      ..writeln('services:')
      ..writeln('- name: web')
      ..writeln('  http_port: 80')
      ..writeln('  instance_count: 1')
      ..writeln('  instance_size_slug: ${dcfg.instanceSize}')
      ..writeln('  image:')
      ..writeln('    registry_type: DOCR')
      ..writeln('    repository: $webRepo')
      ..writeln('    tag: "$tag"')
      ..writeln('    deploy_on_push:')
      ..writeln('      enabled: true')
      ..writeln('ingress:')
      ..writeln('  rules:')
      ..writeln('  - component:')
      ..writeln('      name: web')
      ..writeln('    match:')
      ..writeln('      path:')
      ..writeln('        prefix: /');
    if (ctx.runner.dryRun) {
      ctx.log.dry('write $path');
      return path;
    }
    await File(path).writeAsString(buf.toString());
    return path;
  }

  Future<String> _upsertApp(
    DeployContext ctx,
    String doctl,
    String specPath,
    DigitalOceanConfig dcfg, {
    required String idField,
    String? existingId,
    required String appName,
  }) async {
    final runner = ctx.runner;
    final log = ctx.log;
    if (runner.dryRun) {
      log.dry('$doctl apps create --upsert --spec $specPath --wait');
      return existingId ?? 'dry-run-app-id';
    }

    if (existingId != null && existingId.isNotEmpty) {
      log.detail('updating app $existingId');
      final up = await runner.runCapture(
        doctl,
        [
          'apps',
          'update',
          existingId,
          '--spec',
          specPath,
          '--wait',
          '-o',
          'json',
        ],
        allowDryRun: false,
      );
      if (up.ok) {
        // Force new deployment with latest image tag
        await runner.run(
          doctl,
          ['apps', 'create-deployment', existingId, '--force-rebuild', '--wait'],
          allowDryRun: false,
        );
        return existingId;
      }
      log.warn('apps update failed — trying create --upsert');
    }

    // Do not --wait on create: first deploy may fail health until DB firewall
    // is updated; we still need the app id and can redeploy.
    final create = await runner.runCapture(
      doctl,
      [
        'apps',
        'create',
        '--upsert',
        '--spec',
        specPath,
        '-o',
        'json',
      ],
      allowDryRun: false,
    );
    var id = _jsonFirstString(create.stdout, 'id') ??
        _jsonFirstString(create.stdout, 'ID') ??
        await _findAppIdByName(ctx, doctl, appName);
    if (id == null && !create.ok) {
      // create --wait failure path still creates the app
      id = await _findAppIdByName(ctx, doctl, appName);
    }
    if (id == null) {
      throw StateError(
        'doctl apps create failed (${create.exitCode}): '
        '${create.stderr.isNotEmpty ? create.stderr : create.stdout}',
      );
    }
    await _persistDoField(ctx, idField, id);

    // Trigger deployment and wait (best-effort)
    await runner.run(
      doctl,
      ['apps', 'create-deployment', id, '--force-rebuild', '--wait'],
      allowDryRun: false,
    );
    return id;
  }

  Future<String?> _findAppIdByName(
    DeployContext ctx,
    String doctl,
    String name,
  ) async {
    final r = await ctx.runner.runCapture(
      doctl,
      ['apps', 'list', '-o', 'json'],
      allowDryRun: false,
    );
    if (!r.ok) return null;
    try {
      final list = jsonDecode(r.stdout);
      if (list is! List) return null;
      for (final item in list) {
        if (item is Map) {
          final spec = item['spec'];
          final n = spec is Map ? spec['name']?.toString() : null;
          if (n == name) return item['id']?.toString();
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _waitActive(DeployContext ctx, String doctl, String appId) async {
    if (ctx.runner.dryRun) return;
    // --wait on create/update should be enough; poll once for status
    final r = await ctx.runner.runCapture(
      doctl,
      ['apps', 'get', appId, '-o', 'json'],
      allowDryRun: false,
    );
    if (!r.ok) {
      ctx.log.warn('apps get $appId failed — continuing');
    }
  }

  Future<String?> _defaultIngress(
    DeployContext ctx,
    String doctl,
    String appId,
  ) async {
    if (ctx.runner.dryRun) return null;
    final r = await ctx.runner.runCapture(
      doctl,
      ['apps', 'get', appId, '-o', 'json'],
      allowDryRun: false,
    );
    if (!r.ok) return null;
    final live = _jsonFirstString(r.stdout, 'live_url') ??
        _jsonFirstString(r.stdout, 'default_ingress') ??
        _jsonFirstString(r.stdout, 'DefaultIngress');
    if (live != null) return live;
    // nested active_deployment
    try {
      final m = jsonDecode(r.stdout);
      if (m is Map) {
        final di = m['default_ingress']?.toString() ??
            m['live_url']?.toString();
        if (di != null && di.isNotEmpty) return di;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _trustAppForDatabase(
    DeployContext ctx,
    String doctl,
    String clusterId,
    String appId,
  ) async {
    if (ctx.runner.dryRun) {
      ctx.log.dry(
        '$doctl databases firewalls append $clusterId --rule type:app,value:$appId',
      );
      return;
    }
    ctx.log.detail('trust App Platform app $appId on database $clusterId');
    final r = await ctx.runner.run(
      doctl,
      [
        'databases',
        'firewalls',
        'append',
        clusterId,
        '--rule',
        'app:$appId',
      ],
      allowDryRun: false,
    );
    if (!r.ok) {
      ctx.log.warn(
        'could not add DB firewall for app (may already exist). '
        'If API cannot reach Postgres, run: '
        'doctl databases firewalls append $clusterId --rule type:app,value:$appId',
      );
    }
  }

  Future<void> _persistDoField(
    DeployContext ctx,
    String key,
    String value,
  ) async {
    final f = File(ctx.config.configPath);
    if (!await f.exists()) return;
    var text = await f.readAsString();
    // Ensure digitalocean: block exists
    if (!RegExp(r'^digitalocean:', multiLine: true).hasMatch(text)) {
      text = '$text\ndigitalocean:\n  app: ${_cfg(ctx.config).app}\n';
    }
    final fieldRe = RegExp('^(\\s*$key:\\s*).+\$', multiLine: true);
    if (fieldRe.hasMatch(text)) {
      text = text.replaceFirstMapped(fieldRe, (m) => '${m.group(1)}$value');
    } else {
      text = text.replaceFirst(
        RegExp(r'^(digitalocean:\n)', multiLine: true),
        'digitalocean:\n  $key: $value\n',
      );
    }
    await f.writeAsString(text);
    ctx.log.detail('podfly.yaml digitalocean.$key → $value');
  }

  String? _jsonFirstString(String raw, String key) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final v = decoded[key];
        if (v != null) return v.toString();
        // doctl sometimes wraps
        for (final e in decoded.values) {
          if (e is Map && e[key] != null) return e[key].toString();
        }
      }
      if (decoded is List && decoded.isNotEmpty && decoded.first is Map) {
        final v = (decoded.first as Map)[key];
        if (v != null) return v.toString();
      }
    } catch (_) {
      final m = RegExp('"$key"\\s*:\\s*"([^"]+)"').firstMatch(raw);
      return m?.group(1);
    }
    final m = RegExp('"$key"\\s*:\\s*"([^"]+)"').firstMatch(raw);
    return m?.group(1);
  }
}
