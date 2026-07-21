import 'package:podfly/src/config.dart';
import 'package:podfly/src/hosts/hosts.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(ensureHostsRegistered);

  test('registry has fly + railway + digitalocean + render + cloud_run', () {
    final fly = HostRegistry.require(AppHost.fly);
    final railway = HostRegistry.require(AppHost.railway);
    final digitalOcean = HostRegistry.require(AppHost.digitalOcean);
    final render = HostRegistry.require(AppHost.render);
    final cloudRun = HostRegistry.require(AppHost.cloudRun);
    expect(fly.canDeploy, isTrue);
    expect(railway.canDeploy, isTrue);
    expect(digitalOcean.canDeploy, isTrue);
    expect(render.canDeploy, isTrue);
    expect(cloudRun.canDeploy, isTrue);
    expect(fly.id, 'fly');
    expect(railway.id, 'railway');
    expect(digitalOcean.id, 'digitalocean');
    expect(render.id, 'render');
    expect(cloudRun.id, 'cloud_run');
  });

  test('aliases resolve to adapters', () {
    expect(HostRegistry.requireId('gcp').appHost, AppHost.cloudRun);
    expect(HostRegistry.requireId('do').appHost, AppHost.digitalOcean);
  });

  test('aws still planned (cannot deploy)', () {
    expect(HostRegistry.require(AppHost.aws).canDeploy, isFalse);
  });

  test('AppHostX delegates to registry', () {
    expect(AppHost.fly.isImplemented, isTrue);
    expect(AppHost.digitalOcean.isImplemented, isTrue);
    expect(AppHost.render.isImplemented, isTrue);
    expect(AppHost.cloudRun.isImplemented, isTrue);
    expect(AppHost.aws.isImplemented, isFalse);
    expect(AppHostX.parse('railway'), AppHost.railway);
    expect(AppHostX.parse('google'), AppHost.cloudRun);
    expect(AppHostX.parse('digitalocean'), AppHost.digitalOcean);
    expect(AppHostX.parse('render'), AppHost.render);
    expect(AppHostX.parse('cloud_run'), AppHost.cloudRun);
  });

  test('all hosts listed once', () {
    final ids = HostRegistry.all.map((a) => a.id).toList();
    expect(
      ids,
      containsAll(['fly', 'railway', 'digitalocean', 'render', 'cloud_run']),
    );
    expect(ids.toSet().length, ids.length);
  });
}
