import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../log.dart';
import '../process_runner.dart';
import '../templates.dart';

class WebBuilder {
  WebBuilder({
    required this.config,
    required this.runner,
    required this.log,
  });

  final PodflyConfig config;
  final ProcessRunner runner;
  final Log log;

  Future<void> ensureBootstrap() async {
    if (!config.web.patchBootstrap) return;
    final dest =
        File(p.join(config.flutterPath, 'web', 'flutter_bootstrap.js'));
    final marker = 'canvasKitBaseUrl';
    if (await dest.exists()) {
      final existing = await dest.readAsString();
      if (existing.contains(marker) &&
          !existing.contains('serviceWorkerSettings')) {
        log.detail('bootstrap already podfly-style');
        return;
      }
      log.warn('web/flutter_bootstrap.js exists; leaving in place '
          '(set patch_bootstrap and replace manually if needed)');
      return;
    }
    if (runner.dryRun) {
      log.dry('write ${dest.path}');
      return;
    }
    await dest.parent.create(recursive: true);
    await dest.writeAsString(readTemplate('flutter_bootstrap.js'));
    log.ok('wrote ${p.relative(dest.path, from: config.root)}');
  }

  Future<void> ensureHeadersSource() async {
    if (!config.web.writeHeaders) return;
    final webDir = p.join(config.flutterPath, 'web');
    for (final name in ['_headers', '_redirects']) {
      final dest = File(p.join(webDir, name));
      if (await dest.exists()) continue;
      if (runner.dryRun) {
        log.dry('write ${dest.path}');
        continue;
      }
      await dest.writeAsString(readTemplate(name));
      log.ok('wrote web/$name');
    }
  }

  Future<void> build() async {
    log.step('Build Flutter web');
    await ensureBootstrap();
    await ensureHeadersSource();

    // Always build inside the package (asset path bug with external --output).
    final r = await runner.run(
      'flutter',
      [
        'build',
        'web',
        '--release',
        '--base-href',
        config.web.baseHref,
        '--dart-define=${config.web.serverUrlDefine}=${config.web.apiUrlNormalized}',
      ],
      workingDirectory: config.flutterPath,
    );
    if (!r.ok && !runner.dryRun) {
      throw StateError('flutter build web failed (exit ${r.exitCode})');
    }

    final pkgWeb = p.join(config.flutterPath, 'build', 'web');
    final out = config.webOutPath;

    if (runner.dryRun) {
      log.dry('rsync $pkgWeb/ → $out/');
      return;
    }

    final pkgDir = Directory(pkgWeb);
    if (!await pkgDir.exists()) {
      throw StateError('Missing build output: $pkgWeb');
    }
    final index = File(p.join(pkgWeb, 'index.html'));
    if (!await index.exists()) {
      throw StateError('web build missing index.html');
    }

    await Directory(out).create(recursive: true);
    // Prefer rsync
    if (await runner.which('rsync')) {
      final sync = await runner.run(
        'rsync',
        ['-a', '--delete', '$pkgWeb/', '$out/'],
        allowDryRun: false,
      );
      if (!sync.ok) throw StateError('rsync failed');
    } else {
      await _copyDir(pkgWeb, out);
    }

    // Copy meta files into out
    for (final name in ['_headers', '_redirects']) {
      final src = File(p.join(config.flutterPath, 'web', name));
      if (await src.exists()) {
        await src.copy(p.join(out, name));
      }
    }

    final jpgCount = await _countFiles(out, '.jpg');
    log.detail('asset jpgs in build: $jpgCount (info only)');
    log.ok('web → $out');
  }

  Future<void> _copyDir(String from, String to) async {
    await for (final ent
        in Directory(from).list(recursive: true, followLinks: false)) {
      final rel = p.relative(ent.path, from: from);
      final dest = p.join(to, rel);
      if (ent is Directory) {
        await Directory(dest).create(recursive: true);
      } else if (ent is File) {
        await File(dest).parent.create(recursive: true);
        await ent.copy(dest);
      }
    }
  }

  Future<int> _countFiles(String dir, String ext) async {
    var n = 0;
    final d = Directory(dir);
    if (!await d.exists()) return 0;
    await for (final ent in d.list(recursive: true, followLinks: false)) {
      if (ent is File && ent.path.endsWith(ext)) n++;
    }
    return n;
  }
}
