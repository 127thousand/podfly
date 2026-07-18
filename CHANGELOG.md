# Changelog

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
