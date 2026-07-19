# Changelog

## Unreleased

### Features

- **Host adapter registry** (`lib/src/hosts/`): Fly/Railway/planned clouds as `HostAdapter` plugins — no host switches in doctor/deploy/init
- **Railway deploy** (`host: railway`): project/service create, domain, `railway.toml` + `railway up`, doctor resolves `~/.railway/bin`
- **Railway full stack:** `railway_postgres` provider + static Flutter web service (nginx) + optional CDN
- **fix:** railway `up` path, doctor `--config`, free-tier peak-hour retry, project before Postgres
- **Maximum automation pass:** `fly apps create` (+ unique name if taken), name sanitize, Pages project create, optional Dockerfile template if missing, patch production `publicHost` to Fly
- `PODFLY_AUTO=1` skips Y/n on login prompts
- Detect **mobile / API-only** Serverpod projects and set `web.enabled: false`
- Sample: `examples/mobile_api_only` (real `serverpod create --mini`)
- Discover `*_flutter` without `web/`

## 0.1.0

### Features

- Deploy modes: **split** (Cloudflare Pages + Fly) and **fly** (all-on-Fly)
- Commands: `deploy`, `doctor`, `init`, `smoke`
- Deploy implies init when `podfly.yaml` is missing; doctor runs first
- Facilitated login for fly / wrangler / neonctl on TTY
- Database providers: `none`, `sqlite`, `fly_postgres`, `neon`
- DB need detection with **soft** warnings for unused Serverpod template auth
- Flutter web packaging:
  - In-package build + rsync (avoids asset drop bug)
  - Bootstrap without stub service worker
  - Same-origin CanvasKit
  - Cloudflare Pages `_headers` for WASM/assets caching
  - `SERVER_URL` dart-define injection
- Dry-run and smoke HTTP checks

### Documentation

- User guide, caching guide, database guide, config reference
