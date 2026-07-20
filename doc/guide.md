# podfly user guide

## Install

```bash
dart pub global activate podfly
```

Put the pub global bin directory on your `PATH` (often `~/.pub-cache/bin`).

Contributors: activate from git or a local path (see [README](../README.md)).

## Commands

| Command | Purpose |
|---------|---------|
| `podfly deploy` | Primary entry: doctor → init if needed → deploy |
| `podfly doctor` | Check tools + auth (optionally install CLIs / fix logins) |
| `podfly init` | Write `podfly.yaml` only (wizard) |
| `podfly smoke` | Run configured HTTP checks against live URLs |

Bare flags without a subcommand apply to **deploy**:

```bash
podfly --dry-run
podfly --smoke
podfly --web
```

## Deploy flow (order matters)

```text
podfly deploy
  │
  ├─ resolve project root
  ├─ doctor (baseline: flutter + deferred host CLI)
  │
  ├─ if no podfly.yaml → init wizard (or --yes defaults)
  │     else load podfly.yaml
  │
  ├─ doctor (config-aware: host CLI, wrangler, neonctl, …)
  │
  ├─ ensure API app shell (Fly apps create) before DB attach
  ├─ database ensure (fly_postgres / railway_postgres / neon / sqlite / none)
  │     → sidecar + production.yaml / passwords.yaml when creds known
  ├─ flutter web build + packaging (if web enabled)
  ├─ deploy host API and/or web (Pages or Railway static)
  └─ optional --smoke HTTP checks
```

## Flags

| Flag | Meaning |
|------|---------|
| `--dry-run` | Plan only; no create/deploy side effects; no browser logins |
| `--smoke` | After a real deploy, hit `smoke:` endpoints |
| `--web` | Deploy static UI only |
| `--api` | Deploy API only (skip Flutter web) |
| `--yes` / `-y` | Non-interactive init defaults (CI) |
| `--no-login` | Never open browser auth (CI; use env tokens) |
| `--init` | Force init wizard even if `podfly.yaml` exists |
| `--host fly\|railway\|…` | Override API cloud for this run |
| `--mode split\|monolith` | Override layout (`fly` = legacy alias for monolith) |
| `--root path` | Project root (default: cwd) |
| `--config path` | Explicit `podfly.yaml` path |

## Prerequisites

### Always

- **Dart / Flutter** on `PATH` (`flutter --version` when building web)

### Host CLI (only the one you use)

| `host:` | CLI | Auth |
|---------|-----|------|
| `fly` (default) | `fly` / `flyctl` | `fly auth login` or `FLY_API_TOKEN` |
| `railway` | `railway` | `railway login` or `RAILWAY_TOKEN` |
| others (roadmap) | `render` / `gcloud` / … | doctor checks; deploy not implemented |

### When `mode: split` and web on Pages

- **wrangler** on `PATH`, logged in (`wrangler login` or `CLOUDFLARE_API_TOKEN`)

### When `database.neon.provision: true`

- **neonctl** (or `neon`), logged in (`neonctl auth` or `NEON_API_KEY`)

### CI / non-TTY

See **[ci.md](ci.md)** for full workflows. Short form:

```bash
export FLY_API_TOKEN=…           # or RAILWAY_TOKEN
export CLOUDFLARE_API_TOKEN=…    # if Pages web
podfly deploy --yes --no-login --smoke
```

## Project layout

podfly expects a conventional Serverpod monorepo:

```text
my_app/
  pubspec.yaml          # optional workspace root
  podfly.yaml           # created by init
  fly.toml              # Fly; created if missing
  railway.toml          # Railway; created if missing
  my_app_server/
    Dockerfile
    config/production.yaml
    lib/...
  my_app_flutter/
    web/                # optional
    lib/...
  my_app_client/        # optional
```

If `server` / `flutter` are omitted from config, podfly scans for `*_server` and `*_flutter` directories.

## Mobile vs web (client surface)

podfly inspects the Flutter package at init:

| Layout | Result |
|--------|--------|
| `android/` / `ios/` **without** `web/` | **API only** (`web.enabled: false`) |
| Custom production `web/` | **API + web** |
| Stock `web/` scaffold + mobile dirs | Tends toward **API only** (force with `web.enabled: true`) |
| No Flutter package | **API only** |

```yaml
web:
  enabled: false   # mobile clients hit the API; no Pages / no flutter build web
```

```bash
podfly deploy --api          # force API only
podfly deploy --web          # force web half (even if enabled: false)
```

Sample: [`example/mobile_api_only`](../example/mobile_api_only).

## Maximum automation

podfly aims for: **after `serverpod create` + tools logged in, one command ships.**

| Step | Automated? |
|------|------------|
| `podfly.yaml` | Yes (init / `--yes`) |
| Host app/project create | Yes (Fly apps; Railway project/service) |
| `fly.toml` / `railway.toml` | Yes if missing |
| Serverpod `Dockerfile` | Prefer Serverpod’s; template only if missing |
| API app before Postgres attach | Yes (`ensureApiApp`) |
| Fly / Railway Postgres attach + Serverpod password patch | Yes when attach output / plugin vars available |
| Pages project / Railway web service | Yes when deploying web |
| Web bootstrap / `_headers` | Yes if missing and web enabled |
| `publicHost` patch | Yes when still localhost-like |
| Tool install | Doctor recipes (TTY / `PODFLY_AUTO=1`) |
| Tool login | Prompt on TTY; tokens in CI |

```bash
export PODFLY_AUTO=1   # optional: auto-accept install/login prompts on TTY
podfly deploy --yes --smoke
```

## Modes

`mode` is **UI layout**, not which cloud (`host:`).

### `split` (recommended for most web apps)

| Layer | Host | Content |
|-------|------|---------|
| Browser UI | Cloudflare Pages (`*.pages.dev`) | Flutter web + CanvasKit |
| API | Fly (`*.fly.dev`) or Railway | Serverpod (port 8080) |

Benefits: CDN for multi‑MB WASM/assets; API can scale to zero (DB choice matters).

### `monolith` (UI with the API host)

UI is not on Pages. On Fly: optional copy of Flutter web into the server static dir + single deploy.  
On Railway: still separate API vs web **services** when web is enabled (not one process) — just no Cloudflare Pages.

API-only apps usually use `mode: monolith` + `web.enabled: false`.

Legacy: `mode: fly` means the same as `monolith`.

## Doctor

1. **Baseline** — flutter on PATH  
2. **Config-aware** — host CLI, wrangler, neonctl, consistency warnings  

On an interactive TTY, unauthenticated tools may prompt to log in. Missing binaries get install hints.

## Smoke checks

```yaml
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

- **API** URL = `web.api_url` + path  
- **Web** (Pages) = `https://<cloudflare.project>.pages.dev` + path  

Cold start: allow ~60–90s (podfly uses long HTTP timeouts).

## Troubleshooting

| Symptom | What to check |
|---------|----------------|
| Assets missing in web build | Build inside Flutter package — podfly does this |
| WASM re-downloads every reload | [caching.md](caching.md) |
| Doctor fails on wrangler | `mode: split` + web needs wrangler; or `--api` |
| Doctor fails on fly with `host: railway` | Config not loaded / wrong host — only Railway CLI required |
| fly apps create fails | Name taken — change `fly.app` |
| DB auth fail after Fly deploy | Attach sidecar / `passwords.yaml` — see [database.md](database.md) |
| Missing Dockerfile | Run `serverpod create` first |
| Auth tables but no login | Soft warning only — [database.md](database.md) |
| Double slash 404 on API | `api_url` trailing slash (podfly normalizes) |
| CI login prompts | Use tokens + `--no-login` — [ci.md](ci.md) |

## Related docs

- [CI & GitHub Actions](ci.md)  
- [Caching & Flutter web](caching.md)  
- [Database providers & detection](database.md)  
- [podfly.yaml reference](podfly.yaml.md)  
