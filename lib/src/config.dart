import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

enum DeployMode { split, fly }

/// Where the Serverpod **API** container runs.
enum AppHost {
  fly,
  railway,
  render,
  cloudRun,
  aws,
  azure,
  digitalOcean,
}

enum DatabaseProvider { none, sqlite, flyPostgres, neon }

extension AppHostX on AppHost {
  String get yamlName => switch (this) {
        AppHost.fly => 'fly',
        AppHost.railway => 'railway',
        AppHost.render => 'render',
        AppHost.cloudRun => 'cloud_run',
        AppHost.aws => 'aws',
        AppHost.azure => 'azure',
        AppHost.digitalOcean => 'digitalocean',
      };

  String get label => switch (this) {
        AppHost.fly => 'Fly.io',
        AppHost.railway => 'Railway',
        AppHost.render => 'Render',
        AppHost.cloudRun => 'Google Cloud Run',
        AppHost.aws => 'AWS (App Runner / ECS)',
        AppHost.azure => 'Azure Container Apps',
        AppHost.digitalOcean => 'DigitalOcean App Platform',
      };

  /// CLI binary names to check (first found wins for multi-name tools).
  List<String> get cliBinaries => switch (this) {
        AppHost.fly => ['fly', 'flyctl'],
        AppHost.railway => ['railway'],
        AppHost.render => ['render'],
        AppHost.cloudRun => ['gcloud'],
        AppHost.aws => ['aws'],
        AppHost.azure => ['az'],
        AppHost.digitalOcean => ['doctl'],
      };

  String get installHint => switch (this) {
        AppHost.fly => 'https://fly.io/docs/hands-on/install-flyctl/',
        AppHost.railway => 'https://docs.railway.app/guides/cli',
        AppHost.render => 'https://render.com/docs/cli',
        AppHost.cloudRun => 'https://cloud.google.com/sdk/docs/install',
        AppHost.aws => 'https://docs.aws.amazon.com/cli/',
        AppHost.azure => 'https://learn.microsoft.com/cli/azure/install-azure-cli',
        AppHost.digitalOcean => 'https://docs.digitalocean.com/reference/doctl/',
      };

  /// Deploy implemented in podfly today.
  bool get isImplemented => this == AppHost.fly || this == AppHost.railway;

  static AppHost parse(String? s) => switch (s) {
        null || 'fly' => AppHost.fly,
        'railway' => AppHost.railway,
        'render' => AppHost.render,
        'cloud_run' || 'cloudrun' || 'gcp' || 'google' => AppHost.cloudRun,
        'aws' => AppHost.aws,
        'azure' => AppHost.azure,
        'digitalocean' || 'do' => AppHost.digitalOcean,
        _ => throw FormatException('Unknown host/provider: $s'),
      };
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

/// Railway project / service for the Serverpod API.
class RailwayConfig {
  RailwayConfig({
    required this.project,
    this.service = 'api',
    this.environment = 'production',
    this.projectId,
    this.port = 8080,
    this.config = 'railway.toml',
    this.publicHost,
  });

  /// Human project name (used when creating / as default).
  final String project;
  final String service;
  final String environment;
  /// Railway project UUID when known (skips name-based create).
  final String? projectId;
  /// Internal container port Serverpod listens on (domain targets this).
  final int port;
  /// Config-as-code file at monorepo root (dockerfile path).
  final String config;
  /// e.g. `xxx.up.railway.app` once domain exists.
  final String? publicHost;

  Map<String, Object?> toMap() => {
        'project': project,
        'service': service,
        'environment': environment,
        if (projectId != null) 'project_id': projectId,
        'port': port,
        'config': config,
        if (publicHost != null) 'public_host': publicHost,
      };

  String? get publicUrl {
    final h = publicHost;
    if (h == null || h.isEmpty) return null;
    final host = h.replaceFirst(RegExp(r'^https?://'), '').split('/').first;
    return 'https://$host/';
  }
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
  });

  final DatabaseProvider provider;
  final SqliteConfig? sqlite;
  final FlyPostgresConfig? flyPostgres;
  final NeonConfig? neon;

  Map<String, Object?> toMap() {
    final m = <String, Object?>{'provider': _providerName(provider)};
    if (sqlite != null) m['sqlite'] = sqlite!.toMap();
    if (flyPostgres != null) m['fly_postgres'] = flyPostgres!.toMap();
    if (neon != null) m['neon'] = neon!.toMap();
    return m;
  }

  static String _providerName(DatabaseProvider p) => switch (p) {
        DatabaseProvider.none => 'none',
        DatabaseProvider.sqlite => 'sqlite',
        DatabaseProvider.flyPostgres => 'fly_postgres',
        DatabaseProvider.neon => 'neon',
      };

  static DatabaseProvider parseProvider(String? s) => switch (s) {
        null || 'none' => DatabaseProvider.none,
        'sqlite' => DatabaseProvider.sqlite,
        'fly_postgres' || 'fly-postgres' || 'postgres' =>
          DatabaseProvider.flyPostgres,
        'neon' => DatabaseProvider.neon,
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
    if (host == AppHost.railway) {
      final u = railway?.publicUrl;
      if (u != null) return u;
      // Placeholder until domain is provisioned.
      return web.apiUrlNormalized;
    }
    if (host == AppHost.fly) {
      return 'https://${fly.app}.fly.dev/';
    }
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
      buf.writeln('  environment: ${r.environment}');
      if (r.projectId != null) {
        buf.writeln('  project_id: ${r.projectId}');
      }
      buf.writeln('  port: ${r.port}');
      buf.writeln('  config: ${r.config}');
      if (r.publicHost != null) {
        buf.writeln('  public_host: ${r.publicHost}');
      }
    }
    if (cloudflare != null) {
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
        environment: m['environment']?.toString() ?? 'production',
        projectId: m['project_id']?.toString(),
        port: int.tryParse('${m['port'] ?? 8080}') ?? 8080,
        config: m['config']?.toString() ?? 'railway.toml',
        publicHost: m['public_host']?.toString(),
      );
    }

    CloudflareConfig? cf;
    // Split mode still uses Pages for UI (Fly or Railway API).
    if (doc['cloudflare'] != null || mode == DeployMode.split) {
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

    final webMap = _map(doc['web']);
    final defaultApiUrl = host == AppHost.railway
        ? (railway?.publicUrl ?? 'https://REPLACE.up.railway.app/')
        : 'https://${fly.app}.fly.dev/';
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
