#!/usr/bin/env dart
import 'dart:io';

import 'package:podfly/src/cli.dart';

Future<void> main(List<String> args) async {
  try {
    final code = await runPodfly(args);
    exit(code);
  } catch (e, st) {
    stderr.writeln('podfly: $e');
    if (Platform.environment['PODFLY_DEBUG'] == '1') {
      stderr.writeln(st);
    }
    exit(1);
  }
}
