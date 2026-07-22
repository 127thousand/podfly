# GitHub Pages — static Flutter web (`web_host: github_pages`)

GitHub Pages hosts **Flutter web static assets only** — same role as Cloudflare
Pages, Vercel, and Netlify. It is **not** a Serverpod API host.

| Capability | On GitHub Pages? |
|------------|------------------|
| Flutter web SPA + CanvasKit / WASM | ✅ |
| Serverpod HTTP RPC | ❌ → use `host:` (e.g. Fly) |
| Serverpod **WebSocket streams** | ❌ → same API host (WSS) |
| Project site URL | ✅ `https://<owner>.github.io/<repo>/` |

## Prerequisites

```bash
brew install gh          # https://cli.github.com/
gh auth login            # needs repo scope (push + Pages settings)
# git is also required
```

Doctor checks `gh` + `git` + `gh auth status`.

## Config

```yaml
host: fly
web_host: github_pages
mode: split

github_pages:
  repo: my-flutter-ui          # created if missing
  # owner: my-user             # default: gh api user
  branch: gh-pages             # default
  # private: false

web:
  # Project pages need a non-root base href (podfly auto-sets /<repo>/ if left as /)
  base_href: /my-flutter-ui/
  api_url: https://my-api.fly.dev/
```

| Key | Description |
|-----|-------------|
| `repo` | Repository name (created public by default) |
| `owner` | User/org; resolved from `gh` if omitted |
| `branch` | Source branch for Pages (default `gh-pages`) |
| `private` | Create private repo (`true` — Pages may need a paid plan) |
| `public_host` | Persisted after deploy, e.g. `user.github.io/my-flutter-ui` |

## Deploy behavior

1. Build Flutter web with `--base-href` suited to project Pages (`/<repo>/` when
   `base_href` is still `/`).
2. Stage build: add **`.nojekyll`** and **`404.html`** (copy of `index.html` for SPA).
3. Force-push the tree to `<branch>` via temp git repo + `gh auth token`.
4. Enable Pages (`build_type: legacy`, source branch `/`) via GitHub API if needed.
5. Persist `github_pages.owner` + `public_host`.

## Realtime

Same split pattern as Netlify/Vercel: UI on GitHub Pages, API + WSS on Fly.
Point `SERVER_URL` at the API origin; do not use same-origin when the page is on
`*.github.io`.

Examples:

- [github_pages/split_fly](https://github.com/127thousand/podfly_examples/tree/main/github_pages/split_fly) — RPC only  
- [github_pages/realtime_split](https://github.com/127thousand/podfly_examples/tree/main/github_pages/realtime_split) — clock stream over WSS to Fly

## CI

```bash
# GITHUB_TOKEN with contents:write + pages:write (or classic repo scope)
export GH_TOKEN=…   # gh also respects this
podfly deploy --yes --no-login --smoke
```

## Teardown

```bash
fly apps destroy <api-app> --yes

# Needs delete_repo scope:  gh auth refresh -h github.com -s delete_repo
gh repo delete <owner>/<repo> --yes
```

If delete is denied, empty the `gh-pages` branch (or archive the repo in the UI).

## Related

- [podfly.yaml — `github_pages`](podfly.yaml.md)
- Peer static hosts: `cloudflare` · `vercel` · `netlify`
