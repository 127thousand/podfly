import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../log.dart';
import '../process_runner.dart';

/// Patch Serverpod config publicHost / publicScheme / publicPort.
///
/// Defaults to HTTPS edge (443). Pass [scheme] / [publicPort] for plain HTTP
/// VPS demos (e.g. Hetzner `http` + host port 8080).
Future<void> patchProductionPublicHosts({
  required PodflyConfig config,
  required ProcessRunner runner,
  required Log log,
  required String host,
  String scheme = 'https',
  int? publicPort,
}) async {
  final bare =
      host.replaceFirst(RegExp(r'^https?://'), '').split('/').first;
  final port = publicPort ?? (scheme == 'https' ? 443 : 80);

  final candidates = [
    File(p.join(config.serverPath, 'config', 'production.yaml')),
    File(p.join(config.serverPath, 'config', 'development.yaml')),
  ];

  for (final f in candidates) {
    if (!await f.exists()) continue;
    var text = await f.readAsString();
    final original = text;

    text = text.replaceAllMapped(
      RegExp(
        r'(apiServer:[\s\S]*?publicHost:\s*)(\S+)',
        multiLine: true,
      ),
      (m) {
        final current = m.group(2)!;
        if (current.contains('localhost') ||
            current.contains('example') ||
            current.contains('REPLACE') ||
            current.contains('fly.dev') ||
            current.contains('railway.app') ||
            current.contains('placeholder') ||
            current == '""' ||
            current == "''") {
          return '${m.group(1)}$bare';
        }
        // Always refresh when explicitly redeploying to a known host.
        if (scheme == 'http') {
          return '${m.group(1)}$bare';
        }
        return m.group(0)!;
      },
    );
    text = text.replaceAllMapped(
      RegExp(
        r'(apiServer:[\s\S]*?publicScheme:\s*)(\S+)',
        multiLine: true,
      ),
      (m) {
        if (scheme == 'https') {
          final current = m.group(2)!;
          if (current.contains('http') && !current.contains('https')) {
            return '${m.group(1)}https';
          }
          return m.group(0)!;
        }
        return '${m.group(1)}$scheme';
      },
    );
    text = text.replaceAllMapped(
      RegExp(
        r'(apiServer:[\s\S]*?publicPort:\s*)(\d+)',
        multiLine: true,
      ),
      (m) {
        if (scheme == 'https') {
          final p0 = m.group(2)!;
          if (p0 == '8080' || p0 == '80') {
            return '${m.group(1)}443';
          }
          return m.group(0)!;
        }
        return '${m.group(1)}$port';
      },
    );

    if (text != original) {
      if (runner.dryRun) {
        log.dry(
            'patch ${p.relative(f.path, from: config.root)} publicHost → $bare '
            '($scheme:$port)');
      } else {
        final bak = File('${f.path}.podfly.bak');
        if (!await bak.exists()) await bak.writeAsString(original);
        await f.writeAsString(text);
        log.ok(
            'patched ${p.relative(f.path, from: config.root)} publicHost → $bare '
            '($scheme:$port)');
      }
    }
  }
}
