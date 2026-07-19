import '../config.dart';
import '../log.dart';
import '../process_runner.dart';

/// One cloud that can run the Serverpod API.
///
/// Add a new host by implementing this class and registering it in
/// [HostRegistry] — do not add `switch (host)` in doctor/deploy/init.
abstract class HostAdapter {
  /// YAML `host:` value, e.g. `fly`, `railway`.
  String get id;

  String get label;

  /// CLI binaries (first found wins).
  List<String> get cliBinaries;

  String get installHint;

  /// When true, [deployApi] is implemented.
  bool get canDeploy;

  /// Matching [AppHost] enum value (config still uses the enum).
  AppHost get appHost;

  /// YAML block key for this host (`fly`, `railway`, …).
  String get configKey;

  /// Extra YAML aliases (e.g. `gcp` → `cloud_run`).
  List<String> get idAliases => const [];

  /// Hosts that fit multi-port / static web on the same machine.
  bool get supportsAllInOneWeb => false;

  /// Database providers this host can automate (or sensibly pair with).
  List<DatabaseProvider> get supportedDatabases => const [
        DatabaseProvider.none,
        DatabaseProvider.neon,
      ];

  /// Placeholder / known API base before first deploy (trailing slash).
  String defaultApiUrl({required String name, required String sanitizedName});

  /// Best public API base from current config (trailing slash), or null.
  String? publicApiBase(PodflyConfig config);

  /// How to set a secret (e.g. Neon DATABASE_URL) on this host.
  String secretSetHint(String secretName, PodflyConfig config);

  /// Doctor: CLI is already resolved; verify auth (may prompt login).
  Future<bool> checkAuth(DoctorContext ctx);

  /// Deploy the API container. May update podfly.yaml / production.yaml.
  Future<HostDeployResult> deployApi(DeployContext ctx);

  /// Optional host-specific config warnings during doctor.
  void configWarnings(PodflyConfig config, Log log) {} // ignore: avoid_types_on_closure_parameters
}

class DoctorContext {
  DoctorContext({
    required this.runner,
    required this.log,
    required this.cliPath,
    required this.canLogin,
    required this.autoLogin,
  });

  final ProcessRunner runner;
  final Log log;
  final String cliPath;
  final bool canLogin;
  final bool autoLogin;

  bool get dryRun => runner.dryRun;
}

class DeployContext {
  DeployContext({
    required this.config,
    required this.runner,
    required this.log,
    required this.patchPublicHosts,
  });

  final PodflyConfig config;
  final ProcessRunner runner;
  final Log log;

  /// Patch Serverpod production publicHost/publicScheme/publicPort.
  final Future<void> Function(String bareHost) patchPublicHosts;
}

class HostDeployResult {
  HostDeployResult({this.publicHost, this.displayUrl});

  /// Bare hostname if known (e.g. `app.fly.dev`).
  final String? publicHost;

  /// Human-facing URL for logs (with or without scheme).
  final String? displayUrl;
}

/// Global registry of API hosts. New providers register here once.
class HostRegistry {
  HostRegistry._();

  static final Map<String, HostAdapter> _byId = {};
  static final Map<AppHost, HostAdapter> _byEnum = {};
  static bool _bootstrapped = false;

  static void register(HostAdapter adapter) {
    _byId[adapter.id] = adapter;
    for (final alias in adapter.idAliases) {
      _byId[alias] = adapter;
    }
    _byEnum[adapter.appHost] = adapter;
  }

  static void bootstrap(List<HostAdapter> adapters) {
    if (_bootstrapped) return;
    for (final a in adapters) {
      register(a);
    }
    _bootstrapped = true;
  }

  static HostAdapter require(AppHost host) {
    _assertReady();
    final a = _byEnum[host];
    if (a == null) {
      throw StateError('No HostAdapter registered for $host');
    }
    return a;
  }

  static HostAdapter requireId(String id) {
    _assertReady();
    final a = _byId[id];
    if (a == null) {
      throw FormatException('Unknown host/provider: $id');
    }
    return a;
  }

  static HostAdapter? tryId(String? id) {
    if (id == null) return null;
    _assertReady();
    return _byId[id];
  }

  static List<HostAdapter> get all {
    _assertReady();
    // Unique by enum order
    final seen = <AppHost>{};
    final out = <HostAdapter>[];
    for (final a in _byEnum.values) {
      if (seen.add(a.appHost)) out.add(a);
    }
    return out;
  }

  static List<String> get cliAllowedIds {
    _assertReady();
    return all.map((a) => a.id).toList();
  }

  static void _assertReady() {
    if (!_bootstrapped) {
      throw StateError(
        'HostRegistry not bootstrapped — call ensureHostsRegistered()',
      );
    }
  }
}
