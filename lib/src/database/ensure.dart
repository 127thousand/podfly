import 'dart:io';

import '../config.dart';
import '../hosts/hosts.dart';
import '../log.dart';
import '../process_runner.dart';
import 'production_yaml.dart';

/// Provision / ensure DB resources then patch production.yaml.
class DatabaseEnsure {
  DatabaseEnsure({
    required this.config,
    required this.runner,
    required this.log,
  });

  final PodflyConfig config;
  final ProcessRunner runner;
  final Log log;

  Future<void> run() async {
    log.step('Database (${config.database.provider.name})');

    switch (config.database.provider) {
      case DatabaseProvider.none:
        log.detail('stateless — no external DB');
      case DatabaseProvider.sqlite:
        await _sqliteVolume();
      case DatabaseProvider.flyPostgres:
        await _flyPostgres();
      case DatabaseProvider.neon:
        await _neon();
      case DatabaseProvider.railwayPostgres:
        await _railwayPostgres();
    }

    if (!runner.dryRun) {
      await ProductionYamlPatcher(config: config, log: log).apply();
    } else {
      log.dry('patch ${config.server}/config/production.yaml');
    }
  }

  Future<String> _flyBin() async {
    final fly = await runner.resolve('fly', ['flyctl']);
    if (fly == null) throw StateError('fly not found');
    return fly;
  }

  Future<void> _sqliteVolume() async {
    ensureHostsRegistered();
    if (config.host != AppHost.fly) {
      log.warn(
          'sqlite volume automation is Fly-only; on ${config.host.label} '
          'mount storage yourself or use neon');
      return;
    }
    final s = config.database.sqlite;
    if (s == null || !s.volumeCreate) {
      log.detail('sqlite volume create skipped');
      return;
    }
    final name = s.volumeName ?? '${config.fly.app}_data';
    final fly = await _flyBin();
    log.detail(
        'ensure volume $name (${s.volumeSizeGb}GB) region ${config.fly.region}');
    // List volumes — if missing, create
    final list = await runner.runCapture(
      fly,
      ['volumes', 'list', '-a', config.fly.app, '--json'],
      allowDryRun: true,
    );
    if (!runner.dryRun && list.ok && list.stdout.contains(name)) {
      log.ok('volume $name exists');
      return;
    }
    await runner.run(fly, [
      'volumes',
      'create',
      name,
      '--size',
      '${s.volumeSizeGb}',
      '--region',
      config.fly.region,
      '-a',
      config.fly.app,
      '-y',
    ]);
    log.warn(
        'Add to fly.toml:\n[[mounts]]\n  source = "$name"\n  destination = "${s.volumeDest}"');
  }

  Future<void> _flyPostgres() async {
    final pg = config.database.flyPostgres;
    if (pg == null) return;
    final fly = await _flyBin();
    if (pg.create) {
      log.detail('ensure postgres app ${pg.app}');
      // create is interactive sometimes — use --vm-size shared-cpu-1x if available
      await runner.run(fly, [
        'postgres',
        'create',
        '--name',
        pg.app,
        '--region',
        config.fly.region,
        '--vm-size',
        'shared-cpu-1x',
        '--volume-size',
        '1',
        '--initial-cluster-size',
        '1',
      ]);
    }
    log.detail('attach ${pg.app} → ${config.fly.app}');
    await runner.run(fly, [
      'postgres',
      'attach',
      pg.app,
      '-a',
      config.fly.app,
    ]);
  }

  Future<void> _neon() async {
    final n = config.database.neon;
    if (n == null) return;
    if (n.provision) {
      final neon = await runner.resolve('neonctl', ['neon']);
      if (neon == null) throw StateError('neonctl required for provision');
      final project = n.projectName ?? config.name;
      log.detail('neon provision project $project');
      await runner.run(neon, [
        'projects',
        'create',
        '--name',
        project,
        '--region-id',
        n.region,
      ]);
      log.warn(_neonSecretHint(n.connectionStringSecret));
    } else {
      log.detail(_neonSecretHint(n.connectionStringSecret));
    }
  }

  String _neonSecretHint(String secret) {
    ensureHostsRegistered();
    final adapter = HostRegistry.require(config.host);
    return 'Neon: ${adapter.secretSetHint(secret, config)}';
  }

  Future<void> _railwayPostgres() async {
    if (config.host != AppHost.railway) {
      throw StateError(
        'database.provider railway_postgres requires host: railway',
      );
    }
    final pg = config.database.railwayPostgres ?? RailwayPostgresConfig();
    final railway = await runner.resolve('railway');
    if (railway == null) throw StateError('railway CLI not found');

    if (runner.dryRun) {
      log.dry(
          '$railway add --database postgres  (service ${pg.service}) + wire ${pg.connectionStringSecret}');
      return;
    }

    // Project must exist before plugins can be added.
    await _ensureRailwayProjectLinked(railway);

    final list = await runner.runCapture(
      railway,
      ['service', 'list', '--json'],
      workingDirectory: config.root,
      allowDryRun: false,
    );
    final out = list.stdout + list.stderr;
    final exists = out.toLowerCase().contains(pg.service.toLowerCase()) ||
        out.toLowerCase().contains('postgres');

    if (!exists && pg.create) {
      log.detail('adding Railway Postgres (${pg.service})');
      final add = await runner.run(
        railway,
        ['add', '--database', 'postgres', '--json'],
        workingDirectory: config.root,
        allowDryRun: false,
      );
      if (!add.ok) {
        throw StateError(
            'railway add --database postgres failed (${add.exitCode})');
      }
      log.ok('created Railway Postgres');
    } else {
      log.detail('Railway Postgres service present (or create: false)');
    }

    // Discover service name if template renamed it
    final list2 = await runner.runCapture(
      railway,
      ['service', 'list', '--json'],
      workingDirectory: config.root,
      allowDryRun: false,
    );
    final pgName = _guessPostgresServiceName(list2.stdout) ?? pg.service;
    final api = config.railway?.service ?? 'api';

    // Reference plugin vars onto API service (Railway variable references).
    final ref = '\${{$pgName.DATABASE_URL}}';
    log.detail('wire $api ${pg.connectionStringSecret} ← $pgName.DATABASE_URL');
    await runner.run(
      railway,
      [
        'variable',
        'set',
        '${pg.connectionStringSecret}=$ref',
        '-s',
        api,
        '--skip-deploys',
      ],
      workingDirectory: config.root,
      allowDryRun: false,
    );

    // Fetch private host / password for Serverpod config files when available.
    final vars = await runner.runCapture(
      railway,
      ['variable', 'list', '-s', pgName, '--json'],
      workingDirectory: config.root,
      allowDryRun: false,
    );
    final creds = _parseRailwayPgVars(vars.stdout);
    if (creds != null) {
      // Sidecar for ProductionYamlPatcher (same ensure step).
      final sidecar = File(
        '${config.serverPath}/config/.podfly_railway_pg.json',
      );
      await sidecar.writeAsString(
        '{"host":"${creds.host}","port":"${creds.port}","name":"${creds.database}",'
        '"user":"${creds.user}","password":"${_escapeJson(creds.password)}",'
        '"requireSsl":"false"}',
      );
      log.ok('Railway Postgres credentials for production.yaml patch');
    } else {
      log.warn(
          'could not parse Postgres vars — set production database manually');
    }
  }

  String? _guessPostgresServiceName(String json) {
    // Prefer exact "Postgres"
    if (RegExp(r'"name"\s*:\s*"Postgres"').hasMatch(json)) return 'Postgres';
    final m = RegExp(r'"name"\s*:\s*"([^"]*[Pp]ostgres[^"]*)"').firstMatch(json);
    return m?.group(1);
  }

  ({String host, String port, String database, String user, String password})?
      _parseRailwayPgVars(String json) {
    String? pick(String key) {
      final m = RegExp('"$key"\\s*:\\s*"([^"]*)"').firstMatch(json);
      return m?.group(1);
    }

    // Railway JSON may nest; also try plain KV-ish dumps
    final host = pick('PGHOST') ??
        pick('POSTGRES_HOST') ??
        pick('host') ??
        _extractFromDatabaseUrl(json, 'host');
    final port = pick('PGPORT') ?? pick('port') ?? '5432';
    final database =
        pick('PGDATABASE') ?? pick('POSTGRES_DB') ?? pick('name') ?? 'railway';
    final user =
        pick('PGUSER') ?? pick('POSTGRES_USER') ?? pick('user') ?? 'postgres';
    final password = pick('PGPASSWORD') ??
        pick('POSTGRES_PASSWORD') ??
        pick('password') ??
        _extractFromDatabaseUrl(json, 'password');

    if (host == null || password == null) return null;
    return (
      host: host,
      port: port,
      database: database,
      user: user,
      password: password,
    );
  }

  String? _extractFromDatabaseUrl(String text, String field) {
    final m = RegExp(
      r'postgres(?:ql)?://([^:]+):([^@]+)@([^:/]+):(\d+)/([^?"\s]+)',
    ).firstMatch(text);
    if (m == null) return null;
    return switch (field) {
      'user' => m.group(1),
      'password' => m.group(2),
      'host' => m.group(3),
      'port' => m.group(4),
      'name' => m.group(5),
      _ => null,
    };
  }

  String _escapeJson(String s) =>
      s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

  Future<void> _ensureRailwayProjectLinked(String railway) async {
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
    final rcfg = config.railway;
    if (rcfg?.projectId != null && rcfg!.projectId!.isNotEmpty) {
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
        throw StateError('railway link failed for ${rcfg.projectId}');
      }
      return;
    }
    final name = rcfg?.project ?? config.name.replaceAll('_', '-');
    log.detail('creating Railway project $name (needed for Postgres)');
    final init = await runner.runCapture(
      railway,
      ['init', '--name', name, '--json'],
      workingDirectory: config.root,
      allowDryRun: false,
    );
    if (!init.ok) {
      throw StateError(
          'railway init failed (${init.exitCode}): ${init.stderr}');
    }
    log.ok('created Railway project $name');
  }
}
