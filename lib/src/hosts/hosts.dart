import '../config.dart';
import 'adapter.dart';
import 'aws_host.dart';
import 'cloud_run_host.dart';
import 'digitalocean_host.dart';
import 'fly_host.dart';
import 'planned_host.dart';
import 'railway_host.dart';
import 'render_host.dart';

export 'adapter.dart';
export 'public_host_patch.dart';

bool _done = false;

/// Register all built-in hosts. Safe to call multiple times.
void ensureHostsRegistered() {
  if (_done) return;
  _done = true;
  HostRegistry.bootstrap([
    FlyHost(),
    RailwayHost(),
    DigitalOceanHost(),
    RenderHost(),
    CloudRunHost(),
    AwsHost(),
    PlannedHost(
      id: 'azure',
      label: 'Azure Container Apps',
      cliBinaries: const ['az'],
      installHint:
          'https://learn.microsoft.com/cli/azure/install-azure-cli',
      appHost: AppHost.azure,
      auth: PlannedAuth.command,
      checkArgs: const ['account', 'show'],
      loginHint: 'az login',
    ),
  ]);
}
