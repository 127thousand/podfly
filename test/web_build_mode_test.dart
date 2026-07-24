import 'dart:io';

import 'package:podfly/src/config.dart';
import 'package:podfly/src/web/build.dart';
import 'package:test/test.dart';

void main() {
  group('FlutterWebBuild', () {
    test('parse aliases', () {
      expect(FlutterWebBuildX.parse(null), FlutterWebBuild.canvaskit);
      expect(
        FlutterWebBuildX.parse('canvaskit_cdn'),
        FlutterWebBuild.canvaskitCdn,
      );
      expect(FlutterWebBuildX.parse('wasm'), FlutterWebBuild.wasm);
      expect(FlutterWebBuildX.parse('CDN'), FlutterWebBuild.canvaskitCdn);
    });

    test('canvaskit flags silence dry-run and disable CDN', () {
      final args = WebBuilder.flutterBuildArgs(
        WebConfig(
          apiUrl: 'https://example.com/',
          build: FlutterWebBuild.canvaskit,
        ),
      );
      expect(args, contains('--no-web-resources-cdn'));
      expect(args, contains('--no-wasm-dry-run'));
      expect(args, isNot(contains('--wasm')));
    });

    test('canvaskit_cdn enables CDN', () {
      final args = WebBuilder.flutterBuildArgs(
        WebConfig(
          apiUrl: 'https://example.com/',
          build: FlutterWebBuild.canvaskitCdn,
        ),
      );
      expect(args, contains('--web-resources-cdn'));
      expect(args, isNot(contains('--wasm')));
    });

    test('wasm adds --wasm', () {
      final args = WebBuilder.flutterBuildArgs(
        WebConfig(apiUrl: 'https://example.com/', build: FlutterWebBuild.wasm),
      );
      expect(args, contains('--wasm'));
      expect(args, contains('--dart-define=SERVER_URL=https://example.com/'));
    });
  });

  test('podfly.yaml round-trips web.build', () async {
    final dir = await Directory.systemTemp.createTemp('podfly_web_build_');
    final cfg = PodflyConfig(
      root: dir.path,
      mode: DeployMode.split,
      name: 'demo',
      server: 'demo_server',
      flutter: 'demo_flutter',
      fly: FlyConfig(app: 'demo', region: 'iad'),
      database: DatabaseConfig(provider: DatabaseProvider.none),
      web: WebConfig(
        apiUrl: 'https://demo.fly.dev/',
        build: FlutterWebBuild.canvaskitCdn,
      ),
    );
    await cfg.save();
    final loaded = await PodflyConfig.load(cfg.configPath);
    expect(loaded.web.build, FlutterWebBuild.canvaskitCdn);
    final text = await File(cfg.configPath).readAsString();
    expect(text, contains('build: canvaskit_cdn'));
    await dir.delete(recursive: true);
  });
}
