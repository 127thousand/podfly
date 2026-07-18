import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Locate package templates/ whether running from source or pub cache.
Directory? findTemplatesDir() {
  // 1. Adjacent to script (bin/../templates)
  final script = Platform.script.toFilePath();
  final fromBin = p.normalize(p.join(p.dirname(script), '..', 'templates'));
  if (Directory(fromBin).existsSync()) return Directory(fromBin);

  // 2. Walk up from cwd looking for podfly package
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final t = p.join(dir.path, 'templates');
    final pub = p.join(dir.path, 'pubspec.yaml');
    if (File(pub).existsSync()) {
      final name = File(pub).readAsStringSync();
      if (name.contains('name: podfly') && Directory(t).existsSync()) {
        return Directory(t);
      }
    }
    if (dir.parent.path == dir.path) break;
    dir = dir.parent;
  }

  // 3. Pub global / cache — package_config.json
  try {
    final configFile = File(p.join(
      p.dirname(script),
      '..',
      '.dart_tool',
      'package_config.json',
    ));
    if (configFile.existsSync()) {
      final json =
          jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
      final packages = json['packages'];
      if (packages is List) {
        for (final pkg in packages) {
          if (pkg is! Map) continue;
          if (pkg['name'] != 'podfly') continue;
          final rootUri = pkg['rootUri']?.toString();
          if (rootUri == null) continue;
          var root = rootUri;
          if (root.startsWith('file://')) {
            root = Uri.parse(root).toFilePath();
          } else if (!p.isAbsolute(root)) {
            root = p.normalize(
              p.join(p.dirname(configFile.path), root),
            );
          }
          final t = p.join(root, 'templates');
          if (Directory(t).existsSync()) return Directory(t);
        }
      }
    }
  } catch (_) {}

  return null;
}

String readTemplate(String name) {
  final dir = findTemplatesDir();
  if (dir == null) {
    throw StateError('podfly templates/ not found');
  }
  final f = File(p.join(dir.path, name));
  if (!f.existsSync()) throw StateError('Missing template: $name');
  return f.readAsStringSync();
}
