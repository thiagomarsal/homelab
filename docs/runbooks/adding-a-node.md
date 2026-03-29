# Runbook: Adding a Node

## Add a k3s Agent

1. Provision a new Proxmox VM with Ubuntu 22.04
2. Add the node to `ansible/inventory/hosts.yml` under `agents:`
3. Run: `./scripts/deploy.sh --limit <new-node-hostname> --tags k3s-agent`
4. Verify: `kubectl get nodes`

## Add a k3s Server (control plane expansion)

> Note: k3s HA requires an odd number of servers (3, 5, ...).

1. Provision new Proxmox VM
2. Add to `ansible/inventory/hosts.yml` under `servers:`
3. Run: `./scripts/deploy.sh --limit <new-node-hostname>`
4. Verify etcd membership: `kubectl get nodes -o wide`
