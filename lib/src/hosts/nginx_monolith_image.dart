import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../log.dart';
import '../templates.dart';
import 'adapter.dart';

/// Shared nginx + Serverpod image for one-public-port monoliths
/// (Cloud Run, Fly.io, AWS, Azure, Hetzner, ECS, …).
///
/// - nginx listens on public port (8080 / `$PORT`)
/// - static Flutter from monorepo `build/web` → `/app/public`
/// - Serverpod API/WS on `127.0.0.1:8081`
///
/// **Do not** only copy Flutter into `*_server/web/app` for these hosts:
/// Serverpod serves UI on [webServer] (often 8082) while the platform
/// proxies a single port to [apiServer] — wrong port = timeout / blank UI.
class NginxMonolithImage {
  /// Marker line at top of generated root Dockerfile.
  static const dockerMarker = '# podfly:nginx_monolith';

  /// Legacy marker (Cloud Run only); still recognized.
  static const legacyCloudRunMarker = '# podfly:cloud_run_monolith';

  static bool isMonolithDockerfile(String text) =>
      text.contains(dockerMarker) || text.contains(legacyCloudRunMarker);

  /// True when this deploy should ship the nginx multi-process image.
  static bool wanted(PodflyConfig config, HostAdapter adapter) =>
      adapter.supportsAllInOneWeb &&
      config.mode == DeployMode.monolith &&
      config.web.enabled;

  /// Dockerfile path relative to monorepo root for [docker build -f].
  ///
  /// Monolith+web → root `Dockerfile` (nginx image). API-only → server package
  /// Dockerfile even if a stale root monolith Dockerfile remains from a prior deploy.
  static String relativeDockerfile(PodflyConfig config) {
    if (config.mode == DeployMode.monolith && config.web.enabled) {
      return 'Dockerfile';
    }
    return p.join(config.server, 'Dockerfile');
  }

  /// Write root Dockerfile + deploy/nginx + start.sh; patch production.yaml.
  static Future<void> ensure(DeployContext ctx) async {
    final cfg = ctx.config;
    final log = ctx.log;
    final root = cfg.root;

    final webIndex = File(p.join(root, 'build', 'web', 'index.html'));
    if (!ctx.runner.dryRun && !await webIndex.exists()) {
      throw StateError(
        'Monolith nginx image needs build/web (flutter build web). '
        'podfly should build web before deploy — check web.enabled: true',
      );
    }

    final deployDir = Directory(p.join(root, 'deploy'));
    final nginxPath =
        p.join(deployDir.path, 'nginx.cloud_run_monolith.conf');
    final startPath =
        p.join(deployDir.path, 'start.cloud_run_monolith.sh');
    final dockerPath = p.join(root, 'Dockerfile');

    if (ctx.runner.dryRun) {
      log.dry('write Dockerfile (nginx monolith) + deploy/nginx + start.sh');
      log.dry('patch ${cfg.server}/config/production.yaml apiServer.port → 8081');
      return;
    }

    await deployDir.create(recursive: true);
    await File(nginxPath).writeAsString(
      readTemplate('nginx.cloud_run_monolith.conf'),
    );
    await File(startPath).writeAsString(
      readTemplate('start.cloud_run_monolith.sh'),
    );
    await Process.run('chmod', ['+x', startPath]);

    var docker = readTemplate('Dockerfile.cloud_run_monolith');
    docker = '$dockerMarker\n$docker';
    docker = docker.replaceAll('{{SERVER_DIR}}', cfg.server);
    await File(dockerPath).writeAsString(docker);
    log.ok('wrote nginx monolith Dockerfile (Flutter static + Serverpod :8081)');

    await patchProductionYamlForNginxMonolith(cfg, log: log);
  }

  /// apiServer :8081; move insights off 8081; console logs on.
  static Future<void> patchProductionYamlForNginxMonolith(
    PodflyConfig config, {
    required Log log,
    int port = 8081,
  }) async {
    final f = File(p.join(config.serverPath, 'config', 'production.yaml'));
    if (!await f.exists()) {
      log.warn('no production.yaml — ensure apiServer.port: $port for monolith');
      return;
    }
    final original = await f.readAsString();
    final text = patchNginxMonolithProductionYaml(original, port: port);
    if (text != original) {
      await f.writeAsString(text);
      if (RegExp(r'insightsServer:[\s\S]*?port:\s*8083').hasMatch(text)) {
        log.ok(
          'production.yaml insightsServer.port → 8083 (avoid dual-bind with API)',
        );
      }
      log.ok(
        'production.yaml apiServer.port → $port (nginx proxies public PORT)',
      );
    } else {
      log.detail('production.yaml apiServer.port already $port (or unparsed)');
    }
  }
}

/// Rewrite Serverpod production.yaml for nginx monolith (public PORT → :8081 API).
///
/// Mini `serverpod create` templates put insightsServer on 8081 and api on 8080.
/// Only rewriting api→8081 dual-binds both and Serverpod dies on start.
/// Also enable console session logs so container platforms show crash output.
///
/// Exported as [patchCloudRunMonolithProductionYaml] for older tests/call sites.
String patchNginxMonolithProductionYaml(String text, {int port = 8081}) {
  final apiPortRe = RegExp(
    r'(apiServer:\s*\n(?:[ \t]+.+\n)*?[ \t]+port:\s*)(\d+)',
  );
  if (apiPortRe.hasMatch(text)) {
    text = text.replaceFirstMapped(
      apiPortRe,
      (m) => '${m.group(1)}$port',
    );
  } else if (text.contains('apiServer:')) {
    text = text.replaceFirst(
      'apiServer:',
      'apiServer:\n  port: $port',
    );
  }

  final insightsConflict = RegExp(
    r'(insightsServer:\s*\n(?:[ \t]+.+\n)*?[ \t]+port:\s*)(\d+)',
  );
  final insightsMatch = insightsConflict.firstMatch(text);
  if (insightsMatch != null && insightsMatch.group(2) == '$port') {
    text = text.replaceFirstMapped(
      insightsConflict,
      (m) => '${m.group(1)}8083',
    );
  }

  if (RegExp(r'consoleEnabled:\s*false').hasMatch(text)) {
    text = text.replaceFirst(
      RegExp(r'consoleEnabled:\s*false'),
      'consoleEnabled: true',
    );
  } else if (text.contains('sessionLogs:') &&
      !RegExp(r'consoleEnabled:\s*true').hasMatch(text)) {
    text = text.replaceFirst(
      'sessionLogs:',
      'sessionLogs:\n  consoleEnabled: true',
    );
  }

  return text;
}

/// Back-compat alias used by tests / older call sites.
String patchCloudRunMonolithProductionYaml(String text, {int port = 8081}) =>
    patchNginxMonolithProductionYaml(text, port: port);
