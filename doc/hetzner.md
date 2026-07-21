# Hetzner Cloud — podfly host notes

`host: hetzner` (aliases: `hcloud`, `hetzner_cloud`) deploys Serverpod onto a
**Hetzner Cloud VPS**: bind an existing server or create one, then
**Docker over SSH**, with optional **Caddy HTTPS** on :443.

## What works

| Capability | Status |
|------------|--------|
| Stateless HTTP RPC | ✅ |
| Bind **existing** server (interactive list) | ✅ |
| **Create** server (location → type from live API) | ✅ |
| Ubuntu pin + Docker bootstrap | ✅ |
| Flutter **monolith** (nginx + Serverpod one container) | ✅ |
| Serverpod **WebSocket streams** | ✅ |
| **HTTPS :443** (Caddy + Let's Encrypt) | ✅ |
| Product FQDN (like `*.fly.dev`) | ❌ — use PTR or your domain |
| Scale-to-zero | ❌ — VPS bills while it exists |
| Terraform / CDK | ❌ — CLI only (`hcloud` + SSH) |

## Domains & HTTPS

Hetzner gives **IPs**, not an app hostname (unlike Fly / Cloud Run / ACA). Options:

1. **Reverse DNS (PTR)** on the primary IPv4, e.g.  
   `static.<reversed-ip>.clients.your-server.de` — resolves both ways.  
   With `https: true` and no `domain`, podfly uses this name for Caddy + ACME.
2. **Your domain** — set `hetzner.domain: api.example.com` and point an **A**
   record at the server IP so Let's Encrypt can succeed.

Raw **IP + HTTPS** without a hostname is a poor fit (certs need a name).  
With `https: false`, podfly exposes plain **HTTP** on `port` (default 8080).

## Prerequisites

```bash
brew install hcloud          # https://github.com/hetznercloud/cli
hcloud context create podfly # paste API token from console
hcloud ssh-key create --name mac --public-key-from-file ~/.ssh/id_ed25519.pub
docker                       # local build → stream image over SSH
dart pub global activate podfly
```

## Config

```yaml
host: hetzner
hetzner:
  # After first deploy, podfly fills:
  # server_id, server_name, ipv4, location, server_type, public_host
  image: ubuntu-24.04
  port: 8080
  https: true                 # Caddy :443 → container :8080 (default)
  # domain: api.example.com   # optional; else Hetzner PTR hostname
  # create: true              # with --yes: auto-create if unbound
  # location: ash             # preference; validated against live API
  # server_type: cpx11        # must exist in that location
  # ssh_key: mac-default
```

Full field list: [podfly.yaml.md § hetzner](podfly.yaml.md#hetzner).

## Deploy flows

### Interactive (TTY, unbound)

```bash
podfly deploy --host hetzner --smoke
```

1. List project servers → pick one **or** create new  
2. Create: choose **location**, then **type** (filtered by live API for that location)  
3. Wait for SSH (cloud-init can take ~30–90s after “running”)  
4. Bootstrap Docker if missing  
5. Local `docker build` → `docker save | ssh docker load`  
6. Run container; with `https: true`, install/reload **Caddy** for TLS  
7. Save bind fields to `podfly.yaml`

### Bound (re-deploy)

```yaml
hetzner:
  server_id: "12345"
  ipv4: 5.161.x.x
  public_host: static.…clients.your-server.de
```

Next deploys skip the picker and only push a new image (+ refresh Caddy if needed).

### Non-interactive (`--yes`)

Requires either:

- already bound `server_id` / `ipv4` / `server_name`, or  
- `create: true` (policy picks a suitable type in preferred/default location)

## Location / type policy

Types and locations **vary by region and over time**. podfly does not hardcode
a single SKU forever. It:

1. Queries `hcloud location list` / `server-type list`  
2. Filters x86, min RAM (`min_memory_gb`, default 2), offered in the chosen location  
3. Sorts by monthly price  

User overrides in yaml always win when valid for that location.

## Architecture (realtime monolith)

```text
Browser ──HTTPS :443──► Caddy (LE; PTR or custom domain)
                           └─ reverse_proxy → Docker
                                nginx :8080
                                  ├─ Flutter static
                                  └─ proxy → Serverpod :8081
                                       (RPC + /v1/websocket)
```

Caddy and nginx both forward WebSocket upgrades (expect **101** on `/v1/websocket`).

## Examples

| Path | Notes |
|------|--------|
| [hetzner/api_only](https://github.com/127thousand/podfly_examples/tree/main/hetzner/api_only) | Stateless RPC |
| [hetzner/realtime_monolith](https://github.com/127thousand/podfly_examples/tree/main/hetzner/realtime_monolith) | Flutter web + streams |

```bash
cd hetzner/realtime_monolith
podfly deploy --yes --smoke
# open printed https://… URL → Start clock stream
```

## Teardown

```bash
hcloud server delete SERVER_NAME_OR_ID
```

**Cost:** hourly while the server exists — delete demos when done.

## OS contract

Supported for bootstrap: **Ubuntu** (`ubuntu-24.04` default). Other images may
work if Docker is already installed; panel OS / Windows are out of scope.
