import 'package:podfly/src/fly_name.dart';
import 'package:test/test.dart';

void main() {
  test('sanitizeFlyAppName', () {
    expect(sanitizeFlyAppName('mobile_api_only'), 'mobile-api-only');
    expect(sanitizeFlyAppName('MyApp'), 'myapp');
    expect(sanitizeFlyAppName('a--b'), 'a-b');
    expect(sanitizeFlyAppName('---'), 'app');
  });
}
