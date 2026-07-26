import 'dart:async';
import 'dart:io';

/// CLI logging in the OpenCode / clack style: clean half-block wordmark and a
/// vertical tree of steps (`┌` `│` `●` `◇` `└`).
///
/// Respects `NO_COLOR`, dumb `TERM`, and non-TTY.
class Log {
  Log({this.quiet = false, bool? color}) : color = color ?? _detectColor();

  final bool quiet;
  final bool color;

  /// True while a step group is open (after [step] / [banner] intro).
  bool _open = false;

  static bool _detectColor() {
    if (Platform.environment.containsKey('NO_COLOR')) return false;
    if (Platform.environment['TERM'] == 'dumb') return false;
    return stdout.hasTerminal;
  }

  // Brand purple
  static const _purple = '\x1B[38;2;167;139;250m'; // #a78bfa
  static const _purpleBold = '\x1B[1;38;2;192;132;252m'; // #c084fc bold
  static const _dim = '\x1B[2m';
  static const _green = '\x1B[32m';
  static const _yellow = '\x1B[33m';
  static const _red = '\x1B[31m';
  static const _reset = '\x1B[0m';

  /// OpenCode-style half-block PODFLy (3 rows).
  static const _bannerArt = [
    r'  █▀▀█ █▀▀█ █▀▀▄ █▀▀▀ █    █  █',
    r'  █  █ █  █ █  █ █▀▀  █    ▀▀▀█',
    r'  █▀▀▀ ▀▀▀▀ ▀▀▀▀ █    ▀▀▀▀ ▀▀▀▀',
  ];

  String _c(String code, String s) => color ? '$code$s$_reset' : s;

  String get _pipe => _c(_dim, '│');

  void _ensurePipe() {
    if (!_open || quiet) return;
    stdout.writeln(_pipe);
  }

  /// Half-block PODFLy mark + optional dim subtitle (command name).
  void banner({String? subtitle}) {
    if (quiet) return;
    _open = false;
    stdout.writeln('');
    for (final line in _bannerArt) {
      stdout.writeln(_c(_purpleBold, line));
    }
    if (subtitle != null && subtitle.isNotEmpty) {
      stdout.writeln('');
      stdout.writeln(_c(_dim, '  $subtitle'));
    }
    stdout.writeln('');
  }

  void info(String msg) {
    if (quiet) return;
    if (!_open) {
      stdout.writeln(msg);
      return;
    }
    if (msg.isEmpty) {
      stdout.writeln(_pipe);
      return;
    }
    _ensurePipe();
    stdout.writeln('$_pipe  $msg');
  }

  /// Start a major section: `┌  Title`
  void step(String msg) {
    if (quiet) return;
    if (_open) {
      stdout.writeln(_pipe);
    }
    stdout.writeln('${_c(_purpleBold, '┌')}  $msg');
    _open = true;
  }

  /// Dim bullet under the current step: `●  …`
  void detail(String msg) {
    if (quiet) return;
    _ensurePipe();
    stdout.writeln('${_c(_dim, '●')}  ${_c(_dim, msg)}');
    _open = true;
  }

  /// Success under the current step: `◇  …`
  void ok(String msg) {
    if (quiet) return;
    _ensurePipe();
    stdout.writeln('${_c(_green, '◇')}  $msg');
    _open = true;
  }

  /// Warning: `▲  …` (stderr)
  void warn(String msg) {
    _ensurePipe();
    stderr.writeln('${_c(_yellow, '▲')}  $msg');
    _open = true;
  }

  /// Error: `■  …` (stderr)
  void err(String msg) {
    _ensurePipe();
    stderr.writeln('${_c(_red, '■')}  $msg');
    _open = true;
  }

  /// Dry-run note: dim `●  [dry-run] …`
  void dry(String msg) {
    if (quiet) return;
    _ensurePipe();
    stdout.writeln('${_c(_dim, '●')}  ${_c(_dim, '[dry-run] $msg')}');
    _open = true;
  }

  /// Tip: purple bullet
  void tip(String msg) {
    if (quiet) return;
    _ensurePipe();
    stdout.writeln('${_c(_purple, '●')}  ${_c(_dim, msg)}');
    _open = true;
  }

  /// Close the tree: `└  label in …`
  void elapsed(Duration d, {String label = 'Done'}) {
    if (quiet) return;
    final s = _formatDuration(d);
    _ensurePipe();
    stdout.writeln('${_c(_purpleBold, '└')}  $label in $s');
    stdout.writeln('');
    _open = false;
  }

  /// Explicit outro without duration (e.g. end of create).
  void done([String msg = 'Done']) {
    if (quiet) return;
    _ensurePipe();
    stdout.writeln('${_c(_purpleBold, '└')}  $msg');
    stdout.writeln('');
    _open = false;
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

  /// Spinner on the tree line while [work] runs (TTY + color only).
  Future<T> withSpinner<T>(String message, Future<T> Function() work) async {
    if (quiet || !color || !stdout.hasTerminal) {
      detail('$message…');
      return work();
    }
    const frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
    var i = 0;
    final sw = Stopwatch()..start();
    // Open pipe line once, then rewrite the spinner row.
    if (_open) stdout.writeln(_pipe);
    _open = true;
    final timer = Timer.periodic(const Duration(milliseconds: 80), (_) {
      final frame = frames[i % frames.length];
      i++;
      final sec = (sw.elapsedMilliseconds / 1000).toStringAsFixed(1);
      stdout.write(
        '\r${_c(_purple, frame)}  $message  ${_c(_dim, '${sec}s')}   ',
      );
    });
    try {
      final result = await work();
      timer.cancel();
      stdout.write('\r${' ' * (message.length + 28)}\r');
      return result;
    } catch (e) {
      timer.cancel();
      stdout.write('\r${' ' * (message.length + 28)}\r');
      rethrow;
    }
  }
}
