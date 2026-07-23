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
| Render | `RENDER_API_KEY` | [API keys](https://render.com/docs/api) (CLI non-interactive); set active workspace if needed |
| Cloud Run | `GOOGLE_APPLICATION_CREDENTIALS` | Path to SA JSON; or `gcloud auth` on the runner; enable `run.googleapis.com` + Cloud Build |
| DigitalOcean | `DIGITALOCEAN_ACCESS_TOKEN` | [API tokens](https://docs.digitalocean.com/reference/api/create-personal-access-token/); also need Docker + DOCR in CI |
| Cloudflare Pages | `CLOUDFLARE_API_TOKEN` | Pages edit permission; often need account access |
| Vercel static UI | `VERCEL_TOKEN` | When `web_host: vercel` |
| Netlify static UI | `NETLIFY_AUTH_TOKEN` | When `web_host: netlify` |
| GitHub Pages UI | `GH_TOKEN` / `GITHUB_TOKEN` | When `web_host: github_pages` (repo + pages write) |
| Neon provision | `NEON_API_KEY` | Only if `database.neon.provision: true` |
| Supabase | `SUPABASE_ACCESS_TOKEN` | When `database.provider: supabase` |
| Upstash Redis | `UPSTASH_EMAIL` + `UPSTASH_API_KEY` | When `redis.provider: upstash` |

**Recommended in CI repos:** commit `podfly.yaml` and host config (`fly.toml` /
`railway.toml` / DO app spec) so app names and scale settings are reviewable and
stable across runs. They are **not** required for the CLI — first deploy creates
them if missing — but regenerating every run can pick different defaults.

Always commit the Serverpod Dockerfile (from `serverpod create`).

Do **not** commit:

- `*_server/config/passwords.yaml` production secrets (or treat as secret-generated in CI)
- Sidecars: `.podfly_fly_pg.json`, `.podfly_railway_pg.json`, `.podfly_do_pg.json`, `.podfly_supabase_pg.json`

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
dart pub global activate podfly 0.2.1
```

---

## Example: DigitalOcean API (GitHub Actions)

```yaml
      - name: Install doctl
        uses: digitalocean/action-doctl@v2
        with:
          token: ${{ secrets.DIGITALOCEAN_ACCESS_TOKEN }}

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: DOCR login
        run: doctl registry login

      - name: Deploy
        env:
          DIGITALOCEAN_ACCESS_TOKEN: ${{ secrets.DIGITALOCEAN_ACCESS_TOKEN }}
        run: podfly deploy --host digitalocean --api --yes --no-login --smoke
```

CI runners need Docker (remote build/push to DOCR). Prefer pinning `linux/amd64` builds (podfly sets `--platform` by default).

---

## Example: Fly API-only (GitHub Actions)

**Full working tree** (workflow + `podfly.yaml` + Serverpod mini):  
[`example/mobile_api_only`](../example/mobile_api_only) — deploys on every push to `main`.

| File | Role |
|------|------|
| [`.github/workflows/deploy.yml`](../example/mobile_api_only/.github/workflows/deploy.yml) | `podfly deploy --api` → Fly |
| [`.github/workflows/plan.yml`](../example/mobile_api_only/.github/workflows/plan.yml) | PR dry-run |
| [`podfly.yaml`](../example/mobile_api_only/podfly.yaml) | `host: fly`, `web.enabled: false`, smoke |

### Minimal workflow (copy into monorepo root)

```yaml
name: Deploy API (Fly)
on:
  push:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: deploy-fly-api-${{ github.ref }}
  cancel-in-progress: true

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
          dart pub global activate podfly 0.2.1
          echo "$HOME/.pub-cache/bin" >> "$GITHUB_PATH"

      - name: Deploy
        env:
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}
          PODFLY_AUTO: '1'
        run: podfly deploy --api --yes --no-login --smoke
```

**Secret:** `FLY_API_TOKEN` from `fly tokens create deploy -x 999999h`.

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
