import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../hosts/hosts.dart';
import '../log.dart';
import '../process_runner.dart';
import 'postgres_url.dart';
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
      case DatabaseProvider.digitalOceanPostgres:
        await _digitalOceanPostgres();
      case DatabaseProvider.renderPostgres:
        await _renderPostgres();
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
    ensureHostsRegistered();
    if (config.host != AppHost.fly) {
      log.warn(
          'fly_postgres is only available when host: fly — skipping provision');
      return;
    }

    final fly = await _flyBin();
    final apiApp = config.fly.app;

    // API app is created in Deployer.ensureApiApp before this runs. Re-check so
    // attach never targets a missing app (e.g. ensure called standalone).
    if (!runner.dryRun && !await _flyAppExists(fly, apiApp)) {
      log.detail('creating Fly API app $apiApp (required before postgres attach)');
      final create = await runner.run(
        fly,
        ['apps', 'create', apiApp],
        allowDryRun: false,
      );
      if (!create.ok) {
        throw StateError(
          'fly apps create $apiApp failed before postgres attach '
          '(exit ${create.exitCode}). Run podfly deploy so ensureApiApp runs first.',
        );
      }
      log.ok('created Fly API app $apiApp');
    } else if (runner.dryRun) {
      log.dry('$fly apps create $apiApp  (if not exists, before attach)');
    }

    if (pg.create) {
      if (await _flyAppExists(fly, pg.app)) {
        log.detail('postgres app ${pg.app} already exists');
      } else {
        log.detail('ensure postgres app ${pg.app}');
        final create = await runner.run(fly, [
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
        if (!create.ok && !runner.dryRun) {
          // Race / already exists after check
          final err = (create.stderr + create.stdout).toLowerCase();
          if (!err.contains('already') && !await _flyAppExists(fly, pg.app)) {
            throw StateError(
              'fly postgres create ${pg.app} failed (exit ${create.exitCode})',
            );
          }
          log.detail('postgres create non-zero but app exists — continuing');
        }
      }
    }

    log.detail('attach ${pg.app} → $apiApp');
    final creds = await _flyPostgresAttachAndResolve(fly, pg.app, apiApp);
    if (creds != null) {
      await _writePgSidecar(ProductionYamlPatcher.flyPgSidecarName, creds);
      log.ok(
        'Fly Postgres credentials for Serverpod '
        '(${creds.user}@${creds.host}/${creds.database})',
      );
    } else if (!runner.dryRun) {
      log.warn(
        'could not resolve DATABASE_URL after attach — '
        'Serverpod production.yaml may use placeholders. '
        'Re-run attach or set passwords.yaml production.database manually.',
      );
    }
  }

  /// Attach cluster to API app and parse credentials (attach stdout or sidecar/ssh).
  Future<PostgresUrl?> _flyPostgresAttachAndResolve(
    String fly,
    String pgApp,
    String apiApp,
  ) async {
    if (runner.dryRun) {
      log.dry(
          '$fly postgres attach $pgApp -a $apiApp -y  → parse DATABASE_URL → sidecar');
      return null;
    }

    final attach = await runner.runCapture(
      fly,
      ['postgres', 'attach', pgApp, '-a', apiApp, '-y'],
      allowDryRun: false,
    );
    final out = attach.stdout + attach.stderr;
    var creds = parsePostgresUrlFromText(out);
    if (creds != null) return creds;

    if (attach.ok) {
      // Attach succeeded but no URL in output — try recovery paths.
      log.detail('attach ok but no DATABASE_URL in output — resolving…');
    } else {
      final lower = out.toLowerCase();
      final already = lower.contains('already') ||
          lower.contains('has been attached') ||
          lower.contains('attachment already') ||
          (lower.contains('consumer app') && lower.contains('attached'));
      if (!already) {
        throw StateError(
          'fly postgres attach $pgApp -a $apiApp failed '
          '(exit ${attach.exitCode}): ${attach.stderr.isNotEmpty ? attach.stderr : attach.stdout}',
        );
      }
      log.detail('postgres already attached to $apiApp — resolving credentials');
    }

    // Prefer prior podfly sidecar (survives re-deploys; secrets are not readable).
    creds = await _readFlyPgSidecar();
    if (creds != null) {
      log.detail('using credentials from ${ProductionYamlPatcher.flyPgSidecarName}');
      return creds;
    }

    // Running machine may expose DATABASE_URL in the env (post first deploy).
    creds = await _flyPrintenvDatabaseUrl(fly, apiApp);
    if (creds != null) return creds;

    return null;
  }

  Future<PostgresUrl?> _readFlyPgSidecar() async {
    final f = File(
      p.join(config.serverPath, 'config', ProductionYamlPatcher.flyPgSidecarName),
    );
    if (!await f.exists()) return null;
    try {
      final map = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final host = map['host']?.toString();
      final user = map['user']?.toString();
      final password = map['password']?.toString();
      final name = map['name']?.toString() ?? map['database']?.toString();
      if (host == null || user == null || password == null || name == null) {
        return null;
      }
      return PostgresUrl(
        user: user,
        password: password,
        host: host,
        port: map['port']?.toString() ?? '5432',
        database: name,
        requireSsl: map['requireSsl']?.toString() == 'true',
      );
    } catch (_) {
      return null;
    }
  }

  Future<PostgresUrl?> _flyPrintenvDatabaseUrl(String fly, String apiApp) async {
    final r = await runner.runCapture(
      fly,
      ['ssh', 'console', '-a', apiApp, '-C', 'printenv DATABASE_URL'],
      allowDryRun: false,
    );
    if (!r.ok) return null;
    return parsePostgresUrlFromText(r.stdout + r.stderr);
  }

  Future<bool> _flyAppExists(String fly, String app) async {
    if (runner.dryRun) return false;
    final status = await runner.runCapture(
      fly,
      ['status', '-a', app],
      allowDryRun: false,
    );
    final combined = (status.stdout + status.stderr).toLowerCase();
    return status.ok &&
        !combined.contains('could not find') &&
        !combined.contains('not found') &&
        !combined.contains('error');
  }

  Future<void> _writePgSidecar(String filename, PostgresUrl creds) async {
    final sidecar = File(p.join(config.serverPath, 'config', filename));
    await sidecar.parent.create(recursive: true);
    await sidecar.writeAsString(jsonEncode(creds.toSidecarMap()));
  }

  Future<void> _digitalOceanPostgres() async {
    ensureHostsRegistered();
    if (config.host != AppHost.digitalOcean) {
      throw StateError(
        'database.provider digitalocean_postgres requires host: digitalocean',
      );
    }
    final pg = config.database.digitalOceanPostgres ??
        DigitalOceanPostgresConfig(
          clusterName: '${config.name.replaceAll('_', '-')}-db',
        );
    final doctl = await runner.resolve('doctl');
    if (doctl == null) throw StateError('doctl required for digitalocean_postgres');

    final name = pg.clusterName ?? '${config.name.replaceAll('_', '-')}-db';
    if (runner.dryRun) {
      log.dry(
        '$doctl databases create $name --engine pg --region ${pg.region} …',
      );
      return;
    }

    var clusterId = pg.clusterId;
    // Lookup existing by name
    if (clusterId == null || clusterId.isEmpty) {
      final list = await runner.runCapture(
        doctl,
        ['databases', 'list', '-o', 'json'],
        allowDryRun: false,
      );
      clusterId = _findDoDbId(list.stdout, name);
    }

    if (clusterId == null && pg.create) {
      log.detail('creating DigitalOcean Postgres $name (${pg.region})');
      // Prefer size; fall back if slug invalid
      var create = await runner.runCapture(
        doctl,
        [
          'databases',
          'create',
          name,
          '--engine',
          'pg',
          '--version',
          pg.engineVersion,
          '--region',
          pg.region,
          '--size',
          pg.size,
          '--num-nodes',
          '1',
          '-o',
          'json',
        ],
        allowDryRun: false,
      );
      if (!create.ok) {
        // try alternate size slug used by some accounts
        log.warn('create with ${pg.size} failed — trying db-s-1vcpu-1gb / db-amd-1vcpu-1gb');
        for (final size in ['db-s-1vcpu-1gb', 'db-amd-1vcpu-1gb', 'db-intel-1vcpu-1gb']) {
          if (size == pg.size) continue;
          create = await runner.runCapture(
            doctl,
            [
              'databases',
              'create',
              name,
              '--engine',
              'pg',
              '--version',
              pg.engineVersion,
              '--region',
              pg.region,
              '--size',
              size,
              '--num-nodes',
              '1',
              '-o',
              'json',
            ],
            allowDryRun: false,
          );
          if (create.ok) break;
        }
      }
      if (!create.ok) {
        throw StateError(
          'doctl databases create failed: '
          '${create.stderr.isNotEmpty ? create.stderr : create.stdout}',
        );
      }
      clusterId = _jsonField(create.stdout, 'id');
      log.ok('created DigitalOcean Postgres $name');
      // Wait until online
      await _waitDoDatabase(doctl, clusterId ?? name);
    } else if (clusterId == null) {
      throw StateError(
        'DigitalOcean Postgres $name not found and create: false',
      );
    } else {
      log.detail('using DigitalOcean Postgres id $clusterId');
      await _waitDoDatabase(doctl, clusterId);
    }

    final id = clusterId!;
    // Prefer public host: App Platform reaches DBaaS over public SSL without
    // a pre-configured VPC; private hostnames fail health checks otherwise.
    final conn = await runner.runCapture(
      doctl,
      ['databases', 'connection', id, '-o', 'json'],
      allowDryRun: false,
    );
    var connOut = conn.stdout;
    if (!conn.ok) {
      throw StateError('could not get database connection for $id');
    }

    final host = _jsonField(connOut, 'host') ??
        _jsonField(connOut, 'private_host');
    final port = _jsonField(connOut, 'port') ?? '25060';
    final user = _jsonField(connOut, 'user') ?? 'doadmin';
    final password = _jsonField(connOut, 'password') ?? '';
    final database = _jsonField(connOut, 'database') ?? 'defaultdb';
    if (host == null || password.isEmpty) {
      throw StateError('incomplete DO database connection: $connOut');
    }

    await _writePgSidecar(
      ProductionYamlPatcher.digitalOceanPgSidecarName,
      PostgresUrl(
        user: user,
        password: password,
        host: host,
        port: port,
        database: database,
        requireSsl: true,
      ),
    );
    log.ok('DigitalOcean Postgres credentials → sidecar ($user@$host/$database)');

    // Firewall: prefer app-scoped rules after the App Platform app exists
    // (see DigitalOceanHost._trustAppForDatabase). DO rejects 0.0.0.0/0.

    // Persist cluster id into podfly.yaml if possible
    await _persistDoDbClusterId(id, name);
  }

  String? _findDoDbId(String json, String name) {
    try {
      final list = jsonDecode(json);
      if (list is! List) return null;
      for (final item in list) {
        if (item is Map && item['name']?.toString() == name) {
          return item['id']?.toString();
        }
      }
    } catch (_) {}
    return null;
  }

  String? _jsonField(String raw, String key) {
    try {
      final m = jsonDecode(raw);
      if (m is Map && m[key] != null) return m[key].toString();
      if (m is List && m.isNotEmpty && m.first is Map) {
        final v = (m.first as Map)[key];
        if (v != null) return v.toString();
      }
    } catch (_) {}
    final re = RegExp('"$key"\\s*:\\s*"([^"]*)"');
    return re.firstMatch(raw)?.group(1);
  }

  Future<void> _waitDoDatabase(String doctl, String idOrName) async {
    for (var i = 0; i < 60; i++) {
      final r = await runner.runCapture(
        doctl,
        ['databases', 'get', idOrName, '-o', 'json'],
        allowDryRun: false,
      );
      final status = (_jsonField(r.stdout, 'status') ?? '').toLowerCase();
      if (status == 'online' || status == 'active') {
        log.detail('database online');
        return;
      }
      log.detail('waiting for database ($status)…');
      await Future<void>.delayed(const Duration(seconds: 10));
    }
    log.warn('database not online after wait — continuing');
  }

  Future<void> _persistDoDbClusterId(String id, String name) async {
    final f = File(config.configPath);
    if (!await f.exists()) return;
    var text = await f.readAsString();
    if (!text.contains('digitalocean_postgres:')) return;
    if (RegExp(r'cluster_id:\s*\S+').hasMatch(text)) {
      text = text.replaceFirst(
        RegExp(r'(cluster_id:\s*).+'),
        'cluster_id: $id',
      );
    } else {
      text = text.replaceFirst(
        RegExp(r'(digitalocean_postgres:\n)'),
        'digitalocean_postgres:\n    cluster_id: $id\n    cluster_name: $name\n',
      );
    }
    await f.writeAsString(text);
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
      await _writePgSidecar(
        ProductionYamlPatcher.railwayPgSidecarName,
        PostgresUrl(
          user: creds.user,
          password: creds.password,
          host: creds.host,
          port: creds.port,
          database: creds.database,
          requireSsl: false,
        ),
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

  Future<void> _renderPostgres() async {
    final pg = config.database.renderPostgres;
    if (pg == null) return;
    ensureHostsRegistered();
    if (config.host != AppHost.render) {
      log.warn(
        'render_postgres is only available when host: render — skipping',
      );
      return;
    }

    final render = await runner.resolve('render');
    if (render == null) throw StateError('render CLI not found');

    if (runner.dryRun) {
      log.dry(
        '$render postgres create --name ${pg.name} --plan ${pg.plan} '
        '--region ${pg.region} (if missing)',
      );
      return;
    }

    var id = pg.databaseId;
    if (id == null || id.isEmpty) {
      id = await _findRenderPostgresId(render, pg.name);
    }

    if (id == null && pg.create) {
      log.detail('creating Render Postgres ${pg.name}');
      final create = await runner.runCapture(
        render,
        [
          'postgres',
          'create',
          '--name',
          pg.name,
          '--plan',
          pg.plan,
          '--region',
          pg.region,
          // Empty allow-list blocks all TCP; open for Serverpod on free/public.
          '--ip-allow-list',
          'cidr=0.0.0.0/0,description=everywhere',
          '--confirm',
          '-o',
          'json',
        ],
        allowDryRun: false,
      );
      if (!create.ok) {
        throw StateError(
          'render postgres create failed (exit ${create.exitCode}): '
          '${create.stderr.isNotEmpty ? create.stderr : create.stdout}',
        );
      }
      id = _parseRenderJsonId(create.stdout);
      if (id == null) {
        id = await _findRenderPostgresId(render, pg.name);
      }
      if (id == null) {
        throw StateError('Render Postgres created but id not found');
      }
      log.ok('created Render Postgres ${pg.name} ($id)');
      await _waitRenderPostgresAvailable(render, id);
    } else if (id == null) {
      log.warn('Render Postgres ${pg.name} not found and create: false');
      return;
    } else {
      log.detail('Render Postgres ${pg.name} exists ($id)');
      await _waitRenderPostgresAvailable(render, id);
      // Ensure external connections work (create may have empty allow-list).
      await runner.run(
        render,
        [
          'postgres',
          'update',
          id,
          '--ip-allow-list',
          'cidr=0.0.0.0/0,description=everywhere',
          '--confirm',
          '-o',
          'json',
        ],
        allowDryRun: false,
      );
    }

    final get = await runner.runCapture(
      render,
      [
        'postgres',
        'get',
        id,
        '--include-sensitive-connection-info',
        '--confirm',
        '-o',
        'json',
      ],
      allowDryRun: false,
    );
    if (!get.ok) {
      log.warn('render postgres get failed — cannot patch Serverpod config');
      return;
    }

    final creds = _parseRenderPostgresGet(get.stdout);
    if (creds == null) {
      log.warn(
        'could not parse Render Postgres connectionInfo — '
        'set production database manually',
      );
      return;
    }
    await _writePgSidecar(
      ProductionYamlPatcher.renderPgSidecarName,
      creds,
    );
    log.ok(
      'Render Postgres credentials for Serverpod '
      '(${creds.user}@${creds.host}/${creds.database})',
    );
  }

  Future<String?> _findRenderPostgresId(String render, String name) async {
    final list = await runner.runCapture(
      render,
      ['postgres', 'list', '-o', 'json', '--confirm'],
      allowDryRun: false,
    );
    if (!list.ok) return null;
    final raw = list.stdout.trim();
    if (raw.isEmpty || raw == 'null') return null;
    try {
      final decoded = jsonDecode(raw);
      final items = decoded is Map && decoded['data'] is List
          ? decoded['data'] as List
          : (decoded is List ? decoded : const []);
      for (final item in items) {
        if (item is! Map) continue;
        if (item['name']?.toString() == name) {
          return item['id']?.toString();
        }
      }
    } catch (_) {/* ignore */}
    return null;
  }

  String? _parseRenderJsonId(String stdout) {
    try {
      final decoded = jsonDecode(stdout);
      if (decoded is Map) {
        final data = decoded['data'] ?? decoded;
        if (data is Map && data['id'] != null) return data['id'].toString();
      }
    } catch (_) {/* ignore */}
    return RegExp(r'dpg-[a-z0-9-]+').firstMatch(stdout)?.group(0);
  }

  Future<void> _waitRenderPostgresAvailable(String render, String id) async {
    for (var i = 0; i < 36; i++) {
      final get = await runner.runCapture(
        render,
        ['postgres', 'get', id, '--confirm', '-o', 'json'],
        allowDryRun: false,
      );
      if (get.ok) {
        try {
          final decoded = jsonDecode(get.stdout);
          final data = decoded is Map ? (decoded['data'] ?? decoded) : null;
          final status =
              data is Map ? data['status']?.toString() ?? '' : '';
          if (status == 'available') {
            log.detail('Render Postgres $id available');
            return;
          }
          log.detail('waiting for Render Postgres ($status)…');
        } catch (_) {/* retry */}
      }
      await Future<void>.delayed(const Duration(seconds: 5));
    }
    log.warn('Render Postgres $id not available yet — continuing');
  }

  PostgresUrl? _parseRenderPostgresGet(String stdout) {
    try {
      final decoded = jsonDecode(stdout);
      if (decoded is! Map) return null;
      final data = decoded['data'] ?? decoded;
      if (data is! Map) return null;
      final info = data['connectionInfo'];
      if (info is Map) {
        // Prefer *internal* hostname for services in the same Render workspace
        // (private network; no public SSL dance). Fall back to external+SSL.
        final internal = info['internalConnectionString']?.toString();
        if (internal != null) {
          final u = parsePostgresUrl(internal);
          if (u != null) {
            return PostgresUrl(
              user: u.user,
              password: u.password,
              host: u.host,
              port: u.port,
              database: u.database,
              requireSsl: false,
            );
          }
        }
        final ext = info['externalConnectionString']?.toString();
        if (ext != null) {
          final u = parsePostgresUrl(ext);
          if (u != null) {
            return PostgresUrl(
              user: u.user,
              password: u.password,
              host: u.host,
              port: u.port,
              database: u.database,
              requireSsl: true,
            );
          }
        }
      }
    } catch (_) {/* fall through */}
    return parsePostgresUrlFromText(stdout);
  }
}
