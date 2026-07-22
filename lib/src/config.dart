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
  awsEcs,
  azure,
  hetzner,
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

/// Where Flutter web static is hosted when [DeployMode.split] and the API host
/// does not deploy web natively (not Railway/DO/Render monolith paths).
enum StaticWebHost {
  cloudflare,
  vercel,
  netlify,
  githubPages,
}

extension StaticWebHostX on StaticWebHost {
  String get yamlName => switch (this) {
        StaticWebHost.cloudflare => 'cloudflare',
        StaticWebHost.vercel => 'vercel',
        StaticWebHost.netlify => 'netlify',
        StaticWebHost.githubPages => 'github_pages',
      };

  String get label => switch (this) {
        StaticWebHost.cloudflare => 'Cloudflare Pages',
        StaticWebHost.vercel => 'Vercel',
        StaticWebHost.netlify => 'Netlify',
        StaticWebHost.githubPages => 'GitHub Pages',
      };

  List<String> get cliBinaries => switch (this) {
        StaticWebHost.cloudflare => const ['wrangler'],
        StaticWebHost.vercel => const ['vercel'],
        StaticWebHost.netlify => const ['netlify'],
        StaticWebHost.githubPages => const ['gh'],
      };

  String get installHint => switch (this) {
        StaticWebHost.cloudflare =>
          'https://developers.cloudflare.com/workers/wrangler/install-and-update/',
        StaticWebHost.vercel => 'npm i -g vercel  (https://vercel.com/docs/cli)',
        StaticWebHost.netlify =>
          'npm i -g netlify-cli  (https://docs.netlify.com/cli/get-started/)',
        StaticWebHost.githubPages =>
          'https://cli.github.com/  (brew install gh && gh auth login)',
      };

  static StaticWebHost parse(String? s) {
    final v = s?.trim().toLowerCase();
    if (v == null || v.isEmpty || v == 'cloudflare' || v == 'pages' || v == 'cf') {
      return StaticWebHost.cloudflare;
    }
    if (v == 'vercel' || v == 'vc') return StaticWebHost.vercel;
    if (v == 'netlify' || v == 'ntl') return StaticWebHost.netlify;
    if (v == 'github_pages' ||
        v == 'github' ||
        v == 'gh_pages' ||
        v == 'gh-pages' ||
        v == 'ghp') {
      return StaticWebHost.githubPages;
    }
    throw FormatException(
      'Unknown web_host: $s (use cloudflare, vercel, netlify, or github_pages)',
    );
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

/// Vercel project for Flutter web static (`web_host: vercel`).
class VercelConfig {
  VercelConfig({
    required this.project,
    this.publicHost,
    this.scope,
  });

  /// Vercel project name (`--project`).
  final String project;
  /// e.g. `my-app.vercel.app` after first deploy.
  final String? publicHost;
  /// Optional team / scope (`vercel --scope`).
  final String? scope;

  Map<String, Object?> toMap() => {
        'project': project,
        if (publicHost != null) 'public_host': publicHost,
        if (scope != null) 'scope': scope,
      };
}

/// Netlify site for Flutter web static (`web_host: netlify`).
class NetlifyConfig {
  NetlifyConfig({
    required this.site,
    this.siteId,
    this.publicHost,
    this.team,
  });

  /// Site name (`--site` / `--site-name`). Becomes `https://<site>.netlify.app`.
  final String site;
  /// Stable Netlify site id (preferred for `--site` after first create).
  final String? siteId;
  /// e.g. `my-app.netlify.app` after first deploy.
  final String? publicHost;
  /// Optional team slug (`--team`).
  final String? team;

  Map<String, Object?> toMap() => {
        'site': site,
        if (siteId != null) 'site_id': siteId,
        if (publicHost != null) 'public_host': publicHost,
        if (team != null) 'team': team,
      };
}

/// GitHub Pages site for Flutter web static (`web_host: github_pages`).
///
/// Deploys built assets to a dedicated repo's [branch] (default `gh-pages`)
/// via `git` + `gh`. Project pages URL: `https://<owner>.github.io/<repo>/`.
class GitHubPagesConfig {
  GitHubPagesConfig({
    required this.repo,
    this.owner,
    this.branch = 'gh-pages',
    this.publicHost,
    this.private = false,
  });

  /// Repository name (created if missing).
  final String repo;
  /// GitHub user/org; if null, resolved from `gh api user` at deploy time.
  final String? owner;
  /// Branch published by GitHub Pages (legacy source).
  final String branch;
  /// e.g. `user.github.io/my-repo` (no scheme) after deploy.
  final String? publicHost;
  /// Create repo as private when provisioning (Pages requires public on free
  /// plans for non-enterprise — default public).
  final bool private;

  /// User/org site (`owner.github.io`) vs project site (`owner.github.io/repo`).
  bool get isUserSite {
    final o = owner;
    if (o == null) return false;
    return repo == '$o.github.io';
  }

  /// Suggested Flutter `--base-href` for project pages (trailing slash).
  String suggestedBaseHref(String resolvedOwner) {
    if (repo == '$resolvedOwner.github.io') return '/';
    return '/$repo/';
  }

  /// Public URL host+path without scheme, e.g. `user.github.io/repo`.
  String defaultPublicHost(String resolvedOwner) {
    if (repo == '$resolvedOwner.github.io') return '$resolvedOwner.github.io';
    return '$resolvedOwner.github.io/$repo';
  }

  Map<String, Object?> toMap() => {
        'repo': repo,
        if (owner != null) 'owner': owner,
        'branch': branch,
        if (publicHost != null) 'public_host': publicHost,
        if (private) 'private': private,
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
/// AWS ECS Fargate + ALB (`host: aws_ecs`) — WebSocket-capable.
class AwsEcsConfig {
  AwsEcsConfig({
    required this.service,
    this.region = 'us-east-1',
    this.cluster,
    this.cpu = '512',
    this.memory = '1024',
    this.port = 8080,
    this.desiredCount = 1,
    this.ecrRepository,
    this.executionRole = 'podflyEcsTaskExecutionRole',
    this.taskFamily,
    this.logGroup = '/ecs/podfly',
    this.idleTimeoutSeconds = 3600,
    this.stickiness = true,
    this.assignPublicIp = true,
    this.platform = 'linux/amd64',
    this.imageTag = 'latest',
    this.vpcId,
    this.subnetIds = const [],
    this.loadBalancerArn,
    this.targetGroupArn,
    this.extraEnv = const {},
    this.publicHost,
  });

  final String service;
  final String region;
  final String? cluster;
  final String cpu;
  final String memory;
  final int port;
  final int desiredCount;
  final String? ecrRepository;
  final String executionRole;
  final String? taskFamily;
  final String logGroup;
  /// ALB idle timeout (raise for long WebSocket streams; max 4000).
  final int idleTimeoutSeconds;
  final bool stickiness;
  final bool assignPublicIp;
  final String platform;
  final String imageTag;
  final String? vpcId;
  final List<String> subnetIds;
  final String? loadBalancerArn;
  final String? targetGroupArn;
  final Map<String, String> extraEnv;
  final String? publicHost;

  Map<String, Object?> toMap() => {
        'service': service,
        'region': region,
        if (cluster != null) 'cluster': cluster,
        'cpu': cpu,
        'memory': memory,
        'port': port,
        'desired_count': desiredCount,
        if (ecrRepository != null) 'ecr_repository': ecrRepository,
        'execution_role': executionRole,
        if (taskFamily != null) 'task_family': taskFamily,
        'log_group': logGroup,
        'idle_timeout_seconds': idleTimeoutSeconds,
        'stickiness': stickiness,
        'assign_public_ip': assignPublicIp,
        'platform': platform,
        'image_tag': imageTag,
        if (vpcId != null) 'vpc_id': vpcId,
        if (subnetIds.isNotEmpty) 'subnet_ids': subnetIds,
        if (loadBalancerArn != null) 'load_balancer_arn': loadBalancerArn,
        if (targetGroupArn != null) 'target_group_arn': targetGroupArn,
        if (extraEnv.isNotEmpty) 'env': extraEnv,
        if (publicHost != null) 'public_host': publicHost,
      };
}

/// AWS App Runner settings (`host: aws`).
class AwsConfig {
  AwsConfig({
    required this.service,
    this.region = 'us-east-1',
    this.cpu = '1024',
    this.memory = '2048',
    this.port = 8080,
    this.ecrRepository,
    this.ecrAccessRole = 'AppRunnerECRAccessRole',
    this.imageTag = 'latest',
    this.platform = 'linux/amd64',
    this.startCommand = '/app/entrypoint.sh',
    this.ecrPublic = false,
    this.serviceArn,
    this.extraEnv = const {},
    this.publicHost,
  });

  final String service;
  final String region;
  /// App Runner CPU units: `256` | `512` | `1024` | `2048` | `4096`.
  final String cpu;
  /// App Runner memory MB: must pair with [cpu] (e.g. `1024` → `2048`).
  final String memory;
  final int port;
  /// ECR repository name (default: [service]).
  final String? ecrRepository;
  /// IAM role App Runner assumes to pull from private ECR.
  final String ecrAccessRole;
  /// Image tag; `latest` is replaced with a timestamp at deploy for clean rolls.
  final String imageTag;
  final String platform;
  /// App Runner `StartCommand` (overrides image ENTRYPOINT). Empty = omit.
  /// Default matches the Serverpod example `entrypoint.sh`.
  final String startCommand;
  /// When true, push to **ECR Public** and use `ImageRepositoryType: ECR_PUBLIC`
  /// (no access role). More reliable CREATE on some accounts than private ECR.
  final bool ecrPublic;
  /// Filled after first create (`arn:aws:apprunner:…`).
  final String? serviceArn;
  final Map<String, String> extraEnv;
  final String? publicHost;

  Map<String, Object?> toMap() => {
        'service': service,
        'region': region,
        'cpu': cpu,
        'memory': memory,
        'port': port,
        if (ecrRepository != null) 'ecr_repository': ecrRepository,
        'ecr_access_role': ecrAccessRole,
        'image_tag': imageTag,
        'platform': platform,
        if (startCommand.isNotEmpty) 'start_command': startCommand,
        'ecr_public': ecrPublic,
        if (serviceArn != null) 'service_arn': serviceArn,
        if (extraEnv.isNotEmpty) 'env': extraEnv,
        if (publicHost != null) 'public_host': publicHost,
      };
}

/// Hetzner Cloud VPS settings (`host: hetzner`).
///
/// Bind an existing server (`server_id` / `ipv4` / `server_name`) or create
/// one interactively (TTY) / via [create] + location/type policy.
///
/// Hetzner does not give a product FQDN (unlike Fly/ACA). With [https], podfly
/// runs Caddy on :443 using [domain] or the IP's reverse-DNS (PTR) name.
class HetznerConfig {
  HetznerConfig({
    this.serverName,
    this.serverId,
    this.ipv4,
    this.location,
    this.serverType,
    this.image = 'ubuntu-24.04',
    this.sshKey,
    this.sshUser = 'root',
    this.containerName = 'podfly',
    this.port = 8080,
    this.platform = 'linux/amd64',
    this.create = false,
    this.minMemoryGb = 2,
    this.https = true,
    this.domain,
    this.extraEnv = const {},
    this.publicHost,
  });

  /// Human server name (create / lookup).
  final String? serverName;
  /// Hetzner server id after bind/create.
  final String? serverId;
  final String? ipv4;
  /// Preferred location (e.g. `ash`, `hel1`). Empty → interactive / policy.
  final String? location;
  /// Preferred type (e.g. `cpx11`). Empty → interactive / policy.
  final String? serverType;
  /// OS image name (pin Ubuntu for podfly).
  final String image;
  /// hcloud SSH key name or id.
  final String? sshKey;
  final String sshUser;
  /// Docker container name on the VPS.
  final String containerName;
  /// Host port published for the app container (Caddy proxies to this).
  final int port;
  final String platform;
  /// When true and unbound, create a server non-interactively (with `--yes`).
  final bool create;
  /// Minimum RAM (GB) when auto-picking a server type.
  final int minMemoryGb;
  /// Install Caddy + Let's Encrypt on 443 (default true).
  final bool https;
  /// Custom hostname (A/AAAA → server). Empty → use Hetzner PTR hostname.
  final String? domain;
  final Map<String, String> extraEnv;
  /// Public host for API (hostname preferred; else IPv4).
  final String? publicHost;

  Map<String, Object?> toMap() => {
        if (serverName != null) 'server_name': serverName,
        if (serverId != null) 'server_id': serverId,
        if (ipv4 != null) 'ipv4': ipv4,
        if (location != null) 'location': location,
        if (serverType != null) 'server_type': serverType,
        'image': image,
        if (sshKey != null) 'ssh_key': sshKey,
        'ssh_user': sshUser,
        'container_name': containerName,
        'port': port,
        'platform': platform,
        'create': create,
        'min_memory_gb': minMemoryGb,
        'https': https,
        if (domain != null) 'domain': domain,
        if (extraEnv.isNotEmpty) 'env': extraEnv,
        if (publicHost != null) 'public_host': publicHost,
      };
}

/// Azure Container Apps settings (`host: azure`).
class AzureConfig {
  AzureConfig({
    required this.app,
    this.resourceGroup,
    this.location = 'eastus',
    this.environment,
    this.registry,
    this.repository,
    this.cpu = '0.5',
    this.memory = '1.0Gi',
    this.port = 8080,
    this.minReplicas = 0,
    this.maxReplicas = 3,
    this.imageTag = 'latest',
    this.platform = 'linux/amd64',
    this.extraEnv = const {},
    this.publicHost,
  });

  /// Container app name (DNS-ish, &lt; 32 chars).
  final String app;
  /// Resource group (default: `{app}-rg`).
  final String? resourceGroup;
  final String location;
  /// Container Apps managed environment (default: `{app}-env`).
  final String? environment;
  /// ACR name — alphanumeric only, globally unique (default: sanitized [app]).
  final String? registry;
  /// Image repository inside ACR (default: [app]).
  final String? repository;
  /// vCPU cores as string, e.g. `0.25`, `0.5`, `1.0`.
  final String cpu;
  /// Memory with unit, e.g. `0.5Gi`, `1.0Gi`.
  final String memory;
  final int port;
  final int minReplicas;
  final int maxReplicas;
  /// Image tag; `latest` is replaced with a timestamp at deploy.
  final String imageTag;
  final String platform;
  final Map<String, String> extraEnv;
  final String? publicHost;

  Map<String, Object?> toMap() => {
        'app': app,
        if (resourceGroup != null) 'resource_group': resourceGroup,
        'location': location,
        if (environment != null) 'environment': environment,
        if (registry != null) 'registry': registry,
        if (repository != null) 'repository': repository,
        'cpu': cpu,
        'memory': memory,
        'port': port,
        'min_replicas': minReplicas,
        'max_replicas': maxReplicas,
        'image_tag': imageTag,
        'platform': platform,
        if (extraEnv.isNotEmpty) 'env': extraEnv,
        if (publicHost != null) 'public_host': publicHost,
      };
}

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
    this.executionEnvironment = 'gen2',
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
  /// `gen1` or `gen2` (`gcloud run deploy --execution-environment`). Default gen2.
  final String executionEnvironment;
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
        'execution_environment': executionEnvironment,
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
    this.webHost = StaticWebHost.cloudflare,
    required this.mode,
    required this.name,
    required this.server,
    required this.flutter,
    required this.fly,
    this.railway,
    this.digitalOcean,
    this.render,
    this.cloudRun,
    this.aws,
    this.awsEcs,
    this.azure,
    this.hetzner,
    this.cloudflare,
    this.vercel,
    this.netlify,
    this.githubPages,
    required this.database,
    required this.web,
    this.smoke,
  });

  final String root;
  /// Cloud that runs the Serverpod API container.
  final AppHost host;
  /// Static Flutter web CDN when [mode] is split and API host is not web-native.
  final StaticWebHost webHost;
  final DeployMode mode;
  final String name;
  final String server;
  final String flutter;
  final FlyConfig fly;
  final RailwayConfig? railway;
  final DigitalOceanConfig? digitalOcean;
  final RenderConfig? render;
  final CloudRunConfig? cloudRun;
  final AwsConfig? aws;
  final AwsEcsConfig? awsEcs;
  final AzureConfig? azure;
  final HetznerConfig? hetzner;
  final CloudflareConfig? cloudflare;
  final VercelConfig? vercel;
  final NetlifyConfig? netlify;
  final GitHubPagesConfig? githubPages;
  final DatabaseConfig database;
  final WebConfig web;
  final SmokeConfig? smoke;

  /// True when split mode should push Flutter web to a static CDN.
  bool get usesStaticWebHost {
    if (mode != DeployMode.split || !web.enabled) return false;
    // Avoid circular host.adapter during partial construction — check enum set.
    switch (host) {
      case AppHost.railway:
      case AppHost.digitalOcean:
      case AppHost.render:
      case AppHost.cloudRun:
      case AppHost.aws:
      case AppHost.awsEcs:
      case AppHost.azure:
      case AppHost.hetzner:
        return false;
      case AppHost.fly:
        return true;
    }
  }

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
        if (usesStaticWebHost ||
            webHost != StaticWebHost.cloudflare ||
            vercel != null ||
            netlify != null ||
            githubPages != null)
          'web_host': webHost.yamlName,
        'mode': mode.yamlName,
        'name': name,
        'server': server,
        'flutter': flutter,
        'fly': fly.toMap(),
        if (railway != null) 'railway': railway!.toMap(),
        if (digitalOcean != null) 'digitalocean': digitalOcean!.toMap(),
        if (render != null) 'render': render!.toMap(),
        if (cloudRun != null) 'cloud_run': cloudRun!.toMap(),
        if (aws != null) 'aws': aws!.toMap(),
        if (awsEcs != null) 'aws_ecs': awsEcs!.toMap(),
        if (azure != null) 'azure': azure!.toMap(),
        if (hetzner != null) 'hetzner': hetzner!.toMap(),
        if (cloudflare != null) 'cloudflare': cloudflare!.toMap(),
        if (vercel != null) 'vercel': vercel!.toMap(),
        if (netlify != null) 'netlify': netlify!.toMap(),
        if (githubPages != null) 'github_pages': githubPages!.toMap(),
        'database': database.toMap(),
        'web': web.toMap(),
        if (smoke != null) 'smoke': smoke!.toMap(),
      };

  String toYaml() {
    final buf = StringBuffer();
    buf.writeln('# Generated by podfly — edit freely');
    buf.writeln('host: ${host.yamlName}  # API cloud: fly | railway | render | …');
    if (usesStaticWebHost) {
      buf.writeln(
        'web_host: ${webHost.yamlName}  # Flutter static CDN: cloudflare | vercel | netlify | github_pages',
      );
    }
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
      buf.writeln('  execution_environment: ${c.executionEnvironment}');
      if (c.cloudSqlInstances.isNotEmpty) {
        buf.writeln(
          '  cloud_sql_instances: [${c.cloudSqlInstances.map((e) => '"$e"').join(', ')}]',
        );
      }
      if (c.publicHost != null) {
        buf.writeln('  public_host: ${c.publicHost}');
      }
    }
    if (host == AppHost.aws || aws != null) {
      final a = aws ?? AwsConfig(service: name.replaceAll('_', '-'));
      buf.writeln('aws:');
      buf.writeln('  service: ${a.service}');
      buf.writeln('  region: ${a.region}');
      buf.writeln('  cpu: ${a.cpu}');
      buf.writeln('  memory: ${a.memory}');
      buf.writeln('  port: ${a.port}');
      if (a.ecrRepository != null) {
        buf.writeln('  ecr_repository: ${a.ecrRepository}');
      }
      buf.writeln('  ecr_access_role: ${a.ecrAccessRole}');
      buf.writeln('  image_tag: ${a.imageTag}');
      buf.writeln('  platform: ${a.platform}');
      if (a.startCommand.isNotEmpty) {
        buf.writeln('  start_command: ${a.startCommand}');
      }
      buf.writeln('  ecr_public: ${a.ecrPublic}');
      if (a.serviceArn != null) {
        buf.writeln('  service_arn: ${a.serviceArn}');
      }
      if (a.publicHost != null) {
        buf.writeln('  public_host: ${a.publicHost}');
      }
    }
    if (host == AppHost.awsEcs || awsEcs != null) {
      final e = awsEcs ?? AwsEcsConfig(service: name.replaceAll('_', '-'));
      buf.writeln('aws_ecs:');
      buf.writeln('  service: ${e.service}');
      buf.writeln('  region: ${e.region}');
      if (e.cluster != null) buf.writeln('  cluster: ${e.cluster}');
      buf.writeln('  cpu: ${e.cpu}');
      buf.writeln('  memory: ${e.memory}');
      buf.writeln('  port: ${e.port}');
      buf.writeln('  desired_count: ${e.desiredCount}');
      if (e.ecrRepository != null) {
        buf.writeln('  ecr_repository: ${e.ecrRepository}');
      }
      buf.writeln('  execution_role: ${e.executionRole}');
      if (e.taskFamily != null) buf.writeln('  task_family: ${e.taskFamily}');
      buf.writeln('  log_group: ${e.logGroup}');
      buf.writeln('  idle_timeout_seconds: ${e.idleTimeoutSeconds}');
      buf.writeln('  stickiness: ${e.stickiness}');
      buf.writeln('  assign_public_ip: ${e.assignPublicIp}');
      buf.writeln('  platform: ${e.platform}');
      buf.writeln('  image_tag: ${e.imageTag}');
      if (e.vpcId != null) buf.writeln('  vpc_id: ${e.vpcId}');
      if (e.subnetIds.isNotEmpty) {
        buf.writeln(
          '  subnet_ids: [${e.subnetIds.map((s) => '"$s"').join(', ')}]',
        );
      }
      if (e.loadBalancerArn != null) {
        buf.writeln('  load_balancer_arn: ${e.loadBalancerArn}');
      }
      if (e.targetGroupArn != null) {
        buf.writeln('  target_group_arn: ${e.targetGroupArn}');
      }
      if (e.publicHost != null) {
        buf.writeln('  public_host: ${e.publicHost}');
      }
    }
    if (host == AppHost.azure || azure != null) {
      final a = azure ?? AzureConfig(app: name.replaceAll('_', '-'));
      buf.writeln('azure:');
      buf.writeln('  app: ${a.app}');
      if (a.resourceGroup != null) {
        buf.writeln('  resource_group: ${a.resourceGroup}');
      }
      buf.writeln('  location: ${a.location}');
      if (a.environment != null) {
        buf.writeln('  environment: ${a.environment}');
      }
      if (a.registry != null) buf.writeln('  registry: ${a.registry}');
      if (a.repository != null) buf.writeln('  repository: ${a.repository}');
      buf.writeln('  cpu: ${a.cpu}');
      buf.writeln('  memory: ${a.memory}');
      buf.writeln('  port: ${a.port}');
      buf.writeln('  min_replicas: ${a.minReplicas}');
      buf.writeln('  max_replicas: ${a.maxReplicas}');
      buf.writeln('  image_tag: ${a.imageTag}');
      buf.writeln('  platform: ${a.platform}');
      if (a.publicHost != null) {
        buf.writeln('  public_host: ${a.publicHost}');
      }
    }
    if (host == AppHost.hetzner || hetzner != null) {
      final h = hetzner ?? HetznerConfig();
      buf.writeln('hetzner:');
      if (h.serverName != null) buf.writeln('  server_name: ${h.serverName}');
      if (h.serverId != null) buf.writeln('  server_id: ${h.serverId}');
      if (h.ipv4 != null) buf.writeln('  ipv4: ${h.ipv4}');
      if (h.location != null) buf.writeln('  location: ${h.location}');
      if (h.serverType != null) buf.writeln('  server_type: ${h.serverType}');
      buf.writeln('  image: ${h.image}');
      if (h.sshKey != null) buf.writeln('  ssh_key: ${h.sshKey}');
      buf.writeln('  ssh_user: ${h.sshUser}');
      buf.writeln('  container_name: ${h.containerName}');
      buf.writeln('  port: ${h.port}');
      buf.writeln('  platform: ${h.platform}');
      buf.writeln('  create: ${h.create}');
      buf.writeln('  min_memory_gb: ${h.minMemoryGb}');
      buf.writeln('  https: ${h.https}');
      if (h.domain != null) buf.writeln('  domain: ${h.domain}');
      if (h.publicHost != null) {
        buf.writeln('  public_host: ${h.publicHost}');
      }
    }
    // Static web CDN when split (not native API hosts). web_host written above.
    if (usesStaticWebHost) {
      buf.writeln();
      if (webHost == StaticWebHost.cloudflare && cloudflare != null) {
        buf.writeln('cloudflare:');
        buf.writeln('  project: ${cloudflare!.project}');
        buf.writeln('  branch: ${cloudflare!.branch}');
      }
      if (webHost == StaticWebHost.vercel || vercel != null) {
        final v = vercel ?? VercelConfig(project: name);
        buf.writeln('vercel:');
        buf.writeln('  project: ${v.project}');
        if (v.scope != null) buf.writeln('  scope: ${v.scope}');
        if (v.publicHost != null) {
          buf.writeln('  public_host: ${v.publicHost}');
        }
      }
      if (webHost == StaticWebHost.netlify || netlify != null) {
        final n = netlify ?? NetlifyConfig(site: name);
        buf.writeln('netlify:');
        buf.writeln('  site: ${n.site}');
        if (n.siteId != null) buf.writeln('  site_id: ${n.siteId}');
        if (n.team != null) buf.writeln('  team: ${n.team}');
        if (n.publicHost != null) {
          buf.writeln('  public_host: ${n.publicHost}');
        }
      }
      if (webHost == StaticWebHost.githubPages || githubPages != null) {
        final g = githubPages ?? GitHubPagesConfig(repo: name);
        buf.writeln('github_pages:');
        buf.writeln('  repo: ${g.repo}');
        if (g.owner != null) buf.writeln('  owner: ${g.owner}');
        buf.writeln('  branch: ${g.branch}');
        if (g.private) buf.writeln('  private: true');
        if (g.publicHost != null) {
          buf.writeln('  public_host: ${g.publicHost}');
        }
      }
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
        executionEnvironment: () {
          final raw =
              (m['execution_environment'] ?? m['executionEnvironment'] ?? 'gen2')
                  .toString()
                  .trim()
                  .toLowerCase();
          return raw == 'gen1' ? 'gen1' : 'gen2';
        }(),
        cloudSqlInstances: sqlList,
        extraEnv: envMap,
        publicHost: m['public_host']?.toString(),
      );
    }

    AwsConfig? aws;
    if (doc['aws'] != null ||
        doc['apprunner'] != null ||
        host == AppHost.aws) {
      final m = _map(doc['aws'] ?? doc['apprunner']);
      final envMap = <String, String>{};
      final envRaw = m['env'];
      if (envRaw is YamlMap) {
        for (final e in envRaw.entries) {
          envMap[e.key.toString()] = e.value?.toString() ?? '';
        }
      }
      aws = AwsConfig(
        service: m['service']?.toString() ?? name.replaceAll('_', '-'),
        region: m['region']?.toString() ?? 'us-east-1',
        cpu: m['cpu']?.toString() ?? '1024',
        memory: m['memory']?.toString() ?? '2048',
        port: int.tryParse('${m['port'] ?? 8080}') ?? 8080,
        ecrRepository: m['ecr_repository']?.toString(),
        ecrAccessRole:
            m['ecr_access_role']?.toString() ?? 'AppRunnerECRAccessRole',
        imageTag: m['image_tag']?.toString() ?? 'latest',
        platform: m['platform']?.toString() ?? 'linux/amd64',
        startCommand: m['start_command']?.toString() ?? '/app/entrypoint.sh',
        ecrPublic: m['ecr_public'] == true,
        serviceArn: m['service_arn']?.toString(),
        extraEnv: envMap,
        publicHost: m['public_host']?.toString(),
      );
    }

    AwsEcsConfig? awsEcs;
    if (doc['aws_ecs'] != null ||
        doc['ecs'] != null ||
        host == AppHost.awsEcs) {
      final m = _map(doc['aws_ecs'] ?? doc['ecs']);
      final envMap = <String, String>{};
      final envRaw = m['env'];
      if (envRaw is YamlMap) {
        for (final e in envRaw.entries) {
          envMap[e.key.toString()] = e.value?.toString() ?? '';
        }
      }
      final subnetList = <String>[];
      final sn = m['subnet_ids'];
      if (sn is YamlList) {
        for (final e in sn) {
          subnetList.add(e.toString());
        }
      } else if (sn is String && sn.isNotEmpty) {
        subnetList.addAll(sn.split(',').map((s) => s.trim()));
      }
      final svcName = m['service']?.toString() ?? name.replaceAll('_', '-');
      awsEcs = AwsEcsConfig(
        service: svcName,
        region: m['region']?.toString() ?? 'us-east-1',
        cluster: m['cluster']?.toString(),
        cpu: m['cpu']?.toString() ?? '512',
        memory: m['memory']?.toString() ?? '1024',
        port: int.tryParse('${m['port'] ?? 8080}') ?? 8080,
        desiredCount: int.tryParse('${m['desired_count'] ?? 1}') ?? 1,
        ecrRepository: m['ecr_repository']?.toString(),
        executionRole:
            m['execution_role']?.toString() ?? 'podflyEcsTaskExecutionRole',
        taskFamily: m['task_family']?.toString(),
        logGroup: m['log_group']?.toString() ?? '/ecs/$svcName',
        idleTimeoutSeconds:
            int.tryParse('${m['idle_timeout_seconds'] ?? 3600}') ?? 3600,
        stickiness: m['stickiness'] != false,
        assignPublicIp: m['assign_public_ip'] != false,
        platform: m['platform']?.toString() ?? 'linux/amd64',
        imageTag: m['image_tag']?.toString() ?? 'latest',
        vpcId: m['vpc_id']?.toString(),
        subnetIds: subnetList,
        loadBalancerArn: m['load_balancer_arn']?.toString(),
        targetGroupArn: m['target_group_arn']?.toString(),
        extraEnv: envMap,
        publicHost: m['public_host']?.toString(),
      );
    }

    AzureConfig? azure;
    if (doc['azure'] != null || host == AppHost.azure) {
      final m = _map(doc['azure']);
      final envMap = <String, String>{};
      final envRaw = m['env'];
      if (envRaw is YamlMap) {
        for (final e in envRaw.entries) {
          envMap[e.key.toString()] = e.value?.toString() ?? '';
        }
      }
      final appName = m['app']?.toString() ??
          m['service']?.toString() ??
          name.replaceAll('_', '-');
      azure = AzureConfig(
        app: appName,
        resourceGroup: m['resource_group']?.toString(),
        location: m['location']?.toString() ?? 'eastus',
        environment: m['environment']?.toString(),
        registry: m['registry']?.toString(),
        repository: m['repository']?.toString(),
        cpu: m['cpu']?.toString() ?? '0.5',
        memory: m['memory']?.toString() ?? '1.0Gi',
        port: int.tryParse('${m['port'] ?? 8080}') ?? 8080,
        minReplicas: int.tryParse('${m['min_replicas'] ?? 0}') ?? 0,
        maxReplicas: int.tryParse('${m['max_replicas'] ?? 3}') ?? 3,
        imageTag: m['image_tag']?.toString() ?? 'latest',
        platform: m['platform']?.toString() ?? 'linux/amd64',
        extraEnv: envMap,
        publicHost: m['public_host']?.toString(),
      );
    }

    HetznerConfig? hetzner;
    if (doc['hetzner'] != null || host == AppHost.hetzner) {
      final m = _map(doc['hetzner']);
      final envMap = <String, String>{};
      final envRaw = m['env'];
      if (envRaw is YamlMap) {
        for (final e in envRaw.entries) {
          envMap[e.key.toString()] = e.value?.toString() ?? '';
        }
      }
      hetzner = HetznerConfig(
        serverName: m['server_name']?.toString() ?? m['name']?.toString(),
        serverId: m['server_id']?.toString() ?? m['id']?.toString(),
        ipv4: m['ipv4']?.toString(),
        location: m['location']?.toString(),
        serverType: m['server_type']?.toString() ?? m['type']?.toString(),
        image: m['image']?.toString() ?? 'ubuntu-24.04',
        sshKey: m['ssh_key']?.toString(),
        sshUser: m['ssh_user']?.toString() ?? 'root',
        containerName: m['container_name']?.toString() ?? 'podfly',
        port: int.tryParse('${m['port'] ?? 8080}') ?? 8080,
        platform: m['platform']?.toString() ?? 'linux/amd64',
        create: m['create'] == true,
        minMemoryGb: int.tryParse('${m['min_memory_gb'] ?? 2}') ?? 2,
        https: m['https'] != false,
        domain: m['domain']?.toString(),
        extraEnv: envMap,
        publicHost: m['public_host']?.toString(),
      );
    }

    final webHost = StaticWebHostX.parse(
      doc['web_host']?.toString() ??
          (doc['github_pages'] != null &&
                  doc['cloudflare'] == null &&
                  doc['vercel'] == null &&
                  doc['netlify'] == null
              ? 'github_pages'
              : (doc['netlify'] != null &&
                      doc['cloudflare'] == null &&
                      doc['vercel'] == null
                  ? 'netlify'
                  : (doc['vercel'] != null && doc['cloudflare'] == null
                      ? 'vercel'
                      : 'cloudflare'))),
    );

    CloudflareConfig? cf;
    VercelConfig? vercel;
    NetlifyConfig? netlify;
    GitHubPagesConfig? githubPages;
    // Split UI CDN for Fly (etc.); native API hosts skip static web host.
    final wantStaticWeb = host != AppHost.railway &&
        host != AppHost.digitalOcean &&
        host != AppHost.render &&
        host != AppHost.cloudRun &&
        host != AppHost.aws &&
        host != AppHost.awsEcs &&
        host != AppHost.azure &&
        host != AppHost.hetzner &&
        (doc['cloudflare'] != null ||
            doc['vercel'] != null ||
            doc['netlify'] != null ||
            doc['github_pages'] != null ||
            doc['web_host'] != null ||
            mode == DeployMode.split);
    if (wantStaticWeb) {
      if (webHost == StaticWebHost.vercel || doc['vercel'] != null) {
        final m = _map(doc['vercel']);
        vercel = VercelConfig(
          project: m['project']?.toString() ?? name,
          publicHost: m['public_host']?.toString(),
          scope: m['scope']?.toString() ?? m['team']?.toString(),
        );
      }
      if (webHost == StaticWebHost.netlify || doc['netlify'] != null) {
        final m = _map(doc['netlify']);
        netlify = NetlifyConfig(
          site: m['site']?.toString() ??
              m['project']?.toString() ??
              m['name']?.toString() ??
              name,
          siteId: m['site_id']?.toString() ?? m['id']?.toString(),
          publicHost: m['public_host']?.toString(),
          team: m['team']?.toString() ?? m['account_slug']?.toString(),
        );
      }
      if (webHost == StaticWebHost.githubPages || doc['github_pages'] != null) {
        final m = _map(doc['github_pages']);
        githubPages = GitHubPagesConfig(
          repo: m['repo']?.toString() ??
              m['repository']?.toString() ??
              m['project']?.toString() ??
              name,
          owner: m['owner']?.toString() ?? m['org']?.toString(),
          branch: m['branch']?.toString() ?? 'gh-pages',
          publicHost: m['public_host']?.toString(),
          private: m['private'] == true,
        );
      }
      if (webHost == StaticWebHost.cloudflare ||
          (doc['cloudflare'] != null &&
              webHost != StaticWebHost.vercel &&
              webHost != StaticWebHost.netlify &&
              webHost != StaticWebHost.githubPages)) {
        final m = _map(doc['cloudflare']);
        cf = CloudflareConfig(
          project: m['project']?.toString() ?? name,
          branch: m['branch']?.toString() ?? 'main',
        );
      }
      // Default project if still split and no block
      if (webHost == StaticWebHost.cloudflare && cf == null) {
        cf = CloudflareConfig(project: name);
      }
      if (webHost == StaticWebHost.vercel && vercel == null) {
        vercel = VercelConfig(project: name);
      }
      if (webHost == StaticWebHost.netlify && netlify == null) {
        netlify = NetlifyConfig(site: name);
      }
      if (webHost == StaticWebHost.githubPages && githubPages == null) {
        githubPages = GitHubPagesConfig(repo: name);
      }
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
      sanitizedName: aws?.service ??
          cloudRun?.service ??
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
      webHost: wantStaticWeb ? webHost : StaticWebHost.cloudflare,
      mode: mode,
      name: name,
      server: server,
      flutter: flutter,
      fly: fly,
      railway: railway,
      digitalOcean: digitalOcean,
      render: render,
      cloudRun: cloudRun,
      aws: aws,
      awsEcs: awsEcs,
      azure: azure,
      hetzner: hetzner,
      cloudflare: cf,
      vercel: vercel,
      netlify: netlify,
      githubPages: githubPages,
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
