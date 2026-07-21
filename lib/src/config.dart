import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'hosts/hosts.dart';

/// How UI is packaged relative to the API host.
///
/// - [split]: Flutter web on a CDN (e.g. Pages); API on [AppHost]
/// - [monolith]: UI with the API host (or API-only) — no separate Pages deploy
///
/// YAML: `mode: monolith` (preferred). Alias: `mode: fly` (legacy).
enum DeployMode { split, monolith }

/// Parse `mode:` from podfly.yaml or CLI. Defaults to [DeployMode.split].
DeployMode parseDeployMode(String? raw) {
  final s = raw?.trim().toLowerCase();
  if (s == null || s.isEmpty) return DeployMode.split;
  return switch (s) {
    'split' => DeployMode.split,
    // Preferred name
    'monolith' || 'mono' || 'all-in-one' || 'all_in_one' => DeployMode.monolith,
    // Legacy (pre-0.2): mode was named after the original Fly all-in-one path
    'fly' => DeployMode.monolith,
    _ => DeployMode.split,
  };
}

extension DeployModeX on DeployMode {
  /// Canonical YAML / CLI value written by podfly.
  String get yamlName => this == DeployMode.split ? 'split' : 'monolith';
}

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

enum DatabaseProvider {
  none,
  sqlite,
  flyPostgres,
  neon,
  railwayPostgres,
  digitalOceanPostgres,
  renderPostgres,
}

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

/// Google Cloud Run (serverless API).
///
/// Inexpensive stateless path — not GCE/Terraform. Optional Cloud SQL
/// instances attach via [cloudSqlInstances] (unix socket in production.yaml).
class CloudRunConfig {
  CloudRunConfig({
    required this.service,
    this.project,
    this.region = 'us-central1',
    this.allowUnauthenticated = true,
    this.memory = '1Gi',
    this.cpu = '1',
    this.port = 8080,
    this.minInstances = 0,
    this.maxInstances = 10,
    this.timeoutSeconds = 300,
    this.sessionAffinity = false,
    this.cloudSqlInstances = const [],
    this.extraEnv = const {},
    this.publicHost,
  });

  final String service;
  /// GCP project id; falls back to `gcloud config get-value project`.
  final String? project;
  final String region;
  final bool allowUnauthenticated;
  final String memory;
  final String cpu;
  final int port;
  final int minInstances;
  final int maxInstances;
  /// Request timeout (Cloud Run max 3600). Raise for long WebSocket streams.
  final int timeoutSeconds;
  /// Sticky sessions — recommended for WebSockets when max_instances > 1.
  final bool sessionAffinity;
  /// e.g. `my-project:us-central1:my-sql` for Cloud SQL Auth Proxy socket.
  final List<String> cloudSqlInstances;
  final Map<String, String> extraEnv;
  final String? publicHost;

  Map<String, Object?> toMap() => {
        'service': service,
        if (project != null) 'project': project,
        'region': region,
        'allow_unauthenticated': allowUnauthenticated,
        'memory': memory,
        'cpu': cpu,
        'port': port,
        'min_instances': minInstances,
        'max_instances': maxInstances,
        'timeout_seconds': timeoutSeconds,
        'session_affinity': sessionAffinity,
        if (cloudSqlInstances.isNotEmpty)
          'cloud_sql_instances': cloudSqlInstances,
        if (extraEnv.isNotEmpty) 'env': extraEnv,
        if (publicHost != null) 'public_host': publicHost,
      };
}

/// Render Postgres settings.
class RenderPostgresConfig {
  RenderPostgresConfig({
    required this.name,
    this.create = true,
    this.plan = 'free',
    this.region = 'oregon',
    this.databaseId,
  });

  final String name;
  final bool create;
  final String plan;
  final String region;
  /// Filled after create / lookup (`dpg-…`).
  final String? databaseId;

  Map<String, Object?> toMap() => {
        'name': name,
        'create': create,
        'plan': plan,
        'region': region,
        if (databaseId != null) 'database_id': databaseId,
      };
}

/// Render web service settings (git + Docker; monorepo via [rootDir]).
class RenderConfig {
  RenderConfig({
    required this.service,
    this.region = 'oregon',
    this.plan = 'free',
    this.branch = 'main',
    this.repo,
    this.rootDir,
    this.dockerfilePath,
    this.blueprint = 'render.yaml',
    this.serviceId,
    this.publicHost,
    this.webService,
    this.webServiceId,
    this.webPublicHost,
    this.siteDir = 'site',
  });

  final String service;
  final String region;
  /// Instance plan slug (e.g. free, starter).
  final String plan;
  final String branch;
  /// Git repo URL Render builds from (required for deploy).
  final String? repo;
  /// Monorepo root directory for this service (e.g. `render/api_postgres`).
  final String? rootDir;
  /// Dockerfile path relative to [rootDir] (or repo root). Default: server Dockerfile.
  final String? dockerfilePath;
  final String blueprint;
  final String? serviceId;
  final String? publicHost;
  /// Static site service name (Flutter web). Defaults to `{service}-web`.
  final String? webService;
  final String? webServiceId;
  final String? webPublicHost;
  /// Directory under monorepo leaf with published Flutter web (git-synced).
  final String siteDir;

  String get webServiceName =>
      webService ?? '${sanitizeLike(service)}-web';

  /// DNS-friendly name helper without importing fly_name (hyphens).
  static String sanitizeLike(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]+'), '-');

  Map<String, Object?> toMap() => {
        'service': service,
        'region': region,
        'plan': plan,
        'branch': branch,
        if (repo != null) 'repo': repo,
        if (rootDir != null) 'root_dir': rootDir,
        if (dockerfilePath != null) 'dockerfile_path': dockerfilePath,
        'blueprint': blueprint,
        if (serviceId != null) 'service_id': serviceId,
        if (publicHost != null) 'public_host': publicHost,
        if (webService != null) 'web_service': webService,
        if (webServiceId != null) 'web_service_id': webServiceId,
        if (webPublicHost != null) 'web_public_host': webPublicHost,
        'site_dir': siteDir,
      };

  RenderConfig copyWith({
    String? service,
    String? region,
    String? plan,
    String? branch,
    String? repo,
    String? rootDir,
    String? dockerfilePath,
    String? blueprint,
    String? serviceId,
    String? publicHost,
    String? webService,
    String? webServiceId,
    String? webPublicHost,
    String? siteDir,
  }) =>
      RenderConfig(
        service: service ?? this.service,
        region: region ?? this.region,
        plan: plan ?? this.plan,
        branch: branch ?? this.branch,
        repo: repo ?? this.repo,
        rootDir: rootDir ?? this.rootDir,
        dockerfilePath: dockerfilePath ?? this.dockerfilePath,
        blueprint: blueprint ?? this.blueprint,
        serviceId: serviceId ?? this.serviceId,
        publicHost: publicHost ?? this.publicHost,
        webService: webService ?? this.webService,
        webServiceId: webServiceId ?? this.webServiceId,
        webPublicHost: webPublicHost ?? this.webPublicHost,
        siteDir: siteDir ?? this.siteDir,
      );
}

/// DigitalOcean Managed Postgres (DBaaS) for App Platform apps.
class DigitalOceanPostgresConfig {
  DigitalOceanPostgresConfig({
    this.clusterName,
    this.create = true,
    this.region = 'nyc1',
    this.size = 'db-amd-1vcpu-1gb',
    this.engineVersion = '16',
    this.clusterId,
  });

  final String? clusterName;
  final bool create;
  final String region;
  /// Preferred size slug; podfly falls back if unavailable.
  final String size;
  final String engineVersion;
  /// Filled after create / lookup.
  final String? clusterId;

  Map<String, Object?> toMap() => {
        if (clusterName != null) 'cluster_name': clusterName,
        'create': create,
        'region': region,
        'size': size,
        'engine_version': engineVersion,
        if (clusterId != null) 'cluster_id': clusterId,
      };
}

/// DigitalOcean App Platform settings.
class DigitalOceanConfig {
  DigitalOceanConfig({
    required this.app,
    this.region = 'nyc',
    this.registry,
    this.appId,
    this.webAppId,
    this.publicHost,
    this.webPublicHost,
    this.httpPort = 8080,
    this.instanceSize = 'basic-xxs',
    this.imageTag = 'latest',
    this.apiRepository,
    this.webRepository,
    this.specFile = 'do-app.yaml',
    this.platform = 'linux/amd64',
  });

  final String app;
  /// App Platform region slug (e.g. nyc, fra, sfo).
  final String region;
  /// DOCR registry name (from `doctl registry get`).
  final String? registry;
  final String? appId;
  final String? webAppId;
  final String? publicHost;
  final String? webPublicHost;
  final int httpPort;
  final String instanceSize;
  final String imageTag;
  final String? apiRepository;
  final String? webRepository;
  final String specFile;
  /// Docker build platform for DO (amd64).
  final String platform;

  String? get publicUrl {
    final h = publicHost;
    if (h == null || h.isEmpty) return null;
    return h.startsWith('http') ? h : 'https://$h';
  }

  Map<String, Object?> toMap() => {
        'app': app,
        'region': region,
        if (registry != null) 'registry': registry,
        if (appId != null) 'app_id': appId,
        if (webAppId != null) 'web_app_id': webAppId,
        if (publicHost != null) 'public_host': publicHost,
        if (webPublicHost != null) 'web_public_host': webPublicHost,
        'http_port': httpPort,
        'instance_size': instanceSize,
        'image_tag': imageTag,
        if (apiRepository != null) 'api_repository': apiRepository,
        if (webRepository != null) 'web_repository': webRepository,
        'spec_file': specFile,
        'platform': platform,
      };
}

class DatabaseConfig {
  DatabaseConfig({
    required this.provider,
    this.sqlite,
    this.flyPostgres,
    this.neon,
    this.railwayPostgres,
    this.digitalOceanPostgres,
    this.renderPostgres,
  });

  final DatabaseProvider provider;
  final SqliteConfig? sqlite;
  final FlyPostgresConfig? flyPostgres;
  final NeonConfig? neon;
  final RailwayPostgresConfig? railwayPostgres;
  final DigitalOceanPostgresConfig? digitalOceanPostgres;
  final RenderPostgresConfig? renderPostgres;

  Map<String, Object?> toMap() {
    final m = <String, Object?>{'provider': _providerName(provider)};
    if (sqlite != null) m['sqlite'] = sqlite!.toMap();
    if (flyPostgres != null) m['fly_postgres'] = flyPostgres!.toMap();
    if (neon != null) m['neon'] = neon!.toMap();
    if (railwayPostgres != null) {
      m['railway_postgres'] = railwayPostgres!.toMap();
    }
    if (digitalOceanPostgres != null) {
      m['digitalocean_postgres'] = digitalOceanPostgres!.toMap();
    }
    if (renderPostgres != null) {
      m['render_postgres'] = renderPostgres!.toMap();
    }
    return m;
  }

  static String _providerName(DatabaseProvider p) => switch (p) {
        DatabaseProvider.none => 'none',
        DatabaseProvider.sqlite => 'sqlite',
        DatabaseProvider.flyPostgres => 'fly_postgres',
        DatabaseProvider.neon => 'neon',
        DatabaseProvider.railwayPostgres => 'railway_postgres',
        DatabaseProvider.digitalOceanPostgres => 'digitalocean_postgres',
        DatabaseProvider.renderPostgres => 'render_postgres',
      };

  static DatabaseProvider parseProvider(String? s) => switch (s) {
        null || 'none' => DatabaseProvider.none,
        'sqlite' => DatabaseProvider.sqlite,
        'fly_postgres' || 'fly-postgres' || 'postgres' =>
          DatabaseProvider.flyPostgres,
        'neon' => DatabaseProvider.neon,
        'railway_postgres' || 'railway-postgres' || 'railway' =>
          DatabaseProvider.railwayPostgres,
        'digitalocean_postgres' ||
        'digitalocean-postgres' ||
        'do_postgres' ||
        'do-postgres' =>
          DatabaseProvider.digitalOceanPostgres,
        'render_postgres' || 'render-postgres' || 'render' =>
          DatabaseProvider.renderPostgres,
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
    this.digitalOcean,
    this.render,
    this.cloudRun,
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
  final DigitalOceanConfig? digitalOcean;
  final RenderConfig? render;
  final CloudRunConfig? cloudRun;
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
        'mode': mode.yamlName,
        'name': name,
        'server': server,
        'flutter': flutter,
        'fly': fly.toMap(),
        if (railway != null) 'railway': railway!.toMap(),
        if (digitalOcean != null) 'digitalocean': digitalOcean!.toMap(),
        if (render != null) 'render': render!.toMap(),
        if (cloudRun != null) 'cloud_run': cloudRun!.toMap(),
        if (cloudflare != null) 'cloudflare': cloudflare!.toMap(),
        'database': database.toMap(),
        'web': web.toMap(),
        if (smoke != null) 'smoke': smoke!.toMap(),
      };

  String toYaml() {
    final buf = StringBuffer();
    buf.writeln('# Generated by podfly — edit freely');
    buf.writeln('host: ${host.yamlName}  # API cloud: fly | railway | render | …');
    buf.writeln('mode: ${mode.yamlName}');
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
    if (host == AppHost.digitalOcean || digitalOcean != null) {
      final d = digitalOcean ??
          DigitalOceanConfig(app: name.replaceAll('_', '-'));
      buf.writeln('digitalocean:');
      buf.writeln('  app: ${d.app}');
      buf.writeln('  region: ${d.region}');
      if (d.registry != null) buf.writeln('  registry: ${d.registry}');
      if (d.appId != null) buf.writeln('  app_id: ${d.appId}');
      if (d.webAppId != null) buf.writeln('  web_app_id: ${d.webAppId}');
      if (d.publicHost != null) {
        buf.writeln('  public_host: ${d.publicHost}');
      }
      if (d.webPublicHost != null) {
        buf.writeln('  web_public_host: ${d.webPublicHost}');
      }
      buf.writeln('  http_port: ${d.httpPort}');
      buf.writeln('  instance_size: ${d.instanceSize}');
      buf.writeln('  image_tag: ${d.imageTag}');
      buf.writeln('  spec_file: ${d.specFile}');
      buf.writeln('  platform: ${d.platform}');
    }
    if (host == AppHost.render || render != null) {
      final r = render ??
          RenderConfig(service: name.replaceAll('_', '-'));
      buf.writeln('render:');
      buf.writeln('  service: ${r.service}');
      buf.writeln('  region: ${r.region}');
      buf.writeln('  plan: ${r.plan}');
      buf.writeln('  branch: ${r.branch}');
      if (r.repo != null) buf.writeln('  repo: ${r.repo}');
      if (r.rootDir != null) buf.writeln('  root_dir: ${r.rootDir}');
      if (r.dockerfilePath != null) {
        buf.writeln('  dockerfile_path: ${r.dockerfilePath}');
      }
      buf.writeln('  blueprint: ${r.blueprint}');
      if (r.serviceId != null) buf.writeln('  service_id: ${r.serviceId}');
      if (r.publicHost != null) {
        buf.writeln('  public_host: ${r.publicHost}');
      }
      if (r.webService != null) {
        buf.writeln('  web_service: ${r.webService}');
      }
      if (r.webServiceId != null) {
        buf.writeln('  web_service_id: ${r.webServiceId}');
      }
      if (r.webPublicHost != null) {
        buf.writeln('  web_public_host: ${r.webPublicHost}');
      }
      buf.writeln('  site_dir: ${r.siteDir}');
    }
    if (host == AppHost.cloudRun || cloudRun != null) {
      final c = cloudRun ??
          CloudRunConfig(service: name.replaceAll('_', '-'));
      buf.writeln('cloud_run:');
      buf.writeln('  service: ${c.service}');
      if (c.project != null) buf.writeln('  project: ${c.project}');
      buf.writeln('  region: ${c.region}');
      buf.writeln('  allow_unauthenticated: ${c.allowUnauthenticated}');
      buf.writeln('  memory: ${c.memory}');
      buf.writeln('  cpu: ${c.cpu}');
      buf.writeln('  port: ${c.port}');
      buf.writeln('  min_instances: ${c.minInstances}');
      buf.writeln('  max_instances: ${c.maxInstances}');
      buf.writeln('  timeout_seconds: ${c.timeoutSeconds}');
      buf.writeln('  session_affinity: ${c.sessionAffinity}');
      if (c.cloudSqlInstances.isNotEmpty) {
        buf.writeln(
          '  cloud_sql_instances: [${c.cloudSqlInstances.map((e) => '"$e"').join(', ')}]',
        );
      }
      if (c.publicHost != null) {
        buf.writeln('  public_host: ${c.publicHost}');
      }
    }
    // Cloudflare only when UI is on Pages (not native API hosts)
    if (cloudflare != null &&
        host != AppHost.railway &&
        host != AppHost.digitalOcean &&
        host != AppHost.render &&
        host != AppHost.cloudRun) {
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
    if (database.digitalOceanPostgres != null) {
      final d = database.digitalOceanPostgres!;
      buf.writeln('  digitalocean_postgres:');
      if (d.clusterName != null) {
        buf.writeln('    cluster_name: ${d.clusterName}');
      }
      buf.writeln('    create: ${d.create}');
      buf.writeln('    region: ${d.region}');
      buf.writeln('    size: ${d.size}');
      buf.writeln('    engine_version: ${d.engineVersion}');
      if (d.clusterId != null) {
        buf.writeln('    cluster_id: ${d.clusterId}');
      }
    }
    if (database.renderPostgres != null) {
      final r = database.renderPostgres!;
      buf.writeln('  render_postgres:');
      buf.writeln('    name: ${r.name}');
      buf.writeln('    create: ${r.create}');
      buf.writeln('    plan: ${r.plan}');
      buf.writeln('    region: ${r.region}');
      if (r.databaseId != null) {
        buf.writeln('    database_id: ${r.databaseId}');
      }
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
    final mode = parseDeployMode(doc['mode']?.toString());
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

    DigitalOceanConfig? digitalOcean;
    if (doc['digitalocean'] != null || host == AppHost.digitalOcean) {
      final m = _map(doc['digitalocean']);
      digitalOcean = DigitalOceanConfig(
        app: m['app']?.toString() ?? name.replaceAll('_', '-'),
        region: m['region']?.toString() ?? 'nyc',
        registry: m['registry']?.toString(),
        appId: m['app_id']?.toString(),
        webAppId: m['web_app_id']?.toString(),
        publicHost: m['public_host']?.toString(),
        webPublicHost: m['web_public_host']?.toString(),
        httpPort: int.tryParse('${m['http_port'] ?? 8080}') ?? 8080,
        instanceSize: m['instance_size']?.toString() ?? 'basic-xxs',
        imageTag: m['image_tag']?.toString() ?? 'latest',
        apiRepository: m['api_repository']?.toString(),
        webRepository: m['web_repository']?.toString(),
        specFile: m['spec_file']?.toString() ?? 'do-app.yaml',
        platform: m['platform']?.toString() ?? 'linux/amd64',
      );
    }

    RenderConfig? render;
    if (doc['render'] != null || host == AppHost.render) {
      final m = _map(doc['render']);
      render = RenderConfig(
        service: m['service']?.toString() ?? name.replaceAll('_', '-'),
        region: m['region']?.toString() ?? 'oregon',
        plan: m['plan']?.toString() ?? 'free',
        branch: m['branch']?.toString() ?? 'main',
        repo: m['repo']?.toString(),
        rootDir: m['root_dir']?.toString(),
        dockerfilePath: m['dockerfile_path']?.toString(),
        blueprint: m['blueprint']?.toString() ?? 'render.yaml',
        serviceId: m['service_id']?.toString(),
        publicHost: m['public_host']?.toString(),
        webService: m['web_service']?.toString(),
        webServiceId: m['web_service_id']?.toString(),
        webPublicHost: m['web_public_host']?.toString(),
        siteDir: m['site_dir']?.toString() ?? 'site',
      );
    }

    CloudRunConfig? cloudRun;
    if (doc['cloud_run'] != null ||
        doc['cloudrun'] != null ||
        host == AppHost.cloudRun) {
      final m = _map(doc['cloud_run'] ?? doc['cloudrun']);
      final sqlRaw = m['cloud_sql_instances'];
      final sqlList = <String>[];
      if (sqlRaw is YamlList) {
        for (final e in sqlRaw) {
          sqlList.add(e.toString());
        }
      } else if (sqlRaw is String && sqlRaw.isNotEmpty) {
        sqlList.addAll(sqlRaw.split(',').map((s) => s.trim()));
      }
      final envMap = <String, String>{};
      final envRaw = m['env'];
      if (envRaw is YamlMap) {
        for (final e in envRaw.entries) {
          envMap[e.key.toString()] = e.value?.toString() ?? '';
        }
      }
      cloudRun = CloudRunConfig(
        service: m['service']?.toString() ?? name.replaceAll('_', '-'),
        project: m['project']?.toString(),
        region: m['region']?.toString() ?? 'us-central1',
        allowUnauthenticated: m['allow_unauthenticated'] != false,
        memory: m['memory']?.toString() ?? '1Gi',
        cpu: m['cpu']?.toString() ?? '1',
        port: int.tryParse('${m['port'] ?? 8080}') ?? 8080,
        minInstances: int.tryParse('${m['min_instances'] ?? 0}') ?? 0,
        maxInstances: int.tryParse('${m['max_instances'] ?? 10}') ?? 10,
        timeoutSeconds: int.tryParse('${m['timeout_seconds'] ?? 300}') ?? 300,
        sessionAffinity: m['session_affinity'] == true,
        cloudSqlInstances: sqlList,
        extraEnv: envMap,
        publicHost: m['public_host']?.toString(),
      );
    }

    CloudflareConfig? cf;
    // Pages UI for Fly split; native API hosts skip Pages.
    final wantPages = host != AppHost.railway &&
        host != AppHost.digitalOcean &&
        host != AppHost.render &&
        host != AppHost.cloudRun &&
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
    DigitalOceanPostgresConfig? doPg;
    if (provider == DatabaseProvider.digitalOceanPostgres) {
      final d = _map(dbMap['digitalocean_postgres']);
      doPg = DigitalOceanPostgresConfig(
        clusterName: d['cluster_name']?.toString() ??
            '${name.replaceAll('_', '-')}-db',
        create: d['create'] != false,
        region: d['region']?.toString() ?? 'nyc1',
        size: d['size']?.toString() ?? 'db-amd-1vcpu-1gb',
        engineVersion: d['engine_version']?.toString() ?? '16',
        clusterId: d['cluster_id']?.toString(),
      );
    }
    RenderPostgresConfig? renderPg;
    if (provider == DatabaseProvider.renderPostgres) {
      final r = _map(dbMap['render_postgres']);
      renderPg = RenderPostgresConfig(
        name: r['name']?.toString() ?? '${name.replaceAll('_', '-')}-db',
        create: r['create'] != false,
        plan: r['plan']?.toString() ?? 'free',
        region: r['region']?.toString() ??
            render?.region ??
            'oregon',
        databaseId: r['database_id']?.toString(),
      );
    }

    final webMap = _map(doc['web']);
    final sanitized = name.replaceAll('_', '-');
    final defaultApiUrl = host.adapter.defaultApiUrl(
      name: name,
      sanitizedName: cloudRun?.service ??
          render?.service ??
          digitalOcean?.app ??
          flyMap['app']?.toString() ??
          sanitized,
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
      digitalOcean: digitalOcean,
      render: render,
      cloudRun: cloudRun,
      cloudflare: cf,
      database: DatabaseConfig(
        provider: provider,
        sqlite: sqlite,
        flyPostgres: flyPg,
        neon: neon,
        railwayPostgres: railwayPg,
        digitalOceanPostgres: doPg,
        renderPostgres: renderPg,
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
