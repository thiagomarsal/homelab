# Runbook: Uptime Kuma (off-cluster watcher)

## Why this exists

Every other monitor in this alerting design — Prometheus rules, Alertmanager,
the Loki ruler rules — runs inside the k3s cluster it watches. A watcher that
lives inside the thing it watches goes silent exactly when it matters most:
pve06 sat dead for 14 hours because Loki (the thing that would have surfaced
the problem) died with the host whose logs it needed.

Uptime Kuma is the one component in this design that survives the cluster
dying. It runs as a Docker container inside an LXC on bare-metal Proxmox,
entirely outside k3s, and probes the fleet from the outside.

**Monitor definitions for this instance are not stored in git.** Kuma keeps
them in a SQLite database inside the container. This document — the 12-row
table below, the LXC facts, and the restore procedure — is the reproduction
path if that database and its backups are ever lost.

## LXC facts

| Fact | Value |
|---|---|
| Proxmox host | pve01 |
| CTID | 102 |
| Hostname | uptime-kuma |
| IP | 192.168.1.21/24 |
| Gateway | 192.168.1.1 |
| Bridge | vmbr0 |
| Storage | local-lvm |
| Cores | 1 |
| Memory | 512 MB |
| Disk | 4 GB |
| Container features | `nesting=1,keyctl=1` (required for Docker in an unprivileged LXC) |
| `onboot` | `1` — **load-bearing**. A watcher that doesn't come back after a host reboot fails silently, since its silence reads as "everything is fine." |
| Unprivileged | yes |
| App | Docker container `uptime-kuma`, image `louislam/uptime-kuma:1`, port 3001 published as `3001:3001` |
| URL | <http://192.168.1.21:3001> |
| Planned FQDN (not yet wired to an ingress) | `uptime.tmf-solutions.com` (`kuma_hostname_fqdn` in `ansible/inventory/group_vars/all.yml`) |

Provisioned by `ansible/playbooks/lxc/uptime-kuma.yml` (role:
`ansible/roles/uptime-kuma`). Re-running the playbook is safe — every step is
idempotent (container-exists check, Docker-binary-exists check, and a
`docker inspect` guard before `docker run`).

Container base image: Debian 12 (bookworm), template
`local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst` — verified present on
pve01 by `pveam list local` on 2026-08-17. Chosen over the locally-available
Debian 13 (trixie) template because the Docker install task pins the Docker
apt repository to the `bookworm` suite; mixing that with a trixie base risks
a libc/openssl ABI mismatch between the container OS and Docker's bookworm
packages. `kuma_template` is a role default variable
(`ansible/roles/uptime-kuma/defaults/main.yml`) if this ever needs to change.

## The 12 monitors

All configured in the Kuma web UI (Settings are not exposed via API/CLI in
this setup). Every monitor: **60s interval, 3 retries**, default notification
enabled (see SMTP section below).

| # | Type | Target | Name | Notes |
|---|---|---|---|---|
| 1 | Ping (ICMP) | 192.168.1.10 | pve01 | |
| 2 | Ping (ICMP) | 192.168.1.11 | pve02 | |
| 3 | Ping (ICMP) | 192.168.1.12 | pve03 | |
| 4 | Ping (ICMP) | 192.168.1.13 | pve04 | |
| 5 | Ping (ICMP) | 192.168.1.14 | pve05 | |
| 6 | Ping (ICMP) | 192.168.1.15 | pve06 | |
| 7 | Ping (ICMP) | 192.168.1.16 | pve07 | |
| 8 | Ping (ICMP) | 192.168.1.17 | pve08 | |
| 9 | Ping (ICMP) | 192.168.1.1 | pfSense gateway | |
| 10 | Ping (ICMP) | 1.1.1.1 | internet | Confirms the LXC's uplink itself is up, not just the LAN |
| 11 | HTTP(s) | `https://grafana.tmf-solutions.com` | grafana | Accept status 200-399 |
| 12 | HTTP(s) | `https://alertmanager.tmf-solutions.com/-/healthy` | alertmanager | No auth needed — `/-/healthy` has its own unauthenticated IngressRoute (Task 9) |

The 10 ICMP checks (#1-10) deliberately target hardcoded IPs, not hostnames.
This keeps the probe path free of DNS, Traefik, and k3s — none of those need
to be healthy for these checks to mean something. Only monitors #11 and #12
depend on the in-cluster stack (Traefik ingress, cert-manager TLS, the
Grafana/Alertmanager Services), by design: those two exist to prove the
in-cluster alert path is reachable from outside, which is a different signal
than "is the host up."

## SMTP notification settings

Configured once under **Settings → Notifications**, set as the default
notification, applied to all 12 monitors above.

| Field | Value |
|---|---|
| Type | Email (SMTP) |
| Host | `smtp.gmail.com` |
| Port | `587` |
| Secure | STARTTLS |
| Username | same value as vault var `alert_smtp_user` (Task 5 / Alertmanager) |
| Password | same value as vault var `alert_smtp_password` (Task 5 / Alertmanager) |
| From | same value as vault var `alert_smtp_user` |
| To | same value as vault var `alert_email_to` |
| Subject prefix | `[KUMA]` — keeps this alert path visually distinguishable in the inbox from Alertmanager's mail |

Read the actual values with `ansible-vault view ansible/inventory/group_vars/all.yml`
(or `ansible-vault decrypt --output=-` on the specific block) — never paste
them into this document, a commit, or any other plaintext file.

**Monitor #12 needs no credential.** `kubernetes/monitoring/alertmanager/ingressroute.yml`
(Task 9) carves out a second, higher-priority route for exactly
`Path(`/-/healthy`)` with no auth middleware — that endpoint returns a
constant 200/"OK" and leaks nothing about alert state or config. Everything
else on `alertmanager.tmf-solutions.com` (the UI, the API) still sits behind
basic-auth. This was a deliberate change from the original design: the
basic-auth password is only recoverable as a bcrypt hash
(`alertmanager_basicauth_hash` in vault) — the plaintext is not recoverable
from git or vault at all — so having Kuma hold a copy of it would have been a
second, unrecoverable-if-lost place for that credential to live.

## Backup

- **What**: nightly cron job at `/etc/cron.daily/kuma-db-backup` inside the
  LXC (installed by the `uptime-kuma` Ansible role), which takes a
  `sqlite3 .backup` snapshot of Kuma's database, verifies it with
  `PRAGMA integrity_check` *inside* the container, pulls it out with
  `pct pull`, and only then atomically renames it into place — so a failed
  or partial backup run never overwrites a previous good one.
- **Where**: `/var/lib/vz/dump/kuma/kuma-YYYYMMDD.db` on **pve01** (the host,
  not the container).
- **Retention**: 7 days (older dated files deleted by `mtime`).
- This is the *only* backup of the 12 monitor definitions. There is no
  second copy and nothing here is in git.

## Restore procedure

1. Re-run the provisioning playbook to get a fresh LXC + Docker + Kuma
   container back on pve01 (safe to run even if CTID 102 already exists —
   every step is idempotent):
   ```
   cd ansible
   ansible-playbook playbooks/lxc/uptime-kuma.yml --ask-vault-pass
   ```
2. Stop the freshly-started Kuma container so its (empty) database isn't in
   use while you overwrite it:
   ```
   ansible pve01 -m shell -a 'pct exec 102 -- docker stop uptime-kuma'
   ```
3. Identify the newest good backup on pve01:
   ```
   ansible pve01 -m shell -a 'ls -t /var/lib/vz/dump/kuma/kuma-*.db | head -1'
   ```
4. Push it into the container's Docker volume and restart:
   ```
   ansible pve01 -m shell -a 'pct push 102 /var/lib/vz/dump/kuma/kuma-<newest-date>.db /app/data/kuma.db'
   ansible pve01 -m shell -a 'pct exec 102 -- docker start uptime-kuma'
   ```
5. Confirm at <http://192.168.1.21:3001> that all 12 monitors and the SMTP
   notification are present with correct history. If the backup is more than
   a day old, recreate any monitors added or changed after that backup's
   date manually, using the table in this document as the source of truth.

If no backup exists at all (e.g., pve01 itself was lost before the first
nightly run), there is no reproduction path except manually recreating the
admin account, the SMTP notification, and all 12 monitors from the tables
above.
