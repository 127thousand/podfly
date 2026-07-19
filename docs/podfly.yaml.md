# `podfly.yaml` reference

Created by `podfly init`, read by `deploy` / `smoke` / config-aware `doctor`.

Location: project root (walk-up from cwd also finds it).

## Top level

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `host` | `fly` \| `railway` \| `render` \| `cloud_run` \| `aws` \| `azure` \| `digitalocean` | `fly` | **API cloud** — `fly` and `railway` deploy today |
| `mode` | `split` \| `fly` | `split` | Layout: Pages UI + API host vs all-on-API-host (Fly) |
| `name` | string | directory name | Default for app + Pages project names |
| `server` | string | discovered `*_server` | Path relative to root |
| `flutter` | string | discovered `*_flutter` | Path relative to root |

## `fly`

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `app` | string | `name` | Fly app name |
| `region` | string | `iad` | Primary region |
| `config` | string | `fly.toml` | Path to fly.toml |
| `scale_to_zero` | bool | `true` | Documented intent (fly.toml min machines) |
| `ha` | bool | `false` | When false, deploy with `--ha=false` |

## `railway`

Used when `host: railway`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `project` | string | `name` | Railway project name (created if unlinked) |
| `service` | string | `api` | Service name for the Serverpod API |
| `environment` | string | `production` | Environment to link/deploy |
| `project_id` | string | — | Optional UUID to `railway link` instead of create |
| `port` | int | `8080` | Internal port for `railway domain --port` (Serverpod API) |
| `config` | string | `railway.toml` | Config-as-code with `dockerfilePath` to `*_server/Dockerfile` |
| `public_host` | string | — | e.g. `xxx.up.railway.app` (filled after first domain) |

## `cloudflare` (split only)

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `project` | string | `name` | Pages project name |
| `branch` | string | `main` | Production branch for deploy |

## `database`

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `provider` | `none` \| `sqlite` \| `fly_postgres` \| `neon` | `none` | See [database.md](database.md) |

### `database.sqlite`

```yaml
database:
  provider: sqlite
  sqlite:
    path: /data/serverpod.db
    volume:
      create: true
      name: my-app_data
      size_gb: 1
      dest: /data
```

### `database.fly_postgres`

```yaml
database:
  provider: fly_postgres
  fly_postgres:
    app: my-app-db
    create: true
```

### `database.neon`

```yaml
database:
  provider: neon
  neon:
    connection_string_secret: DATABASE_URL
    provision: false
    project_name: my-app
    region: aws-us-east-1
    host: ep-xxx.us-east-1.aws.neon.tech   # optional if known
    database: neondb
    user: neondb_owner
```

## `web`

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | `true` (inferred at init) | When `false`, skip Flutter web build and Pages — API only (mobile) |
| `server_url_define` | string | `SERVER_URL` | `--dart-define` name for API URL |
| `api_url` | string | `https://<fly.app>.fly.dev/` | Trailing slash normalized |
| `patch_bootstrap` | bool | `true` | Install podfly Flutter bootstrap if missing |
| `write_headers` | bool | `true` | Install Pages `_headers` / `_redirects` if missing |
| `base_href` | string | `/` | `flutter build web --base-href` |
| `static_dir` | string | `server/web/app` | Target for mono `fly` mode copy |

See [caching.md](caching.md) for bootstrap and header semantics.

## `smoke`

```yaml
smoke:
  api:
    method: POST          # GET or POST
    path: /my/endpoint
    body: '{}'            # POST body
    expect_status: 200
  web:
    path: /
    expect_status: 200
```

| Key | Description |
|-----|-------------|
| `api` | Checked against `web.api_url` |
| `web` | Split: Pages URL; fly mode: often same host as API |

Omit `smoke:` if you do not use `--smoke` / `podfly smoke`.

## Full example (split + Neon)

```yaml
mode: split
name: my-app
server: my_app_server
flutter: my_app_flutter

fly:
  app: my-app
  region: iad
  config: fly.toml
  scale_to_zero: true
  ha: false

cloudflare:
  project: my-app
  branch: main

database:
  provider: neon
  neon:
    connection_string_secret: DATABASE_URL
    provision: false
    region: aws-us-east-1

web:
  server_url_define: SERVER_URL
  api_url: https://my-app.fly.dev/
  patch_bootstrap: true
  write_headers: true
  base_href: /

smoke:
  api:
    method: GET
    path: /
    expect_status: 200
  web:
    path: /
    expect_status: 200
```
