import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:podfly/src/discover.dart';
import 'package:test/test.dart';

void main() {
  test('discovers server and flutter packages', () async {
    final dir = await Directory.systemTemp.createTemp('podfly_disc_');
    final server = Directory(p.join(dir.path, 'app_server'))..createSync();
    File(p.join(server.path, 'pubspec.yaml')).writeAsStringSync('''
name: app_server
dependencies:
  serverpod: 4.0.0-beta.0
''');
    Directory(p.join(server.path, 'config')).createSync();

    final flutter = Directory(p.join(dir.path, 'app_flutter'))..createSync();
    File(p.join(flutter.path, 'pubspec.yaml')).writeAsStringSync('''
name: app_flutter
dependencies:
  flutter:
    sdk: flutter
''');
    Directory(p.join(flutter.path, 'web')).createSync();

    final d = await discover(dir.path);
    expect(d.server, 'app_server');
    expect(d.flutter, 'app_flutter');
    await dir.delete(recursive: true);
  });

  test('discovers mobile-only flutter without web/', () async {
    final dir = await Directory.systemTemp.createTemp('podfly_disc_m_');
    final server = Directory(p.join(dir.path, 'app_server'))..createSync();
    File(p.join(server.path, 'pubspec.yaml')).writeAsStringSync('''
name: app_server
dependencies:
  serverpod: 4.0.0-beta.0
''');
    Directory(p.join(server.path, 'config')).createSync();

    final flutter = Directory(p.join(dir.path, 'app_flutter'))..createSync();
    File(p.join(flutter.path, 'pubspec.yaml')).writeAsStringSync('''
name: app_flutter
dependencies:
  flutter:
    sdk: flutter
''');
    Directory(p.join(flutter.path, 'android')).createSync();
    Directory(p.join(flutter.path, 'ios')).createSync();
    // no web/

    final d = await discover(dir.path);
    expect(d.server, 'app_server');
    expect(d.flutter, 'app_flutter');
    expect(d.isComplete, isTrue);
    await dir.delete(recursive: true);
  });
}
