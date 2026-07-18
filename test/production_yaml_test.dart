import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:podfly/src/config.dart';
import 'package:podfly/src/database/production_yaml.dart';
import 'package:podfly/src/log.dart';
import 'package:test/test.dart';

void main() {
  test('removes database block for provider none', () async {
    final dir = await Directory.systemTemp.createTemp('podfly_yaml_');
    final server = Directory(p.join(dir.path, 's'))..createSync();
    final configDir = Directory(p.join(server.path, 'config'))..createSync();
    final f = File(p.join(configDir.path, 'production.yaml'));
    await f.writeAsString('''
apiServer:
  port: 8080

database:
  host: localhost
  port: 5432
  name: app
  user: postgres

sessionLogs:
  persistentEnabled: true
''');

    final cfg = PodflyConfig(
      root: dir.path,
      mode: DeployMode.split,
      name: 'app',
      server: 's',
      flutter: 'f',
      fly: FlyConfig(app: 'app'),
      database: DatabaseConfig(provider: DatabaseProvider.none),
      web: WebConfig(apiUrl: 'https://app.fly.dev/'),
    );

    await ProductionYamlPatcher(config: cfg, log: Log(quiet: true)).apply();
    final text = await f.readAsString();
    expect(text.contains('host: localhost'), isFalse);
    expect(text.contains('persistentEnabled: false'), isTrue);
    expect(text.contains('omitted by podfly'), isTrue);
    await dir.delete(recursive: true);
  });

  test('removes inline database flow mapping', () async {
    final dir = await Directory.systemTemp.createTemp('podfly_yaml_inline_');
    final server = Directory(p.join(dir.path, 's'))..createSync();
    final configDir = Directory(p.join(server.path, 'config'))..createSync();
    final f = File(p.join(configDir.path, 'production.yaml'));
    await f.writeAsString('''
apiServer:
  port: 8080

database: {host: localhost, port: 5432}

sessionLogs:
  persistentEnabled: true
''');

    final cfg = PodflyConfig(
      root: dir.path,
      mode: DeployMode.split,
      name: 'app',
      server: 's',
      flutter: 'f',
      fly: FlyConfig(app: 'app'),
      database: DatabaseConfig(provider: DatabaseProvider.none),
      web: WebConfig(apiUrl: 'https://app.fly.dev/'),
    );

    await ProductionYamlPatcher(config: cfg, log: Log(quiet: true)).apply();
    final text = await f.readAsString();
    expect(text.contains('host: localhost'), isFalse);
    expect(text.contains('omitted by podfly'), isTrue);
    await dir.delete(recursive: true);
  });

  test('removes bare database: key with no children', () async {
    final dir = await Directory.systemTemp.createTemp('podfly_yaml_bare_');
    final server = Directory(p.join(dir.path, 's'))..createSync();
    final configDir = Directory(p.join(server.path, 'config'))..createSync();
    final f = File(p.join(configDir.path, 'production.yaml'));
    await f.writeAsString('''
apiServer:
  port: 8080

database:

redis:
  enabled: false
''');

    final cfg = PodflyConfig(
      root: dir.path,
      mode: DeployMode.split,
      name: 'app',
      server: 's',
      flutter: 'f',
      fly: FlyConfig(app: 'app'),
      database: DatabaseConfig(provider: DatabaseProvider.none),
      web: WebConfig(apiUrl: 'https://app.fly.dev/'),
    );

    await ProductionYamlPatcher(config: cfg, log: Log(quiet: true)).apply();
    final text = await f.readAsString();
    expect(RegExp(r'^database:\s*$', multiLine: true).hasMatch(text), isFalse);
    expect(text.contains('omitted by podfly'), isTrue);
    await dir.delete(recursive: true);
  });
}
