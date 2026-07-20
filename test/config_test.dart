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
