# homelab

Infrastructure-as-code for an 8-node Proxmox homelab running k3s HA.

## Cluster Overview

| Node | IP | Role |
|------|----|------|
| k3s-master-1 | 192.168.1.50 | k3s server (bootstrap) |
| k3s-master-2 | 192.168.1.51 | k3s server |
| k3s-master-3 | 192.168.1.52 | k3s server |
| k3s-worker-1 | 192.168.1.53 | k3s agent |
| k3s-worker-2 | 192.168.1.54 | k3s agent |
| k3s-worker-3 | 192.168.1.55 | k3s agent |
| k3s-worker-4 | 192.168.1.56 | k3s agent |
| k3s-worker-5 | 192.168.1.57 | k3s agent |

- **Proxmox**: 8-node cluster (pve01–pve08), all always-on, local storage only — no cluster-wide ZFS pool (see `docs/architecture.md` for per-host hardware)
- **k3s**: v1.34.5+k3s1 — 3-server HA via kube-vip (VIP: 192.168.1.60)
- **Load balancer**: MetalLB (192.168.1.61–199)
- **Domain**: *.tmf-solutions.com
- **Management**: `kubectl` (context `homelab`) — Rancher is pinned in `group_vars/all.yml` and has manifests under `kubernetes/rancher/`, but is **not deployed**: no `cattle-system` namespace exists and rancher.tmf-solutions.com returns 404

## Repository Layout

```
homelab/
├── ansible/
│   ├── ansible.cfg
│   ├── collections/          # requirements.yml (ansible.posix, community.general, kubernetes.core)
│   ├── inventory/            # hosts.yml + group_vars/all.yml
│   ├── playbooks/
│   │   ├── k3s/              # site.yml (full deploy), reset.yml
│   │   ├── infra/            # apt, reboot, timezone, qemu-guest-agent
│   │   └── lxc/              # pihole, immich, nextcloud
│   └── roles/
│       ├── common/           # OS prep for all nodes
│       ├── k3s-server/       # Control plane setup + kube-vip
│       ├── k3s-agent/        # Worker node setup
│       └── rancher/          # MetalLB, Traefik, Rancher deploy
├── kubernetes/
│   ├── base/                 # Namespaces, ZFS StorageClass
│   ├── apps/                 # Per-app manifests (immich, nextcloud, pihole)
│   └── system/               # cert-manager, ingress-nginx, metallb
├── docker/                   # Compose stacks for LXC-hosted services
├── scripts/
│   ├── deploy.sh             # ansible-playbook playbooks/k3s/site.yml
│   ├── reset.sh              # Cluster teardown (with confirmation)
│   └── kubeconfig-fetch.sh   # SCP kubeconfig from master-1
└── docs/
    ├── architecture.md       # Full topology reference
    ├── cluster-setup.md      # Step-by-step cluster guide
    └── runbooks/             # adding-a-node, disaster-recovery
```

## Prerequisites

- Ansible installed locally
- SSH key at `~/.ssh/id_k3s` with access to all nodes
- Vault password at `~/.vault_password`
- Ansible collections: `ansible-galaxy collection install -r ansible/collections/requirements.yml`

## Quick Start

```bash
# Deploy the full cluster
./scripts/deploy.sh

# Fetch kubeconfig after deploy
./scripts/kubeconfig-fetch.sh

# Verify
kubectl get nodes
```

## LXC Services (outside k3s)

| Service | Notes |
|---------|-------|
| Pi-hole | DNS ad-blocking |
| Immich  | Photo management |
| Nextcloud | File sync/share |

## Secrets

Sensitive values (k3s token) are encrypted with `ansible-vault`. The vault password file lives at `~/.vault_password` and is never committed. See `.gitignore`.
