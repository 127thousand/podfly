# GitHub Actions + Fastlane — mobile iOS/Android

**GHA** = when/where the job runs. **Fastlane** = how you build and (optionally)
ship to TestFlight / Play. podfly generates both; it does not hold signing keys
or trigger builds.

API still: `podfly deploy --api`. This is **not** `deploy.yml` — see [ci.md](ci.md).

## Config

```yaml
mobile:
  provider: github_actions   # alias: gha
  github_actions:
    workflows_dir: .github/workflows
    write_yaml: true
    ios: true
    android: true
    fastlane: true           # default — Fastfile + Gemfile + fastlane lanes
    # fastlane: false        # compile-only (plain flutter build, no Fastlane)
    # bundle_id: com.example.app
    # android_package_name: com.example.app
    flutter_channel: stable

web:
  enabled: false
  api_url: https://my-api.fly.dev/
  server_url_define: SERVER_URL
```

## What gets generated (`fastlane: true`)

| Path | Role |
|------|------|
| `.github/workflows/mobile-android.yml` | ubuntu → Ruby + Flutter → `fastlane android …` |
| `.github/workflows/mobile-ios.yml` | macos → Ruby + Flutter → `fastlane ios …` |
| `*_flutter/Gemfile` | `gem "fastlane"` |
| `*_flutter/fastlane/Fastfile` | lanes: `ios build` / `ios beta`, `android build` / `android internal` |
| `*_flutter/fastlane/Appfile` | bundle id / package stubs |
| `*_flutter/fastlane/Matchfile` | match stub (optional signing repo) |

**Create** missing files only (never full-overwrite hand-tuned workflows/Fastlane).

Each **`podfly deploy`** (after the API URL is known) **re-syncs** URL lines in
existing workflows from `web.api_url` / the live host:

```yaml
          SERVER_URL: https://my-api.fly.dev  # podfly:api_url
```

Also updates `--dart-define=SERVER_URL=…` in compile-only scripts. Fastfile reads
`ENV` (no hard-coded host). Structure, secrets, and custom steps stay intact.

`SERVER_URL` (or `web.server_url_define`) is set in the workflow env from
`web.api_url` and passed into Flutter via `--dart-define`.

### Lanes

| Lane | Platform | Behavior |
|------|----------|----------|
| `ios build` | iOS | `flutter build ios --no-codesign` |
| `ios beta` | iOS | `flutter build ipa`; `upload_to_testflight` **commented** until secrets |
| `android build` | Android | `flutter build appbundle` |
| `android internal` | Android | appbundle; `upload_to_play_store` **commented** until Play JSON |

**Push to main** runs `build` (compile-friendly).  
**workflow_dispatch** lets you pick `beta` / `internal` for release attempts.

## Secrets (release)

Add under GitHub → Settings → Secrets and variables → Actions:

| Secret | Used for |
|--------|----------|
| `MATCH_PASSWORD` / `MATCH_GIT_URL` / `MATCH_GIT_BASIC_AUTHORIZATION` | fastlane match |
| `APP_IDENTIFIER` / `APPLE_ID` / `TEAM_ID` / `ITC_TEAM_ID` | Appfile / match |
| `APP_STORE_CONNECT_API_KEY_*` | ASC API (preferred over password) |
| `PLAY_JSON_KEY` | Play service account JSON body (written to a temp file in CI) |
| `PACKAGE_NAME` | Android package |

Then uncomment `match`, `upload_to_testflight`, and `upload_to_play_store` in
the Fastfile (podfly will not re-touch it once created).

## Compile-only mode

```yaml
mobile:
  provider: github_actions
  github_actions:
    fastlane: false
```

Workflows call `flutter build` only — no Gemfile/Fastlane. Useful as a cheap PR
gate; not a store path.

## vs Codemagic

| | GHA + Fastlane | Codemagic |
|--|----------------|-----------|
| Config | workflows + `fastlane/` | `codemagic.yaml` |
| Signing | match + GitHub secrets | Codemagic integrations |
| Same repo as API deploy | Yes | Separate product |

Pick one `mobile.provider`.

## Flow

```bash
# podfly.yaml: mobile.provider: github_actions  (fastlane defaults true)
podfly deploy --api --yes --smoke
git add .github/workflows/mobile-*.yml \
  your_flutter/Gemfile your_flutter/fastlane/
git commit -m "ci: mobile GHA + Fastlane"
git push
# Actions → Mobile iOS → Run workflow → lane "build" or "beta"
```

## Related

- [ci.md](ci.md) — API deploy  
- [codemagic.md](codemagic.md)  
- [Fastlane docs](https://docs.fastlane.tools/)  
