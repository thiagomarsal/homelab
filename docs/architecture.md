# Homelab Architecture

## Infrastructure Overview

_Verified live against the cluster and `helm list -A` on 2026-08-18._

| Node | IP | Role | Host |
|------|----|------|------|
| k3s-master-1 | 192.168.1.50 | k3s server (bootstrap) | Proxmox VM (Debian 12) |
| k3s-master-2 | 192.168.1.51 | k3s server | Proxmox VM (Debian 12) |
| k3s-master-3 | 192.168.1.52 | k3s server | Proxmox VM (Debian 12) |
| k3s-worker-1 | 192.168.1.53 | k3s agent (always-on) | Proxmox VM (Debian 12 cloud-init) |
| k3s-worker-2 | 192.168.1.54 | k3s agent (always-on) | Proxmox VM (Debian 12 cloud-init) |
| k3s-worker-3 | 192.168.1.55 | k3s agent (always-on) | Proxmox VM (Debian 12 cloud-init) |
| k3s-worker-4 | 192.168.1.56 | k3s agent (always-on) | Proxmox VM (Debian 12 cloud-init), pve07 |
| k3s-worker-5 | 192.168.1.57 | k3s agent (always-on) | Proxmox VM (Debian 12 cloud-init), pve08 |

- **Proxmox cluster**: 8-node (pve01–pve08, 192.168.1.10–17), all always-on, zero on-demand nodes
- **Storage**: no cluster-wide ZFS pool — Longhorn (in-cluster) is the shared storage layer; each pve host uses local SATA/NVMe/lvmthin storage only
- **k3s version**: v1.34.5+k3s1 (Debian 12 bookworm, kernel 6.1.0-52, containerd 2.1.5-k3s1)
- **HA VIP**: 192.168.1.60 (kube-vip v0.8.7 — note: `group_vars/all.yml` pins `kubevip_version: v0.9.1`, live pods still run v0.8.7, so a fresh node-add would drift from the fleet until this is reconciled)
- **Load Balancer pool**: 192.168.1.61–199 (MetalLB v0.14.9)
- **Domain**: *.tmf-solutions.com
- **DNS**: Cloudflare (external) + Pi-hole (internal)
- **Router**: pfSense 192.168.1.1 (VM on pve03) — port forwards 80/443 → Traefik MetalLB IP

### Proxmox host hardware (verified live 2026-08-24)

| Host | IP | Chassis | CPU | RAM (max) | Storage | NIC(s) | Guests |
|---|---|---|---|---|---|---|---|
| pve01 | .10 | generic mini-PC | N95, 4C/4T | 12GB soldered (12GB) | 238GB SATA SSD | `nic0` r8169 | k3s-master-1 (110) |
| pve02 | .11 | generic mini-PC | N150, 4C/4T | 16GB, 1 slot (32GB) | 238GB SATA SSD | `enp1s0` r8169 | k3s-master-2 (111), pihole (CT101) |
| pve03 | .12 | **Lenovo ThinkCentre M900 Tiny** (10FM001GUS) | **i7-6700T, 4C/8T** | 16GB 2×8 DDR4-2133 (32GB) | 1TB Samsung 870 EVO (`ssd-storage`) + 238GB SK hynix BC711 NVMe (boot, `local-lvm`) + 466GB ST500LT012 HDD (`usb-backup`) | `eno1` I219-LM **e1000e** → vmbr0; `enp2s0` RTL8125 2.5GbE r8169 → vmbr1 | pfSense (106), k3s-master-3 (112), immich (CT100, stopped) |
| pve04 | .13 | Kamrui AK1 Plus | N95, 4C/4T | 8GB, 1 slot (16GB) | 1TB Samsung 870 EVO + 238GB SATA SSD | `nic0` r8169 | k3s-worker-1 (115) |
| pve05 | .14 | HP ProDesk 600 G4 DM | i5-8500T, 6C/6T | 16GB 2×8 (32GB) | 954GB Samsung NVMe + 1TB ST1000LM024 HDD (not in any `pvesm` pool) | `eno1` I219-LM **e1000e** | k3s-worker-2 (114) |
| pve06 | .15 | HP ProDesk 600 G4 DM | i5-8500T, 6C/6T | 24GB (16+8, flex mode) (32GB) | 238GB Micron SSD | `nic0` I219-LM **e1000e** | k3s-worker-3 (116) |
| pve07 | .16 | HP ProDesk 600 G4 DM (TAA) | i5-8500T, 6C/6T | 32GB 2×16 (32GB) | 238GB Micron SSD | `nic0` I219-LM **e1000e** | k3s-worker-4 (117), uptime-kuma (CT102), template 9007 |
| pve08 | .17 | HP ProDesk 600 G4 DM (TAA) | i5-8500T, 6C/6T | 32GB 2×16 (32GB) | 238GB Micron SSD | `nic0` I219-LM **e1000e** | k3s-worker-5 (118), template 9008 |

Fleet total 156GB RAM. Every slot is occupied — pve04 and pve01 are at their
board ceilings, so the only way up on pve02/03/05/06 is swapping sticks out.

**pve03 was re-hosted on 2026-08-24**: the HP EliteDesk 800 G2 DM (i5-6500T,
4C/4T) was replaced by a ThinkCentre M900 Tiny. The disks and the two DIMMs
moved across, so the PVE install, hostname, corosync identity and all guests
carried over untouched — it is the same node with faster silicon (4C/8T instead
of 4C/4T). The `eno1` MAC changed with the chassis, which is harmless here since
the host is statically addressed.

The 466GB ST500LT012 backing `/mnt/usb-backup` was left out of the first
reassembly and reconnected the same day. Note that it is hot-plug-fragile:
`/etc/fstab` mounts it by UUID with `nofail`, so a host that boots without the
disk attached comes up clean but leaves `/mnt/usb-backup` an empty directory on
the root disk, and `pvesm status` reports the storage `inactive`. Reattaching
after boot does **not** auto-mount it — run `mount /mnt/usb-backup`.

The M900 Tiny still uses an Intel I219-LM, so pve03 remains exposed to the
`e1000e` errata — see `runbooks/pve-nic-hang.md`.

### Core component versions (helm/live, 2026-08-18)

| Component | Version | Notes |
|---|---|---|
| Traefik | v3.6.11 (chart 39.0.6) | k3s-bundled, HelmChartConfig-customized |
| cert-manager | v1.16.3 | matches `group_vars/all.yml` pin |
| MetalLB | v0.14.9 | matches pin |
| Longhorn | v1.11.1 (chart 108.3.0) | **pin in `group_vars/all.yml` says v1.7.2 — stale, deployed release is newer** |
| kube-vip | v0.8.7 | **pin says v0.9.1 — stale in the other direction, live is older** |
| kube-prometheus-stack | chart 83.7.0 / operator v0.90.1 | matches pin (deliberately hand-tracked, see comment in `group_vars/all.yml`) |
| Loki | 3.6.7 | |
| Promtail | 3.5.1 (chart 6.17.1) | matches pin |
| pve-exporter | 3.5.1 | matches pin |
| Rancher | pin says 2.13.3 | not verified live in this pass |

**Action item:** reconcile `kubevip_version` and `longhorn_version` in `ansible/inventory/group_vars/all.yml` with what's actually deployed, so a re-run doesn't silently attempt to change either component's version.

---

## Ingress & TLS

All traffic (internal and external) flows through a single Traefik instance (k3s built-in):

```
Internet
  └── pfSense 192.168.1.1 (port forward 80/443)
        └── MetalLB → Traefik (k3s)
              ├── n8n.tmf-solutions.com          → n8n Pod (k3s)
              ├── drive.tmf-solutions.com        → Nextcloud Pod (k3s)
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
- `numberOfReplicas: 3` — one replica per master node; volumes survive losing any single node with zero data loss
- Recovery strategy: Longhorn replica reattachment (automatic) + Proxmox VM-level snapshots/backups as a second layer

---

## In-cluster Services

| Service | Type | Storage | Endpoint |
|---------|------|---------|----------|
| n8n | Deployment (n8nio/n8n:1.88.0) | Longhorn PVC 5Gi (SQLite) | n8n.tmf-solutions.com |
| Nextcloud | Deployment (32.0.1-apache) + mariadb:10.11 + redis:7 | Longhorn PVCs (3 replicas) | **drive**.tmf-solutions.com |
| HOA WordPress | Deployment (wordpress:6.7.2-apache) + mariadb:11.4 | Longhorn PVCs (3 replicas) | auburn-fields.com |
| porquinho | Deployment + postgres:pg17 (pgvector) StatefulSet | Longhorn | *deployed via Helm from local-built images; **not tracked in this repo** — no manifests under `kubernetes/apps/`* |
| cloudflare-ddns | CronJob (*/5 min) | None | — |
| Rancher | Helm (via Ansible) | — | rancher.tmf-solutions.com |
| cert-manager | Helm | — | — |
| Longhorn | DaemonSet | — | — |

**Manifests present in `kubernetes/apps/` but not deployed** (no live namespace, no helm release): `jenkins/`, `kafka/`, `redis/` — either planned-but-not-applied or dead, pending triage.

---

## LXC Services (Proxmox — proxied via Traefik)

| Service | LXC IP | Endpoint | Notes |
|---------|--------|---------|-------|
| Immich | 192.168.1.20 | immich.tmf-solutions.com | Photo management |
| Pi-hole | Proxmox LXC | — | Internal DNS, not proxied |

Nextcloud was migrated from an LXC (192.168.1.21) to an in-cluster Deployment;
that LXC (pve02, CT104) was decommissioned 2026-07-18.

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
