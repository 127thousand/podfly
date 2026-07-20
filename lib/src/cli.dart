import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'deploy/deploy.dart';
import 'doctor.dart';
import 'hosts/hosts.dart';
import 'init.dart';
import 'log.dart';
import 'process_runner.dart';
import 'smoke.dart';
import 'tty.dart';

Future<int> runPodfly(List<String> args) async {
  ensureHostsRegistered();
  final parser = _buildParser();

  // Allow `podfly --smoke` as shorthand for `podfly deploy --smoke`
  final knownCommands = {'doctor', 'init', 'deploy', 'smoke', 'help'};
  var effectiveArgs = List<String>.from(args);
  if (args.isEmpty) {
    effectiveArgs = ['deploy'];
  } else if (args.first == 'help' ||
      args.first == '--help' ||
      args.first == '-h') {
    _usage(parser);
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
    _usage(parser);
    return 64;
  }

  if (global['help'] == true || global.command?['help'] == true) {
    _usage(parser);
    return 0;
  }

  switch (global.command?.name) {
    case 'doctor':
      return _doctor(global);
    case 'init':
      return _init(global);
    case 'deploy':
      return _deploy(global);
    case 'smoke':
      return _smokeOnly(global);
    default:
      // `podfly deploy` parsed as command; bare might fall through
      if (global.command == null) {
        return _deploy(global);
      }
      _usage(parser);
      return 64;
  }
}

ArgParser _buildParser() {
  ArgParser deployFlags() => ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addFlag('api', negatable: false, help: 'Deploy API only')
    ..addFlag('web', negatable: false, help: 'Deploy web only')
    ..addFlag('dry-run', negatable: false, help: 'Plan only')
    ..addFlag('smoke', negatable: false, help: 'HTTP checks after deploy')
    ..addFlag('yes', abbr: 'y', negatable: false, help: 'Non-interactive defaults')
    ..addFlag('no-login', negatable: false, help: 'No browser logins')
    ..addFlag('init', negatable: false, help: 'Force init wizard')
    ..addOption(
      'mode',
      allowed: ['split', 'monolith', 'fly'],
      help: 'split = CDN UI + API; monolith = UI with API host (fly = legacy alias)',
    )
    ..addOption('host',
        allowed: HostRegistry.cliAllowedIds,
        help: 'API cloud host (default: fly; fly + railway deploy today)')
    ..addOption('config', help: 'Path to podfly.yaml')
    ..addOption('root', help: 'Project root');

  return ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addCommand('doctor', deployFlags())
    ..addCommand('init', deployFlags())
    ..addCommand('deploy', deployFlags())
    ..addCommand('smoke', deployFlags());
}

void _usage(ArgParser parser) {
  stdout.writeln('''
podfly — deploy Serverpod via existing cloud CLIs (not a host)

  serverpod create …  →  monorepo + Dockerfile (Serverpod)
  podfly deploy       →  fly/railway/wrangler/neonctl + config quirks

Usage:
  podfly deploy [options]   Doctor → init if needed → deploy
  podfly doctor             Check tools + auth
  podfly init               Write podfly.yaml only
  podfly smoke              HTTP checks only

Deploy options:
  --dry-run     Plan only (no create/deploy/network side effects)
  --smoke       After deploy, hit smoke: endpoints in podfly.yaml
  --api         API only (skip Flutter web / Pages) — use for mobile
  --web         Web only (or force web even if web.enabled: false)
  --yes / -y    Non-interactive init defaults
  --no-login    Do not open browser logins (CI: use tokens)
  --init        Force wizard; confirms before overwriting podfly.yaml
  --host        API cloud: fly | railway | digitalocean | render | …
                (wizard asks; fly + railway + digitalocean deploy today)
  --mode        split | monolith   (fly = legacy alias for monolith)
  --root        Project root (default: cwd)
  --config      Path to podfly.yaml

Doctor only requires the CLI for the chosen host (not always Fly).
Supported deploy today: Fly + Railway + DigitalOcean (API), Cloudflare Pages /
Railway·DO static web, Neon / Fly PG / Railway PG / DO PG / SQLite / none.
Dockerfile: prefer Serverpod's *_server/Dockerfile (podfly does not invent hosts).

Install: dart pub global activate podfly

Examples:
  serverpod create my_app --mini -f && cd my_app
  podfly deploy --yes --smoke

  podfly deploy --host railway --api --yes --smoke
  podfly deploy --host digitalocean --yes --smoke
  podfly deploy --yes --dry-run --no-login   # plan
  podfly deploy --api --yes --smoke          # mobile / API-only
  podfly doctor

Docs: https://pub.dev/packages/podfly · https://github.com/127thousand/podfly
''');
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
    config = await Initer(
      root: root,
      log: log,
      yes: yes,
      configPath: explicit ?? existingPath,
      preferredHost: preferredHost,
    ).run();
  } else {
    // configExists is true only when existingPath is non-null and file exists
    config = await PodflyConfig.load(existingPath);
    log.detail('config: $existingPath');
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
      // Explicit monolith CLI: drop Pages block; otherwise keep / default cloudflare for split
      cloudflare: (monolith && modeOpt != null) ||
              host == AppHost.digitalOcean ||
              host == AppHost.railway
          ? null
          : (config.cloudflare ??
              (monolith
                  ? null
                  : CloudflareConfig(project: config.name))),
      database: config.database,
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

  await Deployer(config: config, runner: runner, log: log).run(
    DeployOptions(
      doApi: doApi,
      doWeb: doWeb,
      smoke: _flag(g, 'smoke'),
    ),
  );
  return 0;
}

Future<int> _smokeOnly(ArgResults g) async {
  final log = Log();
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
