import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'hosts/hosts.dart';

enum DeployMode { split, fly }

/// Where the Serverpod **API** container runs.
///
/// Behavior (CLI, deploy, auth) lives on [HostAdapter] via [HostRegistry] —
/// do not add host-specific logic here.
enum AppHost {
  fly,
  railway,
  render,
  cloudRun,
  aws,
  azure,
  digitalOcean,
}

enum DatabaseProvider { none, sqlite, flyPostgres, neon, railwayPostgres }

extension AppHostX on AppHost {
  HostAdapter get adapter {
    ensureHostsRegistered();
    return HostRegistry.require(this);
  }

  String get yamlName => adapter.id;

  String get label => adapter.label;

  List<String> get cliBinaries => adapter.cliBinaries;

  String get installHint => adapter.installHint;

  /// Deploy implemented for this host.
  bool get isImplemented => adapter.canDeploy;

  static AppHost parse(String? s) {
    ensureHostsRegistered();
    if (s == null || s.isEmpty || s == 'fly') return AppHost.fly;
    return HostRegistry.requireId(s).appHost;
  }
}

class FlyConfig {
  FlyConfig({
    required this.app,
    this.region = 'iad',
    this.config = 'fly.toml',
    this.scaleToZero = true,
    this.ha = false,
  });

  final String app;
  final String region;
  final String config;
  final bool scaleToZero;
  final bool ha;

  Map<String, Object?> toMap() => {
        'app': app,
        'region': region,
        'config': config,
        'scale_to_zero': scaleToZero,
        'ha': ha,
      };
}

/// Railway project / services for API (+ optional static web).
class RailwayConfig {
  RailwayConfig({
    required this.project,
    this.service = 'api',
    this.webService = 'web',
    this.environment = 'production',
    this.projectId,
    this.port = 8080,
    this.webPort = 80,
    this.config = 'railway.toml',
    this.publicHost,
    this.webPublicHost,
    this.enableCdn = true,
    this.serverless = true,
  });

  /// Human project name (used when creating / as default).
  final String project;
  final String service;
  /// Static Flutter web service name when web is hosted on Railway.
  final String webService;
  final String environment;
  /// Railway project UUID when known (skips name-based create).
  final String? projectId;
  /// Internal container port Serverpod listens on (domain targets this).
  final int port;
  /// Internal port for nginx static web.
  final int webPort;
  /// Config-as-code file at monorepo root (dockerfile path for API).
  final String config;
  /// e.g. `xxx.up.railway.app` once domain exists.
  final String? publicHost;
  final String? webPublicHost;
  /// Enable Railway edge CDN on the web service.
  final bool enableCdn;
  /// Railway Serverless (sleep ~10m idle). Default on for podfly — not Postgres.
  final bool serverless;

  Map<String, Object?> toMap() => {
        'project': project,
        'service': service,
        'web_service': webService,
        'environment': environment,
        if (projectId != null) 'project_id': projectId,
        'port': port,
        'web_port': webPort,
        'config': config,
        if (publicHost != null) 'public_host': publicHost,
        if (webPublicHost != null) 'web_public_host': webPublicHost,
        'enable_cdn': enableCdn,
        'serverless': serverless,
      };

  String? get publicUrl {
    final h = publicHost;
    if (h == null || h.isEmpty) return null;
    final host = h.replaceFirst(RegExp(r'^https?://'), '').split('/').first;
    return 'https://$host/';
  }

  String? get webPublicUrl {
    final h = webPublicHost;
    if (h == null || h.isEmpty) return null;
    final host = h.replaceFirst(RegExp(r'^https?://'), '').split('/').first;
    return 'https://$host/';
  }
}

class RailwayPostgresConfig {
  RailwayPostgresConfig({
    this.service = 'Postgres',
    this.create = true,
    this.connectionStringSecret = 'DATABASE_URL',
  });

  /// Railway database plugin service name (template default: Postgres).
  final String service;
  final bool create;
  final String connectionStringSecret;

  Map<String, Object?> toMap() => {
        'service': service,
        'create': create,
        'connection_string_secret': connectionStringSecret,
      };
}

class CloudflareConfig {
  CloudflareConfig({required this.project, this.branch = 'main'});
  final String project;
  final String branch;

  Map<String, Object?> toMap() => {
        'project': project,
        'branch': branch,
      };
}

class SqliteConfig {
  SqliteConfig({
    this.path = '/data/serverpod.db',
    this.volumeCreate = true,
    this.volumeName,
    this.volumeSizeGb = 1,
    this.volumeDest = '/data',
  });

  final String path;
  final bool volumeCreate;
  final String? volumeName;
  final int volumeSizeGb;
  final String volumeDest;

  Map<String, Object?> toMap() => {
        'path': path,
        'volume': {
          'create': volumeCreate,
          if (volumeName != null) 'name': volumeName,
          'size_gb': volumeSizeGb,
          'dest': volumeDest,
        },
      };
}

class FlyPostgresConfig {
  FlyPostgresConfig({required this.app, this.create = true});
  final String app;
  final bool create;

  Map<String, Object?> toMap() => {
        'app': app,
        'create': create,
      };
}

class NeonConfig {
  NeonConfig({
    this.connectionStringSecret = 'DATABASE_URL',
    this.provision = false,
    this.projectName,
    this.region = 'aws-us-east-1',
    this.host,
    this.database = 'neondb',
    this.user = 'neondb_owner',
  });

  final String connectionStringSecret;
  final bool provision;
  final String? projectName;
  final String region;
  final String? host;
  final String database;
  final String user;

  Map<String, Object?> toMap() => {
        'connection_string_secret': connectionStringSecret,
        'provision': provision,
        if (projectName != null) 'project_name': projectName,
        'region': region,
        if (host != null) 'host': host,
        'database': database,
        'user': user,
      };
}

class DatabaseConfig {
  DatabaseConfig({
    required this.provider,
    this.sqlite,
    this.flyPostgres,
    this.neon,
    this.railwayPostgres,
  });

  final DatabaseProvider provider;
  final SqliteConfig? sqlite;
  final FlyPostgresConfig? flyPostgres;
  final NeonConfig? neon;
  final RailwayPostgresConfig? railwayPostgres;

  Map<String, Object?> toMap() {
    final m = <String, Object?>{'provider': _providerName(provider)};
    if (sqlite != null) m['sqlite'] = sqlite!.toMap();
    if (flyPostgres != null) m['fly_postgres'] = flyPostgres!.toMap();
    if (neon != null) m['neon'] = neon!.toMap();
    if (railwayPostgres != null) {
      m['railway_postgres'] = railwayPostgres!.toMap();
    }
    return m;
  }

  static String _providerName(DatabaseProvider p) => switch (p) {
        DatabaseProvider.none => 'none',
        DatabaseProvider.sqlite => 'sqlite',
        DatabaseProvider.flyPostgres => 'fly_postgres',
        DatabaseProvider.neon => 'neon',
        DatabaseProvider.railwayPostgres => 'railway_postgres',
      };

  static DatabaseProvider parseProvider(String? s) => switch (s) {
        null || 'none' => DatabaseProvider.none,
        'sqlite' => DatabaseProvider.sqlite,
        'fly_postgres' || 'fly-postgres' || 'postgres' =>
          DatabaseProvider.flyPostgres,
        'neon' => DatabaseProvider.neon,
        'railway_postgres' || 'railway-postgres' || 'railway' =>
          DatabaseProvider.railwayPostgres,
        _ => throw FormatException('Unknown database.provider: $s'),
      };
}

class WebConfig {
  WebConfig({
    this.enabled = true,
    this.serverUrlDefine = 'SERVER_URL',
    required this.apiUrl,
    this.patchBootstrap = true,
    this.writeHeaders = true,
    this.baseHref = '/',
    this.staticDir,
  });

  /// When false, podfly deploys API only (mobile / non-web clients).
  final bool enabled;
  final String serverUrlDefine;
  final String apiUrl;
  final bool patchBootstrap;
  final bool writeHeaders;
  final String baseHref;
  final String? staticDir;

  String get apiUrlNormalized {
    if (apiUrl.endsWith('/')) return apiUrl;
    return '$apiUrl/';
  }

  Map<String, Object?> toMap() => {
        'enabled': enabled,
        'server_url_define': serverUrlDefine,
        'api_url': apiUrlNormalized,
        'patch_bootstrap': patchBootstrap,
        'write_headers': writeHeaders,
        'base_href': baseHref,
        if (staticDir != null) 'static_dir': staticDir,
      };
}

class SmokeEndpoint {
  SmokeEndpoint({
    this.method = 'GET',
    this.path = '/',
    this.body,
    this.expectStatus = 200,
  });

  final String method;
  final String path;
  final String? body;
  final int expectStatus;

  Map<String, Object?> toMap() => {
        'method': method,
        'path': path,
        if (body != null) 'body': body,
        'expect_status': expectStatus,
      };
}

class SmokeConfig {
  SmokeConfig({this.api, this.web});
  final SmokeEndpoint? api;
  final SmokeEndpoint? web;

  Map<String, Object?> toMap() => {
        if (api != null) 'api': api!.toMap(),
        if (web != null) 'web': web!.toMap(),
      };
}

class PodflyConfig {
  PodflyConfig({
    required this.root,
    this.host = AppHost.fly,
    required this.mode,
    required this.name,
    required this.server,
    required this.flutter,
    required this.fly,
    this.railway,
    this.cloudflare,
    required this.database,
    required this.web,
    this.smoke,
  });

  final String root;
  /// Cloud that runs the Serverpod API container.
  final AppHost host;
  final DeployMode mode;
  final String name;
  final String server;
  final String flutter;
  final FlyConfig fly;
  final RailwayConfig? railway;
  final CloudflareConfig? cloudflare;
  final DatabaseConfig database;
  final WebConfig web;
  final SmokeConfig? smoke;

  String get serverPath => p.join(root, server);
  String get flutterPath => p.join(root, flutter);
  String get flyTomlPath => p.join(root, fly.config);
  String get railwayTomlPath =>
      p.join(root, railway?.config ?? 'railway.toml');
  String get configPath => p.join(root, 'podfly.yaml');
  String get webOutPath => p.join(root, 'build', 'web');

  /// Best-known public API base URL for this host (trailing slash).
  String get apiPublicBase {
    final fromHost = host.adapter.publicApiBase(this);
    if (fromHost != null && fromHost.isNotEmpty) return fromHost;
    return web.apiUrlNormalized;
  }

  Map<String, Object?> toMap() => {
        'host': host.yamlName,
        'mode': mode == DeployMode.split ? 'split' : 'fly',
        'name': name,
        'server': server,
        'flutter': flutter,
        'fly': fly.toMap(),
        if (railway != null) 'railway': railway!.toMap(),
        if (cloudflare != null) 'cloudflare': cloudflare!.toMap(),
        'database': database.toMap(),
        'web': web.toMap(),
        if (smoke != null) 'smoke': smoke!.toMap(),
      };

  String toYaml() {
    final buf = StringBuffer();
    buf.writeln('# Generated by podfly — edit freely');
    buf.writeln('host: ${host.yamlName}  # API cloud: fly | railway | render | …');
    buf.writeln('mode: ${mode == DeployMode.split ? 'split' : 'fly'}');
    buf.writeln('name: $name');
    buf.writeln('server: $server');
    buf.writeln('flutter: $flutter');
    buf.writeln();
    if (host == AppHost.fly) {
      buf.writeln('fly:');
      buf.writeln('  app: ${fly.app}');
      buf.writeln('  region: ${fly.region}');
      buf.writeln('  config: ${fly.config}');
      buf.writeln('  scale_to_zero: ${fly.scaleToZero}');
      buf.writeln('  ha: ${fly.ha}');
    }
    if (host == AppHost.railway || railway != null) {
      final r = railway ??
          RailwayConfig(project: name, service: 'api');
      buf.writeln('railway:');
      buf.writeln('  project: ${r.project}');
      buf.writeln('  service: ${r.service}');
      buf.writeln('  web_service: ${r.webService}');
      buf.writeln('  environment: ${r.environment}');
      if (r.projectId != null) {
        buf.writeln('  project_id: ${r.projectId}');
      }
      buf.writeln('  port: ${r.port}');
      buf.writeln('  web_port: ${r.webPort}');
      buf.writeln('  config: ${r.config}');
      buf.writeln('  enable_cdn: ${r.enableCdn}');
      buf.writeln(
          '  serverless: ${r.serverless}  # sleep API/web when idle (~10m)');
      if (r.publicHost != null) {
        buf.writeln('  public_host: ${r.publicHost}');
      }
      if (r.webPublicHost != null) {
        buf.writeln('  web_public_host: ${r.webPublicHost}');
      }
    }
    // Cloudflare only when not hosting UI on Railway
    if (cloudflare != null && host != AppHost.railway) {
      buf.writeln();
      buf.writeln('cloudflare:');
      buf.writeln('  project: ${cloudflare!.project}');
      buf.writeln('  branch: ${cloudflare!.branch}');
    }
    buf.writeln();
    buf.writeln('database:');
    buf.writeln(
        '  provider: ${DatabaseConfig._providerName(database.provider)}');
    if (database.sqlite != null) {
      final s = database.sqlite!;
      buf.writeln('  sqlite:');
      buf.writeln('    path: ${s.path}');
      buf.writeln('    volume:');
      buf.writeln('      create: ${s.volumeCreate}');
      if (s.volumeName != null) buf.writeln('      name: ${s.volumeName}');
      buf.writeln('      size_gb: ${s.volumeSizeGb}');
      buf.writeln('      dest: ${s.volumeDest}');
    }
    if (database.flyPostgres != null) {
      final f = database.flyPostgres!;
      buf.writeln('  fly_postgres:');
      buf.writeln('    app: ${f.app}');
      buf.writeln('    create: ${f.create}');
    }
    if (database.neon != null) {
      final n = database.neon!;
      buf.writeln('  neon:');
      buf.writeln(
          '    connection_string_secret: ${n.connectionStringSecret}');
      buf.writeln('    provision: ${n.provision}');
      if (n.projectName != null) {
        buf.writeln('    project_name: ${n.projectName}');
      }
      buf.writeln('    region: ${n.region}');
      if (n.host != null) buf.writeln('    host: ${n.host}');
    }
    if (database.railwayPostgres != null) {
      final r = database.railwayPostgres!;
      buf.writeln('  railway_postgres:');
      buf.writeln('    service: ${r.service}');
      buf.writeln('    create: ${r.create}');
      buf.writeln(
          '    connection_string_secret: ${r.connectionStringSecret}');
    }
    buf.writeln();
    buf.writeln('web:');
    buf.writeln('  enabled: ${web.enabled}');
    buf.writeln('  server_url_define: ${web.serverUrlDefine}');
    buf.writeln('  api_url: ${web.apiUrlNormalized}');
    buf.writeln('  patch_bootstrap: ${web.patchBootstrap}');
    buf.writeln('  write_headers: ${web.writeHeaders}');
    buf.writeln('  base_href: ${web.baseHref}');
    if (web.staticDir != null) {
      buf.writeln('  static_dir: ${web.staticDir}');
    }
    if (smoke != null) {
      buf.writeln();
      buf.writeln('smoke:');
      if (smoke!.api != null) {
        final a = smoke!.api!;
        buf.writeln('  api:');
        buf.writeln('    method: ${a.method}');
        buf.writeln('    path: ${a.path}');
        if (a.body != null) {
          buf.writeln('    body: ${_yamlDoubleQuoted(a.body!)}');
        }
        buf.writeln('    expect_status: ${a.expectStatus}');
      }
      if (smoke!.web != null) {
        final w = smoke!.web!;
        buf.writeln('  web:');
        buf.writeln('    path: ${w.path}');
        buf.writeln('    expect_status: ${w.expectStatus}');
      }
    }
    return buf.toString();
  }

  Future<void> save([String? path]) async {
    final f = File(path ?? configPath);
    await f.parent.create(recursive: true);
    await f.writeAsString(toYaml());
  }

  /// YAML double-quoted scalar with escaping.
  static String _yamlDoubleQuoted(String value) {
    final escaped = value
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r');
    return '"$escaped"';
  }

  static Future<PodflyConfig> load(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw StateError('Config not found: $path');
    }
    final doc = loadYaml(await file.readAsString());
    if (doc is! YamlMap) throw FormatException('podfly.yaml must be a map');
    final root = p.dirname(p.normalize(file.absolute.path));
    return fromYaml(doc, root);
  }

  static PodflyConfig fromYaml(YamlMap doc, String root) {
    final host = AppHostX.parse(doc['host']?.toString());
    final modeStr = doc['mode']?.toString() ?? 'split';
    final mode = modeStr == 'fly' ? DeployMode.fly : DeployMode.split;
    final name = doc['name']?.toString() ?? p.basename(root);
    final server = doc['server']?.toString() ?? '';
    final flutter = doc['flutter']?.toString() ?? '';

    final flyMap = _map(doc['fly']);
    final fly = FlyConfig(
      app: flyMap['app']?.toString() ?? name,
      region: flyMap['region']?.toString() ?? 'iad',
      config: flyMap['config']?.toString() ?? 'fly.toml',
      scaleToZero: flyMap['scale_to_zero'] != false,
      ha: flyMap['ha'] == true,
    );

    RailwayConfig? railway;
    if (doc['railway'] != null || host == AppHost.railway) {
      final m = _map(doc['railway']);
      railway = RailwayConfig(
        project: m['project']?.toString() ?? name,
        service: m['service']?.toString() ?? 'api',
        webService: m['web_service']?.toString() ?? 'web',
        environment: m['environment']?.toString() ?? 'production',
        projectId: m['project_id']?.toString(),
        port: int.tryParse('${m['port'] ?? 8080}') ?? 8080,
        webPort: int.tryParse('${m['web_port'] ?? 80}') ?? 80,
        config: m['config']?.toString() ?? 'railway.toml',
        publicHost: m['public_host']?.toString(),
        webPublicHost: m['web_public_host']?.toString(),
        enableCdn: m['enable_cdn'] != false,
        serverless: m['serverless'] != false,
      );
    }

    CloudflareConfig? cf;
    // Pages UI for Fly split; Railway hosts its own static web service.
    final wantPages = host != AppHost.railway &&
        (doc['cloudflare'] != null || mode == DeployMode.split);
    if (wantPages) {
      final m = _map(doc['cloudflare']);
      cf = CloudflareConfig(
        project: m['project']?.toString() ?? name,
        branch: m['branch']?.toString() ?? 'main',
      );
    }

    final dbMap = _map(doc['database']);
    final provider =
        DatabaseConfig.parseProvider(dbMap['provider']?.toString());
    SqliteConfig? sqlite;
    FlyPostgresConfig? flyPg;
    NeonConfig? neon;
    // railwayPg declared below with provider branch
    if (provider == DatabaseProvider.sqlite) {
      final s = _map(dbMap['sqlite']);
      final vol = _map(s['volume']);
      sqlite = SqliteConfig(
        path: s['path']?.toString() ?? '/data/serverpod.db',
        volumeCreate: vol['create'] != false,
        volumeName: vol['name']?.toString(),
        volumeSizeGb: int.tryParse('${vol['size_gb'] ?? 1}') ?? 1,
        volumeDest: vol['dest']?.toString() ?? '/data',
      );
    }
    if (provider == DatabaseProvider.flyPostgres) {
      final f = _map(dbMap['fly_postgres']);
      flyPg = FlyPostgresConfig(
        app: f['app']?.toString() ?? '$name-db',
        create: f['create'] != false,
      );
    }
    if (provider == DatabaseProvider.neon) {
      final n = _map(dbMap['neon']);
      neon = NeonConfig(
        connectionStringSecret:
            n['connection_string_secret']?.toString() ?? 'DATABASE_URL',
        provision: n['provision'] == true,
        projectName: n['project_name']?.toString(),
        region: n['region']?.toString() ?? 'aws-us-east-1',
        host: n['host']?.toString(),
        database: n['database']?.toString() ?? 'neondb',
        user: n['user']?.toString() ?? 'neondb_owner',
      );
    }
    RailwayPostgresConfig? railwayPg;
    if (provider == DatabaseProvider.railwayPostgres) {
      final r = _map(dbMap['railway_postgres']);
      railwayPg = RailwayPostgresConfig(
        service: r['service']?.toString() ?? 'Postgres',
        create: r['create'] != false,
        connectionStringSecret:
            r['connection_string_secret']?.toString() ?? 'DATABASE_URL',
      );
    }

    final webMap = _map(doc['web']);
    final sanitized = name.replaceAll('_', '-');
    final defaultApiUrl = host.adapter.defaultApiUrl(
      name: name,
      sanitizedName: flyMap['app']?.toString() ?? sanitized,
    );
    final apiUrl = webMap['api_url']?.toString() ?? defaultApiUrl;
    final web = WebConfig(
      enabled: webMap['enabled'] != false,
      serverUrlDefine:
          webMap['server_url_define']?.toString() ?? 'SERVER_URL',
      apiUrl: apiUrl,
      patchBootstrap: webMap['patch_bootstrap'] != false,
      writeHeaders: webMap['write_headers'] != false,
      baseHref: webMap['base_href']?.toString() ?? '/',
      staticDir: webMap['static_dir']?.toString(),
    );

    SmokeConfig? smoke;
    if (doc['smoke'] != null) {
      final sm = _map(doc['smoke']);
      SmokeEndpoint? api;
      SmokeEndpoint? webEp;
      if (sm['api'] != null) {
        final a = _map(sm['api']);
        api = SmokeEndpoint(
          method: a['method']?.toString() ?? 'GET',
          path: a['path']?.toString() ?? '/',
          body: a['body']?.toString(),
          expectStatus: int.tryParse('${a['expect_status'] ?? 200}') ?? 200,
        );
      }
      if (sm['web'] != null) {
        final w = _map(sm['web']);
        webEp = SmokeEndpoint(
          method: w['method']?.toString() ?? 'GET',
          path: w['path']?.toString() ?? '/',
          expectStatus: int.tryParse('${w['expect_status'] ?? 200}') ?? 200,
        );
      }
      smoke = SmokeConfig(api: api, web: webEp);
    }

    return PodflyConfig(
      root: root,
      host: host,
      mode: mode,
      name: name,
      server: server,
      flutter: flutter,
      fly: fly,
      railway: railway,
      cloudflare: cf,
      database: DatabaseConfig(
        provider: provider,
        sqlite: sqlite,
        flyPostgres: flyPg,
        neon: neon,
        railwayPostgres: railwayPg,
      ),
      web: web,
      smoke: smoke,
    );
  }

  static YamlMap _map(Object? v) {
    if (v is YamlMap) return v;
    return YamlMap();
  }

  /// Walk up from [start] looking for podfly.yaml.
  static Future<String?> findConfigPath(String start) async {
    var dir = Directory(p.normalize(start));
    while (true) {
      final candidate = p.join(dir.path, 'podfly.yaml');
      if (await File(candidate).exists()) return candidate;
      final parent = dir.parent;
      if (parent.path == dir.path) return null;
      dir = parent;
    }
  }
}
