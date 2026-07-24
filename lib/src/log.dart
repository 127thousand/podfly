import 'dart:async';
import 'dart:io';

/// CLI logging with purple brand banner, restrained ANSI color, emojis,
/// and optional ASCII spinners. Respects `NO_COLOR` and non-TTY.
class Log {
  Log({this.quiet = false, bool? color})
      : color = color ?? _detectColor();

  final bool quiet;
  final bool color;

  static bool _detectColor() {
    if (Platform.environment.containsKey('NO_COLOR')) return false;
    if (Platform.environment['TERM'] == 'dumb') return false;
    return stdout.hasTerminal;
  }

  // Purple / brand
  static const _purple = '\x1B[38;5;141m';
  static const _purpleBold = '\x1B[1;38;5;141m';
  static const _dim = '\x1B[2m';
  static const _green = '\x1B[32m';
  static const _yellow = '\x1B[33m';
  static const _red = '\x1B[31m';
  static const _cyan = '\x1B[36m';
  static const _reset = '\x1B[0m';

  String _c(String code, String s) => color ? '$code$s$_reset' : s;

  /// Big-letter PODFLY banner (Serverpod-style block font), purple.
  void banner({String? subtitle}) {
    if (quiet) return;
    // ANSI Shadow–style (same family as `serverpod` CLI wordmarks).
    const art = r'''
  ██████╗   ██████╗  ██████╗  ███████╗ ██╗     ██╗   ██╗
  ██╔══██╗ ██╔═══██╗ ██╔══██╗ ██╔════╝ ██║     ╚██╗ ██╔╝
  ██████╔╝ ██║   ██║ ██║  ██║ █████╗   ██║      ╚████╔╝ 
  ██╔═══╝  ██║   ██║ ██║  ██║ ██╔══╝   ██║       ╚██╔╝  
  ██║      ╚██████╔╝ ██████╔╝ ██║      ███████╗   ██║   
  ╚═╝       ╚═════╝  ╚═════╝  ╚═╝      ╚══════╝   ╚═╝   
''';
    stdout.writeln('');
    for (final line in art.split('\n')) {
      if (line.isEmpty) continue;
      stdout.writeln(_c(_purpleBold, line));
    }
    stdout.writeln(
      _c(_dim, '  🚀 Serverpod, 🍷 BYO cloud.'),
    );
    if (subtitle != null) {
      stdout.writeln(_c(_dim, '  $subtitle'));
    }
    stdout.writeln('');
  }

  void info(String msg) {
    if (!quiet) stdout.writeln(msg);
  }

  void step(String msg) {
    if (quiet) return;
    stdout.writeln('');
    stdout.writeln(_c(_purpleBold, '==> ') + _c(_cyan, '🚀 $msg'));
  }

  void detail(String msg) {
    if (quiet) return;
    stdout.writeln(_c(_dim, '    $msg'));
  }

  void ok(String msg) {
    if (quiet) return;
    stdout.writeln(_c(_green, '  ✓ ') + msg);
  }

  void warn(String msg) {
    stderr.writeln(_c(_yellow, '  ⚠ ') + msg);
  }

  void err(String msg) {
    stderr.writeln(_c(_red, '  ✗ ') + msg);
  }

  void dry(String msg) {
    if (quiet) return;
    stdout.writeln(_c(_dim, '  [dry-run] $msg'));
  }

  void tip(String msg) {
    if (quiet) return;
    stdout.writeln(_c(_purple, '  💡 ') + _c(_dim, msg));
  }

  /// Elapsed duration line (e.g. end of deploy). Always loud — not quietable
  /// beyond [quiet], so failures still report how long things ran.
  void elapsed(Duration d, {String label = 'Done'}) {
    if (quiet) return;
    final s = _formatDuration(d);
    stdout.writeln('');
    stdout.writeln(
      _c(_purpleBold, '════════════════════════════════════════'),
    );
    stdout.writeln(
      _c(_purpleBold, '  ⏱  $label in $s'),
    );
    stdout.writeln(
      _c(_purpleBold, '════════════════════════════════════════'),
    );
  }

  static String _formatDuration(Duration d) {
    if (d.inHours > 0) {
      final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
      final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
      return '${d.inHours}h ${m}m ${s}s';
    }
    if (d.inMinutes > 0) {
      final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
      return '${d.inMinutes}m ${s}s';
    }
    if (d.inSeconds > 0) {
      return '${d.inSeconds}s';
    }
    return '${d.inMilliseconds}ms';
  }

  /// Run [work] with an ASCII spinner while waiting (TTY + color only).
  Future<T> withSpinner<T>(String message, Future<T> Function() work) async {
    if (quiet || !color || !stdout.hasTerminal) {
      detail('$message…');
      return work();
    }
    const frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
    var i = 0;
    final sw = Stopwatch()..start();
    final timer = Timer.periodic(const Duration(milliseconds: 80), (_) {
      final frame = frames[i % frames.length];
      i++;
      final sec = (sw.elapsedMilliseconds / 1000).toStringAsFixed(1);
      stdout.write('\r${_c(_purple, '  $frame ')}$message  ${_c(_dim, '${sec}s')}   ');
    });
    try {
      final result = await work();
      timer.cancel();
      stdout.write('\r${' ' * (message.length + 24)}\r');
      return result;
    } catch (e) {
      timer.cancel();
      stdout.write('\r${' ' * (message.length + 24)}\r');
      rethrow;
    }
  }
}
