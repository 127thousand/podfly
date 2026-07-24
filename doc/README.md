# podfly documentation

| Document | Description |
|----------|-------------|
| [User guide](guide.md) | Commands, deploy flow, flags, automation, troubleshooting |
| [CI & GitHub Actions](ci.md) | Tokens, example workflows, PR dry-run |
| [Caching & Flutter web](caching.md) | WASM, service worker, `_headers`, build rules |
| [Database](database.md) | Providers, detection, Fly/Railway/DO/Supabase Postgres |
| [Supabase](supabase.md) | `database.provider: supabase` — managed Postgres via CLI |
| [podfly.yaml reference](podfly.yaml.md) | Config field list and examples |
| [AWS App Runner](aws.md) | `host: aws` — deploy knobs; **no WebSockets** (Envoy 403) |
| [Azure Container Apps](azure.md) | `host: azure` — Docker → ACR → env/app; WebSockets OK |
| [Hetzner Cloud](hetzner.md) | `host: hetzner` — VPS bind/create + Docker over SSH |
| [Static web CDNs](guide.md#static-web-cdn-web_host) | `web_host: cloudflare \| vercel \| netlify \| github_pages` |
| [Netlify](netlify.md) | `web_host: netlify` — static Flutter CDN; **not** API/WS |
| [GitHub Pages](github_pages.md) | `web_host: github_pages` — static Flutter CDN via `gh` + `git` |
| [Upstash Redis](upstash.md) | `redis.provider: upstash` — optional cache/PubSub |
| [Codemagic](codemagic.md) | `mobile.provider: codemagic` — iOS/Android CI (`codemagic.yaml`) |
| [Design specs](specs/) | Architecture decisions (incl. [ECS+ALB realtime sketch](specs/2026-07-21-aws-ecs-realtime-sketch.md)) |

Start at the [root README](../README.md) for install and quick start.

**Package:** [pub.dev/packages/podfly](https://pub.dev/packages/podfly) · **Changelog:** [../CHANGELOG.md](../CHANGELOG.md)
