import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../fly_name.dart';
import '../log.dart';
import 'adapter.dart';
import 'auth_helpers.dart';

/// AWS ECS Fargate + Application Load Balancer.
///
/// Real WebSocket path for Serverpod streams (App Runner cannot).
/// Orchestrates the `aws` CLI only — no CDK/Terraform.
///
/// Pipeline: Docker build → ECR → task definition → Fargate service behind ALB
/// (idle timeout 3600s). HTTP :80 for demos (no ACM required).
class AwsEcsHost extends HostAdapter {
  @override
  String get id => 'aws_ecs';

  @override
  String get label => 'AWS ECS Fargate + ALB';

  @override
  List<String> get cliBinaries => const ['aws'];

  @override
  String get installHint => 'https://docs.aws.amazon.com/cli/';

  @override
  List<String> get idAliases => const ['ecs', 'fargate', 'aws-ecs'];

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
  AppHost get appHost => AppHost.awsEcs;

  @override
  String get configKey => 'aws_ecs';

  @override
  bool get supportsAllInOneWeb => true;

  @override
  List<DatabaseProvider> get supportedDatabases => const [
        DatabaseProvider.none,
        DatabaseProvider.neon,
        DatabaseProvider.supabase,
      ];

  @override
  String defaultApiUrl({
    required String name,
    required String sanitizedName,
  }) =>
      'http://$sanitizedName-REGION.elb.amazonaws.com/';

  @override
  String? publicApiBase(PodflyConfig config) {
    final c = config.awsEcs;
    if (c == null) return null;
    final h = c.publicHost;
    if (h != null && h.isNotEmpty) {
      return h.startsWith('http')
          ? (h.endsWith('/') ? h : '$h/')
          : 'http://$h/';
    }
    return null;
  }

  @override
  String secretSetHint(String secretName, PodflyConfig config) {
    final svc = config.awsEcs?.service ?? config.name;
    return 'Update task definition env for $svc ($secretName=…) then '
        'aws ecs update-service --force-new-deployment';
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
      final account = _jsonGet(r.stdout, 'Account') ?? '?';
      ctx.log.ok('$bin  account $account');
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
      ],
    );
  }

  @override
  void configWarnings(PodflyConfig config, Log log) {
    log.detail(
      'ECS+ALB: WebSocket-capable front door (unlike App Runner). '
      'Demo uses HTTP :80 (no ACM). ALB+Fargate has a cost floor — delete when done.',
    );
  }

  @override
  Future<HostDeployResult> deployApi(DeployContext ctx) async {
    final config = ctx.config;
    final runner = ctx.runner;
    final log = ctx.log;

    final acfg = config.awsEcs ??
        AwsEcsConfig(service: sanitizeFlyAppName(config.name));
    final service = sanitizeFlyAppName(acfg.service);
    final region = acfg.region;
    log.step('Deploy ECS Fargate + ALB ($service)');

    final aws = await runner.resolve('aws');
    if (aws == null) throw StateError('aws not found — $installHint');
    final docker = await runner.resolve('docker');
    if (docker == null) {
      throw StateError(
        'docker not found — ECS deploy builds images locally then pushes to ECR',
      );
    }

    final account = await _accountId(ctx, aws);
    final repo = acfg.ecrRepository ?? service;
    final tag = acfg.imageTag == 'latest'
        ? DateTime.now().toUtc().millisecondsSinceEpoch.toString()
        : acfg.imageTag;
    final imageUri = '$account.dkr.ecr.$region.amazonaws.com/$repo:$tag';

    final net = await _resolveNetwork(ctx, aws, region: region, acfg: acfg);
    await _ensureEcrRepo(ctx, aws, region: region, repo: repo);
    await _ecrLogin(ctx, aws, docker, account: account, region: region);
    await _dockerBuildAndPush(
      ctx,
      docker: docker,
      imageUri: imageUri,
      platform: acfg.platform,
    );

    final execRoleArn = await _ensureExecutionRole(
      ctx,
      aws,
      account: account,
      roleName: acfg.executionRole,
    );
    await _ensureLogGroup(ctx, aws, region: region, group: acfg.logGroup);

    final sgAlb = await _ensureSecurityGroup(
      ctx,
      aws,
      region: region,
      vpcId: net.vpcId,
      name: _clipName('$service-alb-sg', 255),
      description: 'podfly ALB $service',
      ingress: [
        (protocol: 'tcp', port: 80, cidr: '0.0.0.0/0', sourceSg: null),
      ],
    );
    final sgTasks = await _ensureSecurityGroup(
      ctx,
      aws,
      region: region,
      vpcId: net.vpcId,
      name: _clipName('$service-task-sg', 255),
      description: 'podfly ECS tasks $service',
      ingress: [
        (protocol: 'tcp', port: acfg.port, cidr: null, sourceSg: sgAlb),
      ],
    );

    final alb = await _ensureAlb(
      ctx,
      aws,
      region: region,
      name: _clipName(service, 32),
      subnets: net.subnetIds,
      securityGroups: [sgAlb],
      idleTimeout: acfg.idleTimeoutSeconds,
    );
    final tgArn = await _ensureTargetGroup(
      ctx,
      aws,
      region: region,
      name: _clipName('$service-tg', 32),
      vpcId: net.vpcId,
      port: acfg.port,
      stickiness: acfg.stickiness,
    );
    await _ensureHttpListener(
      ctx,
      aws,
      region: region,
      loadBalancerArn: alb.arn,
      targetGroupArn: tgArn,
    );

    final cluster = acfg.cluster ?? service;
    await _ensureCluster(ctx, aws, region: region, cluster: cluster);

    final taskFamily = acfg.taskFamily ?? service;
    final taskDefArn = await _registerTaskDefinition(
      ctx,
      aws,
      region: region,
      family: taskFamily,
      imageUri: imageUri,
      cpu: acfg.cpu,
      memory: acfg.memory,
      port: acfg.port,
      executionRoleArn: execRoleArn,
      logGroup: acfg.logGroup,
      logRegion: region,
      env: {
        'runmode': 'production',
        'SERVERPOD_RUN_MODE': 'production',
        ...acfg.extraEnv,
      },
    );

    await _ensureEcsService(
      ctx,
      aws,
      region: region,
      cluster: cluster,
      serviceName: service,
      taskDefinition: taskDefArn,
      subnets: net.subnetIds,
      securityGroups: [sgTasks],
      targetGroupArn: tgArn,
      containerName: 'app',
      containerPort: acfg.port,
      desiredCount: acfg.desiredCount,
      assignPublicIp: acfg.assignPublicIp,
    );

    await _waitServiceStable(
      ctx,
      aws,
      region: region,
      cluster: cluster,
      service: service,
    );
    await _waitAlbActive(
      ctx,
      aws,
      region: region,
      loadBalancerArn: alb.arn,
    );

    final dns = alb.dnsName;
    await ctx.patchPublicHosts(dns);
    if (!runner.dryRun) {
      await _persist(
        ctx,
        acfg,
        publicHost: dns,
        cluster: cluster,
        loadBalancerArn: alb.arn,
        targetGroupArn: tgArn,
        ecrRepository: repo,
      );
    }

    final url = 'http://$dns';
    log.ok('ECS+ALB: $url');
    log.detail(
      'WebSocket probe: curl -i -H "Connection: Upgrade" -H "Upgrade: websocket" '
      '… $url/v1/websocket  (expect 101, not 403)',
    );
    return HostDeployResult(publicHost: dns, displayUrl: url);
  }

  // ── network ────────────────────────────────────────────────

  Future<({String vpcId, List<String> subnetIds})> _resolveNetwork(
    DeployContext ctx,
    String aws, {
    required String region,
    required AwsEcsConfig acfg,
  }) async {
    if (ctx.runner.dryRun) {
      return (vpcId: 'vpc-dry', subnetIds: ['subnet-a', 'subnet-b']);
    }
    var vpcId = acfg.vpcId;
    if (vpcId == null || vpcId.isEmpty) {
      final r = await ctx.runner.runCapture(
        aws,
        [
          'ec2',
          'describe-vpcs',
          '--filters',
          'Name=isDefault,Values=true',
          '--query',
          'Vpcs[0].VpcId',
          '--output',
          'text',
          '--region',
          region,
        ],
        allowDryRun: false,
      );
      vpcId = r.stdout.trim();
      if (!r.ok || vpcId.isEmpty || vpcId == 'None') {
        throw StateError(
          'No default VPC — set aws_ecs.vpc_id and aws_ecs.subnet_ids',
        );
      }
    }
    List<String> subnets = acfg.subnetIds;
    if (subnets.isEmpty) {
      final r = await ctx.runner.runCapture(
        aws,
        [
          'ec2',
          'describe-subnets',
          '--filters',
          'Name=vpc-id,Values=$vpcId',
          '--query',
          'Subnets[*].SubnetId',
          '--output',
          'text',
          '--region',
          region,
        ],
        allowDryRun: false,
      );
      subnets = r.stdout
          .trim()
          .split(RegExp(r'\s+'))
          .where((s) => s.isNotEmpty)
          .toList();
      if (subnets.length < 2) {
        throw StateError(
          'Need ≥2 subnets in VPC $vpcId for ALB — set aws_ecs.subnet_ids',
        );
      }
    }
    // ALB needs subnets in ≥2 AZs; take first 2+ as provided
    ctx.log.detail('VPC $vpcId subnets: ${subnets.take(4).join(', ')}…');
    return (vpcId: vpcId, subnetIds: subnets);
  }

  // ── ECR / Docker (same pattern as App Runner) ──────────────

  Future<String> _accountId(DeployContext ctx, String aws) async {
    if (ctx.runner.dryRun) return '123456789012';
    final r = await ctx.runner.runCapture(
      aws,
      ['sts', 'get-caller-identity', '--query', 'Account', '--output', 'text'],
      allowDryRun: false,
    );
    final id = r.stdout.trim();
    if (!r.ok || id.isEmpty) {
      throw StateError('aws sts get-caller-identity failed');
    }
    return id;
  }

  Future<void> _ensureEcrRepo(
    DeployContext ctx,
    String aws, {
    required String region,
    required String repo,
  }) async {
    if (ctx.runner.dryRun) {
      ctx.log.dry('ecr ensure $repo');
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
    if (desc.ok) return;
    final create = await ctx.runner.run(
      aws,
      [
        'ecr',
        'create-repository',
        '--repository-name',
        repo,
        '--region',
        region,
      ],
      allowDryRun: false,
    );
    if (!create.ok) {
      throw StateError('ecr create-repository failed (${create.exitCode})');
    }
  }

  Future<void> _ecrLogin(
    DeployContext ctx,
    String aws,
    String docker, {
    required String account,
    required String region,
  }) async {
    if (ctx.runner.dryRun) {
      ctx.log.dry('ecr docker login');
      return;
    }
    final pass = await ctx.runner.runCapture(
      aws,
      ['ecr', 'get-login-password', '--region', region],
      allowDryRun: false,
    );
    if (!pass.ok) throw StateError('ecr get-login-password failed');
    final registry = '$account.dkr.ecr.$region.amazonaws.com';
    final login = await Process.start(
      docker,
      ['login', '--username', 'AWS', '--password-stdin', registry],
    );
    login.stdin.write(pass.stdout.trim());
    await login.stdin.close();
    if (await login.exitCode != 0) {
      throw StateError('docker login to ECR failed');
    }
  }

  Future<void> _dockerBuildAndPush(
    DeployContext ctx, {
    required String docker,
    required String imageUri,
    required String platform,
  }) async {
    final config = ctx.config;
    final rootDocker = File(p.join(config.root, 'Dockerfile'));
    final serverDocker = File(p.join(config.root, config.server, 'Dockerfile'));
    final df = await rootDocker.exists()
        ? 'Dockerfile'
        : (await serverDocker.exists()
            ? p.join(config.server, 'Dockerfile')
            : 'Dockerfile');
    if (ctx.runner.dryRun) {
      ctx.log.dry('docker build --platform $platform -t $imageUri -f $df .');
      ctx.log.dry('docker push $imageUri');
      return;
    }
    ctx.log.detail('docker build $imageUri');
    final build = await ctx.runner.run(
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
      throw StateError('docker build failed (${build.exitCode})');
    }
    final push = await ctx.runner.run(
      docker,
      ['push', imageUri],
      allowDryRun: false,
    );
    if (!push.ok) {
      throw StateError('docker push failed (${push.exitCode})');
    }
  }

  // ── IAM / logs ─────────────────────────────────────────────

  Future<String> _ensureExecutionRole(
    DeployContext ctx,
    String aws, {
    required String account,
    required String roleName,
  }) async {
    final arn = 'arn:aws:iam::$account:role/$roleName';
    if (ctx.runner.dryRun) {
      ctx.log.dry('iam role $roleName');
      return arn;
    }
    final get = await ctx.runner.runCapture(
      aws,
      ['iam', 'get-role', '--role-name', roleName, '--output', 'json'],
      allowDryRun: false,
    );
    if (get.ok) return arn;
    ctx.log.detail('creating IAM role $roleName');
    final trust = jsonEncode({
      'Version': '2012-10-17',
      'Statement': [
        {
          'Effect': 'Allow',
          'Principal': {'Service': 'ecs-tasks.amazonaws.com'},
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
        'podfly ECS task execution',
      ],
      allowDryRun: false,
    );
    if (!create.ok) {
      throw StateError('iam create-role failed (${create.exitCode})');
    }
    await ctx.runner.run(
      aws,
      [
        'iam',
        'attach-role-policy',
        '--role-name',
        roleName,
        '--policy-arn',
        'arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy',
      ],
      allowDryRun: false,
    );
    await Future<void>.delayed(const Duration(seconds: 10));
    return arn;
  }

  Future<void> _ensureLogGroup(
    DeployContext ctx,
    String aws, {
    required String region,
    required String group,
  }) async {
    if (ctx.runner.dryRun) {
      ctx.log.dry('logs ensure $group');
      return;
    }
    final r = await ctx.runner.runCapture(
      aws,
      [
        'logs',
        'describe-log-groups',
        '--log-group-name-prefix',
        group,
        '--region',
        region,
        '--query',
        'logGroups[?logGroupName==`$group`].logGroupName',
        '--output',
        'text',
      ],
      allowDryRun: false,
    );
    if (r.ok && r.stdout.trim() == group) return;
    await ctx.runner.run(
      aws,
      [
        'logs',
        'create-log-group',
        '--log-group-name',
        group,
        '--region',
        region,
      ],
      allowDryRun: false,
    );
  }

  // ── security groups ────────────────────────────────────────

  Future<String> _ensureSecurityGroup(
    DeployContext ctx,
    String aws, {
    required String region,
    required String vpcId,
    required String name,
    required String description,
    required List<
            ({
              String protocol,
              int port,
              String? cidr,
              String? sourceSg,
            })>
        ingress,
  }) async {
    if (ctx.runner.dryRun) return 'sg-dryrun';
    final find = await ctx.runner.runCapture(
      aws,
      [
        'ec2',
        'describe-security-groups',
        '--filters',
        'Name=vpc-id,Values=$vpcId',
        'Name=group-name,Values=$name',
        '--query',
        'SecurityGroups[0].GroupId',
        '--output',
        'text',
        '--region',
        region,
      ],
      allowDryRun: false,
    );
    var sgId = find.stdout.trim();
    if (find.ok && sgId.isNotEmpty && sgId != 'None') {
      return sgId;
    }
    final create = await ctx.runner.runCapture(
      aws,
      [
        'ec2',
        'create-security-group',
        '--group-name',
        name,
        '--description',
        description,
        '--vpc-id',
        vpcId,
        '--region',
        region,
        '--output',
        'json',
      ],
      allowDryRun: false,
    );
    if (!create.ok) {
      throw StateError('create-security-group failed: ${create.stderr}');
    }
    sgId = _jsonGet(create.stdout, 'GroupId') ?? '';
    if (sgId.isEmpty) throw StateError('no GroupId from create-security-group');

    for (final rule in ingress) {
      final args = <String>[
        'ec2',
        'authorize-security-group-ingress',
        '--group-id',
        sgId,
        '--protocol',
        rule.protocol,
        '--port',
        '${rule.port}',
        '--region',
        region,
      ];
      if (rule.cidr != null) {
        args.addAll(['--cidr', rule.cidr!]);
      } else if (rule.sourceSg != null) {
        args.addAll([
          '--source-group',
          rule.sourceSg!,
        ]);
      }
      await ctx.runner.run(aws, args, allowDryRun: false);
    }
    return sgId;
  }

  // ── ALB ────────────────────────────────────────────────────

  Future<({String arn, String dnsName})> _ensureAlb(
    DeployContext ctx,
    String aws, {
    required String region,
    required String name,
    required List<String> subnets,
    required List<String> securityGroups,
    required int idleTimeout,
  }) async {
    if (ctx.runner.dryRun) {
      return (arn: 'arn:alb', dnsName: 'dryrun.elb.amazonaws.com');
    }
    final find = await ctx.runner.runCapture(
      aws,
      [
        'elbv2',
        'describe-load-balancers',
        '--names',
        name,
        '--region',
        region,
        '--output',
        'json',
      ],
      allowDryRun: false,
    );
    String arn;
    String dns;
    if (find.ok && find.stdout.contains('LoadBalancerArn')) {
      arn = _jsonListFirst(find.stdout, 'LoadBalancers', 'LoadBalancerArn') ??
          '';
      dns = _jsonListFirst(find.stdout, 'LoadBalancers', 'DNSName') ?? '';
    } else {
      // ALB needs subnets in ≥2 AZs — pass all public subnets
      final create = await ctx.runner.runCapture(
        aws,
        [
          'elbv2',
          'create-load-balancer',
          '--name',
          name,
          '--subnets',
          ...subnets,
          '--security-groups',
          ...securityGroups,
          '--scheme',
          'internet-facing',
          '--type',
          'application',
          '--ip-address-type',
          'ipv4',
          '--region',
          region,
          '--output',
          'json',
        ],
        allowDryRun: false,
      );
      if (!create.ok) {
        throw StateError('create-load-balancer failed: ${create.stderr}');
      }
      arn =
          _jsonListFirst(create.stdout, 'LoadBalancers', 'LoadBalancerArn') ??
              '';
      dns = _jsonListFirst(create.stdout, 'LoadBalancers', 'DNSName') ?? '';
    }
    if (arn.isEmpty) throw StateError('no ALB ARN');
    await ctx.runner.run(
      aws,
      [
        'elbv2',
        'modify-load-balancer-attributes',
        '--load-balancer-arn',
        arn,
        '--attributes',
        'Key=idle_timeout.timeout_seconds,Value=$idleTimeout',
        '--region',
        region,
      ],
      allowDryRun: false,
    );
    ctx.log.detail('ALB $dns (idle_timeout=${idleTimeout}s)');
    return (arn: arn, dnsName: dns);
  }

  Future<String> _ensureTargetGroup(
    DeployContext ctx,
    String aws, {
    required String region,
    required String name,
    required String vpcId,
    required int port,
    required bool stickiness,
  }) async {
    if (ctx.runner.dryRun) return 'arn:tg';
    final find = await ctx.runner.runCapture(
      aws,
      [
        'elbv2',
        'describe-target-groups',
        '--names',
        name,
        '--region',
        region,
        '--output',
        'json',
      ],
      allowDryRun: false,
    );
    String arn;
    if (find.ok && find.stdout.contains('TargetGroupArn')) {
      arn = _jsonListFirst(find.stdout, 'TargetGroups', 'TargetGroupArn') ?? '';
    } else {
      final create = await ctx.runner.runCapture(
        aws,
        [
          'elbv2',
          'create-target-group',
          '--name',
          name,
          '--protocol',
          'HTTP',
          '--port',
          '$port',
          '--vpc-id',
          vpcId,
          '--target-type',
          'ip',
          '--health-check-protocol',
          'HTTP',
          '--health-check-path',
          '/',
          '--health-check-interval-seconds',
          '30',
          '--healthy-threshold-count',
          '2',
          '--unhealthy-threshold-count',
          '3',
          '--region',
          region,
          '--output',
          'json',
        ],
        allowDryRun: false,
      );
      if (!create.ok) {
        throw StateError('create-target-group failed: ${create.stderr}');
      }
      arn =
          _jsonListFirst(create.stdout, 'TargetGroups', 'TargetGroupArn') ?? '';
    }
    if (arn.isEmpty) throw StateError('no target group ARN');
    if (stickiness) {
      await ctx.runner.run(
        aws,
        [
          'elbv2',
          'modify-target-group-attributes',
          '--target-group-arn',
          arn,
          '--attributes',
          'Key=stickiness.enabled,Value=true',
          'Key=stickiness.type,Value=lb_cookie',
          'Key=stickiness.lb_cookie.duration_seconds,Value=86400',
          '--region',
          region,
        ],
        allowDryRun: false,
      );
    }
    return arn;
  }

  Future<void> _ensureHttpListener(
    DeployContext ctx,
    String aws, {
    required String region,
    required String loadBalancerArn,
    required String targetGroupArn,
  }) async {
    if (ctx.runner.dryRun) return;
    final list = await ctx.runner.runCapture(
      aws,
      [
        'elbv2',
        'describe-listeners',
        '--load-balancer-arn',
        loadBalancerArn,
        '--region',
        region,
        '--output',
        'json',
      ],
      allowDryRun: false,
    );
    if (list.ok && list.stdout.contains('"Port": 80')) {
      // Ensure default action points at our TG
      final listenerArn =
          _jsonListFirst(list.stdout, 'Listeners', 'ListenerArn');
      if (listenerArn != null) {
        await ctx.runner.run(
          aws,
          [
            'elbv2',
            'modify-listener',
            '--listener-arn',
            listenerArn,
            '--default-actions',
            'Type=forward,TargetGroupArn=$targetGroupArn',
            '--region',
            region,
          ],
          allowDryRun: false,
        );
      }
      return;
    }
    final create = await ctx.runner.run(
      aws,
      [
        'elbv2',
        'create-listener',
        '--load-balancer-arn',
        loadBalancerArn,
        '--protocol',
        'HTTP',
        '--port',
        '80',
        '--default-actions',
        'Type=forward,TargetGroupArn=$targetGroupArn',
        '--region',
        region,
      ],
      allowDryRun: false,
    );
    if (!create.ok) {
      throw StateError('create-listener failed (${create.exitCode})');
    }
  }

  // ── ECS ────────────────────────────────────────────────────

  Future<void> _ensureCluster(
    DeployContext ctx,
    String aws, {
    required String region,
    required String cluster,
  }) async {
    if (ctx.runner.dryRun) {
      ctx.log.dry('ecs cluster $cluster');
      return;
    }
    final desc = await ctx.runner.runCapture(
      aws,
      [
        'ecs',
        'describe-clusters',
        '--clusters',
        cluster,
        '--region',
        region,
        '--query',
        'clusters[0].status',
        '--output',
        'text',
      ],
      allowDryRun: false,
    );
    if (desc.ok && desc.stdout.trim() == 'ACTIVE') return;
    await ctx.runner.run(
      aws,
      [
        'ecs',
        'create-cluster',
        '--cluster-name',
        cluster,
        '--region',
        region,
      ],
      allowDryRun: false,
    );
  }

  Future<String> _registerTaskDefinition(
    DeployContext ctx,
    String aws, {
    required String region,
    required String family,
    required String imageUri,
    required String cpu,
    required String memory,
    required int port,
    required String executionRoleArn,
    required String logGroup,
    required String logRegion,
    required Map<String, String> env,
  }) async {
    if (ctx.runner.dryRun) return 'arn:task-def';
    final container = {
      'name': 'app',
      'image': imageUri,
      'essential': true,
      'portMappings': [
        {'containerPort': port, 'protocol': 'tcp'},
      ],
      'environment': [
        for (final e in env.entries) {'name': e.key, 'value': e.value},
      ],
      'logConfiguration': {
        'logDriver': 'awslogs',
        'options': {
          'awslogs-group': logGroup,
          'awslogs-region': logRegion,
          'awslogs-stream-prefix': 'app',
        },
      },
    };
    final td = {
      'family': family,
      'networkMode': 'awsvpc',
      'requiresCompatibilities': ['FARGATE'],
      'cpu': cpu,
      'memory': memory,
      'executionRoleArn': executionRoleArn,
      'containerDefinitions': [container],
    };
    // Write temp file — CLI accepts file://
    final tmp = File(
      p.join(
        Directory.systemTemp.path,
        'podfly-td-${family.replaceAll(RegExp(r'[^a-zA-Z0-9-]'), '-')}.json',
      ),
    );
    await tmp.writeAsString(jsonEncode(td));
    final r = await ctx.runner.runCapture(
      aws,
      [
        'ecs',
        'register-task-definition',
        '--cli-input-json',
        'file://${tmp.path}',
        '--region',
        region,
        '--output',
        'json',
      ],
      allowDryRun: false,
    );
    try {
      await tmp.delete();
    } catch (_) {}
    if (!r.ok) {
      throw StateError('register-task-definition failed: ${r.stderr}');
    }
    final arn = _jsonNested(r.stdout, 'taskDefinition', 'taskDefinitionArn');
    if (arn == null || arn.isEmpty) {
      throw StateError('no taskDefinitionArn');
    }
    ctx.log.detail('task def $arn');
    return arn;
  }

  Future<void> _ensureEcsService(
    DeployContext ctx,
    String aws, {
    required String region,
    required String cluster,
    required String serviceName,
    required String taskDefinition,
    required List<String> subnets,
    required List<String> securityGroups,
    required String targetGroupArn,
    required String containerName,
    required int containerPort,
    required int desiredCount,
    required bool assignPublicIp,
  }) async {
    if (ctx.runner.dryRun) {
      ctx.log.dry('ecs service $serviceName');
      return;
    }
    final desc = await ctx.runner.runCapture(
      aws,
      [
        'ecs',
        'describe-services',
        '--cluster',
        cluster,
        '--services',
        serviceName,
        '--region',
        region,
        '--query',
        'services[0].status',
        '--output',
        'text',
      ],
      allowDryRun: false,
    );
    final status = desc.stdout.trim();
    final net = 'awsvpcConfiguration={subnets=[${subnets.join(',')}],'
        'securityGroups=[${securityGroups.join(',')}],'
        'assignPublicIp=${assignPublicIp ? 'ENABLED' : 'DISABLED'}}';
    final lb =
        'targetGroupArn=$targetGroupArn,containerName=$containerName,containerPort=$containerPort';

    if (desc.ok && (status == 'ACTIVE' || status == 'DRAINING')) {
      ctx.log.detail('updating ECS service $serviceName');
      final u = await ctx.runner.run(
        aws,
        [
          'ecs',
          'update-service',
          '--cluster',
          cluster,
          '--service',
          serviceName,
          '--task-definition',
          taskDefinition,
          '--desired-count',
          '$desiredCount',
          '--network-configuration',
          net,
          '--force-new-deployment',
          '--region',
          region,
        ],
        allowDryRun: false,
      );
      if (!u.ok) {
        throw StateError('ecs update-service failed (${u.exitCode})');
      }
      return;
    }

    ctx.log.detail('creating ECS service $serviceName');
    final c = await ctx.runner.run(
      aws,
      [
        'ecs',
        'create-service',
        '--cluster',
        cluster,
        '--service-name',
        serviceName,
        '--task-definition',
        taskDefinition,
        '--desired-count',
        '$desiredCount',
        '--launch-type',
        'FARGATE',
        '--platform-version',
        'LATEST',
        '--network-configuration',
        net,
        '--load-balancers',
        lb,
        '--health-check-grace-period-seconds',
        '180',
        '--region',
        region,
      ],
      allowDryRun: false,
    );
    if (!c.ok) {
      throw StateError('ecs create-service failed (${c.exitCode}): check logs');
    }
  }

  Future<void> _waitServiceStable(
    DeployContext ctx,
    String aws, {
    required String region,
    required String cluster,
    required String service,
  }) async {
    if (ctx.runner.dryRun) {
      ctx.log.dry('wait ecs services-stable');
      return;
    }
    ctx.log.detail('waiting for ECS service stable…');
    final r = await ctx.runner.run(
      aws,
      [
        'ecs',
        'wait',
        'services-stable',
        '--cluster',
        cluster,
        '--services',
        service,
        '--region',
        region,
      ],
      allowDryRun: false,
    );
    if (!r.ok) {
      // wait can time out; check running count
      final d = await ctx.runner.runCapture(
        aws,
        [
          'ecs',
          'describe-services',
          '--cluster',
          cluster,
          '--services',
          service,
          '--region',
          region,
          '--query',
          'services[0].{r:runningCount,d:desiredCount,st:status}',
          '--output',
          'json',
        ],
        allowDryRun: false,
      );
      throw StateError(
        'ECS service not stable (wait exit ${r.exitCode}). '
        'Status: ${d.stdout}. Check CloudWatch $cluster / ELB target health.',
      );
    }
    ctx.log.detail('ECS service stable');
  }

  Future<void> _waitAlbActive(
    DeployContext ctx,
    String aws, {
    required String region,
    required String loadBalancerArn,
  }) async {
    if (ctx.runner.dryRun) {
      ctx.log.dry('wait alb available');
      return;
    }
    ctx.log.detail('waiting for ALB active (DNS)…');
    // elbv2 wait load-balancers-available
    final r = await ctx.runner.run(
      aws,
      [
        'elbv2',
        'wait',
        'load-balancers-available',
        '--load-balancer-arns',
        loadBalancerArn,
        '--region',
        region,
      ],
      allowDryRun: false,
    );
    if (!r.ok) {
      ctx.log.warn(
        'ALB wait timed out — DNS may need another minute before smoke',
      );
      return;
    }
    // Brief DNS settle
    await Future<void>.delayed(const Duration(seconds: 10));
    ctx.log.detail('ALB available');
  }

  Future<void> _persist(
    DeployContext ctx,
    AwsEcsConfig base, {
    required String publicHost,
    required String cluster,
    required String loadBalancerArn,
    required String targetGroupArn,
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
      aws: cfg.aws,
      awsEcs: AwsEcsConfig(
        service: base.service,
        region: base.region,
        cluster: cluster,
        cpu: base.cpu,
        memory: base.memory,
        port: base.port,
        desiredCount: base.desiredCount,
        ecrRepository: ecrRepository,
        executionRole: base.executionRole,
        taskFamily: base.taskFamily ?? base.service,
        logGroup: base.logGroup,
        idleTimeoutSeconds: base.idleTimeoutSeconds,
        stickiness: base.stickiness,
        assignPublicIp: base.assignPublicIp,
        platform: base.platform,
        imageTag: base.imageTag,
        vpcId: base.vpcId,
        subnetIds: base.subnetIds,
        loadBalancerArn: loadBalancerArn,
        targetGroupArn: targetGroupArn,
        extraEnv: base.extraEnv,
        publicHost: publicHost,
      ),
      azure: cfg.azure,
      hetzner: cfg.hetzner,
      cloudflare: cfg.cloudflare,
      database: cfg.database,
      web: WebConfig(
        enabled: cfg.web.enabled,
        serverUrlDefine: cfg.web.serverUrlDefine,
        apiUrl: 'http://$publicHost/',
        patchBootstrap: cfg.web.patchBootstrap,
        writeHeaders: cfg.web.writeHeaders,
        baseHref: cfg.web.baseHref,
        staticDir: cfg.web.staticDir,
      ),
      smoke: cfg.smoke,
    );
    await updated.save();
    ctx.log.detail('saved aws_ecs.public_host → $publicHost');
  }

  static String _clipName(String s, int max) {
    final cleaned = s.replaceAll(RegExp(r'[^a-zA-Z0-9-]'), '-');
    if (cleaned.length <= max) return cleaned;
    return cleaned.substring(0, max);
  }

  static String? _jsonGet(String raw, String key) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return m[key]?.toString();
    } catch (_) {
      return null;
    }
  }

  static String? _jsonNested(String raw, String a, String b) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final inner = m[a];
      if (inner is Map) return inner[b]?.toString();
    } catch (_) {}
    return null;
  }

  static String? _jsonListFirst(String raw, String listKey, String field) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final list = m[listKey] as List<dynamic>?;
      if (list != null && list.isNotEmpty && list.first is Map) {
        return (list.first as Map)[field]?.toString();
      }
    } catch (_) {}
    return null;
  }
}
