# Codemagic — mobile iOS/Android CI

Store builds for Flutter clients in a Serverpod monorepo. **Not** an API host:
podfly still deploys the Serverpod API with `podfly deploy --api`; Codemagic
builds IPA / App Bundle and (optionally) ships to TestFlight / Play.

There is no `codemagic deploy` product CLI like Fly. Control plane:

| Piece | Role |
|-------|------|
| **`codemagic.yaml`** | Workflows in the repo (what podfly generates) |
| **Dashboard** | Connect repo, signing groups, store integrations |
| **REST API** | Optional: start builds with an API token |

`codemagic-cli-tools` (`pip install codemagic-cli-tools`) are **signing/build
helpers** used inside workflows — not a deploy client for the Codemagic cloud.

## Config

```yaml
# podfly.yaml
web:
  enabled: false
  api_url: https://my-api.fly.dev/
  server_url_define: SERVER_URL

mobile:
  provider: codemagic
  codemagic:
    path: codemagic.yaml
    write_yaml: true      # write file if missing (never overwrite)
    ios: true
    android: true
    instance_type: mac_mini_m2
    # bundle_id: com.example.myapp
    # app_store_connect: MyAscIntegration   # Teams → Integrations name
    # publish_testflight: false             # set true when integration ready
    # publish_play: false
    # app_id: <codemagic app uuid>          # docs / REST trigger
```

On `podfly init` / first deploy for **API-only** (mobile) surfaces, podfly sets
`mobile.provider: codemagic` by default and writes `codemagic.yaml` if missing.

## What gets generated

Workflows (when enabled):

| Workflow id | What it does |
|-------------|--------------|
| `ios-ipa` | `flutter build ipa` with `--dart-define=SERVER_URL=<web.api_url>` |
| `android-appbundle` | `flutter build appbundle` with the same define |

`SERVER_URL` (or `web.server_url_define`) is baked from **`web.api_url`** so the
mobile app talks to the same API podfly just deployed.

podfly **never overwrites** an existing `codemagic.yaml` (hand-tuned signing
must not be clobbered). Delete the file and re-deploy to regenerate, or edit
`SERVER_URL` by hand when the API host changes.

## One-time Codemagic setup

1. Push the monorepo (including `codemagic.yaml`) to GitHub/GitLab/Bitbucket.
2. [codemagic.io](https://codemagic.io) → add application → select repo.
3. **iOS:** Teams → Integrations → App Store Connect API key; env group
   `ios_signing` (e.g. `CERTIFICATE_PRIVATE_KEY`).
4. **Android:** env group `android_signing` (keystore + passwords); Play
   service account if publishing.
5. Run **iOS IPA** / **Android App Bundle** from the UI.

Optional publish: set `publish_testflight: true` and
`app_store_connect: <integration name>` (then delete `codemagic.yaml` and
regenerate, or edit publishing blocks by hand).

## Trigger a build (REST)

```bash
export CM_API_TOKEN=…   # Codemagic user API token
curl -H "Content-Type: application/json" \
  -H "x-auth-token: $CM_API_TOKEN" \
  --data '{
    "appId": "<app_id>",
    "workflowId": "ios-ipa",
    "branch": "main"
  }' \
  -X POST https://api.codemagic.io/builds
```

## Workflow with API

```bash
# 1) Backend
podfly deploy --api --yes --smoke

# 2) codemagic.yaml already written (or written on deploy)
# 3) Commit + push → Codemagic builds, or trigger via API
```

| Layer | Tool |
|-------|------|
| Serverpod API | `podfly deploy --api` → Fly / Railway / … |
| Flutter iOS/Android | Codemagic (`codemagic.yaml`) |

## Example

[`example/mobile_api_only`](../example/mobile_api_only) — Fly API-only + GHA for
API deploy + Codemagic scaffolding for the Flutter client.

## Related

- [CI & GitHub Actions](ci.md) (API deploy in GHA)
- [guide.md — mobile / API only](guide.md)
- [Codemagic Flutter docs](https://docs.codemagic.io/flutter-configuration/flutter-projects/)
