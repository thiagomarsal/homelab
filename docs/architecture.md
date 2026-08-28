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

### Proxmox host hardware (verified live 2026-08-28)

| Host | IP | Chassis | CPU | RAM (max) | Storage | NIC(s) | Guests |
|---|---|---|---|---|---|---|---|
| pve01 | .10 | generic mini-PC | N95, 4C/4T | 12GB soldered (12GB) | 238GB SATA SSD (G537N1) | `nic0` r8169 | k3s-master-1 (110) |
| pve02 | .11 | **Lenovo ThinkCentre M80q** (11DQS0P500) | **i7-10700T, 8C/16T** | 32GB 2×16 DDR4-3200 (**64GB**) | 954GB Samsung NVMe (`local-lvm` 855GB) | `nic0` I219-LM **e1000e** | k3s-master-2 (111), template 9002 |
| pve03 | .12 | **Lenovo ThinkCentre M900 Tiny** (10FM001GUS) | **i7-6700T, 4C/8T** | 16GB 2×8 DDR4-2133 (32GB) | 1TB Samsung 870 EVO (`ssd-storage`) + 238GB SK hynix BC711 NVMe (boot, `local-lvm`) + 466GB ST500LT012 HDD (`usb-backup`) | `eno1` I219-LM **e1000e** → vmbr0; `enp2s0` RTL8125 2.5GbE r8169 → vmbr1 | pfSense (106), k3s-master-3 (112), **pihole (CT101)**, **uptime-kuma (CT102)**, immich (CT100, stopped) |
| pve04 | .13 | Kamrui AK1 Plus | N95, 4C/4T | 8GB, 1 slot (16GB) | 1TB Samsung 870 EVO + 238GB SATA SSD | `nic0` r8169 | k3s-worker-1 (115) |
| pve05 | .14 | HP ProDesk 600 G4 DM (TAA) | i5-8500T, 6C/6T | 16GB 2×8 (32GB) | 954GB Samsung NVMe + 1TB ST1000LM024 HDD (not in any `pvesm` pool) | `eno1` I219-LM **e1000e** | k3s-worker-2 (114) |
| pve06 | .15 | HP ProDesk 600 G4 DM (TAA) | i5-8500T, 6C/6T | 24GB (16+8, flex mode) (32GB) | 238GB Micron SSD | `nic0` I219-LM **e1000e** | k3s-worker-3 (116) |
| pve07 | .16 | HP ProDesk 600 G4 DM (TAA) | i5-8500T, 6C/6T | 32GB 2×16 (32GB) | 238GB Micron SSD | `nic0` I219-LM **e1000e** | k3s-worker-4 (117), template 9007 |
| pve08 | .17 | HP ProDesk 600 G4 DM (TAA) | i5-8500T, 6C/6T | 32GB 2×16 (32GB) | 238GB Micron SSD | `nic0` I219-LM **e1000e** | k3s-worker-5 (118), template 9008 |

Fleet total 172GB RAM. Every slot is occupied, and every board except pve02's
caps at 32GB — pve04 and pve01 are already at their ceilings, and pve03/05/06
can only grow by swapping sticks out. **pve02 is the sole host that can exceed
32GB** (2 slots, 64GB max), which makes it the natural home for anything that
outgrows the rest of the fleet.

All four ProDesks report the TAA product string, so pve05–pve08 are one
identical quad of chassis; only their RAM configs differ. The i5-8500T caps at
2666 MT/s, so the 3200-rated sticks in pve06/07/08 all run at 2667.

#### Guest allocation and storage fill (live 2026-08-28)

| Host | Host RAM | Allocated to guests | `local-lvm` fill | Other pools |
|---|---|---|---|---|
| pve01 | 11.7GB | 9.2GB (VM110) | **70%** of 141GB | — |
| pve02 | 31.8GB | 10GB (VM111) | 1.5% of 816GB | — |
| pve03 | 15.9GB | **13.3GB** (106+112+CT101+CT102) | 3.8% of 141GB | `ssd-storage` 55% of 913GB, `usb-backup` 9% of 457GB |
| pve04 | 7.7GB | 6GB (VM115) | 52% of 141GB | — |
| pve05 | 15.8GB | 12GB (VM114) | 11% of 816GB | 1TB HDD unpooled |
| pve06 | 23.8GB | 12GB (VM116) | 41% of 141GB | — |
| pve07 | 31.9GB | 12GB (VM117) | 29% of 141GB | — |
| pve08 | 31.9GB | 12GB (VM118) | 55% of 141GB | — |

Every guest runs `balloon: 0`, so host-level `free` overstates pressure — judge
by allocation-vs-host-RAM and by `kubectl top nodes`, not by `free` on the
hypervisor. All non-template guests are `onboot: 1` except immich (CT100, which
is stopped deliberately). Every worker VM is 12288MB / 4 cores, which is why
pve06–pve08 have 11–20GB sitting idle: the 32GB upgrades are unused until the VM
allocations are raised.

SMART is `PASSED` on all 13 drives. The oldest are pve04's 870 EVO (11.2k
power-on hours), pve03's ST500LT012 (10.8k) and pve05's Samsung NVMe (10.6k) —
nothing near end of life, but those three are the first to watch.

**Template RAM is inconsistent:** templates 9007/9008 were reduced to 4096MB, but
**9002 on pve02 is still 12288MB**. Any VM cloned from 9002 inherits 12GB, which
is what originally caused the pve04 overcommit. Reduce it or pass `MEMORY=` at
provision time.

**PVE version drift:** pve02 runs 9.2.11 (it shipped newer and was patched to
join), the other seven run 9.2.10. Harmless, but the fleet is no longer uniform.

#### 2026-08-28 disk cleanup

Reclaimed ~76GB with no downtime: 7.0GB of apt caches across all 8 hosts, 10.1GB
of guest journals, 58.9GB from `k3s crictl rmi --prune`, and 242MB of
unreferenced LXC templates on pve01 (`pveam remove`).

`SystemMaxUse=500M` is now pinned via
`/etc/systemd/journald.conf.d/99-homelab-cap.conf` on all 8 hosts **and** all 8
guests — it was unset everywhere, and three guests had grown ~3.9GB journals.
This was applied by hand and is **not yet in Ansible**; the `common` role is the
right home for it.

PVE host journals were deliberately capped but **not** vacuumed — they hold the
`e1000e` NIC-hang history that `runbooks/pve-nic-hang.md` depends on.

**`ssd-storage` now serves pve03 *and* pve04.** It had `nodes pve03`, so pve04's
identical 913GB thin pool reported `disabled` and Proxmox could not use the drive
at all. `pvesm set ssd-storage --nodes pve03,pve04` unlocked **895GB** of
capacity. One storage id works for both because each host has its own VG *and*
thinpool literally named `ssd-storage`. Previous file saved at
`pve03:/root/storage.cfg.bak-20260828`.

**The 58.9GB from the image prune is trapped.** It freed space inside the guest
filesystems, but **no guest disk has `discard=on`**, so nothing returned to the
LVM-thin pools — thin allocation only ever grows. Every worker disk is plain
`scsi0: local-lvm:vm-NNN-disk-0,size=100G`. Until discard is enabled and the
guests are trimmed, pool fill overstates real usage by a wide margin: `vm-110`
sits at 98.9% allocated against 37GB actually used, and `vm-112`/`vm-106` both
report 100%. Enabling it needs a guest restart per node, so it is pending.

**pve04's orphan is gone.** `ssd-storage:vm-104-disk-0` (100GB provisioned,
~18.5GB real) was the decommissioned nextcloudpi LXC, inactive since creation
with zero config references cluster-wide. Freed 2026-08-28, so pve04's pool is
now at **0.00% of 913GB**.

### Longhorn storage health (2026-08-28)

Available capacity went from **305.9GB to 535.4GB** in one pass. Two fixes:

**k3s-master-2 was contributing nothing.** Its Longhorn disk reported
`max=0.0G` with `DiskFilesystemChanged` — the node CR still recorded diskUUID
`674a3d51…` from the *old* master-2 VM, which `qm destroy 111 --purge` destroyed
during the 2026-08-25 host replacement, while the rebuilt filesystem reports
`87cb9cce…`. Longhorn correctly refuses a disk whose UUID it does not recognise.
Fixed by removing the disk from `node.spec.disks` and re-adding it so the record
matches reality; `/var/lib/longhorn/replicas` was empty, so nothing was at risk.
The webhook rejects removal until `allowScheduling: false` is set first. Now
Ready + Schedulable at 98.2G. **Any rebuild-in-place of a node needs this
check** — a silently unschedulable node is easy to miss.

**The Prometheus volume was 1.88× its own spec** — 30.1GiB actual against a
16GiB request, holding only 5.6GiB of live data. The 15.6GiB base snapshot
sitting under it was already `markRemoved: True` and the engine's purge had
completed on all three replicas: a snapshot whose only child is `volume-head`
**cannot** be coalesced away while the volume is attached, so deleting it was
never the fix. The actual mechanism is a filesystem trim — Prometheus rewrites
TSDB blocks constantly and Longhorn never reclaimed the freed ones. A trim took
it to **11.6GiB**, ~18.5GiB per replica × 3 ≈ 55GB of raw disk.

`fstrim` inside the Prometheus container returns `FITRIM: Operation not
permitted` (unprivileged securityContext). Use the Longhorn API instead, from
any manager pod:

```
curl -s -X POST -H "Content-Type: application/json" -d '{}' \
  "http://longhorn-backend:9500/v1/volumes/<volume>?action=trimFilesystem"
```

Trim stops at the snapshot chain unless the volume sets
`unmapMarkSnapChainRemoved: enabled`, because the global
`remove-snapshots-during-filesystem-trim` setting is `false`. That was patched
on the Prometheus volume only.

To stop the drift recurring, `kubernetes/base/storage/longhorn-recurringjob-trim.yml`
adds a weekly `filesystem-trim` RecurringJob against the `default` group, which
every volume here is already labelled into. Note the two pre-existing backup
RecurringJobs (`hoa-nightly-backup`, `porquinho-nightly`) are **not** in the repo
— they exist only in the cluster.

### Keeping the cleanup from recurring (2026-08-28)

Most of what the cleanup recovered is now self-maintaining, so there is
deliberately **no scheduled cleanup job**. Two root causes were fixed instead:

**`apt-get clean` added to the n8n forced-command wrapper.** The `upgrade` branch
of `/usr/local/sbin/n8n-apt-upgrade.sh` ran `update` → `dist-upgrade` →
`autoremove` and never emptied the package cache, so every monthly run left its
downloads behind — that is the whole 7.0GB. It is intentionally best-effort
(`|| logger`), because `set -e` is active in that branch and a failed cache
cleanup must never abort an upgrade or skip the reboot. Verified after deploy:
`bash -n` clean and identical md5 on all 8 hosts, and `healthcheck` returns
`HEALTHY` on all 8 through the restricted key in both the bare form and n8n's
actual `cd / ; healthcheck` form.

**kubelet image GC lowered from the 85 default to 70/55.** This is why 58.9GB of
unused images accumulated: nodes ran at 18–80% nodefs, never crossed the default
threshold, and image GC had therefore *never fired once*. With 70/55 kubelet
prunes continuously. Set in both `k3s-config.yaml.j2` templates.

Age-based pruning (`imageMaximumGCAge`) is deliberately **not** used. The field
exists in the kubeletconfig struct on v1.34.5, but there is no confirmed
`--kubelet-arg` flag form, and an unrecognised kubelet flag prevents a node from
starting — not a risk worth taking across 8 nodes for a marginal gain.

Rollout was staged on purpose: the config file is deployed to all 8 nodes, but
only **k3s-worker-1** was restarted to validate the flags (drain → restart →
`configz` confirms 70/55 → uncordon). The other seven keep the file dormant and
pick it up at the **1 September** reboot, so nothing was disrupted twice. The one
`Image garbage collection failed once … invalid capacity 0 on image filesystem`
line at kubelet startup is the normal cAdvisor warm-up — it occurred exactly once
at the restart instant and never repeated.

The same 1 September reboot cycles every guest, which is what activates the
pending `discard=on`. The guests' `fstrim.timer` is already enabled weekly, so
the thin pools reclaim themselves within 7 days of that reboot with no manual
step. Note this also explains why the pools grew unchecked despite fstrim
running all along: the guests were trimming, and QEMU was silently discarding the
requests because `discard` was unset.

Still not covered by any automation: the monthly report covers **7 of 8 hosts**
(pve08 runs n8n, so upgrading it inside the loop kills the execution before the
email sends), and nothing watches the kuma backup freshness. A post-upgrade
verification workflow scheduled ~1h later would close both.

Every other volume is comfortably under its spec, so Prometheus was the only
pathological one. Three ghost PVCs (kafka, minio, redis) that had been
`Terminating` since 2026-06-07 are also cleared — their namespaces were already
deleted, which is *why* they were stuck: reads succeed against a missing
namespace but every write is rejected, so the finalizer could never be removed.
Recreating each namespace let the controller finish the GC immediately; then the
empty namespaces were deleted again.

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

**pve02 was replaced on 2026-08-25 (complete).** The Kamrui E2 (N150, 4C/4T,
16GB, 238GB M.2 SATA) went to a family member; a Lenovo ThinkCentre M80q
(i7-10700T 8C/16T, 32GB, 954GB NVMe) took its place, reusing the `pve02` name
and `192.168.1.11` so no inventory edits were needed. It is now the strongest
host in the fleet.

The name and IP had to be reused, so old and new could not coexist — the old
host was removed from the cluster *before* the new one joined, which took the
cluster to two etcd members for about 25 minutes. Sequence that worked:

1. `pct migrate` pihole (CT101) and uptime-kuma (CT102) off to pve03
2. drain `k3s-master-2`, `systemctl stop k3s`, `kubectl delete node` — k3s
   removes the etcd member through raft on node delete; confirm this in the
   k3s journal (`Removing etcd member from cluster due to node delete`), because
   a stale member blocks the rebuild later
3. `qm destroy 111 --purge` (also strips the VMID from `jobs.cfg`), power off,
   then `pvecm delnode pve02` from a surviving node
4. **`rm -rf /etc/pve/nodes/pve02`** — `delnode` leaves this behind and it
   blocks re-adding a node under the same name
5. new host: patch to the fleet's PVE version *first*, then set the final IP,
   then `pvecm add`
6. `nic-offload-fix.yml`, provision VM 111 from a node-local template
   (`TEMPLATE_VMID=9002`, `MEMORY=10240`), then
   `site.yml --limit k3s-master-2`

`pvecm add` prompts for a password interactively. To script it, put the new
node's `/root/.ssh/id_rsa.pub` into the cluster's shared
`/etc/pve/priv/authorized_keys` and use `pvecm add <ip> --use_ssh`.

**pihole (CT101) and uptime-kuma (CT102) now live on pve03**, moved there to
free pve02.

> **Known concentration risk, accepted deliberately.** pve03 carries the router
> (pfSense), LAN DNS (pihole), an etcd master, and the monitor that would report
> the outage (uptime-kuma). A single pve03 failure takes routing, DNS and
> alerting at once — and pve03 is on `e1000e` hardware, whose failure mode is a
> host that stays up with a dead NIC. Pi-hole was previously on pve02 precisely
> to keep DNS off Intel NICs, and **the replacement pve02 is also I219-LM**, so
> that option did not come back. The remaining fix is to move pihole to
> **pve04**, now the only Realtek-NIC host left in the fleet.

pve03 is now the second-tightest host in the fleet on RAM: 2048 (pfSense) +
10240 (master-3) + 512 + 512 (the two CTs) = **13.3GB allocated of 15.9GB**,
leaving ~2.6GB for PVE itself against ~1.7GB typical usage. Do not add guests
here without reducing something first.

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
