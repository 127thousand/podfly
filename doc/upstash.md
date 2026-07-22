# Upstash Redis — Serverpod cache + PubSub (`redis.provider: upstash`)

Optional **serverless Redis** for multi-instance Serverpod:

- Shared **cache** across machines  
- **PubSub** for server events / stream fan-out (`postMessage(..., global: true)`)

Small single-instance apps can leave Redis **off** (`redis.provider: none`, the default).

## Prerequisites

```bash
npm i -g @upstash/cli
upstash login
# or: UPSTASH_EMAIL + UPSTASH_API_KEY
```

## Config

```yaml
redis:
  provider: upstash
  upstash:
    name: my-app-redis      # defaults to <fly.app>-redis
    region: us-east-1
    provision: true         # create if missing
    # database_id / endpoint filled after first provision
```

| Key | Description |
|-----|-------------|
| `name` | Upstash DB name |
| `region` | Primary region for create |
| `provision` | Create DB when id/endpoint missing |
| `database_id` | Stable Upstash id (persisted) |
| `endpoint` | Host only, e.g. `xxx.upstash.io` |
| `port` | Default `6379` (TLS required) |

## What podfly does

1. `upstash redis list` / `create` when provisioning  
2. Writes `*_server/config/.podfly_upstash_redis.json` (endpoint, port, password)  
3. Patches `production.yaml`:

```yaml
redis:
  enabled: true
  host: xxx.upstash.io
  port: 6379
  requireSsl: true
```

4. Patches `passwords.yaml` → `production.redis: '…'`  
5. On **Fly**: `fly secrets set`  
   - `SERVERPOD_REDIS_ENABLED|HOST|PORT|REQUIRE_SSL`  
   - `SERVERPOD_PASSWORD_redis` (required when Redis is enabled; Serverpod’s env name is mixed-case `redis`)

Also patches `passwords.yaml` when present. If the server package has **no**
`config/production.yaml`, env secrets alone are enough (Fly path).

Matches [Serverpod Cloud’s Upstash guide](https://docs.serverpod.dev/cloud/guides/redis).

## Deploy

```bash
# podfly.yaml includes redis: upstash
podfly deploy --yes --smoke
```

Doctor requires `upstash` CLI + auth when `redis.provider: upstash`.

## Proving multi-machine PubSub

Two clients both receiving messages is **not** sufficient: Fly can pin both WebSockets to one machine, and local `postMessage` would still look “fine.”

A reliable proof:

1. Run **≥ 2** API machines (`fly.ha: true` / `min_machines_running ≥ 2`).
2. On connect, record which machine owns the **WebSocket** (e.g. first stream event with `FLY_MACHINE_ID`).
3. On **send**, tag the message with the machine that handled the HTTP RPC (load-balanced separately from the WS).
4. When **send machine ≠ listener machine** and the client still receives the event, fan-out went through Redis.

Example (worked end-to-end, then torn down):  
[podfly_examples/upstash/pubsub_chat](https://github.com/127thousand/podfly_examples/tree/main/upstash/pubsub_chat) — Netlify UI + Fly HA + Upstash; UI highlights **CROSS-MACHINE** deliveries.

```dart
// Publish so other instances receive the event
await session.messages.postMessage(channel, msg, global: true);

// Each instance feeds its own WebSocket listeners
return session.messages.createStream<ChatMessage>(channel);
```

Without Redis, `global: true` throws or never reaches other processes.

## Teardown

```bash
# Redis
upstash redis list
upstash redis delete --db-id <id>
# or console.upstash.com

# If you deployed the example stack:
fly apps destroy <api-app> --yes
netlify sites:delete <site-id> --force   # or vercel / gh as used

# Local (do not commit)
rm -f *_server/config/.podfly_upstash_redis.json
# strip production.redis from passwords.yaml if not gitignored
```

Add `config/.podfly_upstash_redis.json` to the server package `.gitignore` (password material).

## Related

- [podfly.yaml — redis](podfly.yaml.md)  
- Example: [upstash/pubsub_chat](https://github.com/127thousand/podfly_examples/tree/main/upstash/pubsub_chat)  
- [Serverpod caching](https://docs.serverpod.dev/concepts/caching)  
- [Serverpod Cloud Redis guide](https://docs.serverpod.dev/cloud/guides/redis)  
