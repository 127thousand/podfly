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

## Quick start

```bash
cd your_serverpod_monorepo   # workspace with *_server + *_flutter
podfly deploy --smoke
```

That single command:

1. **Doctor (baseline)** — Flutter + Fly installed and authenticated  
2. **Init** if there is no `podfly.yaml` (wizard, or `--yes` for defaults)  
3. **Doctor (config-aware)** — Wrangler / Neon as needed  
4. Database ensure + optional `production.yaml` patch  
5. Flutter web build with **cache-friendly** packaging (see [docs/caching.md](docs/caching.md))  
6. Deploy UI + API  
7. Optional HTTP **smoke** checks  

```bash
podfly deploy --dry-run     # plan only, no side effects
podfly deploy --web         # static UI only (split)
podfly deploy --api         # Fly API only
podfly doctor
podfly init
podfly smoke
```

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
