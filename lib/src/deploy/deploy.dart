import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../database/ensure.dart';
import '../fly_name.dart';
import '../log.dart';
import '../process_runner.dart';
import '../smoke.dart';
import '../templates.dart';
import '../web/build.dart';

class DeployOptions {
  DeployOptions({
    this.doApi = true,
    this.doWeb = true,
    this.smoke = false,
  });
  final bool doApi;
  final bool doWeb;
  final bool smoke;
}

class Deployer {
  Deployer({
    required this.config,
    required this.runner,
    required this.log,
  });

  final PodflyConfig config;
  final ProcessRunner runner;
  final Log log;

  /// Resolved Fly app name after sanitization / uniqueness (set during deploy).
  String? resolvedFlyApp;

  /// Resolved Railway public host (e.g. xxx.up.railway.app).
  String? resolvedRailwayHost;

  Future<void> run(DeployOptions opts) async {
    if (!config.host.isImplemented) {
      throw StateError(
        '${config.host.label} is not implemented in podfly yet '
        '(roadmap). Set host: fly or host: railway in podfly.yaml. '
        'See README provider table.',
      );
    }

    await _ensureServerDockerfile();
    // For Railway we may patch again after domain is known.
    if (config.host == AppHost.fly) {
      await _patchProductionPublicHosts(_flyPublicHost());
    }
    await DatabaseEnsure(config: config, runner: runner, log: log).run();

    final doWeb = opts.doWeb && config.web.enabled;
    final doApi = opts.doApi;
    if (opts.doWeb && !config.web.enabled) {
      log.detail('web.enabled: false — skipping Flutter web build/deploy');
    }

    if (doWeb) {
      await WebBuilder(config: config, runner: runner, log: log).build();
    }

    Future<void> deployApi() async {
      switch (config.host) {
        case AppHost.fly:
          await _deployFly();
        case AppHost.railway:
          await _deployRailway();
        default:
          throw StateError('${config.host.label} deploy not implemented');
      }
    }

    if (config.mode == DeployMode.split && doWeb) {
      await _deployPages();
      if (doApi) await deployApi();
    } else if (config.mode == DeployMode.split && !doWeb) {
      if (doApi) await deployApi();
    } else {
      // All-in-one only meaningful on Fly today; Railway is API-first.
      if (config.host == AppHost.fly && doWeb) {
        await _copyWebIntoServer();
      }
      if (doApi || (config.host == AppHost.fly && doWeb)) {
        await deployApi();
      }
    }

    if (opts.smoke && !runner.dryRun) {
      // Prefer reloaded yaml so railway.public_host / api_url stick after deploy.
      PodflyConfig smokeCfg = config;
      if (await File(config.configPath).exists()) {
        try {
          smokeCfg = await PodflyConfig.load(config.configPath);
        } catch (_) {/* use in-memory */}
      }
      if (resolvedRailwayHost != null &&
          smokeCfg.web.apiUrlNormalized.contains('REPLACE')) {
        smokeCfg = PodflyConfig(
          root: smokeCfg.root,
          host: smokeCfg.host,
          mode: smokeCfg.mode,
          name: smokeCfg.name,
          server: smokeCfg.server,
          flutter: smokeCfg.flutter,
          fly: smokeCfg.fly,
          railway: smokeCfg.railway,
          cloudflare: smokeCfg.cloudflare,
          database: smokeCfg.database,
          web: WebConfig(
            enabled: smokeCfg.web.enabled,
            serverUrlDefine: smokeCfg.web.serverUrlDefine,
            apiUrl: 'https://$resolvedRailwayHost/',
            patchBootstrap: smokeCfg.web.patchBootstrap,
            writeHeaders: smokeCfg.web.writeHeaders,
            baseHref: smokeCfg.web.baseHref,
            staticDir: smokeCfg.web.staticDir,
          ),
          smoke: smokeCfg.smoke,
        );
      }
      final ok = await SmokeRunner(config: smokeCfg, log: log).run();
      if (!ok) throw StateError('smoke checks failed');
    }

    log.step('Done');
    if (doWeb &&
        config.mode == DeployMode.split &&
        config.cloudflare != null) {
      log.detail(
          'UI:  https://${config.cloudflare!.project}.pages.dev');
    }
    if (doApi) {
      if (config.host == AppHost.railway) {
        final h = resolvedRailwayHost ??
            config.railway?.publicHost ??
            '?.up.railway.app';
        log.detail('API: https://$h/');
      } else {
        final app = resolvedFlyApp ?? sanitizeFlyAppName(config.fly.app);
        log.detail('API: https://$app.fly.dev/');
      }
    }
  }

  String _flyPublicHost() {
    final app = resolvedFlyApp ?? sanitizeFlyAppName(config.fly.app);
    return '$app.fly.dev';
  }

  Future<String> _flyBin() async {
    final fly = await runner.resolve('fly', ['flyctl']);
    if (fly == null) throw StateError('fly not found');
    return fly;
  }

  Future<String> _railwayBin() async {
    final r = await runner.resolve('railway');
    if (r == null) {
      throw StateError(
        'railway CLI not found — install: https://docs.railway.app/guides/cli '
        '(or ensure ~/.railway/bin is on PATH)',
      );
    }
    return r;
  }

  /// Write a Serverpod-style Dockerfile if the server package is missing one.
  Future<void> _ensureServerDockerfile() async {
    final rel = p.join(config.server, 'Dockerfile');
    final abs = p.join(config.root, rel);
    if (await File(abs).exists()) return;

    log.detail('no $rel — writing Serverpod-style Dockerfile template');
    var body = readTemplate('Dockerfile.serverpod');
    body = body.replaceAll('{{SERVER_DIR}}', config.server);
    if (runner.dryRun) {
      log.dry('write $rel');
      return;
    }
    await File(abs).parent.create(recursive: true);
    await File(abs).writeAsString(body);
    log.ok('wrote $rel (prefer `serverpod create` Dockerfile when available)');
  }

  /// Point production publicHost so Serverpod clients get HTTPS.
  Future<void> _patchProductionPublicHosts(String host) async {
    final prod = File(
      p.join(config.serverPath, 'config', 'production.yaml'),
    );
    // Mini templates sometimes use only development.yaml
    final candidates = [
      prod,
      File(p.join(config.serverPath, 'config', 'development.yaml')),
    ];
    final bare = host
        .replaceFirst(RegExp(r'^https?://'), '')
        .split('/')
        .first;

    for (final f in candidates) {
      if (!await f.exists()) continue;
      var text = await f.readAsString();
      final original = text;

      // apiServer publicHost — replace placeholders / localhost / previous podfly hosts
      text = text.replaceAllMapped(
        RegExp(
          r'(apiServer:[\s\S]*?publicHost:\s*)(\S+)',
          multiLine: true,
        ),
        (m) {
          final current = m.group(2)!;
          if (current.contains('localhost') ||
              current.contains('example') ||
              current.contains('REPLACE') ||
              current.contains('fly.dev') ||
              current.contains('railway.app') ||
              current == '""' ||
              current == "''") {
            return '${m.group(1)}$bare';
          }
          return m.group(0)!;
        },
      );
      text = text.replaceAllMapped(
        RegExp(
          r'(apiServer:[\s\S]*?publicScheme:\s*)(\S+)',
          multiLine: true,
        ),
        (m) {
          final current = m.group(2)!;
          if (current.contains('http') && !current.contains('https')) {
            return '${m.group(1)}https';
          }
          return m.group(0)!;
        },
      );
      text = text.replaceAllMapped(
        RegExp(
          r'(apiServer:[\s\S]*?publicPort:\s*)(\d+)',
          multiLine: true,
        ),
        (m) {
          final port = m.group(2)!;
          if (port == '8080' || port == '80') {
            return '${m.group(1)}443';
          }
          return m.group(0)!;
        },
      );

      if (text != original) {
        if (runner.dryRun) {
          log.dry(
              'patch ${p.relative(f.path, from: config.root)} publicHost → $bare');
        } else {
          final bak = File('${f.path}.podfly.bak');
          if (!await bak.exists()) await bak.writeAsString(original);
          await f.writeAsString(text);
          log.ok(
              'patched ${p.relative(f.path, from: config.root)} publicHost → $bare');
        }
      }
    }
  }

  Future<void> _ensureFlyToml(String app) async {
    final f = File(config.flyTomlPath);
    final dockerfile = p.join(config.server, 'Dockerfile');
    if (!await File(p.join(config.root, dockerfile)).exists() &&
        !runner.dryRun) {
      // _ensureServerDockerfile should have written it
      if (!await File(p.join(config.root, dockerfile)).exists()) {
        throw StateError('Missing $dockerfile after ensure step');
      }
    }

    if (await f.exists()) {
      // Keep app = name in sync if we sanitized / uniquified
      var text = await f.readAsString();
      final updated = text.replaceFirst(
        RegExp(r'^app\s*=\s*"[^"]*"', multiLine: true),
        'app = "$app"',
      );
      if (updated != text && !runner.dryRun) {
        await f.writeAsString(updated);
        log.detail('updated fly.toml app = $app');
      }
      return;
    }

    log.detail('generating ${config.fly.config}');
    var body = readTemplate('fly.toml.api_only');
    body = body
        .replaceAll('{{APP}}', app)
        .replaceAll('{{REGION}}', config.fly.region)
        .replaceAll('{{DOCKERFILE}}', dockerfile);
    if (runner.dryRun) {
      log.dry('write ${config.flyTomlPath}');
      return;
    }
    await f.writeAsString(body);
    log.ok('wrote ${config.fly.config}');
  }

  /// Ensure Fly app exists; if name is taken globally, try a unique suffix.
  Future<String> _ensureFlyApp(String flyBin, String preferred) async {
    if (runner.dryRun) {
      log.dry('$flyBin apps create $preferred  (if not exists)');
      return preferred;
    }

    var app = preferred;
    for (var attempt = 0; attempt < 5; attempt++) {
      if (await _flyAppExists(flyBin, app)) {
        log.detail('Fly app $app already exists');
        return app;
      }

      log.detail('creating Fly app $app');
      final create = await runner.run(
        flyBin,
        ['apps', 'create', app],
        allowDryRun: false,
      );
      if (create.ok) {
        log.ok('created Fly app $app');
        if (app != preferred) {
          await _persistFlyAppName(app);
        }
        return app;
      }

      final err = (create.stderr + create.stdout).toLowerCase();
      if (err.contains('already') || err.contains('taken')) {
        // Might be ours or someone else's — if status works, use it.
        if (await _flyAppExists(flyBin, app)) {
          log.detail('Fly app $app exists — continuing');
          return app;
        }
        // Taken by another org — pick a new name
        final suffix = Random().nextInt(0xFFFF).toRadixString(16).padLeft(4, '0');
        app = '$preferred-$suffix';
        log.warn('name taken — trying $app');
        continue;
      }

      throw StateError(
        'fly apps create $app failed (exit ${create.exitCode})',
      );
    }
    throw StateError('could not create a unique Fly app name from $preferred');
  }

  Future<bool> _flyAppExists(String flyBin, String app) async {
    final status = await runner.runCapture(
      flyBin,
      ['status', '-a', app],
      allowDryRun: false,
    );
    final combined = (status.stdout + status.stderr).toLowerCase();
    return status.ok &&
        !combined.contains('could not find') &&
        !combined.contains('not found') &&
        !combined.contains('error');
  }

  Future<void> _persistFlyAppName(String app) async {
    final cfgFile = File(config.configPath);
    if (!await cfgFile.exists()) return;
    var text = await cfgFile.readAsString();
    text = text.replaceFirst(
      RegExp(r'(^\s*app:\s*).+$', multiLine: true),
      '  app: $app',
    );
    text = text.replaceFirst(
      RegExp(r'(^\s*api_url:\s*).+$', multiLine: true),
      '  api_url: https://$app.fly.dev/',
    );
    await cfgFile.writeAsString(text);
    log.ok('updated podfly.yaml fly.app → $app');
  }

  Future<void> _deployFly() async {
    final preferred = sanitizeFlyAppName(config.fly.app);
    if (preferred != config.fly.app) {
      log.detail('Fly app name sanitized: ${config.fly.app} → $preferred');
    }
    log.step('Deploy Fly API ($preferred)');
    final fly = await _flyBin();
    final app = await _ensureFlyApp(fly, preferred);
    resolvedFlyApp = app;
    await _ensureFlyToml(app);

    final args = <String>[
      'deploy',
      '-a',
      app,
      '--config',
      config.fly.config,
    ];
    if (!config.fly.ha) args.add('--ha=false');
    final r = await runner.run(fly, args, workingDirectory: config.root);
    if (!r.ok && !runner.dryRun) {
      throw StateError('fly deploy failed (exit ${r.exitCode})');
    }
    log.ok('Fly: https://$app.fly.dev');
  }

  RailwayConfig get _railwayCfg =>
      config.railway ??
      RailwayConfig(project: sanitizeFlyAppName(config.name), service: 'api');

  Future<void> _deployRailway() async {
    final rcfg = _railwayCfg;
    final project = sanitizeFlyAppName(rcfg.project);
    final service = rcfg.service;
    log.step('Deploy Railway API ($project / $service)');
    final railway = await _railwayBin();

    await _ensureRailwayToml(rcfg);
    await _ensureRailwayProject(railway, project, rcfg);
    await _ensureRailwayService(railway, service);
    final host = await _ensureRailwayDomain(railway, service, rcfg.port);
    if (host != null) {
      resolvedRailwayHost = host;
      await _patchProductionPublicHosts(host);
      await _persistRailwayPublicHost(host);
    }

    // -c: stream build logs then exit (agent/CI friendly). -y: no prompts.
    final args = <String>[
      'up',
      '.',
      '-y',
      '-c',
      '-s',
      service,
    ];
    final r = await runner.run(
      railway,
      args,
      workingDirectory: config.root,
    );
    if (!r.ok && !runner.dryRun) {
      throw StateError('railway up failed (exit ${r.exitCode})');
    }
    final display = host ?? rcfg.publicHost ?? 'railway.app';
    log.ok('Railway: https://$display/');
  }

  Future<void> _ensureRailwayToml(RailwayConfig rcfg) async {
    final path = config.railwayTomlPath;
    final dockerfile = p.join(config.server, 'Dockerfile');
    final body = '''
# Generated by podfly — Serverpod monorepo root as Docker context
[build]
builder = "DOCKERFILE"
dockerfilePath = "$dockerfile"
''';
    if (await File(path).exists()) {
      // Keep dockerfilePath in sync if we wrote it before
      var text = await File(path).readAsString();
      if (!text.contains(dockerfile) && text.contains('dockerfilePath')) {
        text = text.replaceFirst(
          RegExp(r'dockerfilePath\s*=\s*"[^"]*"'),
          'dockerfilePath = "$dockerfile"',
        );
        if (!runner.dryRun) {
          await File(path).writeAsString(text);
          log.detail('updated ${rcfg.config} dockerfilePath');
        }
      }
      return;
    }
    if (runner.dryRun) {
      log.dry('write $path');
      return;
    }
    await File(path).writeAsString(body);
    log.ok('wrote ${rcfg.config}');
  }

  Future<void> _ensureRailwayProject(
    String railway,
    String projectName,
    RailwayConfig rcfg,
  ) async {
    if (runner.dryRun) {
      log.dry('$railway status / init --name $projectName (if unlinked)');
      return;
    }

    // Already linked in this directory?
    final status = await runner.runCapture(
      railway,
      ['status', '--json'],
      workingDirectory: config.root,
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
        workingDirectory: config.root,
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
      workingDirectory: config.root,
      allowDryRun: false,
    );
    if (!init.ok) {
      // Project name may already exist in account — try link via list
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
    // Persist project id if JSON has it
    await _tryPersistRailwayProjectId(init.stdout);
  }

  Future<void> _tryPersistRailwayProjectId(String jsonOut) async {
    try {
      // Best-effort: look for "id": "uuid"
      final m = RegExp(r'"id"\s*:\s*"([0-9a-fA-F-]{36})"').firstMatch(jsonOut);
      if (m == null) return;
      final id = m.group(1)!;
      final cfgFile = File(config.configPath);
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
      log.detail('saved railway.project_id → $id');
    } catch (_) {/* ignore */}
  }

  Future<void> _ensureRailwayService(String railway, String service) async {
    if (runner.dryRun) {
      log.dry('$railway service list / add --service $service');
      return;
    }
    final list = await runner.runCapture(
      railway,
      ['service', 'list', '--json'],
      workingDirectory: config.root,
      allowDryRun: false,
    );
    final out = list.stdout + list.stderr;
    if (list.ok &&
        (out.contains('"$service"') ||
            RegExp('"name"\\s*:\\s*"${RegExp.escape(service)}"')
                .hasMatch(out))) {
      log.detail('Railway service $service exists');
      // Ensure linked service
      await runner.run(
        railway,
        ['service', 'link', service],
        workingDirectory: config.root,
        allowDryRun: false,
      );
      return;
    }

    log.detail('creating Railway service $service');
    final add = await runner.run(
      railway,
      ['add', '--service', service, '--json'],
      workingDirectory: config.root,
      allowDryRun: false,
    );
    if (!add.ok) {
      throw StateError('railway add --service $service failed (${add.exitCode})');
    }
    await runner.run(
      railway,
      ['service', 'link', service],
      workingDirectory: config.root,
      allowDryRun: false,
    );
    log.ok('created Railway service $service');
  }

  Future<String?> _ensureRailwayDomain(
    String railway,
    String service,
    int port,
  ) async {
    if (runner.dryRun) {
      log.dry('$railway domain list / domain --port $port -s $service');
      return config.railway?.publicHost;
    }

    final list = await runner.runCapture(
      railway,
      ['domain', 'list', '-s', service, '--json'],
      workingDirectory: config.root,
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
      workingDirectory: config.root,
      allowDryRun: false,
    );
    final host = _parseRailwayDomain(create.stdout) ??
        _parseRailwayDomain(create.stderr);
    if (host != null) {
      log.ok('Railway domain $host');
      return host;
    }
    // Human-readable fallback: scan for *.up.railway.app
    final combined = create.stdout + create.stderr;
    final m = RegExp(r'([a-zA-Z0-9.-]+\.up\.railway\.app)').firstMatch(combined);
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
    // JSON keys commonly: domain, host, name
    for (final key in ['domain', 'host', 'name', 'serviceDomain']) {
      final m = RegExp('"$key"\\s*:\\s*"([^"]+)"').firstMatch(t);
      if (m != null) {
        final v = m.group(1)!;
        if (v.contains('.') && !v.contains(' ')) {
          return v.replaceFirst(RegExp(r'^https?://'), '').split('/').first;
        }
      }
    }
    final re = RegExp(r'([a-zA-Z0-9.-]+\.up\.railway\.app)');
    return re.firstMatch(t)?.group(1);
  }

  Future<void> _persistRailwayPublicHost(String host) async {
    final bare =
        host.replaceFirst(RegExp(r'^https?://'), '').split('/').first;
    final cfgFile = File(config.configPath);
    if (!await cfgFile.exists()) return;
    var text = await cfgFile.readAsString();
    if (RegExp(r'^\s*public_host:', multiLine: true).hasMatch(text)) {
      text = text.replaceFirst(
        RegExp(r'(^\s*public_host:\s*).+$', multiLine: true),
        '  public_host: $bare',
      );
    } else {
      // Insert under railway: block after first nested key line, or after railway:
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
    log.ok('updated podfly.yaml railway.public_host → $bare');
  }

  Future<void> _deployPages() async {
    final project = config.cloudflare!.project;
    log.step('Deploy Cloudflare Pages ($project)');
    final out = config.webOutPath;
    if (!runner.dryRun && !await File(p.join(out, 'index.html')).exists()) {
      throw StateError('missing web build at $out');
    }

    if (runner.dryRun) {
      log.dry('wrangler pages project list / create $project (if needed)');
    } else {
      final list = await runner.runCapture(
        'wrangler',
        ['pages', 'project', 'list'],
        allowDryRun: false,
      );
      if (!list.stdout.contains(project)) {
        log.detail('creating Cloudflare Pages project $project');
        final create = await runner.run('wrangler', [
          'pages',
          'project',
          'create',
          project,
          '--production-branch',
          config.cloudflare!.branch,
        ]);
        if (create.ok) {
          log.ok('created Pages project $project');
        } else {
          log.warn(
              'pages project create failed — deploy may still work if project exists');
        }
      }
    }

    final r = await runner.run('wrangler', [
      'pages',
      'deploy',
      out,
      '--project-name',
      project,
      '--branch',
      config.cloudflare!.branch,
    ]);
    if (!r.ok && !runner.dryRun) {
      throw StateError('wrangler pages deploy failed (exit ${r.exitCode})');
    }
    log.ok('Pages: https://$project.pages.dev');
  }

  Future<void> _copyWebIntoServer() async {
    final staticDir =
        config.web.staticDir ?? p.join(config.server, 'web', 'app');
    final dest = p.isAbsolute(staticDir)
        ? staticDir
        : p.join(config.root, staticDir);
    log.step('Copy web → $staticDir (fly mono)');
    if (runner.dryRun) {
      log.dry('copy ${config.webOutPath} → $dest');
      return;
    }
    final src = config.webOutPath;
    if (!await Directory(src).exists()) {
      throw StateError('build web first: missing $src');
    }
    await Directory(dest).create(recursive: true);
    if (await runner.which('rsync')) {
      await runner.run(
        'rsync',
        ['-a', '--delete', '$src/', '$dest/'],
        allowDryRun: false,
      );
    }
    log.ok('static files in $dest');
  }
}
