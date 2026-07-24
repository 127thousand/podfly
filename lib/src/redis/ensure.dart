import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../database/production_yaml.dart';
import '../log.dart';
import '../process_runner.dart';

/// Provision / ensure Redis then patch production.yaml + passwords.yaml.
class RedisEnsure {
  RedisEnsure({
    required this.config,
    required this.runner,
    required this.log,
  });

  final PodflyConfig config;
  final ProcessRunner runner;
  final Log log;

  static const sidecarName = ProductionYamlPatcher.upstashRedisSidecarName;

  Future<void> run() async {
    if (!config.redis.enabled) {
      log.detail('redis: disabled (provider: none)');
      if (!runner.dryRun) {
        await ProductionYamlPatcher(config: config, log: log).applyRedis();
      }
      return;
    }

    log.step('Redis (${config.redis.provider.yamlName})');
    switch (config.redis.provider) {
      case RedisProvider.none:
        break;
      case RedisProvider.upstash:
        await _upstash();
    }

    if (!runner.dryRun) {
      await ProductionYamlPatcher(config: config, log: log).applyRedis();
      await _setFlyRedisEnvSecrets();
    } else {
      log.dry('patch redis in production.yaml + passwords.yaml');
    }
  }

  Future<void> _upstash() async {
    final u = config.redis.upstash ?? UpstashRedisConfig();
    // Prefer sidecar / existing id
    final sidecar = await _readSidecar();
    if (sidecar != null &&
        (sidecar['endpoint']?.isNotEmpty ?? false) &&
        (sidecar['password']?.isNotEmpty ?? false)) {
      log.detail(
        'Upstash Redis from sidecar: ${sidecar['endpoint']}:${sidecar['port']}',
      );
      await _persistUpstashYaml(
        databaseId: sidecar['database_id'],
        endpoint: sidecar['endpoint']!,
        port: int.tryParse(sidecar['port'] ?? '') ?? u.port,
        name: sidecar['database_name'] ?? u.name,
      );
      return;
    }

    if (u.databaseId != null && u.databaseId!.isNotEmpty) {
      await _fetchAndSave(u.databaseId!);
      return;
    }

    if (u.endpoint != null && u.endpoint!.isNotEmpty && !u.provision) {
      log.warn(
        'upstash: endpoint set but no password sidecar — '
        'set config/$sidecarName or enable provision',
      );
      return;
    }

    if (!u.provision) {
      log.warn('upstash: provision: false and no database_id/sidecar');
      return;
    }

    await _createDatabase(u);
  }

  Future<void> _createDatabase(UpstashRedisConfig u) async {
    final upstash = await runner.resolve('upstash');
    if (upstash == null) {
      throw StateError(
        'upstash CLI not found — npm i -g @upstash/cli  '
        '(https://github.com/upstash/cli)',
      );
    }
    final name = u.name ?? '${config.fly.app}-redis'.replaceAll('_', '-');
    if (runner.dryRun) {
      log.dry('upstash redis create --name $name --region ${u.region}');
      return;
    }

    // Reuse existing by name if present
    final list = await runner.runCapture(
      upstash,
      ['redis', 'list'],
      allowDryRun: false,
    );
    if (list.ok) {
      final existing = _findDbByName(list.stdout, name);
      if (existing != null) {
        log.detail('Upstash Redis "$name" already exists — reusing');
        await _writeSidecar(existing);
        await _persistUpstashYaml(
          databaseId: existing['database_id']?.toString(),
          endpoint: existing['endpoint']?.toString() ?? '',
          port: _portOf(existing, u.port),
          name: name,
        );
        return;
      }
    }

    log.detail('creating Upstash Redis $name (${u.region})');
    final create = await runner.runCapture(
      upstash,
      ['redis', 'create', '--name', name, '--region', u.region],
      allowDryRun: false,
    );
    if (!create.ok) {
      throw StateError(
        'upstash redis create failed:\n${create.stderr}\n${create.stdout}',
      );
    }
    final data = _parseJsonObject(create.stdout) ??
        _parseJsonObject(create.stderr);
    if (data == null) {
      throw StateError('upstash redis create: could not parse JSON response');
    }
    await _writeSidecar(data);
    await _persistUpstashYaml(
      databaseId: data['database_id']?.toString(),
      endpoint: data['endpoint']?.toString() ?? '',
      port: _portOf(data, u.port),
      name: name,
    );
    log.ok(
      'Upstash Redis: ${data['endpoint']}:${_portOf(data, u.port)}',
    );
  }

  Future<void> _fetchAndSave(String databaseId) async {
    final upstash = await runner.resolve('upstash');
    if (upstash == null) {
      throw StateError('upstash CLI not found');
    }
    if (runner.dryRun) {
      log.dry('upstash redis get --db-id $databaseId');
      return;
    }
    final get = await runner.runCapture(
      upstash,
      ['redis', 'get', '--db-id', databaseId],
      allowDryRun: false,
    );
    if (!get.ok) {
      throw StateError(
        'upstash redis get failed:\n${get.stderr}\n${get.stdout}',
      );
    }
    final data =
        _parseJsonObject(get.stdout) ?? _parseJsonObject(get.stderr);
    if (data == null) {
      throw StateError('upstash redis get: could not parse JSON');
    }
    await _writeSidecar(data);
    final u = config.redis.upstash ?? UpstashRedisConfig();
    await _persistUpstashYaml(
      databaseId: databaseId,
      endpoint: data['endpoint']?.toString() ?? '',
      port: _portOf(data, u.port),
      name: data['database_name']?.toString() ?? u.name,
    );
    log.ok('Upstash Redis: ${data['endpoint']}');
  }

  Future<void> _persistUpstashYaml({
    required String? databaseId,
    required String endpoint,
    required int port,
    String? name,
  }) async {
    final base = config.redis.upstash ?? UpstashRedisConfig();
    final updated = PodflyConfig(
      root: config.root,
      host: config.host,
      webHost: config.webHost,
      mode: config.mode,
      name: config.name,
      server: config.server,
      flutter: config.flutter,
      fly: config.fly,
      railway: config.railway,
      digitalOcean: config.digitalOcean,
      render: config.render,
      cloudRun: config.cloudRun,
      aws: config.aws,
      awsEcs: config.awsEcs,
      azure: config.azure,
      hetzner: config.hetzner,
      cloudflare: config.cloudflare,
      vercel: config.vercel,
      netlify: config.netlify,
      githubPages: config.githubPages,
      database: config.database,
      redis: RedisConfig(
        provider: RedisProvider.upstash,
        upstash: UpstashRedisConfig(
          name: name ?? base.name,
          region: base.region,
          provision: base.provision,
          databaseId: databaseId ?? base.databaseId,
          endpoint: endpoint.isNotEmpty ? endpoint : base.endpoint,
          port: port,
        ),
      ),
      mobile: config.mobile,
      web: config.web,
      smoke: config.smoke,
    );
    await updated.save();
    log.detail('saved redis.upstash endpoint + database_id');
  }

  Future<void> _setFlyRedisEnvSecrets() async {
    if (config.host != AppHost.fly) return;
    if (!config.redis.enabled) return;
    final sidecar = await _readSidecar();
    final endpoint =
        sidecar?['endpoint'] ?? config.redis.upstash?.endpoint;
    if (endpoint == null || endpoint.isEmpty) return;

    final port =
        sidecar?['port'] ?? '${config.redis.upstash?.port ?? 6379}';
    final fly = await runner.resolve('fly', ['flyctl']);
    if (fly == null) return;

    // Serverpod env overrides (see Serverpod Cloud Redis guide).
    // Password: SERVERPOD_PASSWORD_redis (required if redis enabled).
    final password = sidecar?['password'];
    final args = <String>[
      'secrets',
      'set',
      '-a',
      config.fly.app,
      'SERVERPOD_REDIS_ENABLED=true',
      'SERVERPOD_REDIS_HOST=$endpoint',
      'SERVERPOD_REDIS_PORT=$port',
      'SERVERPOD_REDIS_REQUIRE_SSL=true',
    ];
    if (password != null && password.isNotEmpty) {
      args.add('SERVERPOD_PASSWORD_redis=$password');
    }
    if (runner.dryRun) {
      log.dry('fly secrets set SERVERPOD_REDIS_* (+ password if known)…');
      return;
    }
    final r = await runner.run(fly, args, allowDryRun: false);
    if (r.ok) {
      log.ok('Fly secrets: SERVERPOD_REDIS_* set'
          '${password != null && password.isNotEmpty ? " (+ password)" : ""}');
    } else {
      log.warn(
        'fly secrets set SERVERPOD_REDIS_* failed — set manually or via passwords.yaml',
      );
    }
  }

  Future<Map<String, String>?> _readSidecar() async {
    final f = File(p.join(config.serverPath, 'config', sidecarName));
    if (!await f.exists()) return null;
    try {
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is! Map) return null;
      return decoded.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeSidecar(Map<String, dynamic> data) async {
    final dir = Directory(p.join(config.serverPath, 'config'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final f = File(p.join(dir.path, sidecarName));
    // Store only what we need; password is sensitive — still required for
    // passwords.yaml patch (same pattern as fly_postgres sidecar).
    final slim = <String, dynamic>{
      'database_id': data['database_id'],
      'database_name': data['database_name'],
      'endpoint': data['endpoint'],
      'port': data['port'],
      'password': data['password'],
      'tls': data['tls'] ?? true,
      'primary_region': data['primary_region'],
    };
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(slim));
    log.detail('wrote config/$sidecarName');
  }

  static Map<String, dynamic>? _parseJsonObject(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    try {
      final v = jsonDecode(t);
      if (v is Map<String, dynamic>) return v;
      if (v is Map) return v.map((k, val) => MapEntry(k.toString(), val));
    } catch (_) {}
    final start = t.indexOf('{');
    final end = t.lastIndexOf('}');
    if (start >= 0 && end > start) {
      try {
        final v = jsonDecode(t.substring(start, end + 1));
        if (v is Map<String, dynamic>) return v;
        if (v is Map) return v.map((k, val) => MapEntry(k.toString(), val));
      } catch (_) {}
    }
    return null;
  }

  static Map<String, dynamic>? _findDbByName(String listJson, String name) {
    try {
      final v = jsonDecode(listJson.trim());
      if (v is! List) return null;
      for (final item in v) {
        if (item is Map && item['database_name']?.toString() == name) {
          return item.map((k, val) => MapEntry(k.toString(), val));
        }
      }
    } catch (_) {}
    return null;
  }

  static int _portOf(Map data, int fallback) {
    final p = data['port'];
    if (p is int) return p;
    return int.tryParse('$p') ?? fallback;
  }
}
