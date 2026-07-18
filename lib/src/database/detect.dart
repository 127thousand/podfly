import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Heuristic: does this Serverpod server look like it needs a database?
enum DatabaseNeed {
  /// No app tables, no session.db usage, production often omits database.
  none,

  /// Clear signals: table: in models, app migrations, or session.db in code.
  required,

  /// Ambiguous (e.g. only framework migration tables) — ask the user.
  unknown,
}

class DatabaseDetection {
  DatabaseDetection({
    required this.need,
    required this.reasons,
    this.appTableModels = const [],
    this.appMigrationTables = const [],
  });

  final DatabaseNeed need;
  final List<String> reasons;
  final List<String> appTableModels;
  final List<String> appMigrationTables;
}

/// Inspect a Serverpod `*_server` package for database usage signals.
Future<DatabaseDetection> detectDatabaseNeed(String serverPath) async {
  final reasons = <String>[];
  final tableModels = <String>[];
  final migrationTables = <String>[];
  var scoreRequired = 0;
  var scoreNone = 0;

  final server = Directory(serverPath);
  if (!await server.exists()) {
    return DatabaseDetection(
      need: DatabaseNeed.unknown,
      reasons: ['server path not found'],
    );
  }

  // 1. .spy.yaml / models with active `table:` key
  await for (final ent in server.list(recursive: true, followLinks: false)) {
    if (ent is! File) continue;
    final name = p.basename(ent.path);
    if (!(name.endsWith('.spy.yaml') || name.endsWith('.spy.yml'))) continue;
    if (ent.path.contains('${p.separator}generated${p.separator}')) continue;

    final lines = await ent.readAsLines();
    for (final line in lines) {
      final trimmed = line.trimLeft();
      // Active table declaration (not commented)
      if (RegExp(r'^table:\s*\S').hasMatch(trimmed)) {
        final table = trimmed.split(':').skip(1).join(':').trim();
        tableModels.add('$name → $table');
        scoreRequired += 3;
        reasons.add('model $name declares table: $table');
      }
    }
  }

  // 2. Migrations definition.json — app tables vs serverpod_* only
  final migRoot = Directory(p.join(serverPath, 'migrations'));
  if (await migRoot.exists()) {
    await for (final ent in migRoot.list(followLinks: false)) {
      if (ent is! Directory) continue;
      final def = File(p.join(ent.path, 'definition.json'));
      if (!await def.exists()) continue;
      try {
        final json = jsonDecode(await def.readAsString());
        final tables = json['tables'];
        if (tables is List) {
          for (final t in tables) {
            if (t is! Map) continue;
            final tName = t['name']?.toString() ?? '';
            final module = t['module']?.toString() ?? '';
            if (tName.isEmpty) continue;
            // Framework / auth module tables still need a DB if present & used
            if (tName.startsWith('serverpod_') || module == 'serverpod') {
              // framework noise
              continue;
            }
            migrationTables.add(tName);
            scoreRequired += 2;
            reasons.add('migration defines app table `$tName`');
          }
        }
      } catch (_) {}
    }
    if (migrationTables.isEmpty && tableModels.isEmpty) {
      reasons.add(
          'migrations exist but only serverpod_* / no app tables (scaffolding)');
      scoreNone += 1;
    }
  } else {
    reasons.add('no migrations/ directory');
    scoreNone += 1;
  }

  // 3. Application code using session.db / ORM
  final lib = Directory(p.join(serverPath, 'lib'));
  if (await lib.exists()) {
    final dbCall = RegExp(
      r'session\.db\b|\.insertRow\b|\.insert\b|\.find\(|\.findById\b|\.updateRow\b|\.deleteRow\b|\.deleteWhere\b',
    );
    await for (final ent in lib.list(recursive: true, followLinks: false)) {
      if (ent is! File || !ent.path.endsWith('.dart')) continue;
      if (ent.path.contains('${p.separator}generated${p.separator}')) continue;
      final text = await ent.readAsString();
      if (dbCall.hasMatch(text)) {
        scoreRequired += 3;
        reasons.add(
            'code uses DB APIs in ${p.relative(ent.path, from: serverPath)}');
        break;
      }
    }
  }

  // 4. production.yaml already omits database
  final prod = File(p.join(serverPath, 'config', 'production.yaml'));
  if (await prod.exists()) {
    final text = await prod.readAsString();
    final hasDbKey = RegExp(r'^database:\s*$', multiLine: true).hasMatch(text) ||
        RegExp(r'^database:\s*\n\s+\w', multiLine: true).hasMatch(text);
    if (!hasDbKey || text.contains('database: omitted')) {
      scoreNone += 2;
      reasons.add('production.yaml has no active database: block');
    } else {
      scoreRequired += 1;
      reasons.add('production.yaml configures database:');
    }
    if (text.contains('persistentEnabled: false')) {
      scoreNone += 1;
    }
    if (text.contains('persistentEnabled: true')) {
      scoreRequired += 1;
      reasons.add('sessionLogs.persistentEnabled: true needs a DB');
    }
  }

  final need = scoreRequired >= 2
      ? DatabaseNeed.required
      : (scoreNone >= 2 && scoreRequired == 0
          ? DatabaseNeed.none
          : (scoreRequired > scoreNone
              ? DatabaseNeed.required
              : (scoreNone > scoreRequired
                  ? DatabaseNeed.none
                  : DatabaseNeed.unknown)));

  return DatabaseDetection(
    need: need,
    reasons: reasons,
    appTableModels: tableModels,
    appMigrationTables: migrationTables,
  );
}
