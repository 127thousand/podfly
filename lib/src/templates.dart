import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

/// Locate package templates/ whether running from source or pub cache.
Directory? findTemplatesDir() {
  // 0. package:podfly → root/templates (works for path + global activate)
  try {
    final uri = Isolate.resolvePackageUriSync(
      Uri.parse('package:podfly/podfly.dart'),
    );
    if (uri != null && uri.scheme == 'file') {
      final libFile = uri.toFilePath();
      // .../lib/podfly.dart → package root
      final root = p.dirname(p.dirname(libFile));
      final t = p.join(root, 'templates');
      if (Directory(t).existsSync()) return Directory(t);
    }
  } catch (_) {}

  // 1. Adjacent to script (bin/../templates)
  final script = Platform.script.toFilePath();
  final fromBin = p.normalize(p.join(p.dirname(script), '..', 'templates'));
  if (Directory(fromBin).existsSync()) return Directory(fromBin);

  // Snapshot next to package: walk up from script looking for templates + pubspec
  var walk = Directory(p.dirname(script));
  for (var i = 0; i < 8; i++) {
    final t = p.join(walk.path, 'templates');
    final pub = p.join(walk.path, 'pubspec.yaml');
    if (File(pub).existsSync() &&
        File(pub).readAsStringSync().contains('name: podfly') &&
        Directory(t).existsSync()) {
      return Directory(t);
    }
    if (walk.parent.path == walk.path) break;
    walk = walk.parent;
  }

  // 2. Walk up from cwd looking for podfly package
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
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

  // 3. Pub global package_config
  try {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final candidates = <String>[
      p.join(p.dirname(script), '..', '.dart_tool', 'package_config.json'),
      if (home.isNotEmpty)
        p.join(home, '.pub-cache', 'global_packages', 'podfly', '.dart_tool',
            'package_config.json'),
    ];
    for (final path in candidates) {
      final configFile = File(p.normalize(path));
      if (!configFile.existsSync()) continue;
      final json =
          jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
      final packages = json['packages'];
      if (packages is! List) continue;
      for (final pkg in packages) {
        if (pkg is! Map) continue;
        if (pkg['name'] != 'podfly') continue;
        final rootUri = pkg['rootUri']?.toString();
        if (rootUri == null) continue;
        var root = rootUri;
        if (root.startsWith('file://')) {
          root = Uri.parse(root).toFilePath();
        } else if (!p.isAbsolute(root)) {
          root = p.normalize(p.join(p.dirname(configFile.path), root));
        }
        final t = p.join(root, 'templates');
        if (Directory(t).existsSync()) return Directory(t);
      }
    }
  } catch (_) {}

  return null;
}

String readTemplate(String name) {
  final dir = findTemplatesDir();
  if (dir == null) {
    throw StateError(
      'podfly templates/ not found (looked via package:podfly, script, cwd)',
    );
  }
  final f = File(p.join(dir.path, name));
  if (!f.existsSync()) throw StateError('Missing template: $name');
  return f.readAsStringSync();
}
