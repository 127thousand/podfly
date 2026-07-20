# CI & GitHub Actions

podfly is designed for non-interactive runs. In CI you install the host CLI(s),
inject tokens as environment variables, and run:

```bash
podfly deploy --yes --no-login --smoke
```

| Flag | Why |
|------|-----|
| `--yes` | Non-interactive init defaults if `podfly.yaml` is missing |
| `--no-login` | Never open a browser; fail if tokens are missing |
| `--smoke` | Optional HTTP checks from `smoke:` in `podfly.yaml` |
| `--api` / `--web` | Deploy only one half |
| `--dry-run` | Plan only (good for pull requests) |

Set `PODFLY_AUTO=1` if doctor might offer CLI installs and you want auto-accept
(prefer preinstalling CLIs in the workflow instead).

---

## Secrets by host

| Target | Secret / env | Notes |
|--------|----------------|-------|
| Fly API | `FLY_API_TOKEN` | [Fly tokens](https://fly.io/docs/security/tokens/) |
| Railway | `RAILWAY_TOKEN` | Account or workspace token |
| Cloudflare Pages | `CLOUDFLARE_API_TOKEN` | Pages edit permission; often need account access |
| Neon provision | `NEON_API_KEY` | Only if `database.neon.provision: true` |

Commit **`podfly.yaml`**, `fly.toml` / `railway.toml`, and the Serverpod Dockerfile.
Do **not** commit:

- `*_server/config/passwords.yaml` production secrets (or treat as secret-generated in CI)
- `*_server/config/.podfly_fly_pg.json` / `.podfly_railway_pg.json` sidecars

### Fly Postgres in CI

`fly postgres attach` sets `DATABASE_URL` on the app. Serverpod still reads
host/user/password from `production.yaml` + `passwords.yaml`. On deploy, podfly:

1. Ensures the API app exists  
2. Attaches (or reuses attachment)  
3. Writes the sidecar from attach output and patches Serverpod config **on the runner**  

So the password does not need to live in git if attach runs successfully in CI.
If attach is already done and the sidecar is missing, re-run a local attach once
or restore the sidecar from a secure store.

---

## Install podfly in CI

```bash
dart pub global activate podfly
echo "$HOME/.pub-cache/bin" >> "$GITHUB_PATH"   # GitHub Actions
```

Pin a version when you want reproducibility:

```bash
dart pub global activate podfly 0.1.0
```

---

## Example: Fly API-only (GitHub Actions)

```yaml
name: Deploy API
on:
  push:
    branches: [main]
    paths:
      - '**/*_server/**'
      - 'podfly.yaml'
      - 'fly.toml'

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: dart-lang/setup-dart@v1
        with:
          sdk: 3.10.3   # match your Serverpod / Dockerfile Dart

      - name: Install flyctl
        uses: superfly/flyctl-actions/setup-flyctl@master

      - name: Install podfly
        run: |
          dart pub global activate podfly
          echo "$HOME/.pub-cache/bin" >> "$GITHUB_PATH"

      - name: Deploy
        env:
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}
        run: podfly deploy --api --yes --no-login --smoke
```

---

## Example: Railway

```yaml
      - name: Install Railway CLI
        run: |
          curl -fsSL https://railway.com/install.sh | sh
          echo "$HOME/.railway/bin" >> "$GITHUB_PATH"

      - name: Deploy
        env:
          RAILWAY_TOKEN: ${{ secrets.RAILWAY_TOKEN }}
        run: podfly deploy --host railway --yes --no-login --smoke
```

Prefer `railway.project_id` (or a stable `railway.project` name) in `podfly.yaml`
so CI never needs interactive `railway link`.

---

## Example: PR dry-run (no side effects)

```yaml
on: pull_request
jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
      - run: |
          dart pub global activate podfly
          echo "$HOME/.pub-cache/bin" >> "$GITHUB_PATH"
      - run: podfly deploy --yes --no-login --dry-run
```

---

## Split web + API

| Job | Command | Tokens |
|-----|---------|--------|
| API | `podfly deploy --api --yes --no-login --smoke` | `FLY_API_TOKEN` or `RAILWAY_TOKEN` |
| Web (Pages) | `podfly deploy --web --yes --no-login` | `CLOUDFLARE_API_TOKEN` (+ Flutter) |

Web jobs need Flutter (`subosito/flutter-action`) as well as Dart.

---

## GitHub Environments

Use [Environments](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment)
for production:

```yaml
jobs:
  deploy:
    environment: production
    # secrets scoped to that environment
```

Optional: required reviewers before the deploy job runs.

---

## Troubleshooting CI

| Symptom | Check |
|---------|--------|
| Doctor wants browser login | Token env not set; use `--no-login` |
| `fly: command not found` | Install flyctl in the job; PATH |
| Railway project missing | Set `railway.project` / `project_id` in `podfly.yaml` |
| Smoke timeout | Cold start; API URL wrong in `web.api_url` / smoke config |
| DB auth failed after deploy | Sidecar/password not patched; re-run deploy after attach |

## Related

- [User guide](guide.md)  
- [Database](database.md)  
- [podfly.yaml reference](podfly.yaml.md)  
