# Netlify — static Flutter web (`web_host: netlify`)

Netlify hosts **Flutter web static assets only** — the same role as
[Cloudflare Pages](https://pages.cloudflare.com) and [Vercel](https://vercel.com).
It is **not** a Serverpod API host.

| Capability | On Netlify? |
|------------|-------------|
| Flutter web SPA + CanvasKit / WASM | ✅ |
| Serverpod HTTP RPC | ❌ → use `host:` (e.g. Fly) |
| Serverpod **WebSocket streams** | ❌ → same API host (WSS) |
| Scale-to-zero static CDN | ✅ |

For realtime, use **split**: UI on Netlify, API + WSS on Fly (or another host that
supports upgrades). Bake `SERVER_URL` to the API origin so the client never
opens websockets against `*.netlify.app`.

## Prerequisites

```bash
npm i -g netlify-cli   # or: brew install netlify-cli
netlify login          # or: export NETLIFY_AUTH_TOKEN=…
```

Doctor checks `netlify` + auth (`NETLIFY_AUTH_TOKEN` / `NETLIFY_TOKEN`, or
`netlify status` / API user).

## Config

```yaml
host: fly
web_host: netlify
mode: split

netlify:
  site: my-flutter-ui          # becomes https://my-flutter-ui.netlify.app
  # team: my-team-slug         # optional
  # site_id: …                 # filled after first deploy
  # public_host: my-flutter-ui.netlify.app
```

| Key | Description |
|-----|-------------|
| `site` | Site name (`--site-name` if creating; default URL host) |
| `site_id` | Stable Netlify id — preferred for `--site` after first create |
| `team` | Optional team slug (`--team`) |
| `public_host` | Persisted after deploy for smoke / logs |

## Deploy behavior

1. Build Flutter web (with `SERVER_URL` / `web.api_url` → API host).
2. Write **`netlify.toml`** into the build dir (SPA `/* → /index.html` 200 +
   WASM / cache headers) unless `*_flutter/web/netlify.toml` exists.
3. `netlify deploy --dir <build/web> --prod --no-build --json`
   - With `site_id`: `--site <id>`
   - Else: `--site-name <site>` (creates the site if missing)
4. Persist `netlify.public_host` (+ `site_id` when returned).

## Realtime (streams)

Netlify cannot terminate Serverpod WSS. Pattern:

| Layer | Where |
|-------|--------|
| Flutter UI | Netlify |
| HTTP RPC + WebSockets | `host:` (Fly recommended) |

Client must resolve API URL to Fly, not Netlify same-origin. Examples:

- [netlify/split_fly](https://github.com/127thousand/podfly_examples/tree/main/netlify/split_fly) — RPC only  
- [netlify/realtime_split](https://github.com/127thousand/podfly_examples/tree/main/netlify/realtime_split) — clock stream over WSS to Fly  

In the Flutter app, avoid falling back to `Uri.base` when the page is on
`*.netlify.app` (see the realtime example’s `resolveServerUrl`).

## CI

```bash
export NETLIFY_AUTH_TOKEN=…   # Personal access token (Netlify UI → User settings)
podfly deploy --yes --no-login --smoke
```

## Teardown

```bash
# Fly API app(s)
fly apps destroy <api-app> --yes

# Netlify site (id from sites:list or podfly.yaml netlify.site_id)
netlify sites:list
netlify sites:delete <site-id> --force
```

Or delete the site in the Netlify dashboard. Always tear down demos after smoke so
static sites and Fly machines do not keep billing.

## Related

- [podfly.yaml — `web_host` / `netlify`](podfly.yaml.md#netlify-split--web_host-netlify)
- [User guide — static web CDN](guide.md#static-web-cdn-web_host)
- Peer static hosts: `web_host: cloudflare` · `web_host: vercel`
