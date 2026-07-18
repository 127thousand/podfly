# podfly — Design Spec

**Date:** 2026-07-18  
**Status:** Approved for implementation (pending final review of this doc)  
**Package:** `podfly`  
**Binary:** `podfly`  
**Repo:** local `/Users/ben/projects/127k/podfly` · remote `github.com/127thousand/podfly` (sibling of `roitelet`)

## Problem

Deploying a **Serverpod + Flutter web** monorepo involves many non-obvious steps:

- Flutter web assets vanish if you `flutter build web --output` outside the package
- API URL must be baked in (`--dart-define=SERVER_URL=…`)
- Flutter’s default service-worker stub force-navigates tabs and makes WASM feel uncached
- CanvasKit/WASM cache headers matter on the static host
- Two sane topologies exist: **everything on Fly**, or **split** (Cloudflare Pages UI + Fly API)

`podfly` turns that into a reusable Dart CLI with a first-run wizard and a config file.

## Goals (v1)

1. Work on any conventional Serverpod workspace (`*_server`, `*_flutter`, optional `*_client`).
2. Support **two deploy modes**: `split` and `fly`.
3. **Doctor**: check `flutter`, `fly`/`flyctl`, and (for split) `wrangler` — installed **and** authenticated.
4. **Interactive wizard** (`podfly init`) via **nocterm** when TTY; flags/config for CI.
5. Encode battle-tested web packaging: build in-package, optional bootstrap patch, `_headers` / `_redirects`.
6. Dry-run and smoke tests.

## Non-goals (v1)

- Provisioning Postgres/Redis/volumes
- Custom domain / DNS automation
- Pure-Dart reimplementation of Fly or Cloudflare APIs (shell out to official CLIs)
- Mobile/desktop deploys
- Melos-only or non-Serverpod layouts as first-class (heuristic discovery only)

## Approaches considered

| Approach | Verdict |
|----------|---------|
| **A. Thin orchestrator** (Dart → flutter / fly / wrangler) | **Chosen** — matches real tools, ships fast |
| B. Pure Dart HTTP APIs for Fly + CF | Too much auth/upload/API surface for v1 |
| C. Melos plugin only | Too narrow for a pub package |

## CLI surface

```text
podfly doctor          # tools + auth
podfly init            # nocterm wizard → podfly.yaml (+ optional templates)
podfly deploy          # --api | --web | --dry-run | --smoke
podfly smoke           # configured smoke checks only
podfly --help
```

### Flags (non-interactive / CI)

| Flag | Meaning |
|------|---------|
| `--config path` | Default `podfly.yaml` in CWD or walk-up to monorepo root |
| `--mode split\|fly` | Override config |
| `--api` / `--web` | Deploy only one half (split); `--api` only for fly-mono is no-op/all |
| `--dry-run` | Print actions, no side effects |
| `--smoke` | After deploy, run smoke |
| `--root path` | Project root |

### Doctor checks

| Tool | Required when | Auth check |
|------|----------------|------------|
| `dart` / `flutter` | always | `flutter --version` |
| `fly` or `flyctl` | always (both modes) | `fly auth whoami` (or equivalent) |
| `wrangler` | `mode: split` | `wrangler whoami` not “not authenticated”; or `CLOUDFLARE_API_TOKEN` set |
| Node/npm | only if wrangler missing and we offer install hint | n/a |

Doctor exits non-zero if required checks fail; prints install/login hints.

## Config: `podfly.yaml`

Written by `init`, read by `deploy` / `smoke`.

```yaml
# podfly.yaml
mode: split                 # split | fly
name: my-app                # default for fly app + pages project names

server: my_app_server       # relative to config root
flutter: my_app_flutter

fly:
  app: my-app
  region: iad
  config: fly.toml          # path relative to root
  scale_to_zero: true
  ha: false                 # fly deploy --ha=false by default for cheap hobby

cloudflare:                 # ignored when mode: fly
  project: my-app
  branch: main

web:
  server_url_define: SERVER_URL
  api_url: https://my-app.fly.dev/   # trailing slash normalized
  patch_bootstrap: true
  write_headers: true
  base_href: /

smoke:
  api:
    method: POST
    path: /                  # project-specific; init asks
    body: '{}'
    expect_status: 200
  web:
    path: /
    expect_status: 200
```

**Discovery:** if `server` / `flutter` omitted, scan for directories matching `*_server` / `*_flutter` with `pubspec.yaml` (and server depends on `serverpod`).

## Deploy modes

### `split` (Pages UI + Fly API)

1. Preflight doctor (strict).
2. Ensure web templates if `patch_bootstrap` / `write_headers` (merge, don’t clobber custom files unless `--force-templates`).
3. `flutter build web` **from the Flutter package directory** (no external `--output` that drops assets).
4. Copy/rsync to staging dir under root (e.g. `.podfly/web` or `build/web`).
5. Apply `_headers` / `_redirects` into build output.
6. `wrangler pages project create` if missing; `wrangler pages deploy … --project-name … --branch …`.
7. `fly deploy -a … --config … --ha=false` (API image from server Dockerfile).
8. Optional smoke: API URL + `https://{project}.pages.dev`.

**Assumptions for API-only Fly image:** project already has a Dockerfile suitable for Serverpod; `init` can generate a **starter** `fly.toml` (port 8080, scale-to-zero) but does not rewrite production.yaml DB settings automatically in v1 (document checklist).

### `fly` (all on Fly)

1. Preflight doctor (no wrangler required).
2. Build Flutter web into package, then copy into server static web path if configured (e.g. `server/web/app` or path in config — default discover `*/web/app` or document Serverpod convention).
3. Single `fly deploy`.
4. Smoke against `https://{app}.fly.dev`.

v1 may require `web.static_dir` in config for mono mode rather than guessing every Serverpod layout.

## Web packaging details (encoded recipes)

### Bootstrap (`patch_bootstrap: true`)

Ensure Flutter package has `web/flutter_bootstrap.js` that:

- Expands `{{flutter_js}}` / `{{flutter_build_config}}`
- Unregisters leftover service workers
- Does **not** pass `serviceWorkerSettings`
- Sets `canvasKitBaseUrl: 'canvaskit/'` (same-origin WASM)

If user already has a custom bootstrap, only patch when missing markers or with explicit confirm in wizard.

### Headers (`write_headers: true`)

Cloudflare Pages `_headers` template:

- `/canvaskit/*`, `/assets/*` → long immutable cache
- `/main.dart.js`, `/flutter.js` → day cache + SWR
- `index.html`, `flutter_bootstrap.js` → no-cache

Plus SPA-friendly `_redirects` if missing (`/* /index.html 200` carefully — optional; Flutter web often doesn’t need full SPA fallback).

### Build rule

**Always** `cd $flutterPackage && flutter build web …` then copy. Never rely on `--output` outside the package as the sole artifact path (asset drop bug).

## Wizard (nocterm)

When `podfly init` and stdin is a TTY:

1. Detect root / packages
2. Choose mode: split vs fly
3. App name, region, scale-to-zero
4. API URL (default from fly app name)
5. Smoke path/method
6. Write `podfly.yaml`
7. Optionally write templates + starter `fly.toml`
8. Run `doctor` and print next step: `podfly deploy --smoke`

Non-TTY: error with message to pass flags or create yaml manually (or `podfly init --defaults` later).

## Architecture

```text
podfly/
  bin/podfly.dart
  lib/
    podfly.dart                 # public API if any
    src/
      cli.dart                  # arg parsing (args package)
      config.dart               # load/save podfly.yaml
      discover.dart             # find server/flutter packages
      doctor.dart
      process_runner.dart       # run + capture external tools
      deploy/
        split.dart
        fly_mono.dart
      web/
        build.dart
        bootstrap.dart
        headers.dart
      smoke.dart
      wizard/
        app.dart                # nocterm UI
  templates/
    _headers
    _redirects
    flutter_bootstrap.js
    fly.toml.api_only
  test/
  docs/specs/
  README.md
  pubspec.yaml
```

**Dependencies (expected):** `args`, `yaml`, `path`, `io`/`glob`, `nocterm`, `mason_logger` or simple stdout styling.

**External tools:** not bundled; doctor validates.

## Error handling

- Fail fast on doctor failures before long builds
- Stream child process stdout/stderr
- Non-zero exit codes from flutter/fly/wrangler → fail deploy with last N lines of log
- Dry-run never creates projects or deploys

## Testing

- Unit: config parse/normalize (trailing slash on `api_url`), discovery on fixture trees
- Unit: bootstrap template contains required markers
- Integration (optional, marked): dry-run path with fake ProcessRunner

## Distribution

1. Develop in `127k/podfly` git repo
2. Push to `github.com/127thousand/podfly`
3. Activate locally: `dart pub global activate --source path ../podfly` or git ref
4. Later: publish to pub.dev when stable

## Adoption example (sacred-draw / tarot_draw)

After v1: replace `scripts/deploy.sh` with:

```bash
podfly deploy --smoke
```

and a checked-in `podfly.yaml` matching current split setup.

## Open decisions (resolved)

| Decision | Choice |
|----------|--------|
| Package name | `podfly` |
| Repo location | Next to `roitelet` under 127k → `127thousand/podfly` |
| UX | Wizard (nocterm) + config file; flags for CI |
| Architecture | Thin orchestrator |

## Success criteria

- `podfly doctor` correctly reports missing/unauth tools
- `podfly init` produces a valid `podfly.yaml` for a Serverpod monorepo
- `podfly deploy` in `split` mode builds web with assets, deploys Pages + Fly
- `podfly deploy` in `fly` mode deploys without wrangler
- Documented path from tarot_draw-style project to first successful deploy
