# Runbook: Adding a Node

All existing nodes (masters + workers) run **Debian 12 (bookworm) cloud-init images**,
not Ubuntu — there's no reusable Proxmox template, each VM is built fresh from the
official genericcloud qcow2.

## Provision the VM (on the target Proxmox host)

1. Pick next free VMID (masters use 110/111/112, workers 113/114 — check `qm list` on
   every reachable pve host first, since on-demand hosts may hide VMs while offline)
2. Pick next free static IP (masters .50-.52, workers .53+)
3. Download the image and create the VM:
   ```bash
   wget -q https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2 -O /tmp/debian-12-generic.qcow2

   qm create <vmid> \
     --name <hostname> \
     --memory <MB> --balloon 0 --cores <n> --sockets 1 --numa 0 --cpu host \
     --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-pci \
     --agent enabled=1 --serial0 socket --vga serial0 --onboot 1

   qm importdisk <vmid> /tmp/debian-12-generic.qcow2 local-lvm
   qm set <vmid> --scsi0 local-lvm:vm-<vmid>-disk-0
   qm set <vmid> --boot order=scsi0
   qm set <vmid> --ide2 local-lvm:cloudinit
   qm set <vmid> --ciuser tfarias --sshkeys <pubkey-file> \
     --ipconfig0 ip=192.168.1.<x>/24,gw=192.168.1.1 --nameserver 192.168.1.5
   qm resize <vmid> scsi0 100G

   rm -f /tmp/debian-12-generic.qcow2
   qm start <vmid>
   ```
4. Wait for cloud-init, confirm SSH: `ssh tfarias@192.168.1.<x> hostname`

## Add a k3s Agent

1. Provision the VM (above)
2. Add the node to `ansible/inventory/hosts.yml` under `agents:` (add `k3s_node_taints`
   too if it should be on-demand/tainted, like k3s-worker-1)
3. If it's a new pve host, also add it under `pve:` and to `pve_nodes` in
   `group_vars/all.yml` so pve-exporter picks it up
4. Run: `ansible-playbook playbooks/k3s/site.yml --limit <new-node-hostname>`
   (runs the `common` prep role + `k3s-agent` join; master phases are skipped
   automatically since they're not in the `--limit` scope)
5. Verify: `kubectl get nodes` (confirm you're on the homelab context first)

## Add a k3s Server (control plane expansion)

> Note: k3s HA requires an odd number of servers (3, 5, ...).

1. Provision the VM (above)
2. Add to `ansible/inventory/hosts.yml` under `servers:`
3. Run: `ansible-playbook playbooks/k3s/site.yml --limit <new-node-hostname>`
4. Verify etcd membership: `kubectl get nodes -o wide`
