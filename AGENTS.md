# AGENTS.md — podfly

Instructions for coding agents working in this repo or deploying Serverpod with podfly.

## What podfly is

Thin **orchestrator** over existing cloud CLIs (`fly`, `railway`, `wrangler`, `neonctl`, …).  
It is **not** a host. It generates config, encodes quirks, and runs provider tools.

API clouds are **HostAdapter** plugins under `lib/src/hosts/` (registry). Do not add `switch (host)` in doctor/deploy/init — implement or extend an adapter and register it.

```text
serverpod create …  →  monorepo + Dockerfile (Serverpod owns this)
podfly deploy       →  CLIs + fly.toml + quirks (podfly owns this)
```

## Default user workflow

```bash
# Once: dart pub global activate podfly
# Once: flutter, host CLI (fly or railway), wrangler (if Pages), neonctl (if Neon provision)
# Once: fly auth login / railway login  (and wrangler login if Pages)

serverpod create my_app --mini -f   # or existing Serverpod 4 project
cd my_app
podfly deploy --yes --smoke
```

For agents (non-interactive):

```bash
podfly deploy --yes --no-login --smoke
# CI: FLY_API_TOKEN or RAILWAY_TOKEN; CLOUDFLARE_API_TOKEN if Pages
# See doc/ci.md
```

Dry-run first when unsure:

```bash
podfly deploy --yes --dry-run --no-login
```

## Commands

| Command | Use |
|---------|-----|
| `podfly deploy` | Primary: doctor → init if needed → deploy |
| `podfly doctor` | Tools + auth only |
| `podfly init` | Write `podfly.yaml` only |
| `podfly smoke` | HTTP checks only |
| `podfly deploy --api` | **API only** (mobile / skip web) |
| `podfly deploy --web` | Web half only (Pages or static) |
| `podfly deploy --dry-run` | Plan only, no side effects |

## Critical rules (do not violate)

1. **Do not invent a random Dockerfile.** Prefer Serverpod’s `*_server/Dockerfile`. Podfly may write a Serverpod-style template only if missing.
2. **Do not use `flutter build web --output` outside the package** as the only artifact path — assets can vanish. Podfly builds in-package then copies.
3. **Do not register Flutter’s stub service worker** for production web — podfly bootstrap fixes this when `patch_bootstrap: true`.
4. **Do not require Postgres** just because auth packages are scaffolded — template auth is a soft warning; only hard-require DB when tables/`requireLogin`/real auth use.
5. **Fly app names:** underscores → hyphens (`my_app` → `my-app`). Podfly creates the app if missing (**before** Postgres attach).
6. **Supported API hosts today:** **`host: fly`**, **`host: railway`**, **`host: digitalocean`** (`do`), **`host: render`**, **`host: cloud_run`** (`gcp`). AWS/Azure: doctor only until implemented. Examples: https://github.com/127thousand/podfly_examples7. **Doctor does not require Fly** unless `host: fly` (or default). Railway → `railway` CLI; DigitalOcean → `doctl` + Docker + DOCR. Pages still needs `wrangler` when `mode: split` and web enabled on Cloudflare.
8. **Fly Postgres:** parse attach `DATABASE_URL` into sidecar + `passwords.yaml` — never hardcode superuser `postgres` as the app user.
9. **DigitalOcean Postgres:** public host + SSL; firewall `app:<app-id>` after app create. WASM nginx must not double-set `Content-Type`.
10. **Install for users:** `dart pub global activate podfly` (pub.dev). Git/path activate is for contributors.

## Decision tree

```text
Deploy Serverpod?
  ├─ Need plan only → podfly deploy --dry-run --yes --no-login
  ├─ Mobile / no Flutter web product → web.enabled: false or --api
  ├─ Flutter web + API → mode: split (Pages + API) or mode: monolith (host-native web)
  ├─ Stateless API → database.provider: none
  ├─ Needs PG + scale-to-zero API → neon (or fly_postgres / railway_postgres / digitalocean_postgres)
  └─ DigitalOcean → doctl + Docker + DOCR registry
```

## Config

- File: `podfly.yaml` at monorepo root (created by init).
- Reference: `doc/podfly.yaml.md`
- Full docs index: `doc/README.md`, `llms.txt`

## This repository

- Package: Dart CLI (`bin/podfly.dart`, `lib/src/…`)
- Templates: `templates/`
- Example mobile API-only: `example/mobile_api_only`
- Tests: `dart test` · analyze: `dart analyze`

When changing deploy behavior, update README roadmap status and docs, then `dart test`.
