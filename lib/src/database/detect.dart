import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Heuristic: does this Serverpod server look like it needs a database?
enum DatabaseNeed {
  /// No app tables, no auth, no session.db — fine without Postgres.
  none,

  /// Clear signals: tables, auth, session.db, or production database block.
  required,

  /// Ambiguous — ask the user.
  unknown,
}

class DatabaseDetection {
  DatabaseDetection({
    required this.need,
    required this.reasons,
    this.appTableModels = const [],
    this.appMigrationTables = const [],
    this.authRequiresDatabase = false,
  });

  final DatabaseNeed need;
  final List<String> reasons;
  final List<String> appTableModels;
  final List<String> appMigrationTables;

  /// True when Serverpod Auth / IDP is wired up (needs tables for users/sessions).
  final bool authRequiresDatabase;
}

final _authPackage = RegExp(
  r'serverpod_auth_(idp|core|shared|server|client|email|google|apple|firebase)',
);

final _authInit = RegExp(
  r'initializeAuthServices|AuthConfig\.set|pod\.authenticationHandler',
);

/// Inspect a Serverpod `*_server` package for database usage signals.
Future<DatabaseDetection> detectDatabaseNeed(String serverPath) async {
  final reasons = <String>[];
  final tableModels = <String>[];
  final migrationTables = <String>[];
  var scoreRequired = 0;
  var scoreNone = 0;
  var authRequiresDatabase = false;
  var authMigrationTables = 0;
  var coreOnlyMigrationTables = 0;

  final server = Directory(serverPath);
  if (!await server.exists()) {
    return DatabaseDetection(
      need: DatabaseNeed.unknown,
      reasons: ['server path not found'],
    );
  }

  // ── Auth: pubspec dependencies ─────────────────────────────
  final pubspec = File(p.join(serverPath, 'pubspec.yaml'));
  if (await pubspec.exists()) {
    final text = await pubspec.readAsString();
    final authDeps = <String>[];
    for (final line in text.split('\n')) {
      final m = RegExp(r'^\s*(serverpod_auth_[\w]+)\s*:').firstMatch(line);
      if (m != null) authDeps.add(m.group(1)!);
    }
    if (authDeps.isNotEmpty) {
      authRequiresDatabase = true;
      scoreRequired += 2;
      reasons.add(
          'pubspec depends on auth: ${authDeps.take(4).join(', ')}'
          '${authDeps.length > 4 ? '…' : ''} (needs DB for users/sessions)');
    }
  }

  // ── Auth: server.dart / lib initializeAuthServices ─────────
  final lib = Directory(p.join(serverPath, 'lib'));
  if (await lib.exists()) {
    await for (final ent in lib.list(recursive: true, followLinks: false)) {
      if (ent is! File || !ent.path.endsWith('.dart')) continue;
      if (ent.path.contains('${p.separator}generated${p.separator}')) continue;
      final text = await ent.readAsString();
      if (_authInit.hasMatch(text)) {
        authRequiresDatabase = true;
        scoreRequired += 3;
        reasons.add(
            'auth initialized in ${p.relative(ent.path, from: serverPath)} '
            '(initializeAuthServices / AuthConfig — needs DB)');
        break;
      }
      // Imports of auth packages in non-generated code
      if (_authPackage.hasMatch(text) &&
          text.contains('import ') &&
          !authRequiresDatabase) {
        // weak until we confirm init — still a hint
        scoreRequired += 1;
        reasons.add(
            'imports serverpod_auth_* in ${p.relative(ent.path, from: serverPath)}');
      }
    }
  }

  // ── 1. .spy.yaml with active `table:` ──────────────────────
  await for (final ent in server.list(recursive: true, followLinks: false)) {
    if (ent is! File) continue;
    final name = p.basename(ent.path);
    if (!(name.endsWith('.spy.yaml') || name.endsWith('.spy.yml'))) continue;
    if (ent.path.contains('${p.separator}generated${p.separator}')) continue;

    final lines = await ent.readAsLines();
    for (final line in lines) {
      final trimmed = line.trimLeft();
      if (RegExp(r'^table:\s*\S').hasMatch(trimmed)) {
        final table = trimmed.split(':').skip(1).join(':').trim();
        tableModels.add('$name → $table');
        scoreRequired += 3;
        reasons.add('model $name declares table: $table');
      }
    }
  }

  // ── 2. Migrations ──────────────────────────────────────────
  // serverpod_* core (logs, health, cloud storage) = scaffolding
  // serverpod_auth_* = real auth schema → DB required
  // other modules / app tables → DB required
  final migRoot = Directory(p.join(serverPath, 'migrations'));
  if (await migRoot.exists()) {
    await for (final ent in migRoot.list(followLinks: false)) {
      if (ent is! Directory) continue;
      final def = File(p.join(ent.path, 'definition.json'));
      if (!await def.exists()) continue;
      try {
        final json = jsonDecode(await def.readAsString());
        final tables = json['tables'];
        if (tables is! List) continue;
        for (final t in tables) {
          if (t is! Map) continue;
          final tName = t['name']?.toString() ?? '';
          final module = t['module']?.toString() ?? '';
          if (tName.isEmpty) continue;

          final isAuth = tName.startsWith('serverpod_auth_') ||
              module.startsWith('serverpod_auth');
          final isCoreServerpod = (tName.startsWith('serverpod_') && !isAuth) ||
              module == 'serverpod';

          if (isAuth) {
            authMigrationTables++;
            authRequiresDatabase = true;
            migrationTables.add(tName);
          } else if (isCoreServerpod) {
            coreOnlyMigrationTables++;
          } else {
            migrationTables.add(tName);
            scoreRequired += 2;
            reasons.add('migration defines app table `$tName`');
          }
        }
      } catch (_) {}
    }

    if (authMigrationTables > 0) {
      scoreRequired += 3;
      reasons.add(
          'migrations include $authMigrationTables serverpod_auth_* tables '
          '(users, sessions, IDP accounts)');
    } else if (coreOnlyMigrationTables > 0 &&
        migrationTables.isEmpty &&
        tableModels.isEmpty &&
        !authRequiresDatabase) {
      reasons.add(
          'migrations only have core serverpod_* tables (no auth, no app tables)');
      scoreNone += 1;
    }
  } else {
    reasons.add('no migrations/ directory');
    scoreNone += 1;
  }

  // ── 3. session.db / ORM in app code ────────────────────────
  if (await lib.exists()) {
    final dbCall = RegExp(
      r'session\.db\b|\.insertRow\b|\.find\(|\.findById\b|\.updateRow\b|\.deleteRow\b|\.deleteWhere\b',
    );
    await for (final ent in lib.list(recursive: true, followLinks: false)) {
      if (ent is! File || !ent.path.endsWith('.dart')) continue;
      if (ent.path.contains('${p.separator}generated${p.separator}')) continue;
      final text = await ent.readAsString();
      // Avoid matching Auth package generated patterns only in app endpoints
      if (dbCall.hasMatch(text)) {
        scoreRequired += 3;
        reasons.add(
            'code uses DB APIs in ${p.relative(ent.path, from: serverPath)}');
        break;
      }
    }
  }

  // ── 4. production.yaml ─────────────────────────────────────
  final prod = File(p.join(serverPath, 'config', 'production.yaml'));
  if (await prod.exists()) {
    final text = await prod.readAsString();
    final hasDbKey =
        RegExp(r'^database:\s*$', multiLine: true).hasMatch(text) ||
            RegExp(r'^database:\s*\n\s+\w', multiLine: true).hasMatch(text);
    final omitted = text.contains('database: omitted') || !hasDbKey;

    if (omitted) {
      if (authRequiresDatabase) {
        // Conflict: auth needs DB but production omitted it
        scoreRequired += 1;
        reasons.add(
            'production.yaml omits database: but auth is configured — '
            'login/session endpoints will fail without a DB');
      } else {
        scoreNone += 2;
        reasons.add('production.yaml has no active database: block');
      }
    } else {
      scoreRequired += 1;
      reasons.add('production.yaml configures database:');
    }
    if (text.contains('persistentEnabled: true')) {
      scoreRequired += 1;
      reasons.add('sessionLogs.persistentEnabled: true needs a DB');
    }
  }

  // Auth alone is enough to require DB (even if app models are pure DTOs)
  if (authRequiresDatabase) {
    scoreRequired = scoreRequired < 2 ? 2 : scoreRequired;
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
    authRequiresDatabase: authRequiresDatabase,
  );
}
