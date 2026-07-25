# podfly create — product roadmap

**Status:** living plan  
**Created:** 2026-07-25  
**Owner:** podfly maintainers  
**Related:** [design](2026-07-18-podfly-design.md), [host adapters](2026-07-19-host-adapter-design.md)

This document is the working plan for evolving podfly from a **Serverpod deploy orchestrator** into a **Flutter monorepo scaffolder + ship tool**. Update this file as phases complete or scope changes.

---

## Vision

**podfly** = one CLI to:

1. **Create** a full monorepo (surfaces + optional backend + optional app architecture).
2. **Deploy / destroy / smoke** with existing cloud CLIs (hosts already built).

Serverpod remains the **flagship backend recipe**, not the only religion.

```
podfly create  →  monorepo with everything
podfly deploy  →  same host engine (Fly, Cloud Run, nginx monolith, CDN split, …)
```

**Out of scope for this roadmap:** multi-region databases, Aurora Global, LiteFS, Spanner-class problems. Those are not podfly’s job.

---

## Product shape

### Axes

| Axis | Options (target) | Notes |
|------|------------------|--------|
| **Product kind** | app+backend · app-only · backend-only | Top menu |
| **Surfaces** | mobile · web · desktop · multi | Multi-select when app |
| **Backend** | none · serverpod · dart_frog · relic · grpc | Recipes plug in |
| **Web topology** | monolith · split | Only if web + backend |
| **App kit** | minimal · recommended · custom | State + nav + folders (later phases) |
| **Ship** | host, DB, redis, mobile CI | Existing init/deploy flow |

### Connect vs gRPC

- **gRPC** (`package:grpc`) = pure Dart **server** recipe (reference: modernize `nrml-grpc`).
- **Connect RPC** ≠ gRPC. Connect-Dart is **client-first** today; do **not** block on a Dart Connect **server**.
- Optional later: Flutter **Connect client** talking to a gRPC or polyglot Connect server.

### Monorepo skeleton (target)

Same tree for all recipes; slots fill differently:

```text
my_app/
  podfly.yaml
  pubspec.yaml                 # Dart workspace
  apps/
    client/                    # Flutter (platforms enabled per surface)
  packages/
    api_client/                # generated/hand client per backend
    shared/                    # optional
  services/
    api/                       # serverpod | frog | relic | grpc
  deploy/                      # nginx monolith assets when needed
  Dockerfile
  .github/ or codemagic.yaml   # if mobile CI
```

**Serverpod compatibility:** v1 may still emit classic `*_server` / `*_client` / `*_flutter` names when `backend: serverpod`, then normalize to `apps/` + `services/` later.

---

## Principles

1. **Recipes plug in; hosts don’t fork** — one Fly/Cloud Run/… adapter, many backends.
2. **HTTP backends share smoke + nginx monolith**; gRPC has its own health/smoke and HTTP/2 notes.
3. **Flutter API URL story is fixed** (learned the hard way):
   - debug → localhost (or Android emu `10.0.2.2`)
   - release split → baked production API URL (never CDN same-origin)
   - release monolith → same origin
4. **One blessed app kit** + few escapes — not a template zoo.
5. **Create ≠ multi-region DB.**
6. Compose `flutter create` / `serverpod create`; own glue, not reimplement frameworks.

---

## Phase roadmap

### Phase 0 — Contract (foundation)

**Goal:** Types and docs so create doesn’t sprawl.

| Deliverable | Detail |
|-------------|--------|
| `BackendRecipe` interface | `id`, `scaffold`, optional `generate`, `smoke`, `dockerfile`, `localRun` |
| `SurfaceSpec` | mobile / web / desktop flags |
| `CreateContext` | root path, name, workspace, yes/dry-run |
| `podfly.yaml` sketch | `create.surfaces`, `create.backend`, existing host/web keys |
| ADR snippet in this file | defaults for nav/state when app kit lands |

**Exit:** Interface compiles; no user-facing create yet (or stub `podfly create --help`).

---

### Phase 1 — `podfly create` MVP

**Goal:** Monorepo → existing `podfly deploy` for Serverpod.

| Include | Exclude |
|---------|---------|
| Product kind: app+backend, app-only, backend-only | App kit (riverpod/go_router) |
| Surfaces: **mobile**, **web**, both | Desktop (scaffold platforms optional later) |
| Backend: **serverpod**, **none** | frog, relic, grpc |
| Write `podfly.yaml` | New hosts |
| Interactive menus + `--yes` defaults | Fancy upgrade of old monorepos |

**Exit criteria:**

- [ ] `podfly create` produces a workspace monorepo.
- [ ] Serverpod path deploys with current Fly/Cloud Run monolith/split paths.
- [ ] App-only + backend-only trees make sense and doctor doesn’t crash.
- [ ] README in scaffold: local run + deploy one-liners.

**Suggested implementation notes:**

- Prefer wrapping `serverpod create` + move into workspace layout, or copy maintained templates under `templates/create/serverpod/`.
- Reuse init host picker where possible after scaffold.

---

### Phase 2 — Second backend (prove pluggability)

**Goal:** One non-Serverpod recipe shares deploy spine.

| Order | Recipe | Why |
|-------|--------|-----|
| **2a** | **dart_frog** | HTTP, simple Docker/smoke, Flutter-friendly |
| **2b** | **relic** | Modern Dart HTTP / Serverpod-adjacent |
| **2c** | **grpc** | Pure Dart `package:grpc`; template from modernized nrml-grpc |

**grpc modernization checklist (template source):**

- [ ] SDK `^3.8+`, `grpc` ^5.x, current protobuf
- [ ] Buf for codegen (optional but preferred)
- [ ] Health / smoke path for deploy
- [ ] Dockerfile + Fly/Cloud Run notes (HTTP/2)
- [ ] Flutter client: `package:grpc` and/or later Connect **client**

**Exit:** Same host adapters deploy frog (and later grpc) without forking `CloudRunHost` / `FlyHost`.

---

### Phase 3 — Surfaces completion

| Surface | Work |
|---------|------|
| **Desktop** | Enable macOS/Windows/Linux on client app; same API URL rules as mobile |
| **Multi-app** | Optional second Flutter package only if needed |
| **Web topology menus** | Only when web + backend: monolith vs split (existing deploy behavior) |

**Exit:** Desktop in create multi-select; no store/installer CI required yet.

---

### Phase 4 — App kit (one-stop-shop Flutter)

**Goal:** Opinionated UI architecture so podfly scaffolds **apps**, not empty counters.

| Deliverable | Default (proposed) | Optional |
|-------------|-------------------|----------|
| Folder layout | feature-first `lib/features/…`, `lib/core/` | minimal flat |
| Navigation | **go_router** | none |
| State | **riverpod** *or* **bloc** (pick one default in Phase 0 ADR) | other / none |
| App entry | `MaterialApp.router` + env/API bootstrap | |
| Lint | strict `analysis_options` | |

**Menus:**

```
App architecture
  • Recommended (go_router + <default state> + features/)
  • Minimal (stock Flutter)
  • Custom: --state=… --nav=…
```

**Order of work inside Phase 4:**

1. Structure only (folders + analysis)  
2. Navigation  
3. State management  
4. Optional: theme, l10n stubs, sample feature calling `api_client`

**Exit:** `--app-kit=recommended` produces a runnable app that can call the backend client when backend ≠ none.

---

### Phase 5 — One-stop polish

| Item | Notes |
|------|--------|
| `podfly run` | Local: start API + flutter (recipe-specific) |
| Golden monorepos in CI | Create each recipe, analyze, optional dry-run deploy |
| Template versioning | Bump create templates without breaking old podfly.yaml |
| Docs | User guide section “Create”; update root README |
| Desktop CI | Optional MSIX/DMG/notarize — only if demanded |

---

## Interactive flow (target UX)

```
1) What are you building?
   • App + backend (recommended)
   • App only (Flutter)
   • Backend only (API)

2) Surfaces (if app) — multi-select
   • Mobile (iOS/Android)
   • Web
   • Desktop (macOS/Windows/Linux)

3) Backend (if not app-only)
   • Serverpod
   • Dart Frog
   • Relic
   • gRPC (Dart)
   • None

4) If web + backend → topology
   • Monolith (one URL)
   • Split (CDN UI + API host)

5) App kit (Phase 4+)
   • Recommended / Minimal / Custom

6) Host / database / mobile CI… (existing init)
```

Non-interactive: `podfly create --yes` with flags mirroring the above.

---

## `podfly.yaml` sketch (create-related)

```yaml
# Existing keys remain authoritative for deploy.
host: fly
mode: split          # or monolith
name: my_app
# server/flutter paths may stay for serverpod or become:
# backend: services/api
# app: apps/client

create:
  surfaces: [mobile, web]
  backend: serverpod       # none | serverpod | dart_frog | relic | grpc
  app_kit: recommended     # minimal | recommended | custom
  # optional:
  # state: riverpod
  # nav: go_router
```

Exact field names can change in Phase 0; keep deploy keys stable.

---

## Explicit non-goals

- Multi-region / multi-master databases (Neon×2, Aurora Global, LiteFS as product features)
- Supporting every state-management library
- Replacing `flutter create` or `serverpod create` internals
- gRPC **as** Serverpod transport
- Waiting on Connect-Dart **server** for a grpc/connect recipe

---

## Success metrics

| Metric | Target |
|--------|--------|
| Time to first deploy from empty dir | &lt; 30 min for Serverpod+Fly path |
| Recipes with CI dry-run green | serverpod, none, then frog |
| “Works on my machine” local story | Documented one-liner per recipe |
| Split web never POSTs CDN by default | Regression covered in app URL resolver template |

---

## Working log

| Date | Note |
|------|------|
| 2026-07-25 | Roadmap created from product discussion (create vision, surfaces, backends, app kit, nrml-grpc notes). |
| | Prior art: nginx monolith all-in-one hosts, split SERVER_URL rules, destroy, web.build modes. |

---

## Next action

When starting implementation, check the first unchecked box in **Phase 0**, then **Phase 1** exit criteria. Prefer small PRs: contract → create serverpod/none → frog → app kit.
