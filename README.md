# podfly

**Deploy Serverpod on real cloud infrastructure without memorizing each provider’s CLI, config, and quirks.**

podfly is a thin orchestrator: it shells out to **existing tools** (`fly`, `wrangler`, `neonctl`, cloud CLIs, …), generates the right config, and encodes battle-tested defaults (Flutter web packaging, scale-to-zero, DB wiring). It is **not** a new host — it makes the hosts you already use boring to ship to.

```text
serverpod create …     →  Dockerfile + monorepo (Serverpod)
podfly deploy          →  provider CLIs + configs + quirks (podfly)
```

**Repo:** [github.com/127thousand/podfly](https://github.com/127thousand/podfly)

---

## Official recommendation

Out of respect for the Serverpod team: the **officially recommended** hosting path is **[Serverpod Cloud](https://serverpod.dev/cloud)** — managed infrastructure built for Serverpod (API, web, Insights, and the rest of the product surface).

**podfly** is for teams that want to stay on **their own** infra (Fly, Railway, big clouds, etc.) and still avoid hand-rolling every CLI and config quirk. It complements Serverpod Cloud; it does not replace it.

---

## Provider roadmap

**podfly status** = first-class in this tool.  
**Fit** = how well that host matches Serverpod’s process model, independent of whether podfly implements the deploy yet.

### Topology keys (what’s possible)

| Topology | Meaning | When it fits |
|----------|---------|--------------|
| 📱 **API-only** | One public API port. Mobile or other clients. | Any container/PaaS that runs a single process + port. |
| 🔀 **Split** | Static Flutter web on a CDN; API on an app host. | Best of both: CDN for multi‑MB WASM; API can scale to zero. |
| 🧱 **All-in-one** | API + static web on one machine (multi-port / multi-role). | Hosts that allow multi-port Machines or a reverse proxy. |

Serverpod **Insights** is not covered by podfly (and is not in this table). For Insights and the full managed product surface, use **[Serverpod Cloud](https://serverpod.dev/cloud)**.

### 🚀 App hosts

| Provider | CLI | podfly | 📱 API-only | 🔀 Split UI+API | 🧱 All-in-one | Notes |
|----------|-----|--------|:-----------:|:---------------:|:-------------:|-------|
| 💜 [**Serverpod Cloud**](https://serverpod.dev/cloud) | Serverpod Cloud | — | ✅ | ✅ | ✅ | **Officially recommended** managed option |
| 🟣 [**Fly.io**](https://fly.io) | `fly` / `flyctl` | ✅ | ✅ | ✅ | ✅ | Default podfly path; multi-port Machines OK |
| 🚂 [**Railway**](https://railway.app) | `railway` | ✅ | ✅ | ✅ | 🟡 | API service + optional Pages UI; one public port |
| 🟠 [**Cloudflare Pages**](https://pages.cloudflare.com) | `wrangler` | ✅ UI | — | ✅ UI | — | Static Flutter web only; **not** the API |
| 🟦 [**Render**](https://render.com) | Render CLI | 🗺️ | ✅ | ✅ | 🟡 | Same: prefer API service + static site |
| ☁️ [**Google Cloud Run**](https://cloud.google.com/run) | `gcloud` | 🗺️ | 🟡 | 🟡 | ❌ | One public port, request-scoped; cold starts; **not** a multi-port monolith |
| 📦 [**AWS**](https://aws.amazon.com) App Runner / ECS | `aws` | 🗺️ | ✅ | ✅ | 🟡 | App Runner ≈ API-only; ECS freer for multi-service |
| 🔷 [**Azure**](https://azure.microsoft.com) Container Apps | `az` | 🗺️ | ✅ | ✅ | 🟡 | Similar constraints to Cloud Run / containers |
| 🌊 [**DigitalOcean**](https://www.digitalocean.com) App Platform | `doctl` | 🗺️ | ✅ | ✅ | 🟡 | Simple PaaS |

**Fit legend:** ✅ natural · 🟡 possible with constraints (single port, split services, always-on, etc.) · ❌ poor fit · 🗺️ podfly not implemented yet · — N/A

**Cloud Run in particular:** usable for **API-only** (or split with UI on Pages/elsewhere) if you pin one port and accept cold starts / min instances. **Not** a good target for stock multi-port Serverpod all-in-one without redesign or multi-service layout.

### 🐘 Hosted Postgres

| Provider | CLI / API | podfly | Notes |
|----------|-----------|--------|--------|
| 🚫 **None** | — | ✅ | Stateless APIs |
| 🟢 [**Neon**](https://neon.tech) | `neonctl` | ✅ | Serverless PG; pairs with sleeping APIs |
| 🟣 [**Fly Postgres**](https://fly.io/docs/postgres/) | `fly postgres` | ✅ | Private network; often bills when API is stopped |
| 💾 **SQLite** (+ Fly volume) | `fly volumes` | ✅ | Single-machine only |
| ⚡ [**Supabase**](https://supabase.com) | CLI / URL | 🗺️ | Managed PG (use DB only if you want) |
| 🚂 [**Railway Postgres**](https://railway.app) | Railway CLI | 🗺️ | Bundle with Railway app |
| 🟦 [**Render Postgres**](https://render.com) | API / dashboard | 🗺️ | Bundle with Render |
| 📦 [**AWS RDS**](https://aws.amazon.com/rds/) | `aws` | 🗺️ | Enterprise default |
| ☁️ [**Google Cloud SQL**](https://cloud.google.com/sql) | `gcloud` | 🗺️ | GCP default |
| 🔷 [**Azure Database for PostgreSQL**](https://azure.microsoft.com/products/postgresql) | `az` | 🗺️ | Azure default |
| 🌊 [**DigitalOcean Managed Postgres**](https://www.digitalocean.com/products/managed-databases) | `doctl` | 🗺️ | Simple managed PG |

**podfly legend:** ✅ supported today · 🗺️ planned  

Want another provider? Open an issue — preference is **excellent DX** or **clouds most teams already pay for**.

---

## What you get today (podfly)

| Mode | UI | API |
|------|----|-----|
| 🔀 **`split`** | 🟠 Cloudflare Pages **or** 🚂 Railway static (`host: railway`) | 🟣 Fly.io or 🚂 Railway |
| 🪰 **`fly`** | Optional static on Fly | 🟣 Fly.io |
| 📱 **API-only** | — (mobile / other clients) | 🟣 Fly.io or 🚂 Railway |

| Database | When |
|----------|------|
| 🚫 **`none`** | Stateless |
| 💾 **`sqlite`** | Single machine + volume (Fly) |
| 🟣 **`fly_postgres`** | Classic Serverpod on Fly |
| 🚂 **`railway_postgres`** | Railway Postgres plugin (`host: railway`) |
| 🟢 **`neon`** | Serverless PG |

Insights and full managed Serverpod ops: **[Serverpod Cloud](https://serverpod.dev/cloud)** (not podfly).

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
| Host CLI (`fly`, `railway`, `gcloud`, …) | **Only for the `host:` you chose** (wizard asks) |
| [Railway CLI](https://docs.railway.app/guides/cli) | `host: railway` (install often lands in `~/.railway/bin`) |
| [wrangler](https://developers.cloudflare.com/workers/wrangler/install-and-update/) | Flutter web on Cloudflare Pages (`mode: split`) |
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
podfly deploy --host railway --api --yes --smoke
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
| [**AGENTS.md**](AGENTS.md) | Rules for coding agents |
| [**llms.txt**](llms.txt) | LLM / doc index |
| [**Skill**](.grok/skills/podfly/SKILL.md) | Grok skill (`/podfly`) |
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
