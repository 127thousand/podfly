import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'log.dart';

class RunResult {
  RunResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });
  final int exitCode;
  final String stdout;
  final String stderr;
  bool get ok => exitCode == 0;
}

/// Runs external tools (flutter, fly, wrangler, …).
///
/// When [dryRun] is true, [run] / [runCapture] skip process execution unless
/// [allowDryRun] is set to false (for rare cases that must always run).
class ProcessRunner {
  ProcessRunner({required this.log, this.dryRun = false});

  final Log log;
  final bool dryRun;

  /// Whether [cmd] is on PATH (Windows uses `where`, elsewhere `which`).
  Future<bool> which(String cmd) async {
    // Also check PATH directories directly for reliability.
    final pathEnv = Platform.environment['PATH'] ?? '';
    final sep = Platform.isWindows ? ';' : ':';
    final exts = Platform.isWindows
        ? (Platform.environment['PATHEXT'] ?? '.EXE;.BAT;.CMD')
            .split(';')
            .where((e) => e.isNotEmpty)
            .toList()
        : <String>[''];

    for (final dir in pathEnv.split(sep)) {
      if (dir.isEmpty) continue;
      for (final ext in exts) {
        final candidate = p.join(dir, '$cmd${ext.toLowerCase()}');
        if (File(candidate).existsSync()) return true;
        // Windows often has mixed-case extensions
        final candidate2 = p.join(dir, '$cmd$ext');
        if (File(candidate2).existsSync()) return true;
      }
      // Unix: exact name
      if (!Platform.isWindows && File(p.join(dir, cmd)).existsSync()) {
        return true;
      }
    }

    final finder = Platform.isWindows ? 'where' : 'which';
    final r = await Process.run(
      finder,
      [cmd],
      runInShell: true,
    );
    return r.exitCode == 0 && (r.stdout as String).trim().isNotEmpty;
  }

  Future<String?> resolve(String cmd, [List<String> alts = const []]) async {
    for (final c in [cmd, ...alts]) {
      if (await which(c)) return c;
    }
    return null;
  }

  Future<RunResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    bool inheritStdio = true,
    /// When true (default), honor [dryRun] and skip execution.
    bool allowDryRun = true,
    Map<String, String>? environment,
  }) async {
    final cmdLine = '$executable ${arguments.join(' ')}';
    if (dryRun && allowDryRun) {
      log.dry(cmdLine +
          (workingDirectory != null ? '  (cwd: $workingDirectory)' : ''));
      return RunResult(exitCode: 0, stdout: '', stderr: '');
    }

    log.detail('→ $cmdLine');

    if (inheritStdio) {
      final proc = await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        mode: ProcessStartMode.inheritStdio,
        runInShell: false,
      );
      final code = await proc.exitCode;
      return RunResult(exitCode: code, stdout: '', stderr: '');
    }

    final r = await Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: false,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    return RunResult(
      exitCode: r.exitCode,
      stdout: r.stdout as String,
      stderr: r.stderr as String,
    );
  }

  /// Capture stdout/stderr. Defaults [allowDryRun] to true so dry-run is consistent.
  Future<RunResult> runCapture(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    bool allowDryRun = true,
  }) {
    return run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      inheritStdio: false,
      allowDryRun: allowDryRun,
    );
  }
}
