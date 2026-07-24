import 'package:podfly/src/mobile/api_url_sync.dart';
import 'package:test/test.dart';

void main() {
  test('syncs YAML SERVER_URL and adds marker', () {
    const before = '''
        env:
          SERVER_URL: https://old.fly.dev
          OTHER: keep
''';
    final r = MobileApiUrlSync.apply(
      before,
      defineName: 'SERVER_URL',
      apiUrl: 'https://new.fly.dev/',
    );
    expect(r.changed, isTrue);
    expect(r.replacements, 1);
    expect(
      r.text,
      contains('SERVER_URL: https://new.fly.dev  # podfly:api_url'),
    );
    expect(r.text, contains('OTHER: keep'));
  });

  test('syncs multiple YAML sites (codemagic ios+android)', () {
    const before = '''
        SERVER_URL: https://a.example.com
        SERVER_URL: https://a.example.com
''';
    final r = MobileApiUrlSync.apply(
      before,
      defineName: 'SERVER_URL',
      apiUrl: 'https://b.example.com',
    );
    expect(r.replacements, 2);
    expect(
      'SERVER_URL: https://b.example.com  # podfly:api_url'
          .allMatches(r.text)
          .length,
      2,
    );
  });

  test('syncs --dart-define=SERVER_URL=', () {
    const before = r'''
          flutter build appbundle --release \
            --dart-define=SERVER_URL=https://old.fly.dev
''';
    final r = MobileApiUrlSync.apply(
      before,
      defineName: 'SERVER_URL',
      apiUrl: 'https://new.fly.dev/',
    );
    expect(r.changed, isTrue);
    expect(r.text, contains('--dart-define=SERVER_URL=https://new.fly.dev'));
    expect(r.text, isNot(contains('old.fly.dev')));
  });

  test('no-op when already current', () {
    const body = '''
          SERVER_URL: https://same.fly.dev  # podfly:api_url
''';
    final r = MobileApiUrlSync.apply(
      body,
      defineName: 'SERVER_URL',
      apiUrl: 'https://same.fly.dev/',
    );
    expect(r.changed, isFalse);
  });

  test('custom define name', () {
    const before = '        API_BASE: https://old.dev\n';
    final r = MobileApiUrlSync.apply(
      before,
      defineName: 'API_BASE',
      apiUrl: 'https://new.dev',
    );
    expect(r.text, contains('API_BASE: https://new.dev  # podfly:api_url'));
  });
}
