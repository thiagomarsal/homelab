# Open WebUI + Porquinho MCP Integration — Design

**Date:** 2026-09-22
**Status:** approved design, not yet implemented
**Scope:** deploy Open WebUI to the k3s homelab and wire it to (a) Gemini and (b)
porquinho's existing MCP tool surface, so the FII/ações research corpus becomes
queryable from a chat UI. First of a two-part effort — trading-agent integration
(tauricresearch/tradingagents, fed by the same corpus) is a separate, later spec
that depends on this one.

---

## 1. Problem

Porquinho's research corpus (23,533 embedded chunks, 11,343 análises, 331 cartas)
is fully ingested and already queryable — but only through `curl` against
`/internal/search` or an MCP client wired by hand. There is no chat interface, and
no way to reach it from a phone or a browser without a terminal. The project's own
architecture doc (`porquinho-architecture-plan.md`, §8, §12 Phase 6) already names
Open WebUI as the intended vendor-free front end; it has simply never been
deployed.

## 2. What already exists (do not rebuild)

- **porquinho** is live in the `porquinho` namespace — Deployment + Postgres
  StatefulSet, Helm-managed from the porquinho repo (`deploy/helm/porquinho`,
  release `porquinho`, currently rev 39). `porquinho.tmf-solutions.com` behind a
  `porquinho-lan-only` Traefik Middleware (`192.168.1.0/24`, `10.42.0.0/16`);
  `/internal/*` paths are excluded from that public route entirely.
- **MCP server** is live inside the app (`spring-ai-starter-mcp-server-webmvc`,
  Spring AI 2.0), exposing `searchReports` and `getThesis` as `@Tool` methods. It
  currently runs the legacy SSE transport — Open WebUI's native MCP support
  (v0.6.31+) speaks **Streamable HTTP only**, so this needs one property change
  (§4).
- **Corpus** is fully embedded (0 chunks missing embeddings as of 2026-09-21).
  Nothing in this spec touches ingestion.

## 3. Governing constraints

- **No public exposure.** Porquinho's own architecture doc is explicit: never
  expose it to the internet. Open WebUI inherits the same rule — it's a window
  onto the same private research corpus and, once Gemini is wired, holds an API
  key worth protecting.
- **Homelab repo conventions, not porquinho's.** Porquinho uses a Helm chart
  because it's a custom app with its own CI-built image. Open WebUI is off-the-
  shelf (`ghcr.io/open-webui/open-webui`) — it follows this repo's existing
  pattern for that case: plain manifests under `kubernetes/apps/<name>/`, the same
  shape as `kubernetes/apps/n8n/`.
- **No GPU in the fleet.** All 6 Proxmox hosts are low-power SFF/mini-PCs with no
  discrete GPU. Local model inference (Ollama) was evaluated and explicitly
  deferred — cloud-only (Gemini) for this phase. If GPU hardware is added later,
  Ollama is an additive change to this design, not a rework of it.

## 4. Decisions

| # | Decision | Choice | Rationale |
|---|---|---|---|
| 1 | MCP transport | Set `spring.ai.mcp.server.protocol: STREAMABLE` in porquinho's `application.yml` | Open WebUI's native MCP client only speaks Streamable HTTP; SSE is deprecated in Spring AI 2.0 anyway |
| 2 | MCP reachability | In-cluster Service DNS (`http://porquinho.porquinho.svc.cluster.local/mcp`), not through Traefik | Both pods are in the same cluster; routing through the public ingress would add a TLS hop and a LAN-allowlist check for no benefit |
| 3 | LLM provider | Gemini via Open WebUI's OpenAI-compatible connection type, `https://generativelanguage.googleapis.com/v1beta/openai` | Matches the provider-swap pattern already documented in porquinho's own architecture doc §8; no new integration code anywhere |
| 4 | Local models | Deferred entirely | No GPU in the fleet; CPU-only inference on the best available host (pve02, i7-10700T) was judged too slow to be worth deploying now |
| 5 | Manifest style | Plain Kubernetes YAML in the homelab repo, mirroring `kubernetes/apps/n8n/` | Off-the-shelf image, no build pipeline — a Helm chart would be pure overhead |
| 6 | API key storage | Entered through Open WebUI's own admin UI (Settings → Connections), not a Kubernetes Secret | This is how Open WebUI's connection model actually works — keys persist in its own SQLite DB, not env vars. A Secret would be dead weight nothing reads. Separately, one Secret *is* needed for `WEBUI_SECRET_KEY` (session-cookie signing) — a different concern found during implementation planning, unrelated to provider API keys. See the implementation plan. |
| 7 | Persistence | Single Longhorn PVC (5Gi), `ReadWriteOnce`, mounted at Open WebUI's data dir | Holds its SQLite DB (chat history, users, connection config) and any uploaded files. 5Gi is generous headroom for single-user use; grow later if needed. |
| 8 | Access | New `open-webui-lan-only` Middleware, same source ranges as porquinho's | Consistent with the existing "never expose publicly" rule; a second middleware per §3 rather than a cross-namespace reference, matching the one-middleware-per-app pattern already in use |

### 4.1 Out of scope

- **tradingagents integration** — separate spec, written after this one ships and
  is verified working end-to-end.
- **Ollama / local inference** — deferred per Decision 4. Revisit only if GPU
  hardware is added to the fleet.
- **Multi-user auth hardening** — Open WebUI's own login (email/password) is
  sufficient for single-user, LAN-only access. SSO/OIDC is not needed here.
- **Any change to porquinho's ingestion, embedding, or search ranking.** This
  spec is a front end and a transport-protocol flip; the corpus and retrieval
  logic are untouched.

## 5. Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ k3s cluster                                                      │
│                                                                   │
│  ┌─────────────────────┐        ┌──────────────────────────┐    │
│  │ namespace: open-webui│        │ namespace: porquinho      │    │
│  │                      │        │                            │    │
│  │  Deployment          │  MCP   │  Deployment (existing)     │    │
│  │  ghcr.io/open-webui/ │ ─────▶ │  Streamable HTTP @ /mcp    │    │
│  │  open-webui:<pinned> │  (svc  │                            │    │
│  │                      │  DNS)  │  Postgres StatefulSet      │    │
│  │  PVC (5Gi, Longhorn) │        │  (existing, untouched)     │    │
│  │  Service (ClusterIP) │        │                            │    │
│  │  IngressRoute ───────┼──┐     └────────────────────────────┘    │
│  │  Middleware (LAN-only)│  │                                      │
│  └───────────────────────┘  │                                      │
│                              │                                      │
└──────────────────────────────┼──────────────────────────────────────┘
                                │
                    Traefik (websecure, wildcard TLS)
                                │
                 ai.tmf-solutions.com
                       (LAN + pod CIDR only)
                                │
                            Browser
                                │
                   Gemini (generativelanguage.
                   googleapis.com, OpenAI-compat)
```

## 6. Changes by repo

### 6.1 porquinho repo (one property)

`src/main/resources/application.yml`, under the existing `mcp.server` block:

```yaml
spring:
  ai:
    mcp:
      server:
        protocol: STREAMABLE
```

Verify the resulting endpoint path (Spring AI's default is `/mcp` for the
streamable-http starter; confirm against the running property, don't assume).
Bump the Helm chart's `image.tag` to the new build and `helm upgrade` as usual —
no other porquinho change is in scope here.

### 6.2 homelab repo — new `kubernetes/apps/open-webui/`

Files, matching the n8n directory shape:

- `namespace.yml` (or an entry in `kubernetes/base/namespaces.yml` — follow
  whichever the n8n entry actually used; confirm at implementation time)
- `deployment.yml` — single replica, `Recreate` strategy (RWO PVC, same reason as
  n8n), `ghcr.io/open-webui/open-webui:<pinned digest or version tag>` (no
  `latest` — same reasoning as porquinho's own image-tag policy), resource
  requests/limits sized from Open WebUI's documented baseline (confirm at
  implementation time rather than guessing; it is a Python/FastAPI app plus a
  bundled frontend, not comparable to porquinho's embedding workload)
- `pvc.yml` — 5Gi, Longhorn default StorageClass
- `service.yml` — ClusterIP, port matching the image's default (8080)
- `middleware.yml` — `open-webui-lan-only`, `ipAllowList` sourceRange
  `192.168.1.0/24` + `10.42.0.0/16` (copy of porquinho's)
- `ingressroute.yml` — `Host(\`ai.tmf-solutions.com\`)`, `websecure`
  entrypoint, `wildcard-tmf-solutions-tls` secret, `open-webui-lan-only`
  middleware attached

Pi-hole already has `ai.tmf-solutions.com` → Traefik's MetalLB VIP, done
ahead of this spec — no DNS work left once the IngressRoute exists.

No `secret.yml` — per Decision 6, nothing in the manifest set needs one.

## 7. Post-deploy configuration (manual, in the Open WebUI admin UI)

Not represented in git — this is runtime state in Open WebUI's own database:

1. **Admin → Settings → Connections** — add an OpenAI-compatible connection:
   base URL `https://generativelanguage.googleapis.com/v1beta/openai`, API key
   from your Gemini token, verify a model list loads.
2. **Admin → Settings → External Tools** — add porquinho as an MCP server:
   `http://porquinho.porquinho.svc.cluster.local/mcp` (confirm exact path per
   §6.1), Streamable HTTP transport.
3. Confirm `searchReports` and `getThesis` appear as available tools in a new
   chat.

## 8. Validation

- `kubectl -n open-webui get pods` — running, no restarts, PVC bound.
- `curl` the porquinho MCP endpoint's handshake directly (from inside the
  cluster, e.g. a debug pod) before touching the Open WebUI UI, to isolate the
  protocol-flip change from the Open WebUI wiring.
- In Open WebUI: send a chat message that requires the corpus, e.g. ask about a
  specific ticker's recent vacância — confirm the model calls `searchReports`
  (visible in Open WebUI's tool-call UI) and the reply cites a real date and URL
  from the corpus rather than answering from pretraining.
- Confirm `ai.tmf-solutions.com` is unreachable from outside
  `192.168.1.0/24` (e.g. via mobile data with wifi off) and reachable from LAN.

## 9. Risks

- **Streamable HTTP endpoint path may not default to `/mcp`.** Spring AI's
  property names for this are new as of 2.0; confirm the actual served path
  against the running app rather than trusting documentation, the same lesson
  `API-MAP.md` already learned the hard way about this codebase's other
  integrations.
- **Open WebUI resource sizing is a guess until deployed.** Unlike porquinho's
  extensively-measured embedding pod, there's no prior data here. Start with
  documented-baseline requests/limits, watch `kubectl top pod`, adjust.
- **Gemini free-tier limits.** Fine for personal chat volume; would need
  revisiting if tradingagents (the next spec) drives much higher call volume
  against the same key.
