import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'discover.dart';
import 'log.dart';
import 'tty.dart';

/// Interactive (or --yes defaults) project init → [PodflyConfig].
class Initer {
  Initer({
    required this.root,
    required this.log,
    this.yes = false,
  });

  final String root;
  final Log log;
  final bool yes;

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
    final String? smokePath;
    final String smokeMethod;

    if (yes || !isTty) {
      name = nameDefault;
      mode = DeployMode.split;
      server = discovered.server ?? '${nameDefault}_server';
      flutter = discovered.flutter ?? '${nameDefault}_flutter';
      region = 'iad';
      dbProvider = DatabaseProvider.none;
      smokePath = '/';
      smokeMethod = 'GET';
      log.detail('using defaults (--yes / non-TTY)');
    } else {
      name = await prompt('App name', defaultValue: nameDefault);
      final modeIdx = await choose(
        'Deploy mode',
        [
          'split — Cloudflare Pages (UI) + Fly (API)',
          'fly — everything on Fly',
        ],
      );
      mode = modeIdx == 1 ? DeployMode.fly : DeployMode.split;
      server = await prompt(
        'Server package path',
        defaultValue: discovered.server ?? '${name}_server',
      );
      flutter = await prompt(
        'Flutter package path',
        defaultValue: discovered.flutter ?? '${name}_flutter',
      );
      region = await prompt('Fly region', defaultValue: 'iad');
      final dbIdx = await choose(
        'Database',
        [
          'none — stateless (cheapest, scale-to-zero friendly)',
          'sqlite — single machine + Fly volume',
          'fly_postgres — Fly managed Postgres (bills when API sleeps)',
          'neon — serverless Postgres (good with scale-to-zero)',
        ],
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
      cloudflare: mode == DeployMode.split
          ? CloudflareConfig(project: name)
          : null,
      database: database,
      web: WebConfig(apiUrl: apiUrl),
      smoke: SmokeConfig(
        api: SmokeEndpoint(
          method: smokeMethod,
          path: smokePath,
          body: smokeMethod.toUpperCase() == 'POST' ? '{}' : null,
        ),
        web: SmokeEndpoint(path: '/'),
      ),
    );

    if (!await Directory(config.serverPath).exists()) {
      log.warn('server path does not exist yet: ${config.server}');
    }
    if (!await Directory(config.flutterPath).exists()) {
      log.warn('flutter path does not exist yet: ${config.flutter}');
    }

    await config.save();
    log.ok('wrote ${config.configPath}');
    return config;
  }
}
