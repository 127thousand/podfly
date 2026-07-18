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

  /// Returns true if all required checks passed.
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
      ok = await _needFly() && ok;
    }

    if (scope == DoctorScope.configAware && config != null) {
      if (config.mode == DeployMode.split) {
        ok = await _needWrangler() && ok;
      }
      if (config.database.provider == DatabaseProvider.neon &&
          config.database.neon?.provision == true) {
        ok = await _needNeon() && ok;
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

  Future<bool> _needFly() async {
    final fly = await runner.resolve('fly', ['flyctl']);
    if (fly == null) {
      log.err('fly / flyctl not found');
      log.detail('Install: https://fly.io/docs/hands-on/install-flyctl/');
      if (_canLogin && await runner.which('brew')) {
        if (await confirm('Install flyctl via brew?')) {
          final r = await runner.run('brew', ['install', 'flyctl']);
          if (r.ok) return _needFly();
        }
      }
      return false;
    }

    // Auth: env token counts
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
      if (await confirm('Run `fly auth login` now?')) {
        final r = await runner.run(fly, ['auth', 'login'], allowDryRun: false);
        if (r.ok) return _needFly();
      }
    } else {
      log.detail('Set FLY_API_TOKEN or run: fly auth login');
    }
    return false;
  }

  Future<bool> _needWrangler() async {
    if (Platform.environment['CLOUDFLARE_API_TOKEN']?.isNotEmpty == true) {
      log.ok('wrangler  (CLOUDFLARE_API_TOKEN set)');
      return true;
    }

    if (!await runner.which('wrangler')) {
      log.err('wrangler not found (needed for mode: split)');
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
      if (await confirm('Run `wrangler login` now?')) {
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
      if (await confirm('Run `neonctl auth` now?')) {
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
