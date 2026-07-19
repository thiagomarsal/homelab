# Backup Architecture

Layered backup strategy for the homelab, built 2026-07-18/19. Each layer
protects against a different failure mode — none of them alone is sufficient
for "can't lose this data" guarantees, but together they cover hardware
failure, human/software error, and total site loss.

## Layers at a glance

| Layer | Mechanism | Protects against | Restore path |
|---|---|---|---|
| 0 | Longhorn 3-replica (in-cluster) | Single node/disk hardware failure | Automatic, transparent — no action needed |
| 1 | UpdraftPlus → Google Drive | Human/plugin error, corruption, ransomware, total cluster loss (HOA only) | UpdraftPlus restore UI, works on any WordPress install |
| 2 | Longhorn native backup → Cloudflare R2 | Same as Layer 1, but infra-level (HOA only) | New Longhorn volume "from backup" at a chosen point in time |
| 3 | Proxmox `vzdump` → Google Drive (via `rclone`) | Total cluster/control-plane loss, covers everything (not just HOA) | Restore VM/CT image on any Proxmox host |

## Layer 0: Longhorn 3-replica

- Default StorageClass `longhorn` has `numberOfReplicas: 3` (cluster-wide default, not per-volume override)
- Every PVC gets one replica per master node (k3s-master-1/2/3)
- Losing any single node costs zero data — the volume keeps serving from the
  survivors and Longhorn reattaches/rebuilds automatically
- **Does not protect against**: data corruption/deletion (replicates the
  mistake instantly), or all 3 masters failing at once (same physical site)

## Layer 1: UpdraftPlus → Google Drive (HOA WordPress only)

- Plugin already installed on the HOA site (`auburn-fields.com`)
- Google Drive remote configured via OAuth (account tied to a 15TB plan)
- Schedule: Database daily / retain 8, Files weekly / retain 8
- Verified 2026-07-18: real scheduled+manual run completed successfully,
  6 backup files (plugins/themes/uploads/DB/etc.) confirmed present in the
  `UpdraftPlus` folder on Drive
- **Restore**: UpdraftPlus's own restore UI in wp-admin, or point a fresh
  WordPress install at the same Drive folder — not tied to this cluster

## Layer 2: Longhorn native backup → Cloudflare R2 (HOA volumes only)

- Cloudflare R2 bucket: `homelab-longhorn-backups` (free tier, 10GB/month —
  actual usage per snapshot is ~310MB, comfortably inside the free tier for
  30+ generations)
- Longhorn `BackupTarget` (singleton CRD `default` in `longhorn-system`):
  `backupTargetURL: s3://homelab-longhorn-backups@auto/`,
  `credentialSecret: longhorn-r2-backup`
- Credentials live in k8s Secret `longhorn-r2-backup` (namespace
  `longhorn-system`): `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
  `AWS_ENDPOINTS` (R2's S3-compatible endpoint URL)
- `RecurringJob` `hoa-nightly-backup` (namespace `longhorn-system`): nightly
  at 3am, retains 14, targets the two HOA volumes directly via the
  `recurring-job.longhorn.io/hoa-nightly-backup=enabled` label (not a group)
- Volumes covered: `hoa-wordpress-data` (10Gi), `hoa-mariadb-data` (8Gi)
- Verified 2026-07-18 end-to-end: backup uploaded successfully, then
  restored into a scratch Longhorn volume + mounted via a throwaway pod —
  confirmed real WordPress files (wp-config.php, uploads, mu-plugins) came
  back intact byte-for-byte. Scratch resources cleaned up after.
- **Restore**: create a new `Volume` CRD with `fromBackup` set to the
  backup's `status.url`, bind a PV/PVC to it, mount wherever needed

## Layer 3: Proxmox `vzdump` → Google Drive (whole-cluster VM/CT level)

Covers the control plane and everything else running as VMs/LXCs — not
just HOA. `rclone` (Google Drive remote, same 15TB account as Layer 1) is
configured independently on pve01, pve02, and pve03 at
`/root/.config/rclone/rclone.conf` (`[gdrive]` remote).

### Schedule (weekly, Sunday)

| Time | Host | VM/CT | What | Local retain (`usb-backup`, a plain dir on root disk) |
|---|---|---|---|---|
| 02:00 | pve01 | 110 | k3s-master-1 | 2 |
| 02:30 | pve02 | 111 | k3s-master-2 | 2 |
| 02:45 | pve03 | 106 | pfSense | 1 (pre-existing job) |
| 03:00 daily | all masters | — | Layer 2 (Longhorn→R2) | 14 (in R2) |
| 03:30 | pve03 | 112 | k3s-master-3 | 2 |
| 04:00 | pve01 | 101 | pihole | 1 (pre-existing job) |

Scheduled via `pvesh create /cluster/backup` (cluster-wide `jobs.cfg`).
Times are staggered so no host runs two jobs at once, and nothing collides
with the daily 3am Layer 2 job.

### rclone sync (per host, root crontab)

Each of pve01/02/03 has a cron entry that pushes its `usb-backup/dump/`
contents to `gdrive:ProxmoxBackups/<hostname>/` shortly after that host's
last weekly job:
- pve01: `20 4 * * 0` (after both its jobs finish)
- pve02: `50 2 * * 0`
- pve03: `50 3 * * 0`

Uses `rclone copy` (not `sync`) so Drive accumulates history independently
of local `keep-last` pruning.

Verified 2026-07-18 end-to-end: manual `vzdump` of pfSense → `rclone copy`
to Drive → `rclone copy` back down → file sizes matched exactly both ways
(1.828 GiB). A full `qmrestore`-to-scratch-VM boot test was not completed
(blocked by the harness's safety classifier on restoring/creating a new VM
non-interactively) — upload/download integrity is confirmed, but "does it
actually boot" is unverified. Worth doing manually if that reassurance is
wanted: `qmrestore <backup>.vma.zst 999 --storage local-lvm`, then
`qm destroy 999` after.

### Excluded from Layer 3

- **immich (VM100)**: deliberately excluded entirely — photos are already
  redundantly stored in Google Photos, so a second cluster-side copy was
  judged not worth the size (326GB actual data) and complexity. (A rootfs-
  only job + separate photo-mount `rclone` sync was built and tested, then
  fully torn down at the user's request once the redundancy was pointed
  out — nothing from that attempt remains.)
- **k3s worker VMs** (113/114/115/116): hold no Longhorn replica data and
  are trivially rebuildable via the `ansible/playbooks/k3s/site.yml`
  playbook + rejoin — not worth backing up as VM images.

## Known gaps / not done

- No automated test-restore *schedule* for any layer — verification so far
  is one-time manual proof, not a recurring check
- Layer 3's `qmrestore`-and-boot test was never completed (see above)
- No monitoring/alerting on backup job success/failure for any layer —
  failures would currently go unnoticed until someone checks manually
