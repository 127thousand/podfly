# podfly

Deploy **Serverpod + Flutter web** with less pain.

- **`split`** — Flutter UI on Cloudflare Pages, API on Fly.io  
- **`fly`** — everything on Fly  
- **Database** — `none` · SQLite (+ volume) · Fly Postgres · Neon  

Interactive setup (`podfly init`) via [nocterm](https://pub.dev/packages/nocterm), plus `doctor`, `deploy`, and `smoke`.

> Design: [docs/specs/2026-07-18-podfly-design.md](docs/specs/2026-07-18-podfly-design.md)

## Status

Early — design approved, implementation in progress.

## Install (later)

```bash
dart pub global activate --source git https://github.com/127thousand/podfly.git
# or path
dart pub global activate --source path /path/to/podfly
```

## Intended usage

```bash
cd your_serverpod_monorepo
podfly deploy --smoke   # if no podfly.yaml → wizard first, then deploy
                        # if not logged into fly/wrangler/neon → prompts + runs login
```

Optional: `podfly init` (configure only), `podfly doctor` (check/fix tools + auth).

## License

TBD
