import 'dart:io';

import '../config.dart';
import '../fly_name.dart';
import '../log.dart';
import '../process_runner.dart';
import '../templates.dart';
import 'adapter.dart';
import 'auth_helpers.dart';
import 'nginx_monolith_image.dart';

class FlyHost extends HostAdapter {
  @override
  String get id => 'fly';

  @override
  String get label => 'Fly.io';

  @override
  List<String> get cliBinaries => const ['fly', 'flyctl'];

  @override
  String get installHint =>
      'https://fly.io/docs/hands-on/install-flyctl/';

  @override
  List<CliInstallRecipe> get installRecipes => const [
        CliInstallRecipe(
          label: 'brew install flyctl',
          executable: 'brew',
          args: ['install', 'flyctl'],
        ),
        CliInstallRecipe(
          label: 'curl -L https://fly.io/install.sh | sh',
          executable: 'sh',
          args: ['-c', 'curl -fsSL https://fly.io/install.sh | sh'],
          needsShell: true,
        ),
      ];

  @override
  bool get canDeploy => true;

  @override
  AppHost get appHost => AppHost.fly;

  @override
  String get configKey => 'fly';

  @override
  bool get supportsAllInOneWeb => true;

  @override
  List<DatabaseProvider> get supportedDatabases => const [
        DatabaseProvider.none,
        DatabaseProvider.sqlite,
        DatabaseProvider.flyPostgres,
        DatabaseProvider.neon,
        DatabaseProvider.supabase,
      ];

  @override
  String defaultApiUrl({
    required String name,
    required String sanitizedName,
  }) =>
      'https://$sanitizedName.fly.dev/';

  @override
  String? publicApiBase(PodflyConfig config) =>
      'https://${config.fly.app}.fly.dev/';

  @override
  String secretSetHint(String secretName, PodflyConfig config) =>
      'fly secrets set $secretName=… -a ${config.fly.app}';

  @override
  Future<bool> checkAuth(DoctorContext ctx) {
    return authViaWhoami(
      ctx: ctx,
      whoamiArgs: const ['auth', 'whoami'],
      loginCommand: 'fly auth login',
      loginArgs: const ['auth', 'login'],
      tokenEnv: 'FLY_API_TOKEN',
    );
  }

  @override
  void configWarnings(PodflyConfig config, Log log) {
    if (config.database.provider == DatabaseProvider.sqlite) {
      if (config.fly.ha) {
        log.warn('sqlite is single-machine; set fly.ha: false');
      }
    }
    if (config.database.provider == DatabaseProvider.flyPostgres) {
      log.warn(
          'Fly Postgres usually keeps billing even when the API scales to zero');
    }
  }

  @override
  Future<String?> ensureApiApp(DeployContext ctx) async {
    final preferred = sanitizeFlyAppName(ctx.config.fly.app);
    if (preferred != ctx.config.fly.app) {
      ctx.log.detail(
          'Fly app name sanitized: ${ctx.config.fly.app} → $preferred');
    }
    final fly = await ctx.runner.resolve('fly', ['flyctl']);
    if (fly == null) throw StateError('fly not found');
    return _ensureFlyApp(ctx, fly, preferred);
  }

  @override
  Future<HostDeployResult> deployApi(DeployContext ctx) async {
    final config = ctx.config;
    final runner = ctx.runner;
    final log = ctx.log;

    final preferred = sanitizeFlyAppName(config.fly.app);
    if (preferred != config.fly.app) {
      log.detail('Fly app name sanitized: ${config.fly.app} → $preferred');
    }
    log.step('Deploy Fly API ($preferred)');

    final fly = await runner.resolve('fly', ['flyctl']);
    if (fly == null) throw StateError('fly not found');

    final app = await _ensureFlyApp(ctx, fly, preferred);

    final monolithWeb =
        config.mode == DeployMode.monolith && config.web.enabled;
    if (monolithWeb) {
      // One public port: nginx :8080 → static Flutter + proxy Serverpod :8081.
      // Plain server Dockerfile + web/app alone leaves API on a different port
      // than fly.toml internal_port (or UI on webServer 8082 — unreachable).
      await NginxMonolithImage.ensure(ctx);
    }

    await _ensureFlyToml(ctx, app, monolithWeb: monolithWeb);
    await ctx.patchPublicHosts('$app.fly.dev');

    final args = <String>[
      'deploy',
      '-a',
      app,
      '--config',
      config.fly.config,
    ];
    if (!config.fly.ha) args.add('--ha=false');
    final r = await runner.run(fly, args, workingDirectory: config.root);
    if (!r.ok && !runner.dryRun) {
      throw StateError('fly deploy failed (exit ${r.exitCode})');
    }
    final url = 'https://$app.fly.dev';
    log.ok('Fly: $url');
    return HostDeployResult(publicHost: '$app.fly.dev', displayUrl: url);
  }

  Future<void> _ensureFlyToml(
    DeployContext ctx,
    String app, {
    required bool monolithWeb,
  }) async {
    final config = ctx.config;
    final runner = ctx.runner;
    final log = ctx.log;
    final f = File(config.flyTomlPath);
    // Monolith: root nginx Dockerfile. API-only: Serverpod package Dockerfile.
    final dockerfile = NginxMonolithImage.relativeDockerfile(config);

    if (await f.exists()) {
      var text = await f.readAsString();
      final original = text;
      text = text.replaceFirst(
        RegExp(r'^app\s*=\s*"[^"]*"', multiLine: true),
        'app = "$app"',
      );
      // Keep dockerfile path in sync when switching monolith ↔ API-only.
      if (RegExp(r'dockerfile\s*=').hasMatch(text)) {
        text = text.replaceFirst(
          RegExp(r'dockerfile\s*=\s*"[^"]*"'),
          'dockerfile = "$dockerfile"',
        );
      } else if (text.contains('[build]')) {
        text = text.replaceFirst(
          '[build]',
          '[build]\n  dockerfile = "$dockerfile"',
        );
      }
      // Monolith nginx listens on 8080 (or \$PORT).
      if (monolithWeb && RegExp(r'internal_port\s*=').hasMatch(text)) {
        text = text.replaceFirst(
          RegExp(r'internal_port\s*=\s*\d+'),
          'internal_port = 8080',
        );
      }
      if (text != original && !runner.dryRun) {
        await f.writeAsString(text);
        log.detail(
          'updated fly.toml app=$app dockerfile=$dockerfile'
          '${monolithWeb ? " (nginx monolith)" : ""}',
        );
      }
      return;
    }

    log.detail('generating ${config.fly.config}');
    var body = readTemplate('fly.toml.api_only');
    body = body
        .replaceAll('{{APP}}', app)
        .replaceAll('{{REGION}}', config.fly.region)
        .replaceAll('{{DOCKERFILE}}', dockerfile);
    if (runner.dryRun) {
      log.dry('write ${config.flyTomlPath}');
      return;
    }
    await f.writeAsString(body);
    log.ok('wrote ${config.fly.config}');
  }

  Future<String> _ensureFlyApp(
    DeployContext ctx,
    String flyBin,
    String preferred,
  ) async {
    final runner = ctx.runner;
    final log = ctx.log;
    if (runner.dryRun) {
      log.dry('$flyBin apps create $preferred  (if not exists)');
      return preferred;
    }

    // Capture stdout/stderr so we can detect "Name has already been taken".
    // inheritStdio would leave those empty and skip the retry path.
    var app = preferred;
    for (var attempt = 0; attempt < 8; attempt++) {
      if (attempt > 0) {
        app = nextFlyAppNameCandidate(preferred, attempt);
      }

      if (await _flyAppExists(runner, flyBin, app)) {
        if (app == preferred) {
          log.detail('Fly app $app already exists (yours) — reusing');
        } else {
          log.ok('reusing existing Fly app $app');
          await _persistFlyAppName(ctx, app);
        }
        return app;
      }

      log.detail('creating Fly app $app');
      final create = await runner.runCapture(
        flyBin,
        ['apps', 'create', app],
        allowDryRun: false,
      );
      if (create.ok) {
        log.ok('created Fly app $app');
        if (app != preferred) {
          log.tip(
            'Preferred name "$preferred" was unavailable; using $app. '
            'Saved to podfly.yaml.',
          );
          await _persistFlyAppName(ctx, app);
        }
        return app;
      }

      final combined = '${create.stderr}\n${create.stdout}';
      final conflict = isFlyAppNameConflict(combined);

      // Name taken by this account but status was flaky — recheck once.
      if (conflict || create.exitCode != 0) {
        if (await _flyAppExists(runner, flyBin, app)) {
          log.detail('Fly app $app exists — continuing');
          if (app != preferred) await _persistFlyAppName(ctx, app);
          return app;
        }
      }

      if (conflict) {
        final next = nextFlyAppNameCandidate(preferred, attempt + 1);
        log.warn(
          'Fly app name "$app" is taken (not in this account). '
          'Trying $next …',
        );
        continue;
      }

      final detail = combined.trim();
      throw StateError(
        'fly apps create $app failed (exit ${create.exitCode})'
        '${detail.isEmpty ? '' : ':\n$detail'}',
      );
    }
    throw StateError(
      'Could not allocate a free Fly app name from "$preferred" '
      'after several tries. Set fly.app: in podfly.yaml to an available name '
      'or delete/rename the conflicting app.',
    );
  }

  Future<bool> _flyAppExists(
    ProcessRunner runner,
    String flyBin,
    String app,
  ) async {
    final status = await runner.runCapture(
      flyBin,
      ['status', '-a', app],
      allowDryRun: false,
    );
    final combined = (status.stdout + status.stderr).toLowerCase();
    return status.ok &&
        !combined.contains('could not find') &&
        !combined.contains('not found') &&
        !combined.contains('error');
  }

  Future<void> _persistFlyAppName(DeployContext ctx, String app) async {
    final cfgFile = File(ctx.config.configPath);
    if (!await cfgFile.exists()) return;
    var text = await cfgFile.readAsString();
    text = text.replaceFirst(
      RegExp(r'(^\s*app:\s*).+$', multiLine: true),
      '  app: $app',
    );
    text = text.replaceFirst(
      RegExp(r'(^\s*api_url:\s*).+$', multiLine: true),
      '  api_url: https://$app.fly.dev/',
    );
    await cfgFile.writeAsString(text);
    ctx.log.ok('updated podfly.yaml fly.app → $app');
  }
}
