# Azure Container Apps — podfly host notes

`host: azure` (aliases: `aca`, `containerapps`, `container_apps`) deploys Serverpod via
**Azure Container Apps**: local Docker build → **ACR** → managed environment + container app.

## What works

| Capability | Status |
|------------|--------|
| Stateless HTTP RPC (`greeting.hello`, etc.) | ✅ |
| Scale-to-zero (`min_replicas: 0`) | ✅ |
| Public HTTPS FQDN | ✅ |
| Flutter web **monolith** (nginx + Serverpod) | ✅ |
| Serverpod **method streams** / WebSockets | ✅ (Container Apps HTTP transport supports Upgrade) |
| Free forever | ❌ — pay for ACR + environment when used; delete RG after demos |

Examples:

- [api_only](https://github.com/127thousand/podfly_examples/tree/main/azure/api_only) — RPC  
- [realtime_monolith](https://github.com/127thousand/podfly_examples/tree/main/azure/realtime_monolith) — Flutter web + API + streams

## Flow

1. Ensure resource group (`{app}-rg` by default)
2. Ensure ACR (**Basic**, admin enabled) + `az acr login`
3. `docker build` / `push` (`linux/amd64`)
4. Ensure Container Apps **environment**
5. `az containerapp create` or `update` with external ingress, target port **8080**

## Prerequisites

```bash
az login
az account set --subscription <id>   # if needed
# Docker Desktop / engine running
dart pub global activate podfly
```

Extension: `az extension add --name containerapp` (or update if present).

## Config knobs

Full YAML: [podfly.yaml.md § azure](podfly.yaml.md#azure).

| Issue | Fix |
|-------|-----|
| ACR name taken | Set unique `azure.registry` (alphanumeric only, 5–50 chars, global) |
| Container app name rules | Lowercase alnum/hyphen, &lt; 32 chars, no `--` |
| Cold start after scale-to-zero | First request may take longer; raise `min_replicas` if needed |
| Cost | Delete the **resource group** when done (app + env + ACR) |

## Teardown (stop charges)

```bash
# simplest: delete the whole resource group written to podfly.yaml
az group delete --name "$RESOURCE_GROUP" --yes --no-wait

# or piece-wise:
az containerapp delete -n "$APP" -g "$RESOURCE_GROUP" --yes
az containerapp env delete -n "$ENV" -g "$RESOURCE_GROUP" --yes
az acr delete -n "$REGISTRY" -g "$RESOURCE_GROUP" --yes
az group delete -n "$RESOURCE_GROUP" --yes
```

## WebSockets

Unlike **AWS App Runner**, Container Apps supports WebSocket upgrades on HTTP ingress.
For long streams, keep a single replica or plan session affinity; scale-to-zero is fine
for demos that accept cold start.
