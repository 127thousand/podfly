import '../config.dart';
import 'adapter.dart';
import 'fly_host.dart';
import 'planned_host.dart';
import 'railway_host.dart';

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
    PlannedHost(
      id: 'render',
      label: 'Render',
      cliBinaries: const ['render'],
      installHint: 'https://render.com/docs/cli',
      appHost: AppHost.render,
      auth: PlannedAuth.presentOnly,
      loginHint: 'auth via RENDER_API_KEY / login',
    ),
    PlannedHost(
      id: 'cloud_run',
      label: 'Google Cloud Run',
      cliBinaries: const ['gcloud'],
      installHint: 'https://cloud.google.com/sdk/docs/install',
      appHost: AppHost.cloudRun,
      aliases: const ['cloudrun', 'gcp', 'google'],
      auth: PlannedAuth.command,
      checkArgs: const ['auth', 'list'],
      loginHint: 'gcloud auth login',
    ),
    PlannedHost(
      id: 'aws',
      label: 'AWS (App Runner / ECS)',
      cliBinaries: const ['aws'],
      installHint: 'https://docs.aws.amazon.com/cli/',
      appHost: AppHost.aws,
      auth: PlannedAuth.command,
      checkArgs: const ['sts', 'get-caller-identity'],
      loginHint: 'aws configure / SSO',
    ),
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
    PlannedHost(
      id: 'digitalocean',
      label: 'DigitalOcean App Platform',
      cliBinaries: const ['doctl'],
      installHint: 'https://docs.digitalocean.com/reference/doctl/',
      appHost: AppHost.digitalOcean,
      aliases: const ['do'],
      auth: PlannedAuth.command,
      checkArgs: const ['account', 'get'],
      loginHint: 'doctl auth init',
    ),
  ]);
}
