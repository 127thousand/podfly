# Example: Serverpod mini → mobile API only

Generated with:

```bash
serverpod create mobile_api_only --mini -f
```

Then **removed** Flutter `web/` (and desktop platforms) so the client looks
mobile-only (`android` + `ios`).

Server Dockerfile is the one **Serverpod created** (Dart multi-stage build).

## Podfly expectation

```bash
cd examples/mobile_api_only
podfly deploy --yes --dry-run
# → web.enabled: false, only fly deploy (no Pages / no flutter build web)
```

This is a real Serverpod 4 beta tree for deploy testing. Mobile store
shipping (TestFlight / Play) is out of scope for podfly.
