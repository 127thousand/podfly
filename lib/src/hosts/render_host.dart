import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../fly_name.dart';
import '../log.dart';
import '../process_runner.dart';
import 'adapter.dart';
import 'auth_helpers.dart';

/// Render App Platform host — git + Docker web service (+ optional Postgres).
///
/// Usual Render path: linked GitHub/GitLab repo, optional monorepo [RenderConfig.rootDir],
/// Dockerfile build on Render. Auth: `render login` or `RENDER_API_KEY`.
class RenderHost extends HostAdapter {
  @override
  String get id => 'render';

  @override
  String get label => 'Render';

  @override
  List<String> get cliBinaries => const ['render'];

  @override
  String get installHint => 'https://render.com/docs/cli';

  @override
  List<CliInstallRecipe> get installRecipes => const [
        CliInstallRecipe(
          label: 'brew install render',
          executable: 'brew',
          args: ['install', 'render'],
        ),
        CliInstallRecipe(
          label: 'curl install script (render-oss/cli)',
          executable: 'sh',
          args: [
            '-c',
            'curl -fsSL https://raw.githubusercontent.com/render-oss/cli/refs/heads/main/bin/install.sh | sh',
          ],
          needsShell: true,
        ),
      ];

  @override
  bool get canDeploy => true;

  @override
  AppHost get appHost => AppHost.render;

  @override
  String get configKey => 'render';

  @override
  List<DatabaseProvider> get supportedDatabases => const [
        DatabaseProvider.none,
        DatabaseProvider.renderPostgres,
        DatabaseProvider.neon,
      ];

  @override
  String defaultApiUrl({
    required String name,
    required String sanitizedName,
  }) =>
      'https://$sanitizedName.onrender.com/';

  @override
  String? publicApiBase(PodflyConfig config) {
    final r = config.render;
    if (r == null) return null;
    final h = r.publicHost;
    if (h != null && h.isNotEmpty) {
      return h.startsWith('http') ? (h.endsWith('/') ? h : '$h/') : 'https://$h/';
    }
    return 'https://${r.service}.onrender.com/';
  }

  @override
  String secretSetHint(String secretName, PodflyConfig config) =>
      'set $secretName on Render service ${config.render?.service ?? config.name} '
      '(Dashboard → Environment, or re-run podfly deploy)';

  @override
  Future<bool> checkAuth(DoctorContext ctx) {
    return authViaWhoami(
      ctx: ctx,
      whoamiArgs: const ['whoami'],
      loginCommand: 'render login',
      loginArgs: const ['login'],
      tokenEnv: 'RENDER_API_KEY',
      failSubstrings: const [
        'not logged',
        'unauthorized',
        'no workspace',
        'authentication',
      ],
    );
  }

  @override
  void configWarnings(PodflyConfig config, Log log) {
    final r = config.render;
    if (r == null) return;
    if (r.repo == null || r.repo!.trim().isEmpty) {
      log.warn(
        'render.repo is required for git-based deploys '
        '(e.g. https://github.com/org/podfly_examples)',
      );
    }
    if (config.database.provider == DatabaseProvider.renderPostgres) {
      log.detail(
        'Render free Postgres expires ~30 days; use a paid plan for production',
      );
    }
  }

  @override
  Future<HostDeployResult> deployApi(DeployContext ctx) async {
    final config = ctx.config;
    final runner = ctx.runner;
    final log = ctx.log;

    final rcfg = config.render ??
        RenderConfig(service: sanitizeFlyAppName(config.name));
    final serviceName = sanitizeFlyAppName(rcfg.service);
    log.step('Deploy Render API ($serviceName)');

    final render = await runner.resolve('render');
    if (render == null) throw StateError('render CLI not found');

    await _ensureBlueprint(ctx, rcfg, serviceName);

    final repo = rcfg.repo?.trim();
    if (repo == null || repo.isEmpty) {
      throw StateError(
        'render.repo is required. Set in podfly.yaml:\n'
        '  render:\n'
        '    repo: https://github.com/ORG/podfly_examples\n'
        '    root_dir: render/api_postgres   # monorepo leaf (optional)\n'
        'Render builds from git (usual path).',
      );
    }

    final serviceId = await _ensureWebService(
      ctx,
      render: render,
      rcfg: rcfg,
      serviceName: serviceName,
      repo: repo,
    );

    // Push latest: for git-backed services a new deploy pulls HEAD of the branch.
    log.detail('trigger deploy $serviceId');
    if (!runner.dryRun) {
      final dep = await runner.run(
        render,
        [
          'deploys',
          'create',
          serviceId,
          '--wait',
          '--confirm',
          '-o',
          'json',
        ],
        allowDryRun: false,
      );
      if (!dep.ok) {
        // First create may already have started a deploy; don't hard-fail only on wait.
        log.warn(
          'render deploys create exited ${dep.exitCode} '
          '(service may still be building — check Dashboard)',
        );
      }
    } else {
      log.dry('$render deploys create $serviceId --wait');
    }

    final publicHost = await _resolveServiceHost(
      runner,
      render,
      serviceId,
      serviceName,
    );
    await ctx.patchPublicHosts(publicHost);

    if (!runner.dryRun) {
      await _persistPublicHost(ctx, publicHost, serviceId);
    }

    final url = 'https://$publicHost';
    log.ok('Render: $url');
    return HostDeployResult(publicHost: publicHost, displayUrl: url);
  }

  Future<void> _ensureBlueprint(
    DeployContext ctx,
    RenderConfig rcfg,
    String serviceName,
  ) async {
    final path = p.join(ctx.config.root, rcfg.blueprint);
    final dockerfileRel = rcfg.dockerfilePath ??
        p.join(ctx.config.server, 'Dockerfile');
    final rootDir = rcfg.rootDir;

    final buf = StringBuffer();
    buf.writeln('# Generated by podfly — Render Blueprint (IaC)');
    buf.writeln('# https://render.com/docs/blueprint-spec');
    buf.writeln('# Monorepo: set rootDir so the example need not be repo root.');
    buf.writeln('services:');
    buf.writeln('  - type: web');
    buf.writeln('    name: $serviceName');
    buf.writeln('    runtime: docker');
    buf.writeln('    plan: ${rcfg.plan}');
    buf.writeln('    region: ${rcfg.region}');
    if (rootDir != null && rootDir.isNotEmpty) {
      buf.writeln('    rootDir: $rootDir');
    }
    // Paths relative to rootDir when set, else repo root.
    buf.writeln('    dockerfilePath: ./$dockerfileRel');
    buf.writeln('    dockerContext: .');
    buf.writeln('    healthCheckPath: /');
    buf.writeln('    envVars:');
    buf.writeln('      - key: runmode');
    buf.writeln('        value: production');
    buf.writeln('      - key: SERVERPOD_RUN_MODE');
    buf.writeln('        value: production');
    if (ctx.config.database.provider == DatabaseProvider.renderPostgres) {
      final dbName = ctx.config.database.renderPostgres?.name ??
          '$serviceName-db';
      buf.writeln('      - key: DATABASE_URL');
      buf.writeln('        fromDatabase:');
      buf.writeln('          name: $dbName');
      buf.writeln('          property: connectionString');
      buf.writeln('databases:');
      buf.writeln('  - name: $dbName');
      buf.writeln(
          '    plan: ${ctx.config.database.renderPostgres?.plan ?? 'free'}');
      buf.writeln(
          '    region: ${ctx.config.database.renderPostgres?.region ?? rcfg.region}');
    }

    if (ctx.runner.dryRun) {
      ctx.log.dry('write $path');
      return;
    }
    if (await File(path).exists()) {
      ctx.log.detail('keeping existing ${rcfg.blueprint}');
      return;
    }
    await File(path).writeAsString(buf.toString());
    ctx.log.ok('wrote ${rcfg.blueprint}');
  }

  Future<String> _ensureWebService(
    DeployContext ctx, {
    required String render,
    required RenderConfig rcfg,
    required String serviceName,
    required String repo,
  }) async {
    final runner = ctx.runner;
    final log = ctx.log;

    if (rcfg.serviceId != null && rcfg.serviceId!.isNotEmpty) {
      log.detail('using render.service_id ${rcfg.serviceId}');
      return rcfg.serviceId!;
    }

    final existing = await _findServiceId(runner, render, serviceName);
    if (existing != null) {
      log.detail('Render service $serviceName exists ($existing)');
      return existing;
    }

    if (runner.dryRun) {
      log.dry(
        '$render services create --name $serviceName --type web_service '
        '--runtime docker --repo $repo …',
      );
      return 'srv-dry-run';
    }

    final args = <String>[
      'services',
      'create',
      '--name',
      serviceName,
      '--type',
      'web_service',
      '--runtime',
      'docker',
      '--repo',
      repo,
      '--branch',
      rcfg.branch,
      '--region',
      rcfg.region,
      '--plan',
      rcfg.plan,
      '--auto-deploy',
      '--env-var',
      'runmode=production',
      '--env-var',
      'SERVERPOD_RUN_MODE=production',
      '--confirm',
      '-o',
      'json',
    ];
    if (rcfg.rootDir != null && rcfg.rootDir!.isNotEmpty) {
      args.addAll(['--root-directory', rcfg.rootDir!]);
    }

    // Serverpod accepts SERVERPOD_PASSWORD_database (see runtime error).
    // Do not pass postgres:// URLs as --env-var (colons break Render's parser).
    // Do not use --secret-file with absolute paths here — the CLI/API 400s on
    // those KEY=VALUE-style flags when values contain ':'.
    final sidecar = await _readRenderPgSidecar(ctx.config);
    final dbPass = sidecar?['password'];
    if (dbPass != null && dbPass.isNotEmpty) {
      args.addAll(['--env-var', 'SERVERPOD_PASSWORD_database=$dbPass']);
    }
    // Host/user/db must be in config/production.yaml in the git tree (commit
    // after first patch) so the Docker image has them.

    log.detail('creating Render web service $serviceName');
    final create = await runner.runCapture(
      render,
      args,
      allowDryRun: false,
    );
    if (!create.ok) {
      throw StateError(
        'render services create failed (exit ${create.exitCode}): '
        '${create.stderr.isNotEmpty ? create.stderr : create.stdout}',
      );
    }

    final id = _extractServiceId(create.stdout) ??
        await _findServiceId(runner, render, serviceName);
    if (id == null) {
      throw StateError(
        'created Render service but could not parse id from CLI output',
      );
    }
    log.ok('created Render service $serviceName ($id)');
    await _persistServiceId(ctx, id);
    return id;
  }

  Future<Map<String, String>?> _readRenderPgSidecar(PodflyConfig config) async {
    final file = File(
      p.join(config.serverPath, 'config', '.podfly_render_pg.json'),
    );
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      return decoded.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
    } catch (_) {
      return null;
    }
  }

  Future<String?> _findServiceId(
    ProcessRunner runner,
    String render,
    String name,
  ) async {
    if (runner.dryRun) return null;
    final list = await runner.runCapture(
      render,
      ['services', '-o', 'json', '--confirm'],
      allowDryRun: false,
    );
    if (!list.ok) return null;
    final raw = list.stdout.trim();
    if (raw.isEmpty || raw == 'null') return null;
    try {
      final decoded = jsonDecode(raw);
      final items = _asList(decoded);
      for (final item in items) {
        if (item is! Map) continue;
        // CLI returns mixed list: {service: {...}} | {postgres: {...}}
        final nested = item['service'] ?? item['postgres'] ?? item;
        if (nested is! Map) continue;
        final n = nested['name']?.toString();
        final id = nested['id']?.toString();
        final type = nested['type']?.toString() ?? '';
        // Prefer web services over postgres rows with the same listing shape
        if (n == name &&
            id != null &&
            id.isNotEmpty &&
            (type.contains('web') || id.startsWith('srv-'))) {
          return id;
        }
      }
    } catch (_) {/* ignore */}
    return null;
  }

  List<dynamic> _asList(Object? decoded) {
    if (decoded is List) return decoded;
    if (decoded is Map) {
      final d = decoded['data'] ?? decoded['services'];
      if (d is List) return d;
    }
    return const [];
  }

  String? _extractServiceId(String stdout) {
    try {
      final decoded = jsonDecode(stdout);
      if (decoded is Map) {
        final data = decoded['data'] ?? decoded;
        if (data is Map) {
          final id = data['id'] ?? data['serviceId'];
          if (id != null) return id.toString();
          final svc = data['service'];
          if (svc is Map && svc['id'] != null) return svc['id'].toString();
        }
      }
    } catch (_) {/* fall through */}
    final m = RegExp(r'srv-[a-z0-9]+').firstMatch(stdout);
    return m?.group(0);
  }

  Future<String> _resolveServiceHost(
    ProcessRunner runner,
    String render,
    String serviceId,
    String serviceName,
  ) async {
    if (runner.dryRun) return '$serviceName.onrender.com';
    final get = await runner.runCapture(
      render,
      ['services', serviceId, '-o', 'json', '--confirm'],
      allowDryRun: false,
    );
    // CLI may use `services` list only — try parse or fallback.
    final text = get.stdout + get.stderr;
    final urlMatch = RegExp(
      r'https?://([a-zA-Z0-9.-]+\.onrender\.com)',
    ).firstMatch(text);
    if (urlMatch != null) return urlMatch.group(1)!;
    try {
      final decoded = jsonDecode(get.stdout);
      final host = _findOnRenderHost(decoded);
      if (host != null) return host;
    } catch (_) {/* fallback */}
    return '$serviceName.onrender.com';
  }

  String? _findOnRenderHost(Object? node) {
    if (node is Map) {
      for (final e in node.entries) {
        final k = e.key.toString().toLowerCase();
        final v = e.value;
        if (v is String && v.contains('.onrender.com')) {
          final u = v.replaceFirst(RegExp(r'^https?://'), '');
          return u.split('/').first;
        }
        if ((k.contains('host') || k.contains('url')) && v is String) {
          final cleaned = v.replaceFirst(RegExp(r'^https?://'), '');
          if (cleaned.contains('onrender.com')) {
            return cleaned.split('/').first;
          }
        }
        final nested = _findOnRenderHost(v);
        if (nested != null) return nested;
      }
    } else if (node is List) {
      for (final i in node) {
        final nested = _findOnRenderHost(i);
        if (nested != null) return nested;
      }
    }
    return null;
  }

  Future<void> _persistServiceId(DeployContext ctx, String id) async {
    final cfg = ctx.config;
    final r = cfg.render;
    if (r == null) return;
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
      render: RenderConfig(
        service: r.service,
        region: r.region,
        plan: r.plan,
        branch: r.branch,
        repo: r.repo,
        rootDir: r.rootDir,
        dockerfilePath: r.dockerfilePath,
        blueprint: r.blueprint,
        serviceId: id,
        publicHost: r.publicHost,
      ),
      cloudflare: cfg.cloudflare,
      database: cfg.database,
      web: cfg.web,
      smoke: cfg.smoke,
    );
    await updated.save();
    ctx.log.detail('saved render.service_id → $id');
  }

  Future<void> _persistPublicHost(
    DeployContext ctx,
    String host,
    String serviceId,
  ) async {
    final cfg = ctx.config;
    final r = cfg.render;
    if (r == null) return;
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
      render: RenderConfig(
        service: r.service,
        region: r.region,
        plan: r.plan,
        branch: r.branch,
        repo: r.repo,
        rootDir: r.rootDir,
        dockerfilePath: r.dockerfilePath,
        blueprint: r.blueprint,
        serviceId: serviceId,
        publicHost: host,
      ),
      cloudflare: cfg.cloudflare,
      database: cfg.database,
      web: WebConfig(
        enabled: cfg.web.enabled,
        serverUrlDefine: cfg.web.serverUrlDefine,
        apiUrl: 'https://$host/',
        patchBootstrap: cfg.web.patchBootstrap,
        writeHeaders: cfg.web.writeHeaders,
        baseHref: cfg.web.baseHref,
        staticDir: cfg.web.staticDir,
      ),
      smoke: cfg.smoke,
    );
    await updated.save();
  }
}

