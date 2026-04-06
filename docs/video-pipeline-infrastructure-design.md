# Video Pipeline Infrastructure — Design Spec

**Date:** 2026-04-03
**Scope:** Phases 1 and 2 — Kafka (Strimzi), Redis, MinIO

---

## Context

Distributed video processing pipeline on k3s homelab. This spec covers the
infrastructure foundation (message broker, cache, object storage) required before
any application components are built.

Full pipeline architecture (for reference):
> Upload API → Kafka → Frame Splitter → Kafka (frames) → ML Workers → Kafka (results) → Aggregator → Dashboard

This spec delivers only the infrastructure layer. Application components are
separate specs.

---

## Goals

- Deploy Kafka, Redis, and MinIO on the on-demand pve04 node (k3s-agent-1)
- All components managed as Helm releases with values files in the repo
- Deploy and teardown via Ansible playbooks; manual `kubectl`/`helm` also supported
- Designed as a prototype today, with commented production migration path in each values file
- Data on ZFS survives teardown cycles — no data loss on redeploy

---

## Non-Goals

- Application components (Upload API, Frame Splitter, ML Workers, Aggregator, Dashboard)
- Kafka topic creation (handled by application deployment)
- GPU configuration on pve04
- Production-grade Kafka replication (deferred — see production notes in values files)
- Proxmox automation for pve04 power on/off (handled manually)

---

## Infrastructure Overview

**Cluster:** k3s HA — 3 always-on masters (pve01–03, mini PCs), 1 on-demand worker (pve04, Dell enterprise server)

**On-demand node:** `k3s-agent-1` — 56 cores, 504G RAM, ZFS raidz2 6.1TB

- Consumes high electricity — powered on only when processing videos
- All video pipeline pods run exclusively on this node

**Existing cluster services** (unaffected, always-on on masters):

- Traefik ingress at `192.168.1.61`
- Monitoring stack (Prometheus, Grafana, Loki)
- Longhorn storage (SSDs on mini PCs, no replication)
- n8n, Nextcloud, Immich, Pi-hole

---

## Repository Structure

```text
kubernetes/
  apps/
    kafka/
      namespace.yaml         ← kafka namespace
      values.yaml            ← Strimzi operator Helm values
      kafka-cluster.yaml     ← KafkaCluster CR (Strimzi CRD)
    redis/
      namespace.yaml         ← redis namespace
      values.yaml            ← Bitnami Redis Helm values
  storage/
    minio/
      namespace.yaml         ← minio namespace
      values.yaml            ← MinIO Helm values
      pv.yaml                ← Local PersistentVolume → ZFS path on pve04

ansible/
  playbooks/
    video-pipeline/
      deploy.yml             ← deploy all components in order
      teardown.yml           ← teardown all components in reverse order
```

---

## Namespaces

| Namespace | Components | Rationale |
| --- | --- | --- |
| `kafka` | Strimzi operator + KafkaCluster | Isolated — Kafka may serve other apps in future |
| `redis` | Redis | Isolated — may run permanently in future |
| `minio` | MinIO | Storage concern, separate from app namespaces |

---

## Component Design

### Common: pve04 Node Pinning

All components share these constraints while running as on-demand prototype:

```yaml
# PROTOTYPE: pin to pve04. Remove nodeSelector for production (allow scheduler to place freely).
nodeSelector:
  kubernetes.io/hostname: k3s-agent-1

# Required: pve04 carries on-demand=true:NoSchedule taint
tolerations:
  - key: on-demand
    operator: Equal
    value: "true"
    effect: NoSchedule
```

---

### Kafka (Strimzi)

**Helm chart:** `strimzi/strimzi-kafka-operator`
**Namespace:** `kafka`

**Operator configuration (`values.yaml`):**

- Pinned to pve04 (nodeSelector + toleration)
- Watches only `kafka` namespace
- `# PROTOTYPE: watchNamespaces: [kafka]. Expand for production if Kafka serves other namespaces.`

**KafkaCluster CR (`kafka-cluster.yaml`):**

- KRaft mode — no ZooKeeper
- 1 combined broker+controller node
- Storage: Longhorn PVC, 20Gi, `numberOfReplicas: 1`
- `# PROTOTYPE: replicas: 1, storage 20Gi. Production: replicas: 3, remove nodeSelector, increase storage.`
- `# PROTOTYPE: combined broker+controller role. Production: split into dedicated broker and controller nodes.`

**Bootstrap address (internal):** `kafka-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092`

---

### Redis

**Helm chart:** `bitnami/redis`
**Namespace:** `redis`

**Configuration (`values.yaml`):**

- Architecture: standalone (single master, no replicas)
- Auth: enabled — password stored in Kubernetes Secret
- Storage: Longhorn PVC, 2Gi, `numberOfReplicas: 1`
- Pinned to pve04 (nodeSelector + toleration)
- `# PROTOTYPE: architecture: standalone. Production: architecture: replication, remove nodeSelector.`
- `# PROTOTYPE: Longhorn PVC with 1 replica. Production: increase Longhorn replicas or use dedicated SSD.`

**Internal endpoint:** `redis-master.redis.svc.cluster.local:6379`

---

### MinIO

**Helm chart:** `minio/minio`
**Namespace:** `minio`

**Configuration (`values.yaml`):**

- Mode: standalone (single instance)
- Storage: Local PersistentVolume → `/mnt/storage/minio` on pve04 ZFS raidz2 pool
- PVC size: 100Gi initial (ZFS pool is 6.1TB — expandable)
- Pinned to pve04 (nodeSelector + toleration)
- Console exposed via Traefik ingress: `minio.tmf-solutions.com`
- `# PROTOTYPE: standalone mode, local PV. Production: distributed mode (4+ nodes), dedicated storage class.`
- `# PROTOTYPE: 100Gi claim. Expand as needed — ZFS pool supports up to ~6TB.`

**Internal S3 endpoint:** `minio.minio.svc.cluster.local:9000`
**Console:** `https://minio.tmf-solutions.com`

**PersistentVolume (`pv.yaml`):**

- Type: `local`
- Host path: `/mnt/storage/minio` (ZFS dataset on pve04)
- `nodeAffinity` to `k3s-agent-1` (required for local PV)
- StorageClass: `local-storage` (manually provisioned, no dynamic provisioning)

> **Important:** The ZFS directory is NOT deleted on teardown. Data persists across deploy/teardown cycles.

---

## Ansible Playbooks

### Shared Variables (`ansible/inventory/group_vars/all.yml`)

```yaml
video_pipeline:
  kubeconfig: "~/.kube/config"
  context: "homelab"
  strimzi_version: "0.45.0"
  kafka_version: "3.9.0"
  redis_chart_version: "20.x"
  minio_chart_version: "5.x"
  zfs_minio_path: "/mnt/storage/minio"
```

### `deploy.yml` — Sequence

1. Add Helm repos (Strimzi, Bitnami, MinIO) — idempotent, skips if already present
2. Create namespaces: `kafka`, `redis`, `minio`
3. Helm install Strimzi operator → wait until operator pod is `Running`
4. Apply `kafka-cluster.yaml` → wait until Kafka broker status is `Ready`
5. Apply MinIO `pv.yaml` (PersistentVolume)
6. Helm install Redis → wait until pod is `Running`
7. Helm install MinIO → wait until pod is `Running`
8. Print deployment summary: internal endpoints + MinIO console URL

### `teardown.yml` — Sequence (reverse order)

1. Helm uninstall MinIO
2. Helm uninstall Redis
3. Delete KafkaCluster CR → wait until Kafka pods fully terminate
4. Helm uninstall Strimzi operator
5. Delete MinIO PersistentVolume
6. Delete namespaces (`minio`, `redis`, `kafka`) → wait for full termination
7. Print teardown confirmation

> **Note:** Teardown does not touch the ZFS directory on pve04. Run `teardown.yml` safely — data is preserved.

---

## Production Migration Notes

When the video pipeline becomes permanent and production-ready, the following
changes are required per component. Each is marked with a `# PROTOTYPE:` comment
in the relevant values file.

| Component | Change |
| --- | --- |
| All | Remove `nodeSelector` + keep toleration only if taint still applies |
| Kafka | `replicas: 3`, dedicated broker and controller nodes, move to always-on masters |
| Kafka | Split combined broker+controller into separate node pools |
| Redis | `architecture: replication`, add replicas, move to always-on masters |
| MinIO | Switch to distributed mode (4+ nodes), dedicated storage class |
| Ansible | Add `values.prod.yaml` per component (Option B) if complexity warrants it |

---

## Success Criteria

- `deploy.yml` runs end-to-end without errors on a freshly joined pve04 node
- Kafka broker is reachable at bootstrap address from within the cluster
- Redis is reachable at its internal endpoint with password auth
- MinIO S3 API is reachable at internal endpoint; console accessible at `minio.tmf-solutions.com`
- `teardown.yml` cleanly removes all components and namespaces
- Re-running `deploy.yml` after teardown succeeds (idempotent)
- ZFS data directory survives a full teardown/redeploy cycle
