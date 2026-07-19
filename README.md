# podfly

Deploy **Serverpod + Flutter web** without relearning the hard parts every time.

| Mode | UI | API |
|------|----|-----|
| **`split`** | [Cloudflare Pages](https://pages.cloudflare.com/) | [Fly.io](https://fly.io/) |
| **`fly`** | Served from the Fly app | Same Fly app |

| Database | When to use |
|----------|-------------|
| **`none`** | Stateless APIs (scale-to-zero friendly) |
| **`sqlite`** | Single machine + Fly volume |
| **`fly_postgres`** | Classic Serverpod Postgres on Fly (bills even if API sleeps) |
| **`neon`** | Serverless Postgres (pairs well with scale-to-zero) |

**Repo:** [github.com/127thousand/podfly](https://github.com/127thousand/podfly)

---

## Install

```bash
# From git
dart pub global activate --source git https://github.com/127thousand/podfly.git

# Or from a local clone
dart pub global activate --source path /path/to/podfly
```

Ensure `~/.pub-cache/bin` is on your `PATH` (e.g. `export PATH="$PATH:$HOME/.pub-cache/bin"`).

**You also need:**

| Tool | When |
|------|------|
| [Flutter](https://flutter.dev) | Always |
| [flyctl](https://fly.io/docs/hands-on/install-flyctl/) | Always |
| [wrangler](https://developers.cloudflare.com/workers/wrangler/install-and-update/) | `mode: split` |
| [neonctl](https://neon.tech/docs/reference/neon-cli) | Only if `database.neon.provision: true` |

`podfly doctor` checks these and can open login flows on a TTY.

---

## Quick start (zero-touch as possible)

```bash
# Once per machine: install tools + log in
# flutter, flyctl, wrangler (if web), neonctl (if Neon provision)

serverpod create my_app --mini -f   # Serverpod creates Dockerfile + monorepo
cd my_app
podfly deploy --yes --smoke         # non-interactive defaults
```

That `podfly deploy` will:

1. **Doctor** — tools on PATH; offers / auto-runs login when needed  
2. **Init** if no `podfly.yaml` (`--yes` skips prompts)  
3. Detect **web vs API-only** (mobile without `web/` → API only)  
4. Write **`fly.toml`** if missing; write Serverpod-style **Dockerfile** only if missing  
5. **`fly apps create`** if the app does not exist (sanitizes `my_app` → `my-app`)  
6. Create **Cloudflare Pages project** if deploying web  
7. Patch production `publicHost` toward `*.fly.dev` when still localhost  
8. Build/deploy + optional **smoke**  

```bash
podfly deploy --dry-run     # plan only
podfly deploy --api         # force API only
podfly deploy --web         # force web half
podfly doctor
podfly init
podfly smoke
```

**You still need:** CLIs installed and authenticated once. **You do not need:** hand-written `fly.toml`, manual `fly apps create`, or a custom Dockerfile when Serverpod already provided one.

---

## Documentation

| Doc | Contents |
|-----|----------|
| [**User guide**](docs/guide.md) | Full flow, flags, CI, prerequisites |
| [**Caching & Flutter web**](docs/caching.md) | WASM/CanvasKit, service worker, `_headers`, build rules |
| [**Database**](docs/database.md) | Providers, detection, template auth warnings |
| [**Config reference**](docs/podfly.yaml.md) | Every `podfly.yaml` field |
| [**Design spec**](docs/specs/2026-07-18-podfly-design.md) | Original architecture decisions |

---

## What podfly automates (lessons baked in)

From real Serverpod + Flutter web deploys (including production caching fixes):

- Build web **inside** the Flutter package (external `--output` can drop assets)
- Inject API base URL via `--dart-define=SERVER_URL=…`
- Patch **Flutter bootstrap**: no stub service worker, same-origin CanvasKit
- Emit Cloudflare Pages **`_headers`** for long-lived WASM/assets
- Discover `*_server` / `*_flutter` packages
- Detect DB need vs unused **Serverpod create** auth scaffolding
- Facilitate `fly auth login` / `wrangler login` / `neonctl auth` when interactive

---

## Example `podfly.yaml` (split, no database)

```yaml
mode: split
name: sacred-draw
server: tarot_draw_server
flutter: tarot_draw_flutter

fly:
  app: sacred-draw
  region: iad
  config: fly.toml
  scale_to_zero: true
  ha: false

cloudflare:
  project: sacred-draw
  branch: main

database:
  provider: none

web:
  server_url_define: SERVER_URL
  api_url: https://sacred-draw.fly.dev/
  patch_bootstrap: true
  write_headers: true

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

---

## License

MIT
