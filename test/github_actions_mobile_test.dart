import 'dart:io';

import 'package:podfly/src/config.dart';
import 'package:podfly/src/log.dart';
import 'package:podfly/src/mobile/github_actions.dart';
import 'package:podfly/src/process_runner.dart';
import 'package:test/test.dart';

void main() {
  PodflyConfig cfg({
    bool android = true,
    bool ios = true,
  }) =>
      PodflyConfig(
        root: '/tmp/demo',
        mode: DeployMode.monolith,
        name: 'demo',
        server: 'demo_server',
        flutter: 'demo_flutter',
        fly: FlyConfig(app: 'demo', region: 'iad'),
        database: DatabaseConfig(provider: DatabaseProvider.none),
        mobile: MobileConfig(
          provider: MobileProvider.githubActions,
          githubActions: GithubActionsMobileConfig(
            ios: ios,
            android: android,
          ),
        ),
        web: WebConfig(
          enabled: false,
          apiUrl: 'https://demo.fly.dev/',
          serverUrlDefine: 'SERVER_URL',
        ),
      );

  test('android workflow has appbundle and SERVER_URL define', () {
    final y = GithubActionsMobileWriter.generateAndroidWorkflow(cfg());
    expect(y, contains('name: Mobile Android'));
    expect(y, contains('runs-on: ubuntu-latest'));
    expect(y, contains('flutter build appbundle'));
    expect(y, contains('--dart-define=SERVER_URL=https://demo.fly.dev'));
    expect(y, contains('working-directory: demo_flutter'));
    expect(y, contains('upload-artifact'));
    expect(y, contains('\${{ github.ref }}'));
  });

  test('ios workflow uses macos and no-codesign by default', () {
    final y = GithubActionsMobileWriter.generateIosWorkflow(cfg());
    expect(y, contains('name: Mobile iOS'));
    expect(y, contains('runs-on: macos-latest'));
    expect(y, contains('flutter build ios --release --no-codesign'));
    expect(y, contains('--dart-define=SERVER_URL=https://demo.fly.dev'));
    expect(y, contains('pod install'));
  });

  test('github_actions round-trip in podfly.yaml', () async {
    final dir = await Directory.systemTemp.createTemp('podfly_gha_');
    final c = PodflyConfig(
      root: dir.path,
      mode: DeployMode.monolith,
      name: 'm',
      server: 'm_server',
      flutter: 'm_flutter',
      fly: FlyConfig(app: 'm', region: 'iad'),
      database: DatabaseConfig(provider: DatabaseProvider.none),
      mobile: MobileConfig(
        provider: MobileProvider.githubActions,
        githubActions: GithubActionsMobileConfig(
          androidWorkflow: 'android.yml',
        ),
      ),
      web: WebConfig(enabled: false, apiUrl: 'https://m.fly.dev/'),
    );
    await c.save();
    final loaded = await PodflyConfig.load(c.configPath);
    expect(loaded.mobile.provider, MobileProvider.githubActions);
    expect(
      loaded.mobile.githubActionsOrDefault.androidWorkflow,
      'android.yml',
    );
    await dir.delete(recursive: true);
  });

  test('ensure writes missing workflows only once', () async {
    final dir = await Directory.systemTemp.createTemp('podfly_gha_w_');
    final log = Log(quiet: true);
    final runner = ProcessRunner(log: log);
    final c = PodflyConfig(
      root: dir.path,
      mode: DeployMode.monolith,
      name: 'm',
      server: 'm_server',
      flutter: 'm_flutter',
      fly: FlyConfig(app: 'm', region: 'iad'),
      database: DatabaseConfig(provider: DatabaseProvider.none),
      mobile: MobileConfig(
        provider: MobileProvider.githubActions,
        githubActions: GithubActionsMobileConfig(),
      ),
      web: WebConfig(enabled: false, apiUrl: 'https://m.fly.dev/'),
    );
    final w = GithubActionsMobileWriter(config: c, runner: runner, log: log);
    await w.ensure();
    final android =
        File('${dir.path}/.github/workflows/mobile-android.yml');
    final ios = File('${dir.path}/.github/workflows/mobile-ios.yml');
    expect(await android.exists(), isTrue);
    expect(await ios.exists(), isTrue);
    final first = await android.readAsString();
    await android.writeAsString('# hand\n$first');
    await w.ensure();
    expect(await android.readAsString(), startsWith('# hand'));
    await dir.delete(recursive: true);
  });
}
