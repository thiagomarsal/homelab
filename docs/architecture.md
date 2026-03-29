# Homelab Architecture

## Infrastructure Overview

| Node | IP | Role | Host |
|------|----|------|------|
| k3s-master-1 | 192.168.1.50 | k3s server (bootstrap) | Proxmox VM |
| k3s-master-2 | 192.168.1.51 | k3s server | Proxmox VM |
| k3s-master-3 | 192.168.1.52 | k3s server | Proxmox VM |
| k3s-worker-1 | 192.168.1.53 | k3s agent (on-demand) | Proxmox VM |

- **Proxmox cluster**: 4-node (pve01–pve04)
- **Storage**: ZFS raidz2 on pve04
- **k3s version**: v1.34.5+k3s1
- **HA VIP**: 192.168.1.60 (kube-vip v0.8.7)
- **Load Balancer pool**: 192.168.1.61–199 (MetalLB v0.14.9)
- **Domain**: *.tmf-solutions.com
- **Rancher**: rancher.tmf-solutions.com

## LXC Services (outside k3s)

| Service | Host | Notes |
|---------|------|-------|
| Pi-hole | Proxmox LXC | DNS ad-blocking |
| Immich | Proxmox LXC | Photo management |
| Nextcloud | Proxmox LXC | File sync/share |

## Repository Layout

```
homelab/
├── ansible/      # Cluster provisioning (k3s, infra, LXC)
├── kubernetes/   # In-cluster manifests (apps, system)
├── docker/       # Compose stacks (LXC service reference)
├── scripts/      # deploy.sh, reset.sh, kubeconfig-fetch.sh
└── docs/         # Architecture, runbooks, guides
```
