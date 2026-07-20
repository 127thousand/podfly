# Changelog

All notable changes to **podfly** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

### Changed

- **`mode: monolith`** replaces `mode: fly` for “UI with API host / no Pages” layout. `mode: fly` remains a legacy alias.

---

## [0.1.1] — 2026-07-20

### Changed

- README / skill: reword Serverpod Cloud positioning (clear “managed vs own infra” split; drop “out of respect” phrasing)

---

## [0.1.0] — 2026-07-20

First public release on [pub.dev](https://pub.dev/packages/podfly).

### Features

#### Host adapter architecture
- **Host adapter registry** (`lib/src/hosts/`): Fly, Railway, and planned clouds as `HostAdapter` plugins
- **Wizard chooses API cloud** (`host:` in `podfly.yaml`); doctor only requires that host’s CLI
- Planned hosts (Render, Cloud Run, AWS, Azure, DigitalOcean): config + doctor install recipes; deploy not implemented yet

#### Fly.io
- Default API host with scale-to-zero-friendly `fly.toml` templates
- `fly apps create` when missing (+ unique suffix if name taken); app name sanitize
- Patch Serverpod `production.yaml` `publicHost` to `*.fly.dev`
- Optional Dockerfile template if Serverpod server Dockerfile is missing
- **`HostAdapter.ensureApiApp`**: create API app **before** database attach
- **`fly_postgres`**: create cluster, attach, parse `DATABASE_URL` → `.podfly_fly_pg.json` + correct Serverpod user/db/`passwords.yaml`

#### Railway
- First-class API host (`host: railway`): project/service, domain, `railway.toml`, `railway up`
- Doctor resolves CLI under `~/.railway/bin`
- Full stack: separate **API** + **static web** (nginx) + optional **Postgres** (not a siamese monolith)
- `railway_postgres` provider with sidecar → `production.yaml` / `passwords.yaml`
- **Serverless by default** for API + web (`sleepApplication` + GraphQL when CLI has no flag)
- Optional CDN on web service

#### Cloudflare Pages
- Split mode: Flutter web → Pages via `wrangler`
- Pages project create; `_headers` / `_redirects`; `SERVER_URL` dart-define

#### Doctor & install
- Doctor can install missing CLIs (Fly, Railway, wrangler, neonctl) via brew or install scripts
- Facilitated login on TTY; `PODFLY_AUTO=1` skips Y/n
- Host-scoped doctor (not always Fly)

#### Database
- Providers: `none`, `sqlite`, `fly_postgres`, `neon`, `railway_postgres`
- DB need detection; soft warnings for unused Serverpod template auth

#### Project surface & web packaging
- Detect mobile / API-only monorepos → `web.enabled: false`
- In-package Flutter web build, CanvasKit, bootstrap without stub SW
- Example: `example/mobile_api_only`

#### CLI
- Commands: `deploy`, `doctor`, `init`, `smoke`
- Flags: `--dry-run`, `--smoke`, `--api`, `--web`, `--yes`, `--no-login`, `--host`, `--mode`
- CI-friendly: env tokens + `--yes --no-login`

### Documentation

- README (install from pub.dev, roadmap, Serverpod Cloud recommendation)
- User guide, caching, database, config reference, **CI / GitHub Actions**
- AGENTS.md, llms.txt, design specs

### Fixes

- Fly app exists before `postgres attach`
- Fly attach credentials (not hard-coded `user: postgres`)
- Railway full-stack service wiring and `up` path
- Example Serverpod deps pinned to `4.0.0-beta.0`

---

## Links

- Package: [pub.dev/packages/podfly](https://pub.dev/packages/podfly)
- Repo: [github.com/127thousand/podfly](https://github.com/127thousand/podfly)
- Docs: [doc/README.md](doc/README.md)
