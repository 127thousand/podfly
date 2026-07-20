# `podfly.yaml` reference

Created by `podfly init`, read by `deploy` / `smoke` / config-aware `doctor`.

Location: project root (walk-up from cwd also finds it).

## Top level

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `host` | `fly` \| `railway` \| `digitalocean` \| `render` \| … | `fly` | **API cloud** — **fly**, **railway**, and **digitalocean** deploy today. Others: doctor only. |
| `mode` | `split` \| `monolith` | `split` | Layout: CDN UI + API vs UI with API host. Alias: `fly` → monolith (legacy) |
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
| `web_service` | string | `web` | Static Flutter web service name |
| `web_port` | int | `80` | Domain port for nginx web |
| `web_public_host` | string | — | Filled after web domain |
| `enable_cdn` | bool | `true` | `railway cdn enable` on web service |
| `serverless` | bool | `true` | Railway Serverless for **api** + **web**. There is **no** `railway serverless` CLI flag; podfly enables it via (1) `sleepApplication` in `railway.toml` on deploy, and (2) GraphQL `serviceInstanceUpdate` using the CLI login token. Does not sleep Postgres. Set `false` to keep services warm. |

### `database.railway_postgres`

```yaml
database:
  provider: railway_postgres
  railway_postgres:
    service: Postgres
    create: true
    connection_string_secret: DATABASE_URL
```

Requires `host: railway`. Adds the Postgres plugin, wires `DATABASE_URL` onto the API service, patches `production.yaml` / `passwords.yaml` when vars are readable.

## `digitalocean`

Used when `host: digitalocean` (alias `do`).

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `app` | string | `name` | App Platform app name (API) |
| `region` | string | `nyc` | App Platform region slug |
| `registry` | string | from `doctl registry get` | DOCR registry name |
| `app_id` | string | — | Filled after first create |
| `web_app_id` | string | — | Separate web app id |
| `public_host` | string | — | e.g. `xxx.ondigitalocean.app` |
| `web_public_host` | string | — | Web app ingress host |
| `http_port` | int | `8080` | Serverpod listen port |
| `instance_size` | string | `basic-xxs` | App Platform instance size |
| `image_tag` | string | `latest` | Used when custom repo names are set |
| `api_repository` | string | `app` name | DOCR repository (Starter tier: **one repo**; tags `api`/`web`) |
| `web_repository` | string | same as API repo | Optional; defaults to shared repo |
| `spec_file` | string | `do-app.yaml` | Generated API app spec path |
| `platform` | string | `linux/amd64` | Docker build platform for DO |

Deploy needs **Docker** (local build) + **`doctl`** (auth or `DIGITALOCEAN_ACCESS_TOKEN`) + an existing **DOCR** registry (`doctl registry create … --subscription-tier starter`).

### `database.digitalocean_postgres`

```yaml
database:
  provider: digitalocean_postgres
  digitalocean_postgres:
    cluster_name: my-app-db
    create: true
    region: nyc1
    size: db-amd-1vcpu-1gb
    engine_version: "16"
```

Requires `host: digitalocean`. Creates/looks up Managed Postgres, writes `.podfly_do_pg.json`, patches Serverpod config (public host + SSL). After the App Platform app exists, trusts it via `doctl databases firewalls append … --rule app:<app-id>`.

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

On deploy, podfly ensures the API Fly app exists, creates/attaches Postgres, then writes
`*_server/config/.podfly_fly_pg.json` from the attach `DATABASE_URL` (app user/db + password)
and patches Serverpod `production.yaml` / `passwords.yaml`. Do not commit the sidecar.

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
| `static_dir` | string | `server/web/app` | Target for monolith mode copy into the server tree |

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
| `web` | Split: Pages URL; monolith: often same host as API |

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
