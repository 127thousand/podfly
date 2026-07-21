# `podfly.yaml` reference

Created by `podfly init`, read by `deploy` / `smoke` / config-aware `doctor`.

Location: project root (walk-up from cwd also finds it).

## Top level

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `host` | `fly` \| `railway` \| `digitalocean` \| `render` \| `cloud_run` \| `aws` \| `aws_ecs` \| `azure` \| … | `fly` | **API cloud** — fly, railway, digitalocean, render, cloud_run, aws, aws_ecs, azure deploy today. |
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

## `aws`

Used when `host: aws` (aliases `apprunner`, `app_runner`, `amazon`).

Deploys **App Runner**: local `docker build` (`linux/amd64`) → ECR → `create-service` /
`update-service`. Requires Docker + `aws` CLI.

**Deep notes (WebSockets, teardown, knobs):** [aws.md](aws.md).

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `service` | string | `name` | App Runner service name |
| `region` | string | `us-east-1` | AWS region |
| `cpu` | string | `1024` | CPU units (`256`…`4096`) |
| `memory` | string | `2048` | Memory MB (must pair with cpu) |
| `port` | int | `8080` | Container port |
| `ecr_repository` | string | service name | ECR repo (created if missing) |
| `ecr_access_role` | string | `AppRunnerECRAccessRole` | IAM role for ECR pull (created if missing) |
| `image_tag` | string | `latest` | If `latest`, podfly uses a timestamp tag each deploy |
| `platform` | string | `linux/amd64` | Docker build platform |
| `start_command` | string | `/app/entrypoint.sh` | App Runner StartCommand (prefer over shell ENTRYPOINT) |
| `ecr_public` | bool | `false` | Push to **ECR Public** + `ECR_PUBLIC` (more reliable CREATE on some accounts) |
| `service_arn` | string | — | Filled after first create |
| `env` | map | — | Extra runtime env vars |
| `public_host` | string | — | Filled after first deploy |

### WebSockets (App Runner)

**Not supported.** The managed edge (Envoy) returns **403** on `Upgrade: websocket`
before traffic reaches the container. There is no customer Envoy/WS config. HTTP RPC
and static UI work; Serverpod streams do not. For AWS + streams use **`host: aws_ecs`**
([below](#aws_ecs)).

Examples:

- [api_only](https://github.com/127thousand/podfly_examples/tree/main/aws/api_only) — RPC  
- [realtime_monolith](https://github.com/127thousand/podfly_examples/tree/main/aws/realtime_monolith) — UI + RPC; streams blocked at edge  
- Streams: [ecs_realtime](https://github.com/127thousand/podfly_examples/tree/main/aws/ecs_realtime) (`host: aws_ecs`)

## `aws_ecs`

Used when `host: aws_ecs` (aliases `ecs`, `fargate`).

**ECS Fargate + Application Load Balancer** — WebSocket-capable AWS path for Serverpod
streams. CLI-only (no CDK). Docker → private ECR → task definition → Fargate service
behind an internet-facing ALB (HTTP :80 for demos; idle timeout default **3600s**).

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `service` | string | `name` | ECS service + ALB name base |
| `region` | string | `us-east-1` | AWS region |
| `cluster` | string | service name | ECS cluster |
| `cpu` | string | `512` | Fargate CPU units |
| `memory` | string | `1024` | Fargate memory (MB) |
| `port` | int | `8080` | Container port (nginx monolith) |
| `desired_count` | int | `1` | Running tasks |
| `idle_timeout_seconds` | int | `3600` | ALB idle timeout (streams) |
| `stickiness` | bool | `true` | LB cookie stickiness |
| `assign_public_ip` | bool | `true` | Tasks get public IP (no NAT needed) |
| `execution_role` | string | `podflyEcsTaskExecutionRole` | Task execution IAM role |
| `log_group` | string | `/ecs/<service>` | CloudWatch log group |
| `vpc_id` / `subnet_ids` | — | default VPC | Optional overrides |
| `public_host` | string | — | ALB DNS after deploy |
| `load_balancer_arn` / `target_group_arn` | string | — | Filled after deploy |

Example: [aws/ecs_realtime](https://github.com/127thousand/podfly_examples/tree/main/aws/ecs_realtime).  
Design notes: [specs/2026-07-21-aws-ecs-realtime-sketch.md](specs/2026-07-21-aws-ecs-realtime-sketch.md).

## `azure`

Used when `host: azure` (aliases `aca`, `containerapps`, `container_apps`).

Deploys **Azure Container Apps**: local `docker build` (`linux/amd64`) → **ACR** →
managed environment + container app (external HTTPS ingress). Requires Docker + `az` CLI
(+ `containerapp` extension).

**Deep notes (teardown, WebSockets):** [azure.md](azure.md).

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `app` | string | `name` | Container app name (&lt; 32 chars) |
| `resource_group` | string | `{app}-rg` | Azure resource group (created if missing) |
| `location` | string | `eastus` | Azure region |
| `environment` | string | `{app}-env` | Container Apps environment name |
| `registry` | string | sanitized app | ACR name (alphanumeric only, global unique) |
| `repository` | string | app name | Image repository inside ACR |
| `cpu` | string | `0.5` | vCPU cores (`0.25`, `0.5`, `1.0`, …) |
| `memory` | string | `1.0Gi` | Memory with unit |
| `port` | int | `8080` | Target port (ingress) |
| `min_replicas` | int | `0` | Scale-to-zero when 0 |
| `max_replicas` | int | `3` | Max scale-out |
| `image_tag` | string | `latest` | If `latest`, podfly uses a timestamp tag each deploy |
| `platform` | string | `linux/amd64` | Docker build platform |
| `env` | map | — | Extra runtime env vars |
| `public_host` | string | — | Filled after first deploy (FQDN) |

Examples:

- [azure/api_only](https://github.com/127thousand/podfly_examples/tree/main/azure/api_only) — RPC  
- [azure/realtime_monolith](https://github.com/127thousand/podfly_examples/tree/main/azure/realtime_monolith) — Flutter + streams

## `cloud_run`

Used when `host: cloud_run` (aliases `gcp`, `google`, `cloudrun`).

Deploys via `gcloud run deploy --source` (Dockerfile at monorepo root or copied from `*_server/`).

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `service` | string | `name` | Cloud Run service name |
| `project` | string | active gcloud project | GCP project id |
| `region` | string | `us-central1` | Region |
| `allow_unauthenticated` | bool | `true` | Public invoker |
| `memory` | string | `1Gi` | Memory limit |
| `cpu` | string | `1` | CPU limit |
| `port` | int | `8080` | Container port |
| `min_instances` | int | `0` | Scale-to-zero when 0 |
| `max_instances` | int | `10` | Max concurrency scale |
| `timeout_seconds` | int | `300` | Request timeout (max **3600**). Raise for long WebSocket streams |
| `session_affinity` | bool | `false` | Sticky sessions — recommended for WebSockets when `max_instances` > 1 |
| `execution_environment` | `gen1` \| `gen2` | **`gen2`** | Passed as `gcloud run deploy --execution-environment` (pinned; not left to CLI default) |
| `cloud_sql_instances` | list | — | e.g. `project:region:instance` for Cloud SQL Auth Proxy |
| `env` | map | — | Extra env vars |
| `public_host` | string | — | Filled after first deploy |

**Monolith (Flutter + API + WS):** one public port only. Ship nginx (or similar) that serves static Flutter and proxies `/` API + `/v1/websocket` to Serverpod on an internal port. See [podfly_examples/gcp/realtime_monolith](https://github.com/127thousand/podfly_examples/tree/main/gcp/realtime_monolith).

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
