import 'dart:io';

import 'package:path/path.dart' as p;

/// What client surfaces this Serverpod monorepo looks like it ships.
enum ClientSurface {
  /// Deploy Flutter web (Pages and/or static on Fly).
  web,

  /// Mobile (or other non-web) clients only — podfly deploys API only.
  apiOnly,

  /// Unclear; default to web for backward compatibility if web/ exists.
  unknown,
}

class SurfaceDetection {
  SurfaceDetection({
    required this.surface,
    required this.reasons,
    this.warnings = const [],
    this.hasWebDir = false,
    this.hasAndroid = false,
    this.hasIos = false,
  });

  final ClientSurface surface;
  final List<String> reasons;
  final List<String> warnings;
  final bool hasWebDir;
  final bool hasAndroid;
  final bool hasIos;

  bool get deployWeb => surface == ClientSurface.web;
  bool get deployApiOnly => surface == ClientSurface.apiOnly;
}

/// Infer whether podfly should build/deploy Flutter web or only the API.
///
/// Serverpod create often scaffolds `web/` even for mobile apps, so we
/// distinguish stock template web from a real web product (same idea as
/// template auth detection).
Future<SurfaceDetection> detectClientSurface({
  required String serverPath,
  String? flutterPath,
}) async {
  final reasons = <String>[];
  final warnings = <String>[];

  // No flutter package → pure API
  if (flutterPath == null || !await Directory(flutterPath).exists()) {
    return SurfaceDetection(
      surface: ClientSurface.apiOnly,
      reasons: ['no Flutter package — API-only deploy'],
      hasWebDir: false,
    );
  }

  final hasWeb = await Directory(p.join(flutterPath, 'web')).exists();
  final hasAndroid = await Directory(p.join(flutterPath, 'android')).exists();
  final hasIos = await Directory(p.join(flutterPath, 'ios')).exists();
  final hasMobile = hasAndroid || hasIos;

  if (!hasWeb) {
    final platforms = <String>[
      if (hasAndroid) 'android',
      if (hasIos) 'ios',
    ];
    reasons.add(
      platforms.isEmpty
          ? 'Flutter package has no web/ directory'
          : 'Flutter package has ${platforms.join('+')} but no web/ — treat as mobile/API-only',
    );
    return SurfaceDetection(
      surface: ClientSurface.apiOnly,
      reasons: reasons,
      hasWebDir: false,
      hasAndroid: hasAndroid,
      hasIos: hasIos,
    );
  }

  // web/ exists — score real web product vs stock scaffold
  var webScore = 0;
  var stockScore = 0;

  final index = File(p.join(flutterPath, 'web', 'index.html'));
  if (await index.exists()) {
    final html = await index.readAsString();
    // Default flutter create title is the package name or "flutter_project"
    if (html.contains('canvasKitBaseUrl') ||
        html.contains('flutter_bootstrap.js')) {
      // bootstrap is usually a sibling file; index referencing custom bits
      webScore += 1;
    }
    if (RegExp(r'<title>\s*flutter[_ ]', caseSensitive: false).hasMatch(html) ||
        html.contains('A new Flutter project')) {
      stockScore += 1;
      reasons.add('web/index.html looks like stock Flutter create template');
    }
  }

  final bootstrap = File(p.join(flutterPath, 'web', 'flutter_bootstrap.js'));
  if (await bootstrap.exists()) {
    final b = await bootstrap.readAsString();
    if (b.contains('canvasKitBaseUrl') && !b.contains('serviceWorkerSettings')) {
      webScore += 3;
      reasons.add('web/flutter_bootstrap.js looks production/podfly-style');
    } else if (b.contains('serviceWorkerSettings')) {
      stockScore += 1;
      reasons.add('web/flutter_bootstrap.js still has Flutter serviceWorkerSettings');
    }
  } else {
    stockScore += 1;
    reasons.add('no custom web/flutter_bootstrap.js');
  }

  final headers = File(p.join(flutterPath, 'web', '_headers'));
  if (await headers.exists()) {
    webScore += 2;
    reasons.add('web/_headers present (static web hosting intended)');
  }

  // Non-trivial assets under web/ beyond defaults
  final webDir = Directory(p.join(flutterPath, 'web'));
  final defaultNames = {
    'index.html',
    'favicon.png',
    'manifest.json',
    'flutter.js',
    'flutter_bootstrap.js',
    'icons',
  };
  var extraWebFiles = 0;
  await for (final ent in webDir.list(followLinks: false)) {
    final name = p.basename(ent.path);
    if (!defaultNames.contains(name) && name != 'icons') {
      extraWebFiles++;
    }
  }
  if (extraWebFiles > 0) {
    webScore += 1;
    reasons.add('web/ has $extraWebFiles non-default entries');
  }

  // Server serves Flutter web?
  final serverDart = File(p.join(serverPath, 'lib', 'server.dart'));
  if (await serverDart.exists()) {
    final s = await serverDart.readAsString();
    if (s.contains('FlutterRoute') && s.contains('web/app')) {
      webScore += 2;
      reasons.add('server.dart registers FlutterRoute for web/app');
    }
    // Only placeholder / conditional with "build the flutter app" page
    if (s.contains('build_flutter_app.html') && !s.contains('FlutterRoute(')) {
      stockScore += 1;
    }
  }

  // serverpod flutter_build script in pubspec
  final serverPub = File(p.join(serverPath, 'pubspec.yaml'));
  if (await serverPub.exists()) {
    final pub = await serverPub.readAsString();
    if (pub.contains('flutter build web') || pub.contains('flutter_build:')) {
      webScore += 1;
      reasons.add('server pubspec has flutter web build script');
    }
  }

  if (hasMobile && webScore == 0) {
    stockScore += 2;
    warnings.add(
        'android/ios present with only stock-looking web/ — likely mobile-first');
  }

  ClientSurface surface;
  if (webScore >= 2) {
    surface = ClientSurface.web;
    reasons.add('score web=$webScore stock=$stockScore → deploy web + API');
  } else if (!hasWeb || (hasMobile && webScore < 2)) {
    // web missing already handled; web stock + mobile → api only
    if (hasMobile && webScore < 2) {
      surface = ClientSurface.apiOnly;
      reasons.add(
          'score web=$webScore stock=$stockScore → API-only (mobile clients)');
      warnings.add(
          'stock web/ scaffold ignored for deploy; use web.enabled: true to force Pages');
    } else if (webScore < stockScore) {
      surface = ClientSurface.apiOnly;
      reasons.add('web looks like unused scaffold → API-only');
    } else {
      surface = ClientSurface.unknown;
      reasons.add('ambiguous client surface web=$webScore stock=$stockScore');
    }
  } else {
    surface = ClientSurface.web;
    reasons.add('default to web deploy');
  }

  // Pure web (no mobile dirs) with any web/ → web
  if (!hasMobile && hasWeb) {
    surface = ClientSurface.web;
    reasons.add('no android/ios dirs; web/ present → web deploy');
  }

  return SurfaceDetection(
    surface: surface,
    reasons: reasons,
    warnings: warnings,
    hasWebDir: hasWeb,
    hasAndroid: hasAndroid,
    hasIos: hasIos,
  );
}
