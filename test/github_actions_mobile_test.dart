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
    bool fastlane = true,
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
            fastlane: fastlane,
            bundleId: 'com.example.demo',
          ),
        ),
        web: WebConfig(
          enabled: false,
          apiUrl: 'https://demo.fly.dev/',
          serverUrlDefine: 'SERVER_URL',
        ),
      );

  test('compile-only android workflow when fastlane false', () {
    final y = GithubActionsMobileWriter.generateAndroidWorkflow(
      cfg(fastlane: false),
    );
    expect(y, contains('name: Mobile Android'));
    expect(y, contains('runs-on: ubuntu-latest'));
    expect(y, contains('flutter build appbundle'));
    expect(y, contains('--dart-define=SERVER_URL=https://demo.fly.dev'));
    expect(y, isNot(contains('fastlane android')));
  });

  test('fastlane android workflow calls bundle exec fastlane', () {
    final y = GithubActionsMobileWriter.generateAndroidWorkflow(cfg());
    expect(y, contains('ruby/setup-ruby'));
    expect(y, contains('bundle exec fastlane android'));
    expect(y, contains('SERVER_URL: https://demo.fly.dev'));
    expect(y, contains('options: [internal, build]'));
  });

  test('fastlane ios workflow and Fastfile lanes', () {
    final y = GithubActionsMobileWriter.generateIosWorkflow(cfg());
    expect(y, contains('runs-on: macos-latest'));
    expect(y, contains('bundle exec fastlane ios'));
    expect(y, contains('MATCH_PASSWORD'));
    expect(y, contains('options: [beta, build]'));

    final ff = GithubActionsMobileWriter.generateFastfile(cfg());
    expect(ff, contains('lane :beta'));
    expect(ff, contains('lane :build'));
    expect(ff, contains('lane :internal'));
    expect(ff, contains('--dart-define=SERVER_URL='));
    expect(ff, contains('upload_to_testflight'));
    expect(ff, contains('upload_to_play_store'));
  });

  test('github_actions round-trip includes fastlane flag', () async {
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
          fastlane: true,
          bundleId: 'com.m.app',
        ),
      ),
      web: WebConfig(enabled: false, apiUrl: 'https://m.fly.dev/'),
    );
    await c.save();
    final loaded = await PodflyConfig.load(c.configPath);
    expect(loaded.mobile.provider, MobileProvider.githubActions);
    expect(loaded.mobile.githubActionsOrDefault.fastlane, isTrue);
    expect(loaded.mobile.githubActionsOrDefault.bundleId, 'com.m.app');
    await dir.delete(recursive: true);
  });

  test('ensure writes workflows + Fastlane files once', () async {
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
        githubActions: GithubActionsMobileConfig(fastlane: true),
      ),
      web: WebConfig(enabled: false, apiUrl: 'https://m.fly.dev/'),
    );
    final w = GithubActionsMobileWriter(config: c, runner: runner, log: log);
    await w.ensure();
    expect(
      await File('${dir.path}/.github/workflows/mobile-android.yml').exists(),
      isTrue,
    );
    expect(
      await File('${dir.path}/.github/workflows/mobile-ios.yml').exists(),
      isTrue,
    );
    expect(await File('${dir.path}/m_flutter/Gemfile').exists(), isTrue);
    expect(
      await File('${dir.path}/m_flutter/fastlane/Fastfile').exists(),
      isTrue,
    );
    expect(
      await File('${dir.path}/m_flutter/fastlane/Appfile').exists(),
      isTrue,
    );
    final ff = File('${dir.path}/m_flutter/fastlane/Fastfile');
    await ff.writeAsString('# hand\n${await ff.readAsString()}');
    await w.ensure();
    expect(await ff.readAsString(), startsWith('# hand'));
    await dir.delete(recursive: true);
  });

  test('ensure syncs SERVER_URL in existing workflow without full rewrite',
      () async {
    final dir = await Directory.systemTemp.createTemp('podfly_gha_sync_');
    final log = Log(quiet: true);
    final runner = ProcessRunner(log: log);
    final wfDir = Directory('${dir.path}/.github/workflows')
      ..createSync(recursive: true);
    final android = File('${wfDir.path}/mobile-android.yml');
    await android.writeAsString('''
# hand-tuned header — must survive
name: Mobile Android
jobs:
  fastlane:
    steps:
      - name: Fastlane
        env:
          SERVER_URL: https://old.example.com
          KEEP_ME: yes
        run: bundle exec fastlane android build
''');
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
          fastlane: true,
          ios: false,
        ),
      ),
      web: WebConfig(enabled: false, apiUrl: 'https://new.example.com/'),
    );
    await GithubActionsMobileWriter(config: c, runner: runner, log: log)
        .ensure();
    final text = await android.readAsString();
    expect(text, startsWith('# hand-tuned header'));
    expect(text, contains('KEEP_ME: yes'));
    expect(
      text,
      contains('SERVER_URL: https://new.example.com  # podfly:api_url'),
    );
    expect(text, isNot(contains('old.example.com')));
    await dir.delete(recursive: true);
  });
}
