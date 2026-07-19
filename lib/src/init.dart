import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'database/detect.dart';
import 'detect_surface.dart';
import 'discover.dart';
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
  });

  final String root;
  final Log log;
  final bool yes;
  final String? configPath;

  Future<PodflyConfig> run() async {
    log.step('Init');
    final discovered = await discover(root);
    if (!discovered.isComplete) {
      log.warn(
          'Could not auto-detect server/flutter packages under $root');
    }

    final nameDefault = p.basename(root);
    final String name;
    final DeployMode mode;
    final String server;
    final String flutter;
    final String region;
    final DatabaseProvider dbProvider;
    final String smokePath;
    final String smokeMethod;
    late final bool webEnabled;

    if (yes || !isTty) {
      name = nameDefault;
      server = discovered.server ?? '${nameDefault}_server';
      flutter = discovered.flutter ?? '${nameDefault}_flutter';
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
      mode = webEnabled ? DeployMode.split : DeployMode.fly;

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
      log.detail('using defaults (--yes / non-TTY)');
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

      final defaultWeb = surface.deployWeb;
      final webIdx = await choose(
        surface.deployApiOnly
            ? 'What should podfly deploy? (looks like mobile/API-only)'
            : 'What should podfly deploy?',
        [
          'API + Flutter web (Pages and/or Fly static)',
          'API only (mobile or other non-web clients)',
        ],
        defaultIndex: defaultWeb ? 0 : 1,
      );
      webEnabled = webIdx == 0;

      final modeIdx = await choose(
        'API hosting mode',
        webEnabled
            ? [
                'split — Cloudflare Pages (UI) + Fly (API)',
                'fly — API + optional static web on Fly',
              ]
            : [
                'fly — API on Fly (recommended for mobile)',
                'fly — API on Fly',
              ],
        defaultIndex: 0,
      );
      // When web disabled, always fly mode (no Pages).
      mode = (!webEnabled || modeIdx == 1) ? DeployMode.fly : DeployMode.split;

      region = await prompt('Fly region', defaultValue: 'iad');

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

      final defaultDbIdx = switch (detection.need) {
        DatabaseNeed.none => 0,
        DatabaseNeed.required => 3, // neon — scale-to-zero friendly default
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
        [
          'none — stateless (cheapest, scale-to-zero friendly)',
          'sqlite — single machine + Fly volume',
          'fly_postgres — Fly managed Postgres (bills when API sleeps)',
          'neon — serverless Postgres (good with scale-to-zero)',
        ],
        defaultIndex: defaultDbIdx,
      );
      dbProvider = [
        DatabaseProvider.none,
        DatabaseProvider.sqlite,
        DatabaseProvider.flyPostgres,
        DatabaseProvider.neon,
      ][dbIdx];
      smokeMethod = await prompt('Smoke HTTP method', defaultValue: 'POST');
      smokePath = await prompt('Smoke API path', defaultValue: '/');
    }

    final flyApp = name;
    final apiUrl = 'https://$flyApp.fly.dev/';

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
        String? host;
        if (isTty && !yes) {
          provision = await confirm('Provision Neon project with neonctl?',
              defaultYes: false);
          if (!provision) {
            host = await prompt('Neon host (or leave blank)',
                defaultValue: '');
            if (host.isEmpty) host = null;
          }
        }
        database = DatabaseConfig(
          provider: DatabaseProvider.neon,
          neon: NeonConfig(
            provision: provision,
            projectName: name,
            host: host,
          ),
        );
    }

    final config = PodflyConfig(
      root: root,
      mode: mode,
      name: name,
      server: server,
      flutter: flutter,
      fly: FlyConfig(app: flyApp, region: region),
      cloudflare: mode == DeployMode.split && webEnabled
          ? CloudflareConfig(project: name)
          : null,
      database: database,
      web: WebConfig(
        enabled: webEnabled,
        apiUrl: apiUrl,
        // No need to patch bootstrap/headers when not deploying web.
        patchBootstrap: webEnabled,
        writeHeaders: webEnabled,
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
}
