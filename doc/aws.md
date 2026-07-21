# AWS (App Runner) — podfly host notes

`host: aws` (aliases: `apprunner`, `app_runner`, `amazon`) deploys Serverpod via
**AWS App Runner**: local Docker build → ECR → `create-service` / `update-service`.

## What works

| Capability | Status |
|------------|--------|
| Stateless HTTP RPC (`greeting.hello`, etc.) | ✅ |
| Scale / public HTTPS URL | ✅ |
| Flutter web **monolith** (nginx serves UI + proxies HTTP API) | ✅ packaging |
| Serverpod **method streams** / WebSockets | ❌ **not supported** |
| Scale-to-zero (Cloud Run style) | ❌ |

Examples:

- [api_only](https://github.com/127thousand/podfly_examples/tree/main/aws/api_only) — RPC
- [realtime_monolith](https://github.com/127thousand/podfly_examples/tree/main/aws/realtime_monolith) — UI + RPC; streams fail at the edge

## WebSockets: research summary (not a config bug)

### Symptom

```http
GET /v1/websocket
Connection: Upgrade
Upgrade: websocket
→ HTTP/1.1 403 Forbidden
server: envoy
connection: close
```

HTTP RPC on the same host returns **200**. The failure is **before** the container
(nginx / Serverpod never see a successful upgrade).

### Why “configure Envoy” does not apply

**Envoy can proxy WebSockets** when you own the proxy (ECS/EKS/self-managed).

App Runner’s edge is a **managed** Envoy. Customers cannot set:

- WebSocket / HTTP upgrade enablement  
- upgrade-related idle timeouts  
- custom Envoy HCM / filter chains  

`CreateService` / `UpdateService` only expose port, start command, env, CPU/memory,
health checks, public/private ingress, VPC egress, observability — **nothing** for
protocol upgrade. See [CreateService API](https://docs.aws.amazon.com/apprunner/latest/api/API_CreateService.html).

Improving **in-container** nginx (`proxy_set_header Upgrade` / `Connection`) cannot
fix an edge that rejects the upgrade with **403**.

### AWS docs & platform stance

- [Developing application code for App Runner](https://docs.aws.amazon.com/apprunner/latest/dg/develop.html):
  HTTP/1.0–1.1 request/response, **120s** request timeout, design for **stateless**
  per-request work — not long-lived bidirectional sockets.
- [Roadmap #13 Support web sockets](https://github.com/aws/apprunner-roadmap/issues/13):
  **closed as not planned**.
- Community (Streamlit, NestJS, re:Post): same local-OK / App Runner-403 pattern.

### Implications for Serverpod

| Host | Flutter monolith | Streams (WS) |
|------|------------------|--------------|
| Cloud Run (`host: cloud_run`) | ✅ | ✅ (with timeout + affinity) |
| App Runner (`host: aws`) | ✅ (HTTP only) | ❌ edge 403 |
| ECS + ALB (`host: aws_ecs`) | ✅ | ✅ (ALB supports WebSockets) |

**Recommendation:** use App Runner for **stateless API** demos; use **`host: aws_ecs`**
(or Cloud Run / Fly) for Serverpod streams. See [ECS sketch](specs/2026-07-21-aws-ecs-realtime-sketch.md)
and example [aws/ecs_realtime](https://github.com/127thousand/podfly_examples/tree/main/aws/ecs_realtime).

## Deploy knobs that *do* matter

| Issue | Fix |
|-------|-----|
| CREATE_FAILED, empty logs | Set `start_command` (default `/app/entrypoint.sh`); shell-form ENTRYPOINT alone is flaky |
| Private ECR pull flaky | `ecr_public: true` (ECR Public + `ECR_PUBLIC`) for demos |
| Monolith image | Root `Dockerfile` preferred when present (nginx + Serverpod) |
| Cost | **Not** free scale-to-zero — delete services after demos |

Full YAML: [podfly.yaml.md § aws](podfly.yaml.md#aws).

## Teardown

```bash
aws apprunner list-services --region us-east-1
aws apprunner delete-service --service-arn "$SERVICE_ARN" --region us-east-1
# optional: ecr / ecr-public delete-repository …
```
