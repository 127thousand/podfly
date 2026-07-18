import 'dart:io';

import 'config.dart';
import 'log.dart';

class SmokeRunner {
  SmokeRunner({required this.config, required this.log});

  final PodflyConfig config;
  final Log log;

  Future<bool> run() async {
    log.step('Smoke checks');
    var ok = true;
    final smoke = config.smoke;
    if (smoke == null) {
      log.warn('no smoke: section in podfly.yaml');
      return true;
    }

    if (smoke.api != null) {
      final ep = smoke.api!;
      final url = _join(config.web.apiUrlNormalized, ep.path);
      ok = await _hit(url, ep) && ok;
    }

    if (smoke.web != null && config.mode == DeployMode.split) {
      final ep = smoke.web!;
      final base = 'https://${config.cloudflare!.project}.pages.dev/';
      final url = _join(base, ep.path);
      ok = await _hit(url, ep) && ok;
    } else if (smoke.web != null && config.mode == DeployMode.fly) {
      final ep = smoke.web!;
      final url = _join(config.web.apiUrlNormalized, ep.path);
      ok = await _hit(url, ep) && ok;
    }

    return ok;
  }

  String _join(String base, String path) {
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    if (path.isEmpty || path == '/') return '$b/';
    final p = path.startsWith('/') ? path : '/$path';
    return '$b$p';
  }

  Future<bool> _hit(String url, SmokeEndpoint ep) async {
    log.detail('${ep.method} $url');
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 90);
      final uri = Uri.parse(url);
      final req = await (ep.method.toUpperCase() == 'POST'
          ? client.postUrl(uri)
          : client.getUrl(uri));
      if (ep.method.toUpperCase() == 'POST') {
        req.headers.contentType = ContentType.json;
        req.write(ep.body ?? '{}');
      }
      final res = await req.close().timeout(const Duration(seconds: 90));
      await res.drain<void>();
      final code = res.statusCode;
      if (code == ep.expectStatus) {
        log.ok('$url → $code');
        return true;
      }
      log.err('$url → $code (expected ${ep.expectStatus})');
      return false;
    } catch (e) {
      log.err('$url failed: $e');
      return false;
    }
  }
}
