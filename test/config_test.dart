import 'dart:io';

import 'package:podfly/src/config.dart';
import 'package:test/test.dart';

void main() {
  test('round-trip yaml', () async {
    final dir = await Directory.systemTemp.createTemp('podfly_test_');
    final cfg = PodflyConfig(
      root: dir.path,
      mode: DeployMode.split,
      name: 'demo',
      server: 'demo_server',
      flutter: 'demo_flutter',
      fly: FlyConfig(app: 'demo', region: 'iad'),
      cloudflare: CloudflareConfig(project: 'demo'),
      database: DatabaseConfig(provider: DatabaseProvider.none),
      web: WebConfig(apiUrl: 'https://demo.fly.dev'),
      smoke: SmokeConfig(
        api: SmokeEndpoint(method: 'POST', path: '/tarot/draw', body: '{}'),
      ),
    );
    await cfg.save();
    final loaded = await PodflyConfig.load(cfg.configPath);
    expect(loaded.name, 'demo');
    expect(loaded.mode, DeployMode.split);
    expect(loaded.web.apiUrlNormalized, 'https://demo.fly.dev/');
    expect(loaded.database.provider, DatabaseProvider.none);
    expect(loaded.smoke?.api?.path, '/tarot/draw');
    await dir.delete(recursive: true);
  });

  test('api_url trailing slash normalized', () {
    final w = WebConfig(apiUrl: 'https://x.fly.dev');
    expect(w.apiUrlNormalized, 'https://x.fly.dev/');
  });

  test('parse database providers', () {
    expect(DatabaseConfig.parseProvider('none'), DatabaseProvider.none);
    expect(DatabaseConfig.parseProvider('neon'), DatabaseProvider.neon);
    expect(
        DatabaseConfig.parseProvider('fly_postgres'), DatabaseProvider.flyPostgres);
    expect(
        DatabaseConfig.parseProvider('render_postgres'),
        DatabaseProvider.renderPostgres);
  });

  test('cloud_run host round-trip', () async {
    final dir = await Directory.systemTemp.createTemp('podfly_gcr_');
    final cfg = PodflyConfig(
      root: dir.path,
      host: AppHost.cloudRun,
      mode: DeployMode.monolith,
      name: 'demo',
      server: 'demo_server',
      flutter: 'demo_flutter',
      fly: FlyConfig(app: 'demo'),
      cloudRun: CloudRunConfig(
        service: 'demo-api',
        project: 'my-gcp-project',
        region: 'us-central1',
        minInstances: 0,
      ),
      database: DatabaseConfig(provider: DatabaseProvider.none),
      web: WebConfig(enabled: false, apiUrl: 'https://example.a.run.app/'),
    );
    await cfg.save();
    final loaded = await PodflyConfig.load(cfg.configPath);
    expect(loaded.host, AppHost.cloudRun);
    expect(loaded.cloudRun?.service, 'demo-api');
    expect(loaded.cloudRun?.project, 'my-gcp-project');
    expect(loaded.cloudRun?.region, 'us-central1');
    expect(loaded.cloudRun?.executionEnvironment, 'gen2');
    expect(loaded.toYaml(), contains('host: cloud_run'));
    expect(loaded.toYaml(), contains('execution_environment: gen2'));
    await dir.delete(recursive: true);
  });

  test('aws host round-trip', () async {
    final dir = await Directory.systemTemp.createTemp('podfly_aws_');
    final cfg = PodflyConfig(
      root: dir.path,
      host: AppHost.aws,
      mode: DeployMode.monolith,
      name: 'demo',
      server: 'demo_server',
      flutter: 'demo_flutter',
      fly: FlyConfig(app: 'demo'),
      aws: AwsConfig(
        service: 'podfly-aws-api',
        region: 'us-east-1',
        cpu: '1024',
        memory: '2048',
      ),
      database: DatabaseConfig(provider: DatabaseProvider.none),
      web: WebConfig(
        enabled: false,
        apiUrl: 'https://example.us-east-1.awsapprunner.com/',
      ),
    );
    await cfg.save();
    final loaded = await PodflyConfig.load(cfg.configPath);
    expect(loaded.host, AppHost.aws);
    expect(loaded.aws?.service, 'podfly-aws-api');
    expect(loaded.aws?.region, 'us-east-1');
    expect(loaded.aws?.cpu, '1024');
    expect(loaded.toYaml(), contains('host: aws'));
    await dir.delete(recursive: true);
  });

  test('render host round-trip', () async {
    final dir = await Directory.systemTemp.createTemp('podfly_render_');
    final cfg = PodflyConfig(
      root: dir.path,
      host: AppHost.render,
      mode: DeployMode.monolith,
      name: 'demo',
      server: 'demo_server',
      flutter: 'demo_flutter',
      fly: FlyConfig(app: 'demo'),
      render: RenderConfig(
        service: 'demo-api',
        repo: 'https://github.com/org/podfly_examples',
        rootDir: 'render/api_postgres',
      ),
      database: DatabaseConfig(
        provider: DatabaseProvider.renderPostgres,
        renderPostgres: RenderPostgresConfig(name: 'demo-db'),
      ),
      web: WebConfig(
        enabled: false,
        apiUrl: 'https://demo-api.onrender.com/',
      ),
    );
    await cfg.save();
    final loaded = await PodflyConfig.load(cfg.configPath);
    expect(loaded.host, AppHost.render);
    expect(loaded.render?.service, 'demo-api');
    expect(loaded.render?.rootDir, 'render/api_postgres');
    expect(loaded.database.provider, DatabaseProvider.renderPostgres);
    expect(loaded.database.renderPostgres?.name, 'demo-db');
    expect(loaded.toYaml(), contains('host: render'));
    await dir.delete(recursive: true);
  });

  test('parseDeployMode: monolith preferred, fly is legacy alias', () async {
    expect(parseDeployMode('split'), DeployMode.split);
    expect(parseDeployMode('monolith'), DeployMode.monolith);
    expect(parseDeployMode('fly'), DeployMode.monolith);
    expect(parseDeployMode('mono'), DeployMode.monolith);

    final dir = await Directory.systemTemp.createTemp('podfly_mode_');
    final f = File('${dir.path}/podfly.yaml');
    await f.writeAsString('''
host: fly
mode: fly
name: demo
server: s
flutter: f
fly:
  app: demo
database:
  provider: none
web:
  api_url: https://demo.fly.dev/
''');
    final loaded = await PodflyConfig.load(f.path);
    expect(loaded.mode, DeployMode.monolith);
    expect(loaded.toYaml(), contains('mode: monolith'));
    await dir.delete(recursive: true);
  });

  test('railway host round-trip', () async {
    final dir = await Directory.systemTemp.createTemp('podfly_railway_');
    final cfg = PodflyConfig(
      root: dir.path,
      host: AppHost.railway,
      mode: DeployMode.monolith,
      name: 'demo',
      server: 'demo_server',
      flutter: 'demo_flutter',
      fly: FlyConfig(app: 'demo'),
      railway: RailwayConfig(
        project: 'demo',
        service: 'api',
        publicHost: 'demo-production-xxxx.up.railway.app',
      ),
      database: DatabaseConfig(provider: DatabaseProvider.none),
      web: WebConfig(apiUrl: 'https://demo-production-xxxx.up.railway.app/'),
    );
    await cfg.save();
    final loaded = await PodflyConfig.load(cfg.configPath);
    expect(loaded.host, AppHost.railway);
    expect(loaded.railway?.project, 'demo');
    expect(loaded.railway?.service, 'api');
    expect(loaded.railway?.publicHost, 'demo-production-xxxx.up.railway.app');
    expect(AppHost.railway.isImplemented, isTrue);
    await dir.delete(recursive: true);
  });

  test('smoke body with quotes round-trips via double-quoted YAML', () async {
    final dir = await Directory.systemTemp.createTemp('podfly_body_');
    final cfg = PodflyConfig(
      root: dir.path,
      mode: DeployMode.split,
      name: 'demo',
      server: 's',
      flutter: 'f',
      fly: FlyConfig(app: 'demo'),
      cloudflare: CloudflareConfig(project: 'demo'),
      database: DatabaseConfig(provider: DatabaseProvider.none),
      web: WebConfig(apiUrl: 'https://demo.fly.dev/'),
      smoke: SmokeConfig(
        api: SmokeEndpoint(
          method: 'POST',
          path: '/x',
          body: "{'a':'b'}",
        ),
      ),
    );
    await cfg.save();
    final yaml = await File(cfg.configPath).readAsString();
    expect(yaml.contains("body: \"{'a':'b'}\""), isTrue);
    final loaded = await PodflyConfig.load(cfg.configPath);
    expect(loaded.smoke?.api?.body, "{'a':'b'}");
    await dir.delete(recursive: true);
  });
}
