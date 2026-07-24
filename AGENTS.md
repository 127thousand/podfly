# AGENTS.md — podfly

Instructions for coding agents working in this repo or deploying Serverpod with podfly.

## What podfly is

Thin **orchestrator** over existing cloud CLIs (`fly`, `railway`, `wrangler`,
`vercel`, `netlify`, `gh`, `neonctl`, …).  
It is **not** a host. It generates config, encodes quirks, and runs provider tools.

API clouds are **HostAdapter** plugins under `lib/src/hosts/` (registry). Do not add
`switch (host)` in doctor/deploy/init — implement or extend an adapter and register it.

Static Flutter CDNs use **`web_host`** + `StaticWebDeployer` (`lib/src/web/static_web.dart`),
not HostAdapter.

```text
serverpod create …  →  monorepo + Dockerfile (Serverpod owns this)
podfly deploy       →  CLIs + fly.toml + quirks (podfly owns this)
```

## Default user workflow

```bash
# Once: dart pub global activate podfly
# Once: flutter, host CLI (fly or railway or …), static CDN CLI if split web
# Once: fly auth login / railway login / wrangler|vercel|netlify|gh login as needed

serverpod create my_app --mini -f   # or existing Serverpod 4 project
cd my_app
podfly deploy --yes --smoke
```

For agents (non-interactive):

```bash
podfly deploy --yes --no-login --smoke
# CI: FLY_API_TOKEN or RAILWAY_TOKEN; plus CDN token if split UI
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
| `podfly deploy --api` | **API only** (mobile / skip web); writes `codemagic.yaml` if `mobile.provider: codemagic` |
| `podfly deploy --web` | Web half only (static CDN or host-native) |
| `podfly deploy --dry-run` | Plan only, no side effects |

## Critical rules (do not violate)

1. **Do not invent a random Dockerfile.** Prefer Serverpod’s `*_server/Dockerfile`. Podfly may write a Serverpod-style template only if missing.
2. **Do not use `flutter build web --output` outside the package** as the only artifact path — assets can vanish. Podfly builds in-package then copies.
3. **Do not register Flutter’s stub service worker** for production web — podfly bootstrap fixes this when `patch_bootstrap: true`.
4. **Do not require Postgres** just because auth packages are scaffolded — template auth is a soft warning; only hard-require DB when tables/`requireLogin`/real auth use.
5. **Fly app names:** underscores → hyphens (`my_app` → `my-app`). Podfly creates the app if missing (**before** Postgres attach).
6. **Supported API hosts:** **`host: fly`**, **`railway`**, **`digitalocean`**, **`render`**, **`cloud_run`**, **`aws`** (App Runner), **`aws_ecs`** (Fargate+ALB), **`azure`** (Container Apps), **`hetzner`** (VPS + Docker/SSH). Examples: https://github.com/127thousand/podfly_examples
7. **Doctor only requires the chosen host CLI.** Split UI:  
   - `web_host: cloudflare` → `wrangler` (+ optional `CLOUDFLARE_API_TOKEN`)  
   - `web_host: vercel` → `vercel` (+ optional `VERCEL_TOKEN`)  
   - `web_host: netlify` → `netlify` (+ optional `NETLIFY_AUTH_TOKEN`)  
   - `web_host: github_pages` → `gh` + `git`  
7b. **App Runner has no WebSockets** (Envoy 403). AWS streams → **`host: aws_ecs`**. Azure ACA and Hetzner support WS. Hetzner has no product FQDN — Caddy + PTR or `hetzner.domain`. Details: `doc/aws.md`, `doc/azure.md`, `doc/hetzner.md`.
7c. **Static CDNs are not API hosts.** Serverpod RPC + WebSockets stay on `host:`. For split realtime, bake `SERVER_URL` to the API origin; never same-origin fallback on `*.vercel.app` / `*.netlify.app` / `*.github.io`. See `doc/netlify.md`, `doc/github_pages.md`.
8. **Fly Postgres:** parse attach `DATABASE_URL` into sidecar + `passwords.yaml` — never hardcode superuser `postgres` as the app user.
9. **DigitalOcean Postgres:** public host + SSL; firewall `app:<app-id>` after app create. WASM nginx must not double-set `Content-Type`.
10. **Install for users:** `dart pub global activate podfly` (pub.dev). Git/path activate is for contributors.
11. **GitHub Pages project sites** need `web.base_href: /<repo>/` (podfly auto-sets when `base_href` is still `/`).
12. **Redis is optional.** Default off. Multi-instance cache/PubSub → `redis.provider: upstash` (`upstash` CLI). Prove fan-out with ≥2 machines + send machine ≠ WS machine (see `doc/upstash.md`, example `upstash/pubsub_chat`). Never commit `.podfly_upstash_redis.json` or Redis passwords.
13. **Supabase is Postgres only** (`database.provider: supabase`) — not Auth/Storage/Realtime. Password lives in `.podfly_supabase_pg.json` (create-time only). See `doc/supabase.md`.

## Decision tree

```text
Deploy Serverpod?
  ├─ Need plan only → podfly deploy --dry-run --yes --no-login
  ├─ Mobile / no Flutter web product → web.enabled: false or --api
  ├─ Flutter web + API → mode: split (CDN UI + API) or mode: monolith (host-native web)
  │    └─ CDN choice → web_host: cloudflare | vercel | netlify | github_pages
  ├─ Need streams → API host that supports WS (not App Runner; not the CDN)
  ├─ Stateless API → database.provider: none
  ├─ Needs PG + scale-to-zero API → neon (or fly_postgres / railway_postgres / …)
  └─ DigitalOcean → doctl + Docker + DOCR registry
```

## Config

- File: `podfly.yaml` at monorepo root (created by init).
- Reference: `doc/podfly.yaml.md`
- Full docs index: `doc/README.md`, `llms.txt`

## This repository

- Package: Dart CLI (`bin/podfly.dart`, `lib/src/…`)
- Templates: `templates/` (`vercel.json`, `netlify.toml`, `_headers`, …)
- Example mobile API-only: `example/mobile_api_only`
- Tests: `dart test` · analyze: `dart analyze`

When changing deploy behavior, update README, `llms.txt`, `AGENTS.md`, host docs,
and CHANGELOG, then `dart test`.
