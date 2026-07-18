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

  test('detects required when auth IDP is initialized', () async {
    final dir = await Directory.systemTemp.createTemp('podfly_db_auth_');
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
    final mig = Directory(
        p.join(dir.path, 'migrations', '20260101000000'))
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

    final d = await detectDatabaseNeed(dir.path);
    expect(d.need, DatabaseNeed.required);
    expect(d.authRequiresDatabase, isTrue);
    await dir.delete(recursive: true);
  });
}

