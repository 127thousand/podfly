import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'database/detect.dart';
import 'detect_surface.dart';
import 'discover.dart';
import 'fly_name.dart';
import 'hosts/hosts.dart';
import 'log.dart';
import 'tty.dart';

/// Interactive (or --yes defaults) project init → [PodflyConfig].
class Initer {
  Initer({
    required this.root,
    required this.log,
    this.yes = false,
    /// When set, save to this path instead of `<root>/podfly.yaml`.
    this.configPath,
    /// Preferred API host (e.g. from `podfly deploy --host railway`).
    this.preferredHost,
  });

  final String root;
  final Log log;
  final bool yes;
  final String? configPath;
  final AppHost? preferredHost;

  Future<PodflyConfig> run() async {
    ensureHostsRegistered();
    log.step('Init');
    final discovered = await discover(root);
    if (!discovered.isComplete) {
      log.warn(
          'Could not auto-detect server/flutter packages under $root');
    }

    final nameDefault = p.basename(root);
    final String name;
    late final AppHost host;
    final DeployMode mode;
    final String server;
    final String flutter;
    final String region;
    final DatabaseProvider dbProvider;
    final String smokePath;
    final String smokeMethod;
    late final bool webEnabled;
    var webHost = StaticWebHost.cloudflare;

    // Host menu from registry (✅ = canDeploy)
    final hostAdapters = HostRegistry.all;
    String hostMenuLabel(HostAdapter a) =>
        '${a.canDeploy ? '✅' : '🗺️'} ${a.label}'
        '${a.canDeploy ? '' : ' (planned — doctor only for now)'}';

    if (yes || !isTty) {
      name = nameDefault;
      server = discovered.server ?? '${nameDefault}_server';
      flutter = discovered.flutter ?? '${nameDefault}_flutter';
      host = preferredHost ?? AppHost.fly;
      region = 'iad';

      final surface = await detectClientSurface(
        serverPath: p.join(root, server),
        flutterPath: p.join(root, flutter),
      );
      log.detail('Client surface: ${surface.surface.name}');
      for (final r in surface.reasons.take(5)) {
        log.detail('  · $r');
      }
      for (final w in surface.warnings.take(3)) {
        log.warn(w);
      }
      webEnabled = surface.deployWeb;
      // API-only apps don't need Cloudflare Pages.
      mode = webEnabled ? DeployMode.split : DeployMode.monolith;

      final detection = await detectDatabaseNeed(
        p.join(root, server),
        flutterPath: p.join(root, flutter),
      );
      log.detail('DB detection: ${detection.need.name}');
      for (final r in detection.reasons.take(5)) {
        log.detail('  · $r');
      }
      for (final w in detection.warnings.take(4)) {
        log.warn(w);
      }
      dbProvider = detection.need == DatabaseNeed.required
          ? DatabaseProvider.neon
          : DatabaseProvider.none;
      smokePath = '/';
      smokeMethod = 'GET';
      log.detail('using defaults (--yes / non-TTY); host: ${host.yamlName}');
    } else {
      name = await prompt('App name', defaultValue: nameDefault);
      server = await prompt(
        'Server package path',
        defaultValue: discovered.server ?? '${name}_server',
      );
      flutter = await prompt(
        'Flutter package path',
        defaultValue: discovered.flutter ?? '${name}_flutter',
      );

      final hostIdx = await choose(
        'Where should the Serverpod API run?',
        hostAdapters.map(hostMenuLabel).toList(),
        defaultIndex: 0,
      );
      host = hostAdapters[hostIdx].appHost;
      final hostAdapter = HostRegistry.require(host);
      if (!hostAdapter.canDeploy) {
        log.warn(
            '${hostAdapter.label} is planned — you can save config and install its CLI, '
            'but deploy only works for hosts marked ✅ today.');
      }

      final surface = await detectClientSurface(
        serverPath: p.join(root, server),
        flutterPath: p.join(root, flutter),
      );
      log.detail('Client surface: ${surface.surface.name}');
      for (final r in surface.reasons.take(6)) {
        log.detail('  · $r');
      }
      for (final w in surface.warnings.take(4)) {
        log.warn(w);
      }

      // One clear topology menu (avoids "monolith" with web disabled).
      if (hostAdapter.supportsAllInOneWeb || hostAdapter.deploysWebNatively) {
        final topoDefault = surface.deployWeb ? 0 : 2;
        final topoIdx = await choose(
          surface.deployApiOnly
              ? 'Deploy topology (project looks mobile/API-first)'
              : 'Deploy topology',
          [
            '🧱 Monolith — Flutter web + API together on ${hostAdapter.label} (one URL)',
            '🔀 Split — Flutter web on a CDN + API on ${hostAdapter.label}',
            '📱 API only — no Flutter web (mobile / other clients)',
          ],
          defaultIndex: topoDefault.clamp(0, 2),
        );
        switch (topoIdx) {
          case 0: // monolith
            webEnabled = true;
            mode = DeployMode.monolith;
          case 1: // split
            webEnabled = true;
            mode = DeployMode.split;
          default: // api only
            webEnabled = false;
            mode = DeployMode.monolith; // API-only still uses single process
        }
      } else {
        // Host cannot embed web — split CDN or API only.
        final webIdx = await choose(
          'What should podfly deploy?',
          [
            '🔀 API + Flutter web on a static CDN',
            '📱 API only (no Flutter web)',
          ],
          defaultIndex: surface.deployWeb ? 0 : 1,
        );
        webEnabled = webIdx == 0;
        mode = webEnabled ? DeployMode.split : DeployMode.monolith;
      }

      final needsStaticCdn = mode == DeployMode.split &&
          webEnabled &&
          !hostAdapter.deploysWebNatively;
      if (needsStaticCdn) {
        final cdnIdx = await choose(
          'Static CDN for Flutter web',
          [
            '🟠 Cloudflare Pages',
            '▲  Vercel',
            '🟢 Netlify',
            '🐙 GitHub Pages',
          ],
          defaultIndex: 0,
        );
        webHost = switch (cdnIdx) {
          1 => StaticWebHost.vercel,
          2 => StaticWebHost.netlify,
          3 => StaticWebHost.githubPages,
          _ => StaticWebHost.cloudflare,
        };
      }

      region = host == AppHost.fly
          ? await prompt('Fly region', defaultValue: 'iad')
          : 'iad';

      final detection = await detectDatabaseNeed(
        p.join(root, server),
        flutterPath: p.join(root, flutter),
      );
      log.detail('DB detection: ${detection.need.name}');
      for (final r in detection.reasons.take(6)) {
        log.detail('  · $r');
      }
      for (final w in detection.warnings.take(5)) {
        log.warn(w);
      }

      final dbProviders = hostAdapter.supportedDatabases;
      final dbLabels = dbProviders.map(_dbMenuLabel).toList();
      final preferredNeon = dbProviders.indexOf(DatabaseProvider.neon);
      final defaultDbIdx = switch (detection.need) {
        DatabaseNeed.none => 0,
        DatabaseNeed.required =>
          preferredNeon >= 0 ? preferredNeon : 0,
        DatabaseNeed.unknown => 0,
      };
      final dbIdx = await choose(
        detection.need == DatabaseNeed.required
            ? 'Database (app uses tables/auth — DB recommended)'
            : detection.need == DatabaseNeed.none
                ? detection.authScaffolded
                    ? 'Database (looks stateless; template auth unused — none OK)'
                    : 'Database (looks stateless — none recommended)'
                : 'Database',
        dbLabels,
        defaultIndex: defaultDbIdx.clamp(0, dbLabels.length - 1),
      );
      dbProvider = dbProviders[dbIdx];
      smokeMethod = await prompt('Smoke HTTP method', defaultValue: 'POST');
      smokePath = await prompt('Smoke API path', defaultValue: '/');
    }

    // DNS-friendly names prefer hyphens.
    final flyApp = sanitizeFlyAppName(name);
    final railwayProject = sanitizeFlyAppName(name);
    final apiUrl = HostRegistry.require(host).defaultApiUrl(
      name: name,
      sanitizedName: flyApp,
    );

    DatabaseConfig database;
    switch (dbProvider) {
      case DatabaseProvider.none:
        database = DatabaseConfig(provider: DatabaseProvider.none);
      case DatabaseProvider.sqlite:
        database = DatabaseConfig(
          provider: DatabaseProvider.sqlite,
          sqlite: SqliteConfig(
            volumeName: '${flyApp}_data',
          ),
        );
      case DatabaseProvider.flyPostgres:
        database = DatabaseConfig(
          provider: DatabaseProvider.flyPostgres,
          flyPostgres: FlyPostgresConfig(app: '$flyApp-db'),
        );
      case DatabaseProvider.neon:
        var provision = false;
        String? neonHost;
        if (isTty && !yes) {
          provision = await confirm('Provision Neon project with neonctl?',
              defaultYes: false);
          if (!provision) {
            neonHost = await prompt('Neon host (or leave blank)',
                defaultValue: '');
            if (neonHost.isEmpty) neonHost = null;
          }
        }
        database = DatabaseConfig(
          provider: DatabaseProvider.neon,
          neon: NeonConfig(
            provision: provision,
            projectName: name,
            host: neonHost,
          ),
        );
      case DatabaseProvider.supabase:
        var provision = true;
        if (isTty && !yes) {
          provision = await confirm(
            'Provision Supabase project with supabase CLI?',
            defaultYes: true,
          );
        }
        database = DatabaseConfig(
          provider: DatabaseProvider.supabase,
          supabase: SupabaseConfig(
            provision: provision,
            projectName: '$flyApp-db',
          ),
        );
      case DatabaseProvider.railwayPostgres:
        database = DatabaseConfig(
          provider: DatabaseProvider.railwayPostgres,
          railwayPostgres: RailwayPostgresConfig(),
        );
      case DatabaseProvider.digitalOceanPostgres:
        database = DatabaseConfig(
          provider: DatabaseProvider.digitalOceanPostgres,
          digitalOceanPostgres: DigitalOceanPostgresConfig(
            clusterName: '$flyApp-db',
          ),
        );
      case DatabaseProvider.renderPostgres:
        database = DatabaseConfig(
          provider: DatabaseProvider.renderPostgres,
          renderPostgres: RenderPostgresConfig(name: '$flyApp-db'),
        );
    }

    final splitStatic = mode == DeployMode.split &&
        webEnabled &&
        host != AppHost.railway &&
        host != AppHost.digitalOcean &&
        host != AppHost.render &&
        host != AppHost.cloudRun &&
        host != AppHost.aws &&
        host != AppHost.awsEcs &&
        host != AppHost.azure &&
        host != AppHost.hetzner;

    final config = PodflyConfig(
      root: root,
      host: host,
      webHost: splitStatic ? webHost : StaticWebHost.cloudflare,
      mode: mode,
      name: name,
      server: server,
      flutter: flutter,
      fly: FlyConfig(app: flyApp, region: region),
      railway: host == AppHost.railway
          ? RailwayConfig(project: railwayProject, service: 'api')
          : null,
      digitalOcean: host == AppHost.digitalOcean
          ? DigitalOceanConfig(app: flyApp)
          : null,
      render: host == AppHost.render
          ? RenderConfig(service: flyApp)
          : null,
      cloudRun: host == AppHost.cloudRun
          ? CloudRunConfig(service: flyApp)
          : null,
      aws: host == AppHost.aws ? AwsConfig(service: flyApp) : null,
      awsEcs: host == AppHost.awsEcs ? AwsEcsConfig(service: flyApp) : null,
      azure: host == AppHost.azure ? AzureConfig(app: flyApp) : null,
      hetzner: host == AppHost.hetzner
          ? HetznerConfig(serverName: flyApp)
          : null,
      cloudflare: splitStatic && webHost == StaticWebHost.cloudflare
          ? CloudflareConfig(project: flyApp)
          : null,
      vercel: splitStatic && webHost == StaticWebHost.vercel
          ? VercelConfig(project: flyApp)
          : null,
      netlify: splitStatic && webHost == StaticWebHost.netlify
          ? NetlifyConfig(site: flyApp)
          : null,
      githubPages: splitStatic && webHost == StaticWebHost.githubPages
          ? GitHubPagesConfig(repo: flyApp)
          : null,
      database: database,
      // Mobile-first monorepos get Codemagic scaffolding (codemagic.yaml).
      mobile: !webEnabled
          ? MobileConfig(
              provider: MobileProvider.codemagic,
              codemagic: CodemagicConfig(),
            )
          : MobileConfig(),
      web: WebConfig(
        enabled: webEnabled,
        apiUrl: apiUrl,
        // CDN split needs bootstrap/headers; monolith serves from the API host.
        patchBootstrap: webEnabled,
        writeHeaders: webEnabled && mode == DeployMode.split,
      ),
      smoke: SmokeConfig(
        api: SmokeEndpoint(
          method: smokeMethod,
          path: smokePath,
          body: smokeMethod.toUpperCase() == 'POST' ? '{}' : null,
        ),
        web: webEnabled ? SmokeEndpoint(path: '/') : null,
      ),
    );

    if (!await Directory(config.serverPath).exists()) {
      log.warn('server path does not exist yet: ${config.server}');
    }
    if (!await Directory(config.flutterPath).exists()) {
      log.warn('flutter path does not exist yet: ${config.flutter}');
    }

    final outPath = configPath ?? config.configPath;
    await config.save(outPath);
    log.ok('wrote $outPath');
    return config;
  }

  static String _dbMenuLabel(DatabaseProvider p) => switch (p) {
        DatabaseProvider.none =>
          'none — stateless (cheapest, scale-to-zero friendly)',
        DatabaseProvider.sqlite =>
          'sqlite — single machine + Fly volume',
        DatabaseProvider.flyPostgres =>
          'fly_postgres — Fly managed Postgres (bills when API sleeps)',
        DatabaseProvider.neon =>
          'neon — serverless Postgres (good with scale-to-zero)',
        DatabaseProvider.supabase =>
          'supabase — managed Postgres (Supabase project / CLI)',
        DatabaseProvider.railwayPostgres =>
          'railway_postgres — Postgres plugin on Railway project',
        DatabaseProvider.digitalOceanPostgres =>
          'digitalocean_postgres — Managed Postgres (DBaaS) for App Platform',
        DatabaseProvider.renderPostgres =>
          'render_postgres — Render managed Postgres (free plan expires ~30d)',
      };
}
