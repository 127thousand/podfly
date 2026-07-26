import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'fly_name.dart';
import 'hosts/hosts.dart';
import 'init.dart';
import 'log.dart';
import 'process_runner.dart';
import 'tty.dart';

/// What the user is scaffolding with `podfly create`.
enum CreateKind {
  /// Flutter app(s) + Serverpod API.
  appBackend,

  /// Flutter only (no Serverpod). Experimental — CI/web packaging only.
  appOnly,

  /// Serverpod server (+ client) without a product UI tree.
  backendOnly,
}

/// Surface flags for create (mobile / web; desktop later).
class CreateSurfaces {
  const CreateSurfaces({this.mobile = false, this.web = false});

  final bool mobile;
  final bool web;

  bool get any => mobile || web;

  /// API-only clients (no Flutter web deploy).
  bool get apiOnly => mobile && !web;

  static const mobileWeb = CreateSurfaces(mobile: true, web: true);
}

/// Options for [Creator] (from CLI flags or interactive menus).
class CreateOptions {
  CreateOptions({
    required this.name,
    required this.parentDir,
    required this.kind,
    required this.surfaces,
    required this.host,
    required this.mode,
    required this.database,
    this.template,
    this.force = true,
  });

  /// Serverpod project name (lowercase, no special chars).
  final String name;

  /// Directory in which `serverpod create` runs (project lands in [projectDir]).
  final String parentDir;

  final CreateKind kind;
  final CreateSurfaces surfaces;
  final AppHost host;

  /// Deploy topology when web is enabled.
  final DeployMode mode;

  /// Managed DB for `podfly.yaml` (and drives default Serverpod template).
  final DatabaseProvider database;

  /// Explicit Serverpod template; null = derive from [kind] + [database].
  final String? template;

  final bool force;

  String get projectDir => p.join(parentDir, name);

  /// Serverpod `--template` value.
  ///
  /// | kind        | DB none     | DB on        |
  /// |-------------|-------------|--------------|
  /// | app+backend | mini        | fullstack    |
  /// | backend     | server*     | server       |
  ///
  /// \* Serverpod has no “server without DB” template; we still use `server`
  /// and set `database.provider: none` in podfly.yaml for API-only demos.
  String get resolvedTemplate {
    if (template != null) return template!;
    return switch (kind) {
      CreateKind.appOnly => 'mini', // unused; flutter-only path
      CreateKind.backendOnly => 'server',
      CreateKind.appBackend =>
        database == DatabaseProvider.none ? 'mini' : 'fullstack',
    };
  }

  /// True when create intends Codemagic (or similar) mobile CI scaffolding.
  bool get wantsMobileCi =>
      kind != CreateKind.backendOnly && surfaces.mobile && !surfaces.web;
}

/// Scaffolds a Serverpod monorepo via `serverpod create`, then writes podfly.yaml.
class Creator {
  Creator({
    required this.log,
    required this.runner,
    this.yes = false,
  });

  final Log log;
  final ProcessRunner runner;
  final bool yes;

  /// Interactive or flag-driven create → project dir + [PodflyConfig].
  ///
  /// With [ProcessRunner.dryRun], plans only (no `serverpod create`, no files).
  Future<PodflyConfig> run({
    String? nameArg,
    String? directoryArg,
    CreateKind? kindFlag,
    CreateSurfaces? surfacesFlag,
    AppHost? hostFlag,
    DeployMode? modeFlag,
    String? templateFlag,
    DatabaseProvider? databaseFlag,
  }) async {
    ensureHostsRegistered();
    log.step('Create');

    final opts = await _resolveOptions(
      nameArg: nameArg,
      directoryArg: directoryArg,
      kindFlag: kindFlag,
      surfacesFlag: surfacesFlag,
      hostFlag: hostFlag,
      modeFlag: modeFlag,
      templateFlag: templateFlag,
      databaseFlag: databaseFlag,
    );

    final webEnabled = opts.kind != CreateKind.backendOnly && opts.surfaces.web;
    // Mobile-only / backend-only → no CDN topology; web → respect mode.
    final mode = !webEnabled ? DeployMode.monolith : opts.mode;

    if (opts.kind == CreateKind.appOnly) {
      log.warn(
        'app-only is experimental: Flutter package only — no Serverpod API. '
        'Deploy is limited to static web / mobile CI.',
      );
    }

    if (runner.dryRun) {
      log.dry(
        'plan: kind=${opts.kind.name} surfaces=mobile:${opts.surfaces.mobile}/'
        'web:${opts.surfaces.web} host=${opts.host.yamlName} '
        'mode=${mode.yamlName} template=${opts.resolvedTemplate} '
        'db=${_providerYaml(opts.database)}'
        '${opts.wantsMobileCi ? ' mobile_ci=codemagic' : ''}',
      );
      if (opts.kind != CreateKind.appOnly) {
        log.dry(
          'serverpod create -n ${opts.name} --template ${opts.resolvedTemplate} '
          '--no-interactive (cwd: ${opts.parentDir})',
        );
      } else {
        log.dry('flutter create ${opts.name} (cwd: ${opts.parentDir})');
      }
      log.dry('would write ${opts.projectDir}/podfly.yaml + PODFLY.md');
      log.ok('dry-run: create plan only → ${opts.projectDir}');
      log.done('Dry-run complete');
      return _plannedConfig(opts, mode: mode, webEnabled: webEnabled);
    }

    if (opts.kind != CreateKind.appOnly) {
      final sp = await runner.resolve('serverpod', ['serverpod']);
      if (sp == null) {
        throw StateError(
          'serverpod CLI not found on PATH. Install with:\n'
          '  dart pub global activate serverpod_cli\n'
          'Then re-run: podfly create',
        );
      }
      await _runServerpodCreate(sp, opts);
    } else {
      await _runFlutterOnly(opts);
    }

    final projectRoot = opts.projectDir;
    if (!await Directory(projectRoot).exists()) {
      throw StateError('expected project at $projectRoot after scaffold');
    }

    // App-only: flutter at monorepo root. Backend-only: no flutter package.
    final flutterPath = switch (opts.kind) {
      CreateKind.appOnly => '.',
      CreateKind.backendOnly => '${opts.name}_flutter',
      CreateKind.appBackend => null, // discover
    };
    final serverPath = opts.kind == CreateKind.appOnly
        ? '${opts.name}_server' // placeholder until user adds API
        : null;

    log.step('Write podfly.yaml');
    final config = await Initer(
      root: projectRoot,
      log: log,
      yes: true,
      preferredHost: opts.host,
      overrides: InitOverrides(
        host: opts.host,
        mode: mode,
        webEnabled: webEnabled,
        database: opts.database,
        webBuild: FlutterWebBuild.canvaskit,
        server: serverPath,
        flutter: flutterPath,
      ),
    ).run();

    await _writeScaffoldReadme(projectRoot, config, opts);
    await _printNextSteps(projectRoot, config, opts);

    log.done('Created ${config.name}');
    return config;
  }

  /// Prefer a short relative path when the project is under cwd; else absolute.
  static String _friendlyCd(String projectRoot) {
    final rel = p.relative(projectRoot);
    if (rel.startsWith('..') || p.isAbsolute(rel)) return projectRoot;
    return rel;
  }

  static String _providerYaml(DatabaseProvider p) => switch (p) {
        DatabaseProvider.none => 'none',
        DatabaseProvider.sqlite => 'sqlite',
        DatabaseProvider.flyPostgres => 'fly_postgres',
        DatabaseProvider.neon => 'neon',
        DatabaseProvider.supabase => 'supabase',
        DatabaseProvider.railwayPostgres => 'railway_postgres',
        DatabaseProvider.digitalOceanPostgres => 'digitalocean_postgres',
        DatabaseProvider.renderPostgres => 'render_postgres',
      };

  /// Unsaved config describing what dry-run would write.
  PodflyConfig _plannedConfig(
    CreateOptions opts, {
    required DeployMode mode,
    required bool webEnabled,
  }) {
    final name = opts.name;
    final flyApp = sanitizeFlyAppName(name);
    final server = '${name}_server';
    final flutter = opts.kind == CreateKind.appOnly
        ? '.'
        : '${name}_flutter';
    final host = opts.host;
    final apiUrl = HostRegistry.require(host).defaultApiUrl(
      name: name,
      sanitizedName: flyApp,
    );
    return PodflyConfig(
      root: opts.projectDir,
      host: host,
      webHost: StaticWebHost.cloudflare,
      mode: mode,
      name: name,
      server: server,
      flutter: flutter,
      fly: FlyConfig(app: flyApp),
      database: _databaseConfig(opts.database, name: name, flyApp: flyApp),
      mobile: opts.wantsMobileCi
          ? MobileConfig(
              provider: MobileProvider.codemagic,
              codemagic: CodemagicConfig(),
            )
          : MobileConfig(),
      web: WebConfig(
        enabled: webEnabled,
        apiUrl: apiUrl,
        patchBootstrap: webEnabled,
        writeHeaders: webEnabled && mode == DeployMode.split,
        build: FlutterWebBuild.canvaskit,
      ),
      smoke: SmokeConfig(
        api: SmokeEndpoint(
          method: 'POST',
          path: '/greeting/hello',
          body: '{}',
        ),
        web: webEnabled ? SmokeEndpoint(path: '/') : null,
      ),
    );
  }

  static DatabaseConfig _databaseConfig(
    DatabaseProvider provider, {
    required String name,
    required String flyApp,
  }) {
    switch (provider) {
      case DatabaseProvider.none:
        return DatabaseConfig(provider: DatabaseProvider.none);
      case DatabaseProvider.sqlite:
        return DatabaseConfig(
          provider: DatabaseProvider.sqlite,
          sqlite: SqliteConfig(volumeName: '${flyApp}_data'),
        );
      case DatabaseProvider.flyPostgres:
        return DatabaseConfig(
          provider: DatabaseProvider.flyPostgres,
          flyPostgres: FlyPostgresConfig(app: '$flyApp-db'),
        );
      case DatabaseProvider.neon:
        return DatabaseConfig(
          provider: DatabaseProvider.neon,
          neon: NeonConfig(provision: false, projectName: name),
        );
      case DatabaseProvider.supabase:
        return DatabaseConfig(
          provider: DatabaseProvider.supabase,
          supabase: SupabaseConfig(provision: true, projectName: '$flyApp-db'),
        );
      case DatabaseProvider.railwayPostgres:
        return DatabaseConfig(
          provider: DatabaseProvider.railwayPostgres,
          railwayPostgres: RailwayPostgresConfig(),
        );
      case DatabaseProvider.digitalOceanPostgres:
        return DatabaseConfig(
          provider: DatabaseProvider.digitalOceanPostgres,
          digitalOceanPostgres:
              DigitalOceanPostgresConfig(clusterName: '$flyApp-db'),
        );
      case DatabaseProvider.renderPostgres:
        return DatabaseConfig(
          provider: DatabaseProvider.renderPostgres,
          renderPostgres: RenderPostgresConfig(name: '$flyApp-db'),
        );
    }
  }

  Future<CreateOptions> _resolveOptions({
    String? nameArg,
    String? directoryArg,
    CreateKind? kindFlag,
    CreateSurfaces? surfacesFlag,
    AppHost? hostFlag,
    DeployMode? modeFlag,
    String? templateFlag,
    DatabaseProvider? databaseFlag,
  }) async {
    final useYes = yes || !isTty;

    // Parent + name
    var name = (nameArg ?? '').trim().toLowerCase();
    var parent = Directory.current.path;

    if (directoryArg != null && directoryArg.isNotEmpty) {
      final abs = p.normalize(Directory(directoryArg).absolute.path);
      if (name.isEmpty) {
        name = p.basename(abs).toLowerCase();
        parent = p.dirname(abs);
      } else {
        parent = abs;
      }
    }

    if (name.isEmpty) {
      if (useYes) {
        name = 'my_app';
      } else {
        name = (await prompt('Project name (lowercase)', defaultValue: 'my_app'))
            .trim()
            .toLowerCase();
      }
    }

    name = _sanitizeServerpodName(name);
    parent = p.normalize(Directory(parent).absolute.path);

    // Kind
    late CreateKind kind;
    if (kindFlag != null) {
      kind = kindFlag;
    } else if (useYes) {
      kind = CreateKind.appBackend;
    } else {
      final idx = await choose(
        'What are you building?',
        [
          'App + Serverpod backend (recommended)',
          'Backend only (Serverpod server)',
          'App only — experimental (Flutter, no Serverpod)',
        ],
        defaultIndex: 0,
      );
      kind = switch (idx) {
        1 => CreateKind.backendOnly,
        2 => CreateKind.appOnly,
        _ => CreateKind.appBackend,
      };
    }

    // Surfaces
    late CreateSurfaces surfaces;
    if (kind == CreateKind.backendOnly) {
      surfaces = const CreateSurfaces();
    } else if (surfacesFlag != null) {
      surfaces = surfacesFlag;
    } else if (useYes) {
      surfaces = CreateSurfaces.mobileWeb;
    } else {
      final idx = await choose(
        'Client surfaces',
        [
          'Mobile + Web',
          'Mobile only (API deploy + Codemagic CI)',
          'Web only',
        ],
        defaultIndex: 0,
      );
      surfaces = switch (idx) {
        1 => const CreateSurfaces(mobile: true),
        2 => const CreateSurfaces(web: true),
        _ => CreateSurfaces.mobileWeb,
      };
    }

    // Database + Serverpod template
    late DatabaseProvider database;
    String? template = templateFlag;
    if (kind == CreateKind.appOnly) {
      database = DatabaseProvider.none;
    } else if (databaseFlag != null) {
      database = databaseFlag;
    } else if (templateFlag != null) {
      // Template implies DB unless user forced --database.
      database = switch (templateFlag) {
        'mini' => DatabaseProvider.none,
        'fullstack' || 'server' => DatabaseProvider.neon,
        _ => DatabaseProvider.none,
      };
    } else if (useYes) {
      // Fastest first ship: mini / no DB. Opt into Postgres with --database.
      database = DatabaseProvider.none;
    } else if (kind == CreateKind.backendOnly) {
      final idx = await choose(
        'Database',
        [
          'None — API only (podfly.yaml database: none; server template still has migrations)',
          'Postgres — Neon (default managed)',
          'Postgres — Fly Postgres',
        ],
        defaultIndex: 0,
      );
      database = switch (idx) {
        1 => DatabaseProvider.neon,
        2 => DatabaseProvider.flyPostgres,
        _ => DatabaseProvider.none,
      };
    } else {
      final idx = await choose(
        'Database',
        [
          'None — mini template (fastest demo, no Postgres)',
          'Postgres — fullstack template + Neon',
          'Postgres — fullstack template + Fly Postgres',
        ],
        defaultIndex: 0,
      );
      database = switch (idx) {
        1 => DatabaseProvider.neon,
        2 => DatabaseProvider.flyPostgres,
        _ => DatabaseProvider.none,
      };
    }

    // If user passed --template mini but also --database neon, template wins for
    // scaffold; DB still goes to podfly.yaml (they can grow into it).
    if (templateFlag == 'mini' && database != DatabaseProvider.none) {
      log.tip(
        'template mini has no DB schema; podfly.yaml still records '
        '${_providerYaml(database)} for when you add tables.',
      );
    }
    if (templateFlag == 'fullstack' && database == DatabaseProvider.none) {
      log.tip(
        'fullstack includes migrations; consider --database neon (or fly_postgres).',
      );
    }

    // Host
    late AppHost host;
    if (hostFlag != null) {
      host = hostFlag;
    } else if (useYes) {
      host = AppHost.fly;
    } else if (kind == CreateKind.appOnly) {
      host = AppHost.fly; // placeholder for future API / CI defaults
    } else {
      final adapters = HostRegistry.all;
      final idx = await choose(
        'Where should the API run?',
        adapters
            .map((a) =>
                '${a.canDeploy ? '✅' : '🗺️'} ${a.label}  ·  ${a.capabilitySummary}')
            .toList(),
        defaultIndex: 0,
      );
      host = adapters[idx].appHost;
    }

    // Host-native DB defaults when user picked a generic "postgres"
    // and host is Railway/DO/Render — optional refinement:
    if (database == DatabaseProvider.neon &&
        (host == AppHost.railway ||
            host == AppHost.digitalOcean ||
            host == AppHost.render)) {
      // Keep neon unless interactive already chose fly — fine for MVP.
    }

    // Mode when web
    late DeployMode mode;
    final wantWeb = kind != CreateKind.backendOnly && surfaces.web;
    if (!wantWeb) {
      mode = DeployMode.monolith;
    } else if (modeFlag != null) {
      mode = modeFlag;
    } else if (useYes) {
      mode = DeployMode.split;
    } else {
      final adapter = HostRegistry.require(host);
      final labels = <String>[];
      final modes = <DeployMode>[];
      if (adapter.supportsAllInOneWeb) {
        labels.add('🧱 Monolith — one URL (Flutter + API)');
        modes.add(DeployMode.monolith);
      }
      if (adapter.supportsSplitCdn || adapter.deploysWebNatively) {
        labels.add('🔀 Split — CDN / native web UI + API host');
        modes.add(DeployMode.split);
      }
      if (labels.isEmpty) {
        mode = DeployMode.split;
      } else {
        final idx = await choose('Web topology', labels, defaultIndex: 0);
        mode = modes[idx.clamp(0, modes.length - 1)];
      }
    }

    final projectDir = p.join(parent, name);
    if (await Directory(projectDir).exists()) {
      final kids = await Directory(projectDir).list().toList();
      if (kids.isNotEmpty) {
        throw StateError(
          'Target directory is not empty: $projectDir\n'
          'Choose a new name or remove the directory.',
        );
      }
    }

    return CreateOptions(
      name: name,
      parentDir: parent,
      kind: kind,
      surfaces: surfaces,
      host: host,
      mode: mode,
      database: database,
      template: template,
      force: true,
    );
  }

  Future<void> _runServerpodCreate(String serverpod, CreateOptions opts) async {
    final template = opts.resolvedTemplate;
    log.detail(
      'serverpod create -n ${opts.name} --template $template --no-interactive',
    );

    if (runner.dryRun) {
      log.dry(
        'serverpod create -n ${opts.name} -t $template --no-interactive '
        '(cwd: ${opts.parentDir})',
      );
      return;
    }

    await Directory(opts.parentDir).create(recursive: true);

    final args = <String>[
      'create',
      '-n',
      opts.name,
      '--template',
      template,
      '--no-interactive',
      if (opts.force) '-f',
    ];

    final r = await runner.run(
      serverpod,
      args,
      workingDirectory: opts.parentDir,
      allowDryRun: false,
    );
    if (!r.ok) {
      throw StateError(
        'serverpod create failed (exit ${r.exitCode})\n'
        '${r.stderr}\n${r.stdout}',
      );
    }
    log.ok('serverpod create → ${opts.projectDir}');
  }

  Future<void> _runFlutterOnly(CreateOptions opts) async {
    final flutter = await runner.resolve('flutter', ['flutter']);
    if (flutter == null) {
      throw StateError('flutter not found on PATH');
    }
    log.detail('flutter create ${opts.name} (app-only, experimental)');
    if (runner.dryRun) {
      log.dry('flutter create ${opts.name} (cwd: ${opts.parentDir})');
      return;
    }
    await Directory(opts.parentDir).create(recursive: true);
    final platforms = <String>[
      if (opts.surfaces.mobile) ...['ios', 'android'],
      if (opts.surfaces.web) 'web',
    ];
    // Default to common mobile+web if somehow empty.
    final platformList =
        platforms.isEmpty ? ['ios', 'android', 'web'] : platforms;
    final args = <String>[
      'create',
      opts.name,
      '--platforms',
      platformList.join(','),
    ];
    final r = await runner.run(
      flutter,
      args,
      workingDirectory: opts.parentDir,
      allowDryRun: false,
    );
    if (!r.ok) {
      throw StateError('flutter create failed (exit ${r.exitCode})');
    }
    log.ok('flutter create → ${opts.projectDir}');
  }

  Future<void> _writeScaffoldReadme(
    String projectRoot,
    PodflyConfig config,
    CreateOptions opts,
  ) async {
    final path = p.join(projectRoot, 'PODFLY.md');
    if (await File(path).exists()) return;
    final buf = StringBuffer()
      ..writeln('# ${config.name}')
      ..writeln()
      ..writeln(
        opts.kind == CreateKind.appOnly
            ? 'Scaffolded with **podfly create** (app-only · experimental).'
            : 'Scaffolded with **podfly create** (Serverpod).',
      )
      ..writeln()
      ..writeln(
        '| | |\n'
        '|--|--|\n'
        '| Host | `${config.host.yamlName}` |\n'
        '| Mode | `${config.mode.yamlName}` |\n'
        '| Web | `${config.web.enabled}` |\n'
        '| Database | `${_providerYaml(opts.database)}` |\n'
        '| Template | `${opts.kind == CreateKind.appOnly ? 'flutter' : opts.resolvedTemplate}` |',
      )
      ..writeln();

    if (opts.kind != CreateKind.appOnly) {
      buf
        ..writeln('## Local')
        ..writeln()
        ..writeln('```bash')
        ..writeln('serverpod start');
      if (opts.kind != CreateKind.backendOnly && config.web.enabled) {
        buf.writeln(
          'cd ${config.flutter} && flutter run -d chrome '
          '--dart-define=SERVER_URL=http://localhost:8080/',
        );
      } else if (opts.kind != CreateKind.backendOnly && opts.surfaces.mobile) {
        buf.writeln(
          'cd ${config.flutter} && flutter run '
          '--dart-define=SERVER_URL=http://localhost:8080/',
        );
      }
      buf.writeln('```');
      buf.writeln();
    } else {
      buf
        ..writeln('## Local')
        ..writeln()
        ..writeln('```bash')
        ..writeln('cd ${config.flutter == '.' ? '.' : config.flutter}')
        ..writeln('flutter run')
        ..writeln('```')
        ..writeln();
    }

    buf.writeln('## Deploy');
    buf.writeln();
    buf.writeln('```bash');
    if (!config.web.enabled) {
      buf.writeln('podfly deploy --api --smoke   # API only (mobile / backend)');
    } else {
      buf.writeln('podfly deploy --smoke');
    }
    buf.writeln('```');
    buf.writeln();

    if (opts.wantsMobileCi) {
      buf
        ..writeln('## Mobile CI')
        ..writeln()
        ..writeln(
          '`podfly.yaml` sets `mobile.provider: codemagic`. After the first '
          'API deploy, `codemagic.yaml` is written/synced with `SERVER_URL`.',
        )
        ..writeln();
    }

    if (opts.database != DatabaseProvider.none) {
      buf
        ..writeln('## Database')
        ..writeln()
        ..writeln(
          'Configured provider: `${_providerYaml(opts.database)}`. '
          'Deploy provisions/wires credentials when the host supports it; '
          'see [doc/database.md](https://github.com/127thousand/podfly/blob/main/doc/database.md).',
        )
        ..writeln();
    }

    buf
      ..writeln('## Config')
      ..writeln()
      ..writeln('Edit `podfly.yaml` freely. Re-run `podfly init` to re-pick host/CDN.');

    if (!runner.dryRun) {
      await File(path).writeAsString(buf.toString());
      log.detail('wrote PODFLY.md');
    }
  }

  Future<void> _printNextSteps(
    String projectRoot,
    PodflyConfig config,
    CreateOptions opts,
  ) async {
    log.ok('Created ${config.name} at $projectRoot');
    log.detail('Next:');
    final cdTarget = _friendlyCd(projectRoot);
    log.detail('  cd $cdTarget');

    if (opts.kind != CreateKind.appOnly) {
      log.detail('  serverpod start              # local API');
    }

    if (opts.kind != CreateKind.backendOnly) {
      final flutterCd = config.flutter == '.' ? '.' : config.flutter;
      if (config.web.enabled) {
        log.detail(
          '  cd $flutterCd && flutter run -d chrome '
          '--dart-define=SERVER_URL=http://localhost:8080/',
        );
      } else if (opts.surfaces.mobile) {
        log.detail(
          '  cd $flutterCd && flutter run '
          '--dart-define=SERVER_URL=http://localhost:8080/',
        );
      }
    }

    if (!config.web.enabled) {
      log.detail('  podfly deploy --api --smoke  # ship API');
    } else {
      log.detail('  podfly deploy --smoke        # ship');
    }

    // Host CLI / auth hints (light doctor)
    final adapter = HostRegistry.require(opts.host);
    final bins = adapter.cliBinaries;
    var missing = false;
    for (final bin in bins) {
      final path = await runner.resolve(bin, [bin]);
      if (path == null) {
        missing = true;
        log.tip(
          '${adapter.label} CLI `$bin` not on PATH — ${adapter.installHint}',
        );
        break;
      }
    }
    if (!missing) {
      final login = _loginHint(opts.host);
      if (login != null) {
        log.tip('Log in once if needed: $login');
      }
      log.tip('Then: podfly doctor && podfly deploy --smoke');
    }

    if (opts.wantsMobileCi) {
      log.tip(
        'Mobile-only: web.enabled=false · Codemagic CI on first API deploy',
      );
    }
    if (opts.database != DatabaseProvider.none) {
      log.tip(
        'Database: ${_providerYaml(opts.database)} — credentials wired on deploy',
      );
    }
  }

  /// Serverpod: lowercase letters, digits, underscores only.
  static String _sanitizeServerpodName(String raw) {
    var n = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_');
    n = n.replaceAll(RegExp(r'_+'), '_');
    n = n.replaceAll(RegExp(r'^_|_$'), '');
    if (n.isEmpty) n = 'my_app';
    if (RegExp(r'^[0-9]').hasMatch(n)) n = 'app_$n';
    return n;
  }

  static String? _loginHint(AppHost host) => switch (host) {
        AppHost.fly => 'fly auth login',
        AppHost.railway => 'railway login',
        AppHost.digitalOcean => 'doctl auth init',
        AppHost.render => 'render login',
        AppHost.cloudRun => 'gcloud auth login',
        AppHost.aws || AppHost.awsEcs => 'aws configure',
        AppHost.azure => 'az login',
        AppHost.hetzner => 'hcloud context create',
      };
}

/// Parse `--kind` CLI value.
CreateKind? parseCreateKind(String? s) {
  if (s == null || s.isEmpty) return null;
  return switch (s.toLowerCase().replaceAll('-', '_')) {
    'app_backend' || 'app+backend' || 'fullstack' || 'full' =>
      CreateKind.appBackend,
    'app_only' || 'app' || 'flutter' => CreateKind.appOnly,
    'backend_only' || 'backend' || 'server' || 'api' => CreateKind.backendOnly,
    _ => throw FormatException(
        'Unknown --kind: $s (app-backend | app-only | backend-only)',
      ),
  };
}

/// Parse `--surfaces mobile,web`.
CreateSurfaces? parseCreateSurfaces(String? s) {
  if (s == null || s.trim().isEmpty) return null;
  final parts =
      s.toLowerCase().split(RegExp(r'[,+\s]+')).where((e) => e.isNotEmpty);
  var mobile = false;
  var web = false;
  for (final p in parts) {
    switch (p) {
      case 'mobile' || 'ios' || 'android':
        mobile = true;
      case 'web':
        web = true;
      case 'desktop' || 'macos' || 'windows' || 'linux':
        // Accepted but not scaffolded specially yet.
        break;
      default:
        throw FormatException('Unknown surface: $p (mobile | web)');
    }
  }
  if (!mobile && !web) {
    throw FormatException('--surfaces needs mobile and/or web');
  }
  return CreateSurfaces(mobile: mobile, web: web);
}

/// Parse `--database` for create (podfly.yaml provider).
DatabaseProvider? parseCreateDatabase(String? s) {
  if (s == null || s.trim().isEmpty) return null;
  return switch (s.toLowerCase().replaceAll('-', '_')) {
    'none' || 'no' || 'off' => DatabaseProvider.none,
    'neon' => DatabaseProvider.neon,
    'fly_postgres' || 'fly' || 'flypg' => DatabaseProvider.flyPostgres,
    'sqlite' => DatabaseProvider.sqlite,
    'supabase' => DatabaseProvider.supabase,
    'railway_postgres' || 'railway' => DatabaseProvider.railwayPostgres,
    'digitalocean_postgres' || 'do_postgres' || 'do' =>
      DatabaseProvider.digitalOceanPostgres,
    'render_postgres' || 'render' => DatabaseProvider.renderPostgres,
    _ => throw FormatException(
        'Unknown --database: $s '
        '(none | neon | fly_postgres | sqlite | supabase | …)',
      ),
  };
}
