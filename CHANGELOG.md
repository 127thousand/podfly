# Changelog

All notable changes to **podfly** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

### Added

- **AWS App Runner** `ecr_public: true` — push to ECR Public + `ImageRepositoryType: ECR_PUBLIC`
- Prefer monorepo **root Dockerfile** when present (nginx monolith images)
- Example: [podfly_examples/aws/realtime_monolith](https://github.com/127thousand/podfly_examples/tree/main/aws/realtime_monolith)
- **[doc/aws.md](doc/aws.md)** — App Runner WebSocket limitation (managed Envoy 403; not customer-configurable)
- **Sketch:** [ECS Fargate + ALB realtime](doc/specs/2026-07-21-aws-ecs-realtime-sketch.md) for AWS + Serverpod streams

### Planned (parked)

- **`host: aws_ecs`** — Fargate + ALB (WebSocket-capable); see sketch above
- **Upstash Redis** (optional): wire Serverpod Redis host/password/SSL for multi-instance cache/PubSub — not required for small/stateless apps

---

## [0.5.0] — 2026-07-21

### Added

- **`host: aws`** (aliases `apprunner`, `app_runner`, `amazon`): AWS **App Runner** deploy
  - Local Docker build (`linux/amd64`) → **ECR** push → `create-service` / `update-service`
  - Auto-creates ECR repository + `AppRunnerECRAccessRole` (ECR pull) when missing
  - Config: region, cpu/memory, port, ecr_repository, `start_command`, service_arn, env
  - Default `start_command: /app/entrypoint.sh` (App Runner often fails CREATE without it)
  - TCP health check (works without a custom HTTP path)
- Example: [podfly_examples/aws/api_only](https://github.com/127thousand/podfly_examples/tree/main/aws/api_only)

---

## [0.4.1] — 2026-07-21

### Added

- **Cloud Run** `timeout_seconds` (default 300, max 3600) and `session_affinity` for long-lived WebSockets
- Example: [podfly_examples/gcp/realtime_monolith](https://github.com/127thousand/podfly_examples/tree/main/gcp/realtime_monolith) — Flutter web + Serverpod streams in one Cloud Run service (nginx monolith)

---

## [0.4.0] — 2026-07-21

### Added

- **`host: cloud_run`** (aliases `gcp`, `google`, `cloudrun`): Google Cloud Run API deploy via `gcloud run deploy --source`
  - Config: project, region, memory/cpu, min/max instances, Cloud SQL instance attach list
  - Copies server Dockerfile to monorepo root when needed (Cloud Run source build)
  - Auth: active `gcloud` account or `GOOGLE_APPLICATION_CREDENTIALS`
  - Positioning: inexpensive **stateless** Serverpod (not GCE/Terraform)
- Example: [podfly_examples/gcp/api_only](https://github.com/127thousand/podfly_examples/tree/main/gcp/api_only)

---

## [0.3.1] — 2026-07-20

### Added

- **Render static sites** for Flutter web (`deployWeb`): stage `site/`, git push, `static_site` service
- Example: [podfly_examples/render/api_and_static](https://github.com/127thousand/podfly_examples/tree/main/render/api_and_static)

### Fixed

- Resolve Render service URL by service id (avoid picking another `*.onrender.com`)
- Smoke `web:` uses `render.web_public_host` when set

---

## [0.3.0] — 2026-07-20

### Added

- **`host: render`**: Render web service (git + Docker) via `render` CLI
  - Monorepo support via `render.root_dir` (maps to Render `rootDir`)
  - Generates starter `render.yaml` Blueprint when missing
  - Auth: `render login` or `RENDER_API_KEY`
- **`database.provider: render_postgres`**: create/lookup free/paid PG, fetch connection info, sidecar + Serverpod config patch
- Examples monorepo: [podfly_examples](https://github.com/127thousand/podfly_examples) (`fly/api_only`, `render/api_postgres`)

### Changed

- Provider roadmap: Render marked supported (was planned)

---

## [0.2.2] — 2026-07-20

### Added

- README hero image (`doc/images/podfly-hero.jpg`)

### Changed

- Docs: clarify value prop — `serverpod create` then `podfly deploy` is enough; `fly.toml` / host configs are generated when missing (examples commit them only for stable CI)
- Docs: **Serverpod version compatibility** — 4.x primary; Serverpod **3.4.11** smoke-tested on Fly (mini + `none`, server template + `fly_postgres`)
- Example `mobile_api_only` README: product story, optional `fly.toml`, greenfield setup path

---

## [0.2.1] — 2026-07-20

### Added

- **Example CI:** `example/mobile_api_only` GitHub Actions workflows for Fly API-only deploy on every push to `main` (+ PR dry-run)
- Live demo repo: [127thousand/podfly-api-only-demo](https://github.com/127thousand/podfly-api-only-demo)

### Fixed

- Doctor no longer hard-requires **Flutter** for API-only deploys (`--api` or `web.enabled: false`) — unblocks GitHub Actions without Flutter SDK

---

## [0.2.0] — 2026-07-20

### Added

- **`host: digitalocean`** (alias `do`): App Platform via `doctl` + DOCR
  - Local Docker build/push (`linux/amd64`), app spec create/upsert
  - API app + optional separate **web** app (nginx + Flutter build)
  - **`digitalocean_postgres`**: Managed Postgres (DBaaS), public SSL host, app firewall `app:<id>`
  - Starter DOCR: one repository with tags `api` / `web`
- **`mode: monolith`** as the canonical name for “UI with API host / no Pages” (replaces `mode: fly` as primary)

### Changed

- `mode: fly` remains a **legacy alias** for `monolith`
- Native web hosts (Railway / DigitalOcean): deploy **API before web** so Flutter bakes a live `SERVER_URL`
- nginx static template: set WASM `Content-Type` via `default_type` (not `add_header`) so CanvasKit loads (avoids blank Flutter canvas)

### Fixed

- Duplicate `Content-Type: application/wasm,application/wasm` broke Flutter web on DO/Railway nginx deploys

---

## [0.1.1] — 2026-07-20

### Changed

- README / skill: reword Serverpod Cloud positioning (clear “managed vs own infra” split)

---

## [0.1.0] — 2026-07-20

First public release on [pub.dev](https://pub.dev/packages/podfly).

### Features

#### Host adapter architecture
- **Host adapter registry** (`lib/src/hosts/`): Fly, Railway, and planned clouds as `HostAdapter` plugins
- **Wizard chooses API cloud** (`host:` in `podfly.yaml`); doctor only requires that host’s CLI
- Planned hosts (Render, Cloud Run, AWS, Azure): config + doctor install recipes; deploy not implemented yet

#### Fly.io
- Default API host with scale-to-zero-friendly `fly.toml` templates
- `fly apps create` when missing (+ unique suffix if name taken); app name sanitize
- Patch Serverpod `production.yaml` `publicHost` to `*.fly.dev`
- **`HostAdapter.ensureApiApp`**: create API app **before** database attach
- **`fly_postgres`**: create cluster, attach, parse `DATABASE_URL` → sidecar + Serverpod user/db/`passwords.yaml`

#### Railway
- First-class API host (`host: railway`): project/service, domain, `railway.toml`, `railway up`
- Full stack: separate **API** + **static web** (nginx) + optional **Postgres**
- `railway_postgres` provider with sidecar → `production.yaml` / `passwords.yaml`
- **Serverless by default** for API + web
- Optional CDN on web service

#### Cloudflare Pages
- Split mode: Flutter web → Pages via `wrangler`

#### Doctor, database, CLI
- Doctor can install missing CLIs; facilitated login on TTY; `PODFLY_AUTO=1`
- Providers: `none`, `sqlite`, `fly_postgres`, `neon`, `railway_postgres`
- Detect mobile / API-only monorepos; Flutter web packaging (CanvasKit, bootstrap)
- Commands: `deploy`, `doctor`, `init`, `smoke`; CI-friendly `--yes --no-login`

### Documentation

- README, user guide, CI, caching, database, config reference, AGENTS.md, llms.txt

---

## Links

- Package: [pub.dev/packages/podfly](https://pub.dev/packages/podfly)
- Repo: [github.com/127thousand/podfly](https://github.com/127thousand/podfly)
- Docs: [doc/README.md](doc/README.md)
