import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../database/ensure.dart';
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

  Future<void> run(DeployOptions opts) async {
    await DatabaseEnsure(config: config, runner: runner, log: log).run();

    if (opts.doWeb) {
      await WebBuilder(config: config, runner: runner, log: log).build();
    }

    if (config.mode == DeployMode.split) {
      if (opts.doWeb) await _deployPages();
      if (opts.doApi) await _deployFly();
    } else {
      if (opts.doWeb) await _copyWebIntoServer();
      if (opts.doApi || opts.doWeb) await _deployFly();
    }

    if (opts.smoke && !runner.dryRun) {
      final ok = await SmokeRunner(config: config, log: log).run();
      if (!ok) throw StateError('smoke checks failed');
    }

    log.step('Done');
    if (config.mode == DeployMode.split) {
      log.detail(
          'UI:  https://${config.cloudflare!.project}.pages.dev');
    }
    log.detail('API: ${config.web.apiUrlNormalized}');
  }

  Future<String> _flyBin() async {
    final fly = await runner.resolve('fly', ['flyctl']);
    if (fly == null) throw StateError('fly not found');
    return fly;
  }

  Future<void> _ensureFlyToml() async {
    final f = File(config.flyTomlPath);
    if (await f.exists()) return;
    log.detail('generating ${config.fly.config}');
    var dockerfile = p.join(config.server, 'Dockerfile');
    if (!await File(p.join(config.root, dockerfile)).exists()) {
      dockerfile = 'Dockerfile';
    }
    var body = readTemplate('fly.toml.api_only');
    body = body
        .replaceAll('{{APP}}', config.fly.app)
        .replaceAll('{{REGION}}', config.fly.region)
        .replaceAll('{{DOCKERFILE}}', dockerfile);
    if (runner.dryRun) {
      log.dry('write ${config.flyTomlPath}');
      return;
    }
    await f.writeAsString(body);
    log.ok('wrote ${config.fly.config}');
  }

  Future<void> _deployFly() async {
    log.step('Deploy Fly API (${config.fly.app})');
    await _ensureFlyToml();
    final fly = await _flyBin();
    final args = <String>[
      'deploy',
      '-a',
      config.fly.app,
      '--config',
      config.fly.config,
    ];
    if (!config.fly.ha) args.add('--ha=false');
    final r = await runner.run(fly, args, workingDirectory: config.root);
    if (!r.ok && !runner.dryRun) {
      throw StateError('fly deploy failed (exit ${r.exitCode})');
    }
    log.ok('Fly: https://${config.fly.app}.fly.dev');
  }

  Future<void> _deployPages() async {
    final project = config.cloudflare!.project;
    log.step('Deploy Cloudflare Pages ($project)');
    final out = config.webOutPath;
    if (!runner.dryRun && !await File(p.join(out, 'index.html')).exists()) {
      throw StateError('missing web build at $out');
    }

    // Create project if missing (best effort). Skip network in dry-run.
    if (runner.dryRun) {
      log.dry('wrangler pages project list / create $project (if needed)');
    } else {
      final list = await runner.runCapture(
        'wrangler',
        ['pages', 'project', 'list'],
        allowDryRun: false,
      );
      if (!list.stdout.contains(project)) {
        await runner.run('wrangler', [
          'pages',
          'project',
          'create',
          project,
          '--production-branch',
          config.cloudflare!.branch,
        ]);
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
    final staticDir = config.web.staticDir ??
        p.join(config.server, 'web', 'app');
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
