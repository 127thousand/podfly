import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../database/ensure.dart';
import '../hosts/hosts.dart';
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

/// Orchestrates web build, Pages, and host adapters — no per-cloud switches.
class Deployer {
  Deployer({
    required this.config,
    required this.runner,
    required this.log,
  });

  final PodflyConfig config;
  final ProcessRunner runner;
  final Log log;

  HostDeployResult? lastApiResult;
  HostDeployResult? lastWebResult;

  Future<void> run(DeployOptions opts) async {
    ensureHostsRegistered();
    final adapter = HostRegistry.require(config.host);

    if (!adapter.canDeploy) {
      throw StateError(
        '${adapter.label} is not implemented in podfly yet '
        '(roadmap). Set host: fly or host: railway in podfly.yaml. '
        'See README provider table.',
      );
    }

    await _ensureServerDockerfile();
    await DatabaseEnsure(config: config, runner: runner, log: log).run();

    final doWeb = opts.doWeb && config.web.enabled;
    final doApi = opts.doApi;
    if (opts.doWeb && !config.web.enabled) {
      log.detail('web.enabled: false — skipping Flutter web build/deploy');
    }

    if (doWeb) {
      await WebBuilder(config: config, runner: runner, log: log).build();
    }

    final ctx = DeployContext(
      config: config,
      runner: runner,
      log: log,
      patchPublicHosts: (host) => patchProductionPublicHosts(
        config: config,
        runner: runner,
        log: log,
        host: host,
      ),
    );

    // Web first (Pages / Railway static / copy into image), then API.
    if (doWeb) {
      if (adapter.deploysWebNatively) {
        lastWebResult = await adapter.deployWeb(ctx);
      } else if (config.mode == DeployMode.split) {
        await _deployPages();
      } else if (adapter.supportsAllInOneWeb) {
        await _copyWebIntoServer();
      } else {
        log.warn('no web deploy path for ${adapter.label}');
      }
    }
    if (doApi) {
      lastApiResult = await adapter.deployApi(ctx);
    }

    if (opts.smoke && !runner.dryRun) {
      final smokeCfg = await _smokeConfig();
      final ok = await SmokeRunner(config: smokeCfg, log: log).run();
      if (!ok) throw StateError('smoke checks failed');
    }

    log.step('Done');
    if (doWeb) {
      if (lastWebResult?.displayUrl != null) {
        log.detail('UI:  ${lastWebResult!.displayUrl}');
      } else if (config.mode == DeployMode.split &&
          config.cloudflare != null) {
        log.detail(
            'UI:  https://${config.cloudflare!.project}.pages.dev');
      }
    }
    if (doApi) {
      final url = lastApiResult?.displayUrl ??
          lastApiResult?.publicHost ??
          adapter.publicApiBase(config) ??
          config.web.apiUrlNormalized;
      log.detail('API: $url');
    }
  }

  Future<PodflyConfig> _smokeConfig() async {
    PodflyConfig smokeCfg = config;
    if (await File(config.configPath).exists()) {
      try {
        smokeCfg = await PodflyConfig.load(config.configPath);
      } catch (_) {/* use in-memory */}
    }
    final host = lastApiResult?.publicHost;
    if (host != null && smokeCfg.web.apiUrlNormalized.contains('REPLACE')) {
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
          apiUrl: 'https://$host/',
          patchBootstrap: smokeCfg.web.patchBootstrap,
          writeHeaders: smokeCfg.web.writeHeaders,
          baseHref: smokeCfg.web.baseHref,
          staticDir: smokeCfg.web.staticDir,
        ),
        smoke: smokeCfg.smoke,
      );
    }
    return smokeCfg;
  }

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
    log.step('Copy web → $staticDir (all-in-one)');
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
