# Example: Serverpod + mobile Flutter (no web)

This fixture has:

- `mobile_api_server` — API only (no FlutterRoute web serving)
- `mobile_api_flutter` — `android/` + `ios/`, **no `web/`**
- `mobile_api_client` — generated client package stub

```bash
cd examples/mobile_api_only
podfly deploy --yes --dry-run
# Expect: no flutter build web, no wrangler, only fly deploy
```
