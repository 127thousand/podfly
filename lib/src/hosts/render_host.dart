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
  bool get deploysWebNatively => true;

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
  Future<String?> ensureApiPublicHost(DeployContext ctx) async {
    final r = ctx.config.render;
    if (r?.publicHost != null && r!.publicHost!.isNotEmpty) {
      return r.publicHost;
    }
    final name = sanitizeFlyAppName(r?.service ?? ctx.config.name);
    return '$name.onrender.com';
  }

  @override
  Future<HostDeployResult?> deployWeb(DeployContext ctx) async {
    final config = ctx.config;
    final runner = ctx.runner;
    final log = ctx.log;
    final rcfg = config.render ??
        RenderConfig(service: sanitizeFlyAppName(config.name));
    final webName = sanitizeFlyAppName(rcfg.webServiceName);
    log.step('Deploy Render static site ($webName)');

    final render = await runner.resolve('render');
    if (render == null) throw StateError('render CLI not found');

    final repo = rcfg.repo?.trim();
    if (repo == null || repo.isEmpty) {
      throw StateError('render.repo is required for static site deploys');
    }

    // Stage Flutter build → site/ (Render static sites deploy from git).
    await _stageStaticSite(ctx, rcfg);
    await _gitCommitAndPushSite(ctx, rcfg);

    final serviceId = await _ensureStaticSite(
      ctx,
      render: render,
      rcfg: rcfg,
      webName: webName,
      repo: repo,
    );

    log.detail('trigger static deploy $serviceId');
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
        log.warn(
          'render deploys create (static) exited ${dep.exitCode} '
          '— check Dashboard',
        );
      }
    } else {
      log.dry('$render deploys create $serviceId --wait');
    }

    final publicHost = await _resolveServiceHost(
      runner,
      render,
      serviceId,
      webName,
    );
    await _persistWebHost(ctx, publicHost, serviceId);
    final url = 'https://$publicHost';
    log.ok('Render static: $url');
    return HostDeployResult(publicHost: publicHost, displayUrl: url);
  }

  /// Copy `flutter/build/web` → `{siteDir}/` under the monorepo leaf.
  Future<void> _stageStaticSite(DeployContext ctx, RenderConfig rcfg) async {
    final log = ctx.log;
    final src = p.join(ctx.config.flutterPath, 'build', 'web');
    final dest = p.join(ctx.config.root, rcfg.siteDir);
    if (ctx.runner.dryRun) {
      log.dry('stage $src → $dest');
      return;
    }
    final srcDir = Directory(src);
    if (!await srcDir.exists()) {
      throw StateError(
        'Missing Flutter web build at $src — flutter build web should run first',
      );
    }
    final destDir = Directory(dest);
    if (await destDir.exists()) {
      await destDir.delete(recursive: true);
    }
    await destDir.create(recursive: true);
    // Prefer rsync; fall back to recursive copy.
    final rsync = await ctx.runner.resolve('rsync');
    if (rsync != null) {
      final r = await ctx.runner.run(
        rsync,
        ['-a', '--delete', '$src/', '$dest/'],
        allowDryRun: false,
      );
      if (!r.ok) {
        throw StateError('rsync site failed (exit ${r.exitCode})');
      }
    } else {
      await for (final entity in srcDir.list(recursive: true)) {
        final rel = p.relative(entity.path, from: src);
        final target = p.join(dest, rel);
        if (entity is Directory) {
          await Directory(target).create(recursive: true);
        } else if (entity is File) {
          await entity.copy(target);
        }
      }
    }
    // SPA fallback for Flutter client routes (Render serves _redirects on static).
    final redirects = File(p.join(dest, '_redirects'));
    if (!await redirects.exists()) {
      await redirects.writeAsString('/*    /index.html   200\n');
    }
    log.ok('staged static site → ${rcfg.siteDir}/');
  }

  /// Commit + push `site/` so Render's git-based static deploy can see it.
  Future<void> _gitCommitAndPushSite(
    DeployContext ctx,
    RenderConfig rcfg,
  ) async {
    final log = ctx.log;
    final runner = ctx.runner;
    if (runner.dryRun) {
      log.dry('git add ${rcfg.siteDir} && commit && push');
      return;
    }
    // Find git root (podfly_examples monorepo, not necessarily leaf).
    var dir = Directory(ctx.config.root);
    String? gitRoot;
    while (true) {
      if (await Directory(p.join(dir.path, '.git')).exists()) {
        gitRoot = dir.path;
        break;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    if (gitRoot == null) {
      log.warn(
        'No .git above ${ctx.config.root} — commit/push ${rcfg.siteDir}/ '
        'yourself so Render can deploy the static site',
      );
      return;
    }

    final siteRel = p.relative(
      p.join(ctx.config.root, rcfg.siteDir),
      from: gitRoot,
    );
    await runner.run(
      'git',
      ['add', '-A', siteRel],
      workingDirectory: gitRoot,
      allowDryRun: false,
    );
    final st = await runner.runCapture(
      'git',
      ['status', '--porcelain', siteRel],
      workingDirectory: gitRoot,
      allowDryRun: false,
    );
    if (st.stdout.trim().isEmpty) {
      log.detail('site/ already committed — push if needed');
    } else {
      final commit = await runner.run(
        'git',
        [
          '-c',
          'user.email=podfly@local',
          '-c',
          'user.name=podfly',
          'commit',
          '-m',
          'chore: podfly render static site publish (${rcfg.siteDir})',
        ],
        workingDirectory: gitRoot,
        allowDryRun: false,
      );
      if (!commit.ok) {
        log.warn('git commit site/ failed — push manually if needed');
        return;
      }
      log.ok('committed $siteRel');
    }
    final push = await runner.run(
      'git',
      ['push', 'origin', 'HEAD'],
      workingDirectory: gitRoot,
      allowDryRun: false,
    );
    if (!push.ok) {
      log.warn(
        'git push failed — push $siteRel to origin so Render can build',
      );
    } else {
      log.ok('pushed static site to origin');
    }
  }

  Future<String> _ensureStaticSite(
    DeployContext ctx, {
    required String render,
    required RenderConfig rcfg,
    required String webName,
    required String repo,
  }) async {
    final runner = ctx.runner;
    final log = ctx.log;
    if (rcfg.webServiceId != null && rcfg.webServiceId!.isNotEmpty) {
      return rcfg.webServiceId!;
    }
    final existing = await _findServiceId(runner, render, webName);
    if (existing != null) {
      log.detail('Render static site $webName exists ($existing)');
      return existing;
    }
    if (runner.dryRun) {
      log.dry(
        '$render services create --type static_site --name $webName …',
      );
      return 'srv-static-dry-run';
    }
    final args = <String>[
      'services',
      'create',
      '--name',
      webName,
      '--type',
      'static_site',
      '--repo',
      repo,
      '--branch',
      rcfg.branch,
      '--build-command',
      'true',
      '--publish-directory',
      rcfg.siteDir,
      '--confirm',
      '-o',
      'json',
    ];
    if (rcfg.rootDir != null && rcfg.rootDir!.isNotEmpty) {
      args.addAll(['--root-directory', rcfg.rootDir!]);
    }
    log.detail('creating Render static site $webName');
    final create = await runner.runCapture(
      render,
      args,
      allowDryRun: false,
    );
    if (!create.ok) {
      throw StateError(
        'render services create (static_site) failed '
        '(exit ${create.exitCode}): '
        '${create.stderr.isNotEmpty ? create.stderr : create.stdout}',
      );
    }
    final id = _extractServiceId(create.stdout) ??
        await _findServiceId(runner, render, webName);
    if (id == null) {
      throw StateError('static site created but id not parsed');
    }
    log.ok('created Render static site $webName ($id)');
    await _persistWebServiceId(ctx, id);
    return id;
  }

  Future<void> _persistWebServiceId(DeployContext ctx, String id) async {
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
      render: r.copyWith(webServiceId: id),
      cloudflare: cfg.cloudflare,
      database: cfg.database,
      web: cfg.web,
      smoke: cfg.smoke,
    );
    await updated.save();
  }

  Future<void> _persistWebHost(
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
      render: r.copyWith(webServiceId: serviceId, webPublicHost: host),
      cloudflare: cfg.cloudflare,
      database: cfg.database,
      web: cfg.web,
      smoke: cfg.smoke,
    );
    await updated.save();
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
    // Prefer list JSON and match by id — bare `services <id>` is unreliable
    // and scanning all services can pick the wrong onrender.com host.
    final list = await runner.runCapture(
      render,
      ['services', '-o', 'json', '--confirm'],
      allowDryRun: false,
    );
    if (list.ok) {
      try {
        final decoded = jsonDecode(list.stdout);
        for (final item in _asList(decoded)) {
          if (item is! Map) continue;
          final nested = item['service'] ?? item;
          if (nested is! Map) continue;
          if (nested['id']?.toString() != serviceId) continue;
          final details = nested['serviceDetails'];
          if (details is Map && details['url'] != null) {
            final u = details['url'].toString()
                .replaceFirst(RegExp(r'^https?://'), '');
            return u.split('/').first;
          }
          final name = nested['name']?.toString();
          if (name != null && name.isNotEmpty) {
            return '$name.onrender.com';
          }
        }
      } catch (_) {/* fall through */}
    }
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
      render: r.copyWith(serviceId: id),
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
      render: r.copyWith(serviceId: serviceId, publicHost: host),
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


