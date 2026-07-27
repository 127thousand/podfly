# Changelog

All notable changes to **podfly** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

### Planned (parked)

- **AWS RDS / Cloud SQL / Azure Database for PostgreSQL** — enterprise Postgres providers
- **`podfly create`** recipes beyond Serverpod (dart_frog, relic, grpc) and app kit
  (see [doc/specs/2026-07-25-podfly-create-roadmap.md](doc/specs/2026-07-25-podfly-create-roadmap.md))

---

## [0.11.2] — 2026-07-26

### Added

- **Banner shimmer** restored on color TTYs (~0.5s purple→white sweep over
  PODFLy). Skipped for quiet, `NO_COLOR`, pipes, `CI=true`, or
  `PODFLY_NO_SHIMMER=1`.

---

## [0.11.1] — 2026-07-26

### Fixed

- **Fly app create** — detect `Name has already been taken` from captured
  CLI output (inheritStdio left stderr empty, so retries never ran). On
  global collision, try `preferred-xxxx` and persist the new name to
  `podfly.yaml`.

---

## [0.11.0] — 2026-07-26

### Added

- **`podfly create`** — one-shot Serverpod scaffold + `podfly.yaml`:
  wraps `serverpod create` (or `flutter create` for app-only), then init with
  host/mode/web overrides (no second wizard).
- **Create hardening:** `--database` drives template (`mini` / `fullstack`);
  mobile-only → API + Codemagic; post-create host CLI/login tips; app-only
  experimental; richer `PODFLY.md`.
- **`InitOverrides`** on `Initer` for non-interactive create/deploy glue.
- **`podfly upgrade`** — `dart pub global activate` (pub.dev, `--git`, `--path`).
- **`podfly version` / `--version`** — embedded package version.
- **Detailed help** — `podfly help [topic]` and `podfly <cmd> --help`
  (create, deploy, destroy, doctor, init, smoke, upgrade, hosts, config, workflow).

### Changed

- Help text leads with `podfly create` as the first-time path.
- **CLI UI** — OpenCode/clack-style half-block PODFLy banner and tree steps
  (`┌` `│` `●` `◇` `└`).

---

## [0.10.15] — 2026-07-25

### Added

- **Banner shimmer** on color TTYs (~0.5s purple→white sweep over the PODFLY
  wordmark). Skipped for quiet, `NO_COLOR`, pipes, `CI=true`, or
  `PODFLY_NO_SHIMMER=1`.

---

## [0.10.14] — 2026-07-24

### Changed

- **Cloud Run** `session_affinity` defaults to **`true`** (sticky sessions for
  WebSocket streams when scaled out). Set `cloud_run.session_affinity: false`
  to opt out. Omitted YAML key now means on (`!= false`), not off.

---

## [0.10.13] — 2026-07-24

### Fixed

- **All all-in-one monoliths** (Fly, Cloud Run, AWS App Runner, ECS, Azure,
  Hetzner) share one path: [NginxMonolithImage] writes root Dockerfile + nginx
  + start.sh, patches `apiServer.port: 8081`, and deploys never rely on
  “copy into `web/app` only”. Docker builds use
  `NginxMonolithImage.relativeDockerfile` so API-only does not pick a stale
  root monolith image.
- CDN split: Vercel/Netlify headers for `*.mjs` (`text/javascript`) for
  `web.build: wasm`.

---

## [0.10.12] — 2026-07-24

### Fixed

- **Fly.io monolith:** use the same **nginx + Serverpod** image as Cloud Run
  (`internal_port` 8080 → static Flutter + API/WS on :8081). Copying Flutter into
  `web/app` alone left the proxy hitting the wrong port after Cloud Run had
  moved `apiServer` to 8081 (request timeouts on `*.fly.dev`).

---

## [0.10.11] — 2026-07-24

### Fixed

- **`web.build: wasm` on nginx hosts:** serve `.mjs` as `text/javascript` (Alpine
  mime.types defaults to `application/octet-stream`, so browsers reject
  `main.dart.mjs` after a successful first paint / cold cache).

---

## [0.10.10] — 2026-07-24

### Added

- **`web.build`** Flutter web compile mode (init menu + `podfly.yaml`):
  - `canvaskit` (default) — same-origin CanvasKit; silences wasm dry-run noise
  - `canvaskit_cdn` — CanvasKit engine from Flutter CDN (smaller image)
  - `wasm` — `flutter build web --wasm` (dart2wasm / skwasm)
- Init asks **Flutter web build** when topology includes web.

### Fixed

- Cloud Run default `api_url` no longer invents a fake `*-region-project.a.run.app`
  host (was baked into `SERVER_URL` and 404’d form submits).

---

## [0.10.9] — 2026-07-24

### Fixed

- **`podfly destroy`:** do not delete Cloudflare/Vercel/Netlify for **monolith**
  (UI is inside the API service) or native-web hosts — only when
  `usesStaticWebHost` (real CDN split deploy).

---

## [0.10.8] — 2026-07-24

### Fixed

- **Cloud Run monolith:** real one-URL UI — multi-stage **nginx + Serverpod** image
  (Flutter static on public port, API/WS on :8081). Copying into `web/app` alone left
  the API answering `/` because Cloud Run only exposes one port.
  - Writes root `Dockerfile` + `deploy/nginx.cloud_run_monolith.conf` + start script
  - Patches `production.yaml` `apiServer.port: 8081`
  - Uses pre-built `build/web` from podfly’s Flutter web step

---

## [0.10.7] — 2026-07-24

### Fixed

- **Wizard:** stop asking for smoke HTTP method/path — default `POST /greeting/hello`
  (Serverpod mini). Override via `smoke:` in `podfly.yaml` if needed.

---

## [0.10.6] — 2026-07-24

### Fixed

- **Host capability menus:** each API cloud shows what it supports
  (`API · monolith · CDN split` or `native web`). Topology choices are built
  from those flags so Cloud Run / Azure / Hetzner / AWS offer **monolith**.
- Cloud Run (and peers) can use **CDN split** again (`usesStaticWebHost`).
- Tip when monolith is unavailable for a host.

---

## [0.10.5] — 2026-07-24

### Fixed

- **Monolith vs API-only:** topology menu is one clear choice (Monolith / Split / API only).
  Previously API-only was saved as `mode: monolith` with `web.enabled: false`, so picking
  “monolith” intent was easy to miss and only the API deployed.
- **Monolith web copy:** fallback recursive copy when `rsync` is missing; verify `index.html`
- Warn when `mode: monolith` + `web.enabled: false`; print UI URL for true monolith deploys

---

## [0.10.4] — 2026-07-24

### Changed

- **Interactive menus:** ↑/↓ arrow selection (j/k + Enter) via `mason_logger`
  instead of numbered `1) 2) 3)` prompts — host, CDN, database, confirmations

---

## [0.10.3] — 2026-07-24

### Fixed

- **Timer:** always print total wall-clock time at end of `podfly deploy` (even if smoke fails)
- **Interactive re-pick:** without `--yes`, existing `podfly.yaml` prompts
  "Change API cloud / UI CDN / database?" instead of silently reusing Fly/Cloudflare

---

## [0.10.2] — 2026-07-24

### Changed

- Banner slogan: `🚀 Serverpod, 🍷 BYO cloud.`

---

## [0.10.1] — 2026-07-24

### Changed

- **Banner:** Serverpod-style big-letter `PODFLY` ASCII art in purple (replaces the small box)

---

## [0.10.0] — 2026-07-24

### Added

- **Purple banner**, restrained ANSI color, emojis, ASCII spinners (`Log`); respects `NO_COLOR`
- **Deploy timer** — `⏱ Deploy finished in Xm Ys` plus tip for `podfly destroy`
- **`podfly destroy` / `nuke`** — tear down API + static web from `podfly.yaml`
  - Confirm on TTY; `--yes` for CI; `--dry-run`; `--database` opt-in for managed PG
  - Fly, Cloudflare Pages, Vercel, Netlify, GitHub Pages, DO apps, Cloud Run; others warned
- **Interactive CDN picker** on first init (Cloudflare / Vercel / Netlify / GitHub Pages)
- Tips when `--yes` skips host/CDN questions; show host from existing config on redeploy

---

## [0.9.1] — 2026-07-24

### Fixed

- **Cloudflare Pages:** sanitize project names (underscores → hyphens). Wrangler
  rejects names like `hello_podfly` (`code: 8000003`); use `hello-podfly`.

---

## [0.9.0] — 2026-07-24

### Added

- **`mobile.provider: codemagic`** — generate **`codemagic.yaml`** for Flutter iOS/Android
  - Workflows `ios-ipa` / `android-appbundle` bake `web.api_url` into `--dart-define`
  - Writes only when missing (never overwrites hand-tuned signing)
  - API-only init defaults Codemagic on; doctor notes file status
  - Does **not** trigger builds or manage store secrets (dashboard / REST API)
  - **[doc/codemagic.md](doc/codemagic.md)** · example `example/mobile_api_only`
- **`mobile.provider: github_actions`** — generate **`.github/workflows/mobile-*.yml`**
  - **`fastlane: true` (default)** — also scaffolds `Gemfile` + `fastlane/Fastfile|Appfile|Matchfile`
    under the Flutter package; workflows run `bundle exec fastlane` (lanes: `build` /
    `ios beta` / `android internal`). Store upload steps commented until secrets are set.
  - **`fastlane: false`** — compile-only plain `flutter build` workflows
  - Same `SERVER_URL` dart-define; never full-overwrites existing files
  - **[doc/github_actions_mobile.md](doc/github_actions_mobile.md)**
- **Mobile API URL sync** — each `podfly deploy` rewrites only `SERVER_URL` /
  `--dart-define=…` lines in existing GHA workflows and `codemagic.yaml` from
  the live/configured API URL (`# podfly:api_url`); runs after API deploy so the
  host is known
- **`redis.provider: upstash`** — optional Serverpod Redis (cache/PubSub)
  - `upstash redis create/list/get` when `provision: true`
  - Sidecar `.podfly_upstash_redis.json`; patches `production.yaml` + `passwords.yaml`
  - Fly: `SERVERPOD_REDIS_ENABLED|HOST|PORT|REQUIRE_SSL` + `SERVERPOD_PASSWORD_redis`
  - Doctor: `@upstash/cli` + login / `UPSTASH_EMAIL` + `UPSTASH_API_KEY`
  - **[doc/upstash.md](doc/upstash.md)** — provision, secrets, multi-machine PubSub proof, teardown
  - Example: [upstash/pubsub_chat](https://github.com/127thousand/podfly_examples/tree/main/upstash/pubsub_chat)
    (Fly HA + Netlify chat; CROSS-MACHINE UI; demo stack torn down after verify)
- **`database.provider: supabase`** — managed Postgres via Supabase CLI
  - `supabase projects create/list` when `provision: true` (generated DB password)
  - Sidecar `.podfly_supabase_pg.json`; patches `production.yaml` + `passwords.yaml`
  - Doctor: `supabase` + login / `SUPABASE_ACCESS_TOKEN`
  - Default **session pooler** (IPv4) so Fly DB endpoints do not hang on
    IPv6-only `db.<ref>.supabase.co`; ignores stale direct `host` overrides
  - **[doc/supabase.md](doc/supabase.md)**
- **Netlify:** `sites:create` when site is missing — `--site-name` alone no longer creates sites

---

## [0.8.0] — 2026-07-22

### Added

- **`web_host: vercel`** — Flutter web static on **Vercel** (same role as Cloudflare Pages)
  - Creates project if missing (`vercel project add`), then `vercel deploy … --prod`
  - Writes `vercel.json` (SPA rewrites + WASM / cache headers) unless project provides one
  - Doctor: `vercel` CLI + `vercel whoami` / `VERCEL_TOKEN`
  - Example: [vercel/split_fly](https://github.com/127thousand/podfly_examples/tree/main/vercel/split_fly),
    [vercel/realtime_split](https://github.com/127thousand/podfly_examples/tree/main/vercel/realtime_split)
- **`web_host: netlify`** — Flutter web static on **Netlify**
  - Creates site if missing (`--site-name`), then `netlify deploy --dir … --prod --no-build`
  - Writes `netlify.toml` (SPA rewrites + WASM / cache headers) unless project provides one
  - Doctor: `netlify` CLI + `netlify status` / `NETLIFY_AUTH_TOKEN`
  - **[doc/netlify.md](doc/netlify.md)** — config, CI token, realtime split, teardown
  - Examples: [netlify/split_fly](https://github.com/127thousand/podfly_examples/tree/main/netlify/split_fly),
    [netlify/realtime_split](https://github.com/127thousand/podfly_examples/tree/main/netlify/realtime_split)
- **`web_host: github_pages`** — Flutter web static on **GitHub Pages**
  - Creates repo if missing (`gh repo create`), force-pushes `gh-pages` branch
  - Writes `.nojekyll` + `404.html` SPA fallback; auto `base_href: /<repo>/`
  - Doctor: `gh` + `git` + `gh auth status`
  - **[doc/github_pages.md](doc/github_pages.md)**
  - Examples: [github_pages/split_fly](https://github.com/127thousand/podfly_examples/tree/main/github_pages/split_fly),
    [github_pages/realtime_split](https://github.com/127thousand/podfly_examples/tree/main/github_pages/realtime_split)
- Top-level **`web_host`**: `cloudflare` (default) \| `vercel` \| `netlify` \| `github_pages`
- Refactor: `StaticWebDeployer` for Pages/Vercel/Netlify/GitHub Pages
- Docs: `llms.txt`, `AGENTS.md`, guide/ci/podfly.yaml updated for static CDN matrix + realtime split

---

## [0.7.0] — 2026-07-21

### Added

- **`host: hetzner`** (aliases `hcloud`, `hetzner_cloud`): Hetzner Cloud VPS
  - Interactive: pick **existing** server or **create** (location → type from live API)
  - Non-interactive: bound `server_id`/`ipv4` or `create: true` + policy
  - Local Docker build → `docker save \| ssh docker load` → container on :8080
  - **Caddy HTTPS :443** (Let's Encrypt) via PTR hostname or `hetzner.domain`
  - Ubuntu pin + remote Docker bootstrap; WebSockets OK
- Examples: [hetzner/api_only](https://github.com/127thousand/podfly_examples/tree/main/hetzner/api_only), [hetzner/realtime_monolith](https://github.com/127thousand/podfly_examples/tree/main/hetzner/realtime_monolith)
- **[doc/hetzner.md](doc/hetzner.md)** — bind vs create, domains/HTTPS, teardown
- `DeployContext.nonInteractive` from `podfly deploy --yes`

---

## [0.6.0] — 2026-07-21

### Added

- **`host: azure`** (aliases `aca`, `containerapps`, `container_apps`): **Azure Container Apps**
  - Local Docker build (`linux/amd64`) → **ACR** (Basic, admin) → managed environment + app
  - Creates resource group / ACR / environment when missing; external ingress, target port 8080
  - Scale-to-zero via `min_replicas: 0`; WebSockets supported (unlike App Runner)
  - Config: app, resource_group, location, environment, registry, cpu/memory, replicas
- Examples: [azure/api_only](https://github.com/127thousand/podfly_examples/tree/main/azure/api_only), [azure/realtime_monolith](https://github.com/127thousand/podfly_examples/tree/main/azure/realtime_monolith)
- **[doc/azure.md](doc/azure.md)** — deploy flow, teardown (delete resource group)
- **`host: aws_ecs`** (aliases `ecs`, `fargate`): ECS Fargate + **ALB** (WebSocket-capable)
  - Docker → private ECR → task definition → Fargate service behind internet-facing ALB
  - ALB idle timeout (default 3600s), optional stickiness; HTTP :80 for demos (no ACM)
- Example: [aws/ecs_realtime](https://github.com/127thousand/podfly_examples/tree/main/aws/ecs_realtime)
- **AWS App Runner** `ecr_public: true` — push to ECR Public + `ImageRepositoryType: ECR_PUBLIC`
- Prefer monorepo **root Dockerfile** when present (nginx monolith images)
- Example: [aws/realtime_monolith](https://github.com/127thousand/podfly_examples/tree/main/aws/realtime_monolith)
- **[doc/aws.md](doc/aws.md)** — App Runner WebSocket limitation (managed Envoy 403)
- **Sketch:** [ECS Fargate + ALB realtime](doc/specs/2026-07-21-aws-ecs-realtime-sketch.md)

### Changed

- **Cloud Run:** always pass `--execution-environment` (default **`gen2`** via `cloud_run.execution_environment`)

---

## [0.5.0] — 2026-07-21

### Added

- **`host: aws`** (aliases `apprunner`, `app_runner`, `amazon`): AWS **App Runner** deploy
  - Local Docker build (`linux/amd64`) → **ECR** push → `create-service` / `update-service`
  - Auto-creates ECR repository + `AppRunnerECRAccessRole` (ECR pull) when missing
  - Config: region, cpu/memory, port, ecr_repository, `start_command`, service_arn, env
  - Default `start_command: /app/entrypoint.sh` (App Runner often fails CREATE without it)
  - TCP health check (works without a custom HTTP path)
- Example: [podfly_examples/aws/api_only](https://github.com/127thousand/podfly_examples/tree/main/aws/api_only)

---

## [0.4.1] — 2026-07-21

### Added

- **Cloud Run** `timeout_seconds` (default 300, max 3600) and `session_affinity` for long-lived WebSockets
- Example: [podfly_examples/gcp/realtime_monolith](https://github.com/127thousand/podfly_examples/tree/main/gcp/realtime_monolith) — Flutter web + Serverpod streams in one Cloud Run service (nginx monolith)

---

## [0.4.0] — 2026-07-21

### Added

- **`host: cloud_run`** (aliases `gcp`, `google`, `cloudrun`): Google Cloud Run API deploy via `gcloud run deploy --source`
  - Config: project, region, memory/cpu, min/max instances, Cloud SQL instance attach list
  - Copies server Dockerfile to monorepo root when needed (Cloud Run source build)
  - Auth: active `gcloud` account or `GOOGLE_APPLICATION_CREDENTIALS`
  - Positioning: inexpensive **stateless** Serverpod (not GCE/Terraform)
- Example: [podfly_examples/gcp/api_only](https://github.com/127thousand/podfly_examples/tree/main/gcp/api_only)

---

## [0.3.1] — 2026-07-20

### Added

- **Render static sites** for Flutter web (`deployWeb`): stage `site/`, git push, `static_site` service
- Example: [podfly_examples/render/api_and_static](https://github.com/127thousand/podfly_examples/tree/main/render/api_and_static)

### Fixed

- Resolve Render service URL by service id (avoid picking another `*.onrender.com`)
- Smoke `web:` uses `render.web_public_host` when set

---

## [0.3.0] — 2026-07-20

### Added

- **`host: render`**: Render web service (git + Docker) via `render` CLI
  - Monorepo support via `render.root_dir` (maps to Render `rootDir`)
  - Generates starter `render.yaml` Blueprint when missing
  - Auth: `render login` or `RENDER_API_KEY`
- **`database.provider: render_postgres`**: create/lookup free/paid PG, fetch connection info, sidecar + Serverpod config patch
- Examples monorepo: [podfly_examples](https://github.com/127thousand/podfly_examples) (`fly/api_only`, `render/api_postgres`)

### Changed

- Provider roadmap: Render marked supported (was planned)

---

## [0.2.2] — 2026-07-20

### Added

- README hero image (`doc/images/podfly-hero.jpg`)

### Changed

- Docs: clarify value prop — `serverpod create` then `podfly deploy` is enough; `fly.toml` / host configs are generated when missing (examples commit them only for stable CI)
- Docs: **Serverpod version compatibility** — 4.x primary; Serverpod **3.4.11** smoke-tested on Fly (mini + `none`, server template + `fly_postgres`)
- Example `mobile_api_only` README: product story, optional `fly.toml`, greenfield setup path

---

## [0.2.1] — 2026-07-20

### Added

- **Example CI:** `example/mobile_api_only` GitHub Actions workflows for Fly API-only deploy on every push to `main` (+ PR dry-run)
- Live demo repo: [127thousand/podfly-api-only-demo](https://github.com/127thousand/podfly-api-only-demo)

### Fixed

- Doctor no longer hard-requires **Flutter** for API-only deploys (`--api` or `web.enabled: false`) — unblocks GitHub Actions without Flutter SDK

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
