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
}
