import 'package:podfly/src/config.dart';
import 'package:podfly/src/hosts/hosts.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(ensureHostsRegistered);

  test('registry has fly + railway as deployable', () {
    final fly = HostRegistry.require(AppHost.fly);
    final railway = HostRegistry.require(AppHost.railway);
    expect(fly.canDeploy, isTrue);
    expect(railway.canDeploy, isTrue);
    expect(fly.id, 'fly');
    expect(railway.id, 'railway');
  });

  test('aliases resolve to adapters', () {
    expect(HostRegistry.requireId('gcp').appHost, AppHost.cloudRun);
    expect(HostRegistry.requireId('do').appHost, AppHost.digitalOcean);
  });

  test('planned hosts cannot deploy', () {
    expect(HostRegistry.require(AppHost.render).canDeploy, isFalse);
  });

  test('AppHostX delegates to registry', () {
    expect(AppHost.fly.isImplemented, isTrue);
    expect(AppHost.render.isImplemented, isFalse);
    expect(AppHostX.parse('railway'), AppHost.railway);
    expect(AppHostX.parse('google'), AppHost.cloudRun);
  });

  test('all hosts listed once', () {
    final ids = HostRegistry.all.map((a) => a.id).toList();
    expect(ids, containsAll(['fly', 'railway', 'render', 'cloud_run']));
    expect(ids.toSet().length, ids.length);
  });
}
