import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../log.dart';

/// Best-effort text patch of Serverpod production.yaml for database settings.
class ProductionYamlPatcher {
  ProductionYamlPatcher({required this.config, required this.log});

  final PodflyConfig config;
  final Log log;

  File get file =>
      File(p.join(config.serverPath, 'config', 'production.yaml'));

  Future<void> apply() async {
    final f = file;
    if (!await f.exists()) {
      log.warn('no ${p.relative(f.path, from: config.root)} — skip DB patch');
      return;
    }

    var text = await f.readAsString();
    final bak = File('${f.path}.podfly.bak');
    if (!await bak.exists()) {
      await bak.writeAsString(text);
      log.detail('backup → ${p.basename(bak.path)}');
    }

    switch (config.database.provider) {
      case DatabaseProvider.none:
        text = _removeDatabaseBlock(text);
        text = _setSessionLogsPersistent(text, false);
      case DatabaseProvider.sqlite:
        // Serverpod is historically Postgres-first; leave a clear comment block.
        log.warn(
            'sqlite: Serverpod may require Postgres — writing path comment only');
        text = _upsertComment(
          text,
          '# podfly: sqlite path ${config.database.sqlite?.path ?? '/data/serverpod.db'}\n'
          '# Ensure your Serverpod version supports sqlite before production use.\n',
        );
      case DatabaseProvider.flyPostgres:
        final app = config.database.flyPostgres?.app ?? '${config.name}-db';
        // Fly private DNS is typically <app>.internal — user may need attach output.
        text = _upsertDatabaseBlock(text, {
          'host': '$app.internal',
          'port': '5432',
          'name': config.name.replaceAll('-', '_'),
          'user': 'postgres',
          'requireSsl': 'false',
        });
      case DatabaseProvider.neon:
        final host = config.database.neon?.host ?? 'YOUR_NEON_HOST';
        final db = config.database.neon?.database ?? 'neondb';
        final user = config.database.neon?.user ?? 'neondb_owner';
        text = _upsertDatabaseBlock(text, {
          'host': host,
          'port': '5432',
          'name': db,
          'user': user,
          'requireSsl': 'true',
        });
        log.detail(
            'Neon: set Fly secret ${config.database.neon?.connectionStringSecret ?? 'DATABASE_URL'} '
            'and passwords.yaml production.database');
    }

    await f.writeAsString(text);
    log.ok('patched config/production.yaml (${config.database.provider.name})');
  }

  String _removeDatabaseBlock(String text) {
    final replacement =
        '# database: omitted by podfly (provider: none)\n';

    // Indented multi-line block
    final blockRe = RegExp(
      r'^database:\s*\n(?:[ \t]+.+\n)*',
      multiLine: true,
    );
    if (blockRe.hasMatch(text)) {
      return text.replaceFirst(blockRe, replacement);
    }

    // Inline / flow mapping: `database: {host: x}` or `database: {}`
    final inlineRe = RegExp(
      r'^database:\s*\{[^}]*\}\s*\n?',
      multiLine: true,
    );
    if (inlineRe.hasMatch(text)) {
      return text.replaceFirst(inlineRe, replacement);
    }

    // Bare key with no children: `database:` then next top-level key or EOF
    final bareRe = RegExp(
      r'^database:\s*(?:#.*)?\n(?=^\S|\Z)',
      multiLine: true,
    );
    if (bareRe.hasMatch(text)) {
      return text.replaceFirst(bareRe, replacement);
    }

    if (!text.contains('database:')) {
      return text;
    }
    // Last resort: comment out every line that starts a database key
    return text.replaceFirst(
      RegExp(r'^database:', multiLine: true),
      '# database: (podfly could not fully strip — review manually)',
    );
  }

  String _setSessionLogsPersistent(String text, bool enabled) {
    final re = RegExp(r'persistentEnabled:\s*(true|false)');
    if (re.hasMatch(text)) {
      return text.replaceFirst(re, 'persistentEnabled: $enabled');
    }
    return text;
  }

  String _upsertDatabaseBlock(String text, Map<String, String> fields) {
    final block = StringBuffer()
      ..writeln('database:')
      ..writeln('  host: ${fields['host']}')
      ..writeln('  port: ${fields['port']}')
      ..writeln('  name: ${fields['name']}')
      ..writeln('  user: ${fields['user']}')
      ..writeln('  requireSsl: ${fields['requireSsl']}');
    final re = RegExp(
      r'^database:\s*\n(?:[ \t]+.+\n)*',
      multiLine: true,
    );
    if (re.hasMatch(text)) {
      return text.replaceFirst(re, block.toString());
    }
    return '$text\n$block';
  }

  String _upsertComment(String text, String comment) {
    if (text.contains('podfly: sqlite')) return text;
    return '$comment$text';
  }
}
