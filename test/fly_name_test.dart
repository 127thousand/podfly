import 'package:podfly/src/fly_name.dart';
import 'package:test/test.dart';

void main() {
  test('sanitizeFlyAppName', () {
    expect(sanitizeFlyAppName('mobile_api_only'), 'mobile-api-only');
    expect(sanitizeFlyAppName('MyApp'), 'myapp');
    expect(sanitizeFlyAppName('a--b'), 'a-b');
    expect(sanitizeFlyAppName('---'), 'app');
  });

  group('isFlyAppNameConflict', () {
    test('matches Fly validation message', () {
      expect(
        isFlyAppNameConflict(
          'Error: Validation failed: Name has already been taken '
          '(Request ID: 01KYFQADWY4PYX8R721EJ6SV5N-dfw)',
        ),
        isTrue,
      );
    });

    test('matches already exists phrasing', () {
      expect(
        isFlyAppNameConflict('name already exists for this organization'),
        isTrue,
      );
    });

    test('ignores unrelated failures', () {
      expect(
        isFlyAppNameConflict('Error: authentication required'),
        isFalse,
      );
      expect(isFlyAppNameConflict(''), isFalse);
    });
  });

  group('nextFlyAppNameCandidate', () {
    test('suffixes preferred name', () {
      final a = nextFlyAppNameCandidate('my-app', 1);
      final b = nextFlyAppNameCandidate('my-app', 2);
      expect(a, startsWith('my-app-'));
      expect(b, startsWith('my-app-'));
      expect(a, isNot(equals(b)));
      expect(a, matches(RegExp(r'^[a-z0-9-]+$')));
    });

    test('shortens long preferred names', () {
      final long = 'a' * 40;
      final c = nextFlyAppNameCandidate(long, 1);
      expect(c.length, lessThanOrEqualTo(30));
    });
  });
}
