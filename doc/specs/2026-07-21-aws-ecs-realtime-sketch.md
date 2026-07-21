# Sketch: AWS ECS Fargate + ALB realtime (Serverpod streams)

**Status:** **implemented** as `host: aws_ecs` (CLI orchestration, no CDK).  
**Goal:** first-class AWS path for **Flutter web + Serverpod WebSocket streams**, where App Runner cannot go.

## Problem

`host: aws` (App Runner) is fine for HTTP RPC and static UI packaging, but the managed
edge (Envoy) returns **403** on `Upgrade: websocket`. Serverpod method streams need WS.

**Cloud Run** already proves the monolith pattern (`gcp/realtime_monolith`). AWS needs a
host that actually forwards upgrades: **Application Load Balancer** → **ECS Fargate**.

## Target shape (v1)

```text
Browser
  │ HTTPS :443
  ▼
ALB  (HTTP/HTTPS listener, idle timeout ≥ 3600s, stickiness optional)
  │
  ├─ path /  (static)  → same target group OR separate static service
  └─ path /* API + /v1/websocket → target group → Fargate tasks
                    │
                    ▼
              Task: nginx :8080
                    ├─ static Flutter (build/web)
                    └─ proxy → Serverpod :8081
```

Same **container** as App Runner / Cloud Run monolith (`Dockerfile` + `deploy/nginx.conf`
+ `start.sh`). Only the **front door** changes.

### Alternatives considered

| Option | Pros | Cons for podfly v1 |
|--------|------|---------------------|
| **ALB + Fargate monolith** (chosen) | Real WS; reuses monolith image; one public hostname | More IAM/VPC; not scale-to-zero free |
| API Gateway WebSocket API | Managed WS | Wrong protocol model for Serverpod client streams |
| CloudFront → App Runner | CDN | Origin still App Runner → still no WS |
| NLB TCP passthrough | Raw TCP | TLS/certs harder; less “PaaS” |
| App Runner + separate WS service | — | App Runner still blocks WS |

## podfly product shape (proposed)

```yaml
host: aws_ecs   # or host: aws + aws.runtime: ecs|apprunner
mode: monolith
name: aws_rt

aws_ecs:   # or aws: { runtime: ecs, ... }
  cluster: podfly-aws-rt
  service: podfly-aws-rt
  region: us-east-1
  cpu: "512"
  memory: "1024"
  desired_count: 1
  # ALB
  idle_timeout_seconds: 3600
  health_check_path: /   # or TCP on 8080
  # Networking
  # vpc_id / subnets / public: true → create or use defaults
  assign_public_ip: true
  # Image
  ecr_repository: podfly-aws-rt
  platform: linux/amd64
```

### Deploy pipeline (orchestrate existing CLIs)

1. **Doctor:** `aws`, `docker`, credentials; optional `jq`.
2. **Network:** default VPC or create VPC + 2 public subnets (minimal “works” path).
3. **ECR:** create repo, `docker build --platform linux/amd64`, push (private ECR is fine with task execution role).
4. **IAM:** task execution role (ECR pull, logs) + task role (empty or CloudWatch).
5. **Logs:** CloudWatch log group `/ecs/podfly-…`.
6. **ALB:** internet-facing, security group 443/80 → tasks 8080; target group HTTP:8080;
   stickiness optional; **idle timeout 3600**.
7. **TLS:** ACM certificate + HTTPS listener (prompt for domain / use HTTP-only for demos).
8. **ECS:** cluster (Fargate), task definition (monolith image, port 8080, `start.sh`),
   service desired_count=1, attach to target group, public IP if no NAT.
9. **Patch** `production.yaml` publicHost + `podfly.yaml` public_host / service ARN.
10. **Smoke:** `POST /greeting/hello` + optional WS probe (`Upgrade` → expect **101**, not 403).

### Config / adapter sketch

```
AwsEcsHost implements HostAdapter
  id: aws_ecs
  canDeploy: true
  supportedDatabases: none, neon  # RDS later
```

Keep **`host: aws`** = App Runner (cheap RPC). Do **not** overload App Runner with ECS
flags; separate host id is clearer for wizard + docs.

### Smoke for streams (new)

```yaml
smoke:
  api:
    method: POST
    path: /greeting/hello
    body: '{"name":"ecs"}'
  web:
    path: /
  # future:
  # websocket:
  #   path: /v1/websocket
  #   expect_upgrade: true
```

Manual v1: document `curl` upgrade probe expecting **101 Switching Protocols** from ALB
(not Envoy 403).

## Cost / ops notes

- Fargate + ALB has a **floor** cost (ALB hours + task CPU/memory). Worse than App Runner
  for idle RPC demos; correct for realtime.
- `desired_count: 0` is possible but loses always-on URL; for demos use 1 and **delete**.
- Multi-task streams without Redis still need stickiness; multi-instance fan-out needs Redis
  (Upstash parked).

## Implementation phases

| Phase | Deliverable |
|-------|-------------|
| **0** | This sketch + App Runner WS docs (done in parallel) |
| **1** | Manual `aws/` scripts or CDK one-shot that deploys existing monolith image to Fargate+ALB; prove WS 101 + Flutter stream UI |
| **2** | `AwsEcsHost` in podfly: ECR + task def + service + ALB; HTTP smoke |
| **3** | ACM/domain helper; WS smoke; example `aws/ecs_realtime` in podfly_examples |
| **4** | Optional: RDS / Neon; min capacity / autoscaling; private subnets + NAT |

## Out of scope (v1)

- App Runner WebSocket “config” workarounds (none exist)  
- API Gateway WebSocket protocol adapter for Serverpod client  
- Full Terraform/GCE-style multi-region  

## Success criteria

1. Browser opens ALB URL → Flutter UI.  
2. `greeting.hello` 200.  
3. **Start clock stream** receives ticks (same as Cloud Run demo).  
4. `curl` WebSocket upgrade to `/v1/websocket` → **101**, not 403.  
5. `podfly deploy --host aws_ecs --yes --smoke` (or documented script) is repeatable.  
6. Teardown command/script removes ALB + service + task def + ECR (or documents cost if left).

## References

- [ALB listeners / WebSocket](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-listeners.html)  
- [App Runner develop (HTTP-only model)](https://docs.aws.amazon.com/apprunner/latest/dg/develop.html)  
- [podfly AWS App Runner notes](../aws.md)  
- Working stream demo: `podfly_examples/gcp/realtime_monolith`  
- Container reuse: `podfly_examples/aws/realtime_monolith` Dockerfile  
