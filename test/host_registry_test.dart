import 'package:podfly/src/config.dart';
import 'package:podfly/src/hosts/hosts.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(ensureHostsRegistered);

  test('registry has fly + railway + do + render + cloud_run + aws + ecs + azure',
      () {
    final fly = HostRegistry.require(AppHost.fly);
    final railway = HostRegistry.require(AppHost.railway);
    final digitalOcean = HostRegistry.require(AppHost.digitalOcean);
    final render = HostRegistry.require(AppHost.render);
    final cloudRun = HostRegistry.require(AppHost.cloudRun);
    final aws = HostRegistry.require(AppHost.aws);
    final awsEcs = HostRegistry.require(AppHost.awsEcs);
    final azure = HostRegistry.require(AppHost.azure);
    expect(fly.canDeploy, isTrue);
    expect(railway.canDeploy, isTrue);
    expect(digitalOcean.canDeploy, isTrue);
    expect(render.canDeploy, isTrue);
    expect(cloudRun.canDeploy, isTrue);
    expect(aws.canDeploy, isTrue);
    expect(awsEcs.canDeploy, isTrue);
    expect(azure.canDeploy, isTrue);
    expect(fly.id, 'fly');
    expect(railway.id, 'railway');
    expect(digitalOcean.id, 'digitalocean');
    expect(render.id, 'render');
    expect(cloudRun.id, 'cloud_run');
    expect(aws.id, 'aws');
    expect(awsEcs.id, 'aws_ecs');
    expect(azure.id, 'azure');
  });

  test('aliases resolve to adapters', () {
    expect(HostRegistry.requireId('gcp').appHost, AppHost.cloudRun);
    expect(HostRegistry.requireId('do').appHost, AppHost.digitalOcean);
    expect(HostRegistry.requireId('apprunner').appHost, AppHost.aws);
    expect(HostRegistry.requireId('ecs').appHost, AppHost.awsEcs);
    expect(HostRegistry.requireId('fargate').appHost, AppHost.awsEcs);
    expect(HostRegistry.requireId('aca').appHost, AppHost.azure);
  });

  test('azure can deploy', () {
    expect(HostRegistry.require(AppHost.azure).canDeploy, isTrue);
    expect(HostRegistry.requireId('aca').appHost, AppHost.azure);
  });

  test('AppHostX delegates to registry', () {
    expect(AppHost.fly.isImplemented, isTrue);
    expect(AppHost.digitalOcean.isImplemented, isTrue);
    expect(AppHost.render.isImplemented, isTrue);
    expect(AppHost.cloudRun.isImplemented, isTrue);
    expect(AppHost.aws.isImplemented, isTrue);
    expect(AppHost.awsEcs.isImplemented, isTrue);
    expect(AppHost.azure.isImplemented, isTrue);
    expect(AppHostX.parse('railway'), AppHost.railway);
    expect(AppHostX.parse('google'), AppHost.cloudRun);
    expect(AppHostX.parse('digitalocean'), AppHost.digitalOcean);
    expect(AppHostX.parse('render'), AppHost.render);
    expect(AppHostX.parse('cloud_run'), AppHost.cloudRun);
    expect(AppHostX.parse('aws'), AppHost.aws);
    expect(AppHostX.parse('aws_ecs'), AppHost.awsEcs);
    expect(AppHostX.parse('azure'), AppHost.azure);
    expect(AppHostX.parse('aca'), AppHost.azure);
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
        ],
      ),
    );
    expect(ids.toSet().length, ids.length);
  });
}
