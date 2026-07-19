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
///
/// Flutter packages may be **mobile-only** (no `web/`); still discover them.
Future<DiscoveredProject> discover(String root) async {
  final abs = p.normalize(Directory(root).absolute.path);
  String? server;
  String? flutter;
  String? flutterWithWeb;
  String? client;

  await for (final ent in Directory(abs).list(followLinks: false)) {
    if (ent is! Directory) continue;
    final name = p.basename(ent.path);
    final pubspec = File(p.join(ent.path, 'pubspec.yaml'));
    if (!await pubspec.exists()) continue;
    final text = await pubspec.readAsString();
    final rel = p.relative(ent.path, from: abs);

    final isServerpodServer = text.contains('serverpod:') &&
        (name.endsWith('_server') ||
            await File(p.join(ent.path, 'Dockerfile')).exists() ||
            await Directory(p.join(ent.path, 'config')).exists());
    if (isServerpodServer) {
      server ??= rel;
    }

    final isFlutterPkg = name.endsWith('_flutter') ||
        (text.contains('flutter:') && text.contains('sdk: flutter'));
    if (isFlutterPkg) {
      final hasWeb = await Directory(p.join(ent.path, 'web')).exists();
      if (name.endsWith('_flutter')) {
        flutter ??= rel;
        if (hasWeb) flutterWithWeb ??= rel;
      } else if (flutter == null) {
        flutter = rel;
        if (hasWeb) flutterWithWeb ??= rel;
      }
    }

    if (name.endsWith('_client')) {
      client = rel;
    }
  }

  // Prefer a Flutter package that includes web/ when several exist.
  final chosenFlutter = flutterWithWeb ?? flutter;

  return DiscoveredProject(
    root: abs,
    server: server,
    flutter: chosenFlutter,
    client: client,
  );
}
