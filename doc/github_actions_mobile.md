# GitHub Actions — mobile iOS/Android CI

Same role as [Codemagic](codemagic.md): **generate pipeline files** for Flutter
store clients in a Serverpod monorepo. podfly still deploys the **API**
(`podfly deploy --api`); GHA builds AAB / iOS on GitHub-hosted runners.

This is **not** the API deploy workflow (`deploy.yml` + `FLY_API_TOKEN`). That
stays separate — see [ci.md](ci.md).

## Config

```yaml
mobile:
  provider: github_actions   # alias: gha
  github_actions:
    workflows_dir: .github/workflows
    write_yaml: true         # write if missing; never overwrite
    ios: true
    android: true
    android_workflow: mobile-android.yml
    ios_workflow: mobile-ios.yml
    flutter_channel: stable

web:
  enabled: false
  api_url: https://my-api.fly.dev/
  server_url_define: SERVER_URL
```

On `podfly deploy`, missing workflow files are created. Existing files are left
alone (hand-tuned signing must not be clobbered).

## What gets generated

| File | Runner | Default build |
|------|--------|----------------|
| `mobile-android.yml` | `ubuntu-latest` | `flutter build appbundle` + artifact |
| `mobile-ios.yml` | `macos-latest` | `flutter build ios --no-codesign` + optional artifact |

Both bake `--dart-define=SERVER_URL=<web.api_url>` (or `web.server_url_define`).

Triggers: `workflow_dispatch` and `push` to `main` filtered to the Flutter
package path (so API-only commits do not burn macOS minutes).

## Secrets / signing

| Platform | Default | Store release |
|----------|---------|----------------|
| Android | Unsigned/release keystore as Flutter default | Keystore + Play secrets; extend workflow |
| iOS | `--no-codesign` (compile check) | Certs/profiles + `flutter build ipa`; extend workflow |

podfly does not manage keystores or App Store Connect keys.

## vs Codemagic

| | GitHub Actions | Codemagic |
|--|----------------|-----------|
| Config file | `.github/workflows/mobile-*.yml` | `codemagic.yaml` |
| Mac builders | GitHub `macos-*` (minutes) | Codemagic mac instances |
| Store publish UX | DIY / third-party actions | Built-in integrations |
| API deploy in same org | Natural (`deploy.yml` already) | Separate product |

Pick **one** `mobile.provider`. API deploy can still use GHA either way.

## Workflow with API

```bash
podfly deploy --api --yes --smoke   # API + write mobile-*.yml if missing
git add .github/workflows/mobile-*.yml podfly.yaml
git commit -m "ci: mobile GHA"
git push
# Actions → Mobile Android / Mobile iOS → Run workflow
```

## Example

[`example/mobile_api_only`](../example/mobile_api_only) documents both providers.
API deploy workflows live there already; switch `mobile.provider` to
`github_actions` and re-deploy (or delete workflows and regenerate) for mobile
build YAML.

## Related

- [ci.md](ci.md) — API deploy tokens and `podfly deploy` in GHA  
- [codemagic.md](codemagic.md) — Codemagic alternative  
- [guide.md — mobile](guide.md)  
