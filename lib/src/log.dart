import 'dart:io';

/// Simple colored CLI logging.
class Log {
  final bool quiet;
  Log({this.quiet = false});

  void info(String msg) {
    if (!quiet) stdout.writeln(msg);
  }

  void step(String msg) {
    if (!quiet) stdout.writeln('\n==> $msg');
  }

  void detail(String msg) {
    if (!quiet) stdout.writeln('    $msg');
  }

  void ok(String msg) {
    if (!quiet) stdout.writeln('  ✓ $msg');
  }

  void warn(String msg) {
    stderr.writeln('  ! $msg');
  }

  void err(String msg) {
    stderr.writeln('  ✗ $msg');
  }

  void dry(String msg) {
    if (!quiet) stdout.writeln('  [dry-run] $msg');
  }
}
