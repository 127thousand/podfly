# Host adapter registry

## Goal

Stop hardcoding Fly/Railway/etc. in `doctor`, `deploy`, `init`, and `database/ensure`. Adding a host should mean one new file + register.

## Design

```text
lib/src/hosts/
  adapter.dart       # HostAdapter, HostRegistry, contexts
  hosts.dart         # ensureHostsRegistered() bootstrap
  fly_host.dart
  railway_host.dart
  planned_host.dart  # roadmap stubs (CLI + doctor only)
  public_host_patch.dart
  auth_helpers.dart
```

`HostAdapter` owns: id, CLI, auth check, deploy API, default API URL, secret-set hint, supported DBs, all-in-one web flag.

`HostRegistry` maps `AppHost` / yaml id → adapter. Aliases (e.g. `gcp` → cloud_run) live on the adapter.

Orchestrators stay host-agnostic:

- **Deployer** → `adapter.deployApi(DeployContext)`
- **Doctor** → `adapter.checkAuth(DoctorContext)`
- **Initer** → `HostRegistry.all` for menu + `supportedDatabases`

## Adding a host

1. Implement `HostAdapter` (or extend `PlannedHost` until deploy is ready).
2. Register in `ensureHostsRegistered()`.
3. No new `switch (host)` in doctor/deploy/init.

## YAML

Unchanged: `host: fly` + `fly:` / `railway:` blocks. Typed `FlyConfig` / `RailwayConfig` remain for host-specific fields; adapters read them from `PodflyConfig`.
