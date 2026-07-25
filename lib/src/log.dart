import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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

  /// ANSI Shadow–style PODFLY wordmark (same family as `serverpod` CLI).
  static const _bannerArt = r'''
  ██████╗   ██████╗  ██████╗  ███████╗ ██╗     ██╗   ██╗
  ██╔══██╗ ██╔═══██╗ ██╔══██╗ ██╔════╝ ██║     ╚██╗ ██╔╝
  ██████╔╝ ██║   ██║ ██║  ██║ █████╗   ██║      ╚████╔╝ 
  ██╔═══╝  ██║   ██║ ██║  ██║ ██╔══╝   ██║       ╚██╔╝  
  ██║      ╚██████╔╝ ██████╔╝ ██║      ███████╗   ██║   
  ╚═╝       ╚═════╝  ╚═════╝  ╚═╝      ╚══════╝   ╚═╝   
''';

  String _c(String code, String s) => color ? '$code$s$_reset' : s;

  /// Big-letter PODFLY banner. On a color TTY, a short purple→white shimmer
  /// runs once (~0.5s). Disabled for quiet, `NO_COLOR`, dumb TERM, pipes, or
  /// `PODFLY_NO_SHIMMER=1`.
  void banner({String? subtitle}) {
    if (quiet) return;
    final lines = _bannerArt
        .split('\n')
        .where((l) => l.isNotEmpty)
        .toList(growable: false);

    stdout.writeln('');
    if (_shouldShimmer) {
      _shimmerBanner(lines);
    } else {
      for (final line in lines) {
        stdout.writeln(_c(_purpleBold, line));
      }
    }
    stdout.writeln(
      _c(_dim, '  🚀 Serverpod, 🍷 BYO cloud.'),
    );
    if (subtitle != null) {
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
    final width =
        lines.fold<int>(0, (w, l) => math.max(w, l.length));
    const band = 10;
    const frameMs = 28;
    final frames = ((width + band * 2) / 3).ceil().clamp(12, 22);

    // Hide cursor for cleaner rewrite.
    stdout.write('\x1B[?25l');
    try {
      // Initial paint (dim purple base).
      for (final line in lines) {
        stdout.writeln(_shimmerLine(line, peak: -band, band: band));
      }

      for (var f = 0; f < frames; f++) {
        final peak = -band + f * 3;
        // Move cursor up to rewrite art lines in place.
        stdout.write('\x1B[${lines.length}A');
        for (final line in lines) {
          stdout.write('\x1B[2K'); // clear line
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
        buf.write('\x1B[1;38;5;231m$ch$_reset');
      } else if (d <= band ~/ 3) {
        // Bright lavender
        buf.write('\x1B[1;38;5;189m$ch$_reset');
      } else if (d <= (band * 2) ~/ 3) {
        // Brand purple
        buf.write('\x1B[1;38;5;141m$ch$_reset');
      } else if (d <= band) {
        // Soft edge
        buf.write('\x1B[38;5;104m$ch$_reset');
      } else {
        // Base glyph
        buf.write('\x1B[1;38;5;98m$ch$_reset');
      }
    }
    return buf.toString();
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
