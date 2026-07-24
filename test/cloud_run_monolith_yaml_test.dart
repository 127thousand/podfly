import 'package:podfly/src/hosts/cloud_run_host.dart';
import 'package:test/test.dart';

void main() {
  test('moves insights off 8081 when api is patched to 8081', () {
    const mini = '''
apiServer:
  port: 8080
  publicHost: api.examplepod.com
  publicPort: 443
  publicScheme: https

insightsServer:
  port: 8081
  publicHost: insights.examplepod.com
  publicPort: 443
  publicScheme: https

webServer:
  port: 8082
  publicHost: app.examplepod.com
  publicPort: 443
  publicScheme: https

sessionLogs:
  consoleEnabled: false
''';

    final out = patchCloudRunMonolithProductionYaml(mini, port: 8081);

    expect(out, contains(RegExp(r'apiServer:\s*\n(?:.+\n)*?[ \t]+port:\s*8081')));
    expect(out, contains(RegExp(r'insightsServer:\s*\n(?:.+\n)*?[ \t]+port:\s*8083')));
    expect(out, isNot(contains(RegExp(r'insightsServer:\s*\n(?:.+\n)*?[ \t]+port:\s*8081'))));
    expect(out, contains('consoleEnabled: true'));
  });

  test('leaves insights alone when already off the API port', () {
    const yaml = '''
apiServer:
  port: 8081

insightsServer:
  port: 8089

sessionLogs:
  consoleEnabled: true
''';
    final out = patchCloudRunMonolithProductionYaml(yaml, port: 8081);
    expect(out, contains('port: 8089'));
    expect(out, equals(yaml));
  });
}
