import '../config.dart';
import 'adapter.dart';
import 'auth_helpers.dart';

/// Roadmap host: doctor can check CLI; deploy throws until implemented.
class PlannedHost extends HostAdapter {
  PlannedHost({
    required this.id,
    required this.label,
    required this.cliBinaries,
    required this.installHint,
    required this.appHost,
    this.auth = PlannedAuth.presentOnly,
    this.checkArgs = const [],
    this.loginHint = '',
    List<String>? aliases,
  }) : _aliases = aliases ?? const [];

  @override
  final String id;
  @override
  final String label;
  @override
  final List<String> cliBinaries;
  @override
  final String installHint;
  @override
  final AppHost appHost;

  final PlannedAuth auth;
  final List<String> checkArgs;
  final String loginHint;
  final List<String> _aliases;

  @override
  List<String> get idAliases => _aliases;

  @override
  bool get canDeploy => false;

  @override
  String get configKey => id;

  @override
  String defaultApiUrl({
    required String name,
    required String sanitizedName,
  }) =>
      'https://REPLACE.example/';

  @override
  String? publicApiBase(PodflyConfig config) => null;

  @override
  String secretSetHint(String secretName, PodflyConfig config) =>
      'set $secretName on $label';

  @override
  Future<bool> checkAuth(DoctorContext ctx) async {
    switch (auth) {
      case PlannedAuth.presentOnly:
        return authPresentOnly(ctx, note: loginHint.isEmpty ? null : loginHint);
      case PlannedAuth.command:
        return authViaCommand(
          ctx: ctx,
          checkArgs: checkArgs,
          loginHint: loginHint,
        );
    }
  }

  @override
  Future<HostDeployResult> deployApi(DeployContext ctx) {
    throw StateError(
      '$label is not implemented in podfly yet (roadmap). '
      'Set host: fly or host: railway, or implement HostAdapter for $id. '
      'See README provider table.',
    );
  }
}

enum PlannedAuth { presentOnly, command }
