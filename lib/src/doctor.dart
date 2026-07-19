import 'dart:io';

import 'config.dart';
import 'log.dart';
import 'process_runner.dart';
import 'tty.dart';

enum DoctorScope { baseline, configAware }

class Doctor {
  Doctor({
    required this.runner,
    required this.log,
    this.fixAuth = true,
    this.noLogin = false,
  });

  final ProcessRunner runner;
  final Log log;
  final bool fixAuth;
  final bool noLogin;

  bool get _canLogin => fixAuth && !noLogin && isTty && !runner.dryRun;

  bool get _autoLogin =>
      Platform.environment['PODFLY_AUTO'] == '1' ||
      Platform.environment['CI'] == 'true';

  /// Returns true if all required checks passed.
  ///
  /// [baseline] only requires Flutter (host is unknown until config/init).
  /// [configAware] checks the API host CLI + wrangler/neon as needed.
  Future<bool> run({
    required DoctorScope scope,
    PodflyConfig? config,
  }) async {
    log.step(scope == DoctorScope.baseline
        ? 'Doctor (baseline)'
        : 'Doctor (config-aware)');

    var ok = true;

    if (scope == DoctorScope.baseline) {
      ok = await _needBinary('flutter', installHint: 'https://flutter.dev') &&
          ok;
      // Host CLI is checked after config exists (user may choose Render, not Fly).
      if (config != null) {
        ok = await _needHost(config.host) && ok;
      } else {
        log.detail('host CLI deferred until provider is chosen');
      }
    }

    if (scope == DoctorScope.configAware && config != null) {
      ok = await _needHost(config.host) && ok;

      // Wrangler only when we actually deploy Flutter web to Pages.
      if (config.web.enabled &&
          (config.mode == DeployMode.split || config.host == AppHost.fly)) {
        // Pages is only used for split UI today
        if (config.mode == DeployMode.split && config.web.enabled) {
          ok = await _needWrangler() && ok;
        }
      }
      if (config.database.provider == DatabaseProvider.neon &&
          config.database.neon?.provision == true) {
        ok = await _needNeon() && ok;
      }
      if (!config.host.isImplemented) {
        log.warn(
            '${config.host.label} is on the roadmap — deploy will not run yet. '
            'Use host: fly for production deploys today.');
      }
      _configWarnings(config);
    }

    if (ok) {
      log.ok('Doctor passed');
    } else {
      log.err('Doctor failed');
    }
    return ok;
  }

  Future<bool> _needHost(AppHost host) async {
    final bins = host.cliBinaries;
    final resolved = await runner.resolve(bins.first, bins.skip(1).toList());
    if (resolved == null) {
      log.err('${host.label} CLI not found (need one of: ${bins.join(', ')})');
      log.detail('Install: ${host.installHint}');
      return false;
    }

    // Auth checks are host-specific
    switch (host) {
      case AppHost.fly:
        return _needFlyAuth(resolved);
      case AppHost.railway:
        return _needGenericAuth(resolved, ['whoami'], 'railway login');
      case AppHost.render:
        log.ok('$resolved  (present — auth via RENDER_API_KEY / login)');
        return true;
      case AppHost.cloudRun:
        return _needGenericAuth(resolved, ['auth', 'list'], 'gcloud auth login');
      case AppHost.aws:
        return _needGenericAuth(
            resolved, ['sts', 'get-caller-identity'], 'aws configure / SSO');
      case AppHost.azure:
        return _needGenericAuth(resolved, ['account', 'show'], 'az login');
      case AppHost.digitalOcean:
        return _needGenericAuth(resolved, ['account', 'get'], 'doctl auth init');
    }
  }

  Future<bool> _needBinary(String name, {String? installHint}) async {
    if (await runner.which(name)) {
      if (runner.dryRun) {
        log.ok('$name  (on PATH; version check skipped in dry-run)');
        return true;
      }
      final r =
          await runner.runCapture(name, ['--version'], allowDryRun: false);
      final ver = (r.stdout + r.stderr).trim().split('\n').first;
      log.ok('$name  $ver');
      return true;
    }
    log.err('$name not found on PATH');
    if (installHint != null) log.detail('Install: $installHint');
    return false;
  }

  Future<bool> _needFlyAuth(String fly) async {
    if (Platform.environment['FLY_API_TOKEN']?.isNotEmpty == true) {
      log.ok('$fly  (FLY_API_TOKEN set)');
      return true;
    }
    if (runner.dryRun) {
      log.ok('$fly  (auth check skipped in dry-run)');
      return true;
    }
    final who =
        await runner.runCapture(fly, ['auth', 'whoami'], allowDryRun: false);
    final out = (who.stdout + who.stderr).toLowerCase();
    if (who.ok &&
        !out.contains('not logged') &&
        !out.contains('no access token') &&
        who.stdout.trim().isNotEmpty) {
      log.ok('$fly  authenticated as ${who.stdout.trim().split('\n').first}');
      return true;
    }
    log.warn('$fly not authenticated');
    if (_canLogin) {
      final go = _autoLogin || await confirm('Run `fly auth login` now?');
      if (go) {
        final r = await runner.run(fly, ['auth', 'login'], allowDryRun: false);
        if (r.ok) return _needFlyAuth(fly);
      }
    } else {
      log.detail('Set FLY_API_TOKEN or run: fly auth login');
    }
    return false;
  }

  Future<bool> _needGenericAuth(
    String bin,
    List<String> checkArgs,
    String loginHint,
  ) async {
    if (runner.dryRun) {
      log.ok('$bin  (present; auth skipped in dry-run)');
      return true;
    }
    final r = await runner.runCapture(bin, checkArgs, allowDryRun: false);
    if (r.ok) {
      log.ok('$bin  authenticated / ready');
      return true;
    }
    log.warn('$bin not authenticated or misconfigured');
    log.detail('Fix: $loginHint');
    return false;
  }

  Future<bool> _needWrangler() async {
    if (Platform.environment['CLOUDFLARE_API_TOKEN']?.isNotEmpty == true) {
      log.ok('wrangler  (CLOUDFLARE_API_TOKEN set)');
      return true;
    }
    if (!await runner.which('wrangler')) {
      log.err('wrangler not found (needed for Cloudflare Pages UI)');
      log.detail(
          'Install: npm i -g wrangler   or   brew install cloudflare-wrangler2');
      if (_canLogin && await runner.which('npm')) {
        if (await confirm('Install wrangler via npm -g?')) {
          final r = await runner.run('npm', ['i', '-g', 'wrangler']);
          if (r.ok) return _needWrangler();
        }
      }
      return false;
    }
    if (runner.dryRun) {
      log.ok('wrangler  (auth check skipped in dry-run)');
      return true;
    }
    final who = await runner.runCapture(
      'wrangler',
      ['whoami'],
      allowDryRun: false,
    );
    final combined = (who.stdout + who.stderr).toLowerCase();
    if (who.ok && !combined.contains('not authenticated')) {
      log.ok('wrangler  authenticated');
      return true;
    }
    log.warn('wrangler not authenticated');
    if (_canLogin) {
      final go = _autoLogin || await confirm('Run `wrangler login` now?');
      if (go) {
        final r =
            await runner.run('wrangler', ['login'], allowDryRun: false);
        if (r.ok) return _needWrangler();
      }
    } else {
      log.detail('Set CLOUDFLARE_API_TOKEN or run: wrangler login');
    }
    return false;
  }

  Future<bool> _needNeon() async {
    if (Platform.environment['NEON_API_KEY']?.isNotEmpty == true) {
      log.ok('neonctl  (NEON_API_KEY set)');
      return true;
    }
    final neon = await runner.resolve('neonctl', ['neon']);
    if (neon == null) {
      log.err('neonctl not found (needed for Neon provision)');
      log.detail('Install: brew install neonctl   or   npm i -g neonctl');
      if (_canLogin && await runner.which('brew')) {
        if (await confirm('Install neonctl via brew?')) {
          final r = await runner.run('brew', ['install', 'neonctl']);
          if (r.ok) return _needNeon();
        }
      }
      return false;
    }
    if (runner.dryRun) {
      log.ok('$neon  (auth check skipped in dry-run)');
      return true;
    }
    final me =
        await runner.runCapture(neon, ['me'], allowDryRun: false);
    if (me.ok) {
      log.ok('$neon  authenticated');
      return true;
    }
    log.warn('$neon not authenticated');
    if (_canLogin) {
      final go = _autoLogin || await confirm('Run `neonctl auth` now?');
      if (go) {
        final r = await runner.run(neon, ['auth'], allowDryRun: false);
        if (r.ok) return _needNeon();
      }
    } else {
      log.detail('Set NEON_API_KEY or run: neonctl auth');
    }
    return false;
  }

  void _configWarnings(PodflyConfig config) {
    if (config.database.provider == DatabaseProvider.sqlite) {
      final vol = config.database.sqlite;
      if (vol == null || vol.volumeCreate == false) {
        log.warn(
            'sqlite without a Fly volume may lose data on machine replace');
      }
      if (config.fly.ha) {
        log.warn('sqlite is single-machine; set fly.ha: false');
      }
    }
    if (config.database.provider == DatabaseProvider.flyPostgres) {
      log.warn(
          'Fly Postgres usually keeps billing even when the API scales to zero');
      if (config.host != AppHost.fly) {
        log.warn('fly_postgres is only available when host: fly');
      }
    }
    if (config.database.provider == DatabaseProvider.none) {
      final mig = Directory('${config.serverPath}/migrations');
      if (mig.existsSync()) {
        final entries = mig.listSync().whereType<Directory>();
        if (entries.isNotEmpty) {
          log.warn(
              'database.provider is none but migrations/ exist — production has no DB');
        }
      }
    }
  }
}
