import 'package:podfly/src/config.dart';
import 'package:podfly/src/hosts/hosts.dart';
import 'package:podfly/src/hosts/nginx_monolith_image.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(ensureHostsRegistered);

  test('every supportsAllInOneWeb host uses nginx monolith when mode+web', () {
    final allInOne = HostRegistry.all.where((h) => h.supportsAllInOneWeb).toList();
    // Fly, Cloud Run, AWS App Runner, ECS, Azure, Hetzner
    expect(allInOne.map((h) => h.id).toSet(), containsAll([
      'fly',
      'cloud_run',
      'aws',
      'aws_ecs',
      'azure',
      'hetzner',
    ]));

    for (final adapter in allInOne) {
      final mono = _cfg(
        host: adapter.appHost,
        mode: DeployMode.monolith,
        webEnabled: true,
      );
      expect(
        NginxMonolithImage.wanted(mono, adapter),
        isTrue,
        reason: '${adapter.id} monolith+web should want nginx image',
      );
      expect(
        NginxMonolithImage.relativeDockerfile(mono),
        'Dockerfile',
        reason: '${adapter.id} should build root Dockerfile',
      );

      final apiOnly = _cfg(
        host: adapter.appHost,
        mode: DeployMode.monolith,
        webEnabled: false,
      );
      expect(
        NginxMonolithImage.wanted(apiOnly, adapter),
        isFalse,
        reason: '${adapter.id} API-only must not require nginx image',
      );
      expect(
        NginxMonolithImage.relativeDockerfile(apiOnly),
        'demo_server/Dockerfile',
        reason: '${adapter.id} API-only uses server Dockerfile',
      );
    }
  });

  test('native-web hosts do not use nginx monolith image', () {
    final native = HostRegistry.all.where((h) => h.deploysWebNatively).toList();
    expect(
      native.map((h) => h.id).toSet(),
      containsAll(['railway', 'digitalocean', 'render']),
    );
    for (final a in native) {
      expect(a.supportsAllInOneWeb, isFalse);
      final cfg = _cfg(
        host: a.appHost,
        mode: DeployMode.monolith,
        webEnabled: true,
      );
      expect(NginxMonolithImage.wanted(cfg, a), isFalse);
    }
  });
}

PodflyConfig _cfg({
  required AppHost host,
  required DeployMode mode,
  required bool webEnabled,
}) {
  return PodflyConfig(
    root: '/tmp/podfly_test',
    host: host,
    mode: mode,
    name: 'demo',
    server: 'demo_server',
    flutter: 'demo_flutter',
    fly: FlyConfig(app: 'demo'),
    database: DatabaseConfig(provider: DatabaseProvider.none),
    web: WebConfig(enabled: webEnabled, apiUrl: 'https://example.com/'),
  );
}
