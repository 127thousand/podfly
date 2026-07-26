import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'create.dart';
import 'deploy/deploy.dart';
import 'destroy/destroy.dart';
import 'doctor.dart';
import 'fly_name.dart';
import 'help.dart';
import 'hosts/hosts.dart';
import 'init.dart';
import 'log.dart';
import 'process_runner.dart';
import 'smoke.dart';
import 'tty.dart';
import 'upgrade.dart';
import 'version.dart';

Future<int> runPodfly(List<String> args) async {
  ensureHostsRegistered();
  final parser = _buildParser();

  // Allow `podfly --smoke` as shorthand for `podfly deploy --smoke`
  final knownCommands = {
    'doctor',
    'init',
    'create',
    'deploy',
    'destroy',
    'nuke',
    'smoke',
    'upgrade',
    'version',
    'help',
  };
  var effectiveArgs = List<String>.from(args);

  if (args.isEmpty) {
    effectiveArgs = ['deploy'];
  } else if (args.first == '--version' || args.first == '-v') {
    stdout.writeln(podflyVersionLine());
    return 0;
  } else if (args.first == 'help') {
    // podfly help [topic]
    printHelp(args.length > 1 ? args[1] : null);
    return 0;
  } else if (args.first == '--help' || args.first == '-h') {
    printHelp();
    return 0;
  } else if (!knownCommands.contains(args.first) &&
      args.first.startsWith('-')) {
    effectiveArgs = ['deploy', ...args];
  }

  ArgResults global;
  try {
    global = parser.parse(effectiveArgs);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    printHelp();
    return 64;
  }

  // Command-specific --help / -h
  final cmdName = global.command?.name;
  if (global['help'] == true || global.command?['help'] == true) {
    printHelp(cmdName == 'nuke' ? 'destroy' : cmdName);
    return 0;
  }
  if (global['version'] == true) {
    stdout.writeln(podflyVersionLine());
    return 0;
  }

  switch (cmdName) {
    case 'doctor':
      return _doctor(global);
    case 'init':
      return _init(global);
    case 'create':
      return _create(global);
    case 'deploy':
      return _deploy(global);
    case 'destroy':
    case 'nuke':
      return _destroy(global);
    case 'smoke':
      return _smokeOnly(global);
    case 'upgrade':
      return _upgrade(global);
    case 'version':
      stdout.writeln(podflyVersionLine());
      return 0;
    case 'help':
      printHelp(global.command?.rest.isNotEmpty == true
          ? global.command!.rest.first
          : null);
      return 0;
    default:
      if (global.command == null) {
        return _deploy(global);
      }
      printHelp();
      return 64;
  }
}

ArgParser _buildParser() {
  ArgParser deployFlags() => ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addFlag('api', negatable: false, help: 'Deploy / destroy API')
    ..addFlag('web', negatable: false, help: 'Deploy / destroy web only')
    ..addFlag('dry-run', negatable: false, help: 'Plan only')
    ..addFlag('smoke', negatable: false, help: 'HTTP checks after deploy')
    ..addFlag('yes', abbr: 'y', negatable: false,
        help: 'Non-interactive defaults / confirm destroy')
    ..addFlag('no-login', negatable: false, help: 'No browser logins')
    ..addFlag('init', negatable: false, help: 'Force init wizard')
    ..addFlag('database',
        negatable: false,
        help: 'destroy: also delete managed database (Supabase/Fly PG/…)')
    ..addOption(
      'mode',
      allowed: ['split', 'monolith', 'fly'],
      help: 'split = CDN UI + API; monolith = UI with API host (fly = legacy alias)',
    )
    ..addOption('host',
        allowed: HostRegistry.cliAllowedIds,
        help: 'API cloud host (default: fly; see README for supported hosts)')
    ..addOption('config', help: 'Path to podfly.yaml')
    ..addOption('root', help: 'Project root');

  ArgParser createFlags() => ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addFlag('dry-run', negatable: false, help: 'Plan only (no files)')
    ..addFlag('yes', abbr: 'y', negatable: false,
        help: 'Non-interactive defaults (app+backend, mobile+web, Fly, no DB)')
    ..addOption('directory',
        abbr: 'd',
        help: 'Parent directory for the new project (default: cwd)')
    ..addOption('kind',
        help: 'app-backend | app-only | backend-only',
        valueHelp: 'kind')
    ..addOption('surfaces',
        help: 'Comma list: mobile, web (ignored for backend-only)',
        valueHelp: 'mobile,web')
    ..addOption('host',
        allowed: HostRegistry.cliAllowedIds,
        help: 'API cloud host (default: fly)')
    ..addOption('mode',
        allowed: ['split', 'monolith', 'fly'],
        help: 'Web topology when web surface is on (default: split)')
    ..addOption('template',
        allowed: ['mini', 'fullstack', 'server', 'module'],
        help:
            'serverpod create template (default: mini if no DB, fullstack if DB)')
    ..addOption('database',
        help:
            'none | neon | fly_postgres | sqlite | … (default: none with --yes)',
        valueHelp: 'provider');

  ArgParser upgradeFlags() => ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addFlag('dry-run', negatable: false, help: 'Print activate command only')
    ..addFlag('yes', abbr: 'y', negatable: false, help: 'Non-interactive')
    ..addFlag('git',
        negatable: false, help: 'Activate from GitHub instead of pub.dev')
    ..addOption('git-url',
        help: 'Git URL for --git (default: 127thousand/podfly)')
    ..addOption('path', help: 'Activate from local path (contributors)');

  ArgParser versionFlags() => ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false);

  ArgParser helpFlags() => ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false);

  return ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addFlag('version', abbr: 'v', negatable: false, help: 'Print version')
    ..addCommand('doctor', deployFlags())
    ..addCommand('init', deployFlags())
    ..addCommand('create', createFlags())
    ..addCommand('deploy', deployFlags())
    ..addCommand('destroy', deployFlags())
    ..addCommand('nuke', deployFlags()) // alias
    ..addCommand('smoke', deployFlags())
    ..addCommand('upgrade', upgradeFlags())
    ..addCommand('version', versionFlags())
    ..addCommand('help', helpFlags());
}

String _root(ArgResults g) {
  final fromCmd = g.command?['root'] as String?;
  return p.normalize(
    Directory(fromCmd ?? Directory.current.path).absolute.path,
  );
}

bool _flag(ArgResults g, String name) {
  final c = g.command;
  if (c != null) {
    try {
      if (c[name] == true) return true;
    } catch (_) {}
  }
  return false;
}

String? _opt(ArgResults g, String name) {
  final c = g.command;
  if (c == null) return null;
  try {
    return c[name] as String?;
  } catch (_) {
    return null;
  }
}

Future<int> _doctor(ArgResults g) async {
  final log = Log();
  log.banner(subtitle: 'doctor');
  final runner = ProcessRunner(log: log, dryRun: _flag(g, 'dry-run'));
  final doctor = Doctor(
    runner: runner,
    log: log,
    noLogin: _flag(g, 'no-login'),
  );
  final root = _root(g);
  final explicit = _opt(g, 'config');
  final cfgPath = explicit ?? await PodflyConfig.findConfigPath(root);
  PodflyConfig? config;
  if (cfgPath != null && await File(cfgPath).exists()) {
    config = await PodflyConfig.load(cfgPath);
    log.detail('config: $cfgPath');
  }
  var ok = await doctor.run(scope: DoctorScope.baseline);
  if (config != null) {
    ok = await doctor.run(scope: DoctorScope.configAware, config: config) && ok;
  } else {
    log.detail('no podfly.yaml — skipped config-aware checks');
  }
  return ok ? 0 : 1;
}

Future<int> _init(ArgResults g) async {
  final log = Log();
  log.banner(subtitle: 'init');
  final root = _root(g);
  final runner = ProcessRunner(log: log, dryRun: _flag(g, 'dry-run'));
  final doctor = Doctor(
    runner: runner,
    log: log,
    noLogin: _flag(g, 'no-login'),
  );
  if (!await doctor.run(scope: DoctorScope.baseline)) return 1;
  final explicit = _opt(g, 'config');
  final hostOpt = _opt(g, 'host');
  final config = await Initer(
    root: root,
    log: log,
    yes: _flag(g, 'yes'),
    configPath: explicit,
    preferredHost: hostOpt != null ? AppHostX.parse(hostOpt) : null,
  ).run();
  if (!await doctor.run(scope: DoctorScope.configAware, config: config)) {
    return 1;
  }
  log.detail('Next: podfly deploy --smoke');
  return 0;
}

Future<int> _create(ArgResults g) async {
  final log = Log();
  final dry = _flag(g, 'dry-run');
  log.banner(subtitle: dry ? 'create (dry-run)' : 'create');
  final runner = ProcessRunner(log: log, dryRun: dry);

  final cmd = g.command;
  final rest = cmd?.rest ?? const <String>[];
  final nameArg = rest.isNotEmpty ? rest.first : null;
  if (rest.length > 1) {
    log.err('Too many arguments — usage: podfly create [name] [options]');
    return 64;
  }

  CreateKind? kind;
  CreateSurfaces? surfaces;
  DeployMode? mode;
  AppHost? host;
  DatabaseProvider? database;
  try {
    kind = parseCreateKind(_opt(g, 'kind'));
    surfaces = parseCreateSurfaces(_opt(g, 'surfaces'));
    database = parseCreateDatabase(_opt(g, 'database'));
    final modeOpt = _opt(g, 'mode');
    if (modeOpt != null) mode = parseDeployMode(modeOpt);
    final hostOpt = _opt(g, 'host');
    if (hostOpt != null) host = AppHostX.parse(hostOpt);
  } on FormatException catch (e) {
    log.err(e.message);
    return 64;
  }

  try {
    await Creator(
      log: log,
      runner: runner,
      yes: _flag(g, 'yes'),
    ).run(
      nameArg: nameArg,
      directoryArg: _opt(g, 'directory'),
      kindFlag: kind,
      surfacesFlag: surfaces,
      hostFlag: host,
      modeFlag: mode,
      templateFlag: _opt(g, 'template'),
      databaseFlag: database,
    );
    return 0;
  } catch (e, st) {
    log.err('$e');
    if (Platform.environment['PODFLY_DEBUG'] == '1') {
      log.detail('$st');
    }
    return 1;
  }
}

Future<int> _deploy(ArgResults g) async {
  final log = Log();
  final dry = _flag(g, 'dry-run');
  final noLogin = _flag(g, 'no-login') || dry;
  final runner = ProcessRunner(log: log, dryRun: dry);
  final doctor = Doctor(
    runner: runner,
    log: log,
    noLogin: noLogin,
  );

  final root = _root(g);
  log.banner(
    subtitle: dry ? 'deploy (dry-run)' : 'deploy',
  );
  log.step('podfly deploy${dry ? ' (dry-run)' : ''}');
  log.detail('root: $root');

  final explicit = _opt(g, 'config');
  var cfgPath = explicit ?? await PodflyConfig.findConfigPath(root);
  final forceInit = _flag(g, 'init');
  final yes = _flag(g, 'yes');
  final apiOnlyFlag = _flag(g, 'api');

  late PodflyConfig config;
  final existingPath = cfgPath;
  final configExists =
      existingPath != null && await File(existingPath).exists();

  // Peek config so API-only deploys can skip the Flutter SDK requirement.
  PodflyConfig? peekConfig;
  if (configExists) {
    try {
      peekConfig = await PodflyConfig.load(existingPath);
    } catch (_) {/* init/overwrite path may fix */}
  }
  final needFlutter = !apiOnlyFlag &&
      (peekConfig == null || peekConfig.web.enabled);
  if (!await doctor.run(
    scope: DoctorScope.baseline,
    requireFlutter: needFlutter,
  )) {
    return 1;
  }

  final hostOpt = _opt(g, 'host');
  final preferredHost =
      hostOpt != null ? AppHostX.parse(hostOpt) : null;

  if (forceInit && configExists && !yes) {
    final path = existingPath;
    final overwrite = await confirm(
      'Overwrite existing ${p.basename(path)}?',
      defaultYes: false,
    );
    if (!overwrite) {
      log.detail('keeping existing config');
      config = await PodflyConfig.load(path);
      log.detail('config: $path');
    } else {
      config = await Initer(
        root: root,
        log: log,
        yes: yes,
        configPath: explicit ?? path,
        preferredHost: preferredHost,
      ).run();
    }
  } else if (forceInit || !configExists) {
    if (yes) {
      log.tip(
        '--yes skips the host/CDN picker (defaults: Fly + Cloudflare). '
        'Omit --yes for interactive choice.',
      );
    } else if (isTty) {
      log.tip('Interactive setup — pick API cloud and UI CDN when asked.');
    }
    config = await Initer(
      root: root,
      log: log,
      yes: yes,
      configPath: explicit ?? existingPath,
      preferredHost: preferredHost,
    ).run();
  } else {
    // configExists — load, but offer to re-pick cloud when interactive.
    config = await PodflyConfig.load(existingPath);
    log.detail('config: $existingPath');
    final summary =
        'host: ${config.host.yamlName}'
        '${config.web.enabled ? ' · web_host: ${config.webHost.yamlName}' : ' · API-only'}';
    log.detail(summary);

    if (isTty && !yes) {
      log.info('');
      log.info('  Current setup → $summary');
      final change = await confirm(
        'Change API cloud / UI CDN / database options?',
        defaultYes: false,
      );
      if (change) {
        config = await Initer(
          root: root,
          log: log,
          yes: false,
          configPath: existingPath,
          preferredHost: preferredHost,
        ).run();
      }
    }
  }

  final modeOpt = _opt(g, 'mode');
  if (hostOpt != null || modeOpt != null) {
    final host =
        hostOpt != null ? AppHostX.parse(hostOpt) : config.host;
    final mode = modeOpt != null
        ? parseDeployMode(modeOpt)
        : config.mode;
    final monolith = mode == DeployMode.monolith;
    config = PodflyConfig(
      root: config.root,
      host: host,
      webHost: config.webHost,
      mode: mode,
      name: config.name,
      server: config.server,
      flutter: config.flutter,
      fly: config.fly,
      railway: host == AppHost.railway
          ? (config.railway ??
              RailwayConfig(project: config.name, service: 'api'))
          : config.railway,
      digitalOcean: host == AppHost.digitalOcean
          ? (config.digitalOcean ??
              DigitalOceanConfig(app: config.name.replaceAll('_', '-')))
          : config.digitalOcean,
      render: host == AppHost.render
          ? (config.render ??
              RenderConfig(service: config.name.replaceAll('_', '-')))
          : config.render,
      cloudRun: host == AppHost.cloudRun
          ? (config.cloudRun ??
              CloudRunConfig(service: config.name.replaceAll('_', '-')))
          : config.cloudRun,
      aws: host == AppHost.aws
          ? (config.aws ??
              AwsConfig(service: config.name.replaceAll('_', '-')))
          : config.aws,
      awsEcs: host == AppHost.awsEcs
          ? (config.awsEcs ??
              AwsEcsConfig(service: config.name.replaceAll('_', '-')))
          : config.awsEcs,
      azure: host == AppHost.azure
          ? (config.azure ??
              AzureConfig(app: config.name.replaceAll('_', '-')))
          : config.azure,
      hetzner: host == AppHost.hetzner
          ? (config.hetzner ?? HetznerConfig())
          : config.hetzner,
      // Explicit monolith CLI: drop static CDN block; otherwise keep / default for split
      cloudflare: (monolith && modeOpt != null) ||
              host == AppHost.digitalOcean ||
              host == AppHost.railway ||
              host == AppHost.render ||
              host == AppHost.cloudRun ||
              host == AppHost.aws ||
              host == AppHost.awsEcs ||
              host == AppHost.azure ||
              host == AppHost.hetzner
          ? null
          : (config.cloudflare ??
              (monolith
                  ? null
                  : (config.webHost == StaticWebHost.cloudflare
                      ? CloudflareConfig(
                          project: sanitizeFlyAppName(config.name),
                        )
                      : null))),
      vercel: (monolith && modeOpt != null) ||
              host == AppHost.digitalOcean ||
              host == AppHost.railway ||
              host == AppHost.render ||
              host == AppHost.cloudRun ||
              host == AppHost.aws ||
              host == AppHost.awsEcs ||
              host == AppHost.azure ||
              host == AppHost.hetzner
          ? null
          : (config.vercel ??
              (monolith
                  ? null
                  : (config.webHost == StaticWebHost.vercel
                      ? VercelConfig(project: config.name)
                      : null))),
      netlify: (monolith && modeOpt != null) ||
              host == AppHost.digitalOcean ||
              host == AppHost.railway ||
              host == AppHost.render ||
              host == AppHost.cloudRun ||
              host == AppHost.aws ||
              host == AppHost.awsEcs ||
              host == AppHost.azure ||
              host == AppHost.hetzner
          ? null
          : (config.netlify ??
              (monolith
                  ? null
                  : (config.webHost == StaticWebHost.netlify
                      ? NetlifyConfig(site: config.name)
                      : null))),
      githubPages: (monolith && modeOpt != null) ||
              host == AppHost.digitalOcean ||
              host == AppHost.railway ||
              host == AppHost.render ||
              host == AppHost.cloudRun ||
              host == AppHost.aws ||
              host == AppHost.awsEcs ||
              host == AppHost.azure ||
              host == AppHost.hetzner
          ? null
          : (config.githubPages ??
              (monolith
                  ? null
                  : (config.webHost == StaticWebHost.githubPages
                      ? GitHubPagesConfig(repo: config.name)
                      : null))),
      database: config.database,
      redis: config.redis,
      mobile: config.mobile,
      web: config.web,
      smoke: config.smoke,
    );
  }

  var doApi = true;
  var doWeb = config.web.enabled;
  // Explicit flags override config.
  if (_flag(g, 'api') && !_flag(g, 'web')) doWeb = false;
  if (_flag(g, 'web') && !_flag(g, 'api')) {
    doApi = false;
    doWeb = true; // force web even if web.enabled was false
  }
  if (_flag(g, 'web') && _flag(g, 'api')) {
    doWeb = true;
    doApi = true;
  }

  if (!await doctor.run(
    scope: DoctorScope.configAware,
    config: config,
    requireFlutter: doWeb,
  )) {
    return 1;
  }

  if (!doWeb) {
    log.detail(
        'Deploy targets: API only'
        '${config.web.enabled ? '' : ' (web.enabled: false)'}');
  }

  final wall = Stopwatch()..start();
  try {
    await Deployer(
      config: config,
      runner: runner,
      log: log,
      nonInteractive: yes,
    ).run(
      DeployOptions(
        doApi: doApi,
        doWeb: doWeb,
        smoke: _flag(g, 'smoke'),
      ),
    );
    return 0;
  } catch (e, st) {
    log.err('$e');
    if (Platform.environment['PODFLY_DEBUG'] == '1') {
      log.detail('$st');
    }
    return 1;
  } finally {
    // Wall clock including doctor/init — always printed.
    wall.stop();
    log.elapsed(wall.elapsed, label: 'Deploy finished');
  }
}

Future<int> _destroy(ArgResults g) async {
  final log = Log();
  final dry = _flag(g, 'dry-run');
  final yes = _flag(g, 'yes');
  log.banner(subtitle: dry ? 'destroy (dry-run)' : 'destroy');
  final root = _root(g);
  final explicit = _opt(g, 'config');
  final cfgPath = explicit ?? await PodflyConfig.findConfigPath(root);
  if (cfgPath == null || !await File(cfgPath).exists()) {
    log.err('No podfly.yaml — nothing to destroy');
    return 1;
  }
  final config = await PodflyConfig.load(cfgPath);
  log.detail('config: $cfgPath');

  var doApi = true;
  var doWeb = true;
  if (_flag(g, 'api') && !_flag(g, 'web')) doWeb = false;
  if (_flag(g, 'web') && !_flag(g, 'api')) doApi = false;

  final runner = ProcessRunner(log: log, dryRun: dry);
  final sw = Stopwatch()..start();
  try {
    await Destroyer(
      config: config,
      runner: runner,
      log: log,
      yes: yes,
    ).run(
      doApi: doApi,
      doWeb: doWeb && config.web.enabled,
      doDatabase: _flag(g, 'database'),
    );
  } catch (e) {
    log.err('$e');
    return 1;
  }
  sw.stop();
  log.elapsed(sw.elapsed, label: 'Destroy finished');
  return 0;
}

Future<int> _smokeOnly(ArgResults g) async {
  final log = Log();
  log.banner(subtitle: 'smoke');
  final root = _root(g);
  final cfgPath = await PodflyConfig.findConfigPath(root);
  if (cfgPath == null) {
    log.err('No podfly.yaml — run podfly deploy or podfly init first');
    return 1;
  }
  final config = await PodflyConfig.load(cfgPath);
  final ok = await SmokeRunner(config: config, log: log).run();
  return ok ? 0 : 1;
}

Future<int> _upgrade(ArgResults g) async {
  final log = Log();
  final dry = _flag(g, 'dry-run');
  log.banner(subtitle: dry ? 'upgrade (dry-run)' : 'upgrade');
  final runner = ProcessRunner(log: log, dryRun: dry);

  UpgradeSource source = UpgradeSource.pub;
  String? pathDir = _opt(g, 'path');
  var gitUrl = _opt(g, 'git-url');
  if (pathDir != null && pathDir.isNotEmpty) {
    source = UpgradeSource.path;
  } else if (_flag(g, 'git') || (gitUrl != null && gitUrl.isNotEmpty)) {
    source = UpgradeSource.git;
    gitUrl ??= 'https://github.com/127thousand/podfly.git';
  }

  try {
    return await Upgrader(log: log, runner: runner).run(
      UpgradeOptions(
        source: source,
        gitUrl: gitUrl ?? 'https://github.com/127thousand/podfly.git',
        pathDir: pathDir,
        dryRun: dry,
        yes: _flag(g, 'yes'),
      ),
    );
  } catch (e, st) {
    log.err('$e');
    if (Platform.environment['PODFLY_DEBUG'] == '1') {
      log.detail('$st');
    }
    return 1;
  }
}
