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

  Future<void> run(DeployOptions opts) async {
    if (!config.host.isImplemented) {
      throw StateError(
        '${config.host.label} is not implemented in podfly yet '
        '(roadmap). Set host: fly in podfly.yaml, or contribute a provider. '
        'See README provider table.',
      );
    }

    await _ensureServerDockerfile();
    await _patchProductionPublicHosts();
    await DatabaseEnsure(config: config, runner: runner, log: log).run();

    final doWeb = opts.doWeb && config.web.enabled;
    final doApi = opts.doApi;
    if (opts.doWeb && !config.web.enabled) {
      log.detail('web.enabled: false — skipping Flutter web build/deploy');
    }

    if (doWeb) {
      await WebBuilder(config: config, runner: runner, log: log).build();
    }

    if (config.mode == DeployMode.split && doWeb) {
      await _deployPages();
      if (doApi) await _deployFly();
    } else if (config.mode == DeployMode.split && !doWeb) {
      if (doApi) await _deployFly();
    } else {
      if (doWeb) await _copyWebIntoServer();
      if (doApi || doWeb) await _deployFly();
    }

    if (opts.smoke && !runner.dryRun) {
      final ok = await SmokeRunner(config: config, log: log).run();
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
      final app = resolvedFlyApp ?? sanitizeFlyAppName(config.fly.app);
      log.detail('API: https://$app.fly.dev/');
    }
  }

  Future<String> _flyBin() async {
    final fly = await runner.resolve('fly', ['flyctl']);
    if (fly == null) throw StateError('fly not found');
    return fly;
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

  /// Point production publicHost at the Fly app so Serverpod clients get HTTPS.
  Future<void> _patchProductionPublicHosts() async {
    final prod = File(
      p.join(config.serverPath, 'config', 'production.yaml'),
    );
    // Mini templates sometimes use only development.yaml
    final candidates = [
      prod,
      File(p.join(config.serverPath, 'config', 'development.yaml')),
    ];
    final app = sanitizeFlyAppName(config.fly.app);
    final host = '$app.fly.dev';

    for (final f in candidates) {
      if (!await f.exists()) continue;
      var text = await f.readAsString();
      final original = text;

      // apiServer publicHost
      text = text.replaceAllMapped(
        RegExp(
          r'(apiServer:[\s\S]*?publicHost:\s*)(\S+)',
          multiLine: true,
        ),
        (m) {
          final current = m.group(2)!;
          if (current.contains('localhost') ||
              current.contains('example') ||
              current == '""' ||
              current == "''") {
            return '${m.group(1)}$host';
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
          log.dry('patch ${p.relative(f.path, from: config.root)} publicHost → $host');
        } else {
          final bak = File('${f.path}.podfly.bak');
          if (!await bak.exists()) await bak.writeAsString(original);
          await f.writeAsString(text);
          log.ok(
              'patched ${p.relative(f.path, from: config.root)} publicHost → $host');
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
