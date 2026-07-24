import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'deploy/deploy.dart';
import 'destroy/destroy.dart';
import 'doctor.dart';
import 'fly_name.dart';
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
  final knownCommands = {
    'doctor',
    'init',
    'deploy',
    'destroy',
    'nuke',
    'smoke',
    'help',
  };
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
    case 'destroy':
    case 'nuke':
      return _destroy(global);
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

  return ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addCommand('doctor', deployFlags())
    ..addCommand('init', deployFlags())
    ..addCommand('deploy', deployFlags())
    ..addCommand('destroy', deployFlags())
    ..addCommand('nuke', deployFlags()) // alias
    ..addCommand('smoke', deployFlags());
}

void _usage(ArgParser parser) {
  stdout.writeln('''
podfly — deploy Serverpod via existing cloud CLIs (not a host)

  serverpod create …  →  monorepo + Dockerfile (Serverpod)
  podfly deploy       →  fly/railway/wrangler/… + config quirks
  podfly destroy      →  tear down API + static web (opt-in DB)

Usage:
  podfly deploy [options]   Doctor → init if needed → deploy
  podfly destroy [options]  Tear down cloud resources from podfly.yaml
  podfly doctor             Check tools + auth
  podfly init               Write podfly.yaml only (interactive host picker)
  podfly smoke              HTTP checks only

Deploy options:
  --dry-run     Plan only (no create/deploy/network side effects)
  --smoke       After deploy, hit smoke: endpoints in podfly.yaml
  --api         API only (skip Flutter web / Pages) — use for mobile
  --web         Web only (or force web even if web.enabled: false)
  --yes / -y    Non-interactive init defaults (skips host/CDN questions!)
  --no-login    Do not open browser logins (CI: use tokens)
  --init        Force wizard; confirms before overwriting podfly.yaml
  --host        API cloud: fly | railway | digitalocean | render | …
  --mode        split | monolith
  --root / --config

Destroy options:
  --yes         Required non-interactively; confirm destruction
  --api / --web Limit what is destroyed (default: both)
  --database    Also delete managed Postgres (Supabase / Fly PG / …)
  --dry-run     Print plan only

Tip: first-time interactive demo — omit --yes so you are asked for cloud + CDN:
  serverpod create my_app --mini -f && cd my_app && podfly deploy --smoke

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
    // configExists is true only when existingPath is non-null and file exists
    config = await PodflyConfig.load(existingPath);
    log.detail('config: $existingPath');
    log.detail(
      'host: ${config.host.yamlName}'
      '${config.web.enabled ? ' · web_host: ${config.webHost.yamlName}' : ' · API-only'}',
    );
    if (isTty && !yes) {
      log.tip('Re-run with --init to change host / CDN / database.');
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
