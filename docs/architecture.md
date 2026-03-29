# Homelab Architecture

## Infrastructure Overview

| Node | IP | Role | Host |
|------|----|------|------|
| k3s-master-1 | 192.168.1.50 | k3s server (bootstrap) | Proxmox VM |
| k3s-master-2 | 192.168.1.51 | k3s server | Proxmox VM |
| k3s-master-3 | 192.168.1.52 | k3s server | Proxmox VM |
| k3s-worker-1 | 192.168.1.53 | k3s agent (on-demand) | Proxmox VM |

- **Proxmox cluster**: 4-node (pve01–pve04), pve04 is on-demand
- **Storage**: ZFS raidz2 on pve04
- **k3s version**: v1.34.5+k3s1
- **HA VIP**: 192.168.1.60 (kube-vip v0.8.7)
- **Load Balancer pool**: 192.168.1.61–199 (MetalLB v0.14.9)
- **Domain**: *.tmf-solutions.com
- **DNS**: Cloudflare (external) + Pi-hole (internal)
- **Router**: pfSense 192.168.1.1 — port forwards 80/443 → Traefik MetalLB IP

---

## Ingress & TLS

All traffic (internal and external) flows through a single Traefik instance (k3s built-in):

```
Internet
  └── pfSense 192.168.1.1 (port forward 80/443)
        └── MetalLB → Traefik (k3s)
              ├── n8n.tmf-solutions.com          → n8n Pod (k3s)
              ├── nextcloud.tmf-solutions.com    → Nextcloud LXC 192.168.1.21
              ├── immich.tmf-solutions.com       → Immich LXC 192.168.1.20
              ├── rancher.tmf-solutions.com      → Rancher (k3s)
              └── traefik.tmf-solutions.com      → Traefik dashboard (k3s)
```

- **TLS**: cert-manager with Cloudflare DNS-01 → wildcard cert `*.tmf-solutions.com`
- **HTTP→HTTPS**: Global redirect via Traefik entrypoint config
- **LXC proxying**: Headless `Service` + `Endpoints` objects pointing to LXC IPs
- **NPM**: Decommissioned — replaced by Traefik

---

## Storage

- **Longhorn** (default StorageClass) — distributed block storage running inside k3s
- `numberOfReplicas: 1` — no replication, data is non-critical
- Independent of pve04 (on-demand) — data lives on master node disks
- Recovery strategy: Proxmox VM-level snapshots/backups

---

## In-cluster Services

| Service | Type | Storage | Endpoint |
|---------|------|---------|----------|
| n8n | Deployment | Longhorn PVC 5Gi (SQLite) | n8n.tmf-solutions.com |
| cloudflare-ddns | CronJob (*/5 min) | None | — |
| Rancher | Helm (via Ansible) | — | rancher.tmf-solutions.com |
| cert-manager | Helm | — | — |
| Longhorn | DaemonSet | — | — |

---

## LXC Services (Proxmox — proxied via Traefik)

| Service | LXC IP | Endpoint | Notes |
|---------|--------|---------|-------|
| Nextcloud | 192.168.1.21 | nextcloud.tmf-solutions.com | File sync/share |
| Immich | 192.168.1.20 | immich.tmf-solutions.com | Photo management |
| Pi-hole | Proxmox LXC | — | Internal DNS, not proxied |

---

## Secrets Strategy

Secrets are never committed to git. Applied manually via `kubectl apply`:

| Secret | Namespace | Contents |
|--------|-----------|----------|
| `cloudflare-api-token` | `cert-manager` | Cloudflare API token (DNS-01 + DDNS) |
| `cloudflare-api-token` | `cloudflare-ddns` | Same token (separate namespace) |
| `n8n-secret` | `n8n` | `N8N_ENCRYPTION_KEY` |

Secret YAML files are committed with placeholder values and a comment to fill manually.

---

## Repository Layout

```
homelab/
├── ansible/      # Cluster provisioning (k3s, infra, LXC)
├── kubernetes/   # In-cluster manifests (apps, system)
├── docker/       # Compose stacks (LXC service reference)
├── scripts/      # deploy.sh, reset.sh, kubeconfig-fetch.sh
└── docs/         # Architecture, cluster guide, runbooks
```
