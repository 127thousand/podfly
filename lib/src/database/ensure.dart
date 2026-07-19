import '../config.dart';
import '../hosts/hosts.dart';
import '../log.dart';
import '../process_runner.dart';
import 'production_yaml.dart';

/// Provision / ensure DB resources then patch production.yaml.
class DatabaseEnsure {
  DatabaseEnsure({
    required this.config,
    required this.runner,
    required this.log,
  });

  final PodflyConfig config;
  final ProcessRunner runner;
  final Log log;

  Future<void> run() async {
    log.step('Database (${config.database.provider.name})');

    switch (config.database.provider) {
      case DatabaseProvider.none:
        log.detail('stateless — no external DB');
      case DatabaseProvider.sqlite:
        await _sqliteVolume();
      case DatabaseProvider.flyPostgres:
        await _flyPostgres();
      case DatabaseProvider.neon:
        await _neon();
    }

    if (!runner.dryRun) {
      await ProductionYamlPatcher(config: config, log: log).apply();
    } else {
      log.dry('patch ${config.server}/config/production.yaml');
    }
  }

  Future<String> _flyBin() async {
    final fly = await runner.resolve('fly', ['flyctl']);
    if (fly == null) throw StateError('fly not found');
    return fly;
  }

  Future<void> _sqliteVolume() async {
    ensureHostsRegistered();
    if (config.host != AppHost.fly) {
      log.warn(
          'sqlite volume automation is Fly-only; on ${config.host.label} '
          'mount storage yourself or use neon');
      return;
    }
    final s = config.database.sqlite;
    if (s == null || !s.volumeCreate) {
      log.detail('sqlite volume create skipped');
      return;
    }
    final name = s.volumeName ?? '${config.fly.app}_data';
    final fly = await _flyBin();
    log.detail(
        'ensure volume $name (${s.volumeSizeGb}GB) region ${config.fly.region}');
    // List volumes — if missing, create
    final list = await runner.runCapture(
      fly,
      ['volumes', 'list', '-a', config.fly.app, '--json'],
      allowDryRun: true,
    );
    if (!runner.dryRun && list.ok && list.stdout.contains(name)) {
      log.ok('volume $name exists');
      return;
    }
    await runner.run(fly, [
      'volumes',
      'create',
      name,
      '--size',
      '${s.volumeSizeGb}',
      '--region',
      config.fly.region,
      '-a',
      config.fly.app,
      '-y',
    ]);
    log.warn(
        'Add to fly.toml:\n[[mounts]]\n  source = "$name"\n  destination = "${s.volumeDest}"');
  }

  Future<void> _flyPostgres() async {
    final pg = config.database.flyPostgres;
    if (pg == null) return;
    final fly = await _flyBin();
    if (pg.create) {
      log.detail('ensure postgres app ${pg.app}');
      // create is interactive sometimes — use --vm-size shared-cpu-1x if available
      await runner.run(fly, [
        'postgres',
        'create',
        '--name',
        pg.app,
        '--region',
        config.fly.region,
        '--vm-size',
        'shared-cpu-1x',
        '--volume-size',
        '1',
        '--initial-cluster-size',
        '1',
      ]);
    }
    log.detail('attach ${pg.app} → ${config.fly.app}');
    await runner.run(fly, [
      'postgres',
      'attach',
      pg.app,
      '-a',
      config.fly.app,
    ]);
  }

  Future<void> _neon() async {
    final n = config.database.neon;
    if (n == null) return;
    if (n.provision) {
      final neon = await runner.resolve('neonctl', ['neon']);
      if (neon == null) throw StateError('neonctl required for provision');
      final project = n.projectName ?? config.name;
      log.detail('neon provision project $project');
      await runner.run(neon, [
        'projects',
        'create',
        '--name',
        project,
        '--region-id',
        n.region,
      ]);
      log.warn(_neonSecretHint(n.connectionStringSecret));
    } else {
      log.detail(_neonSecretHint(n.connectionStringSecret));
    }
  }

  String _neonSecretHint(String secret) {
    ensureHostsRegistered();
    final adapter = HostRegistry.require(config.host);
    return 'Neon: ${adapter.secretSetHint(secret, config)}';
  }
}
