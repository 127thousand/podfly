import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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
  ///
  /// On a color TTY, a short purple→white shimmer runs once (~0.5s).
  /// Disabled for quiet, `NO_COLOR`, dumb TERM, pipes, `CI=true`, or
  /// `PODFLY_NO_SHIMMER=1`.
  void banner({String? subtitle}) {
    if (quiet) return;
    _open = false;
    stdout.writeln('');
    if (_shouldShimmer) {
      _shimmerBanner(_bannerArt);
    } else {
      for (final line in _bannerArt) {
        stdout.writeln(_c(_purpleBold, line));
      }
    }
    if (subtitle != null && subtitle.isNotEmpty) {
      stdout.writeln('');
      stdout.writeln(_c(_dim, '  $subtitle'));
    }
    stdout.writeln('');
  }

  bool get _shouldShimmer {
    if (!color || !stdout.hasTerminal) return false;
    if (Platform.environment['PODFLY_NO_SHIMMER'] == '1') return false;
    if (Platform.environment['CI'] == 'true') return false;
    return true;
  }

  /// Sweep a bright band across the wordmark, then settle on solid purple.
  void _shimmerBanner(List<String> lines) {
    final width = lines.fold<int>(0, (w, l) => math.max(w, l.length));
    const band = 8;
    const frameMs = 28;
    final frames = ((width + band * 2) / 2.5).ceil().clamp(10, 20);

    stdout.write('\x1B[?25l'); // hide cursor
    try {
      for (final line in lines) {
        stdout.writeln(_shimmerLine(line, peak: -band, band: band));
      }

      for (var f = 0; f < frames; f++) {
        final peak = -band + (f * (width + band * 2) / frames).round();
        stdout.write('\x1B[${lines.length}A');
        for (final line in lines) {
          stdout.write('\x1B[2K');
          stdout.writeln(_shimmerLine(line, peak: peak, band: band));
        }
        sleep(const Duration(milliseconds: frameMs));
      }

      // Final solid brand purple.
      stdout.write('\x1B[${lines.length}A');
      for (final line in lines) {
        stdout.write('\x1B[2K');
        stdout.writeln(_c(_purpleBold, line));
      }
    } finally {
      stdout.write('\x1B[?25h');
    }
  }

  /// Color one art line with a highlight centered at [peak] column.
  String _shimmerLine(String line, {required int peak, required int band}) {
    if (!color) return line;
    final buf = StringBuffer();
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      // Keep pure spaces unstyled so background stays clean.
      if (ch == ' ') {
        buf.write(ch);
        continue;
      }
      final d = (i - peak).abs();
      if (d <= 1) {
        // Hot core — near white
        buf.write('\x1B[1;38;2;255;255;255m$ch$_reset');
      } else if (d <= band ~/ 3) {
        // Bright lavender
        buf.write('\x1B[1;38;2;233;213;255m$ch$_reset'); // #e9d5ff
      } else if (d <= (band * 2) ~/ 3) {
        // Brand purple
        buf.write('\x1B[1;38;2;192;132;252m$ch$_reset'); // #c084fc
      } else if (d <= band) {
        // Soft edge
        buf.write('\x1B[38;2;167;139;250m$ch$_reset'); // #a78bfa
      } else {
        // Base glyph (deeper purple)
        buf.write('\x1B[1;38;2;126;34;206m$ch$_reset'); // #7e22ce
      }
    }
    return buf.toString();
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
