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
| Proxmox host | **pve03** (was pve01 → pve07 2026-08-21 → pve03 2026-08-25) |
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

> **When CT102 moves hosts, the `kuma_host` inventory group must move with it.**
> The playbook targets that group (`ansible/inventory/hosts.yml`), and the role
> installs the nightly DB backup cron on whatever host it hits. The cron drives
> the container through `pct exec`, so on the wrong host it fails every night.
>
> This is not hypothetical: the group used to be a templated var
> (`hosts: "{{ kuma_lxc_host | default('pve01') }}"`), and because Ansible
> evaluates `hosts:` *before* group_vars load, the var was always undefined and
> the default silently pinned every run to pve01. The cron stayed there through
> two migrations and failed nightly from 2026-08-21 to 2026-08-28 with
> `sqlite3 .backup failed inside the container`. Fixed 2026-08-28 by switching to
> a real inventory group; `pct migrate` now needs a one-line inventory edit plus
> a re-run of this playbook.

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
| 13 | **Keyword** | `https://192.168.1.61/` + header `Host: auburn-fields.com` | HOA site (auburn-fields) | Keyword `Auburn Fields`, `ignore_tls` on. See note below — this one is deliberately not a plain status check |

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

### Why the HOA monitor is a keyword check against the ingress IP

Two deliberate choices, both learned from the 2026-08-17 outage:

**Keyword, not status.** When mariadb is down, WordPress frequently still answers
HTTP 200 while serving a database-error page. A status-only check would call that
healthy. The monitor therefore requires the string `Auburn Fields` (from the page
title) to appear in the response.

**Ingress IP + Host header, not the public hostname.** `auburn-fields.com` resolves
to Cloudflare (`2606:4700:…`), so checking that name tests Cloudflare's edge and your
uplink as well as the site — it would go red during an internet outage even though the
cluster is serving fine, and Kuma's job is watching *your fleet*. Probing
`https://192.168.1.61/` with a `Host:` header hits Traefik directly, so this monitor
answers "is the cluster serving the HOA site" rather than "can the world reach it".
`ignore_tls` is on because connecting by IP sends the wrong SNI for the
auburn-fields.com certificate.

If you also want the resident's-eye view, add a second monitor on
`https://auburn-fields.com` — it is genuinely a different question, and both are worth
having. `hoa.tmf-solutions.com` is not usable for this: it does not resolve locally and
301s to the public domain anyway.

## How these monitors were created (2026-08-17)

They were **seeded directly into Kuma's SQLite**, not clicked in through the UI:
one `notification` row (SMTP, `is_default=1`), 12 `monitor` rows, and a
`monitor_notification` row linking each monitor to the notification — then a
`docker restart uptime-kuma` so Kuma loaded them. Kuma has no REST API for
monitor creation (its UI drives socket.io), so SQL was the only scriptable path.

That bypasses Kuma's own validation, so it was proven with a drill rather than
assumed: a throwaway `ping` monitor against a dead IP (192.168.1.99, 1 retry)
went DOWN and delivered a `[KUMA] ... is DOWN` email, after which the drill
monitor was deleted. **If you ever re-seed this way, run that drill again** —
a malformed `notification.config` JSON fails silently, and silence from a
watcher is indistinguishable from everything being fine.

`monitor_notification.id` has no AUTOINCREMENT, so ids must be supplied
explicitly when inserting.

### DNS note

`alertmanager.tmf-solutions.com` resolves via a **CNAME in pihole's
`pihole.toml`** (`[dns] cnameRecords`) pointing at `traefik.tmf-solutions.com`,
which `[dns] hosts` maps to 192.168.1.61 — the same pattern grafana uses.
pihole here is **v6**: it does NOT read `/etc/pihole/custom.list`, and the
`pihole` CLI is not on PATH, so `pihole restartdns` silently does nothing.
Reload records with `systemctl restart pihole-FTL` inside CT 101.

## Backup

- **What**: nightly cron job at `/etc/cron.daily/kuma-db-backup` on the
  **Proxmox host** — not inside the LXC (installed by the `uptime-kuma` Ansible
  role). It drives the container from outside via `pct exec` / `docker exec`:
  takes a `sqlite3 .backup` snapshot of Kuma's database, verifies it with
  `PRAGMA integrity_check` *inside* the container, pulls it out with
  `pct pull`, and only then atomically renames it into place — so a failed
  or partial backup run never overwrites a previous good one.
- **Where**: `/var/lib/vz/dump/kuma/kuma-YYYYMMDD.db` on **pve03** (the host,
  not the container). Because the cron lives on the host, it does **not** follow
  a `pct migrate` — see the warning above.
- **Retention**: 7 days (older dated files, and any orphaned
  `.kuma-*.db.tmp` files left by an interrupted pull, deleted by `mtime`).
  Note the retention `find` runs *after* the backup step and `fail()` exits
  early, so a broken backup also stops pruning — which is the only reason the
  2026-08 outage did not silently delete its own last-known-good files.
- This is the *only* backup of the 13 monitor definitions. There is no
  second copy and nothing here is in git. (A one-off rescue copy of the
  2026-08-18→21 files also sits in `pve03:/root/kuma-backup-archive/`, outside
  the retention path.)
- **Checking it actually ran**: the host's cron.daily failures go nowhere by
  default. The script logs to journald under the `kuma-db-backup` tag on every
  run — a `daemon.info` line on success, a `daemon.err` line with a reason on
  failure. The tag is on the **host's** journal, so do not wrap this in
  `pct exec`:
  ```
  ansible kuma_host -m shell -a 'journalctl -t kuma-db-backup --since "-8 days"'
  ```
  A missing success line for a given day means that day has no backup —
  treat it the same as a failure even if nothing paged. Nothing in Prometheus
  watches this yet; it is a manual check.

## Restore procedure

1. Re-run the provisioning playbook to get a fresh LXC + Docker + Kuma
   container back on the host in the `kuma_host` inventory group (currently
   pve03; safe to run even if CTID 102 already exists — every step is
   idempotent):
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
4. `/app/data` is a **Docker named volume** (`uptime-kuma`), not a path in
   the LXC's own filesystem — `pct push` writes into the LXC rootfs, which
   nothing reads, and a restore done that way leaves Kuma silently starting
   empty at the setup wizard with no error anywhere. Reach into the
   container the same way the backup script does: push to a scratch path in
   the LXC first, then `docker cp` from there into the volume. Stop the
   container first so Kuma isn't holding `kuma.db` open mid-restore:
   ```
   ansible pve01 -m shell -a 'pct push 102 /var/lib/vz/dump/kuma/kuma-<newest-date>.db /tmp/kuma-restore.db'
   ansible pve01 -m shell -a 'pct exec 102 -- docker cp /tmp/kuma-restore.db uptime-kuma:/app/data/kuma.db'
   ansible pve01 -m shell -a 'pct exec 102 -- rm -f /tmp/kuma-restore.db'
   ansible pve01 -m shell -a 'pct exec 102 -- docker start uptime-kuma'
   ```
5. **Verify the restore actually took**, not just that the container
   started: open <http://192.168.1.21:3001> and confirm it loads straight to
   the login screen (or dashboard) — **not** the first-run setup wizard —
   and that all 12 monitors from the table above are present with their
   prior history. Seeing the setup wizard means the `docker cp` step landed
   on an empty/wrong file and needs to be redone. If the backup used is more
   than a day old, recreate any monitors added or changed after that
   backup's date manually, using the table in this document as the source
   of truth.

If no backup exists at all (e.g., pve01 itself was lost before the first
nightly run), there is no reproduction path except manually recreating the
admin account, the SMTP notification, and all 12 monitors from the tables
above.
