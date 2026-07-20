# Example: API-only Serverpod + Fly + GitHub Actions

Stateless Serverpod **API** on **Fly.io** (scale-to-zero), deployed by **podfly**
on every push to `main`. No Flutter web / Pages.

## The product story (read this first)

podfly’s happy path is **not** “write Fly config, then deploy.” It is:

```bash
serverpod create my_app --mini -f
cd my_app
podfly deploy --yes --smoke   # writes podfly.yaml + fly.toml if missing, then deploys
```

You do **not** need a hand-written `fly.toml` before the first deploy. podfly generates a starter when the file is missing, creates the Fly app, runs `fly deploy`, and optionally smokes the API.

**Why this example still contains `fly.toml` + `podfly.yaml`:** so the **public demo** has a fixed Fly app name, scale-to-zero settings, and CI that is reviewable and deterministic. That is packaging for GitHub Actions — not a requirement of the CLI. If you deleted both files here and ran `podfly deploy --api --yes`, podfly would recreate starters (with a new or default app name).

| Piece | Choice | Why |
|-------|--------|-----|
| Host | **Fly.io** | Cheap at low traffic (`min_machines_running = 0`) |
| Tooling | **podfly** | Creates app + host config if missing, deploy, smoke |
| CI | **GitHub Actions** | `FLY_API_TOKEN` → same `podfly deploy --api` as local |

Generated originally with:

```bash
serverpod create mobile_api_only --mini -f
```

Then Flutter `web/` / desktop were removed so the surface is mobile/API-only.

---

## Live demo repo

A public copy of this example is wired for CI:

- **GitHub:** https://github.com/127thousand/podfly-api-only-demo  
- **Fly app:** `podfly-api-only-demo` → https://podfly-api-only-demo.fly.dev/  
- **Secret:** `FLY_API_TOKEN` (Fly org deploy token, set via `gh secret set`)

Every push to `main` runs `.github/workflows/deploy.yml`.

## Layout

```text
example/mobile_api_only/          ← monorepo root for this example
  podfly.yaml                     ← product config (also auto-created by deploy)
  fly.toml                        ← Fly platform config (also auto-created if missing)
  .github/workflows/
    deploy.yml                    ← push to main → Fly
    plan.yml                      ← PR → dry-run only
  mobile_api_only_server/         ← Serverpod + Dockerfile
  mobile_api_only_client/
  mobile_api_only_flutter/        ← android/ios only (not deployed by podfly)
```

---

## One-time setup (fork / your own app name)

### 1. Unique Fly app name (only if reusing this tree)

Fly app names are **global**. Prefer setting the name in **`podfly.yaml`** only:

```yaml
fly:
  app: myorg-mobile-api   # change me
web:
  api_url: https://myorg-mobile-api.fly.dev/
```

On deploy, if `fly.toml` already exists, podfly patches its `app = "…"` to match. If you omit `fly.toml` entirely, podfly writes a full starter with that name.

### 2. Fly deploy token

```bash
fly auth login
fly tokens create deploy -x 999999h
# → copy the token (starts with FlyV1 …)
```

### 3. GitHub secret

Repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**

| Name | Value |
|------|--------|
| `FLY_API_TOKEN` | Token from step 2 |

Or CLI:

```bash
gh secret set FLY_API_TOKEN -R YOU/YOUR_REPO --body "$TOKEN"
```

### 4. Use this example as a repo (or copy into yours)

**Option A — this folder is the git root** (simplest for demos):

```bash
cd example/mobile_api_only
git init
git add .
git commit -m "API-only Serverpod + podfly CI"
# create empty GitHub repo, then:
git remote add origin git@github.com:YOU/YOUR_REPO.git
git branch -M main
git push -u origin main
```

**Option B — greenfield Serverpod (no example files required):**

```bash
serverpod create my_app --mini -f
cd my_app
# optional: copy only .github/workflows from this example
podfly deploy --api --yes --smoke
# commit the generated podfly.yaml (+ fly.toml if you want them in git)
```

**Option C — copy workflows into an existing monorepo:**

```bash
cp -R example/mobile_api_only/.github your_serverpod_root/
# podfly.yaml / fly.toml optional; deploy creates them if missing
```

---

## What the workflow does

On every **push to `main`** (and manual **workflow_dispatch**):

1. Checkout  
2. Install Dart **3.10.3** (matches the Dockerfile)  
3. Install **flyctl**  
4. `dart pub global activate podfly 0.2.1`  
5. `podfly deploy --api --yes --no-login --smoke`  

podfly will:

- create the Fly app if missing  
- write or reuse `fly.toml` / Dockerfile  
- `fly deploy --ha=false` (scale-to-zero)  
- smoke: `POST /greeting/hello` with `{"name":"podfly"}`  

PRs run **`plan.yml`**: dry-run only (no Fly token required for planning).

---

## Local deploy

```bash
cd example/mobile_api_only
dart pub global activate podfly   # or pin 0.2.1
export PATH="$PATH:$HOME/.pub-cache/bin"

podfly deploy --api --yes --dry-run --no-login   # plan
podfly deploy --api --yes --smoke                # real deploy (fly auth login first)
```

---

## Verify

```bash
curl -sS -X POST "https://YOUR-APP.fly.dev/greeting/hello" \
  -H "Content-Type: application/json" \
  -d '{"name":"world"}'
# → Greeting JSON
```

---

## Cost notes (Fly)

- `auto_stop_machines = "stop"` + `min_machines_running = 0` → idle ≈ \$0 compute  
- First request may cold-start (~few seconds)  
- No Postgres in this example (`database.provider: none`)  

For a DB later: set `database.provider: neon` or `fly_postgres` and update secrets/docs accordingly.

---

## Out of scope

- TestFlight / Play Store packaging  
- Flutter web / Cloudflare Pages  
- Multi-environment (staging) apps — use a second `fly.app` + workflow `environment:`  

See also: [doc/ci.md](../../doc/ci.md), [doc/guide.md](../../doc/guide.md).
