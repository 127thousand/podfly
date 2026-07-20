# Flutter web caching & packaging

This document captures the production lessons behind podfly’s web build
defaults. They exist so multi‑megabyte CanvasKit/WASM and card/assets load
**once** and then come from disk/CDN cache on reload.

## Problems we hit (and fixed)

### 1. Broken asset output path

```bash
# Fragile — Flutter may omit AssetManifest + asset files when --output
# points outside the package:
flutter build web --output ../build/web
```

**podfly rule:** always:

```text
cd <flutter_package>
flutter build web …
# then rsync package build/web → <root>/build/web
```

Never rely on external `--output` alone as the deploy artifact.

### 2. Flutter’s stub service worker

Recent Flutter web builds register `flutter_service_worker.js` that:

1. Installs  
2. Unregisters itself  
3. **Force-navigates** open tabs  

That feels like “WASM never caches” even when `Cache-Control` is correct.

**podfly fix:** custom `web/flutter_bootstrap.js` that:

- Expands `{{flutter_js}}` / `{{flutter_build_config}}`
- Unregisters any leftover service workers
- Does **not** pass `serviceWorkerSettings` to `_flutter.loader.load`

### 3. CanvasKit from gstatic every time

Default/`--web-resources-cdn` loads engine WASM from Google’s CDN. That can be
fine for caching, but:

- Harder to control headers with your host  
- Mixed with the SW reload bug, reloads looked “cold”  

**podfly fix:** same-origin CanvasKit:

```js
_flutter.loader.load({
  config: {
    canvasKitBaseUrl: 'canvaskit/',
  },
});
```

### 4. Blank Flutter canvas on nginx (Railway / DigitalOcean)

If the page “loads” assets but the canvas stays blank, check:

```bash
curl -sI https://your-web-host/canvaskit/canvaskit.wasm | grep -i content-type
```

Must be exactly **`application/wasm`**. A duplicated header such as
`application/wasm,application/wasm` (from nginx `add_header Content-Type`
stacked on `mime.types`) makes browsers reject the module.

**podfly nginx template** uses:

```nginx
location ~* \.wasm$ {
    types { }
    default_type application/wasm;
    add_header Cache-Control "public, max-age=31536000, immutable";
    try_files $uri =404;
}
```

The build already ships `build/web/canvaskit/*.wasm`. Pages serves them with
long cache headers (below). **Do not** pass `--web-resources-cdn` in the
podfly build (we intentionally omit it).

### 4. Cache-Control strategy (Cloudflare Pages)

Template: `templates/_headers` → copied into the Flutter package `web/` and
into the deploy directory.

| Path | Policy | Why |
|------|--------|-----|
| `/canvaskit/*` | `public, max-age=31536000, immutable` | Engine WASM/JS, content-addressed by Flutter version |
| `/assets/*` | same | Card images, fonts, manifests under assets |
| `/icons/*` | same | Static icons |
| `/main.dart.js` | `max-age=86400, stale-while-revalidate=604800` | App bundle (no content hash in filename) |
| `/flutter.js` | same | Loader |
| `/flutter_bootstrap.js` | `no-cache` | Entry must pick up deploy changes |
| `/`, `/index.html` | `no-cache` | HTML shell |
| `/flutter_service_worker.js` | `no-cache` | Avoid sticky broken SW |
| `/version.json`, `/manifest.json` | `no-cache` | Metadata |

**Note:** `_headers` is a **Cloudflare Pages** feature (`mode: split`).  
All-on-Fly static hosting does not use this file unless you add equivalent
headers in your server/proxy.

## What `podfly deploy` does for web

Controlled by `podfly.yaml`:

```yaml
web:
  patch_bootstrap: true   # default true
  write_headers: true     # default true
  server_url_define: SERVER_URL
  api_url: https://my-app.fly.dev/
  base_href: /
```

### When `patch_bootstrap: true`

1. If `flutter/web/flutter_bootstrap.js` is **missing**, write the podfly template.  
2. If it already looks podfly-style (`canvasKitBaseUrl` and no `serviceWorkerSettings`), leave it.  
3. If a **custom** bootstrap exists that still looks like stock Flutter, **leave it** and warn — we do not overwrite custom files by default.

To re-apply the recipe: delete `web/flutter_bootstrap.js` (or replace with the
template from this repo) and redeploy.

### When `write_headers: true`

If `web/_headers` or `web/_redirects` are missing, write the podfly templates.
Existing files are left untouched.

### Build

```text
flutter build web --release \
  --base-href <web.base_href> \
  --dart-define=<server_url_define>=<api_url>
```

Then rsync/copy to `<root>/build/web` and copy `_headers` / `_redirects` into
that output for `wrangler pages deploy`.

## Verifying cache behavior in the browser

1. Open the Pages URL once (cold load may download ~5–7 MB CanvasKit).  
2. DevTools → **Application** → Service Workers → unregister any for this origin.  
3. Ensure **Disable cache** is **unchecked**.  
4. Reload. Network panel should show `canvaskit.wasm` / assets as  
   **(disk cache)** or **(memory cache)**, not multi‑MB network transfers.

**Note:** Browsers still *compile* WASM after a process kill; that is CPU work,
not a cache miss. Look at transfer size / “from disk cache”, not only duration.

## API URL injection

Flutter clients need a production API base:

```dart
// Typical pattern
const fromEnv = String.fromEnvironment('SERVER_URL');
```

podfly passes:

```bash
--dart-define=SERVER_URL=https://my-app.fly.dev/
```

(`server_url_define` renames the define if your app uses another key.)

Serverpod’s client normalizes a trailing slash on the host and joins
`endpoint/method` without a double slash. podfly normalizes `api_url` to end
with `/`.

## Checklist for a fast first paint (beyond podfly)

podfly handles deploy packaging. Product-level speedups still help:

- [ ] Reasonable image sizes (WebP/AVIF where possible)  
- [ ] Don’t load all 78 card images up front  
- [ ] Prefer deferred fonts where acceptable  
- [ ] Optional: real Workbox PWA later (not Flutter’s deprecated SW)  

## Template sources in this repo

| File | Role |
|------|------|
| `templates/flutter_bootstrap.js` | No stub SW + local CanvasKit |
| `templates/_headers` | Pages Cache-Control rules |
| `templates/_redirects` | Optional SPA notes |
| `lib/src/web/build.dart` | Build orchestration |
