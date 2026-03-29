# Runbook: Disaster Recovery

## Full Cluster Reset and Redeploy

1. Run reset: `./scripts/reset.sh`
2. Redeploy: `./scripts/deploy.sh`
3. Fetch kubeconfig: `./scripts/kubeconfig-fetch.sh`

## Restore from etcd Snapshot

k3s snapshots are stored on servers at `/var/lib/rancher/k3s/server/db/snapshots/`.

```bash
# Stop k3s on all servers
ansible all -m systemd -a "name=k3s state=stopped"

# Restore on bootstrap node
k3s server --cluster-reset --cluster-reset-restore-path=<snapshot-path>

# Restart cluster
ansible all -m systemd -a "name=k3s state=started"
```

## kubeconfig Lost/Expired

```bash
./scripts/kubeconfig-fetch.sh
```
