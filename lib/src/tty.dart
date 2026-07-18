import 'dart:io';

bool get isTty => stdin.hasTerminal && stdout.hasTerminal;

Future<bool> confirm(String question, {bool defaultYes = true}) async {
  if (!isTty) return defaultYes;
  final hint = defaultYes ? 'Y/n' : 'y/N';
  stdout.write('$question [$hint] ');
  final line = stdin.readLineSync()?.trim().toLowerCase() ?? '';
  if (line.isEmpty) return defaultYes;
  return line == 'y' || line == 'yes';
}

Future<String> prompt(String question, {String? defaultValue}) async {
  if (!isTty) return defaultValue ?? '';
  final hint = defaultValue != null ? ' [$defaultValue]' : '';
  stdout.write('$question$hint: ');
  final line = stdin.readLineSync()?.trim() ?? '';
  if (line.isEmpty && defaultValue != null) return defaultValue;
  return line;
}

Future<int> choose(String question, List<String> options,
    {int defaultIndex = 0}) async {
  if (!isTty) return defaultIndex;
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
