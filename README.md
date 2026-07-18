# podfly

Deploy **Serverpod + Flutter web** with less pain.

| Mode | What happens |
|------|----------------|
| **`split`** | Flutter UI → Cloudflare Pages · API → Fly.io |
| **`fly`** | Everything on Fly |

| Database | Notes |
|----------|--------|
| **none** | Stateless (scale-to-zero friendly) |
| **sqlite** | Single machine + Fly volume |
| **fly_postgres** | Managed PG (bills even if API sleeps) |
| **neon** | Serverless PG (good with scale-to-zero) |

## Install

```bash
dart pub global activate --source path /path/to/podfly
# later: dart pub global activate --source git https://github.com/127thousand/podfly.git
```

Ensure `~/.pub-cache/bin` is on your `PATH`.

## Usage

```bash
cd your_serverpod_monorepo
podfly deploy --smoke
```

Flow:

1. **Doctor (baseline)** — `flutter`, `fly` present + authenticated (offers `fly auth login`)
2. **Init** if no `podfly.yaml` (interactive wizard, or `--yes` defaults)
3. **Doctor (config-aware)** — `wrangler` / `neonctl` as needed
4. DB ensure + production.yaml patch → web build → deploy
5. Optional **`--smoke`** HTTP checks

```bash
podfly deploy --dry-run    # plan only
podfly deploy --web        # Pages only
podfly deploy --api        # Fly only
podfly doctor
podfly init
podfly smoke
```

## Design

See [docs/specs/2026-07-18-podfly-design.md](docs/specs/2026-07-18-podfly-design.md).

## License

MIT
