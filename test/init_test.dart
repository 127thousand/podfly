import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:podfly/src/config.dart';
import 'package:podfly/src/init.dart';
import 'package:podfly/src/log.dart';
import 'package:test/test.dart';

void main() {
  test('Initer --yes writes parseable podfly.yaml', () async {
    final dir = await Directory.systemTemp.createTemp('podfly_init_');
    // Minimal server + flutter layout for discovery / detect
    final server = Directory(p.join(dir.path, 'demo_server'))..createSync();
    Directory(p.join(server.path, 'config')).createSync();
    File(p.join(server.path, 'config', 'production.yaml')).writeAsStringSync('''
apiServer:
  port: 8080
# database: omitted
sessionLogs:
  persistentEnabled: false
''');
    File(p.join(server.path, 'pubspec.yaml')).writeAsStringSync('''
name: demo_server
dependencies:
  serverpod: 4.0.0
''');
    final flutter = Directory(p.join(dir.path, 'demo_flutter'))..createSync();
    Directory(p.join(flutter.path, 'web')).createSync();
    File(p.join(flutter.path, 'pubspec.yaml')).writeAsStringSync('''
name: demo_flutter
dependencies:
  flutter:
    sdk: flutter
''');

    final cfg = await Initer(
      root: dir.path,
      log: Log(quiet: true),
      yes: true,
    ).run();

    expect(await File(cfg.configPath).exists(), isTrue);
    final loaded = await PodflyConfig.load(cfg.configPath);
    expect(loaded.mode, DeployMode.split);
    expect(loaded.server, 'demo_server');
    expect(loaded.flutter, 'demo_flutter');
    expect(loaded.database.provider, DatabaseProvider.none);
    expect(loaded.web.apiUrlNormalized, endsWith('/'));

    await dir.delete(recursive: true);
  });

  test('Initer respects custom configPath', () async {
    final dir = await Directory.systemTemp.createTemp('podfly_init_cfg_');
    Directory(p.join(dir.path, 'x_server', 'config')).createSync(recursive: true);
    File(p.join(dir.path, 'x_server', 'config', 'production.yaml'))
        .writeAsStringSync('apiServer:\n  port: 8080\n');
    File(p.join(dir.path, 'x_server', 'pubspec.yaml'))
        .writeAsStringSync('name: x_server\ndependencies:\n  serverpod: 1.0.0\n');
    Directory(p.join(dir.path, 'x_flutter', 'web')).createSync(recursive: true);
    File(p.join(dir.path, 'x_flutter', 'pubspec.yaml')).writeAsStringSync(
        'name: x_flutter\ndependencies:\n  flutter:\n    sdk: flutter\n');

    final custom = p.join(dir.path, 'custom', 'my-podfly.yaml');
    await Initer(
      root: dir.path,
      log: Log(quiet: true),
      yes: true,
      configPath: custom,
    ).run();

    expect(await File(custom).exists(), isTrue);
    final loaded = await PodflyConfig.load(custom);
    expect(loaded.name, p.basename(dir.path));

    await dir.delete(recursive: true);
  });
}