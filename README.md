# homelab

Infrastructure-as-code for a 4-node Proxmox homelab running k3s HA with Rancher.

## Cluster Overview

| Node | IP | Role |
|------|----|------|
| k3s-master-1 | 192.168.1.50 | k3s server (bootstrap) |
| k3s-master-2 | 192.168.1.51 | k3s server |
| k3s-master-3 | 192.168.1.52 | k3s server |
| k3s-worker-1 | 192.168.1.53 | k3s agent (on-demand) |

- **Proxmox**: 4-node cluster (pve01–pve04), ZFS raidz2 on pve04
- **k3s**: v1.34.5+k3s1 — 3-server HA via kube-vip (VIP: 192.168.1.60)
- **Load balancer**: MetalLB (192.168.1.61–199)
- **Domain**: *.tmf-solutions.com
- **Management**: Rancher at rancher.tmf-solutions.com

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
