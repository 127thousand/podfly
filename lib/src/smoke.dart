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

    if (smoke.web != null) {
      final ep = smoke.web!;
      final base = _webBase();
      if (base != null) {
        final url = _join(base, ep.path);
        ok = await _hit(url, ep) && ok;
      } else {
        log.warn('smoke.web set but no web URL (cloudflare / railway.web_public_host)');
      }
    }

    return ok;
  }

  String? _webBase() {
    final rw = config.railway?.webPublicUrl;
    if (rw != null) return rw;
    final doWeb = config.digitalOcean?.webPublicHost;
    if (doWeb != null && doWeb.isNotEmpty) {
      return doWeb.startsWith('http')
          ? (doWeb.endsWith('/') ? doWeb : '$doWeb/')
          : 'https://$doWeb/';
    }
    if (config.mode == DeployMode.split && config.cloudflare != null) {
      return 'https://${config.cloudflare!.project}.pages.dev/';
    }
    if (config.mode == DeployMode.monolith) {
      return config.web.apiUrlNormalized;
    }
    return null;
  }

  String _join(String base, String path) {
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    if (path.isEmpty || path == '/') return '$b/';
    final p = path.startsWith('/') ? path : '/$path';
    return '$b$p';
  }

  Future<bool> _hit(String url, SmokeEndpoint ep) async {
    log.detail('${ep.method} $url');
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 90);
    try {
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
    } finally {
      client.close(force: true);
    }
  }
}
