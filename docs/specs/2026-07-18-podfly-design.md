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
- Database choice is easy to get wrong: no DB (stateless), SQLite on a volume, Fly Postgres (always costs), or Neon (serverless PG, pairs well with scale-to-zero)

`podfly` turns that into a reusable Dart CLI with a first-run wizard and a config file.

## Goals (v1)

1. Work on any conventional Serverpod workspace (`*_server`, `*_flutter`, optional `*_client`).
2. Support **two deploy modes**: `split` and `fly`.
3. Support **database providers**: `none` | `sqlite` | `fly_postgres` | `neon`.
4. **Doctor**: check `flutter`, `fly`/`flyctl`, and (for split) `wrangler` — installed **and** authenticated; plus provider-specific tools (`neonctl` when using Neon).
5. **Interactive wizard** (`podfly init`) via **nocterm** when TTY; flags/config for CI.
6. Encode battle-tested web packaging: build in-package, optional bootstrap patch, `_headers` / `_redirects`.
7. Wire Serverpod `config/production.yaml` (and Fly secrets / mounts) for the chosen DB — do not leave “forgot database:” as a footgun.
8. Dry-run and smoke tests.

## Non-goals (v1)

- Redis / multi-region DB failover
- Custom domain / DNS automation
- Pure-Dart reimplementation of Fly, Cloudflare, or Neon APIs (shell out to official CLIs)
- Migrating data between providers
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
| `neonctl` (or `neon`) | `database.provider: neon` **and** `database.neon.provision: true` | `neonctl auth` / env token present |
| Node/npm | only if wrangler missing and we offer install hint | n/a |

Doctor also **validates config consistency**, e.g.:

- `sqlite` + `scale_to_zero: true` without a volume → warn (data loss / empty disk on new machine)
- `fly_postgres` → warn that PG app usually bills even when API is stopped
- `none` but `production.yaml` still has `database:` → warn / offer to strip on next init deploy step

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

# ── Database (Serverpod production) ─────────────────────────
database:
  # none | sqlite | fly_postgres | neon
  provider: none

  # --- provider: none ---
  # Omit `database:` from production.yaml (stateless API).
  # sessionLogs.persistentEnabled should be false.

  # --- provider: sqlite ---
  sqlite:
    # Path inside the machine. Prefer a mounted volume path.
    path: /data/serverpod.db
    volume:
      create: true            # fly volumes create …
      name: my-app_data
      size_gb: 1
      # mount path in fly.toml [[mounts]]
      dest: /data

  # --- provider: fly_postgres ---
  fly_postgres:
    # Existing cluster name, or create on init/deploy
    app: my-app-db            # Fly Postgres app name
    create: true              # fly postgres create
    # After attach, Serverpod typically uses internal host from secrets
    # or explicit database: block in production.yaml
    # Database name/user often match project; password via passwords.yaml / secrets

  # --- provider: neon ---
  neon:
    # Option A: use existing connection string (no neonctl)
    # Prefer Fly secret — never commit the password.
    connection_string_secret: DATABASE_URL   # fly secrets set
    # Option B: provision (requires neonctl + auth)
    provision: false
    project_name: my-app                    # when provision: true
    region: aws-us-east-1                   # Neon region id
    # Serverpod production.yaml can use host/port/user/name + password from env/secret
    # or a single URL if the project supports it — podfly documents the Serverpod-shaped block

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

## Database providers

Serverpod expects a `database:` block in run-mode YAML (or none, if the app never opens a pool). `podfly` makes the choice explicit and applies it on `init` / before `deploy`.

| Provider | Best for | Cost / scale notes | What podfly does |
|----------|----------|--------------------|------------------|
| **`none`** | Stateless APIs (e.g. sacred-draw deck-in-JSON) | Cheapest; API can scale to zero cleanly | Strip or omit `database:` in production; set `sessionLogs.persistentEnabled: false`; warn if migrations exist |
| **`sqlite`** | Tiny apps, single-machine persistence | Volume ~$; **not** multi-machine HA | `fly volumes create` + `[[mounts]]`; production `database` / sqlite path per Serverpod version; document “one machine” (`ha: false`, `min_machines` 0–1) |
| **`fly_postgres`** | Classic Serverpod, private network | **PG stays on** → ongoing bill even if API auto-stops | `fly postgres create` (optional), `fly postgres attach`, write `database:` host to Fly internal hostname; store password in `passwords.yaml` / Fly secrets pattern Serverpod expects |
| **`neon`** | Serverless PG + scale-to-zero API | Neon free/paid tiers; sleep when idle | Set Fly secret (`DATABASE_URL` or discrete fields); write production `database:` with Neon host + `requireSsl: true`; optional `neonctl` provision |

### Tradeoffs to surface in the wizard

```text
                    API scale-to-zero    Multi-machine    Ops complexity
none                     ✓                   ✓              low
sqlite                   ✓*                  ✗              medium (volume)
neon                     ✓                   ✓              medium (SSL + secret)
fly_postgres             △**                 ✓              medium-high
```

\* SQLite + scale-to-zero needs a **persistent volume**; cold start still works, data survives.  
\*\* Fly Postgres is a separate app; API can stop but **DB cost remains**.

### Applying config to Serverpod

`podfly` will **patch** (with backup) `server/config/production.yaml`:

- **`none`**: remove `database:` key; ensure redis off if unused; `sessionLogs.persistentEnabled: false`.
- **`sqlite`**: write sqlite-oriented settings supported by the detected Serverpod version (path on volume). If the installed Serverpod only supports Postgres, doctor fails with a clear message (no silent misconfig).
- **`fly_postgres` / `neon`**: write:

```yaml
database:
  host: <internal-or-neon-host>
  port: 5432
  name: <db>
  user: <user>
  requireSsl: true   # neon: true; fly private network: often false
```

Password: Serverpod’s `config/passwords.yaml` `production.database` **or** env injection — prefer **Fly secrets** and document the Serverpod password resolution path used by the project’s version. Never commit real secrets; `init` writes placeholders + `fly secrets set` commands.

### Migrations

- If `provider != none` and `server/migrations/` is non-empty: `deploy` runs or prints `serverpod create-migration` / apply steps (v1: **print checklist + optional `dart run` / server entry apply** if standard; do not invent a second migration tool).
- If `provider: none` and migrations exist: **warn** that production has no DB.

### Provisioning commands (orchestrated)

| Provider | First-time actions |
|----------|-------------------|
| `none` | Config patch only |
| `sqlite` | `fly volumes create …`; ensure `fly.toml` `[[mounts]]`; deploy with single machine |
| `fly_postgres` | `fly postgres create --name … --region …`; `fly postgres attach … -a <api-app>`; patch production host to attached hostname |
| `neon` | Either paste connection string → `fly secrets set`, or `neonctl projects create` + fetch connection URI → secret |

Provisioning is **idempotent-ish**: skip create if named resource already exists; never destroy without an explicit `podfly db destroy` (out of v1 — only create/attach).

## Deploy modes

### `split` (Pages UI + Fly API)

1. Preflight doctor (strict) including DB tool checks.
2. Ensure DB resources (volume / postgres / neon secret) if `create`/`provision` flags set.
3. Patch production.yaml for database provider (backup `.bak`).
4. Ensure web templates if `patch_bootstrap` / `write_headers` (merge, don’t clobber custom files unless `--force-templates`).
5. `flutter build web` **from the Flutter package directory** (no external `--output` that drops assets).
6. Copy/rsync to staging dir under root (e.g. `.podfly/web` or `build/web`).
7. Apply `_headers` / `_redirects` into build output.
8. `wrangler pages project create` if missing; `wrangler pages deploy … --project-name … --branch …`.
9. `fly deploy -a … --config … --ha=false` (API image from server Dockerfile).
10. Optional smoke: API URL + `https://{project}.pages.dev`.

**Assumptions for API-only Fly image:** project already has a Dockerfile suitable for Serverpod; `init` can generate a **starter** `fly.toml` (port 8080, scale-to-zero, optional mounts).

### `fly` (all on Fly)

1. Preflight doctor (no wrangler required).
2. Same DB ensure + production.yaml patch as split.
3. Build Flutter web into package, then copy into server static web path if configured (e.g. `server/web/app` or path in config — default discover `*/web/app` or document Serverpod convention).
4. Single `fly deploy`.
5. Smoke against `https://{app}.fly.dev`.

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
4. **Database provider** with short cost/scale blurb:
   - none (stateless)
   - sqlite (+ volume)
   - fly_postgres
   - neon (existing URL vs provision)
5. Provider-specific fields (volume size, PG app name, Neon region / paste URL)
6. API URL (default from fly app name)
7. Smoke path/method
8. Write `podfly.yaml`
9. Optionally write templates + starter `fly.toml` (+ mounts if sqlite)
10. Run `doctor` and print next step: `podfly deploy --smoke`

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
      database/
        provider.dart           # enum + validation
        none.dart
        sqlite.dart             # volume + path
        fly_postgres.dart       # create/attach
        neon.dart               # secret + optional neonctl
        production_yaml.dart    # patch server config
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
    fly.toml.with_volume
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
- Unit: production.yaml patch for each `database.provider` (fixture YAML in/out)
- Unit: doctor consistency warnings (sqlite without volume, none with migrations)
- Integration (optional, marked): dry-run path with fake ProcessRunner (including `fly postgres` / `neonctl` no-ops)

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

and a checked-in `podfly.yaml` matching current split setup + `database.provider: none`.

## Open decisions (resolved)

| Decision | Choice |
|----------|--------|
| Package name | `podfly` |
| Repo location | Next to `roitelet` under 127k → `127thousand/podfly` |
| UX | Wizard (nocterm) + config file; flags for CI |
| Architecture | Thin orchestrator |
| Database | `none` \| `sqlite` \| `fly_postgres` \| `neon` in v1 |

## Success criteria

- `podfly doctor` correctly reports missing/unauth tools (including neonctl when needed)
- `podfly init` produces a valid `podfly.yaml` including database choice
- `podfly deploy` patches production.yaml appropriately for each provider
- `split` mode builds web with assets, deploys Pages + Fly
- `fly` mode deploys without wrangler
- Documented path from tarot_draw-style project (`database: none`) to first successful deploy
- Documented path for a Serverpod app with Neon or Fly Postgres
