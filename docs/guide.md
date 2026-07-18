# podfly user guide

## Commands

| Command | Purpose |
|---------|---------|
| `podfly deploy` | Primary entry: doctor → init if needed → deploy |
| `podfly doctor` | Check tools + auth (optionally fix logins) |
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
  ├─ doctor (baseline)
  │     flutter, fly/flyctl — install hints + login if TTY
  │
  ├─ if no podfly.yaml → init wizard (or --yes defaults)
  │     else load podfly.yaml
  │
  ├─ doctor (config-aware)
  │     wrangler if mode: split
  │     neonctl if neon.provision: true
  │     config consistency warnings
  │
  ├─ database ensure (volume / postgres / neon notes)
  ├─ patch server config/production.yaml (with .podfly.bak)
  ├─ flutter web build + packaging recipes
  ├─ deploy Cloudflare Pages and/or Fly
  └─ optional --smoke HTTP checks
```

## Flags

| Flag | Meaning |
|------|---------|
| `--dry-run` | Print planned actions only; no create/deploy/network side effects; doctor skips live auth whoami (tools still checked on PATH); no browser logins |
| `--smoke` | After a real deploy, hit `smoke:` endpoints |
| `--web` | Deploy static UI only (skip Fly when used alone) |
| `--api` | Deploy Fly API only (skip Pages when used alone) |
| `--yes` / `-y` | Non-interactive init defaults (CI) |
| `--no-login` | Never open browser auth (CI; use env tokens) |
| `--init` | Force init wizard even if `podfly.yaml` exists |
| `--mode split\|fly` | Override config mode for this run |
| `--root path` | Project root (default: cwd) |
| `--config path` | Explicit `podfly.yaml` path |

## Prerequisites

### Always

- **Dart / Flutter** on `PATH` (`flutter --version`)
- **fly** or **flyctl** on `PATH`, logged in (`fly auth login` or `FLY_API_TOKEN`)

### When `mode: split`

- **wrangler** on `PATH`, logged in (`wrangler login` or `CLOUDFLARE_API_TOKEN`)
- Cloudflare account that can create Pages projects

### When `database.neon.provision: true`

- **neonctl** (or `neon`), logged in (`neonctl auth` or `NEON_API_KEY`)

### CI / non-TTY

```bash
export FLY_API_TOKEN=…
export CLOUDFLARE_API_TOKEN=…   # if split
export NEON_API_KEY=…           # if provisioning Neon

podfly deploy --yes --no-login --smoke
```

Do not rely on interactive wizard or browser login in CI.

## Project layout

podfly expects a conventional Serverpod monorepo:

```text
my_app/
  pubspec.yaml          # optional workspace root
  podfly.yaml           # created by init
  fly.toml              # created if missing
  my_app_server/
    Dockerfile
    config/production.yaml
    lib/...
  my_app_flutter/
    web/
    lib/...
  my_app_client/        # optional
```

If `server` / `flutter` are omitted from config, podfly scans for `*_server` and `*_flutter` directories.

## Modes

### `split` (recommended for most web apps)

| Layer | Host | Content |
|-------|------|---------|
| Browser UI | `https://<project>.pages.dev` | Flutter web build + assets + CanvasKit |
| API | `https://<app>.fly.dev` | Serverpod only (port 8080) |

Benefits: global CDN for multi‑MB WASM/assets; Fly can scale the API to zero.

### `fly` (everything on one app)

1. Build Flutter web  
2. Copy into `web.static_dir` (default `server/web/app`)  
3. Single `fly deploy`  

Requires your Serverpod server to serve that static tree (or equivalent).

## Doctor

Doctor runs in two scopes:

1. **Baseline** — always (before init)  
2. **Config-aware** — after `podfly.yaml` exists  

On an interactive TTY, unauthenticated tools prompt to run:

- `fly auth login`
- `wrangler login`
- `neonctl auth`

Missing binaries get install hints; optional brew/npm install may be offered.

## Smoke checks

Configured under `smoke:` in `podfly.yaml`. Example:

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
- **Web** URL (split) = `https://<cloudflare.project>.pages.dev` + path  

Fly cold start: allow ~60–90s timeout (podfly uses long HTTP timeouts).

## Wizard / UX notes

- Init uses simple terminal prompts (not a full nocterm TUI). Same questions as the design wizard.
- `podfly deploy --init` asks before overwriting an existing `podfly.yaml` (unless `--yes`).
- `--config path` is used for both load and save when creating config.

## Troubleshooting

| Symptom | What to check |
|---------|----------------|
| Assets/images missing in web build | Must build inside Flutter package — podfly already does this; don’t override with broken external `--output` |
| WASM re-downloads every reload | Bootstrap/SW — see [caching.md](caching.md) |
| Doctor fails on wrangler | `mode: split` needs wrangler; or switch to `mode: fly` |
| Auth tables but no login | Soft warning only — see [database.md](database.md) |
| Deploy works locally, Pages shows old JS | `main.dart.js` is cached up to 1 day; hard-refresh or wait; bootstrap/index are `no-cache` |
| Double slash 404 on API | Ensure `api_url` is normalized (podfly adds trailing `/`); Serverpod client joins `host + endpoint` |

## Related docs

- [Caching & Flutter web](caching.md)  
- [Database providers & detection](database.md)  
- [podfly.yaml reference](podfly.yaml.md)  
