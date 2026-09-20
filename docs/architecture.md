# Homelab Architecture

## Infrastructure Overview

_Verified live against the cluster and `helm list -A` on 2026-08-18; node table and
fleet size updated 2026-09-18 after decommissioning pve01 and pve04; full
per-host hardware inventory (CPU/RAM/storage detail) and fleet health refreshed
2026-09-20._

| Node | IP | Role | Host |
|------|----|------|------|
| k3s-master-2 | 192.168.1.51 | k3s server (bootstrap) | Proxmox VM (Debian 12), pve02 |
| k3s-master-3 | 192.168.1.52 | k3s server | Proxmox VM (Debian 12), pve03 |
| k3s-worker-2 | 192.168.1.54 | k3s agent (always-on) | Proxmox VM (Debian 12 cloud-init), pve05 |
| k3s-worker-3 | 192.168.1.55 | k3s server (promoted 2026-09-18) | Proxmox VM (Debian 12 cloud-init), pve06 |
| k3s-worker-4 | 192.168.1.56 | k3s agent (always-on) | Proxmox VM (Debian 12 cloud-init), pve07 |
| k3s-worker-5 | 192.168.1.57 | k3s agent (always-on) | Proxmox VM (Debian 12 cloud-init), pve08 |

**k3s-master-1 (pve01) and k3s-worker-1 (pve04) were decommissioned 2026-09-18.**
pve01 held an etcd member; before removing it, k3s-worker-3 (pve06) was drained,
had its k3s-agent uninstalled, and rejoined as a k3s server to keep etcd at 3
members throughout (never dropped below 3). pve04 was a plain worker with no
etcd role, so it was a straightforward drain + remove. Both PVE hosts had their
Longhorn replicas evicted and workloads (`hoa/mariadb`, `hoa/wordpress`,
`traefik`, `n8n`, `porquinho-postgres`) verified rescheduled and healthy before
any uninstall. See `ansible/inventory/hosts.yml` — `k3s_init: true` (the
bootstrap flag, only used for a from-scratch disaster-recovery rebuild) moved
from k3s-master-1 to k3s-master-2.

- **Proxmox cluster**: 6-node (pve02, pve03, pve05, pve06, pve07, pve08 — 192.168.1.11–17, excluding .13), all always-on, zero on-demand nodes
- **Storage**: no cluster-wide ZFS pool — Longhorn (in-cluster) is the shared storage layer; each pve host uses local SATA/NVMe/lvmthin storage only
- **k3s version**: v1.34.5+k3s1 (Debian 12 bookworm, kernel 6.1.0-52, containerd 2.1.5-k3s1)
- **HA VIP**: 192.168.1.60 (kube-vip v0.8.7 — note: `group_vars/all.yml` pins `kubevip_version: v0.9.1`, live pods still run v0.8.7, so a fresh node-add would drift from the fleet until this is reconciled)
- **Load Balancer pool**: 192.168.1.61–199 (MetalLB v0.14.9)
- **Domain**: *.tmf-solutions.com
- **DNS**: Cloudflare (external) + Pi-hole (internal)
- **Router**: pfSense 192.168.1.1 (VM on pve03) — port forwards 80/443 → Traefik MetalLB IP

### Proxmox host hardware (verified live 2026-09-20 via direct SSH to all 6 hosts; RAM previously updated 2026-09-11; pve01/pve04 decommissioned 2026-09-18)

| Host | IP | Chassis | Baseboard | CPU | RAM (installed/max) | Storage (summary) | NIC(s) | Guests |
|---|---|---|---|---|---|---|---|---|
| pve02 | .11 | **Lenovo ThinkCentre M80q** (11DQS0P500, SN MJ0E003Z) | Lenovo 316C | **i7-10700T, 8C/16T**, 2.0GHz base / 4.5GHz max | 32GB 2×16GB DDR4-3200 (**64GB max, 2 slots**) | 954GB Samsung NVMe SSD (`local-lvm` 855GB) | `nic0` I219-LM **e1000e** | k3s-master-2 (111), template 9002 |
| pve03 | .12 | **Lenovo ThinkCentre M900 Tiny** (10FM001GUS, SN MJ03Z0M7) | Lenovo 30D0 | **i7-6700T, 4C/8T**, 2.8GHz base / 4.2GHz max | 32GB 2×16GB DDR4-2133 (**32GB ceiling**), mixed brand, 1Rx8 | 238GB SK hynix NVMe SSD (boot, `local-lvm`) + 1TB Samsung 870 EVO SATA SSD (`ssd-storage`) + 466GB Seagate ST500LT012 USB HDD (`usb-backup`) | `eno1` I219-LM **e1000e** → vmbr0; `enp2s0` RTL8125 2.5GbE r8169 → vmbr1 | pfSense (106), k3s-master-3 (112), **pihole (CT101)**, **uptime-kuma (CT102)**, immich (CT100, stopped) |
| pve05 | .14 | HP ProDesk 600 G4 DM (TAA, SN MXL9231VXM) | HP 83EF | i5-8500T, 6C/6T (no HT), 2.1GHz base / 3.5GHz max | 32GB 2×16GB DDR4-2667 (**32GB ceiling**), mixed brand, 2Rx8 | 954GB Samsung NVMe SSD (`local-lvm`) + **1TB Seagate ST1000LM024 SATA HDD, unpooled/idle** | `eno1` I219-LM **e1000e** | k3s-worker-2 (114) |
| pve06 | .15 | HP ProDesk 600 G4 DM (TAA, SN MXL92854JV) | HP 83EF | i5-8500T, 6C/6T (no HT), 2.1GHz base / 3.5GHz max | 24GB (16+8, asymmetric, mixed brand) (**32GB ceiling, 1 slot free-ish**) | 238GB Micron SATA SSD | `nic0` I219-LM **e1000e** | k3s-worker-3 (116) — **promoted to k3s server 2026-09-18**, now also carries an etcd member |
| pve07 | .16 | HP ProDesk 600 G4 DM (TAA, SN MXL9221RWG) | HP 83EF | i5-8500T, 6C/6T (no HT), 2.1GHz base / 3.5GHz max | 32GB 2×16GB DDR4-3200 (**32GB ceiling**), mixed brand (one unidentified JEDEC vendor) | 238GB Micron SATA SSD | `nic0` I219-LM **e1000e** | k3s-worker-4 (117), template 9007 |
| pve08 | .17 | HP ProDesk 600 G4 DM (TAA, SN MXL92857QD) | HP 83EF | i5-8500T, 6C/6T (no HT), 2.1GHz base / 3.5GHz max | 32GB 2×16GB DDR4-3200, both Micron (**32GB ceiling**) | 238GB Micron SATA SSD | `nic0` I219-LM **e1000e** | k3s-worker-5 (118), template 9008 |

#### Memory detail (per-DIMM, `dmidecode -t memory`, 2026-09-20)

| Host | Slot | Size | Rated speed | Brand | Part number | Configured speed |
|---|---|---|---|---|---|---|
| pve02 | ChannelA-DIMM0 | 16GB | DDR4-3200 | Samsung | M471A2K43DB1-CWE | 2933 MT/s |
| pve02 | ChannelB-DIMM0 | 16GB | DDR4-3200 | Samsung | M471A2K43DB1-CWE | 2933 MT/s |
| pve03 | ChannelA-DIMM0 | 16GB | DDR4-2133 | Micron | 8ATF2G64HZ-3G2B2 | 2133 MT/s |
| pve03 | ChannelB-DIMM0 | 16GB | DDR4-2133 | SK hynix | HMAA2GS6CJR8N-XN | 2133 MT/s |
| pve05 | DIMM1 (ChannelB) | 16GB | DDR4-2667 | Hynix/Hyundai | HMA82GS6JJR8N-VK | 2667 MT/s |
| pve05 | DIMM3 (ChannelA) | 16GB | DDR4-2667 | Samsung | M471A2K43DB1-CTD | 2667 MT/s |
| pve06 | DIMM1 (ChannelB) | 16GB | DDR4-3200 | Samsung | M471A2G43BB2-CWE | 2667 MT/s |
| pve06 | DIMM3 (ChannelA) | 8GB | DDR4-2667 | Hynix/Hyundai | HMA81GS6JJR8N-VK | 2667 MT/s |
| pve07 | DIMM1 (ChannelB) | 16GB | DDR4-3200 | **Unknown vendor** (JEDEC ID 0x450B) | WPBH32D416SWA-16G | 2667 MT/s |
| pve07 | DIMM3 (ChannelA) | 16GB | DDR4-3200 | SK hynix | HMAA2GS6CJR8N-XN | 2667 MT/s |
| pve08 | DIMM1 (ChannelB) | 16GB | DDR4-3200 | Micron | 8ATF2G64HZ-3G2E2 | 2667 MT/s |
| pve08 | DIMM3 (ChannelA) | 16GB | DDR4-3200 | Micron | 16ATF2G64HZ-3G2J1 | 2667 MT/s |

2933 MT/s on pve02 is the i7-10700T's official supported ceiling for non-K desktop
Comet Lake, not a downclock — that pair is running at spec. The 2667 MT/s on
every ProDesk (pve05-08) is the i5-8500T platform's documented max regardless of
the DIMMs being 3200-rated, also expected. pve03's 2133 MT/s matches the
i7-6700T's official ceiling. None of these are misconfigurations.

#### Storage detail (bus, class, brand — `lsblk`/`smartctl`, 2026-09-20)

| Host | Device | Bus | Class | Size | Brand / model | Role |
|---|---|---|---|---|---|---|
| pve02 | nvme0n1 | NVMe (M.2 PCIe) | SSD | 953.9GB | Samsung MZVLB1T0HBLR-000L7 | OS + `local-lvm` |
| pve03 | nvme0n1 | NVMe (M.2 PCIe) | SSD | 238.5GB | SK hynix BC711 | OS boot + `local-lvm` |
| pve03 | sda | SATA III (6.0 Gb/s) | SSD | 931.5GB | Samsung 870 EVO 1TB | `ssd-storage` pool |
| pve03 | sdb | USB (external, hot-plug) | HDD, 5400 RPM | 465.8GB | Seagate ST500LT012-1DG142 | `usb-backup` (nofail mount, does not auto-remount) |
| pve05 | nvme0n1 | NVMe (M.2 PCIe) | SSD | 953.9GB | Samsung MZVLW1T0HMLH-000L2 | OS + `local-lvm` |
| pve05 | sda | SATA (2.6/3.0 Gb/s, drive-limited) | HDD, 5400 RPM | 931.5GB | Seagate ST1000LM024 HN-M101MBB | **not in any `pvesm` pool — fully idle** |
| pve06 | sda | SATA III (6.0 Gb/s) | SSD | 238.5GB | Micron MTFDDAK256TBN-1AR1ZABHA | OS + `local-lvm` |
| pve07 | sda | SATA III (6.0 Gb/s) | SSD | 238.5GB | Micron MTFDDAK256TBN-1AR1ZABHA | OS + `local-lvm` |
| pve08 | sda | SATA III (6.0 Gb/s) | SSD | 238.5GB | Micron MTFDDAK256TBN-1AR1ZABHA | OS + `local-lvm` |

SMART overall-health is `PASSED` on every drive above, all 9 spinning/flash
devices across the 6 hosts. Power-on hours: pve03's USB HDD leads at 11,362h,
followed by pve05's NVMe at 10,628h — both previously flagged, still nowhere
near end-of-life, still the two to watch first.

**pve01 (.10) and pve04 (.13) were decommissioned and wiped 2026-09-18** —
pve01 was a 12GB-soldered N95 mini-PC hosting k3s-master-1 (an etcd member),
pve04 was an 8GB/1-slot Kamrui AK1 Plus hosting k3s-worker-1. Both were
permanent RAM dead ends (see the ceiling notes in prior versions of this doc)
and are no longer part of the fleet. See
[[project_ram_upgrade_and_pve01_pve04_decommission]] in memory for the full
procedure and gotchas (Longhorn eviction is per-disk, not just per-node —
`evictionRequested` must be set on both the node and its disk, and
`allowScheduling: false` must precede each).

Fleet total **184GB RAM** across 6 hosts (was 204GB across 8 before removing
pve01's 12GB and pve04's 8GB). Every remaining board except pve02's caps at
32GB, and pve03/05/07/08 are now all at their 32GB ceiling except pve06 (24GB,
still has 8GB of headroom if a stick becomes available). **pve02 is the sole
host that can exceed 32GB** (2 slots, 64GB max), which makes it the natural
home for anything that outgrows the rest of the fleet.

All four ProDesks report the TAA product string, so pve05–pve08 are one
identical quad of chassis; only their RAM configs differ. The i5-8500T caps at
2666 MT/s, so the 3200-rated sticks in pve06/07/08 all run at 2667.

#### Guest allocation and storage fill (live 2026-08-28; pve01/pve04 rows removed 2026-09-18, not re-swept for the rest)

| Host | Host RAM | Allocated to guests | `local-lvm` fill | Other pools |
|---|---|---|---|---|
| pve02 | 31.8GB | 10GB (VM111) | 1.5% of 816GB | — |
| pve03 | 15.9GB | **13.3GB** (106+112+CT101+CT102) | 3.8% of 141GB | `ssd-storage` 55% of 913GB, `usb-backup` 9% of 457GB |
| pve05 | 15.8GB | 12GB (VM114) | 11% of 816GB | 1TB HDD unpooled |
| pve06 | 23.8GB | 12GB (VM116) + etcd/control-plane since 2026-09-18 | 41% of 141GB | — |
| pve07 | 31.9GB | 12GB (VM117) | 29% of 141GB | — |
| pve08 | 31.9GB | 12GB (VM118) | 55% of 141GB | — |

**Host RAM for pve03/pve05 above (15.9GB/15.8GB) predates the 2026-09-11 RAM
upgrade and hasn't been re-swept live** — both are now 32GB installed, expect
~31.8-31.9GB reported like the other 32GB boards. pve06's allocation also
predates its 2026-09-18 promotion to k3s server, which added etcd load without
changing its VM's memory reservation. Re-verify with `free -h` and
`kubectl top nodes` before trusting these figures.

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

**PVE version drift resolved:** all 6 hosts now report `pve-manager/9.2.11` as
of 2026-09-20 (was pve02-only in the 2026-08-28 pass, other hosts on 9.2.10).
Fleet is uniform again.

#### 2026-09-20 fleet health & cleanup pass

Full hardware inventory (above) plus live health check across all 6 hosts via
direct SSH (`~/.ssh/id_k3s`, root). Findings:

- **SMART: PASSED on every drive, no immediate concerns.** Load averages are
  low everywhere (highest is pve03 at ~1.6, expected given its 4 guests);
  no host is memory- or CPU-pressured.
- **Same 93 apt packages pending on all 6 hosts.** Identical count fleet-wide
  means nothing has been patched since the last run — consistent with
  [[project_n8n_pve_upgrade_automation]]'s next scheduled window (1 Oct 2026).
  No action needed before then.
- **Journals and apt caches are healthy.** Apt caches are 20-36K everywhere
  (the `apt-get clean` fix from 2026-08-28 is holding). Journals range 24M-491.8M
  against the 500M cap; pve03 is closest to its ceiling (busiest host, 4 guests),
  which just means it rotates out older entries sooner — not a fault.
- **pve02's template 9002 fixed 2026-09-20** — cut from 12288MB to 4096MB
  (`qm set 9002 --memory 4096`), now matching 9007/9008. This was the last
  outstanding template-RAM item from 2026-08-28.
- **pve05's 1TB Seagate ST1000LM024 HDD is still fully idle** — not in any
  `pvesm` storage pool, not mounted, spinning for nothing. It's a 5400 RPM
  laptop drive already SATA-II-limited by the drive itself (3.0 Gb/s, not the
  controller). Options: add it as a second Longhorn disk on k3s-worker-2 for
  extra (slower) replica capacity, repurpose it as a second `usb-backup`-style
  target, or physically pull it — it contributes nothing today and is pure
  power draw + failure surface.
- **RAM is comfortable fleet-wide.** Every 32GB-ceiling ProDesk (pve05/07/08)
  is already maxed; pve06 has 24GB (8GB of headroom if a matching stick turns
  up, not urgent — no memory pressure observed). pve02 remains the only host
  that can go past 32GB (64GB max, 2 slots), so it stays the natural landing
  spot for anything that outgrows the rest of the fleet.
- **No stray VMs/CTs, no leftover kernels.** `qm list`/`pct list` match the
  canonical table above exactly (only the known stopped templates 9002/9007/9008
  and the intentionally-stopped immich CT100). Zero extra `pve-kernel-*`
  packages installed anywhere, so `autoremove` is doing its job.
- **On buying a replacement mini PC:** current data doesn't show a capacity
  gap. `local-lvm`/pool fill sits 5-36% across the fleet, RAM headroom exists
  on pve02 and pve06, and no host shows sustained load or memory pressure. The
  pve01/pve04 sale proceeds don't need to be reinvested for capacity reasons —
  only revisit this if a specific new workload (e.g. a resource-heavy app,
  or restoring pve03's DNS-off-Intel-NIC goal with a Realtek-NIC minipc,
  see the concentration-risk note above) creates a concrete need.

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
