import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:podfly/src/detect_surface.dart';
import 'package:test/test.dart';

void main() {
  test('mobile-only flutter (android+ios, no web) → apiOnly', () async {
    final root = await Directory.systemTemp.createTemp('podfly_mobile_');
    final server = Directory(p.join(root.path, 'app_server'))..createSync();
    File(p.join(server.path, 'lib', 'server.dart'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('void run() {}');

    final flutter = Directory(p.join(root.path, 'app_flutter'))..createSync();
    Directory(p.join(flutter.path, 'android')).createSync();
    Directory(p.join(flutter.path, 'ios')).createSync();
    Directory(p.join(flutter.path, 'lib')).createSync();
    File(p.join(flutter.path, 'pubspec.yaml')).writeAsStringSync('''
name: app_flutter
dependencies:
  flutter:
    sdk: flutter
''');

    final d = await detectClientSurface(
      serverPath: server.path,
      flutterPath: flutter.path,
    );
    expect(d.surface, ClientSurface.apiOnly);
    expect(d.deployWeb, isFalse);
    expect(d.hasAndroid, isTrue);
    expect(d.hasIos, isTrue);
    expect(d.hasWebDir, isFalse);

    await root.delete(recursive: true);
  });

  test('web product with podfly bootstrap → web', () async {
    final root = await Directory.systemTemp.createTemp('podfly_web_');
    final server = Directory(p.join(root.path, 'app_server'))..createSync();
    File(p.join(server.path, 'lib', 'server.dart'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('''
void run() {
  pod.webServer.addRoute(FlutterRoute(appDir), '/');
}
''');

    final flutter = Directory(p.join(root.path, 'app_flutter'))..createSync();
    final web = Directory(p.join(flutter.path, 'web'))..createSync();
    File(p.join(web.path, 'index.html')).writeAsStringSync(
      '<html><title>Sacred Draw</title></html>',
    );
    File(p.join(web.path, 'flutter_bootstrap.js')).writeAsStringSync('''
{{flutter_js}}
{{flutter_build_config}}
_flutter.loader.load({ config: { canvasKitBaseUrl: 'canvaskit/' } });
''');
    File(p.join(web.path, '_headers'))
        .writeAsStringSync('/canvaskit/*\n  Cache-Control: max-age=1\n');

    final d = await detectClientSurface(
      serverPath: server.path,
      flutterPath: flutter.path,
    );
    expect(d.surface, ClientSurface.web);
    expect(d.deployWeb, isTrue);

    await root.delete(recursive: true);
  });

  test('no flutter package → apiOnly', () async {
    final root = await Directory.systemTemp.createTemp('podfly_api_');
    final server = Directory(p.join(root.path, 'app_server'))..createSync();

    final d = await detectClientSurface(
      serverPath: server.path,
      flutterPath: p.join(root.path, 'missing_flutter'),
    );
    expect(d.surface, ClientSurface.apiOnly);

    await root.delete(recursive: true);
  });
}
