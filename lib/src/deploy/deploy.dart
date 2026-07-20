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

    // Working config may pick up API public host before Flutter web build.
    var cfg = config;

    final ctx = DeployContext(
      config: cfg,
      runner: runner,
      log: log,
      patchPublicHosts: (host) => patchProductionPublicHosts(
        config: cfg,
        runner: runner,
        log: log,
        host: host,
      ),
    );

    // For split Railway web, resolve API hostname first (SERVER_URL dart-define).
    if (opts.doWeb && cfg.web.enabled && adapter.deploysWebNatively) {
      final apiHost = await adapter.ensureApiPublicHost(ctx);
      if (apiHost != null) {
        cfg = _withApiUrl(cfg, 'https://$apiHost/');
      }
    }

    await _ensureServerDockerfile();

    // API app/project must exist before DB attach (Fly postgres attach -a …).
    final ensureCtx = DeployContext(
      config: cfg,
      runner: runner,
      log: log,
      patchPublicHosts: (host) => patchProductionPublicHosts(
        config: cfg,
        runner: runner,
        log: log,
        host: host,
      ),
    );
    final resolvedApp = await adapter.ensureApiApp(ensureCtx);
    if (resolvedApp != null &&
        resolvedApp != cfg.fly.app &&
        await File(cfg.configPath).exists()) {
      try {
        cfg = await PodflyConfig.load(cfg.configPath);
      } catch (_) {
        // keep in-memory cfg if yaml reload fails
      }
    }

    await DatabaseEnsure(config: cfg, runner: runner, log: log).run();

    final doWeb = opts.doWeb && cfg.web.enabled;
    final doApi = opts.doApi;
    if (opts.doWeb && !cfg.web.enabled) {
      log.detail('web.enabled: false — skipping Flutter web build/deploy');
    }

    final buildCtx = DeployContext(
      config: cfg,
      runner: runner,
      log: log,
      patchPublicHosts: (host) => patchProductionPublicHosts(
        config: cfg,
        runner: runner,
        log: log,
        host: host,
      ),
    );

    if (doWeb) {
      await WebBuilder(config: cfg, runner: runner, log: log).build();
    }

    // Separate web service (Railway) or Pages / all-in-one copy — not siamese.
    if (doWeb) {
      if (adapter.deploysWebNatively) {
        lastWebResult = await adapter.deployWeb(buildCtx);
      } else if (cfg.mode == DeployMode.split) {
        await _deployPages();
      } else if (adapter.supportsAllInOneWeb) {
        await _copyWebIntoServer();
      } else {
        log.warn('no web deploy path for ${adapter.label}');
      }
    }
    if (doApi) {
      lastApiResult = await adapter.deployApi(buildCtx);
    }

    if (opts.smoke && !runner.dryRun) {
      final smokeCfg = await _smokeConfig(cfg);
      final ok = await SmokeRunner(config: smokeCfg, log: log).run();
      if (!ok) throw StateError('smoke checks failed');
    }

    log.step('Done');
    if (doWeb) {
      if (lastWebResult?.displayUrl != null) {
        log.detail('UI:  ${lastWebResult!.displayUrl}');
      } else if (cfg.mode == DeployMode.split && cfg.cloudflare != null) {
        log.detail(
            'UI:  https://${cfg.cloudflare!.project}.pages.dev');
      }
    }
    if (doApi) {
      final url = lastApiResult?.displayUrl ??
          lastApiResult?.publicHost ??
          adapter.publicApiBase(cfg) ??
          cfg.web.apiUrlNormalized;
      log.detail('API: $url');
    }
  }

  PodflyConfig _withApiUrl(PodflyConfig c, String apiUrl) {
    return PodflyConfig(
      root: c.root,
      host: c.host,
      mode: c.mode,
      name: c.name,
      server: c.server,
      flutter: c.flutter,
      fly: c.fly,
      railway: c.railway,
      cloudflare: c.cloudflare,
      database: c.database,
      web: WebConfig(
        enabled: c.web.enabled,
        serverUrlDefine: c.web.serverUrlDefine,
        apiUrl: apiUrl,
        patchBootstrap: c.web.patchBootstrap,
        writeHeaders: c.web.writeHeaders,
        baseHref: c.web.baseHref,
        staticDir: c.web.staticDir,
      ),
      smoke: c.smoke,
    );
  }

  Future<PodflyConfig> _smokeConfig(PodflyConfig fallback) async {
    PodflyConfig smokeCfg = fallback;
    if (await File(fallback.configPath).exists()) {
      try {
        smokeCfg = await PodflyConfig.load(fallback.configPath);
      } catch (_) {/* use in-memory */}
    }
    final host = lastApiResult?.publicHost;
    if (host != null &&
        (smokeCfg.web.apiUrlNormalized.contains('REPLACE') ||
            smokeCfg.web.apiUrlNormalized.contains('fly.dev'))) {
      // Prefer live Railway API host for smoke after railway deploy.
      if (fallback.host == AppHost.railway ||
          smokeCfg.web.apiUrlNormalized.contains('REPLACE')) {
        smokeCfg = _withApiUrl(smokeCfg, 'https://$host/');
      }
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
