import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../fly_name.dart';
import '../log.dart';
import '../process_runner.dart';
import '../templates.dart';
import 'adapter.dart';
import 'auth_helpers.dart';

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
    await _ensureFlyToml(ctx, app);
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

  Future<void> _ensureFlyToml(DeployContext ctx, String app) async {
    final config = ctx.config;
    final runner = ctx.runner;
    final log = ctx.log;
    final f = File(config.flyTomlPath);
    final dockerfile = p.join(config.server, 'Dockerfile');

    if (await f.exists()) {
      var text = await f.readAsString();
      final updated = text.replaceFirst(
        RegExp(r'^app\s*=\s*"[^"]*"', multiLine: true),
        'app = "$app"',
      );
      if (updated != text && !runner.dryRun) {
        await f.writeAsString(updated);
        log.detail('updated fly.toml app = $app');
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

    var app = preferred;
    for (var attempt = 0; attempt < 5; attempt++) {
      if (await _flyAppExists(runner, flyBin, app)) {
        log.detail('Fly app $app already exists');
        return app;
      }

      log.detail('creating Fly app $app');
      final create = await runner.run(
        flyBin,
        ['apps', 'create', app],
        allowDryRun: false,
      );
      if (create.ok) {
        log.ok('created Fly app $app');
        if (app != preferred) {
          await _persistFlyAppName(ctx, app);
        }
        return app;
      }

      final err = (create.stderr + create.stdout).toLowerCase();
      if (err.contains('already') || err.contains('taken')) {
        if (await _flyAppExists(runner, flyBin, app)) {
          log.detail('Fly app $app exists — continuing');
          return app;
        }
        final suffix =
            Random().nextInt(0xFFFF).toRadixString(16).padLeft(4, '0');
        app = '$preferred-$suffix';
        log.warn('name taken — trying $app');
        continue;
      }

      throw StateError(
        'fly apps create $app failed (exit ${create.exitCode})',
      );
    }
    throw StateError('could not create a unique Fly app name from $preferred');
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
