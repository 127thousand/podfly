import 'dart:io';

import 'config.dart';
import 'hosts/hosts.dart';
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
  /// [requireFlutter]: when false, skip the hard Flutter requirement (API-only
  /// deploys / CI without a Flutter SDK). Defaults to true for baseline.
  Future<bool> run({
    required DoctorScope scope,
    PodflyConfig? config,
    bool? requireFlutter,
  }) async {
    ensureHostsRegistered();
    log.step(scope == DoctorScope.baseline
        ? 'Doctor (baseline)'
        : 'Doctor (config-aware)');

    var ok = true;

    if (scope == DoctorScope.baseline) {
      final needFlutter = requireFlutter ?? true;
      if (needFlutter) {
        ok = await _needBinary(
              'flutter',
              installHint:
                  'https://docs.flutter.dev/get-started/install (no safe one-liner)',
            ) &&
            ok;
      } else {
        log.detail('flutter optional (API-only / web.enabled: false)');
      }
      if (config != null) {
        ok = await _needHost(config.host) && ok;
      } else {
        log.detail('host CLI deferred until provider is chosen');
      }
    }

    if (scope == DoctorScope.configAware && config != null) {
      ok = await _needHost(config.host) && ok;

      // Cloudflare Pages only when host does not deploy web natively.
      final adapter = HostRegistry.require(config.host);
      final needFlutter = requireFlutter ?? config.web.enabled;
      if (needFlutter) {
        ok = await _needBinary(
              'flutter',
              installHint:
                  'https://docs.flutter.dev/get-started/install (no safe one-liner)',
            ) &&
            ok;
      }
      if (config.web.enabled &&
          config.mode == DeployMode.split &&
          config.usesStaticWebHost) {
        switch (config.webHost) {
          case StaticWebHost.cloudflare:
            ok = await _needWrangler() && ok;
          case StaticWebHost.vercel:
            ok = await _needVercel() && ok;
          case StaticWebHost.netlify:
            ok = await _needNetlify() && ok;
          case StaticWebHost.githubPages:
            ok = await _needGitHubCli() && ok;
        }
      }
      if (config.database.provider == DatabaseProvider.neon &&
          config.database.neon?.provision == true) {
        ok = await _needNeon() && ok;
      }
      if (config.database.provider == DatabaseProvider.supabase) {
        ok = await _needSupabase() && ok;
      }
      if (config.redis.provider == RedisProvider.upstash) {
        ok = await _needUpstash() && ok;
      }
      if (!adapter.canDeploy) {
        log.warn(
            '${adapter.label} is on the roadmap — deploy will not run yet. '
            'Use host: fly, railway, or digitalocean for production deploys today.');
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
    final adapter = HostRegistry.require(host);
    final bins = adapter.cliBinaries;
    var resolved = await runner.resolve(bins.first, bins.skip(1).toList());
    if (resolved == null) {
      log.warn(
          '${adapter.label} CLI not found (need one of: ${bins.join(', ')})');
      log.detail('Docs: ${adapter.installHint}');
      if (await _tryInstallRecipes(adapter.installRecipes, adapter.label)) {
        resolved = await runner.resolve(bins.first, bins.skip(1).toList());
      }
      if (resolved == null) {
        log.err('${adapter.label} CLI still missing after install attempt');
        return false;
      }
      log.ok('${adapter.label} CLI installed → $resolved');
    }

    return adapter.checkAuth(DoctorContext(
      runner: runner,
      log: log,
      cliPath: resolved,
      canLogin: _canLogin,
      autoLogin: _autoLogin,
    ));
  }

  /// Offer install recipes (brew / curl|sh). Returns true if any recipe succeeded.
  Future<bool> _tryInstallRecipes(
    List<CliInstallRecipe> recipes,
    String what,
  ) async {
    if (recipes.isEmpty) return false;
    if (!_canLogin && !_autoLogin) {
      for (final r in recipes) {
        log.detail('Install option: ${r.label}');
      }
      return false;
    }

    for (final recipe in recipes) {
      // Skip brew recipes if brew isn't available.
      if (recipe.executable == 'brew' && !await runner.which('brew')) {
        continue;
      }
      if (recipe.executable == 'npm' && !await runner.which('npm')) {
        continue;
      }
      final go = _autoLogin ||
          await confirm('Install $what via `${recipe.label}` now?');
      if (!go) continue;

      log.detail('running: ${recipe.label}');
      final r = await runner.run(
        recipe.executable,
        recipe.args,
        allowDryRun: false,
      );
      if (r.ok) {
        log.ok('installed $what');
        return true;
      }
      log.warn('install failed (${r.exitCode}): ${recipe.label}');
    }
    return false;
  }

  Future<bool> _needBinary(
    String name, {
    String? installHint,
    List<CliInstallRecipe> installRecipes = const [],
  }) async {
    if (await runner.which(name) ||
        await runner.resolvePath(name) != null) {
      if (runner.dryRun) {
        log.ok('$name  (on PATH; version check skipped in dry-run)');
        return true;
      }
      final bin = await runner.resolvePath(name) ?? name;
      final r =
          await runner.runCapture(bin, ['--version'], allowDryRun: false);
      final ver = (r.stdout + r.stderr).trim().split('\n').first;
      log.ok('$name  $ver');
      return true;
    }
    log.warn('$name not found on PATH');
    if (installHint != null) log.detail('Install: $installHint');
    if (await _tryInstallRecipes(installRecipes, name)) {
      return _needBinary(name, installHint: installHint);
    }
    log.err('$name still missing');
    return false;
  }

  Future<bool> _needWrangler() async {
    if (Platform.environment['CLOUDFLARE_API_TOKEN']?.isNotEmpty == true) {
      log.ok('wrangler  (CLOUDFLARE_API_TOKEN set)');
      return true;
    }
    if (!await runner.which('wrangler')) {
      log.warn('wrangler not found (needed for Cloudflare Pages UI)');
      final installed = await _tryInstallRecipes(const [
        CliInstallRecipe(
          label: 'npm i -g wrangler',
          executable: 'npm',
          args: ['i', '-g', 'wrangler'],
        ),
        CliInstallRecipe(
          label: 'brew install cloudflare-wrangler2',
          executable: 'brew',
          args: ['install', 'cloudflare-wrangler2'],
        ),
      ], 'wrangler');
      if (!installed || !await runner.which('wrangler')) {
        log.err('wrangler still missing');
        log.detail(
            'Install: npm i -g wrangler   or   brew install cloudflare-wrangler2');
        return false;
      }
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

  Future<bool> _needVercel() async {
    if (Platform.environment['VERCEL_TOKEN']?.isNotEmpty == true) {
      log.ok('vercel  (VERCEL_TOKEN set)');
      return true;
    }
    if (!await runner.which('vercel')) {
      log.warn('vercel not found (needed for Vercel static UI)');
      final installed = await _tryInstallRecipes(const [
        CliInstallRecipe(
          label: 'npm i -g vercel',
          executable: 'npm',
          args: ['i', '-g', 'vercel'],
        ),
        CliInstallRecipe(
          label: 'brew install vercel-cli',
          executable: 'brew',
          args: ['install', 'vercel-cli'],
        ),
      ], 'vercel');
      if (!installed || !await runner.which('vercel')) {
        log.err('vercel still missing');
        log.detail('Install: npm i -g vercel');
        return false;
      }
    }
    if (runner.dryRun) {
      log.ok('vercel  (auth check skipped in dry-run)');
      return true;
    }
    final who = await runner.runCapture(
      'vercel',
      ['whoami'],
      allowDryRun: false,
    );
    final combined = (who.stdout + who.stderr).toLowerCase();
    if (who.ok &&
        !combined.contains('not logged') &&
        !combined.contains('no existing credentials') &&
        who.stdout.trim().isNotEmpty) {
      log.ok('vercel  ${who.stdout.trim().split('\n').first}');
      return true;
    }
    log.warn('vercel not authenticated');
    if (_canLogin) {
      final go = _autoLogin || await confirm('Run `vercel login` now?');
      if (go) {
        final r = await runner.run('vercel', ['login'], allowDryRun: false);
        if (r.ok) return _needVercel();
      }
    } else {
      log.detail('Set VERCEL_TOKEN or run: vercel login');
    }
    return false;
  }

  Future<bool> _needGitHubCli() async {
    if (!await runner.which('gh')) {
      log.warn('gh not found (needed for GitHub Pages static UI)');
      final installed = await _tryInstallRecipes(const [
        CliInstallRecipe(
          label: 'brew install gh',
          executable: 'brew',
          args: ['install', 'gh'],
        ),
      ], 'gh');
      if (!installed || !await runner.which('gh')) {
        log.err('gh still missing');
        log.detail('Install: https://cli.github.com/');
        return false;
      }
    }
    if (!await runner.which('git')) {
      log.err('git not found (required to push gh-pages branch)');
      return false;
    }
    if (runner.dryRun) {
      log.ok('gh  (auth check skipped in dry-run)');
      return true;
    }
    final status = await runner.runCapture(
      'gh',
      ['auth', 'status'],
      allowDryRun: false,
    );
    final text = status.stdout + status.stderr;
    if (status.ok || text.toLowerCase().contains('logged in')) {
      final user = RegExp(r'account\s+(\S+)', caseSensitive: false)
              .firstMatch(text)
              ?.group(1) ??
          RegExp(r'Logged in to github\.com account (\S+)')
              .firstMatch(text)
              ?.group(1);
      log.ok('gh  ${user ?? "authenticated"}');
      return true;
    }
    log.warn('gh not authenticated');
    if (_canLogin) {
      final go = _autoLogin || await confirm('Run `gh auth login` now?');
      if (go) {
        final r = await runner.run('gh', ['auth', 'login'], allowDryRun: false);
        if (r.ok) return _needGitHubCli();
      }
    } else {
      log.detail('Run: gh auth login  (needs repo scope for Pages push)');
    }
    return false;
  }

  Future<bool> _needNetlify() async {
    if (Platform.environment['NETLIFY_AUTH_TOKEN']?.isNotEmpty == true ||
        Platform.environment['NETLIFY_TOKEN']?.isNotEmpty == true) {
      log.ok('netlify  (NETLIFY_AUTH_TOKEN set)');
      return true;
    }
    if (!await runner.which('netlify')) {
      log.warn('netlify not found (needed for Netlify static UI)');
      final installed = await _tryInstallRecipes(const [
        CliInstallRecipe(
          label: 'npm i -g netlify-cli',
          executable: 'npm',
          args: ['i', '-g', 'netlify-cli'],
        ),
        CliInstallRecipe(
          label: 'brew install netlify-cli',
          executable: 'brew',
          args: ['install', 'netlify-cli'],
        ),
      ], 'netlify');
      if (!installed || !await runner.which('netlify')) {
        log.err('netlify still missing');
        log.detail('Install: npm i -g netlify-cli');
        return false;
      }
    }
    if (runner.dryRun) {
      log.ok('netlify  (auth check skipped in dry-run)');
      return true;
    }
    final status = await runner.runCapture(
      'netlify',
      ['status'],
      allowDryRun: false,
    );
    // `status` exits non-zero when cwd is unlinked even if logged in.
    final statusText = status.stdout + status.stderr;
    final email = RegExp(r'Email:\s*(\S+)', caseSensitive: false)
        .firstMatch(statusText);
    if (email != null &&
        !statusText.toLowerCase().contains('not logged in')) {
      log.ok('netlify  ${email.group(1)}');
      return true;
    }
    final api = await runner.runCapture(
      'netlify',
      ['api', 'getCurrentUser'],
      allowDryRun: false,
    );
    if (api.ok && api.stdout.contains('email')) {
      log.ok('netlify  authenticated');
      return true;
    }
    log.warn('netlify not authenticated');
    if (_canLogin) {
      final go = _autoLogin || await confirm('Run `netlify login` now?');
      if (go) {
        final r = await runner.run('netlify', ['login'], allowDryRun: false);
        if (r.ok) return _needNetlify();
      }
    } else {
      log.detail('Set NETLIFY_AUTH_TOKEN or run: netlify login');
    }
    return false;
  }

  Future<bool> _needUpstash() async {
    if (Platform.environment['UPSTASH_EMAIL']?.isNotEmpty == true &&
        Platform.environment['UPSTASH_API_KEY']?.isNotEmpty == true) {
      log.ok('upstash  (UPSTASH_EMAIL + UPSTASH_API_KEY set)');
      return true;
    }
    if (!await runner.which('upstash')) {
      log.warn('upstash not found (needed for redis.provider: upstash)');
      final installed = await _tryInstallRecipes(const [
        CliInstallRecipe(
          label: 'npm i -g @upstash/cli',
          executable: 'npm',
          args: ['i', '-g', '@upstash/cli'],
        ),
      ], 'upstash');
      if (!installed || !await runner.which('upstash')) {
        log.err('upstash still missing');
        log.detail('Install: npm i -g @upstash/cli');
        return false;
      }
    }
    if (runner.dryRun) {
      log.ok('upstash  (auth check skipped in dry-run)');
      return true;
    }
    final list = await runner.runCapture(
      'upstash',
      ['redis', 'list'],
      allowDryRun: false,
    );
    if (list.ok) {
      log.ok('upstash  authenticated');
      return true;
    }
    final err = (list.stderr + list.stdout).toLowerCase();
    if (err.contains('authentication') || err.contains('login')) {
      log.warn('upstash not authenticated');
      if (_canLogin) {
        final go = _autoLogin || await confirm('Run `upstash login` now?');
        if (go) {
          final r =
              await runner.run('upstash', ['login'], allowDryRun: false);
          if (r.ok) return _needUpstash();
        }
      } else {
        log.detail(
          'Set UPSTASH_EMAIL + UPSTASH_API_KEY or run: upstash login',
        );
      }
      return false;
    }
    // list may fail for other reasons but CLI works
    log.ok('upstash  CLI present');
    return true;
  }

  Future<bool> _needNeon() async {
    if (Platform.environment['NEON_API_KEY']?.isNotEmpty == true) {
      log.ok('neonctl  (NEON_API_KEY set)');
      return true;
    }
    var neon = await runner.resolve('neonctl', ['neon']);
    if (neon == null) {
      log.warn('neonctl not found (needed for Neon provision)');
      final installed = await _tryInstallRecipes(const [
        CliInstallRecipe(
          label: 'brew install neonctl',
          executable: 'brew',
          args: ['install', 'neonctl'],
        ),
        CliInstallRecipe(
          label: 'npm i -g neonctl',
          executable: 'npm',
          args: ['i', '-g', 'neonctl'],
        ),
      ], 'neonctl');
      neon = installed ? await runner.resolve('neonctl', ['neon']) : null;
      if (neon == null) {
        log.err('neonctl still missing');
        log.detail('Install: brew install neonctl   or   npm i -g neonctl');
        return false;
      }
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

  Future<bool> _needSupabase() async {
    if (Platform.environment['SUPABASE_ACCESS_TOKEN']?.isNotEmpty == true) {
      log.ok('supabase  (SUPABASE_ACCESS_TOKEN set)');
      return true;
    }
    var bin = await runner.resolve('supabase');
    if (bin == null) {
      log.warn('supabase not found (needed for database.provider: supabase)');
      final installed = await _tryInstallRecipes(const [
        CliInstallRecipe(
          label: 'brew install supabase/tap/supabase',
          executable: 'brew',
          args: ['install', 'supabase/tap/supabase'],
        ),
        CliInstallRecipe(
          label: 'npm i -g supabase',
          executable: 'npm',
          args: ['i', '-g', 'supabase'],
        ),
      ], 'supabase');
      bin = installed ? await runner.resolve('supabase') : null;
      if (bin == null) {
        log.err('supabase still missing');
        log.detail(
          'Install: brew install supabase/tap/supabase  '
          'or  npm i -g supabase',
        );
        return false;
      }
    }
    if (runner.dryRun) {
      log.ok('$bin  (auth check skipped in dry-run)');
      return true;
    }
    final list = await runner.runCapture(
      bin,
      ['projects', 'list'],
      allowDryRun: false,
    );
    if (list.ok) {
      log.ok('$bin  authenticated');
      return true;
    }
    final err = (list.stderr + list.stdout).toLowerCase();
    if (err.contains('login') ||
        err.contains('token') ||
        err.contains('auth') ||
        err.contains('unauthorized')) {
      log.warn('$bin not authenticated');
      if (_canLogin) {
        final go = _autoLogin || await confirm('Run `supabase login` now?');
        if (go) {
          final r = await runner.run(bin, ['login'], allowDryRun: false);
          if (r.ok) return _needSupabase();
        }
      } else {
        log.detail(
          'Set SUPABASE_ACCESS_TOKEN or run: supabase login',
        );
      }
      return false;
    }
    log.ok('$bin  CLI present');
    return true;
  }

  void _configWarnings(PodflyConfig config) {
    ensureHostsRegistered();
    final adapter = HostRegistry.require(config.host);
    adapter.configWarnings(config, log);

    if (config.database.provider == DatabaseProvider.sqlite) {
      final vol = config.database.sqlite;
      if (vol == null || vol.volumeCreate == false) {
        log.warn(
            'sqlite without a Fly volume may lose data on machine replace');
      }
    }
    if (config.database.provider == DatabaseProvider.flyPostgres &&
        config.host != AppHost.fly) {
      log.warn('fly_postgres is only available when host: fly');
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
