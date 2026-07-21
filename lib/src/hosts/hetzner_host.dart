import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../fly_name.dart';
import '../log.dart';
import '../tty.dart';
import 'adapter.dart';
import 'auth_helpers.dart';

/// Hetzner Cloud VPS — bind existing or create, then Docker over SSH.
///
/// Interactive (TTY): pick an existing server or create (location → type).
/// Non-interactive (`--yes`): requires bound `server_id`/`ipv4`/`server_name`
/// or `create: true` with optional location/type policy.
///
/// OS contract: Ubuntu (default image `ubuntu-24.04`). Docker is bootstrapped
/// over SSH when missing.
class HetznerHost extends HostAdapter {
  @override
  String get id => 'hetzner';

  @override
  String get label => 'Hetzner Cloud';

  @override
  List<String> get cliBinaries => const ['hcloud'];

  @override
  String get installHint =>
      'https://github.com/hetznercloud/cli#installation';

  @override
  List<String> get idAliases => const ['hcloud', 'hetzner_cloud'];

  @override
  List<CliInstallRecipe> get installRecipes => const [
        CliInstallRecipe(
          label: 'brew install hcloud',
          executable: 'brew',
          args: ['install', 'hcloud'],
        ),
      ];

  @override
  bool get canDeploy => true;

  @override
  AppHost get appHost => AppHost.hetzner;

  @override
  String get configKey => 'hetzner';

  @override
  List<DatabaseProvider> get supportedDatabases => const [
        DatabaseProvider.none,
        DatabaseProvider.neon,
      ];

  @override
  String defaultApiUrl({
    required String name,
    required String sanitizedName,
  }) =>
      'https://YOUR_HOSTNAME/';

  @override
  String? publicApiBase(PodflyConfig config) {
    final c = config.hetzner;
    if (c == null) return null;
    final h = c.publicHost ?? c.domain ?? c.ipv4;
    if (h == null || h.isEmpty) return null;
    if (h.startsWith('http')) {
      return h.endsWith('/') ? h : '$h/';
    }
    // Hostname (PTR or custom) with HTTPS edge
    if (c.https && !_looksLikeIpv4(h)) {
      return 'https://$h/';
    }
    // Raw IP fallback (HTTP on app port)
    final port = c.port;
    if (h.contains(':')) return 'http://$h/';
    return 'http://$h:$port/';
  }

  static bool _looksLikeIpv4(String h) =>
      RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(h);

  @override
  String secretSetHint(String secretName, PodflyConfig config) {
    final ip = config.hetzner?.ipv4 ?? '<ip>';
    return 'ssh root@$ip  # set $secretName in docker run -e or compose';
  }

  @override
  Future<bool> checkAuth(DoctorContext ctx) async {
    final bin = ctx.cliPath;
    if (ctx.dryRun) {
      ctx.log.ok('$bin  (auth check skipped in dry-run)');
      return true;
    }
    final r = await ctx.runner.runCapture(
      bin,
      ['location', 'list', '-o', 'json'],
      allowDryRun: false,
    );
    if (r.ok) {
      final ctxName = await ctx.runner.runCapture(
        bin,
        ['context', 'active'],
        allowDryRun: false,
      );
      final name = ctxName.stdout.trim();
      ctx.log.ok(
        '$bin  authenticated'
        '${name.isNotEmpty ? " (context $name)" : ""}',
      );
      return true;
    }
    return authViaWhoami(
      ctx: ctx,
      whoamiArgs: const ['location', 'list'],
      loginCommand: 'hcloud context create',
      loginArgs: const ['context', 'create', 'podfly'],
      failSubstrings: const [
        'unauthorized',
        'unauthenticated',
        'no context',
        'token',
        'forbidden',
      ],
    );
  }

  @override
  void configWarnings(PodflyConfig config, Log log) {
    log.detail(
      'Hetzner: bind/create VPS + Docker over SSH. No product FQDN — use PTR '
      'hostname or custom domain + Caddy HTTPS. Bill hourly; delete when done. '
      'See doc/hetzner.md.',
    );
  }

  @override
  Future<HostDeployResult> deployApi(DeployContext ctx) async {
    final config = ctx.config;
    final runner = ctx.runner;
    final log = ctx.log;
    final hcfg = config.hetzner ?? HetznerConfig();

    log.step('Deploy Hetzner Cloud VPS');

    final hcloud = await runner.resolve('hcloud');
    if (hcloud == null) throw StateError('hcloud not found — $installHint');

    final docker = await runner.resolve('docker');
    if (docker == null) {
      throw StateError(
        'docker not found — local build then transfer image over SSH',
      );
    }

    final bound = await _resolveServer(ctx, hcloud, hcfg);
    log.detail(
      'server ${bound.name} id=${bound.id} ${bound.ipv4} '
      '(${bound.serverType ?? "?"} @ ${bound.location ?? "?"})',
    );

    // Existing servers may also need a short SSH settle (reboots, etc.).
    await _waitSsh(ctx, user: hcfg.sshUser, ipv4: bound.ipv4);

    await _ensureRemoteDocker(
      ctx,
      user: hcfg.sshUser,
      ipv4: bound.ipv4,
    );

    final imageTag = DateTime.now().toUtc().millisecondsSinceEpoch.toString();
    final localImage = 'podfly-hetzner:${imageTag}';
    await _dockerBuild(ctx, docker: docker, image: localImage, platform: hcfg.platform);

    final remoteImage = 'podfly-app:$imageTag';
    await _transferImage(
      ctx,
      docker: docker,
      localImage: localImage,
      remoteImage: remoteImage,
      user: hcfg.sshUser,
      ipv4: bound.ipv4,
    );

    await _runContainer(
      ctx,
      user: hcfg.sshUser,
      ipv4: bound.ipv4,
      remoteImage: remoteImage,
      containerName: hcfg.containerName,
      hostPort: hcfg.port,
      // With Caddy, only loopback; plain HTTP publishes on all interfaces.
      localhostOnly: hcfg.https,
      env: {
        'runmode': 'production',
        'SERVERPOD_RUN_MODE': 'production',
        ...hcfg.extraEnv,
      },
    );

    // Public hostname: custom domain > Hetzner PTR > raw IP
    final dnsPtr = bound.dnsPtr ??
        await _fetchDnsPtr(ctx, hcloud, bound.id);
    final hostname = (hcfg.domain != null && hcfg.domain!.isNotEmpty)
        ? hcfg.domain!
        : (dnsPtr != null && dnsPtr.isNotEmpty ? dnsPtr : bound.ipv4);

    String url;
    if (hcfg.https && !_looksLikeIpv4(hostname)) {
      await _ensureCaddy(
        ctx,
        user: hcfg.sshUser,
        ipv4: bound.ipv4,
        hostname: hostname,
        upstreamPort: hcfg.port,
      );
      await ctx.patchPublicHosts(
        hostname,
        scheme: 'https',
        publicPort: 443,
      );
      url = 'https://$hostname';
    } else {
      if (hcfg.https && _looksLikeIpv4(hostname)) {
        log.warn(
          'https: true but no PTR/custom domain — serving plain HTTP on '
          ':${hcfg.port}. Set hetzner.domain or wait for dns_ptr.',
        );
      }
      await ctx.patchPublicHosts(
        bound.ipv4,
        scheme: 'http',
        publicPort: hcfg.port,
      );
      url = 'http://${bound.ipv4}:${hcfg.port}';
    }

    if (!runner.dryRun) {
      await _persist(
        ctx,
        hcfg,
        serverId: bound.id,
        serverName: bound.name,
        ipv4: bound.ipv4,
        location: bound.location ?? hcfg.location,
        serverType: bound.serverType ?? hcfg.serverType,
        publicHost: hostname,
        domain: hcfg.domain ?? dnsPtr,
      );
    }

    log.ok('Hetzner: $url');
    return HostDeployResult(
      publicHost: hostname,
      displayUrl: url,
    );
  }

  // ── Server resolve / create ───────────────────────────────────

  Future<_BoundServer> _resolveServer(
    DeployContext ctx,
    String hcloud,
    HetznerConfig hcfg,
  ) async {
    final log = ctx.log;
    if (ctx.runner.dryRun) {
      log.dry('resolve Hetzner server (bind or create)');
      return _BoundServer(
        id: hcfg.serverId ?? '0',
        name: hcfg.serverName ?? 'dry-run',
        ipv4: hcfg.ipv4 ?? '203.0.113.10',
        location: hcfg.location,
        serverType: hcfg.serverType,
      );
    }

    // Explicit bind
    if (hcfg.serverId != null && hcfg.serverId!.isNotEmpty) {
      return _describeServer(ctx, hcloud, hcfg.serverId!);
    }
    if (hcfg.ipv4 != null && hcfg.ipv4!.isNotEmpty) {
      final byIp = await _findServerByIpv4(ctx, hcloud, hcfg.ipv4!);
      if (byIp != null) return byIp;
      // IP known but not in project (external) — still deploy via SSH
      return _BoundServer(
        id: hcfg.serverId ?? '',
        name: hcfg.serverName ?? hcfg.ipv4!,
        ipv4: hcfg.ipv4!,
        location: hcfg.location,
        serverType: hcfg.serverType,
      );
    }
    if (hcfg.serverName != null && hcfg.serverName!.isNotEmpty) {
      final byName = await _findServerByName(ctx, hcloud, hcfg.serverName!);
      if (byName != null) return byName;
    }

    final interactive = isTty && !ctx.nonInteractive;
    if (interactive) {
      return _interactiveResolve(ctx, hcloud, hcfg);
    }

    // Non-interactive
    if (hcfg.create) {
      return _createServer(ctx, hcloud, hcfg, interactive: false);
    }
    throw StateError(
      'Hetzner server not bound. Set hetzner.server_id / ipv4 / server_name, '
      'or hetzner.create: true with --yes, or run interactively (no --yes).',
    );
  }

  Future<_BoundServer> _interactiveResolve(
    DeployContext ctx,
    String hcloud,
    HetznerConfig hcfg,
  ) async {
    final log = ctx.log;
    final servers = await _listServers(ctx, hcloud);
    final options = <String>[
      for (final s in servers)
        '${s.name}  ${s.status}  ${s.ipv4}  ${s.serverType ?? "?"}  ${s.location ?? "?"}',
      '＋ Create new server…',
    ];
    if (servers.isEmpty) {
      log.detail('No servers in this Hetzner project — create one');
      return _createServer(ctx, hcloud, hcfg, interactive: true);
    }
    final pick = await choose(
      'Hetzner target (existing or create):',
      options,
      defaultIndex: 0,
    );
    if (pick < servers.length) {
      return servers[pick];
    }
    return _createServer(ctx, hcloud, hcfg, interactive: true);
  }

  Future<_BoundServer> _createServer(
    DeployContext ctx,
    String hcloud,
    HetznerConfig hcfg, {
    required bool interactive,
  }) async {
    final log = ctx.log;
    final name = sanitizeFlyAppName(
      hcfg.serverName ?? ctx.config.name.replaceAll('_', '-'),
    );

    final location = await _pickLocation(
      ctx,
      hcloud,
      preferred: hcfg.location,
      interactive: interactive,
    );
    final type = await _pickServerType(
      ctx,
      hcloud,
      location: location,
      preferred: hcfg.serverType,
      minMemoryGb: hcfg.minMemoryGb,
      interactive: interactive,
    );
    final sshKey = await _pickSshKey(
      ctx,
      hcloud,
      preferred: hcfg.sshKey,
      interactive: interactive,
    );

    log.detail('creating server $name type=$type location=$location key=$sshKey');
    if (ctx.runner.dryRun) {
      log.dry('hcloud server create …');
      return _BoundServer(
        id: '0',
        name: name,
        ipv4: '203.0.113.10',
        location: location,
        serverType: type,
      );
    }

    final args = <String>[
      'server',
      'create',
      '--name',
      name,
      '--type',
      type,
      '--image',
      hcfg.image,
      '--location',
      location,
      '--ssh-key',
      sshKey,
      '--label',
      'podfly=1',
      '--label',
      'app=$name',
      '-o',
      'json',
    ];
    final r = await ctx.runner.runCapture(hcloud, args, allowDryRun: false);
    if (!r.ok) {
      throw StateError(
        'hcloud server create failed (exit ${r.exitCode}):\n'
        '${r.stderr}\n${r.stdout}',
      );
    }

    // create JSON may be server object or wrapper
    final created = _parseCreatedServer(r.stdout);
    // Wait for running + IP
    _BoundServer? ready;
    for (var i = 0; i < 60; i++) {
      final s = await _describeServer(ctx, hcloud, created);
      if (s.ipv4.isNotEmpty && s.status == 'running') {
        log.detail('server running ${s.ipv4}');
        ready = s;
        break;
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    if (ready == null) {
      throw StateError('server $created did not become running with IPv4');
    }
    await _waitSsh(ctx, user: hcfg.sshUser, ipv4: ready.ipv4);
    return ready;
  }

  /// Cloud-init / sshd can take 30–90s after "running".
  Future<void> _waitSsh(
    DeployContext ctx, {
    required String user,
    required String ipv4,
  }) async {
    final log = ctx.log;
    if (ctx.runner.dryRun) {
      log.dry('wait for ssh $user@$ipv4');
      return;
    }
    log.detail('waiting for SSH on $ipv4 …');
    for (var i = 0; i < 40; i++) {
      final r = await Process.run(
        'ssh',
        [
          ..._sshBaseArgs(),
          '-o',
          'ConnectionAttempts=1',
          '$user@$ipv4',
          'true',
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      if (r.exitCode == 0) {
        log.detail('SSH ready');
        return;
      }
      if (i % 5 == 0) {
        log.detail('SSH not ready yet (${i * 3}s)…');
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    throw StateError(
      'SSH to $user@$ipv4 not ready within timeout. '
      'Retry: podfly deploy (server may already exist).',
    );
  }

  Future<String> _pickLocation(
    DeployContext ctx,
    String hcloud, {
    String? preferred,
    required bool interactive,
  }) async {
    final list = await _jsonList(ctx, hcloud, ['location', 'list', '-o', 'json']);
    final names = <String>[];
    final labels = <String>[];
    for (final m in list) {
      final n = m['name']?.toString() ?? '';
      if (n.isEmpty) continue;
      names.add(n);
      final desc = m['description']?.toString() ?? '';
      final country = m['country']?.toString() ?? '';
      labels.add('$n  $desc  ($country)');
    }
    if (names.isEmpty) {
      throw StateError('hcloud location list returned no locations');
    }
    if (preferred != null && preferred.isNotEmpty) {
      if (names.contains(preferred)) return preferred;
      ctx.log.warn('location $preferred not in list — picking interactively/auto');
    }
    if (interactive) {
      final i = await choose('Location:', labels, defaultIndex: names.indexOf('hel1').clamp(0, names.length - 1));
      return names[i];
    }
    // Prefer EU cheap zone for demos
    for (final p in ['hel1', 'fsn1', 'nbg1', 'ash', 'hil', 'sin']) {
      if (names.contains(p)) return p;
    }
    return names.first;
  }

  Future<String> _pickServerType(
    DeployContext ctx,
    String hcloud, {
    required String location,
    String? preferred,
    required int minMemoryGb,
    required bool interactive,
  }) async {
    final list = await _jsonList(ctx, hcloud, ['server-type', 'list', '-o', 'json']);
    final candidates = <_TypeOffer>[];
    for (final m in list) {
      final name = m['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      if (m['deprecated'] == true) continue;
      final arch = m['architecture']?.toString() ?? 'x86';
      if (arch != 'x86') continue;
      final mem = (m['memory'] is num)
          ? (m['memory'] as num).toDouble()
          : double.tryParse('${m['memory']}') ?? 0;
      if (mem < minMemoryGb) continue;
      final prices = m['prices'];
      if (prices is! List) continue;
      double? monthly;
      for (final p in prices) {
        if (p is! Map) continue;
        if (p['location']?.toString() != location) continue;
        final pm = p['price_monthly'];
        if (pm is Map) {
          monthly = double.tryParse('${pm['gross'] ?? pm['net']}');
        }
        break;
      }
      if (monthly == null) continue; // not offered in location
      final cores = m['cores'] is num ? (m['cores'] as num).toInt() : 1;
      candidates.add(_TypeOffer(
        name: name,
        cores: cores,
        memoryGb: mem,
        monthly: monthly,
      ));
    }
    candidates.sort((a, b) {
      final c = a.monthly.compareTo(b.monthly);
      if (c != 0) return c;
      return a.cores.compareTo(b.cores);
    });
    if (candidates.isEmpty) {
      throw StateError(
        'No x86 server types with ≥${minMemoryGb}GB RAM in $location. '
        'Pick another location or set hetzner.server_type.',
      );
    }
    if (preferred != null && preferred.isNotEmpty) {
      final hit = candidates.where((c) => c.name == preferred).toList();
      if (hit.isNotEmpty) return hit.first.name;
      ctx.log.warn(
        'server_type $preferred not available in $location — picking from list',
      );
    }
    if (interactive) {
      final labels = [
        for (final c in candidates)
          '${c.name}  ${c.cores} vCPU  ${c.memoryGb}GB  '
              '~\$${c.monthly.toStringAsFixed(2)}/mo',
      ];
      final i = await choose(
        'Server type in $location:',
        labels,
        defaultIndex: 0,
      );
      return candidates[i].name;
    }
    return candidates.first.name;
  }

  Future<String> _pickSshKey(
    DeployContext ctx,
    String hcloud, {
    String? preferred,
    required bool interactive,
  }) async {
    final list = await _jsonList(ctx, hcloud, ['ssh-key', 'list', '-o', 'json']);
    if (list.isEmpty) {
      throw StateError(
        'No SSH keys in Hetzner project. Upload one:\n'
        '  hcloud ssh-key create --name mac --public-key-from-file ~/.ssh/id_ed25519.pub',
      );
    }
    final names = list.map((m) => m['name']?.toString() ?? '').where((n) => n.isNotEmpty).toList();
    if (preferred != null && preferred.isNotEmpty && names.contains(preferred)) {
      return preferred;
    }
    if (interactive && names.length > 1) {
      final i = await choose('SSH key:', names, defaultIndex: 0);
      return names[i];
    }
    return names.first;
  }

  // ── hcloud helpers ────────────────────────────────────────────

  Future<List<_BoundServer>> _listServers(DeployContext ctx, String hcloud) async {
    final list = await _jsonList(ctx, hcloud, ['server', 'list', '-o', 'json']);
    return list.map(_serverFromJson).whereType<_BoundServer>().toList();
  }

  Future<_BoundServer?> _findServerByName(
    DeployContext ctx,
    String hcloud,
    String name,
  ) async {
    final all = await _listServers(ctx, hcloud);
    for (final s in all) {
      if (s.name == name) return s;
    }
    return null;
  }

  Future<_BoundServer?> _findServerByIpv4(
    DeployContext ctx,
    String hcloud,
    String ip,
  ) async {
    final all = await _listServers(ctx, hcloud);
    for (final s in all) {
      if (s.ipv4 == ip) return s;
    }
    return null;
  }

  Future<_BoundServer> _describeServer(
    DeployContext ctx,
    String hcloud,
    String idOrName,
  ) async {
    final r = await ctx.runner.runCapture(
      hcloud,
      ['server', 'describe', idOrName, '-o', 'json'],
      allowDryRun: false,
    );
    if (!r.ok) {
      throw StateError('hcloud server describe $idOrName failed');
    }
    final m = jsonDecode(r.stdout);
    if (m is! Map<String, dynamic>) {
      throw StateError('unexpected server describe JSON');
    }
    final s = _serverFromJson(m);
    if (s == null) throw StateError('could not parse server $idOrName');
    return s;
  }

  String _parseCreatedServer(String raw) {
    try {
      final d = jsonDecode(raw);
      if (d is Map) {
        if (d['server'] is Map) {
          return '${(d['server'] as Map)['id']}';
        }
        if (d['id'] != null) return '${d['id']}';
      }
    } catch (_) {}
    // Fallback: parse "Server 123 created"
    final m = RegExp(r'Server\s+(\d+)').firstMatch(raw);
    if (m != null) return m.group(1)!;
    throw StateError('could not parse server create output: $raw');
  }

  _BoundServer? _serverFromJson(Map<dynamic, dynamic> m) {
    final id = m['id']?.toString();
    final name = m['name']?.toString();
    if (id == null || name == null) return null;
    String ipv4 = '';
    String? dnsPtr;
    final pub = m['public_net'];
    if (pub is Map) {
      final v4 = pub['ipv4'];
      if (v4 is Map) {
        ipv4 = v4['ip']?.toString() ?? '';
        dnsPtr = v4['dns_ptr']?.toString();
        if (dnsPtr != null && dnsPtr.isEmpty) dnsPtr = null;
      }
    }
    String? location;
    // Prefer top-level location (newer API); fall back to datacenter.location
    final locTop = m['location'];
    if (locTop is Map) {
      location = locTop['name']?.toString();
    }
    final dc = m['datacenter'];
    if (location == null && dc is Map) {
      final loc = dc['location'];
      if (loc is Map) location = loc['name']?.toString();
    }
    String? serverType;
    final st = m['server_type'];
    if (st is Map) serverType = st['name']?.toString();
    return _BoundServer(
      id: id,
      name: name,
      ipv4: ipv4,
      status: m['status']?.toString() ?? '',
      location: location,
      serverType: serverType,
      dnsPtr: dnsPtr,
    );
  }

  Future<List<Map<String, dynamic>>> _jsonList(
    DeployContext ctx,
    String hcloud,
    List<String> args,
  ) async {
    final r = await ctx.runner.runCapture(hcloud, args, allowDryRun: false);
    if (!r.ok) {
      throw StateError('hcloud ${args.join(' ')} failed');
    }
    try {
      final d = jsonDecode(r.stdout);
      if (d is List) {
        return d.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      }
    } catch (_) {}
    return [];
  }

  // ── SSH + Docker ──────────────────────────────────────────────

  Future<void> _ensureRemoteDocker(
    DeployContext ctx, {
    required String user,
    required String ipv4,
  }) async {
    final log = ctx.log;
    if (ctx.runner.dryRun) {
      log.dry('ssh $user@$ipv4 ensure docker');
      return;
    }
    log.detail('checking docker on $ipv4 …');
    final check = await _ssh(
      user: user,
      ipv4: ipv4,
      command: 'docker version --format "{{.Server.Version}}" 2>/dev/null || echo MISSING',
    );
    if (check.contains('MISSING') || check.trim().isEmpty) {
      log.detail('installing Docker on $ipv4 (Ubuntu)…');
      // Official convenience script; idempotent enough for demos
      final install = await _ssh(
        user: user,
        ipv4: ipv4,
        command: r'''
set -e
export DEBIAN_FRONTEND=noninteractive
if command -v docker >/dev/null 2>&1; then exit 0; fi
apt-get update -qq
apt-get install -y -qq ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker
''',
      );
      if (install.toLowerCase().contains('error') &&
          !install.contains('docker')) {
        // soft: recheck
      }
      final recheck = await _ssh(
        user: user,
        ipv4: ipv4,
        command: 'docker version --format "{{.Server.Version}}"',
      );
      if (recheck.trim().isEmpty) {
        throw StateError(
          'Docker install on $ipv4 failed. SSH in and install docker manually.',
        );
      }
      log.detail('Docker ${recheck.trim()} installed');
    } else {
      log.detail('Docker ${check.trim()} present');
    }
  }

  Future<void> _dockerBuild(
    DeployContext ctx, {
    required String docker,
    required String image,
    required String platform,
  }) async {
    final config = ctx.config;
    final runner = ctx.runner;
    final log = ctx.log;
    final rootDocker = File(p.join(config.root, 'Dockerfile'));
    final serverDocker = File(p.join(config.root, config.server, 'Dockerfile'));
    final df = await rootDocker.exists()
        ? 'Dockerfile'
        : (await serverDocker.exists()
            ? p.join(config.server, 'Dockerfile')
            : 'Dockerfile');

    if (runner.dryRun) {
      log.dry('docker build --platform $platform -t $image -f $df .');
      return;
    }
    log.detail('docker build $image ($platform)');
    final build = await runner.run(
      docker,
      [
        'build',
        '--platform',
        platform,
        '-t',
        image,
        '-f',
        df,
        '.',
      ],
      workingDirectory: config.root,
      allowDryRun: false,
    );
    if (!build.ok) {
      throw StateError('docker build failed (exit ${build.exitCode})');
    }
  }

  Future<void> _transferImage(
    DeployContext ctx, {
    required String docker,
    required String localImage,
    required String remoteImage,
    required String user,
    required String ipv4,
  }) async {
    final log = ctx.log;
    if (ctx.runner.dryRun) {
      log.dry('docker save $localImage | ssh docker load');
      return;
    }
    log.detail('transfer image → $ipv4 ($remoteImage)');
    // Tag remote name locally then save
    final tag = await ctx.runner.run(
      docker,
      ['tag', localImage, remoteImage],
      allowDryRun: false,
    );
    if (!tag.ok) {
      throw StateError('docker tag failed');
    }
    final save = await Process.start(
      docker,
      ['save', remoteImage],
    );
    final ssh = await Process.start(
      'ssh',
      [
        ..._sshBaseArgs(),
        '$user@$ipv4',
        'docker load',
      ],
    );
    await save.stdout.pipe(ssh.stdin);
    final saveErr = await save.stderr.transform(utf8.decoder).join();
    final sshErr = await ssh.stderr.transform(utf8.decoder).join();
    final saveCode = await save.exitCode;
    final sshCode = await ssh.exitCode;
    if (saveCode != 0 || sshCode != 0) {
      throw StateError(
        'image transfer failed (save=$saveCode ssh=$sshCode)\n$saveErr\n$sshErr',
      );
    }
    log.detail('image loaded on $ipv4');
  }

  Future<void> _runContainer(
    DeployContext ctx, {
    required String user,
    required String ipv4,
    required String remoteImage,
    required String containerName,
    required int hostPort,
    required bool localhostOnly,
    required Map<String, String> env,
  }) async {
    final log = ctx.log;
    if (ctx.runner.dryRun) {
      log.dry('ssh docker run $remoteImage');
      return;
    }
    final envFlags = env.entries.map((e) => "-e ${e.key}=${e.value}").join(' ');
    // Bind app to localhost only when Caddy terminates TLS publicly.
    final publish =
        localhostOnly ? '127.0.0.1:$hostPort:8080' : '$hostPort:8080';
    final script = '''
set -e
docker rm -f $containerName 2>/dev/null || true
docker run -d --name $containerName --restart unless-stopped \\
  -p $publish $envFlags $remoteImage
docker ps --filter name=$containerName --format '{{.Status}}'
''';
    final out = await _ssh(user: user, ipv4: ipv4, command: script);
    log.detail('container: ${out.trim().split('\n').last}');
  }

  /// Caddy reverse proxy + automatic HTTPS (Let's Encrypt) on :443.
  Future<void> _ensureCaddy(
    DeployContext ctx, {
    required String user,
    required String ipv4,
    required String hostname,
    required int upstreamPort,
  }) async {
    final log = ctx.log;
    if (ctx.runner.dryRun) {
      log.dry('install Caddy for https://$hostname → :$upstreamPort');
      return;
    }
    log.detail('Caddy HTTPS for $hostname → 127.0.0.1:$upstreamPort');
    final host = hostname.trim();
    // Unquoted heredoc so $host / port expand on the remote shell.
    final script = '''
set -e
export DEBIAN_FRONTEND=noninteractive
if ! command -v caddy >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl gnupg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  apt-get update -qq
  apt-get install -y -qq caddy
fi
mkdir -p /etc/caddy
cat > /etc/caddy/Caddyfile <<EOF
$host {
	reverse_proxy 127.0.0.1:$upstreamPort
}
EOF
systemctl enable --now caddy
caddy validate --config /etc/caddy/Caddyfile
systemctl reload caddy || systemctl restart caddy
for i in \$(seq 1 45); do
  if ss -lnt 2>/dev/null | grep -q ':443 ' || ss -lnt 2>/dev/null | grep -q ':443\$'; then
    echo caddy_443_up
    break
  fi
  sleep 2
done
''';
    await _ssh(user: user, ipv4: ipv4, command: script);
    // Give Let's Encrypt a moment; first request may still race
    await Future<void>.delayed(const Duration(seconds: 5));
    log.detail('Caddy configured for https://$host/');
  }

  Future<String?> _fetchDnsPtr(
    DeployContext ctx,
    String hcloud,
    String serverId,
  ) async {
    if (serverId.isEmpty || ctx.runner.dryRun) return null;
    try {
      final s = await _describeServer(ctx, hcloud, serverId);
      return s.dnsPtr;
    } catch (_) {
      return null;
    }
  }

  List<String> _sshBaseArgs() => const [
        '-o',
        'BatchMode=yes',
        '-o',
        'StrictHostKeyChecking=accept-new',
        '-o',
        'ConnectTimeout=30',
      ];

  Future<String> _ssh({
    required String user,
    required String ipv4,
    required String command,
  }) async {
    final r = await Process.run(
      'ssh',
      [..._sshBaseArgs(), '$user@$ipv4', command],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (r.exitCode != 0) {
      final err = '${r.stderr}\n${r.stdout}'.trim();
      throw StateError('ssh $user@$ipv4 failed (exit ${r.exitCode}): $err');
    }
    return r.stdout as String;
  }

  Future<void> _persist(
    DeployContext ctx,
    HetznerConfig base, {
    required String serverId,
    required String serverName,
    required String ipv4,
    String? location,
    String? serverType,
    required String publicHost,
    String? domain,
  }) async {
    final cfg = ctx.config;
    final port = base.port;
    final apiUrl = base.https && !_looksLikeIpv4(publicHost)
        ? 'https://$publicHost/'
        : 'http://$ipv4:$port/';
    final updated = PodflyConfig(
      root: cfg.root,
      host: cfg.host,
      mode: cfg.mode,
      name: cfg.name,
      server: cfg.server,
      flutter: cfg.flutter,
      fly: cfg.fly,
      railway: cfg.railway,
      digitalOcean: cfg.digitalOcean,
      render: cfg.render,
      cloudRun: cfg.cloudRun,
      aws: cfg.aws,
      awsEcs: cfg.awsEcs,
      azure: cfg.azure,
      hetzner: HetznerConfig(
        serverName: serverName,
        serverId: serverId,
        ipv4: ipv4,
        location: location ?? base.location,
        serverType: serverType ?? base.serverType,
        image: base.image,
        sshKey: base.sshKey,
        sshUser: base.sshUser,
        containerName: base.containerName,
        port: port,
        platform: base.platform,
        create: base.create,
        minMemoryGb: base.minMemoryGb,
        https: base.https,
        domain: domain ?? base.domain,
        extraEnv: base.extraEnv,
        publicHost: publicHost,
      ),
      cloudflare: cfg.cloudflare,
      database: cfg.database,
      web: WebConfig(
        enabled: cfg.web.enabled,
        serverUrlDefine: cfg.web.serverUrlDefine,
        apiUrl: apiUrl,
        patchBootstrap: cfg.web.patchBootstrap,
        writeHeaders: cfg.web.writeHeaders,
        baseHref: cfg.web.baseHref,
        staticDir: cfg.web.staticDir,
      ),
      smoke: cfg.smoke,
    );
    await updated.save();
    ctx.log.detail('saved hetzner.server_id + public_host');
  }
}

class _BoundServer {
  _BoundServer({
    required this.id,
    required this.name,
    required this.ipv4,
    this.status = '',
    this.location,
    this.serverType,
    this.dnsPtr,
  });

  final String id;
  final String name;
  final String ipv4;
  final String status;
  final String? location;
  final String? serverType;
  /// Reverse DNS on primary IPv4 (e.g. static.…clients.your-server.de).
  final String? dnsPtr;
}

class _TypeOffer {
  _TypeOffer({
    required this.name,
    required this.cores,
    required this.memoryGb,
    required this.monthly,
  });

  final String name;
  final int cores;
  final double memoryGb;
  final double monthly;
}
