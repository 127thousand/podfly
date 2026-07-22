import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../database/ensure.dart';
import '../redis/ensure.dart';
import '../hosts/hosts.dart';
import '../log.dart';
import '../process_runner.dart';
import '../smoke.dart';
import '../templates.dart';
import '../web/build.dart';
import '../web/static_web.dart';

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
    this.nonInteractive = false,
  });

  final PodflyConfig config;
  final ProcessRunner runner;
  final Log log;
  /// From `podfly deploy --yes` — hosts skip interactive prompts.
  final bool nonInteractive;

  HostDeployResult? lastApiResult;
  HostDeployResult? lastWebResult;

  DeployContext _ctx(PodflyConfig cfg) => DeployContext(
        config: cfg,
        runner: runner,
        log: log,
        nonInteractive: nonInteractive,
        patchPublicHosts: (host, {scheme = 'https', publicPort}) =>
            patchProductionPublicHosts(
          config: cfg,
          runner: runner,
          log: log,
          host: host,
          scheme: scheme,
          publicPort: publicPort,
        ),
      );

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

    final ctx = _ctx(cfg);

    // For split Railway web, resolve API hostname first (SERVER_URL dart-define).
    if (opts.doWeb && cfg.web.enabled && adapter.deploysWebNatively) {
      final apiHost = await adapter.ensureApiPublicHost(ctx);
      if (apiHost != null) {
        cfg = _withApiUrl(cfg, 'https://$apiHost/');
      }
    }

    await _ensureServerDockerfile();

    // API app/project must exist before DB attach (Fly postgres attach -a …).
    final ensureCtx = _ctx(cfg);
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

    // DB ensure may write cluster_id / credentials into podfly.yaml + sidecars.
    if (await File(cfg.configPath).exists()) {
      try {
        cfg = await PodflyConfig.load(cfg.configPath);
      } catch (_) {/* keep in-memory */}
    }

    await RedisEnsure(config: cfg, runner: runner, log: log).run();
    if (await File(cfg.configPath).exists()) {
      try {
        cfg = await PodflyConfig.load(cfg.configPath);
      } catch (_) {/* keep in-memory */}
    }

    final doWeb = opts.doWeb && cfg.web.enabled;
    final doApi = opts.doApi;
    if (opts.doWeb && !cfg.web.enabled) {
      log.detail('web.enabled: false — skipping Flutter web build/deploy');
    }

    final buildCtx = _ctx(cfg);

    // When the host deploys web natively (Railway / DO), ship API first so
    // Flutter can bake the live API URL into SERVER_URL.
    final nativeWeb = adapter.deploysWebNatively;

    if (doApi && nativeWeb) {
      lastApiResult = await adapter.deployApi(buildCtx);
      final live = lastApiResult?.displayUrl ?? lastApiResult?.publicHost;
      if (live != null) {
        final url = live.startsWith('http')
            ? (live.endsWith('/') ? live : '$live/')
            : 'https://$live/';
        cfg = _withApiUrl(cfg, url);
      }
    }

    if (doWeb) {
      cfg = _withGitHubPagesBaseHref(cfg);
      await WebBuilder(config: cfg, runner: runner, log: log).build();
    }

    // Separate web service (Railway / DO) or static CDN / all-in-one copy.
    if (doWeb) {
      if (nativeWeb) {
        lastWebResult = await adapter.deployWeb(_ctx(cfg));
      } else if (cfg.mode == DeployMode.split && cfg.usesStaticWebHost) {
        final staticResult = await StaticWebDeployer(
          config: cfg,
          runner: runner,
          log: log,
        ).deploy();
        lastWebResult = HostDeployResult(
          publicHost: staticResult.publicHost,
          displayUrl: staticResult.displayUrl,
        );
        // Reload if vercel/netlify public_host was persisted
        if (await File(cfg.configPath).exists()) {
          try {
            cfg = await PodflyConfig.load(cfg.configPath);
          } catch (_) {/* keep */}
        }
      } else if (adapter.supportsAllInOneWeb) {
        await _copyWebIntoServer();
      } else {
        log.warn('no web deploy path for ${adapter.label}');
      }
    }
    if (doApi && !nativeWeb) {
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
      } else if (cfg.mode == DeployMode.split && cfg.usesStaticWebHost) {
        if (cfg.webHost == StaticWebHost.vercel && cfg.vercel != null) {
          final h = cfg.vercel!.publicHost ?? '${cfg.vercel!.project}.vercel.app';
          log.detail('UI:  https://$h');
        } else if (cfg.webHost == StaticWebHost.netlify && cfg.netlify != null) {
          final h =
              cfg.netlify!.publicHost ?? '${cfg.netlify!.site}.netlify.app';
          log.detail('UI:  https://$h');
        } else if (cfg.webHost == StaticWebHost.githubPages &&
            cfg.githubPages != null) {
          final g = cfg.githubPages!;
          final h = g.publicHost ??
              (g.owner != null ? g.defaultPublicHost(g.owner!) : g.repo);
          log.detail('UI:  https://$h');
        } else if (cfg.cloudflare != null) {
          log.detail(
              'UI:  https://${cfg.cloudflare!.project}.pages.dev');
        }
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
      webHost: c.webHost,
      mode: c.mode,
      name: c.name,
      server: c.server,
      flutter: c.flutter,
      fly: c.fly,
      railway: c.railway,
      digitalOcean: c.digitalOcean,
      render: c.render,
      cloudRun: c.cloudRun,
      aws: c.aws,
      awsEcs: c.awsEcs,
      azure: c.azure,
      hetzner: c.hetzner,
      cloudflare: c.cloudflare,
      vercel: c.vercel,
      netlify: c.netlify,
      githubPages: c.githubPages,
      database: c.database,
      redis: c.redis,
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

  /// Project Pages need `--base-href /repo/` so assets resolve under
  /// `https://owner.github.io/repo/`.
  PodflyConfig _withGitHubPagesBaseHref(PodflyConfig c) {
    if (c.webHost != StaticWebHost.githubPages) return c;
    final g = c.githubPages;
    if (g == null) return c;
    final current = c.web.baseHref;
    if (current.isNotEmpty && current != '/') return c;
    final owner = g.owner;
    // Without owner we still use /repo/ (user sites are rare for demos).
    final href = owner != null
        ? g.suggestedBaseHref(owner)
        : (g.repo.endsWith('.github.io') ? '/' : '/${g.repo}/');
    if (href == current) return c;
    log.detail('github_pages: using base_href $href');
    return PodflyConfig(
      root: c.root,
      host: c.host,
      webHost: c.webHost,
      mode: c.mode,
      name: c.name,
      server: c.server,
      flutter: c.flutter,
      fly: c.fly,
      railway: c.railway,
      digitalOcean: c.digitalOcean,
      render: c.render,
      cloudRun: c.cloudRun,
      aws: c.aws,
      awsEcs: c.awsEcs,
      azure: c.azure,
      hetzner: c.hetzner,
      cloudflare: c.cloudflare,
      vercel: c.vercel,
      netlify: c.netlify,
      githubPages: c.githubPages,
      database: c.database,
      redis: c.redis,
      web: WebConfig(
        enabled: c.web.enabled,
        serverUrlDefine: c.web.serverUrlDefine,
        apiUrl: c.web.apiUrl,
        patchBootstrap: c.web.patchBootstrap,
        writeHeaders: c.web.writeHeaders,
        baseHref: href,
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
    // Prefer full display URL (Hetzner uses http://IP:port).
    final display = lastApiResult?.displayUrl;
    if (display != null && display.isNotEmpty) {
      final url = display.startsWith('http')
          ? (display.endsWith('/') ? display : '$display/')
          : 'https://$display/';
      return _withApiUrl(smokeCfg, url);
    }
    final host = lastApiResult?.publicHost;
    if (host != null &&
        (fallback.host == AppHost.railway ||
            fallback.host == AppHost.digitalOcean ||
            fallback.host == AppHost.render ||
            fallback.host == AppHost.cloudRun ||
            fallback.host == AppHost.aws ||
            fallback.host == AppHost.awsEcs ||
            fallback.host == AppHost.azure ||
            fallback.host == AppHost.hetzner ||
            smokeCfg.web.apiUrlNormalized.contains('REPLACE'))) {
      final base = fallback.host.adapter.publicApiBase(smokeCfg);
      if (base != null && base.isNotEmpty) {
        return _withApiUrl(smokeCfg, base);
      }
      smokeCfg = _withApiUrl(smokeCfg, 'https://$host/');
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
