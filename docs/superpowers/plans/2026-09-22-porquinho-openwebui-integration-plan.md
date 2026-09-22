# Porquinho + Open WebUI Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Open WebUI to the k3s homelab as a chat front end for porquinho's research corpus, wired to Gemini for reasoning and to porquinho's MCP tool surface (`searchReports`, `getThesis`) for grounded retrieval.

**Architecture:** Flip porquinho's already-live MCP server from SSE to Streamable HTTP (one Spring AI property), release and redeploy it. Deploy Open WebUI as a new plain-manifest app in the homelab repo, reachable only from the LAN, wired at runtime (via its own admin UI, not env vars) to Gemini and to porquinho's MCP endpoint over in-cluster Service DNS.

**Tech Stack:** Spring AI 2.0 MCP server (porquinho, existing), Open WebUI (`ghcr.io/open-webui/open-webui`, new), k3s, Traefik IngressRoute/Middleware, Longhorn PVC, Helm (porquinho only — Open WebUI uses plain manifests).

**Spec:** `docs/superpowers/specs/2026-09-22-porquinho-openwebui-integration-design.md`

## Global Constraints

- Never expose porquinho or Open WebUI to the internet — LAN-only Traefik `ipAllowList` (`192.168.1.0/24`, `10.42.0.0/16`) on both.
- No GPU in the fleet — cloud-only (Gemini) for this phase; no Ollama.
- Open WebUI manifests are plain YAML in `kubernetes/apps/open-webui/`, matching `kubernetes/apps/n8n/` — no Helm chart for it.
- Never deploy a moving image tag. Porquinho: an immutable `vX.Y.Z` release tag via `scripts/release.sh` + `scripts/deploy.sh` (never `latest`). Open WebUI: a pinned `vX.Y.Z[-slim]` tag (never `:main`/`:latest`).
- Secrets follow the repo's actual convention (not the aspirational one in `CLAUDE.md`): a placeholder `secret.yml` is committed with a comment explaining how to create the real one; the real value is applied manually with `kubectl create secret`, never committed.
- `ai.tmf-solutions.com` already resolves in Pi-hole to Traefik's MetalLB VIP — no DNS work in this plan.

---

## Task 1: Flip porquinho's MCP server to Streamable HTTP, release, deploy

**Repo:** `/mnt/c/development/porquinho`

**Files:**
- Modify: `src/main/resources/application.yml:47-51` (the existing `mcp.server` block)

**Interfaces:**
- Produces: porquinho's MCP server reachable at `http://porquinho.porquinho.svc.cluster.local/mcp` speaking Streamable HTTP (Spring AI's default `mcp-endpoint` for this transport is `/mcp` — confirmed against `spring-ai-starter-mcp-server-webmvc` 2.0 docs; porquinho does not currently override `spring.ai.mcp.server.streamable-http.mcp-endpoint`, so the default applies). Task 4 consumes this URL.

No new test is added here: this is a one-property configuration change to a third-party starter's transport, not new application logic. Verification is functional (the curl check in Step 8), matching how the spec itself validates this (§8).

- [ ] **Step 1: Edit the MCP server config**

In `src/main/resources/application.yml`, change:

```yaml
    mcp:
      server:
        name: porquinho
        version: 0.1.0
        type: SYNC
```

to:

```yaml
    mcp:
      server:
        name: porquinho
        version: 0.1.0
        type: SYNC
        # Open WebUI's native MCP client (v0.6.31+) only speaks Streamable HTTP.
        # SSE (the prior default) is deprecated in Spring AI 2.0. Default
        # mcp-endpoint for this transport is /mcp — not overridden here.
        protocol: STREAMABLE
```

- [ ] **Step 2: Confirm the app still builds**

Run: `./mvnw -q -DskipTests clean package`
Expected: `BUILD SUCCESS`, `target/porquinho-*.jar` produced. `-DskipTests` is correct here — the test suite needs Testcontainers/Postgres and this change has no logic to unit-test; the build check alone catches a YAML typo or an invalid enum value.

- [ ] **Step 3: Commit**

```bash
cd /mnt/c/development/porquinho
git add src/main/resources/application.yml
git commit -m "$(cat <<'EOF'
feat: switch MCP server to Streamable HTTP transport

Open WebUI's native MCP client only speaks Streamable HTTP (v0.6.31+),
and SSE is deprecated in Spring AI 2.0 anyway. No endpoint path change
— /mcp is still the default.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
git push origin main
```

- [ ] **Step 4: Cut a release**

```bash
scripts/release.sh minor
```

This is a `minor` bump per the project's own rule (`scripts/release.sh` header comment): new behaviour, backward-compatible — existing MCP clients using SSE would break, but there are none in production use yet (Open WebUI is the first). Confirm the script prints the new tag (e.g. `v0.11.0` if the prior release was `v0.10.3`) and that it pushed the tag — it refuses on a dirty tree or a branch other than `main`, so Step 3 must be clean first.

- [ ] **Step 5: Wait for CI to publish the image**

```bash
gh run list --repo thiagomarsal/porquinho --limit 1
gh run watch --repo thiagomarsal/porquinho
```

Expected: the workflow triggered by the new tag completes successfully and pushes `ghcr.io/thiagomarsal/porquinho:<the new vX.Y.Z tag>`.

- [ ] **Step 6: Deploy**

```bash
scripts/deploy.sh
```

Confirm the printed `kubectl context` is `homelab` and the printed `image tag` matches the tag from Step 4 before answering `y`. This runs `helm upgrade` against the `porquinho` release.

- [ ] **Step 7: Verify the pod picked up the new image and the MCP endpoint responds**

```bash
kubectl -n porquinho get deploy porquinho -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n porquinho port-forward svc/porquinho 18080:80 >/tmp/pf.log 2>&1 &
sleep 2
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:18080/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"verify","version":"0"}}}'
kill %1
```

Expected: the image tag matches the new release, and the curl prints `200` (a Streamable HTTP MCP server accepts a POST `initialize` and responds; a `404` means the endpoint path is wrong, a connection refused means the pod didn't restart — re-check Step 6).

---

## Task 2: Deploy Open WebUI's core workload to k3s

**Repo:** `/home/tfarias/homelab`

**Files:**
- Modify: `kubernetes/base/namespaces.yml` (append the `open-webui` namespace, same pattern as the existing `n8n` entry)
- Create: `kubernetes/apps/open-webui/secret.yml`
- Create: `kubernetes/apps/open-webui/configmap.yml`
- Create: `kubernetes/apps/open-webui/pvc.yml`
- Create: `kubernetes/apps/open-webui/deployment.yml`
- Create: `kubernetes/apps/open-webui/service.yml`

**Interfaces:**
- Consumes: nothing from Task 1 yet (that's Task 4's job) — this task stands alone.
- Produces: a `Service` named `open-webui` in namespace `open-webui`, port 80 → container port 8080. Task 3's `IngressRoute` targets this service by name.

- [ ] **Step 1: Register the namespace**

Append to `kubernetes/base/namespaces.yml` (same shape as every other entry in that file, e.g. the `n8n` one):

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: open-webui
```

- [ ] **Step 2: Check what image tag is actually current, and confirm a slim variant exists**

```bash
gh api /orgs/open-webui/packages/container/open-webui/versions --paginate \
  | jq -r '.[].metadata.container.tags[]' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+(-slim)?$' | sort -V | tail -20
```

Pick the newest `vX.Y.Z-slim` tag. Use the plain `vX.Y.Z` tag instead only if no `-slim` variant exists for that version. At the time this plan was written (2026-09-22) the newest release was `v0.11.4`, and Open WebUI's own release notes describe `v0.11.4`'s slim image as the smallest yet — so `v0.11.4-slim` is the expected answer; treat it as a starting guess to confirm, not as gospel, since the image tags outlive this plan.

- [ ] **Step 3: Generate and create the session-signing secret**

Open WebUI signs session cookies with `WEBUI_SECRET_KEY`. Without a fixed value, every pod restart invalidates all logged-in sessions — worth pinning even for a single user, the same way porquinho pins `n8n_encryption_key`-style secrets rather than letting them float.

```bash
openssl rand -hex 32
```

Copy the output, then:

```bash
kubectl create namespace open-webui --dry-run=client -o yaml | kubectl apply -f -
kubectl -n open-webui create secret generic open-webui-secret \
  --from-literal=WEBUI_SECRET_KEY='<paste the value from openssl rand>'
```

Do **not** put the real value in git. Commit this placeholder instead:

`kubernetes/apps/open-webui/secret.yml`:
```yaml
---
# Managed manually, not by this manifest — same convention as
# kubernetes/apps/n8n/secret.yml and porquinho's ghcr-pull/truststore secrets.
# Real value created with:
#   openssl rand -hex 32
#   kubectl -n open-webui create secret generic open-webui-secret \
#     --from-literal=WEBUI_SECRET_KEY='<generated value>'
# Do NOT apply this file. Do NOT commit the real value.
```

- [ ] **Step 4: Write the ConfigMap**

`kubernetes/apps/open-webui/configmap.yml`:
```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: open-webui-config
  namespace: open-webui
data:
  WEBUI_NAME: "Porquinho"
  WEBUI_URL: "https://ai.tmf-solutions.com"
  # Signup stays open until the first (admin) account is created in Task 4 —
  # Open WebUI makes the FIRST registered user an admin automatically. Task 4
  # flips this to "false" once that account exists, since this is meant to
  # be single-user.
  ENABLE_SIGNUP: "true"
```

- [ ] **Step 5: Write the PVC**

`kubernetes/apps/open-webui/pvc.yml`:
```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: open-webui-data
  namespace: open-webui
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 5Gi
```

- [ ] **Step 6: Write the Deployment**

`kubernetes/apps/open-webui/deployment.yml` — use the image tag confirmed in Step 2 in place of `v0.11.4-slim` below if it differs:

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: open-webui
  namespace: open-webui
spec:
  replicas: 1
  selector:
    matchLabels:
      app: open-webui
  strategy:
    type: Recreate  # RWO PVC — same reason as n8n and porquinho
  template:
    metadata:
      labels:
        app: open-webui
    spec:
      containers:
        - name: open-webui
          image: ghcr.io/open-webui/open-webui:v0.11.4-slim
          ports:
            - containerPort: 8080
          envFrom:
            - configMapRef:
                name: open-webui-config
            - secretRef:
                name: open-webui-secret
          volumeMounts:
            - name: data
              mountPath: /app/backend/data
          resources:
            # Slim image, cloud-only (no local embedding/reranking models
            # loaded — see Global Constraints). A 2025 community measurement
            # put bare Open WebUI near 1Gi RSS; this leaves headroom above
            # that without taking memory these 10-12Gi nodes don't have to
            # give, the same sizing discipline porquinho's own values.yaml
            # documents at length.
            requests:
              cpu: 200m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 1536Mi
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 30
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: open-webui-data
```

- [ ] **Step 7: Write the Service**

`kubernetes/apps/open-webui/service.yml`:
```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: open-webui
  namespace: open-webui
spec:
  selector:
    app: open-webui
  ports:
    - port: 80
      targetPort: 8080
```

- [ ] **Step 8: Apply everything and verify the pod comes up**

```bash
cd /home/tfarias/homelab
kubectl apply -f kubernetes/base/namespaces.yml
kubectl apply -f kubernetes/apps/open-webui/configmap.yml
kubectl apply -f kubernetes/apps/open-webui/pvc.yml
kubectl apply -f kubernetes/apps/open-webui/deployment.yml
kubectl apply -f kubernetes/apps/open-webui/service.yml
kubectl -n open-webui get pods -w
```

Expected: `open-webui-<hash>` reaches `1/1 Running` within ~60s (first pull of the image may take longer). If it sits in `CrashLoopBackOff`, check `kubectl -n open-webui logs deploy/open-webui` — a "Permission denied" writing to `/app/backend/data` means the image runs as a non-root UID that doesn't own the fresh Longhorn volume; find it with `kubectl -n open-webui exec deploy/open-webui -- id` and add a matching `spec.template.spec.securityContext.fsGroup` to the Deployment, then re-apply.

- [ ] **Step 9: Verify the UI loads**

```bash
kubectl -n open-webui port-forward svc/open-webui 18081:80 >/tmp/pf-owui.log 2>&1 &
sleep 2
curl -s -o /dev/null -w '%{http_code}\n' localhost:18081/health
kill %1
```

Expected: `200`.

- [ ] **Step 10: Commit**

```bash
cd /home/tfarias/homelab
git add kubernetes/base/namespaces.yml kubernetes/apps/open-webui/
git commit -m "$(cat <<'EOF'
feat: deploy Open WebUI core workload

New namespace, ConfigMap, PVC, Deployment, Service. Not yet exposed
through Traefik (Task 3) or wired to a model/porquinho (Task 4).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Expose Open WebUI through Traefik, LAN-only

**Repo:** `/home/tfarias/homelab`

**Files:**
- Create: `kubernetes/apps/open-webui/middleware.yml`
- Create: `kubernetes/apps/open-webui/ingressroute.yml`

**Interfaces:**
- Consumes: the `open-webui` Service from Task 2 (name `open-webui`, port 80, namespace `open-webui`).
- Produces: `https://ai.tmf-solutions.com` reachable from the LAN and blocked elsewhere.

- [ ] **Step 1: Write the Middleware**

`kubernetes/apps/open-webui/middleware.yml`:
```yaml
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: open-webui-lan-only
  namespace: open-webui
spec:
  ipAllowList:
    sourceRange:
      - 192.168.1.0/24
      - 10.42.0.0/16
```

- [ ] **Step 2: Write the IngressRoute**

`kubernetes/apps/open-webui/ingressroute.yml`:
```yaml
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: open-webui
  namespace: open-webui
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`ai.tmf-solutions.com`)
      kind: Rule
      middlewares:
        - name: open-webui-lan-only
      services:
        - name: open-webui
          port: 80
  tls:
    secretName: wildcard-tmf-solutions-tls
```

- [ ] **Step 3: Apply and verify from the LAN**

```bash
cd /home/tfarias/homelab
kubectl apply -f kubernetes/apps/open-webui/middleware.yml
kubectl apply -f kubernetes/apps/open-webui/ingressroute.yml
curl -s -o /dev/null -w '%{http_code}\n' https://ai.tmf-solutions.com/health
```

Run the `curl` from a machine on `192.168.1.0/24` (this WSL host qualifies if bridged onto the LAN; otherwise run it from any LAN machine). Expected: `200`.

- [ ] **Step 4: Verify the LAN restriction actually blocks non-LAN traffic**

From a network NOT in `192.168.1.0/24` (e.g. phone on mobile data, wifi off) or by temporarily editing `middleware.yml`'s `sourceRange` to a range that excludes your current IP and re-applying to test the negative case, confirm the request is refused (Traefik returns `403` for `ipAllowList` rejections). Revert the temporary edit if you used it.

- [ ] **Step 5: Commit**

```bash
cd /home/tfarias/homelab
git add kubernetes/apps/open-webui/middleware.yml kubernetes/apps/open-webui/ingressroute.yml
git commit -m "$(cat <<'EOF'
feat: expose Open WebUI at ai.tmf-solutions.com, LAN-only

Same ipAllowList ranges as porquinho's own middleware.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Wire Gemini and porquinho's MCP tools, end-to-end validation

**Repo:** none — this task is runtime configuration through Open WebUI's admin UI, plus one ConfigMap follow-up in `/home/tfarias/homelab`. It depends on Task 1 (porquinho's `/mcp` endpoint live) and Task 3 (`https://ai.tmf-solutions.com` reachable).

**Files:**
- Modify: `kubernetes/apps/open-webui/configmap.yml` (flip `ENABLE_SIGNUP` once the admin account exists)

**Interfaces:**
- Consumes: `http://porquinho.porquinho.svc.cluster.local/mcp` (Task 1's output); `https://ai.tmf-solutions.com` (Task 3's output).

- [ ] **Step 1: Create the admin account**

Visit `https://ai.tmf-solutions.com` from a LAN machine, use the sign-up form to create your own account. Open WebUI makes the first registered user an admin automatically — confirm via **Admin → Settings → Users** that your account shows role `admin`.

- [ ] **Step 2: Lock signups**

In `kubernetes/apps/open-webui/configmap.yml`, change `ENABLE_SIGNUP: "true"` to `ENABLE_SIGNUP: "false"`, then:

```bash
cd /home/tfarias/homelab
kubectl apply -f kubernetes/apps/open-webui/configmap.yml
kubectl -n open-webui rollout restart deployment/open-webui
kubectl -n open-webui rollout status deployment/open-webui
```

- [ ] **Step 3: Add the Gemini connection**

In Open WebUI: **Admin → Settings → Connections → Add Connection**. Type: OpenAI-compatible. Base URL: `https://generativelanguage.googleapis.com/v1beta/openai`. API key: your Gemini token. Save, then confirm a model list populates (e.g. `gemini-2.5-flash`, `gemini-2.5-pro` — exact names depend on what your key has access to).

- [ ] **Step 4: Add porquinho as an MCP tool server**

In Open WebUI: **Admin → Settings → External Tools → Add**. Type: MCP (Streamable HTTP). URL: `http://porquinho.porquinho.svc.cluster.local/mcp`. Save. Confirm it connects (Open WebUI shows a green/connected status, or errors if the handshake fails — if it fails, re-run Task 1 Step 7's curl check to isolate whether it's the porquinho endpoint or the Open WebUI side).

- [ ] **Step 5: Enable the tool in a chat and verify grounded retrieval**

Start a new chat, select a Gemini model, enable the porquinho tool server for that chat (Open WebUI's tool-toggle in the chat input), and ask something the corpus should answer, e.g.:

> "O que a Desmistificando disse recentemente sobre a vacância do BTLG11?"

Expected: the chat's tool-call UI shows `searchReports` (or `getThesis`) was invoked, and the reply cites a specific date and URL rather than a generic answer. If no tool call happens, confirm the tool server is enabled for that specific chat (it's a per-chat toggle, not global) and that the selected model supports tool calling.

- [ ] **Step 6: Commit the signup lockdown**

```bash
cd /home/tfarias/homelab
git add kubernetes/apps/open-webui/configmap.yml
git commit -m "$(cat <<'EOF'
chore: lock Open WebUI signups after creating the admin account

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

This closes out the spec: porquinho's corpus is now queryable from a chat UI, reachable only from the LAN, grounded in real citations rather than pretraining.
