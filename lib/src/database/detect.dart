import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Heuristic: does this Serverpod server look like it needs a database?
enum DatabaseNeed {
  /// No app tables / hard auth / session.db — fine without Postgres.
  none,

  /// Clear signals: app tables, requireLogin, session.db, or active auth use.
  required,

  /// Ambiguous — ask the user.
  unknown,
}

class DatabaseDetection {
  DatabaseDetection({
    required this.need,
    required this.reasons,
    this.warnings = const [],
    this.appTableModels = const [],
    this.appMigrationTables = const [],
    this.authScaffolded = false,
    this.authActivelyUsed = false,
  });

  final DatabaseNeed need;
  final List<String> reasons;
  /// Soft notes (e.g. unused template auth) — do not force DB alone.
  final List<String> warnings;
  final List<String> appTableModels;
  final List<String> appMigrationTables;

  /// Template-style auth present (deps / init / migration tables).
  final bool authScaffolded;

  /// App actually gates endpoints or UI on auth.
  final bool authActivelyUsed;

  @Deprecated('Use authActivelyUsed / authScaffolded')
  bool get authRequiresDatabase => authActivelyUsed;
}

final _authPackage = RegExp(
  r'serverpod_auth_(idp|core|shared|server|client|email|google|apple|firebase)',
);

final _authInit = RegExp(
  r'initializeAuthServices|AuthConfig\.set|pod\.authenticationHandler',
);

final _requireLoginTrue = RegExp(
  r'bool\s+get\s+requireLogin\s*=>\s*true\b',
);

final _authSessionUse = RegExp(
  r'session\.authenticated\b|session\.auth\b|AuthSuccess\b|'
  r'authenticatedUser\b|currentUserId\b|requireAuthentication\b',
);

/// Inspect a Serverpod `*_server` package (and optional Flutter app) for DB need.
///
/// **Template auth** (Serverpod create default) is a **warning**, not a hard
/// requirement — login tables exist but unused apps (e.g. sacred-draw) can stay
/// `database: none`. Hard require when app models/ORM/`requireLogin`/sign-in home.
Future<DatabaseDetection> detectDatabaseNeed(
  String serverPath, {
  String? flutterPath,
}) async {
  final reasons = <String>[];
  final warnings = <String>[];
  final tableModels = <String>[];
  final migrationTables = <String>[];
  var scoreRequired = 0;
  var scoreNone = 0;
  var authScaffolded = false;
  var authActivelyUsed = false;
  var authMigrationTables = 0;
  var coreOnlyMigrationTables = 0;

  final server = Directory(serverPath);
  if (!await server.exists()) {
    return DatabaseDetection(
      need: DatabaseNeed.unknown,
      reasons: ['server path not found'],
    );
  }

  // ── Auth scaffold: pubspec ─────────────────────────────────
  final pubspec = File(p.join(serverPath, 'pubspec.yaml'));
  if (await pubspec.exists()) {
    final text = await pubspec.readAsString();
    final authDeps = <String>[];
    for (final line in text.split('\n')) {
      final m = RegExp(r'^\s*(serverpod_auth_[\w]+)\s*:').firstMatch(line);
      if (m != null) authDeps.add(m.group(1)!);
    }
    if (authDeps.isNotEmpty) {
      authScaffolded = true;
      warnings.add(
          'template/auth deps: ${authDeps.take(3).join(', ')}'
          '${authDeps.length > 3 ? '…' : ''} — strip if unused, else need a DB for login');
    }
  }

  // ── Auth scaffold + active use in server lib ───────────────
  final lib = Directory(p.join(serverPath, 'lib'));
  if (await lib.exists()) {
    await for (final ent in lib.list(recursive: true, followLinks: false)) {
      if (ent is! File || !ent.path.endsWith('.dart')) continue;
      if (ent.path.contains('${p.separator}generated${p.separator}')) continue;

      final rel = p.relative(ent.path, from: serverPath);
      final text = await ent.readAsString();
      final inAuthDir = rel.contains('${p.separator}auth${p.separator}') ||
          rel.contains('/auth/');

      if (_authInit.hasMatch(text)) {
        authScaffolded = true;
        warnings.add(
            'auth initialized in $rel (Serverpod create default) — '
            'only needs DB if you use login');
      }

      if (_authPackage.hasMatch(text) && text.contains('import ')) {
        authScaffolded = true;
      }

      // App endpoints requiring login → auth is real
      if (_requireLoginTrue.hasMatch(text) && !inAuthDir) {
        // Insights etc. not in app lib
        authActivelyUsed = true;
        scoreRequired += 3;
        reasons.add('endpoint requireLogin => true in $rel (auth is in use)');
      }

      if (_authSessionUse.hasMatch(text) && !inAuthDir) {
        authActivelyUsed = true;
        scoreRequired += 2;
        reasons.add('app code checks auth session in $rel');
      }
    }
  }

  // ── App models with table: ─────────────────────────────────
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

  // ── Migrations ─────────────────────────────────────────────
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
            authScaffolded = true;
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
      warnings.add(
          'migrations include $authMigrationTables serverpod_auth_* tables '
          '(template schema; unused unless login is enabled)');
    }
    if (coreOnlyMigrationTables > 0 &&
        migrationTables.isEmpty &&
        tableModels.isEmpty) {
      reasons.add(
          'migrations only have core serverpod_* tables (no app tables)');
      scoreNone += 1;
    }
  } else {
    reasons.add('no migrations/ directory');
    scoreNone += 1;
  }

  // ── session.db / ORM in app code ───────────────────────────
  if (await lib.exists()) {
    final dbCall = RegExp(
      r'session\.db\b|\.insertRow\b|\.find\(|\.findById\b|\.updateRow\b|\.deleteRow\b|\.deleteWhere\b',
    );
    await for (final ent in lib.list(recursive: true, followLinks: false)) {
      if (ent is! File || !ent.path.endsWith('.dart')) continue;
      if (ent.path.contains('${p.separator}generated${p.separator}')) continue;
      final rel = p.relative(ent.path, from: serverPath);
      if (rel.contains('${p.separator}auth${p.separator}') ||
          rel.contains('/auth/')) {
        continue; // template auth endpoints
      }
      final text = await ent.readAsString();
      if (dbCall.hasMatch(text)) {
        scoreRequired += 3;
        reasons.add('code uses DB APIs in $rel');
        break;
      }
    }
  }

  // ── Flutter: sign-in as home = active auth ─────────────────
  final flutter = flutterPath ?? _guessFlutterSibling(serverPath);
  if (flutter != null) {
    final flutterAuth = await _inspectFlutterAuth(flutter);
    if (flutterAuth.scaffolded) {
      authScaffolded = true;
      warnings.addAll(flutterAuth.warnings);
    }
    if (flutterAuth.active) {
      authActivelyUsed = true;
      scoreRequired += 3;
      reasons.addAll(flutterAuth.reasons);
    }
  }

  // ── production.yaml ────────────────────────────────────────
  final prod = File(p.join(serverPath, 'config', 'production.yaml'));
  if (await prod.exists()) {
    final text = await prod.readAsString();
    final hasDbKey =
        RegExp(r'^database:\s*$', multiLine: true).hasMatch(text) ||
            RegExp(r'^database:\s*\n\s+\w', multiLine: true).hasMatch(text);
    final omitted = text.contains('database: omitted') || !hasDbKey;

    if (omitted) {
      scoreNone += 2;
      reasons.add('production.yaml has no active database: block');
      if (authScaffolded && !authActivelyUsed) {
        warnings.add(
            'auth is scaffolded but production omits database: — fine if '
            'you never call login; add a DB before enabling sign-in');
      }
      if (authActivelyUsed) {
        scoreRequired += 2;
        reasons.add(
            'production.yaml omits database: but auth is actively used');
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

  // Scaffold-only auth does NOT force required
  if (authActivelyUsed) {
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
    warnings: warnings,
    appTableModels: tableModels,
    appMigrationTables: migrationTables,
    authScaffolded: authScaffolded,
    authActivelyUsed: authActivelyUsed,
  );
}

String? _guessFlutterSibling(String serverPath) {
  final parent = p.dirname(serverPath);
  final base = p.basename(serverPath);
  // app_server → app_flutter
  if (base.endsWith('_server')) {
    final candidate =
        p.join(parent, '${base.substring(0, base.length - '_server'.length)}_flutter');
    if (Directory(candidate).existsSync()) return candidate;
  }
  // scan parent for *_flutter with web/
  final dir = Directory(parent);
  if (!dir.existsSync()) return null;
  for (final ent in dir.listSync()) {
    if (ent is! Directory) continue;
    final n = p.basename(ent.path);
    if (n.endsWith('_flutter') &&
        Directory(p.join(ent.path, 'web')).existsSync()) {
      return ent.path;
    }
  }
  return null;
}

class _FlutterAuthInspect {
  _FlutterAuthInspect({
    this.scaffolded = false,
    this.active = false,
    this.warnings = const [],
    this.reasons = const [],
  });
  final bool scaffolded;
  final bool active;
  final List<String> warnings;
  final List<String> reasons;
}

Future<_FlutterAuthInspect> _inspectFlutterAuth(String flutterPath) async {
  final warnings = <String>[];
  final reasons = <String>[];
  var scaffolded = false;
  var active = false;

  final pub = File(p.join(flutterPath, 'pubspec.yaml'));
  if (await pub.exists()) {
    final t = await pub.readAsString();
    if (t.contains('serverpod_auth')) {
      scaffolded = true;
      warnings.add(
          'Flutter depends on serverpod_auth_* (template) — strip if no login UI');
    }
  }

  final lib = Directory(p.join(flutterPath, 'lib'));
  if (!await lib.exists()) {
    return _FlutterAuthInspect(scaffolded: scaffolded, warnings: warnings);
  }

  var hasSignInScreen = false;
  var signInIsHome = false;

  await for (final ent in lib.list(recursive: true, followLinks: false)) {
    if (ent is! File || !ent.path.endsWith('.dart')) continue;
    final text = await ent.readAsString();
    final rel = p.relative(ent.path, from: flutterPath);
    final base = p.basename(ent.path);

    if (base.contains('sign_in') ||
        text.contains('SignInScreen') ||
        text.contains('SignInPage')) {
      hasSignInScreen = true;
      scaffolded = true;
    }

    // home: SignInScreen / MaterialApp(home: SignIn...)
    if (RegExp(
          r'''home:\s*(const\s+)?\w*SignIn\w*|initialRoute:\s*['"][^'"]*sign[_-]?in''',
          caseSensitive: false,
        ).hasMatch(text)) {
      signInIsHome = true;
    }

    // Auth gate wrapping the app
    if (text.contains('authInfoListenable') &&
        (text.contains('isAuthenticated') || text.contains('signedIn')) &&
        !base.contains('sign_in')) {
      // Could be only in sign_in_screen — if main.dart gates, harder
      if (base == 'main.dart' || rel.contains('app.dart')) {
        active = true;
        reasons.add('Flutter $rel gates UI on auth state');
      }
    }
  }

  if (hasSignInScreen && !signInIsHome) {
    warnings.add(
        'Flutter has sign_in_screen.dart but it is not the app home '
        '(typical unused Serverpod template)');
  }
  if (signInIsHome) {
    active = true;
    reasons.add('Flutter app home/initialRoute is sign-in (auth is in use)');
  }

  return _FlutterAuthInspect(
    scaffolded: scaffolded,
    active: active,
    warnings: warnings,
    reasons: reasons,
  );
}
