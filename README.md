# podfly

**Deploy Serverpod on real cloud infrastructure without memorizing each provider’s CLI, config, and quirks.**

podfly is a thin orchestrator: it shells out to **existing tools** (`fly`, `railway`, `wrangler`, `neonctl`, …), generates the right config, and encodes battle-tested defaults (Flutter web packaging, scale-to-zero, DB wiring). It is **not** a new host — it makes the hosts you already use boring to ship to.

```text
serverpod create …     →  Dockerfile + monorepo (Serverpod)
podfly deploy          →  provider CLIs + configs + quirks (podfly)
```

| | |
|--|--|
| **pub.dev** | [![pub package](https://img.shields.io/pub/v/podfly.svg)](https://pub.dev/packages/podfly) |
| **Repo** | [github.com/127thousand/podfly](https://github.com/127thousand/podfly) |

---

## Serverpod Cloud vs podfly

The Serverpod project’s managed offering is **[Serverpod Cloud](https://serverpod.dev/cloud)** — API, web, Insights, and the rest of the product surface on infrastructure built for Serverpod.

**podfly** is the path when you want to keep **your own** infra (Fly, Railway, and similar) and still avoid hand-rolling every CLI and config quirk. Use one or the other; they solve different problems.

---

## Install

```bash
dart pub global activate podfly
```

Ensure `~/.pub-cache/bin` (or your platform’s pub cache bin) is on `PATH`. Upgrade with the same command.

**Contributors / unreleased:**

```bash
dart pub global activate --source git https://github.com/127thousand/podfly.git
# or: dart pub global activate --source path /path/to/podfly
```

| Tool | When |
|------|------|
| [Flutter](https://flutter.dev) / Dart | Always |
| Host CLI (`fly`, `railway`, …) | **Only for the `host:` you chose** (wizard asks) |
| [Railway CLI](https://docs.railway.app/guides/cli) | `host: railway` (often `~/.railway/bin`) |
| [wrangler](https://developers.cloudflare.com/workers/wrangler/install-and-update/) | Flutter web on Cloudflare Pages (`mode: split`) |
| [neonctl](https://neon.tech/docs/reference/neon-cli) | `database.neon.provision: true` |

`podfly doctor` checks these, can install missing CLIs (TTY or `PODFLY_AUTO=1`), and can open login flows on a TTY.

**CI:** see [doc/ci.md](doc/ci.md) (`FLY_API_TOKEN` / `RAILWAY_TOKEN` + `--yes --no-login`).

---

## Quick start

```bash
serverpod create my_app --mini -f   # Serverpod: monorepo + Dockerfile
cd my_app
podfly deploy --yes --smoke         # podfly: provider CLIs + config quirks
```

Typical automation (Fly today):

1. Doctor tools + auth  
2. Init `podfly.yaml` if missing (`--yes` = non-interactive)  
3. Detect web vs **API-only** (e.g. mobile without `web/`)  
4. Ensure API app exists (needed before Postgres attach)  
5. Database ensure (`fly_postgres` / `railway_postgres` / neon / none)  
6. Write `fly.toml` / `railway.toml` if missing; Serverpod-style Dockerfile only if missing  
7. Patch production `publicHost`  
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

---

## What you get today

| Mode | UI | API |
|------|----|-----|
| 🔀 **`split`** | 🟠 Cloudflare Pages **or** 🚂 Railway static (`host: railway`) | 🟣 Fly.io or 🚂 Railway |
| 🪰 **`fly`** | Optional static on Fly | 🟣 Fly.io |
| 📱 **API-only** | — (mobile / other clients) | 🟣 Fly.io or 🚂 Railway |

| Database | When |
|----------|------|
| 🚫 **`none`** | Stateless |
| 💾 **`sqlite`** | Single machine + volume (Fly) |
| 🟣 **`fly_postgres`** | Classic Serverpod on Fly (attach → Serverpod config) |
| 🚂 **`railway_postgres`** | Railway Postgres plugin (`host: railway`) |
| 🟢 **`neon`** | Serverless PG |

Insights and full managed Serverpod ops: **[Serverpod Cloud](https://serverpod.dev/cloud)** (not podfly).

---

## Provider roadmap

**podfly status** = first-class in this tool.  
**Fit** = how well that host matches Serverpod’s process model, independent of whether podfly implements the deploy yet.

### Topology keys

| Topology | Meaning | When it fits |
|----------|---------|--------------|
| 📱 **API-only** | One public API port. Mobile or other clients. | Any container/PaaS that runs a single process + port. |
| 🔀 **Split** | Static Flutter web on a CDN; API on an app host. | Best of both: CDN for multi‑MB WASM; API can scale to zero. |
| 🧱 **All-in-one** | API + static web on one machine (multi-port / multi-role). | Hosts that allow multi-port Machines or a reverse proxy. |

Serverpod **Insights** is not covered by podfly. For Insights and the full managed product surface, use **[Serverpod Cloud](https://serverpod.dev/cloud)**.

### App hosts

| Provider | CLI | podfly | 📱 API-only | 🔀 Split UI+API | 🧱 All-in-one | Notes |
|----------|-----|--------|:-----------:|:---------------:|:-------------:|-------|
| 💜 [**Serverpod Cloud**](https://serverpod.dev/cloud) | Serverpod Cloud | — | ✅ | ✅ | ✅ | Serverpod’s managed host (not via podfly) |
| 🟣 [**Fly.io**](https://fly.io) | `fly` / `flyctl` | ✅ | ✅ | ✅ | ✅ | Default podfly path; multi-port Machines OK |
| 🚂 [**Railway**](https://railway.app) | `railway` | ✅ | ✅ | ✅ | 🟡 | Separate API + static web services |
| 🟠 [**Cloudflare Pages**](https://pages.cloudflare.com) | `wrangler` | ✅ UI | — | ✅ UI | — | Static Flutter web only; **not** the API |
| 🟦 [**Render**](https://render.com) | Render CLI | 🗺️ | ✅ | ✅ | 🟡 | Prefer API service + static site |
| ☁️ [**Google Cloud Run**](https://cloud.google.com/run) | `gcloud` | 🗺️ | 🟡 | 🟡 | ❌ | One public port; cold starts |
| 📦 [**AWS**](https://aws.amazon.com) App Runner / ECS | `aws` | 🗺️ | ✅ | ✅ | 🟡 | App Runner ≈ API-only |
| 🔷 [**Azure**](https://azure.microsoft.com) Container Apps | `az` | 🗺️ | ✅ | ✅ | 🟡 | Similar to other container PaaS |
| 🌊 [**DigitalOcean**](https://www.digitalocean.com) App Platform | `doctl` | 🗺️ | ✅ | ✅ | 🟡 | Simple PaaS |

**Fit legend:** ✅ natural · 🟡 possible with constraints · ❌ poor fit · 🗺️ podfly not implemented yet · — N/A

### Hosted Postgres

| Provider | CLI / API | podfly | Notes |
|----------|-----------|--------|--------|
| 🚫 **None** | — | ✅ | Stateless APIs |
| 🟢 [**Neon**](https://neon.tech) | `neonctl` | ✅ | Serverless PG; pairs with sleeping APIs |
| 🟣 [**Fly Postgres**](https://fly.io/docs/postgres/) | `fly postgres` | ✅ | Private network; often bills when API is stopped |
| 🚂 [**Railway Postgres**](https://railway.app) | Railway CLI | ✅ | `database.provider: railway_postgres` |
| 💾 **SQLite** (+ Fly volume) | `fly volumes` | ✅ | Single-machine only |
| ⚡ [**Supabase**](https://supabase.com) | CLI / URL | 🗺️ | Managed PG |
| 🟦 [**Render Postgres**](https://render.com) | API / dashboard | 🗺️ | Bundle with Render |
| 📦 [**AWS RDS**](https://aws.amazon.com/rds/) | `aws` | 🗺️ | Enterprise default |
| ☁️ [**Google Cloud SQL**](https://cloud.google.com/sql) | `gcloud` | 🗺️ | GCP default |
| 🔷 [**Azure Database for PostgreSQL**](https://azure.microsoft.com/products/postgresql) | `az` | 🗺️ | Azure default |
| 🌊 [**DigitalOcean Managed Postgres**](https://www.digitalocean.com/products/managed-databases) | `doctl` | 🗺️ | Simple managed PG |

**podfly legend:** ✅ supported today · 🗺️ planned  

Want another provider? Open an issue — preference is **excellent DX** or **clouds most teams already pay for**.

---

## Example `podfly.yaml` (split, no database)

```yaml
host: fly
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

Railway API-only sketch:

```yaml
host: railway
mode: fly
name: my-api
server: my_app_server
web:
  enabled: false
database:
  provider: railway_postgres
  railway_postgres:
    create: true
```

Full field list: [doc/podfly.yaml.md](doc/podfly.yaml.md).

---

## Documentation

| Doc | Contents |
|-----|----------|
| [**User guide**](doc/guide.md) | Flow, flags, automation, troubleshooting |
| [**CI / GitHub Actions**](doc/ci.md) | Tokens, example workflows, dry-run on PR |
| [**Caching & Flutter web**](doc/caching.md) | WASM, service worker, `_headers` |
| [**Database**](doc/database.md) | Providers + detection |
| [**Config reference**](doc/podfly.yaml.md) | `podfly.yaml` fields |
| [**AGENTS.md**](AGENTS.md) | Rules for coding agents |
| [**llms.txt**](llms.txt) | LLM / doc index |
| [**Skill**](.grok/skills/podfly/SKILL.md) | Grok skill (`/podfly`) |
| [**CHANGELOG**](CHANGELOG.md) | Release history |
| [**Design specs**](doc/specs/) | Architecture decisions |

---

## License

MIT
