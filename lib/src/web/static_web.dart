import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../log.dart';
import '../process_runner.dart';
import '../templates.dart';

/// Deploy Flutter web static output to a CDN-style host
/// (Cloudflare Pages / Vercel / Netlify / GitHub Pages).
///
/// Parallel to API [HostAdapter], but only for split-mode UI. Native web hosts
/// (Railway, DO, …) use [HostAdapter.deployWeb] instead.
class StaticWebDeployer {
  StaticWebDeployer({
    required this.config,
    required this.runner,
    required this.log,
  });

  final PodflyConfig config;
  final ProcessRunner runner;
  final Log log;

  Future<HostDeployResultLike> deploy() async {
    switch (config.webHost) {
      case StaticWebHost.cloudflare:
        return _cloudflarePages();
      case StaticWebHost.vercel:
        return _vercel();
      case StaticWebHost.netlify:
        return _netlify();
      case StaticWebHost.githubPages:
        return _githubPages();
    }
  }

  Future<HostDeployResultLike> _cloudflarePages() async {
    final cf = config.cloudflare;
    if (cf == null) {
      throw StateError(
        'web_host: cloudflare requires a cloudflare: project block in podfly.yaml',
      );
    }
    final project = cf.project;
    log.step('Deploy Cloudflare Pages ($project)');
    final out = config.webOutPath;
    if (!runner.dryRun && !await File(p.join(out, 'index.html')).exists()) {
      throw StateError('missing web build at $out');
    }

    if (runner.dryRun) {
      log.dry('wrangler pages project list / create $project (if needed)');
      log.dry('wrangler pages deploy $out --project-name $project');
      return HostDeployResultLike(
        publicHost: '$project.pages.dev',
        displayUrl: 'https://$project.pages.dev',
      );
    }

    final list = await runner.runCapture(
      'wrangler',
      ['pages', 'project', 'list'],
      allowDryRun: false,
    );
    if (!list.stdout.contains(project)) {
      log.detail('creating Cloudflare Pages project $project');
      final create = await runner.run('wrangler', [
        'pages',
        'project',
        'create',
        project,
        '--production-branch',
        cf.branch,
      ]);
      if (create.ok) {
        log.ok('created Pages project $project');
      } else {
        log.warn(
          'pages project create failed — deploy may still work if project exists',
        );
      }
    }

    final r = await runner.run('wrangler', [
      'pages',
      'deploy',
      out,
      '--project-name',
      project,
      '--branch',
      cf.branch,
    ]);
    if (!r.ok) {
      throw StateError('wrangler pages deploy failed (exit ${r.exitCode})');
    }
    final url = 'https://$project.pages.dev';
    log.ok('Pages: $url');
    return HostDeployResultLike(publicHost: '$project.pages.dev', displayUrl: url);
  }

  Future<HostDeployResultLike> _vercel() async {
    final vc = config.vercel ?? VercelConfig(project: config.name);
    final project = vc.project;
    log.step('Deploy Vercel ($project)');
    final out = config.webOutPath;
    if (!runner.dryRun && !await File(p.join(out, 'index.html')).exists()) {
      throw StateError('missing web build at $out');
    }

    await _ensureVercelJson(out);

    if (runner.dryRun) {
      log.dry('vercel deploy $out --prod --yes --project $project');
      return HostDeployResultLike(
        publicHost: vc.publicHost ?? '$project.vercel.app',
        displayUrl: 'https://${vc.publicHost ?? '$project.vercel.app'}',
      );
    }

    final vercel = await runner.resolve('vercel');
    if (vercel == null) {
      throw StateError(
        'vercel CLI not found — npm i -g vercel  '
        '(https://vercel.com/docs/cli)',
      );
    }

    final token = Platform.environment['VERCEL_TOKEN'];
    final scope = vc.scope;

    // Ensure project exists (deploy --project fails if missing).
    final listArgs = <String>['project', 'ls'];
    if (token != null && token.isNotEmpty) {
      listArgs.addAll(['--token', token]);
    }
    if (scope != null && scope.isNotEmpty) {
      listArgs.addAll(['--scope', scope]);
    }
    final list = await runner.runCapture(vercel, listArgs, allowDryRun: false);
    if (!list.stdout.contains(project) && !list.stderr.contains(project)) {
      log.detail('creating Vercel project $project');
      final addArgs = <String>['project', 'add', project];
      if (token != null && token.isNotEmpty) {
        addArgs.addAll(['--token', token]);
      }
      if (scope != null && scope.isNotEmpty) {
        addArgs.addAll(['--scope', scope]);
      }
      final add = await runner.run(vercel, addArgs, allowDryRun: false);
      if (!add.ok) {
        log.warn(
          'vercel project add failed — deploy may still work if project exists',
        );
      }
    }

    final args = <String>[
      'deploy',
      out,
      '--prod',
      '--yes',
      '--project',
      project,
    ];
    if (token != null && token.isNotEmpty) {
      args.addAll(['--token', token]);
    }
    if (scope != null && scope.isNotEmpty) {
      args.addAll(['--scope', scope]);
    }

    final r = await runner.runCapture(vercel, args, allowDryRun: false);
    if (!r.ok) {
      throw StateError(
        'vercel deploy failed (exit ${r.exitCode}):\n${r.stderr}\n${r.stdout}',
      );
    }

    // Deployment URL may be a long unique host; prefer stable project alias.
    final deploymentUrl = _extractVercelUrl(r.stdout) ??
        _extractVercelUrl(r.stderr);
    final stableHost = '$project.vercel.app';
    final displayUrl = 'https://$stableHost';
    log.ok('Vercel: $displayUrl'
        '${deploymentUrl != null && !deploymentUrl.contains(stableHost) ? " ($deploymentUrl)" : ""}');

    if (!runner.dryRun) {
      await _persistVercelHost(stableHost);
    }

    return HostDeployResultLike(
      publicHost: stableHost,
      displayUrl: displayUrl,
    );
  }

  Future<void> _ensureVercelJson(String outDir) async {
    final dest = File(p.join(outDir, 'vercel.json'));
    // Prefer project-level template if user committed one under flutter/web
    final src = File(p.join(config.flutterPath, 'web', 'vercel.json'));
    if (runner.dryRun) {
      log.dry('ensure vercel.json in $outDir');
      return;
    }
    if (await src.exists()) {
      await src.copy(dest.path);
      log.detail('copied web/vercel.json → build');
      return;
    }
    if (await dest.exists()) return;
    await dest.writeAsString(readTemplate('vercel.json'));
    log.detail('wrote vercel.json (SPA rewrites + wasm headers)');
  }

  Future<void> _persistVercelHost(String publicHost) async {
    final cfg = config;
    final base = cfg.vercel ?? VercelConfig(project: cfg.name);
    final updated = PodflyConfig(
      root: cfg.root,
      host: cfg.host,
      webHost: cfg.webHost,
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
      awsEcs: cfg.awsEcs,
      azure: cfg.azure,
      hetzner: cfg.hetzner,
      cloudflare: cfg.cloudflare,
      vercel: VercelConfig(
        project: base.project,
        publicHost: publicHost,
        scope: base.scope,
      ),
      netlify: cfg.netlify,
      githubPages: cfg.githubPages,
      database: cfg.database,
      web: cfg.web,
      smoke: cfg.smoke,
    );
    await updated.save();
    log.detail('saved vercel.public_host');
  }

  Future<HostDeployResultLike> _netlify() async {
    final nc = config.netlify ?? NetlifyConfig(site: config.name);
    final site = nc.site;
    log.step('Deploy Netlify ($site)');
    final out = config.webOutPath;
    if (!runner.dryRun && !await File(p.join(out, 'index.html')).exists()) {
      throw StateError('missing web build at $out');
    }

    await _ensureNetlifyToml(out);

    final stableHost = nc.publicHost ?? '$site.netlify.app';
    if (runner.dryRun) {
      log.dry(
        'netlify deploy --dir $out --prod --no-build '
        '${nc.siteId != null ? "--site ${nc.siteId}" : "--site-name $site"}',
      );
      return HostDeployResultLike(
        publicHost: stableHost,
        displayUrl: 'https://$stableHost',
      );
    }

    final netlify = await runner.resolve('netlify', ['netlify-cli']);
    if (netlify == null) {
      throw StateError(
        'netlify CLI not found — npm i -g netlify-cli  '
        '(https://docs.netlify.com/cli/get-started/)',
      );
    }

    final token = Platform.environment['NETLIFY_AUTH_TOKEN'] ??
        Platform.environment['NETLIFY_TOKEN'];
    final args = <String>[
      'deploy',
      '--dir',
      out,
      '--prod',
      '--no-build',
      '--json',
    ];
    if (nc.siteId != null && nc.siteId!.isNotEmpty) {
      args.addAll(['--site', nc.siteId!]);
    } else {
      // Creates the site if missing.
      args.addAll(['--site-name', site]);
    }
    if (nc.team != null && nc.team!.isNotEmpty) {
      args.addAll(['--team', nc.team!]);
    }
    if (token != null && token.isNotEmpty) {
      args.addAll(['--auth', token]);
    }

    final r = await runner.runCapture(netlify, args, allowDryRun: false);
    if (!r.ok) {
      throw StateError(
        'netlify deploy failed (exit ${r.exitCode}):\n${r.stderr}\n${r.stdout}',
      );
    }

    final parsed = _parseNetlifyDeployJson(r.stdout) ??
        _parseNetlifyDeployJson(r.stderr);
    final host = _hostFromUrl(parsed?['url'] ?? parsed?['ssl_url']) ??
        stableHost;
    final siteId = parsed?['site_id'] ?? nc.siteId;
    final displayUrl = host.startsWith('http') ? host : 'https://$host';
    final publicHost = host
        .replaceFirst(RegExp(r'^https?://'), '')
        .replaceFirst(RegExp(r'/$'), '');

    log.ok('Netlify: $displayUrl');

    if (!runner.dryRun) {
      await _persistNetlify(
        publicHost: publicHost,
        siteId: siteId is String ? siteId : siteId?.toString(),
      );
    }

    return HostDeployResultLike(
      publicHost: publicHost,
      displayUrl: displayUrl,
    );
  }

  Future<void> _ensureNetlifyToml(String outDir) async {
    final dest = File(p.join(outDir, 'netlify.toml'));
    final src = File(p.join(config.flutterPath, 'web', 'netlify.toml'));
    if (runner.dryRun) {
      log.dry('ensure netlify.toml in $outDir');
      return;
    }
    if (await src.exists()) {
      await src.copy(dest.path);
      log.detail('copied web/netlify.toml → build');
      return;
    }
    if (await dest.exists()) return;
    await dest.writeAsString(readTemplate('netlify.toml'));
    log.detail('wrote netlify.toml (SPA rewrites + wasm headers)');
  }

  Future<void> _persistNetlify({
    required String publicHost,
    String? siteId,
  }) async {
    final cfg = config;
    final base = cfg.netlify ?? NetlifyConfig(site: cfg.name);
    final updated = PodflyConfig(
      root: cfg.root,
      host: cfg.host,
      webHost: cfg.webHost,
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
      awsEcs: cfg.awsEcs,
      azure: cfg.azure,
      hetzner: cfg.hetzner,
      cloudflare: cfg.cloudflare,
      vercel: cfg.vercel,
      netlify: NetlifyConfig(
        site: base.site,
        siteId: siteId ?? base.siteId,
        publicHost: publicHost,
        team: base.team,
      ),
      githubPages: cfg.githubPages,
      database: cfg.database,
      web: cfg.web,
      smoke: cfg.smoke,
    );
    await updated.save();
    log.detail('saved netlify.public_host'
        '${siteId != null ? " + site_id" : ""}');
  }

  Future<HostDeployResultLike> _githubPages() async {
    final gp = config.githubPages ?? GitHubPagesConfig(repo: config.name);
    final repo = gp.repo;
    log.step('Deploy GitHub Pages ($repo)');
    final out = config.webOutPath;
    if (!runner.dryRun && !await File(p.join(out, 'index.html')).exists()) {
      throw StateError('missing web build at $out');
    }

    if (runner.dryRun) {
      final owner = gp.owner ?? '<gh-user>';
      final host = gp.publicHost ?? gp.defaultPublicHost(owner);
      log.dry('gh repo create $owner/$repo (if missing)');
      log.dry('git push -f origin HEAD:${gp.branch}  (from $out)');
      log.dry('gh api POST repos/$owner/$repo/pages (enable legacy source)');
      return HostDeployResultLike(
        publicHost: host,
        displayUrl: 'https://$host/',
      );
    }

    final gh = await runner.resolve('gh');
    if (gh == null) {
      throw StateError(
        'gh CLI not found — https://cli.github.com/  (brew install gh)',
      );
    }
    if (!await runner.which('git')) {
      throw StateError('git not found (required to push GitHub Pages branch)');
    }

    final owner = gp.owner ?? await _ghLogin(gh);
    final publicHost = gp.publicHost ?? gp.defaultPublicHost(owner);
    final displayUrl = 'https://$publicHost/';

    await _ensureGhRepo(gh, owner: owner, repo: repo, private: gp.private);
    await _pushGhPagesBranch(
      outDir: out,
      owner: owner,
      repo: repo,
      branch: gp.branch,
      gh: gh,
    );
    await _ensureGhPagesEnabled(
      gh,
      owner: owner,
      repo: repo,
      branch: gp.branch,
    );

    log.ok('GitHub Pages: $displayUrl');
    await _persistGitHubPages(publicHost: publicHost, owner: owner);

    return HostDeployResultLike(
      publicHost: publicHost,
      displayUrl: displayUrl,
    );
  }

  Future<String> _ghLogin(String gh) async {
    final r = await runner.runCapture(
      gh,
      ['api', 'user', '-q', '.login'],
      allowDryRun: false,
    );
    final login = r.stdout.trim();
    if (!r.ok || login.isEmpty) {
      throw StateError(
        'could not resolve GitHub user — run: gh auth login\n${r.stderr}',
      );
    }
    return login;
  }

  Future<void> _ensureGhRepo(
    String gh, {
    required String owner,
    required String repo,
    required bool private,
  }) async {
    final view = await runner.runCapture(
      gh,
      ['repo', 'view', '$owner/$repo', '--json', 'name'],
      allowDryRun: false,
    );
    if (view.ok) {
      log.detail('GitHub repo $owner/$repo exists');
      return;
    }
    log.detail('creating GitHub repo $owner/$repo');
    final args = <String>[
      'repo',
      'create',
      '$owner/$repo',
      private ? '--private' : '--public',
      '--description',
      'podfly Flutter web (GitHub Pages)',
    ];
    final create = await runner.run(gh, args, allowDryRun: false);
    if (!create.ok) {
      // Race or already exists under different view error
      final again = await runner.runCapture(
        gh,
        ['repo', 'view', '$owner/$repo', '--json', 'name'],
        allowDryRun: false,
      );
      if (!again.ok) {
        throw StateError(
          'gh repo create $owner/$repo failed:\n${create.stderr}\n${create.stdout}',
        );
      }
    } else {
      log.ok('created GitHub repo $owner/$repo');
    }
  }

  Future<void> _pushGhPagesBranch({
    required String outDir,
    required String owner,
    required String repo,
    required String branch,
    required String gh,
  }) async {
    // SPA fallback + disable Jekyll so paths like assets/ aren't filtered.
    final index = File(p.join(outDir, 'index.html'));
    final notFound = File(p.join(outDir, '404.html'));
    if (await index.exists() && !await notFound.exists()) {
      await index.copy(notFound.path);
      log.detail('wrote 404.html (SPA fallback for GitHub Pages)');
    }
    final nojekyll = File(p.join(outDir, '.nojekyll'));
    if (!await nojekyll.exists()) {
      await nojekyll.writeAsString('');
      log.detail('wrote .nojekyll');
    }

    final tokenR = await runner.runCapture(
      gh,
      ['auth', 'token'],
      allowDryRun: false,
    );
    final token = tokenR.stdout.trim();
    if (!tokenR.ok || token.isEmpty) {
      throw StateError(
        'gh auth token failed — run: gh auth login\n${tokenR.stderr}',
      );
    }

    final tmp = await Directory.systemTemp.createTemp('podfly_ghp_');
    try {
      final src = outDir.endsWith('/') ? outDir : '$outDir/';
      final copy = await runner.run(
        'rsync',
        ['-a', '--delete', src, '${tmp.path}/'],
        allowDryRun: false,
      );
      if (!copy.ok) {
        final cp = await runner.run(
          'cp',
          ['-a', src, '.'],
          workingDirectory: tmp.path,
          allowDryRun: false,
        );
        if (!cp.ok) {
          throw StateError('failed to stage GitHub Pages files');
        }
      }

      Future<void> git(List<String> args) async {
        final r = await runner.run(
          'git',
          args,
          workingDirectory: tmp.path,
          allowDryRun: false,
        );
        if (!r.ok) {
          throw StateError(
            'git ${args.join(' ')} failed (exit ${r.exitCode})',
          );
        }
      }

      await git(['init']);
      await git(['checkout', '-B', branch]);
      await git(['add', '-A']);
      final commit = await runner.run(
        'git',
        [
          '-c',
          'user.email=podfly@users.noreply.github.com',
          '-c',
          'user.name=podfly',
          'commit',
          '-m',
          'Deploy Flutter web (podfly)',
          '--allow-empty',
        ],
        workingDirectory: tmp.path,
        allowDryRun: false,
      );
      if (!commit.ok) {
        throw StateError('git commit failed for GitHub Pages deploy');
      }

      // Prefer x-access-token remote (works with gh OAuth tokens). Logs redact
      // the secret via ProcessRunner._redactCmdLine.
      final remote =
          'https://x-access-token:$token@github.com/$owner/$repo.git';
      final push = await runner.run(
        'git',
        ['push', '-f', remote, 'HEAD:$branch'],
        workingDirectory: tmp.path,
        allowDryRun: false,
      );
      if (!push.ok) {
        throw StateError(
          'git push to $owner/$repo $branch failed — '
          'ensure the token can write to the repo',
        );
      }
      log.detail('pushed $branch → $owner/$repo');
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> _ensureGhPagesEnabled(
    String gh, {
    required String owner,
    required String repo,
    required String branch,
  }) async {
    final get = await runner.runCapture(
      gh,
      ['api', 'repos/$owner/$repo/pages'],
      allowDryRun: false,
    );
    if (get.ok) {
      log.detail('GitHub Pages already enabled');
      return;
    }
    final post = await runner.runCapture(
      gh,
      [
        'api',
        '-X',
        'POST',
        'repos/$owner/$repo/pages',
        '-f',
        'build_type=legacy',
        '-f',
        'source[branch]=$branch',
        '-f',
        'source[path]=/',
      ],
      allowDryRun: false,
    );
    if (!post.ok) {
      final combined = (post.stdout + post.stderr).toLowerCase();
      if (combined.contains('already') ||
          combined.contains('409') ||
          combined.contains('exists')) {
        log.detail('GitHub Pages already configured');
        return;
      }
      log.warn(
        'could not enable GitHub Pages via API — enable in repo Settings → Pages '
        '(branch: $branch). Files are on the branch.\n${post.stderr}',
      );
      return;
    }
    log.ok('enabled GitHub Pages ($branch /)');
  }

  Future<void> _persistGitHubPages({
    required String publicHost,
    required String owner,
  }) async {
    final cfg = config;
    final base = cfg.githubPages ?? GitHubPagesConfig(repo: cfg.name);
    final updated = PodflyConfig(
      root: cfg.root,
      host: cfg.host,
      webHost: cfg.webHost,
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
      awsEcs: cfg.awsEcs,
      azure: cfg.azure,
      hetzner: cfg.hetzner,
      cloudflare: cfg.cloudflare,
      vercel: cfg.vercel,
      netlify: cfg.netlify,
      githubPages: GitHubPagesConfig(
        repo: base.repo,
        owner: owner,
        branch: base.branch,
        publicHost: publicHost,
        private: base.private,
      ),
      database: cfg.database,
      web: cfg.web,
      smoke: cfg.smoke,
    );
    await updated.save();
    log.detail('saved github_pages.public_host + owner');
  }

  static String? _extractVercelUrl(String text) {
    // Prefer production URLs
    final prod = RegExp(
      r'https://[a-zA-Z0-9][-a-zA-Z0-9.]*\.vercel\.app',
    ).allMatches(text);
    for (final m in prod) {
      final u = m.group(0)!;
      // Skip inspection / alias noise if multiple
      if (!u.contains('—') && !u.contains(' ')) return u;
    }
    // Any https URL on last lines
    final lines = text.split('\n').reversed;
    for (final line in lines) {
      final m = RegExp(r'https://\S+').firstMatch(line.trim());
      if (m != null) {
        final u = m.group(0)!.replaceAll(RegExp(r'[)>.,]+$'), '');
        if (u.contains('vercel.app') || u.startsWith('https://')) return u;
      }
    }
    return null;
  }

  /// Netlify `--json` prints a JSON object (sometimes after other logs).
  static Map<String, dynamic>? _parseNetlifyDeployJson(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    try {
      final v = jsonDecode(t);
      if (v is Map<String, dynamic>) return v;
    } catch (_) {}
    final start = t.lastIndexOf('{');
    final end = t.lastIndexOf('}');
    if (start >= 0 && end > start) {
      try {
        final v = jsonDecode(t.substring(start, end + 1));
        if (v is Map<String, dynamic>) return v;
      } catch (_) {}
    }
    return null;
  }

  static String? _hostFromUrl(Object? url) {
    if (url == null) return null;
    final s = url.toString().trim();
    if (s.isEmpty) return null;
    return s;
  }
}

/// Lightweight result so static web deploy need not import host adapter fully.
class HostDeployResultLike {
  HostDeployResultLike({this.publicHost, this.displayUrl});
  final String? publicHost;
  final String? displayUrl;
}
