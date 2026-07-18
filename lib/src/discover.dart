import 'dart:io';

import 'package:path/path.dart' as p;

class DiscoveredProject {
  DiscoveredProject({
    required this.root,
    this.server,
    this.flutter,
    this.client,
  });

  final String root;
  final String? server;
  final String? flutter;
  final String? client;

  bool get isComplete => server != null && flutter != null;
}

/// Find Serverpod monorepo packages under [root].
Future<DiscoveredProject> discover(String root) async {
  final abs = p.normalize(Directory(root).absolute.path);
  String? server;
  String? flutter;
  String? client;

  await for (final ent in Directory(abs).list(followLinks: false)) {
    if (ent is! Directory) continue;
    final name = p.basename(ent.path);
    final pubspec = File(p.join(ent.path, 'pubspec.yaml'));
    if (!await pubspec.exists()) continue;
    final text = await pubspec.readAsString();

    if (name.endsWith('_server') || text.contains('serverpod:')) {
      if (text.contains('serverpod:') &&
          (name.endsWith('_server') ||
              await File(p.join(ent.path, 'Dockerfile')).exists() ||
              await Directory(p.join(ent.path, 'config')).exists())) {
        server ??= p.relative(ent.path, from: abs);
      }
    }
    if (name.endsWith('_flutter') ||
        (text.contains('flutter:') &&
            text.contains('sdk: flutter') &&
            await Directory(p.join(ent.path, 'web')).exists())) {
      // Prefer *_flutter naming
      if (name.endsWith('_flutter') || flutter == null) {
        if (await Directory(p.join(ent.path, 'web')).exists()) {
          flutter = p.relative(ent.path, from: abs);
        }
      }
    }
    if (name.endsWith('_client')) {
      client = p.relative(ent.path, from: abs);
    }
  }

  // Workspace-style root pubspec
  final rootPub = File(p.join(abs, 'pubspec.yaml'));
  if (await rootPub.exists()) {
    final t = await rootPub.readAsString();
    if (t.contains('workspace:')) {
      // already scanned children
    }
  }

  return DiscoveredProject(
    root: abs,
    server: server,
    flutter: flutter,
    client: client,
  );
}
