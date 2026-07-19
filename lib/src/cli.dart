import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'deploy/deploy.dart';
import 'doctor.dart';
import 'init.dart';
import 'log.dart';
import 'process_runner.dart';
import 'smoke.dart';
import 'tty.dart';

Future<int> runPodfly(List<String> args) async {
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
    ..addOption('mode', allowed: ['split', 'fly'])
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
  podfly deploy       →  fly/wrangler/neonctl + config quirks

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
  --no-login    Do not open browser logins (CI: use FLY_API_TOKEN, etc.)
  --init        Force wizard; confirms before overwriting podfly.yaml
  --mode        split | fly   (split = Pages UI + Fly API)
  --root        Project root (default: cwd)
  --config      Path to podfly.yaml

Supported today: Fly (API), Cloudflare Pages (UI), Neon / Fly PG / SQLite / none.
Dockerfile: prefer Serverpod's *_server/Dockerfile (podfly does not invent hosts).

Examples:
  serverpod create my_app --mini -f && cd my_app
  podfly deploy --yes --smoke

  podfly deploy --yes --dry-run --no-login   # plan
  podfly deploy --api --yes --smoke          # mobile / API-only
  podfly doctor

Docs: https://github.com/127thousand/podfly (README, AGENTS.md, llms.txt)
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
  final cfgPath = await PodflyConfig.findConfigPath(root);
  PodflyConfig? config;
  if (cfgPath != null) {
    config = await PodflyConfig.load(cfgPath);
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
  final config = await Initer(
    root: root,
    log: log,
    yes: _flag(g, 'yes'),
    configPath: explicit,
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

  if (!await doctor.run(scope: DoctorScope.baseline)) return 1;

  final explicit = _opt(g, 'config');
  var cfgPath = explicit ?? await PodflyConfig.findConfigPath(root);
  final forceInit = _flag(g, 'init');
  final yes = _flag(g, 'yes');

  late PodflyConfig config;
  final existingPath = cfgPath;
  final configExists =
      existingPath != null && await File(existingPath).exists();

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
      ).run();
    }
  } else if (forceInit || !configExists) {
    config = await Initer(
      root: root,
      log: log,
      yes: yes,
      configPath: explicit ?? existingPath,
    ).run();
  } else {
    // configExists is true only when existingPath is non-null and file exists
    config = await PodflyConfig.load(existingPath);
    log.detail('config: $existingPath');
  }

  final modeOpt = _opt(g, 'mode');
  if (modeOpt != null) {
    final flyMode = modeOpt == 'fly';
    config = PodflyConfig(
      root: config.root,
      mode: flyMode ? DeployMode.fly : DeployMode.split,
      name: config.name,
      server: config.server,
      flutter: config.flutter,
      fly: config.fly,
      // Clear Cloudflare block in fly mode so config stays consistent.
      cloudflare: flyMode
          ? null
          : (config.cloudflare ?? CloudflareConfig(project: config.name)),
      database: config.database,
      web: config.web,
      smoke: config.smoke,
    );
  }

  if (!await doctor.run(scope: DoctorScope.configAware, config: config)) {
    return 1;
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
