import 'dart:io';

import 'package:mason_logger/mason_logger.dart' as ml;

/// True when stdin/stdout are attached to an interactive terminal.
bool get isTty => stdin.hasTerminal && stdout.hasTerminal;

/// Shared mason logger for arrow-key menus (↑/↓ + enter).
///
/// Not used for normal deploy logging (that stays on [Log] with the purple
/// banner). Theme leans purple/cyan for podfly branding.
final ml.Logger _ml = ml.Logger(
  level: ml.Level.info,
  theme: ml.LogTheme(
    info: (m) => m,
    detail: (m) => ml.darkGray.wrap(m),
    success: (m) => ml.lightGreen.wrap(m),
    warn: (m) => ml.yellow.wrap(m),
    err: (m) => ml.lightRed.wrap(m),
  ),
);

Future<bool> confirm(String question, {bool defaultYes = true}) async {
  if (!isTty) return defaultYes;
  try {
    return _ml.confirm(
      question,
      defaultValue: defaultYes,
    );
  } catch (_) {
    // Fallback if raw mode fails (piped stdin, etc.)
    final hint = defaultYes ? 'Y/n' : 'y/N';
    stdout.write('$question [$hint] ');
    final line = stdin.readLineSync()?.trim().toLowerCase() ?? '';
    if (line.isEmpty) return defaultYes;
    return line == 'y' || line == 'yes';
  }
}

Future<String> prompt(String question, {String? defaultValue}) async {
  if (!isTty) return defaultValue ?? '';
  try {
    final result = _ml.prompt(
      question,
      defaultValue: defaultValue ?? '',
    );
    if (result.isEmpty && defaultValue != null) return defaultValue;
    return result;
  } catch (_) {
    final hint = defaultValue != null ? ' [$defaultValue]' : '';
    stdout.write('$question$hint: ');
    final line = stdin.readLineSync()?.trim() ?? '';
    if (line.isEmpty && defaultValue != null) return defaultValue;
    return line;
  }
}

/// Interactive single-select with **↑/↓** (or j/k) and Enter.
///
/// Returns the selected index. Falls back to numbered menu if the terminal
/// does not support raw mode.
Future<int> choose(
  String question,
  List<String> options, {
  int defaultIndex = 0,
}) async {
  if (options.isEmpty) return 0;
  final safeDefault = defaultIndex.clamp(0, options.length - 1);

  if (!isTty) return safeDefault;

  try {
    final selected = _ml.chooseOne<String>(
      question,
      choices: options,
      defaultValue: options[safeDefault],
    );
    final idx = options.indexOf(selected);
    return idx >= 0 ? idx : safeDefault;
  } catch (_) {
    return _numberedChoose(question, options, safeDefault);
  }
}

int _numberedChoose(String question, List<String> options, int defaultIndex) {
  stdout.writeln(question);
  for (var i = 0; i < options.length; i++) {
    final mark = i == defaultIndex ? '*' : ' ';
    stdout.writeln('  $mark ${i + 1}) ${options[i]}');
  }
  stdout.write('Choice [${defaultIndex + 1}]: ');
  final line = stdin.readLineSync()?.trim() ?? '';
  if (line.isEmpty) return defaultIndex;
  final n = int.tryParse(line);
  if (n == null || n < 1 || n > options.length) return defaultIndex;
  return n - 1;
}
