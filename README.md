# podfly

<p align="center">
  <img src="doc/images/podfly-hero.jpg" alt="podfly — fueling Serverpod launches" width="720" />
</p>

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
| Host CLI (`fly`, `railway`, `doctl`, …) | **Only for the `host:` you chose** (wizard asks) |
| [Railway CLI](https://docs.railway.app/guides/cli) | `host: railway` (often `~/.railway/bin`) |
| [doctl](https://docs.digitalocean.com/reference/doctl/) + Docker | `host: digitalocean` (DOCR registry required) |
| [wrangler](https://developers.cloudflare.com/workers/wrangler/install-and-update/) | Flutter web on Cloudflare Pages (`mode: split`) |
| [neonctl](https://neon.tech/docs/reference/neon-cli) | `database.neon.provision: true` |

`podfly doctor` checks these, can install missing CLIs (TTY or `PODFLY_AUTO=1`), and can open login flows on a TTY.

**CI:** see [doc/ci.md](doc/ci.md) (`FLY_API_TOKEN` / `RAILWAY_TOKEN` + `--yes --no-login`).

---

## Quick start

**Value prop:** create a Serverpod project, then one command ships it. You do **not** hand-write `fly.toml` / `railway.toml` / app specs first — podfly generates them when missing.

```bash
serverpod create my_app --mini -f   # Serverpod: monorepo + Dockerfile
cd my_app
fly auth login                      # once per machine (or set FLY_API_TOKEN in CI)
podfly deploy --yes --smoke         # creates podfly.yaml + fly.toml if needed, deploys, smokes
```

That’s the happy path. No prior `podfly.yaml`, no prior host config — only a normal Serverpod tree and a logged-in host CLI (or CI token).

### Do I need `fly.toml`?

| Situation | What happens |
|-----------|----------------|
| **Fresh project** | `podfly deploy` writes a starter `fly.toml` (or `railway.toml`, etc.) then deploys |
| **File already exists** | podfly leaves your settings alone (only patches `app =` when the Fly app name changes) |
| **Committed in an example / prod repo** | Optional lock-in for **reviewable, deterministic CI** — not a prerequisite to *use* podfly |

Same idea for `podfly.yaml`: created on first deploy (`--yes` = non-interactive defaults). Commit both when you care about stable names and settings in git; delete them and redeploy to regenerate starters.

**Examples by cloud** (separate repo, monorepo leaves):  
[github.com/127thousand/podfly_examples](https://github.com/127thousand/podfly_examples) — e.g. `fly/api_only`, `render/api_postgres`.  
Package pointer: [`example/mobile_api_only`](example/mobile_api_only) (Fly API-only).

What deploy automates (Fly path today):

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
| 🔀 **`split`** | 🟠 Cloudflare Pages (CDN) + API host | 🟣 Fly / 🚂 Railway / 🌊 DO |
| 🧱 **`monolith`** | UI with the API host (or DO native web app) | 🟣 Fly / 🚂 Railway / 🌊 DO |
| 📱 **API-only** | — (`web.enabled: false`; usually `mode: monolith`) | 🟣 Fly / 🚂 Railway / 🌊 DO |

`mode: fly` is still accepted as a **legacy alias** for `monolith`.

| Database | When |
|----------|------|
| 🚫 **`none`** | Stateless |
| 💾 **`sqlite`** | Single machine + volume (Fly) |
| 🟣 **`fly_postgres`** | Classic Serverpod on Fly (attach → Serverpod config) |
| 🚂 **`railway_postgres`** | Railway Postgres plugin (`host: railway`) |
| 🌊 **`digitalocean_postgres`** | DO Managed Postgres (`host: digitalocean`) |
| 🟢 **`neon`** | Serverless PG |

Insights and full managed Serverpod ops: **[Serverpod Cloud](https://serverpod.dev/cloud)** (not podfly).

### Serverpod version compatibility

podfly is a **host orchestrator** — it does not depend on the `serverpod` package. Compatibility is about project layout, Dockerfile, and config files.

| Serverpod | Status | Notes |
|-----------|--------|--------|
| **4.x** (incl. current beta) | **Primary / tested** | Examples, fallback Dockerfile template, and docs target 4.x |
| **3.4.x** | **Smoke-tested** | See below |
| **Older than 3.4** | Untested | Likely fine if the project already has a working Serverpod Dockerfile |

**Verified on Serverpod 3.4.11** (real Fly deploys, 2026-07-20):

| Project | Database | Result |
|---------|----------|--------|
| `serverpod create … --mini` | `none` | API deploy + smoke `POST /greeting/hello` → 200 |
| `serverpod create … --template server` | `fly_postgres` (create + attach + patch `production.yaml` / `passwords.yaml`) | API deploy + same smoke → 200 |

What made 3.x work: podfly used the **project’s own Dockerfile** (`dart:3.8` + `dart compile exe`) and conventional `*_server` / config paths.  

What is still **4-oriented** (avoid relying on these for 3.x):

- Fallback Dockerfile if yours is missing (`templates/Dockerfile.serverpod` is Serverpod **4-style**: Dart 3.10 + `dart build cli`)
- Examples and CI sample pin Serverpod 4 / Dart 3.10

**Rule of thumb:** keep the Dockerfile from `serverpod create` for your major version; run `podfly deploy --api --yes --smoke`. Do not delete the Dockerfile and expect the generated 4-style template to build a 3.x app.

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
| 🟦 [**Render**](https://render.com) | `render` | ✅ | ✅ | 🟡 | 🟡 | Git + Docker; monorepo `rootDir`; `render_postgres` |
| ☁️ [**Google Cloud Run**](https://cloud.google.com/run) | `gcloud` | ✅ | ✅ | 🟡 | ✅* | Cheap serverless; *monolith = nginx + Serverpod one container (see `gcp/realtime_monolith`) |
| 📦 [**AWS App Runner**](https://aws.amazon.com/apprunner/) | `aws` | ✅ | ✅ | 🟡 | 🟡 | ECR image; **no WebSockets** (Envoy 403); not free scale-to-zero |
| 🔷 [**Azure**](https://azure.microsoft.com) Container Apps | `az` | 🗺️ | ✅ | ✅ | 🟡 | Similar to other container PaaS |
| 🌊 [**DigitalOcean**](https://www.digitalocean.com) App Platform | `doctl` | ✅ | ✅ | ✅ | 🟡 | DOCR images + App Spec; web = separate app |

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
| 🟦 [**Render Postgres**](https://render.com) | `render postgres` | ✅ | `database.provider: render_postgres` |
| 📦 [**AWS RDS**](https://aws.amazon.com/rds/) | `aws` | 🗺️ | Enterprise default |
| ☁️ [**Google Cloud SQL**](https://cloud.google.com/sql) | `gcloud` | 🗺️ | BYO: set `cloud_run.cloud_sql_instances` + unix socket in production.yaml |
| 🔷 [**Azure Database for PostgreSQL**](https://azure.microsoft.com/products/postgresql) | `az` | 🗺️ | Azure default |
| 🌊 [**DigitalOcean Managed Postgres**](https://www.digitalocean.com/products/managed-databases) | `doctl` | ✅ | `digitalocean_postgres` + app firewall |

**podfly legend:** ✅ supported today · 🗺️ planned  

Want another provider? Open an issue — preference is **excellent DX** or **clouds most teams already pay for**.

### Redis / shared state (later)

Most small apps **do not need Redis** (Postgres is enough). When you run **multiple instances** and need shared cache or PubSub (live streams across machines), Serverpod can use Redis.

| Provider | podfly | Notes |
|----------|--------|--------|
| 🔺 [**Upstash**](https://upstash.com) | 🗺️ later | Serverless Redis + TLS; Serverpod’s own Cloud docs use it as the third-party example; great fit with scale-to-zero hosts |
| Host-managed Redis | — | Fly/Railway/etc. Redis plugins — manual config today |

Parked as an **extra**, not core cheap path: optional `redis` / Upstash wiring (env + `production.yaml` patch) after Cloud Run and the main host set settle.

---

## Example `podfly.yaml` (split, no database)

```yaml
host: fly
mode: split   # or monolith — UI with API host, no Pages
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
mode: monolith
name: my-api
server: my_app_server
web:
  enabled: false
database:
  provider: railway_postgres
  railway_postgres:
    create: true
```

DigitalOcean full stack sketch:

```yaml
host: digitalocean
mode: monolith
name: my-app
server: my_app_server
flutter: my_app_flutter
digitalocean:
  app: my-app
  region: nyc
database:
  provider: digitalocean_postgres
  digitalocean_postgres:
    create: true
    region: nyc1
web:
  enabled: true
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
