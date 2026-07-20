import 'package:podfly/src/database/postgres_url.dart';
import 'package:test/test.dart';

void main() {
  group('parsePostgresUrl', () {
    test('parses standard attach URL', () {
      final u = parsePostgresUrl(
        'postgres://podfly_ws_probe:oqKZyXURHrgeTKo@podfly-ws-probe-db.flycast:5432/podfly_ws_probe?sslmode=disable',
      );
      expect(u, isNotNull);
      expect(u!.user, 'podfly_ws_probe');
      expect(u.password, 'oqKZyXURHrgeTKo');
      expect(u.host, 'podfly-ws-probe-db.flycast');
      expect(u.port, '5432');
      expect(u.database, 'podfly_ws_probe');
      expect(u.requireSsl, isFalse);
    });

    test('parses url-encoded password', () {
      final u = parsePostgresUrl(
        'postgresql://user:p%40ss%2Fword@db.example:5432/mydb',
      );
      expect(u!.password, 'p@ss/word');
      expect(u.user, 'user');
      expect(u.database, 'mydb');
    });

    test('detects sslmode=require', () {
      final u = parsePostgresUrl(
        'postgres://u:p@h:5432/d?sslmode=require',
      );
      expect(u!.requireSsl, isTrue);
    });

    test('default port when omitted', () {
      final u = parsePostgresUrl('postgres://u:p@host/db');
      expect(u!.port, '5432');
      expect(u.host, 'host');
    });
  });

  group('parsePostgresUrlFromText', () {
    test('finds DATABASE_URL= line from fly attach', () {
      const out = '''
Postgres cluster podfly-ws-probe-db is now attached to podfly-ws-probe
The following secret was added to podfly-ws-probe:
  DATABASE_URL=postgres://podfly_ws_probe:secret@podfly-ws-probe-db.flycast:5432/podfly_ws_probe?sslmode=disable
''';
      final u = parsePostgresUrlFromText(out);
      expect(u, isNotNull);
      expect(u!.user, 'podfly_ws_probe');
      expect(u.password, 'secret');
      expect(u.host, 'podfly-ws-probe-db.flycast');
    });

    test('finds bare connection string in prose', () {
      final u = parsePostgresUrlFromText(
        'Connection string: postgres://postgres:Pw@cluster.internal:5432/postgres',
      );
      expect(u!.user, 'postgres');
      expect(u.password, 'Pw');
    });
  });
}
