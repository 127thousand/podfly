import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../fly_name.dart';
import '../log.dart';
import '../templates.dart';
import 'adapter.dart';
import 'auth_helpers.dart';

class RailwayHost extends HostAdapter {
  @override
  String get id => 'railway';

  @override
  String get label => 'Railway';

  @override
  List<String> get cliBinaries => const ['railway'];

  @override
  String get installHint => 'https://docs.railway.app/guides/cli';

  @override
  List<CliInstallRecipe> get installRecipes => const [
        CliInstallRecipe(
          label: 'brew install railway',
          executable: 'brew',
          args: ['install', 'railway'],
        ),
        CliInstallRecipe(
          label: 'curl -fsSL https://railway.com/install.sh | sh',
          executable: 'sh',
          args: ['-c', 'curl -fsSL https://railway.com/install.sh | sh'],
          needsShell: true,
        ),
      ];

  @override
  bool get canDeploy => true;

  @override
  AppHost get appHost => AppHost.railway;

  @override
  String get configKey => 'railway';

  @override
  bool get supportsAllInOneWeb => false;

  @override
  bool get deploysWebNatively => true;

  @override
  List<DatabaseProvider> get supportedDatabases => const [
        DatabaseProvider.none,
        DatabaseProvider.railwayPostgres,
        DatabaseProvider.neon,
        DatabaseProvider.supabase,
      ];

  @override
  String defaultApiUrl({
    required String name,
    required String sanitizedName,
  }) =>
      'https://REPLACE.up.railway.app/';

  @override
  String? publicApiBase(PodflyConfig config) {
    return config.railway?.publicUrl;
  }

  @override
  String secretSetHint(String secretName, PodflyConfig config) {
    final svc = config.railway?.service ?? 'api';
    return 'railway variable set $secretName=… -s $svc';
  }

  @override
  Future<bool> checkAuth(DoctorContext ctx) {
    return authViaWhoami(
      ctx: ctx,
      whoamiArgs: const ['whoami'],
      loginCommand: 'railway login',
      loginArgs: const ['login'],
      tokenEnv: 'RAILWAY_TOKEN',
    );
  }

  @override
  void configWarnings(PodflyConfig config, Log log) {
    if (config.database.provider == DatabaseProvider.sqlite) {
      log.warn(
          'sqlite on Railway needs a volume wired manually — prefer neon or none');
    }
    if (config.database.provider == DatabaseProvider.flyPostgres) {
      log.warn('fly_postgres is only available when host: fly');
    }
  }

  RailwayConfig _cfg(PodflyConfig config) =>
      config.railway ??
      RailwayConfig(
        project: sanitizeFlyAppName(config.name),
        service: 'api',
      );

  @override
  Future<String?> ensureApiPublicHost(DeployContext ctx) async {
    final rcfg = _cfg(ctx.config);
    final project = sanitizeFlyAppName(rcfg.project);
    final service = rcfg.service;
    final railway = await ctx.runner.resolve('railway');
    if (railway == null) return null;

    ctx.log.step('Railway: ensure project + API domain');
    await _ensureRailwayProject(ctx, railway, project, rcfg);
    await _ensureRailwayService(ctx, railway, service);
    final host = await _ensureRailwayDomain(ctx, railway, service, rcfg.port);
    if (host != null) {
      await ctx.patchPublicHosts(host);
      await _persistRailwayPublicHost(ctx, host);
    }
    return host;
  }

  @override
  Future<HostDeployResult> deployApi(DeployContext ctx) async {
    final config = ctx.config;
    final runner = ctx.runner;
    final log = ctx.log;
    final rcfg = _cfg(config);
    final project = sanitizeFlyAppName(rcfg.project);
    final service = rcfg.service;

    log.step('Deploy Railway API ($project / $service)');
    final railway = await runner.resolve('railway');
    if (railway == null) {
      throw StateError(
        'railway CLI not found — install: $installHint '
        '(or ensure ~/.railway/bin is on PATH)',
      );
    }

    await _ensureRailwayToml(ctx, rcfg);
    await _ensureRailwayIgnore(ctx);
    await _ensureRailwayProject(ctx, railway, project, rcfg);
    await _ensureRailwayService(ctx, railway, service);
    await _ensureServerlessViaApi(ctx, railway, service, rcfg);
    final host = await _ensureRailwayDomain(ctx, railway, service, rcfg.port);
    if (host != null) {
      await ctx.patchPublicHosts(host);
      await _persistRailwayPublicHost(ctx, host);
    }

    // Do not pass PATH `.` — Railway CLI 5.x errors with "prefix not found".
    // Upload cwd via workingDirectory instead.
    final args = <String>['up', '-y', '-c', '-s', service];
    var r = await runner.run(
      railway,
      args,
      workingDirectory: config.root,
    );
    // Free-tier US regions often block peak hours — retry once in eu-west.
    if (!r.ok && !runner.dryRun) {
      log.warn(
          'railway up failed — retrying with eu-west=1 (free-tier peak hours?)');
      await runner.run(
        railway,
        ['scale', '-s', service, 'eu-west=1', 'us-west=0', 'us-east=0'],
        workingDirectory: config.root,
        allowDryRun: false,
      );
      r = await runner.run(
        railway,
        args,
        workingDirectory: config.root,
      );
    }
    if (!r.ok && !runner.dryRun) {
      throw StateError(
        'railway up failed (exit ${r.exitCode}). '
        'If free-tier peak hours: railway scale -s $service eu-west=1 && retry',
      );
    }
    final display = host ?? rcfg.publicHost ?? 'railway.app';
    final url = 'https://$display/';
    log.ok('Railway API: $url');
    return HostDeployResult(publicHost: host ?? rcfg.publicHost, displayUrl: url);
  }

  @override
  Future<HostDeployResult?> deployWeb(DeployContext ctx) async {
    final config = ctx.config;
    final runner = ctx.runner;
    final log = ctx.log;
    final rcfg = _cfg(config);
    final project = sanitizeFlyAppName(rcfg.project);
    final service = rcfg.webService;

    log.step('Deploy Railway web ($project / $service)');
    final railway = await runner.resolve('railway');
    if (railway == null) {
      throw StateError('railway CLI not found — install: $installHint');
    }

    // Stage outside the monorepo so `railway up` does not archive local
    // Serverpod unix sockets (upload fails with "socket can not be archived").
    final stageAbs = p.join(
      Directory.systemTemp.path,
      'podfly-railway-web-${sanitizeFlyAppName(config.name)}',
    );
    await _stageWebBundle(ctx, stageAbs);

    await _ensureRailwayProject(ctx, railway, project, rcfg);
    await _ensureRailwayService(ctx, railway, service);
    await _ensureServerlessViaApi(ctx, railway, service, rcfg);
    await _ensureRailwayIgnore(ctx);

    // No PATH arg (CLI "prefix not found"); cwd = staged bundle only.
    // Explicit -p/-e required when cwd is outside the monorepo link.
    final args = <String>[
      'up',
      '-y',
      '-c',
      '-s',
      service,
      '-e',
      rcfg.environment,
    ];
    final projectId = rcfg.projectId ?? await _readLinkedProjectId(ctx, railway);
    if (projectId != null) {
      args.addAll(['-p', projectId]);
    }
    if (runner.dryRun) {
      log.dry('$railway ${args.join(' ')}  (cwd: $stageAbs)');
    } else {
      var r = await runner.run(
        railway,
        args,
        workingDirectory: stageAbs,
      );
      if (!r.ok) {
        log.warn('railway up web failed — retry eu-west');
        await runner.run(
          railway,
          ['scale', '-s', service, 'eu-west=1', 'us-west=0', 'us-east=0'],
          workingDirectory: config.root,
          allowDryRun: false,
        );
        r = await runner.run(
          railway,
          args,
          workingDirectory: stageAbs,
        );
      }
      if (!r.ok) {
        throw StateError('railway up web failed (exit ${r.exitCode})');
      }
    }

    final host =
        await _ensureRailwayDomain(ctx, railway, service, rcfg.webPort);
    if (host != null) {
      await _persistRailwayWebHost(ctx, host);
    }

    if (rcfg.enableCdn && !runner.dryRun) {
      final cdn = await runner.run(
        railway,
        ['cdn', 'enable', '-s', service],
        workingDirectory: config.root,
        allowDryRun: false,
      );
      if (cdn.ok) {
        log.ok('Railway CDN enabled on $service');
      } else {
        log.detail('CDN enable skipped/failed (optional)');
      }
    }

    final display = host ?? rcfg.webPublicHost ?? 'railway.app';
    final url = 'https://$display/';
    log.ok('Railway web: $url');
    return HostDeployResult(publicHost: host, displayUrl: url);
  }

  Future<void> _stageWebBundle(DeployContext ctx, String stageAbs) async {
    final src = ctx.config.webOutPath;
    final publicDir = p.join(stageAbs, 'public');
    if (ctx.runner.dryRun) {
      ctx.log.dry('stage web → $stageAbs (from $src)');
      return;
    }
    if (!await Directory(src).exists()) {
      throw StateError('missing Flutter web build at $src');
    }
    await Directory(publicDir).create(recursive: true);
    // Copy build output into public/
    if (await ctx.runner.which('rsync')) {
      await ctx.runner.run(
        'rsync',
        ['-a', '--delete', '$src/', '$publicDir/'],
        allowDryRun: false,
      );
    } else {
      // Fallback: recursive copy via shell
      await ctx.runner.run(
        'cp',
        ['-R', '$src/.', publicDir],
        allowDryRun: false,
      );
    }
    await File(p.join(stageAbs, 'Dockerfile'))
        .writeAsString(readTemplate('Dockerfile.railway_web'));
    await File(p.join(stageAbs, 'nginx.conf'))
        .writeAsString(readTemplate('nginx.railway_web.conf'));
    final sleep = ctx.config.railway?.serverless ?? true;
    await File(p.join(stageAbs, 'railway.toml')).writeAsString('''
# Generated by podfly — static Flutter web on Railway
[build]
builder = "DOCKERFILE"
dockerfilePath = "Dockerfile"

[deploy]
sleepApplication = $sleep
''');
    ctx.log.ok('staged Railway web bundle → $stageAbs (serverless=$sleep)');
  }

  /// Keep `railway up` small and free of local sockets (413 / archive errors).
  Future<void> _ensureRailwayIgnore(DeployContext ctx) async {
    final path = p.join(ctx.config.root, '.railwayignore');
    final flutter = ctx.config.flutter;
    final lines = <String>[
      '# Written by podfly — slim monorepo upload for Serverpod API image',
      '.serverpod/',
      '**/.s.PGSQL*',
      '**/*.sock',
      '.dart_tool/',
      '**/build/',
      'build/',
      '.git/',
      if (flutter.isNotEmpty) '$flutter/',
      // Client package if present next to server
      if (ctx.config.server.endsWith('_server'))
        '${ctx.config.server.replaceFirst(RegExp(r'_server$'), '_client')}/',
    ];
    final body = '${lines.join('\n')}\n';
    if (ctx.runner.dryRun) {
      ctx.log.dry('write .railwayignore');
      return;
    }
    // Always refresh so size limits stay current.
    await File(path).writeAsString(body);
    ctx.log.detail('ensured .railwayignore (exclude flutter/build/sockets)');
  }

  Future<String?> _readLinkedProjectId(
    DeployContext ctx,
    String railway,
  ) async {
    final status = await ctx.runner.runCapture(
      railway,
      ['status', '--json'],
      workingDirectory: ctx.config.root,
      allowDryRun: false,
    );
    final m = RegExp(r'"id"\s*:\s*"([0-9a-fA-F-]{36})"')
        .firstMatch(status.stdout);
    return m?.group(1) ?? ctx.config.railway?.projectId;
  }

  /// Enable Railway Serverless via Public GraphQL API.
  ///
  /// There is **no** `railway serverless` CLI subcommand. The dashboard uses
  /// `serviceInstanceUpdate(sleepApplication: true)`. We do the same with the
  /// logged-in CLI token (or `RAILWAY_TOKEN`).
  Future<void> _ensureServerlessViaApi(
    DeployContext ctx,
    String railway,
    String serviceName,
    RailwayConfig rcfg,
  ) async {
    if (!rcfg.serverless) {
      ctx.log.detail('railway.serverless: false — skip Serverless API update');
      return;
    }
    if (ctx.runner.dryRun) {
      ctx.log.dry(
          'GraphQL serviceInstanceUpdate sleepApplication=true for $serviceName');
      return;
    }

    final ids = await _resolveServiceIds(ctx, railway, serviceName, rcfg);
    if (ids == null) {
      ctx.log.detail(
          'could not resolve service/env ids for Serverless — relying on railway.toml');
      return;
    }

    final token = await _railwayApiToken();
    if (token == null || token.isEmpty) {
      ctx.log.detail(
          'no Railway API token — Serverless only via railway.toml sleepApplication');
      return;
    }

    final tmp = File(
      p.join(Directory.systemTemp.path, 'podfly-railway-serverless.json'),
    );
    await tmp.writeAsString(_jsonEncodeServerlessMutation(
      serviceId: ids.serviceId,
      environmentId: ids.environmentId,
      sleep: true,
    ));
    final r = await ctx.runner.runCapture(
      'curl',
      [
        '-sS',
        '-X',
        'POST',
        'https://backboard.railway.com/graphql/v2',
        '-H',
        'Content-Type: application/json',
        '-H',
        'Authorization: Bearer $token',
        '--data-binary',
        '@${tmp.path}',
      ],
      workingDirectory: ctx.config.root,
      allowDryRun: false,
    );
    if (!r.ok) {
      ctx.log.warn(
          'Serverless GraphQL failed — railway.toml sleepApplication still applies on up');
      return;
    }
    final out = r.stdout + r.stderr;
    if (out.contains('"errors"')) {
      ctx.log.warn('Serverless GraphQL: ${out.trim()}');
      return;
    }
    ctx.log.ok('Railway Serverless enabled for $serviceName (GraphQL API)');
  }

  String _jsonEncodeServerlessMutation({
    required String serviceId,
    required String environmentId,
    required bool sleep,
  }) {
    return '{"query":"mutation(\$serviceId:String!,\$environmentId:String!,\$input:ServiceInstanceUpdateInput!){serviceInstanceUpdate(serviceId:\$serviceId,environmentId:\$environmentId,input:\$input)}","variables":{"serviceId":"$serviceId","environmentId":"$environmentId","input":{"sleepApplication":$sleep}}}';
  }

  Future<({String serviceId, String environmentId})?> _resolveServiceIds(
    DeployContext ctx,
    String railway,
    String serviceName,
    RailwayConfig rcfg,
  ) async {
    final status = await ctx.runner.runCapture(
      railway,
      ['status', '--json'],
      workingDirectory: ctx.config.root,
      allowDryRun: false,
    );
    if (!status.ok) return null;
    final text = status.stdout;
    // environment id
    final envId = RegExp(r'"environmentId"\s*:\s*"([0-9a-fA-F-]{36})"')
            .firstMatch(text)
            ?.group(1) ??
        RegExp(
          r'"environments"[^]]*?"id"\s*:\s*"([0-9a-fA-F-]{36})"',
        ).firstMatch(text)?.group(1);

    // Prefer matching service by name from service list --json
    final list = await ctx.runner.runCapture(
      railway,
      ['service', 'list', '--json'],
      workingDirectory: ctx.config.root,
      allowDryRun: false,
    );
    String? serviceId;
    final nameRe = RegExp(
      '"id"\\s*:\\s*"([0-9a-fA-F-]{36})"\\s*,\\s*"name"\\s*:\\s*"${RegExp.escape(serviceName)}"',
    );
    final nameRe2 = RegExp(
      '"name"\\s*:\\s*"${RegExp.escape(serviceName)}"\\s*,\\s*"id"\\s*:\\s*"([0-9a-fA-F-]{36})"',
    );
    serviceId = nameRe.firstMatch(list.stdout)?.group(1) ??
        nameRe2.firstMatch(list.stdout)?.group(1);

    // Human status also prints "service ID: uuid"
    serviceId ??= RegExp(
      'service ID:\\s*([0-9a-fA-F-]{36})',
      caseSensitive: false,
    ).firstMatch(status.stdout + list.stdout)?.group(1);

    if (serviceId == null || envId == null) return null;
    return (serviceId: serviceId, environmentId: envId);
  }

  Future<String?> _railwayApiToken() async {
    final env = Platform.environment['RAILWAY_TOKEN'] ??
        Platform.environment['RAILWAY_API_TOKEN'];
    if (env != null && env.isNotEmpty) return env;

    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    if (home.isEmpty) return null;
    final cfg = File(p.join(home, '.railway', 'config.json'));
    if (!await cfg.exists()) return null;
    try {
      final text = await cfg.readAsString();
      final m = RegExp(r'"accessToken"\s*:\s*"([^"]+)"').firstMatch(text);
      return m?.group(1);
    } catch (_) {
      return null;
    }
  }

  Future<void> _ensureRailwayToml(
    DeployContext ctx,
    RailwayConfig rcfg,
  ) async {
    final path = ctx.config.railwayTomlPath;
    final dockerfile = p.join(ctx.config.server, 'Dockerfile');
    final sleep = rcfg.serverless;
    final body = '''
# Generated by podfly — Serverpod monorepo root as Docker context
[build]
builder = "DOCKERFILE"
dockerfilePath = "$dockerfile"

[deploy]
# Railway Serverless (formerly app sleeping): stop when idle ~10m.
# Does not apply to Postgres plugins. Off if railway.serverless: false.
sleepApplication = $sleep
''';
    if (await File(path).exists()) {
      var text = await File(path).readAsString();
      var changed = false;
      if (!text.contains(dockerfile) && text.contains('dockerfilePath')) {
        text = text.replaceFirst(
          RegExp(r'dockerfilePath\s*=\s*"[^"]*"'),
          'dockerfilePath = "$dockerfile"',
        );
        changed = true;
      }
      if (!text.contains('sleepApplication')) {
        text = text.trimRight();
        text = '$text\n\n[deploy]\nsleepApplication = $sleep\n';
        changed = true;
      } else {
        final updated = text.replaceFirst(
          RegExp(r'sleepApplication\s*=\s*(true|false)'),
          'sleepApplication = $sleep',
        );
        if (updated != text) {
          text = updated;
          changed = true;
        }
      }
      if (changed && !ctx.runner.dryRun) {
        await File(path).writeAsString(text);
        ctx.log.detail('updated ${rcfg.config}');
      }
      return;
    }
    if (ctx.runner.dryRun) {
      ctx.log.dry('write $path (sleepApplication=$sleep)');
      return;
    }
    await File(path).writeAsString(body);
    ctx.log.ok('wrote ${rcfg.config} (serverless/sleep=$sleep)');
  }

  Future<void> _ensureRailwayProject(
    DeployContext ctx,
    String railway,
    String projectName,
    RailwayConfig rcfg,
  ) async {
    final runner = ctx.runner;
    final log = ctx.log;
    if (runner.dryRun) {
      log.dry('$railway status / init --name $projectName (if unlinked)');
      return;
    }

    final status = await runner.runCapture(
      railway,
      ['status', '--json'],
      workingDirectory: ctx.config.root,
      allowDryRun: false,
    );
    if (status.ok && status.stdout.trim().isNotEmpty) {
      log.detail('Railway project already linked');
      return;
    }

    if (rcfg.projectId != null && rcfg.projectId!.isNotEmpty) {
      log.detail('linking Railway project ${rcfg.projectId}');
      final link = await runner.run(
        railway,
        [
          'link',
          '-p',
          rcfg.projectId!,
          '-s',
          rcfg.service,
          '-e',
          rcfg.environment,
        ],
        workingDirectory: ctx.config.root,
        allowDryRun: false,
      );
      if (!link.ok) {
        throw StateError(
            'railway link failed (exit ${link.exitCode}) for ${rcfg.projectId}');
      }
      log.ok('linked Railway project ${rcfg.projectId}');
      return;
    }

    log.detail('creating Railway project $projectName');
    final init = await runner.runCapture(
      railway,
      ['init', '--name', projectName, '--json'],
      workingDirectory: ctx.config.root,
      allowDryRun: false,
    );
    if (!init.ok) {
      log.warn(
          'railway init failed (exit ${init.exitCode}); try linking existing project');
      final combined = init.stdout + init.stderr;
      if (combined.toLowerCase().contains('already') ||
          combined.toLowerCase().contains('exists')) {
        log.detail(
            'If the project exists: railway link -p <id> -s ${rcfg.service}');
      }
      throw StateError(
        'railway init failed (exit ${init.exitCode}): ${init.stderr}',
      );
    }
    log.ok('created Railway project $projectName');
    await _tryPersistRailwayProjectId(ctx, init.stdout);
  }

  Future<void> _tryPersistRailwayProjectId(
    DeployContext ctx,
    String jsonOut,
  ) async {
    try {
      final m =
          RegExp(r'"id"\s*:\s*"([0-9a-fA-F-]{36})"').firstMatch(jsonOut);
      if (m == null) return;
      final id = m.group(1)!;
      final cfgFile = File(ctx.config.configPath);
      if (!await cfgFile.exists()) return;
      var text = await cfgFile.readAsString();
      if (text.contains('project_id:')) {
        text = text.replaceFirst(
          RegExp(r'(^\s*project_id:\s*).+$', multiLine: true),
          '  project_id: $id',
        );
      } else if (text.contains(RegExp(r'^railway:', multiLine: true))) {
        text = text.replaceFirst(
          RegExp(r'^(railway:\n)', multiLine: true),
          'railway:\n  project_id: $id\n',
        );
      }
      await cfgFile.writeAsString(text);
      ctx.log.detail('saved railway.project_id → $id');
    } catch (_) {/* ignore */}
  }

  Future<void> _ensureRailwayService(
    DeployContext ctx,
    String railway,
    String service,
  ) async {
    final runner = ctx.runner;
    final log = ctx.log;
    if (runner.dryRun) {
      log.dry('$railway service list / add --service $service');
      return;
    }
    final list = await runner.runCapture(
      railway,
      ['service', 'list', '--json'],
      workingDirectory: ctx.config.root,
      allowDryRun: false,
    );
    final out = list.stdout + list.stderr;
    if (list.ok &&
        (out.contains('"$service"') ||
            RegExp('"name"\\s*:\\s*"${RegExp.escape(service)}"')
                .hasMatch(out))) {
      log.detail('Railway service $service exists');
      await runner.run(
        railway,
        ['service', 'link', service],
        workingDirectory: ctx.config.root,
        allowDryRun: false,
      );
      return;
    }

    log.detail('creating Railway service $service');
    final add = await runner.run(
      railway,
      ['add', '--service', service, '--json'],
      workingDirectory: ctx.config.root,
      allowDryRun: false,
    );
    if (!add.ok) {
      throw StateError(
          'railway add --service $service failed (${add.exitCode})');
    }
    await runner.run(
      railway,
      ['service', 'link', service],
      workingDirectory: ctx.config.root,
      allowDryRun: false,
    );
    log.ok('created Railway service $service');
  }

  Future<String?> _ensureRailwayDomain(
    DeployContext ctx,
    String railway,
    String service,
    int port,
  ) async {
    final runner = ctx.runner;
    final log = ctx.log;
    if (runner.dryRun) {
      log.dry('$railway domain list / domain --port $port -s $service');
      return ctx.config.railway?.publicHost;
    }

    final list = await runner.runCapture(
      railway,
      ['domain', 'list', '-s', service, '--json'],
      workingDirectory: ctx.config.root,
      allowDryRun: false,
    );
    final existing = _parseRailwayDomain(list.stdout);
    if (existing != null) {
      log.detail('Railway domain $existing');
      return existing;
    }

    log.detail('creating Railway domain (port $port)');
    final create = await runner.runCapture(
      railway,
      ['domain', '--port', '$port', '-s', service, '--json'],
      workingDirectory: ctx.config.root,
      allowDryRun: false,
    );
    final host = _parseRailwayDomain(create.stdout) ??
        _parseRailwayDomain(create.stderr);
    if (host != null) {
      log.ok('Railway domain $host');
      return host;
    }
    final combined = create.stdout + create.stderr;
    final m =
        RegExp(r'([a-zA-Z0-9.-]+\.up\.railway\.app)').firstMatch(combined);
    if (m != null) {
      log.ok('Railway domain ${m.group(1)}');
      return m.group(1);
    }
    log.warn(
        'could not parse Railway domain — set railway.public_host in podfly.yaml');
    return null;
  }

  String? _parseRailwayDomain(String jsonOrText) {
    final t = jsonOrText.trim();
    if (t.isEmpty) return null;
    for (final key in ['domain', 'host', 'name', 'serviceDomain']) {
      final m = RegExp('"$key"\\s*:\\s*"([^"]+)"').firstMatch(t);
      if (m != null) {
        final v = m.group(1)!;
        if (v.contains('.') && !v.contains(' ')) {
          return v.replaceFirst(RegExp(r'^https?://'), '').split('/').first;
        }
      }
    }
    return RegExp(r'([a-zA-Z0-9.-]+\.up\.railway\.app)').firstMatch(t)?.group(1);
  }

  Future<void> _persistRailwayPublicHost(
    DeployContext ctx,
    String host,
  ) async {
    final bare =
        host.replaceFirst(RegExp(r'^https?://'), '').split('/').first;
    final cfgFile = File(ctx.config.configPath);
    if (!await cfgFile.exists()) return;
    var text = await cfgFile.readAsString();
    if (RegExp(r'^\s*public_host:', multiLine: true).hasMatch(text)) {
      text = text.replaceFirst(
        RegExp(r'(^\s*public_host:\s*).+$', multiLine: true),
        '  public_host: $bare',
      );
    } else {
      final railwayHeader = RegExp(r'^railway:\s*$', multiLine: true);
      if (railwayHeader.hasMatch(text)) {
        text = text.replaceFirst(
          railwayHeader,
          'railway:\n  public_host: $bare',
        );
      }
    }
    text = text.replaceFirst(
      RegExp(r'(^\s*api_url:\s*).+$', multiLine: true),
      '  api_url: https://$bare/',
    );
    await cfgFile.writeAsString(text);
    ctx.log.ok('updated podfly.yaml railway.public_host → $bare');
  }

  Future<void> _persistRailwayWebHost(
    DeployContext ctx,
    String host,
  ) async {
    final bare =
        host.replaceFirst(RegExp(r'^https?://'), '').split('/').first;
    final cfgFile = File(ctx.config.configPath);
    if (!await cfgFile.exists()) return;
    var text = await cfgFile.readAsString();
    if (RegExp(r'^\s*web_public_host:', multiLine: true).hasMatch(text)) {
      text = text.replaceFirst(
        RegExp(r'(^\s*web_public_host:\s*).+$', multiLine: true),
        '  web_public_host: $bare',
      );
    } else if (RegExp(r'^railway:', multiLine: true).hasMatch(text)) {
      text = text.replaceFirst(
        RegExp(r'^(railway:\s*)$', multiLine: true),
        'railway:\n  web_public_host: $bare',
      );
      // If railway: already has nested keys, append web_public_host after first line
      if (!text.contains('web_public_host:')) {
        text = text.replaceFirst(
          RegExp(r'^(railway:\n)', multiLine: true),
          'railway:\n  web_public_host: $bare\n',
        );
      }
    }
    await cfgFile.writeAsString(text);
    ctx.log.ok('updated podfly.yaml railway.web_public_host → $bare');
  }
}
