import 'dart:io';

import 'package:podfly/src/config.dart';
import 'package:podfly/src/log.dart';
import 'package:podfly/src/mobile/codemagic.dart';
import 'package:podfly/src/process_runner.dart';
import 'package:test/test.dart';

void main() {
  test('generateYaml includes ios + android workflows and SERVER_URL', () {
    final cfg = PodflyConfig(
      root: '/tmp/demo',
      mode: DeployMode.monolith,
      name: 'demo',
      server: 'demo_server',
      flutter: 'demo_flutter',
      fly: FlyConfig(app: 'demo', region: 'iad'),
      database: DatabaseConfig(provider: DatabaseProvider.none),
      mobile: MobileConfig(
        provider: MobileProvider.codemagic,
        codemagic: CodemagicConfig(
          ios: true,
          android: true,
          bundleId: 'com.example.demo',
        ),
      ),
      web: WebConfig(
        enabled: false,
        apiUrl: 'https://demo.fly.dev/',
        serverUrlDefine: 'SERVER_URL',
      ),
    );

    final y = CodemagicYamlWriter.generateYaml(cfg);
    expect(y, contains('workflows:'));
    expect(y, contains('ios-ipa:'));
    expect(y, contains('android-appbundle:'));
    expect(y, contains('demo_flutter'));
    expect(y, contains('SERVER_URL: https://demo.fly.dev'));
    expect(y, contains('flutter build ipa'));
    expect(y, contains('flutter build appbundle'));
    expect(y, contains('BUNDLE_ID: com.example.demo'));
    // publish block stays commented until publish_testflight: true
    expect(y, contains('#     submit_to_testflight: true'));
    expect(
      y.split('\n').where((l) => l.trim() == 'submit_to_testflight: true'),
      isEmpty,
    );
  });

  test('publish_testflight adds publishing when integration set', () {
    final cfg = PodflyConfig(
      root: '/tmp/demo',
      mode: DeployMode.monolith,
      name: 'demo',
      server: 'demo_server',
      flutter: 'app_flutter',
      fly: FlyConfig(app: 'demo', region: 'iad'),
      database: DatabaseConfig(provider: DatabaseProvider.none),
      mobile: MobileConfig(
        provider: MobileProvider.codemagic,
        codemagic: CodemagicConfig(
          ios: true,
          android: false,
          publishTestflight: true,
          appStoreConnectIntegration: 'MyTeam',
        ),
      ),
      web: WebConfig(enabled: false, apiUrl: 'https://api.example.com'),
    );
    final y = CodemagicYamlWriter.generateYaml(cfg);
    expect(y, contains('app_store_connect: MyTeam'));
    expect(y, contains('submit_to_testflight: true'));
    expect(y, isNot(contains('android-appbundle:')));
  });

  test('mobile codemagic round-trip in podfly.yaml', () async {
    final dir = await Directory.systemTemp.createTemp('podfly_cm_');
    final cfg = PodflyConfig(
      root: dir.path,
      mode: DeployMode.monolith,
      name: 'm',
      server: 'm_server',
      flutter: 'm_flutter',
      fly: FlyConfig(app: 'm', region: 'iad'),
      database: DatabaseConfig(provider: DatabaseProvider.none),
      mobile: MobileConfig(
        provider: MobileProvider.codemagic,
        codemagic: CodemagicConfig(
          bundleId: 'com.m.app',
          publishTestflight: false,
        ),
      ),
      web: WebConfig(enabled: false, apiUrl: 'https://m.fly.dev/'),
    );
    await cfg.save();
    final loaded = await PodflyConfig.load(cfg.configPath);
    expect(loaded.mobile.provider, MobileProvider.codemagic);
    expect(loaded.mobile.codemagicOrDefault.bundleId, 'com.m.app');
    expect(loaded.mobile.codemagicOrDefault.ios, isTrue);
    await dir.delete(recursive: true);
  });

  test('ensure writes file once and leaves existing alone', () async {
    final dir = await Directory.systemTemp.createTemp('podfly_cm_w_');
    final log = Log(quiet: true);
    final runner = ProcessRunner(log: log);
    final cfg = PodflyConfig(
      root: dir.path,
      mode: DeployMode.monolith,
      name: 'm',
      server: 'm_server',
      flutter: 'm_flutter',
      fly: FlyConfig(app: 'm', region: 'iad'),
      database: DatabaseConfig(provider: DatabaseProvider.none),
      mobile: MobileConfig(
        provider: MobileProvider.codemagic,
        codemagic: CodemagicConfig(),
      ),
      web: WebConfig(enabled: false, apiUrl: 'https://m.fly.dev/'),
    );
    await CodemagicYamlWriter(config: cfg, runner: runner, log: log).ensure();
    final f = File('${dir.path}/codemagic.yaml');
    expect(await f.exists(), isTrue);
    final first = await f.readAsString();
    await f.writeAsString('# hand edited\n$first');
    await CodemagicYamlWriter(config: cfg, runner: runner, log: log).ensure();
    expect(await f.readAsString(), startsWith('# hand edited'));
    await dir.delete(recursive: true);
  });
}
