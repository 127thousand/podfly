import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../fly_name.dart';
import '../log.dart';
import '../process_runner.dart';
import 'adapter.dart';
import 'auth_helpers.dart';

/// Google Cloud Run — inexpensive serverless Serverpod API (stateless).
///
/// Aligns with Serverpod's GCR guide: Docker image, scale-to-zero, optional
/// Cloud SQL later. Not full GCE/Terraform. UI/web is out of scope for v1.
class CloudRunHost extends HostAdapter {
  @override
  String get id => 'cloud_run';

  @override
  String get label => 'Google Cloud Run';

  @override
  List<String> get cliBinaries => const ['gcloud'];

  @override
  String get installHint => 'https://cloud.google.com/sdk/docs/install';

  @override
  List<String> get idAliases => const ['cloudrun', 'gcp', 'google'];

  @override
  List<CliInstallRecipe> get installRecipes => const [
        CliInstallRecipe(
          label: 'brew install --cask google-cloud-sdk',
          executable: 'brew',
          args: ['install', '--cask', 'google-cloud-sdk'],
        ),
      ];

  @override
  bool get canDeploy => true;

  @override
  AppHost get appHost => AppHost.cloudRun;

  @override
  String get configKey => 'cloud_run';

  @override
  List<DatabaseProvider> get supportedDatabases => const [
        DatabaseProvider.none,
        DatabaseProvider.neon,
        // Cloud SQL: bring-your-own in production.yaml (unix socket); auto later
      ];

  @override
  String defaultApiUrl({
    required String name,
    required String sanitizedName,
  }) =>
      // Final URL is project/region-specific; placeholder until first deploy.
      'https://$sanitizedName-REGION-PROJECT.a.run.app/';

  @override
  String? publicApiBase(PodflyConfig config) {
    final c = config.cloudRun;
    if (c == null) return null;
    final h = c.publicHost;
    if (h != null && h.isNotEmpty) {
      return h.startsWith('http')
          ? (h.endsWith('/') ? h : '$h/')
          : 'https://$h/';
    }
    return null;
  }

  @override
  String secretSetHint(String secretName, PodflyConfig config) {
    final c = config.cloudRun;
    final svc = c?.service ?? config.name;
    final region = c?.region ?? 'us-central1';
    return 'gcloud run services update $svc --region $region '
        '--update-env-vars $secretName=…';
  }

  @override
  Future<bool> checkAuth(DoctorContext ctx) async {
    final bin = ctx.cliPath;
    // Application default / CI service account
    final credFile = Platform.environment['GOOGLE_APPLICATION_CREDENTIALS'] ??
        Platform.environment['CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE'];
    if (credFile != null && credFile.isNotEmpty) {
      ctx.log.ok('$bin  (service account credentials file set)');
      return true;
    }
    if (ctx.dryRun) {
      ctx.log.ok('$bin  (auth check skipped in dry-run)');
      return true;
    }
    final list = await ctx.runner.runCapture(
      bin,
      ['auth', 'list', '--filter=status:ACTIVE', '--format=value(account)'],
      allowDryRun: false,
    );
    final account = list.stdout.trim();
    if (list.ok && account.isNotEmpty) {
      ctx.log.ok('$bin  $account');
      return true;
    }
    return authViaWhoami(
      ctx: ctx,
      whoamiArgs: const ['auth', 'list'],
      loginCommand: 'gcloud auth login',
      loginArgs: const ['auth', 'login'],
      failSubstrings: const ['no credentialed', 'not logged'],
    );
  }

  @override
  void configWarnings(PodflyConfig config, Log log) {
    final c = config.cloudRun;
    if (c == null) return;
    if (c.project == null || c.project!.trim().isEmpty) {
      log.warn(
        'cloud_run.project unset — using active gcloud project '
        '(gcloud config get-value project)',
      );
    }
    log.detail(
      'Cloud Run is for stateless Serverpod (API). Future calls / in-memory '
      'global state need GCE Terraform or Serverpod Cloud — not this path.',
    );
  }

  @override
  Future<HostDeployResult> deployApi(DeployContext ctx) async {
    final config = ctx.config;
    final runner = ctx.runner;
    final log = ctx.log;

    final ccfg = config.cloudRun ??
        CloudRunConfig(service: sanitizeFlyAppName(config.name));
    final service = sanitizeFlyAppName(ccfg.service);
    log.step('Deploy Cloud Run API ($service)');

    final gcloud = await runner.resolve('gcloud');
    if (gcloud == null) throw StateError('gcloud not found — $installHint');

    final project = await _resolveProject(ctx, gcloud, ccfg);
    final region = ccfg.region;

    await _ensureRootDockerfile(ctx);

    final args = <String>[
      'run',
      'deploy',
      service,
      '--source',
      '.',
      '--region',
      region,
      '--project',
      project,
      '--port',
      '${ccfg.port}',
      '--memory',
      ccfg.memory,
      '--cpu',
      ccfg.cpu,
      '--min-instances',
      '${ccfg.minInstances}',
      '--max-instances',
      '${ccfg.maxInstances}',
      '--timeout',
      '${ccfg.timeoutSeconds}',
      '--quiet',
    ];
    if (ccfg.sessionAffinity) {
      args.add('--session-affinity');
    } else {
      args.add('--no-session-affinity');
    }
    final envPairs = <String>[
      'runmode=production',
      'SERVERPOD_RUN_MODE=production',
      ...ccfg.extraEnv.entries.map((e) => '${e.key}=${e.value}'),
    ];
    args.addAll(['--set-env-vars', envPairs.join(',')]);
    if (ccfg.allowUnauthenticated) {
      args.add('--allow-unauthenticated');
    } else {
      args.add('--no-allow-unauthenticated');
    }
    if (ccfg.cloudSqlInstances.isNotEmpty) {
      args.addAll([
        '--set-cloudsql-instances',
        ccfg.cloudSqlInstances.join(','),
      ]);
    }

    log.detail(
      'gcloud run deploy $service --source . --region $region --project $project',
    );
    final r = await runner.run(
      gcloud,
      args,
      workingDirectory: config.root,
    );
    if (!r.ok && !runner.dryRun) {
      throw StateError(
        'gcloud run deploy failed (exit ${r.exitCode}). '
        'Enable Cloud Run API if needed: '
        'gcloud services enable run.googleapis.com --project $project',
      );
    }

    final url = await _resolveServiceUrl(
      runner,
      gcloud,
      service: service,
      region: region,
      project: project,
    );
    final host = url
        .replaceFirst(RegExp(r'^https?://'), '')
        .split('/')
        .first;
    await ctx.patchPublicHosts(host);
    if (!runner.dryRun) {
      await _persist(ctx, ccfg, project: project, publicHost: host);
    }

    log.ok('Cloud Run: $url');
    return HostDeployResult(publicHost: host, displayUrl: url);
  }

  /// Serverpod Dockerfiles expect monorepo root context; Cloud Run `--source`
  /// looks for a Dockerfile in that directory.
  Future<void> _ensureRootDockerfile(DeployContext ctx) async {
    final rootDocker = File(p.join(ctx.config.root, 'Dockerfile'));
    final serverDocker =
        File(p.join(ctx.config.root, ctx.config.server, 'Dockerfile'));
    if (await rootDocker.exists()) {
      ctx.log.detail('using monorepo root Dockerfile');
      return;
    }
    if (!await serverDocker.exists()) {
      ctx.log.warn(
        'No Dockerfile at root or ${ctx.config.server}/ — '
        'gcloud may fail; run serverpod create or add a Dockerfile',
      );
      return;
    }
    if (ctx.runner.dryRun) {
      ctx.log.dry('copy ${ctx.config.server}/Dockerfile → ./Dockerfile');
      return;
    }
    await rootDocker.writeAsString(await serverDocker.readAsString());
    ctx.log.ok(
      'copied ${ctx.config.server}/Dockerfile → ./Dockerfile '
      '(Cloud Run --source requires root Dockerfile)',
    );
  }

  Future<String> _resolveProject(
    DeployContext ctx,
    String gcloud,
    CloudRunConfig ccfg,
  ) async {
    final fromCfg = ccfg.project?.trim();
    if (fromCfg != null && fromCfg.isNotEmpty) return fromCfg;
    if (ctx.runner.dryRun) return 'PROJECT';
    final r = await ctx.runner.runCapture(
      gcloud,
      ['config', 'get-value', 'project'],
      allowDryRun: false,
    );
    final p = r.stdout.trim();
    if (!r.ok || p.isEmpty || p == '(unset)') {
      throw StateError(
        'Set cloud_run.project in podfly.yaml or: gcloud config set project ID',
      );
    }
    return p;
  }

  Future<String> _resolveServiceUrl(
    ProcessRunner runner,
    String gcloud, {
    required String service,
    required String region,
    required String project,
  }) async {
    if (runner.dryRun) {
      return 'https://$service-hash-$region.a.run.app';
    }
    final desc = await runner.runCapture(
      gcloud,
      [
        'run',
        'services',
        'describe',
        service,
        '--region',
        region,
        '--project',
        project,
        '--format=value(status.url)',
      ],
      allowDryRun: false,
    );
    final url = desc.stdout.trim();
    if (desc.ok && url.startsWith('http')) return url;
    // Fallback parse from deploy stdout is handled by describe only
    throw StateError(
      'Could not resolve Cloud Run URL for $service '
      '(describe exit ${desc.exitCode})',
    );
  }

  Future<void> _persist(
    DeployContext ctx,
    CloudRunConfig base, {
    required String project,
    required String publicHost,
  }) async {
    final cfg = ctx.config;
    final updated = PodflyConfig(
      root: cfg.root,
      host: cfg.host,
      mode: cfg.mode,
      name: cfg.name,
      server: cfg.server,
      flutter: cfg.flutter,
      fly: cfg.fly,
      railway: cfg.railway,
      digitalOcean: cfg.digitalOcean,
      render: cfg.render,
      cloudRun: CloudRunConfig(
        service: base.service,
        project: project,
        region: base.region,
        allowUnauthenticated: base.allowUnauthenticated,
        memory: base.memory,
        cpu: base.cpu,
        port: base.port,
        minInstances: base.minInstances,
        maxInstances: base.maxInstances,
        timeoutSeconds: base.timeoutSeconds,
        sessionAffinity: base.sessionAffinity,
        cloudSqlInstances: base.cloudSqlInstances,
        extraEnv: base.extraEnv,
        publicHost: publicHost,
      ),
      cloudflare: cfg.cloudflare,
      database: cfg.database,
      web: WebConfig(
        enabled: cfg.web.enabled,
        serverUrlDefine: cfg.web.serverUrlDefine,
        apiUrl: 'https://$publicHost/',
        patchBootstrap: cfg.web.patchBootstrap,
        writeHeaders: cfg.web.writeHeaders,
        baseHref: cfg.web.baseHref,
        staticDir: cfg.web.staticDir,
      ),
      smoke: cfg.smoke,
    );
    await updated.save();
    ctx.log.detail('saved cloud_run.public_host → $publicHost');
  }
}
