import 'dart:convert';
import 'dart:io';

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
class ProcessRunner {
  ProcessRunner({required this.log, this.dryRun = false});

  final Log log;
  final bool dryRun;

  Future<bool> which(String cmd) async {
    final r = await Process.run('which', [cmd], runInShell: true);
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

  Future<RunResult> runCapture(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    bool allowDryRun = false,
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
