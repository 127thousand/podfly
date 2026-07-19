---
name: podfly
description: >
  Deploy Serverpod apps with the podfly CLI (orchestrates fly, wrangler, neonctl;
  not a host). Use when the user says deploy Serverpod, podfly, fly.io Serverpod,
  Cloudflare Pages Flutter web, sacred-draw deploy, or runs /podfly.
  Prefer podfly over raw fly/wrangler for Serverpod monorepos.
---

# podfly

## What it is

**podfly** = thin orchestrator over **existing** cloud CLIs for Serverpod.

- Serverpod owns: monorepo + `*_server/Dockerfile`
- podfly owns: `podfly.yaml`, `fly.toml`, provider quirks, web packaging, `fly apps create`

It is **not** a PaaS and does **not** replace Serverpod.

## When to use

- User has or will create a Serverpod 4 project and wants it on Fly (and optional Pages/Neon)
- User asks to deploy Serverpod / Flutter web API split / mobile API-only

## Prerequisites (once)

- `flutter` on PATH
- **Only the CLI for the chosen API host** (wizard sets `host:` in podfly.yaml):
  - `fly` / `flyctl` when `host: fly` (only fully implemented deploy today)
  - `railway` / `render` / `gcloud` / `aws` / `az` / `doctl` when those hosts are selected (doctor checks; deploy not implemented yet)
- `wrangler` + login only if Flutter web → Cloudflare Pages
- `neonctl` if `database.neon.provision: true`

Install podfly:

```bash
dart pub global activate --source git https://github.com/127thousand/podfly.git
# or path to local clone
export PATH="$PATH:$HOME/.pub-cache/bin"
```

## Default actions

### New project

```bash
serverpod create my_app --mini -f    # or fullstack
cd my_app
podfly deploy --yes --smoke
```

### Existing monorepo

```bash
cd <serverpod_root>   # has *_server, optional *_flutter
podfly deploy --yes --smoke
# unsure? plan first:
podfly deploy --yes --dry-run --no-login
```

### Mobile / API only

```bash
podfly deploy --api --yes --smoke
# or set web.enabled: false in podfly.yaml
```

### CI / non-TTY

```bash
export FLY_API_TOKEN=…
export CLOUDFLARE_API_TOKEN=…   # if Pages
podfly deploy --yes --no-login --smoke
```

## Decision tree

1. No Serverpod project → `serverpod create` first (never fake a random Dockerfile).
2. Plan only → `--dry-run --no-login`.
3. Wizard / config chooses **API cloud** (`host: fly|railway|render|…`) — only install **that** host’s CLI.
4. Flutter has android/ios and no real web product → `--api` or `web.enabled: false`.
5. Flutter web + API on Fly → `mode: split` (Pages + Fly) after init.
6. Stateless → `database.provider: none`.
7. Need Postgres + sleeping API → Neon; on-Fly private PG → `fly_postgres`.
8. Non-Fly hosts: doctor checks CLI; **deploy only implemented for Fly** until roadmap lands.

## Do not

- Invent Python/Node Dockerfiles for Serverpod
- Use `flutter build web --output` outside the package as the sole artifact
- Force Fly CLI when user selected Render/Railway/etc.
- Claim Railway/Render/AWS deploy works in podfly yet (roadmap — deploy is Fly today)
- Force Postgres just because auth packages are scaffolded
- Skip doctor failures without fixing auth/tools

## Verify

```bash
podfly smoke
# or curl API + Pages URL after deploy
```

## Docs in repo

If the podfly repo is available, prefer:

- `AGENTS.md`, `llms.txt`, `README.md`
- `docs/guide.md`, `docs/podfly.yaml.md`, `docs/caching.md`, `docs/database.md`
