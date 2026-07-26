import 'log.dart';
import 'process_runner.dart';
import 'version.dart';

/// How to reinstall / upgrade the podfly CLI itself.
enum UpgradeSource {
  /// `dart pub global activate podfly` (pub.dev).
  pub,

  /// `dart pub global activate --source git <url>`.
  git,

  /// `dart pub global activate --source path <dir>`.
  path,
}

class UpgradeOptions {
  UpgradeOptions({
    this.source = UpgradeSource.pub,
    this.gitUrl = 'https://github.com/127thousand/podfly.git',
    this.pathDir,
    this.dryRun = false,
    this.yes = false,
  });

  final UpgradeSource source;
  final String gitUrl;
  final String? pathDir;
  final bool dryRun;
  final bool yes;
}

/// Upgrade (or reinstall) the globally activated `podfly` executable.
class Upgrader {
  Upgrader({required this.log, required this.runner});

  final Log log;
  final ProcessRunner runner;

  Future<int> run(UpgradeOptions opts) async {
    log.step('Upgrade');

    final before = await installedGlobalVersion();
    log.detail('This binary: $podflyVersion');
    if (before != null) {
      log.detail('pub global list: podfly $before');
    } else {
      log.detail('pub global list: podfly not listed (path/git install?)');
    }

    final dart = await runner.resolve('dart', ['dart']);
    if (dart == null) {
      log.err('dart not found on PATH — cannot upgrade');
      return 1;
    }

    final args = <String>['pub', 'global', 'activate'];
    switch (opts.source) {
      case UpgradeSource.pub:
        args.add('podfly');
        log.detail('Source: pub.dev (package podfly)');
      case UpgradeSource.git:
        args.addAll(['--source', 'git', opts.gitUrl]);
        log.detail('Source: git ${opts.gitUrl}');
      case UpgradeSource.path:
        final dir = opts.pathDir;
        if (dir == null || dir.isEmpty) {
          log.err('--path requires a directory');
          return 64;
        }
        args.addAll(['--source', 'path', dir]);
        log.detail('Source: path $dir');
    }

    final cmdLine = '$dart ${args.join(' ')}';
    if (opts.dryRun) {
      log.dry(cmdLine);
      log.done('Dry-run complete');
      return 0;
    }

    log.detail('Running: $cmdLine');
    final r = await runner.run(
      dart,
      args,
      allowDryRun: false,
      inheritStdio: true,
    );
    if (!r.ok) {
      log.err('upgrade failed (exit ${r.exitCode})');
      if (r.stderr.isNotEmpty) log.detail(r.stderr.trim());
      return r.exitCode == 0 ? 1 : r.exitCode;
    }

    final after = await installedGlobalVersion();
    if (before != null && after != null && before != after) {
      log.ok('Upgraded $before → $after');
    } else if (after != null) {
      log.ok('Active global version: $after');
    } else {
      log.ok('Activate finished (re-open shell if `podfly` is not found)');
    }

    if (after != null && after != podflyVersion) {
      log.tip(
        'This process still reports $podflyVersion until you start a new '
        '`podfly` invocation.',
      );
    }

    log.tip('Verify: podfly version && podfly doctor');
    log.done('Upgrade complete');
    return 0;
  }

  /// Parse `dart pub global list` for `podfly <version>`.
  Future<String?> installedGlobalVersion() async {
    final dart = await runner.resolve('dart', ['dart']);
    if (dart == null) return null;
    // Always hit the real pub global list (even when upgrade is --dry-run).
    final r = await runner.runCapture(
      dart,
      ['pub', 'global', 'list'],
      allowDryRun: false,
    );
    if (!r.ok) return null;
    for (final line in r.stdout.split('\n')) {
      final t = line.trim();
      // "podfly 0.11.0" or "podfly 0.11.0 at path ..."
      final m = RegExp(r'^podfly\s+(\S+)').firstMatch(t);
      if (m != null) return m.group(1);
    }
    return null;
  }
}
