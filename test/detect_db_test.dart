import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:podfly/src/database/detect.dart';
import 'package:test/test.dart';

void main() {
  test('detects none when no tables and production omits database', () async {
    final dir = await Directory.systemTemp.createTemp('podfly_db_none_');
    final config = Directory(p.join(dir.path, 'config'))..createSync();
    File(p.join(config.path, 'production.yaml')).writeAsStringSync('''
apiServer:
  port: 8080
# database: omitted
sessionLogs:
  persistentEnabled: false
''');
    Directory(p.join(dir.path, 'lib')).createSync();
    File(p.join(dir.path, 'lib', 'card.spy.yaml')).writeAsStringSync('''
class: Card
fields:
  name: String
''');

    final d = await detectDatabaseNeed(dir.path);
    expect(d.need, DatabaseNeed.none);
    await dir.delete(recursive: true);
  });

  test('detects required when table: in spy model', () async {
    final dir = await Directory.systemTemp.createTemp('podfly_db_req_');
    Directory(p.join(dir.path, 'lib')).createSync(recursive: true);
    File(p.join(dir.path, 'lib', 'user.spy.yaml')).writeAsStringSync('''
class: User
table: user
fields:
  email: String
''');
    File(p.join(dir.path, 'lib', 'ep.dart')).writeAsStringSync('''
Future<void> save(Session session) async {
  await User.db.insertRow(session, user);
}
''');

    final d = await detectDatabaseNeed(dir.path);
    expect(d.need, DatabaseNeed.required);
    expect(d.appTableModels, isNotEmpty);
    await dir.delete(recursive: true);
  });

  test('template auth alone is warning, not required', () async {
    final dir = await Directory.systemTemp.createTemp('podfly_db_auth_soft_');
    File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('''
name: demo_server
dependencies:
  serverpod: 4.0.0
  serverpod_auth_idp_server: 4.0.0
''');
    Directory(p.join(dir.path, 'lib')).createSync();
    File(p.join(dir.path, 'lib', 'server.dart')).writeAsStringSync('''
import 'package:serverpod_auth_idp_server/core.dart';
void run() {
  pod.initializeAuthServices(
    tokenManagerBuilders: [],
    identityProviderBuilders: [],
  );
}
''');
    File(p.join(dir.path, 'lib', 'draw_endpoint.dart')).writeAsStringSync('''
class DrawEndpoint extends Endpoint {
  Future<int> deckSize(Session session) async => 78;
}
''');
    final config = Directory(p.join(dir.path, 'config'))..createSync();
    File(p.join(config.path, 'production.yaml')).writeAsStringSync('''
apiServer:
  port: 8080
# database: omitted
sessionLogs:
  persistentEnabled: false
''');
    final mig = Directory(p.join(dir.path, 'migrations', '20260101000000'))
      ..createSync(recursive: true);
    File(p.join(mig.path, 'definition.json')).writeAsStringSync(jsonEncode({
      'tables': [
        {
          'name': 'serverpod_auth_core_user',
          'module': 'serverpod_auth_core',
        },
        {
          'name': 'serverpod_log',
          'module': 'serverpod',
        },
      ],
    }));

    // Flutter sibling with unused sign_in
    final parent = dir.parent;
    final flutter = Directory(p.join(parent.path, 'demo_flutter'))
      ..createSync(recursive: true);
    Directory(p.join(flutter.path, 'web')).createSync();
    Directory(p.join(flutter.path, 'lib', 'screens')).createSync(recursive: true);
    File(p.join(flutter.path, 'pubspec.yaml')).writeAsStringSync('''
name: demo_flutter
dependencies:
  serverpod_auth_idp_flutter: 4.0.0
''');
    File(p.join(flutter.path, 'lib', 'main.dart')).writeAsStringSync('''
class TarotDrawApp extends StatelessWidget {
  Widget build(context) => MaterialApp(home: DrawScreen());
}
''');
    File(p.join(flutter.path, 'lib', 'screens', 'sign_in_screen.dart'))
        .writeAsStringSync('class SignInScreen {}');

    // Rename server dir so sibling guess works: parent/demo_server
    final serverDir = Directory(p.join(parent.path, 'demo_server'));
    await dir.rename(serverDir.path);

    final d = await detectDatabaseNeed(
      serverDir.path,
      flutterPath: flutter.path,
    );
    expect(d.authScaffolded, isTrue);
    expect(d.authActivelyUsed, isFalse);
    expect(d.need, DatabaseNeed.none);
    expect(d.warnings, isNotEmpty);

    await serverDir.delete(recursive: true);
    await flutter.delete(recursive: true);
  });

  test('requireLogin on app endpoint forces required', () async {
    final dir = await Directory.systemTemp.createTemp('podfly_db_auth_hard_');
    Directory(p.join(dir.path, 'lib')).createSync();
    File(p.join(dir.path, 'lib', 'secret_endpoint.dart')).writeAsStringSync('''
class SecretEndpoint extends Endpoint {
  @override
  bool get requireLogin => true;

  Future<String> secret(Session session) async => 'x';
}
''');
    File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('''
name: demo
dependencies:
  serverpod_auth_idp_server: 1.0.0
''');

    final d = await detectDatabaseNeed(dir.path);
    expect(d.need, DatabaseNeed.required);
    expect(d.authActivelyUsed, isTrue);
    await dir.delete(recursive: true);
  });
}
