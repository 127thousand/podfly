import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../fly_name.dart';
import '../log.dart';
import 'adapter.dart';
import 'auth_helpers.dart';

/// AWS App Runner — container image from ECR (local Docker build + push).
///
/// Stateless Serverpod API only for v1 (mirrors Cloud Run api_only).
/// Requires `aws` CLI + Docker. Creates ECR repo + `AppRunnerECRAccessRole`
/// when missing.
class AwsHost extends HostAdapter {
  @override
  String get id => 'aws';

  @override
  String get label => 'AWS App Runner';

  @override
  List<String> get cliBinaries => const ['aws'];

  @override
  String get installHint => 'https://docs.aws.amazon.com/cli/';

  @override
  List<String> get idAliases => const ['apprunner', 'app_runner', 'amazon'];

  @override
  List<CliInstallRecipe> get installRecipes => const [
        CliInstallRecipe(
          label: 'brew install awscli',
          executable: 'brew',
          args: ['install', 'awscli'],
        ),
      ];

  @override
  bool get canDeploy => true;

  @override
  AppHost get appHost => AppHost.aws;

  @override
  String get configKey => 'aws';

  @override
  List<DatabaseProvider> get supportedDatabases => const [
        DatabaseProvider.none,
        DatabaseProvider.neon,
      ];

  @override
  String defaultApiUrl({
    required String name,
    required String sanitizedName,
  }) =>
      'https://$sanitizedName.REGION.awsapprunner.com/';

  @override
  String? publicApiBase(PodflyConfig config) {
    final c = config.aws;
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
    final arn = config.aws?.serviceArn ?? '<service-arn>';
    return 'aws apprunner update-service --service-arn $arn '
        '--source-configuration … (set $secretName in ImageConfiguration '
        'RuntimeEnvironmentVariables)';
  }

  @override
  Future<bool> checkAuth(DoctorContext ctx) async {
    final bin = ctx.cliPath;
    if (ctx.dryRun) {
      ctx.log.ok('$bin  (auth check skipped in dry-run)');
      return true;
    }
    final r = await ctx.runner.runCapture(
      bin,
      ['sts', 'get-caller-identity', '--output', 'json'],
      allowDryRun: false,
    );
    if (r.ok && r.stdout.contains('Account')) {
      final account = _jsonString(r.stdout, 'Account') ?? '?';
      final arn = _jsonString(r.stdout, 'Arn') ?? '';
      ctx.log.ok('$bin  account $account ${arn.isNotEmpty ? "($arn)" : ""}');
      return true;
    }
    return authViaWhoami(
      ctx: ctx,
      whoamiArgs: const ['sts', 'get-caller-identity'],
      loginCommand: 'aws configure',
      loginArgs: const ['configure'],
      failSubstrings: const [
        'Unable to locate credentials',
        'ExpiredToken',
        'could not be found',
      ],
    );
  }

  @override
  void configWarnings(PodflyConfig config, Log log) {
    log.detail(
      'App Runner: Docker → ECR → create/update. Not free scale-to-zero — '
      'delete services when done. See doc/aws.md.',
    );
    log.warn(
      'App Runner does NOT support WebSockets (managed Envoy returns 403 on '
      'Upgrade). HTTP RPC OK; Serverpod streams need Cloud Run/Fly or future '
      'ECS+ALB (doc/specs/2026-07-21-aws-ecs-realtime-sketch.md).',
    );
  }

  @override
  Future<HostDeployResult> deployApi(DeployContext ctx) async {
    final config = ctx.config;
    final runner = ctx.runner;
    final log = ctx.log;

    final acfg = config.aws ??
        AwsConfig(service: sanitizeFlyAppName(config.name));
    final service = sanitizeFlyAppName(acfg.service);
    log.step('Deploy AWS App Runner ($service)');

    final aws = await runner.resolve('aws');
    if (aws == null) throw StateError('aws not found — $installHint');

    final docker = await runner.resolve('docker');
    if (docker == null) {
      throw StateError(
        'docker not found — App Runner deploy builds images locally then pushes to ECR',
      );
    }

    final region = acfg.region;
    final account = await _accountId(ctx, aws);
    final repo = acfg.ecrRepository ?? service;
    final tag = acfg.imageTag == 'latest'
        ? DateTime.now().toUtc().millisecondsSinceEpoch.toString()
        : acfg.imageTag;

    late final String imageUri;
    if (acfg.ecrPublic) {
      final alias = await _ensurePublicEcr(ctx, aws, repo: repo);
      imageUri = 'public.ecr.aws/$alias/$repo:$tag';
      await _ecrPublicLogin(ctx, aws, docker);
    } else {
      imageUri = '$account.dkr.ecr.$region.amazonaws.com/$repo:$tag';
      await _ensureEcrRepo(ctx, aws, region: region, repo: repo);
      await _ecrLogin(ctx, aws, docker, account: account, region: region);
    }

    await _dockerBuildAndPush(
      ctx,
      docker: docker,
      imageUri: imageUri,
      platform: acfg.platform,
    );

    final env = <String, String>{
      'runmode': 'production',
      'SERVERPOD_RUN_MODE': 'production',
      ...acfg.extraEnv,
    };

    String? accessRoleArn;
    if (!acfg.ecrPublic) {
      accessRoleArn = await _ensureEcrAccessRole(
        ctx,
        aws,
        account: account,
        roleName: acfg.ecrAccessRole,
      );
    }

    final sourceConfig = _sourceConfigurationJson(
      imageUri: imageUri,
      port: acfg.port,
      accessRoleArn: accessRoleArn,
      env: env,
      startCommand: acfg.startCommand,
      ecrPublic: acfg.ecrPublic,
    );

    String? serviceArn = acfg.serviceArn;
    if (serviceArn == null || serviceArn.isEmpty) {
      serviceArn = await _findServiceArn(
        ctx,
        aws,
        region: region,
        serviceName: service,
      );
    }

    if (serviceArn == null) {
      serviceArn = await _createService(
        ctx,
        aws,
        region: region,
        serviceName: service,
        sourceConfig: sourceConfig,
        acfg: acfg,
      );
    } else {
      await _updateService(
        ctx,
        aws,
        region: region,
        serviceArn: serviceArn,
        sourceConfig: sourceConfig,
        acfg: acfg,
      );
    }

    await _waitRunning(ctx, aws, region: region, serviceArn: serviceArn);
    final url = await _serviceUrl(
      ctx,
      aws,
      region: region,
      serviceArn: serviceArn,
    );
    final host = url
        .replaceFirst(RegExp(r'^https?://'), '')
        .split('/')
        .first;

    await ctx.patchPublicHosts(host);
    if (!runner.dryRun) {
      await _persist(
        ctx,
        acfg,
        serviceArn: serviceArn,
        publicHost: host,
        ecrRepository: repo,
      );
    }

    log.ok('App Runner: $url');
    return HostDeployResult(publicHost: host, displayUrl: url);
  }

  Map<String, Object?> _sourceConfigurationJson({
    required String imageUri,
    required int port,
    required String? accessRoleArn,
    required Map<String, String> env,
    required String? startCommand,
    required bool ecrPublic,
  }) {
    // App Runner often fails CREATE with empty logs when relying only on
    // Dockerfile ENTRYPOINT (shell form). Explicit StartCommand is reliable.
    final imageConfig = <String, Object?>{
      'Port': '$port',
      if (startCommand != null && startCommand.isNotEmpty)
        'StartCommand': startCommand,
      if (env.isNotEmpty) 'RuntimeEnvironmentVariables': env,
    };
    final map = <String, Object?>{
      'ImageRepository': {
        'ImageIdentifier': imageUri,
        'ImageConfiguration': imageConfig,
        'ImageRepositoryType': ecrPublic ? 'ECR_PUBLIC' : 'ECR',
      },
      'AutoDeploymentsEnabled': false,
    };
    if (!ecrPublic && accessRoleArn != null) {
      map['AuthenticationConfiguration'] = {
        'AccessRoleArn': accessRoleArn,
      };
    }
    return map;
  }

  Future<String> _accountId(DeployContext ctx, String aws) async {
    if (ctx.runner.dryRun) return '123456789012';
    final r = await ctx.runner.runCapture(
      aws,
      ['sts', 'get-caller-identity', '--query', 'Account', '--output', 'text'],
      allowDryRun: false,
    );
    final id = r.stdout.trim();
    if (!r.ok || id.isEmpty) {
      throw StateError('aws sts get-caller-identity failed — run aws configure');
    }
    return id;
  }

  /// Returns the public registry alias (e.g. `g7h3f3f2`).
  Future<String> _ensurePublicEcr(
    DeployContext ctx,
    String aws, {
    required String repo,
  }) async {
    final log = ctx.log;
    if (ctx.runner.dryRun) {
      log.dry('aws ecr-public ensure repository $repo');
      return 'alias';
    }
    // Ensure repo exists
    final desc = await ctx.runner.runCapture(
      aws,
      [
        'ecr-public',
        'describe-repositories',
        '--repository-names',
        repo,
        '--region',
        'us-east-1',
      ],
      allowDryRun: false,
    );
    if (!desc.ok) {
      log.detail('creating ECR Public repository $repo');
      final create = await ctx.runner.run(
        aws,
        [
          'ecr-public',
          'create-repository',
          '--repository-name',
          repo,
          '--region',
          'us-east-1',
        ],
        allowDryRun: false,
      );
      if (!create.ok) {
        throw StateError(
          'aws ecr-public create-repository failed (exit ${create.exitCode})',
        );
      }
    }
    final reg = await ctx.runner.runCapture(
      aws,
      [
        'ecr-public',
        'describe-registries',
        '--region',
        'us-east-1',
        '--output',
        'json',
      ],
      allowDryRun: false,
    );
    if (!reg.ok) {
      throw StateError('aws ecr-public describe-registries failed');
    }
    try {
      final decoded = jsonDecode(reg.stdout) as Map<String, dynamic>;
      final list = decoded['registries'] as List<dynamic>? ?? [];
      if (list.isNotEmpty && list.first is Map) {
        final uri = (list.first as Map)['registryUri']?.toString() ?? '';
        // public.ecr.aws/ALIAS
        final alias = uri.split('/').last;
        if (alias.isNotEmpty) {
          log.detail('ECR Public: public.ecr.aws/$alias/$repo');
          return alias;
        }
      }
    } catch (_) {}
    throw StateError('could not resolve ECR Public registry alias');
  }

  Future<void> _ecrPublicLogin(
    DeployContext ctx,
    String aws,
    String docker,
  ) async {
    final log = ctx.log;
    if (ctx.runner.dryRun) {
      log.dry('aws ecr-public get-authorization-token | docker login');
      return;
    }
    final token = await ctx.runner.runCapture(
      aws,
      [
        'ecr-public',
        'get-authorization-token',
        '--region',
        'us-east-1',
        '--output',
        'text',
        '--query',
        'authorizationData.authorizationToken',
      ],
      allowDryRun: false,
    );
    if (!token.ok || token.stdout.trim().isEmpty) {
      throw StateError('aws ecr-public get-authorization-token failed');
    }
    // Token is base64(AWS:password)
    final decoded = utf8.decode(base64.decode(token.stdout.trim()));
    final password = decoded.contains(':')
        ? decoded.split(':').sublist(1).join(':')
        : decoded;
    final login = await Process.start(
      docker,
      ['login', '--username', 'AWS', '--password-stdin', 'public.ecr.aws'],
    );
    login.stdin.write(password);
    await login.stdin.close();
    final code = await login.exitCode;
    if (code != 0) {
      final err = await login.stderr.transform(utf8.decoder).join();
      throw StateError('docker login to public.ecr.aws failed: $err');
    }
    log.detail('docker logged in to public.ecr.aws');
  }

  Future<void> _ensureEcrRepo(
    DeployContext ctx,
    String aws, {
    required String region,
    required String repo,
  }) async {
    final log = ctx.log;
    if (ctx.runner.dryRun) {
      log.dry('aws ecr describe-repositories / create-repository $repo');
      return;
    }
    final desc = await ctx.runner.runCapture(
      aws,
      [
        'ecr',
        'describe-repositories',
        '--repository-names',
        repo,
        '--region',
        region,
      ],
      allowDryRun: false,
    );
    if (desc.ok) {
      log.detail('ECR repository: $repo');
      return;
    }
    log.detail('creating ECR repository $repo');
    final create = await ctx.runner.run(
      aws,
      [
        'ecr',
        'create-repository',
        '--repository-name',
        repo,
        '--region',
        region,
        '--image-scanning-configuration',
        'scanOnPush=true',
      ],
      allowDryRun: false,
    );
    if (!create.ok) {
      throw StateError(
        'aws ecr create-repository failed (exit ${create.exitCode})',
      );
    }
  }

  Future<void> _ecrLogin(
    DeployContext ctx,
    String aws,
    String docker, {
    required String account,
    required String region,
  }) async {
    final log = ctx.log;
    if (ctx.runner.dryRun) {
      log.dry('aws ecr get-login-password | docker login');
      return;
    }
    final pass = await ctx.runner.runCapture(
      aws,
      ['ecr', 'get-login-password', '--region', region],
      allowDryRun: false,
    );
    if (!pass.ok || pass.stdout.trim().isEmpty) {
      throw StateError('aws ecr get-login-password failed');
    }
    final registry = '$account.dkr.ecr.$region.amazonaws.com';
    final login = await Process.start(
      docker,
      ['login', '--username', 'AWS', '--password-stdin', registry],
    );
    login.stdin.write(pass.stdout.trim());
    await login.stdin.close();
    final code = await login.exitCode;
    if (code != 0) {
      final err = await login.stderr.transform(utf8.decoder).join();
      throw StateError('docker login to ECR failed: $err');
    }
    log.detail('docker logged in to $registry');
  }

  Future<void> _dockerBuildAndPush(
    DeployContext ctx, {
    required String docker,
    required String imageUri,
    required String platform,
  }) async {
    final config = ctx.config;
    final runner = ctx.runner;
    final log = ctx.log;
    // Prefer monorepo root Dockerfile (monolith nginx image); else server.
    final rootDocker = File(p.join(config.root, 'Dockerfile'));
    final serverDocker = File(p.join(config.root, config.server, 'Dockerfile'));
    final df = await rootDocker.exists()
        ? 'Dockerfile'
        : (await serverDocker.exists()
            ? p.join(config.server, 'Dockerfile')
            : 'Dockerfile');

    if (runner.dryRun) {
      log.dry('docker build --platform $platform -t $imageUri -f $df .');
      log.dry('docker push $imageUri');
      return;
    }

    log.detail('docker build $imageUri ($platform)');
    final build = await runner.run(
      docker,
      [
        'build',
        '--platform',
        platform,
        '-t',
        imageUri,
        '-f',
        df,
        '.',
      ],
      workingDirectory: config.root,
      allowDryRun: false,
    );
    if (!build.ok) {
      throw StateError('docker build failed (exit ${build.exitCode})');
    }
    log.detail('docker push $imageUri');
    final push = await runner.run(
      docker,
      ['push', imageUri],
      workingDirectory: config.root,
      allowDryRun: false,
    );
    if (!push.ok) {
      throw StateError('docker push failed (exit ${push.exitCode})');
    }
  }

  /// App Runner needs an IAM role to pull private ECR images.
  Future<String> _ensureEcrAccessRole(
    DeployContext ctx,
    String aws, {
    required String account,
    required String roleName,
  }) async {
    final log = ctx.log;
    final arn = 'arn:aws:iam::$account:role/$roleName';
    if (ctx.runner.dryRun) {
      log.dry('ensure IAM role $roleName');
      return arn;
    }
    final get = await ctx.runner.runCapture(
      aws,
      ['iam', 'get-role', '--role-name', roleName, '--output', 'json'],
      allowDryRun: false,
    );
    if (get.ok) {
      log.detail('IAM role: $roleName');
      return _jsonString(get.stdout, 'Role', nested: 'Arn') ?? arn;
    }

    log.detail('creating IAM role $roleName for App Runner → ECR');
    final trust = jsonEncode({
      'Version': '2012-10-17',
      'Statement': [
        {
          'Effect': 'Allow',
          'Principal': {
            'Service': 'build.apprunner.amazonaws.com',
          },
          'Action': 'sts:AssumeRole',
        },
      ],
    });
    final create = await ctx.runner.run(
      aws,
      [
        'iam',
        'create-role',
        '--role-name',
        roleName,
        '--assume-role-policy-document',
        trust,
        '--description',
        'podfly: App Runner pull images from ECR',
      ],
      allowDryRun: false,
    );
    if (!create.ok) {
      throw StateError(
        'aws iam create-role $roleName failed (exit ${create.exitCode}). '
        'Create the role manually or grant iam:CreateRole.',
      );
    }
    final attach = await ctx.runner.run(
      aws,
      [
        'iam',
        'attach-role-policy',
        '--role-name',
        roleName,
        '--policy-arn',
        'arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess',
      ],
      allowDryRun: false,
    );
    if (!attach.ok) {
      throw StateError(
        'aws iam attach-role-policy failed (exit ${attach.exitCode})',
      );
    }
    // IAM eventual consistency (App Runner CREATE can fail if role is brand-new)
    await Future<void>.delayed(const Duration(seconds: 15));
    return arn;
  }

  Future<String?> _findServiceArn(
    DeployContext ctx,
    String aws, {
    required String region,
    required String serviceName,
  }) async {
    if (ctx.runner.dryRun) return null;
    final r = await ctx.runner.runCapture(
      aws,
      [
        'apprunner',
        'list-services',
        '--region',
        region,
        '--output',
        'json',
      ],
      allowDryRun: false,
    );
    if (!r.ok) return null;
    try {
      final decoded = jsonDecode(r.stdout) as Map<String, dynamic>;
      final list = decoded['ServiceSummaryList'] as List<dynamic>? ?? [];
      for (final item in list) {
        if (item is! Map) continue;
        if (item['ServiceName']?.toString() == serviceName) {
          return item['ServiceArn']?.toString();
        }
      }
    } catch (_) {}
    return null;
  }

  Future<String> _createService(
    DeployContext ctx,
    String aws, {
    required String region,
    required String serviceName,
    required Map<String, Object?> sourceConfig,
    required AwsConfig acfg,
  }) async {
    final log = ctx.log;
    final instance = {
      'Cpu': acfg.cpu,
      'Memory': acfg.memory,
    };
    // Generous unhealthy threshold: first pull + cold start of Dart AOT.
    final health = {
      'Protocol': 'TCP',
      'Interval': 10,
      'Timeout': 5,
      'HealthyThreshold': 1,
      'UnhealthyThreshold': 10,
    };
    if (ctx.runner.dryRun) {
      log.dry('aws apprunner create-service $serviceName');
      return 'arn:aws:apprunner:$region:123456789012:service/$serviceName/dry';
    }
    log.detail('creating App Runner service $serviceName');
    final r = await ctx.runner.runCapture(
      aws,
      [
        'apprunner',
        'create-service',
        '--service-name',
        serviceName,
        '--source-configuration',
        jsonEncode(sourceConfig),
        '--instance-configuration',
        jsonEncode(instance),
        '--health-check-configuration',
        jsonEncode(health),
        '--region',
        region,
        '--output',
        'json',
      ],
      allowDryRun: false,
    );
    if (!r.ok) {
      throw StateError(
        'aws apprunner create-service failed (exit ${r.exitCode}):\n'
        '${r.stderr}\n${r.stdout}',
      );
    }
    final arn = _jsonString(r.stdout, 'Service', nested: 'ServiceArn');
    if (arn == null || arn.isEmpty) {
      throw StateError('create-service returned no ServiceArn: ${r.stdout}');
    }
    return arn;
  }

  Future<void> _updateService(
    DeployContext ctx,
    String aws, {
    required String region,
    required String serviceArn,
    required Map<String, Object?> sourceConfig,
    required AwsConfig acfg,
  }) async {
    final log = ctx.log;
    final instance = {
      'Cpu': acfg.cpu,
      'Memory': acfg.memory,
    };
    if (ctx.runner.dryRun) {
      log.dry('aws apprunner update-service $serviceArn');
      return;
    }
    log.detail('updating App Runner service');
    final r = await ctx.runner.run(
      aws,
      [
        'apprunner',
        'update-service',
        '--service-arn',
        serviceArn,
        '--source-configuration',
        jsonEncode(sourceConfig),
        '--instance-configuration',
        jsonEncode(instance),
        '--region',
        region,
      ],
      allowDryRun: false,
    );
    if (!r.ok) {
      throw StateError(
        'aws apprunner update-service failed (exit ${r.exitCode})',
      );
    }
  }

  Future<void> _waitRunning(
    DeployContext ctx,
    String aws, {
    required String region,
    required String serviceArn,
  }) async {
    final log = ctx.log;
    if (ctx.runner.dryRun) {
      log.dry('wait App Runner RUNNING');
      return;
    }
    log.detail('waiting for App Runner service RUNNING…');
    const maxAttempts = 90; // ~15 min
    for (var i = 0; i < maxAttempts; i++) {
      final r = await ctx.runner.runCapture(
        aws,
        [
          'apprunner',
          'describe-service',
          '--service-arn',
          serviceArn,
          '--region',
          region,
          '--output',
          'json',
        ],
        allowDryRun: false,
      );
      if (r.ok) {
        final status = _jsonString(r.stdout, 'Service', nested: 'Status');
        if (status == 'RUNNING') {
          log.detail('service RUNNING');
          return;
        }
        if (status == 'CREATE_FAILED' ||
            status == 'DELETE_FAILED' ||
            status == 'DELETED') {
          throw StateError(
            'App Runner service ended in $status — check AWS console / '
            'describe-service for details',
          );
        }
        if (i % 6 == 0) {
          log.detail('status: $status');
        }
      }
      await Future<void>.delayed(const Duration(seconds: 10));
    }
    throw StateError(
      'App Runner service did not become RUNNING within timeout',
    );
  }

  Future<String> _serviceUrl(
    DeployContext ctx,
    String aws, {
    required String region,
    required String serviceArn,
  }) async {
    if (ctx.runner.dryRun) {
      return 'https://example.us-east-1.awsapprunner.com';
    }
    final r = await ctx.runner.runCapture(
      aws,
      [
        'apprunner',
        'describe-service',
        '--service-arn',
        serviceArn,
        '--region',
        region,
        '--query',
        'Service.ServiceUrl',
        '--output',
        'text',
      ],
      allowDryRun: false,
    );
    var url = r.stdout.trim();
    if (!r.ok || url.isEmpty || url == 'None') {
      throw StateError('could not resolve App Runner ServiceUrl');
    }
    if (!url.startsWith('http')) url = 'https://$url';
    return url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }

  Future<void> _persist(
    DeployContext ctx,
    AwsConfig base, {
    required String serviceArn,
    required String publicHost,
    required String ecrRepository,
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
      cloudRun: cfg.cloudRun,
      aws: AwsConfig(
        service: base.service,
        region: base.region,
        cpu: base.cpu,
        memory: base.memory,
        port: base.port,
        ecrRepository: ecrRepository,
        ecrAccessRole: base.ecrAccessRole,
        imageTag: base.imageTag,
        platform: base.platform,
        startCommand: base.startCommand,
        ecrPublic: base.ecrPublic,
        serviceArn: serviceArn,
        extraEnv: base.extraEnv,
        publicHost: publicHost,
      ),
      awsEcs: cfg.awsEcs,
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
    ctx.log.detail('saved aws.service_arn + public_host');
  }

  static String? _jsonString(
    String raw,
    String key, {
    String? nested,
  }) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      if (nested != null) {
        final inner = m[key];
        if (inner is Map) return inner[nested]?.toString();
        return null;
      }
      return m[key]?.toString();
    } catch (_) {
      return null;
    }
  }
}
