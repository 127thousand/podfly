import 'dart:io';

import 'package:podfly/src/config.dart';
import 'package:podfly/src/destroy/destroy.dart';
import 'package:podfly/src/log.dart';
import 'package:podfly/src/process_runner.dart';
import 'package:test/test.dart';

void main() {
  test('destroy dry-run plans fly + cloudflare for split', () async {
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

  test('cloud_run monolith does not plan Cloudflare Pages destroy', () async {
    final dir = await Directory.systemTemp.createTemp('podfly_destroy_gcr_');
    final cfg = PodflyConfig(
      root: dir.path,
      host: AppHost.cloudRun,
      mode: DeployMode.monolith,
      name: 'hello_podfly',
      server: 'hello_podfly_server',
      flutter: 'hello_podfly_flutter',
      fly: FlyConfig(app: 'unused', region: 'iad'),
      cloudRun: CloudRunConfig(
        service: 'hello-podfly',
        region: 'us-central1',
      ),
      // Default webHost is cloudflare — must NOT destroy Pages for monolith.
      cloudflare: CloudflareConfig(project: 'hello-podfly'),
      database: DatabaseConfig(provider: DatabaseProvider.none),
      web: WebConfig(
        enabled: true,
        apiUrl: 'https://hello-podfly.a.run.app/',
      ),
    );
    final log = Log(quiet: true);
    final runner = ProcessRunner(log: log, dryRun: true);
    // Should not throw; only Cloud Run service in plan (no wrangler).
    await Destroyer(
      config: cfg,
      runner: runner,
      log: log,
      yes: true,
    ).run(doApi: true, doWeb: true, doDatabase: false);
    expect(cfg.usesStaticWebHost, isFalse);
    expect(cfg.mode, DeployMode.monolith);
    await dir.delete(recursive: true);
  });
}
