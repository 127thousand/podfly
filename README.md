# podfly

**Deploy Serverpod on real cloud infrastructure without memorizing each provider’s CLI, config, and quirks.**

podfly is a thin orchestrator: it shells out to **existing tools** (`fly`, `wrangler`, `neonctl`, cloud CLIs, …), generates the right config, and encodes battle-tested defaults (Flutter web packaging, scale-to-zero, DB wiring). It is **not** a new host — it makes the hosts you already use boring to ship to.

```text
serverpod create …     →  Dockerfile + monorepo (Serverpod)
podfly deploy          →  provider CLIs + configs + quirks (podfly)
```

**Repo:** [github.com/127thousand/podfly](https://github.com/127thousand/podfly)

---

## Provider roadmap

Status is what **podfly** supports as a first-class target (not whether you can deploy Serverpod there by hand).

### App hosts (run the Serverpod Docker API)

| Provider | CLI | Status | Notes |
|----------|-----|--------|--------|
| [**Fly.io**](https://fly.io) | `fly` / `flyctl` | **Supported** | Default path; apps create, `fly.toml`, scale-to-zero |
| [**Cloudflare Pages**](https://pages.cloudflare.com) | `wrangler` | **Supported** (UI only) | Flutter web split frontend; not the API |
| [**Railway**](https://railway.app) | Railway CLI | Planned | Excellent DX; Docker + Git |
| [**Render**](https://render.com) | Render CLI / Blueprint | Planned | Docker services + simple prod |
| [**Google Cloud Run**](https://cloud.google.com/run) | `gcloud` | Planned | Large-cloud default; containers |
| [**AWS**](https://aws.amazon.com) (App Runner / ECS) | `aws` | Planned | What most enterprises already have |
| [**Azure**](https://azure.microsoft.com) Container Apps | `az` | Planned | Same for Microsoft shops |
| [**DigitalOcean**](https://www.digitalocean.com) App Platform | `doctl` | Planned | Simple PaaS many already use |

### Hosted Postgres

| Provider | CLI / API | Status | Notes |
|----------|-----------|--------|--------|
| **None** | — | **Supported** | Stateless APIs |
| [**Neon**](https://neon.tech) | `neonctl` | **Supported** | Serverless PG; good with sleeping APIs |
| [**Fly Postgres**](https://fly.io/docs/postgres/) | `fly postgres` | **Supported** | Private network to Machines; bills when API sleeps |
| **SQLite** (+ Fly volume) | `fly volumes` | **Supported** | Single-machine only |
| [**Supabase**](https://supabase.com) | Supabase CLI / URL | Planned | Managed PG (use as database only if you want) |
| [**Railway Postgres**](https://railway.app) | Railway CLI | Planned | Bundle with Railway app host |
| [**Render Postgres**](https://render.com) | Dashboard / API | Planned | Bundle with Render |
| [**AWS RDS**](https://aws.amazon.com/rds/) | `aws` | Planned | Enterprise default |
| [**Google Cloud SQL**](https://cloud.google.com/sql) | `gcloud` | Planned | GCP default |
| [**Azure Database for PostgreSQL**](https://azure.microsoft.com/products/postgresql) | `az` | Planned | Azure default |
| [**DigitalOcean Managed Postgres**](https://www.digitalocean.com/products/managed-databases) | `doctl` | Planned | Simple managed PG |

Want another provider? Open an issue — preference is **excellent DX** or **clouds most teams already pay for**.

---

## What you get today (Fly + optional Pages + Neon)

| Mode | UI | API |
|------|----|-----|
| **`split`** | Cloudflare Pages | Fly.io |
| **`fly`** | Optional static on Fly | Fly.io |
| **API-only** | — (mobile / other clients) | Fly.io (`web.enabled: false`) |

| Database | When |
|----------|------|
| **`none`** | Stateless |
| **`sqlite`** | Single machine + volume |
| **`fly_postgres`** | Classic Serverpod on Fly |
| **`neon`** | Serverless PG |

---

## Install

```bash
dart pub global activate --source git https://github.com/127thousand/podfly.git
# or: dart pub global activate --source path /path/to/podfly
```

Ensure `~/.pub-cache/bin` is on your `PATH`.

| Tool | When |
|------|------|
| [Flutter](https://flutter.dev) | Always |
| [flyctl](https://fly.io/docs/hands-on/install-flyctl/) | Current default host |
| [wrangler](https://developers.cloudflare.com/workers/wrangler/install-and-update/) | Split UI (Pages) |
| [neonctl](https://neon.tech/docs/reference/neon-cli) | `database.neon.provision: true` |

`podfly doctor` checks these and can open login flows on a TTY.

---

## Quick start

```bash
serverpod create my_app --mini -f   # Serverpod: monorepo + Dockerfile
cd my_app
podfly deploy --yes --smoke         # podfly: provider CLIs + config quirks
```

podfly will (today, on Fly/Pages/Neon):

1. Doctor tools + auth  
2. Init `podfly.yaml` if missing (`--yes` = non-interactive)  
3. Detect web vs **API-only** (e.g. mobile without `web/`)  
4. Write `fly.toml` if missing; Serverpod-style Dockerfile only if missing  
5. **`fly apps create`** if needed (sanitizes names; unique suffix if taken)  
6. Create Pages project when deploying web  
7. Patch production `publicHost` toward `*.fly.dev` when still localhost  
8. Build/deploy + optional smoke  

```bash
podfly deploy --dry-run
podfly deploy --api
podfly deploy --web
podfly doctor
podfly init
podfly smoke
```

**Once per machine:** install CLIs and log in.  
**Not required:** hand-written provider config for supported targets, or guessing CanvasKit/SW/asset build quirks.

---

## Documentation

| Doc | Contents |
|-----|----------|
| [**User guide**](docs/guide.md) | Flow, flags, CI, automation |
| [**Caching & Flutter web**](docs/caching.md) | WASM, service worker, `_headers` |
| [**Database**](docs/database.md) | Providers + detection |
| [**Config reference**](docs/podfly.yaml.md) | `podfly.yaml` fields |
| [**Design spec**](docs/specs/2026-07-18-podfly-design.md) | Architecture decisions |

---

## Example `podfly.yaml` (split, no database)

```yaml
mode: split
name: sacred-draw
server: tarot_draw_server
flutter: tarot_draw_flutter

fly:
  app: sacred-draw
  region: iad
  config: fly.toml
  scale_to_zero: true
  ha: false

cloudflare:
  project: sacred-draw
  branch: main

database:
  provider: none

web:
  enabled: true
  server_url_define: SERVER_URL
  api_url: https://sacred-draw.fly.dev/
  patch_bootstrap: true
  write_headers: true

smoke:
  api:
    method: POST
    path: /tarot/draw
    body: '{}'
    expect_status: 200
  web:
    path: /
    expect_status: 200
```

---

## License

MIT
