# Changelog

All notable changes to **podfly** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

### Added

- **Example CI:** `example/mobile_api_only` GitHub Actions workflows for Fly API-only deploy on every push to `main` (+ PR dry-run)

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
