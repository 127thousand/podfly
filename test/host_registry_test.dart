import 'package:podfly/src/config.dart';
import 'package:podfly/src/hosts/hosts.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(ensureHostsRegistered);

  test('registry has all deployable hosts', () {
    final fly = HostRegistry.require(AppHost.fly);
    final railway = HostRegistry.require(AppHost.railway);
    final digitalOcean = HostRegistry.require(AppHost.digitalOcean);
    final render = HostRegistry.require(AppHost.render);
    final cloudRun = HostRegistry.require(AppHost.cloudRun);
    final aws = HostRegistry.require(AppHost.aws);
    final awsEcs = HostRegistry.require(AppHost.awsEcs);
    final azure = HostRegistry.require(AppHost.azure);
    final hetzner = HostRegistry.require(AppHost.hetzner);
    expect(fly.canDeploy, isTrue);
    expect(railway.canDeploy, isTrue);
    expect(digitalOcean.canDeploy, isTrue);
    expect(render.canDeploy, isTrue);
    expect(cloudRun.canDeploy, isTrue);
    expect(aws.canDeploy, isTrue);
    expect(awsEcs.canDeploy, isTrue);
    expect(azure.canDeploy, isTrue);
    expect(hetzner.canDeploy, isTrue);
    expect(hetzner.id, 'hetzner');
  });

  test('aliases resolve to adapters', () {
    expect(HostRegistry.requireId('gcp').appHost, AppHost.cloudRun);
    expect(HostRegistry.requireId('do').appHost, AppHost.digitalOcean);
    expect(HostRegistry.requireId('apprunner').appHost, AppHost.aws);
    expect(HostRegistry.requireId('ecs').appHost, AppHost.awsEcs);
    expect(HostRegistry.requireId('fargate').appHost, AppHost.awsEcs);
    expect(HostRegistry.requireId('aca').appHost, AppHost.azure);
    expect(HostRegistry.requireId('hcloud').appHost, AppHost.hetzner);
  });

  test('azure + hetzner can deploy', () {
    expect(HostRegistry.require(AppHost.azure).canDeploy, isTrue);
    expect(HostRegistry.require(AppHost.hetzner).canDeploy, isTrue);
  });

  test('AppHostX delegates to registry', () {
    expect(AppHost.fly.isImplemented, isTrue);
    expect(AppHost.digitalOcean.isImplemented, isTrue);
    expect(AppHost.render.isImplemented, isTrue);
    expect(AppHost.cloudRun.isImplemented, isTrue);
    expect(AppHost.aws.isImplemented, isTrue);
    expect(AppHost.awsEcs.isImplemented, isTrue);
    expect(AppHost.azure.isImplemented, isTrue);
    expect(AppHost.hetzner.isImplemented, isTrue);
    expect(AppHostX.parse('railway'), AppHost.railway);
    expect(AppHostX.parse('google'), AppHost.cloudRun);
    expect(AppHostX.parse('digitalocean'), AppHost.digitalOcean);
    expect(AppHostX.parse('render'), AppHost.render);
    expect(AppHostX.parse('cloud_run'), AppHost.cloudRun);
    expect(AppHostX.parse('aws'), AppHost.aws);
    expect(AppHostX.parse('aws_ecs'), AppHost.awsEcs);
    expect(AppHostX.parse('azure'), AppHost.azure);
    expect(AppHostX.parse('aca'), AppHost.azure);
    expect(AppHostX.parse('hetzner'), AppHost.hetzner);
    expect(AppHostX.parse('hcloud'), AppHost.hetzner);
  });

  test('all hosts listed once', () {
    final ids = HostRegistry.all.map((a) => a.id).toList();
    expect(
      ids,
      containsAll(
        [
          'fly',
          'railway',
          'digitalocean',
          'render',
          'cloud_run',
          'aws',
          'aws_ecs',
          'azure',
          'hetzner',
        ],
      ),
    );
    expect(ids.toSet().length, ids.length);
  });
}
