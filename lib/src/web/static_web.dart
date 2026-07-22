import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../log.dart';
import '../process_runner.dart';
import '../templates.dart';

/// Deploy Flutter web static output to a CDN-style host (Pages / Vercel).
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

    final args = <String>[
      'deploy',
      out,
      '--prod',
      '--yes',
      '--project',
      project,
    ];
    final token = Platform.environment['VERCEL_TOKEN'];
    if (token != null && token.isNotEmpty) {
      args.addAll(['--token', token]);
    }
    final scope = vc.scope;
    if (scope != null && scope.isNotEmpty) {
      args.addAll(['--scope', scope]);
    }

    final r = await runner.runCapture(vercel, args, allowDryRun: false);
    if (!r.ok) {
      throw StateError(
        'vercel deploy failed (exit ${r.exitCode}):\n${r.stderr}\n${r.stdout}',
      );
    }

    final url = _extractVercelUrl(r.stdout) ??
        _extractVercelUrl(r.stderr) ??
        'https://$project.vercel.app';
    final host = url
        .replaceFirst(RegExp(r'^https?://'), '')
        .split('/')
        .first;
    log.ok('Vercel: $url');

    // Persist public_host when we resolved a real URL
    if (!runner.dryRun && host.isNotEmpty) {
      await _persistVercelHost(host);
    }

    return HostDeployResultLike(publicHost: host, displayUrl: url);
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
      database: cfg.database,
      web: cfg.web,
      smoke: cfg.smoke,
    );
    await updated.save();
    log.detail('saved vercel.public_host');
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
}

/// Lightweight result so static web deploy need not import host adapter fully.
class HostDeployResultLike {
  HostDeployResultLike({this.publicHost, this.displayUrl});
  final String? publicHost;
  final String? displayUrl;
}
