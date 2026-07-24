import 'dart:io';

import 'package:podfly/src/config.dart';
import 'package:podfly/src/destroy/destroy.dart';
import 'package:podfly/src/log.dart';
import 'package:podfly/src/process_runner.dart';
import 'package:test/test.dart';

void main() {
  test('destroy dry-run plans fly + cloudflare without error', () async {
    final dir = await Directory.systemTemp.createTemp('podfly_destroy_');
    final cfg = PodflyConfig(
      root: dir.path,
      mode: DeployMode.split,
      name: 'demo',
      server: 'demo_server',
      flutter: 'demo_flutter',
      fly: FlyConfig(app: 'demo-app', region: 'iad'),
      cloudflare: CloudflareConfig(project: 'demo-app'),
      database: DatabaseConfig(provider: DatabaseProvider.none),
      web: WebConfig(enabled: true, apiUrl: 'https://demo-app.fly.dev/'),
    );
    await cfg.save();
    final log = Log(quiet: true);
    final runner = ProcessRunner(log: log, dryRun: true);
    await Destroyer(
      config: cfg,
      runner: runner,
      log: log,
      yes: true,
    ).run(doApi: true, doWeb: true, doDatabase: false);
    await dir.delete(recursive: true);
  });
}
