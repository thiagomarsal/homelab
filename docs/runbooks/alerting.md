# Runbook: Alerting (PVE + k3s)

## Architecture: two independent paths

```
Path 1 — in-cluster (rich detail, dies with the cluster)

  Prometheus (pinned to k3s-worker-2)
    scrapes: k8s targets, node-exporter x8, kube-state-metrics,
             longhorn-backend, traefik, cert-manager, pve-exporter -> 8 PVE hosts
    evaluates PrometheusRule CRs (pve-rules, longhorn-rules, cert-rules)
        | fires
  Alertmanager (in-cluster, 1 replica, emptyDir)
        ^ also receives
  Loki ruler (loki-0) -> POST /api/v2/alerts   [log-based rules]
        | group + inhibit + route
  Gmail SMTP :587 -> inbox

Path 2 — off-cluster (thin, survives cluster death)

  Uptime Kuma LXC (CTID 102, pve01, 192.168.1.21)
    ICMP x8 PVE hosts, ICMP pfSense gateway, ICMP 1.1.1.1
    HTTPS traefik ingress, grafana
    HTTP alertmanager /-/healthy (unauthenticated — see Task 9 change below)
        |
  Gmail SMTP :587 -> inbox, subject prefix [KUMA]
```

**What Path 1 covers**: everything with a metric or a log line — PVE host/guest
state, storage, memory, Longhorn volume health, certificate expiry, and (once
the log-shipping gap below is fixed) two kernel-level PVE symptoms. This is the
detailed path: it names the specific host, guest, volume, or storage id.

**What Path 2 covers**: is the fleet reachable at all, from outside the
cluster and outside k3s's own view of itself. It is deliberately dumb — ICMP
and a handful of HTTP health checks — because dumb is what survives the
cluster dying. Path 2 is what would have caught pve06's 14-hour outage if
Loki (part of Path 1) hadn't died with the host whose logs it needed.

**What neither path covers**:

- **A site-wide outage.** If pfSense, the internet uplink, or pve01 itself
  goes down, both paths go silent at the same time — Path 1 because
  Alertmanager can't reach Gmail (or the cluster is gone), Path 2 because
  Kuma's LXC is on pve01 and/or its uplink is the same router. Closing this
  needs an external dead-man's switch (e.g. Healthchecks.io: Prometheus fires
  a repeating `Watchdog` alert, Alertmanager pings an external URL, and the
  *absence* of pings — checked from outside the network — is what alerts).
  This was considered during design and deliberately deferred. It is the
  single highest-value thing to add next.
- **Uptime Kuma itself.** Nothing watches the watcher. If the Kuma LXC or its
  Docker container dies, both the ICMP fleet checks and the Alertmanager
  health check silently stop, and everything reads as "no news" instead of
  "no watcher." There is no mitigation for this today beyond the LXC's
  `onboot: 1` and periodic manual checks (see docs/runbooks/uptime-kuma.md).

## Alert reference

First response assumes you're looking at the email or the Alertmanager UI at
`alertmanager.tmf-solutions.com` and have SSH/kubectl access.

| Alert | Meaning | First response |
|---|---|---|
| `PVEHostDown` | Every pve-exporter view agrees a PVE host is unreachable. | Check power/console on the host. If it's the e1000e NIC hang (host alive, network dead — see `pve-nic-hang.md`), reboot is the only recovery. Guest-down and Longhorn cascades for this host are inhibited — don't expect separate emails for those. |
| `PVEClusterNotQuorate` | Corosync lost quorum. | Treat as a partition, not a single host failure — this inhibits `PVEHostDown` because a quorum loss reads as N host failures otherwise. Check corosync on the surviving nodes (`pvecm status`) before touching anything else. |
| `PVEGuestDownUnexpectedly` | A guest with `onboot=1` is not running. It did not stop on purpose. | Check the host it lives on first (may be inhibited under a `PVEHostDown` for that host). If the host is fine, `qm start <vmid>` (or `pct start` for LXC) and check why it stopped — `journalctl`, OOM, host disk pressure. |
| `PVEGuestOnbootDisabled` | A running guest has `onboot=0` — it will **not** come back after its host reboots. | `qm set <vmid> --onboot 1` (or `pct set` for LXC). Low urgency but fix before the next rolling upgrade touches that host. |
| `PVEExporterTargetDown` | One pve-exporter scrape target is down, but the other targets still see the whole fleet (every target returns all 8 hosts). | Redundancy loss, not blindness. Check the specific exporter instance named in the alert; not urgent unless it's the last one covering a given host. |
| `PVEStorageCritical` | A PVE storage is >95% full. | Proxmox write failures are imminent or happening. Free space now — check for old snapshots, ISOs, or vzdump backups on that storage. |
| `PVEStorageFillingUp` | A PVE storage is >85% full. | Not urgent (normal fill in this fleet tops out ~72%), but plan cleanup before it becomes `PVEStorageCritical`. Inhibited automatically once Critical fires for the same storage id. |
| `PVEHostMemoryPressure` | A PVE host has been above 92% memory for 30m. | Guests on it risk OOM kills. Check which guest is oversized or leaking; consider migrating a guest off if the host is chronically tight. |
| `PVEMetricsAbsent` | `pve_up` has vanished entirely — pve-exporter is producing nothing. | Every other PVE alert is now silently dead. Check the pve-exporter pod/service and the Prometheus scrape config immediately; this is the meta-alert that says "you're blind." |
| `LonghornVolumeFaulted` | All replicas of a Longhorn volume are unavailable. | The workload using it cannot read or write. Check `kubectl get volumes.longhorn.io -n longhorn-system` and the Longhorn UI for the failed replicas; this is an active outage for whatever pod owns the volume. |
| `LonghornVolumeDegraded` | A volume has run on fewer replicas than configured for 20+ minutes (rides out normal rebuild churn). | Check whether a rebuild is in progress and progressing. If it's stuck, check node/disk pressure on the replica's node. |
| `LonghornNodeStorageFillingUp` | Longhorn storage on a node is >85% full. | Longhorn stops scheduling new replicas there before it fills completely. Free space or add capacity on that node. |
| `CertExpiringSoon` | A cert-manager certificate expires in under 14 days and hasn't renewed yet. | Check the DNS-01 solver and Cloudflare API token (`cloudflare_api_token` in vault). Every `*.tmf-solutions.com` route depends on the wildcard cert — this is not optional to ignore. |
| `CertRenewalFailed` | A certificate's Ready condition is False. | Renewal is actively failing, not just slow. `kubectl describe certificate` / `kubectl describe certificaterequest` in the relevant namespace; usually a DNS-01 challenge or token problem. |
| `CertMetricsAbsent` | cert-manager metrics have disappeared entirely. | The two cert rules above are silently dead. Check the cert-manager ServiceMonitor and that cert-manager itself is running. |
| `PVENICHang` (Loki) | Kernel logged "Detected Hardware Unit Hang" — the e1000e TX ring wedge. | Full detail in `docs/runbooks/pve-nic-hang.md`. Host is alive but off the network; reboot is the only recovery. **Cannot fire yet — see Known gaps.** |
| `PVEKernelOOM` (Loki) | Kernel OOM-killer fired on a PVE host. | Check which guest or host process grew; not necessarily the same guest that got killed. **Cannot fire yet — see Known gaps.** |

## Silencing during planned work

**Manual, via the browser UI**: go to `https://alertmanager.tmf-solutions.com`
(basic-auth required — credentials from vault, see below), Silences ->
New Silence, matcher on `pve_host` (or whatever label scopes the work), and
set a duration that comfortably covers the maintenance window.

**Automatic, for rolling upgrades**: `scripts/pve-rolling-upgrade.sh` now
creates a silence matching `pve_host="<host>"` before upgrading each host and
deletes it as soon as that host is back and the cluster is healthy again —
including on every abort path (a failed playbook run, a cluster-health
timeout) and on an operator Ctrl-C. If Alertmanager is unreachable when the
script starts, it logs a warning and proceeds unsilenced rather than
aborting the upgrade — a broken alert path must never block patching a
production fleet. Silences created this way auto-expire after 45 minutes as
a backstop even if the script itself dies uncleanly.

## Running the self-checks

**Rule linting + unit tests** (no cluster access needed, runs promtool in
Docker):

```bash
./scripts/check-rules.sh
```

Extracts `.spec.groups` from every PrometheusRule CR, lints them, then runs
the unit tests in `tests/rules/`. Run this after any change to
`kubernetes/monitoring/rules/*.yml`.

**End-to-end delivery self-test** (needs `kubectl` access to `homelab` and
port-forwards to Alertmanager):

```bash
./scripts/alert-selftest.sh critical   # posts one synthetic critical alert
./scripts/alert-selftest.sh warning
./scripts/alert-selftest.sh info       # proves info-level alerts route to null
./scripts/alert-selftest.sh inhibit    # proves the node-down inhibition cascade
./scripts/alert-selftest.sh silence    # proves silence create/mute/delete
```

Everything it posts is tagged `selftest: "true"` and uses `pve_host: pve99`
(a host that doesn't exist), so it's safe to run against the real
Alertmanager at any time; it cleans up after itself on every exit path,
including Ctrl-C.

## The inhibition trade-off

While a k8s node is `NotReady`/unreachable, an inhibit rule mutes
`KubePod.*|KubeDeployment.*|KubeStatefulSet.*|KubeDaemonSet.*` alerts
**cluster-wide**, not just for pods on that node. This is deliberate and
coarse: kube-state-metrics' pod-level alerts carry no reliable `node` label
to scope the inhibition more tightly, so the choice was between "mute too
much" and "mute nothing and drown in expected churn during every node
outage." Muting too much was chosen.

**Consequence**: once the node recovers, pods are not automatically
re-checked. A real pod problem that started or continued during the outage
window will not have alerted. After any `PVEHostDown` / `PVEGuestDownUnexpectedly`
/ node-down recovery, manually check:

```bash
kubectl --context homelab get pods -A | grep -vE 'Running|Completed'
```

## Known gaps

1. **No external dead-man's switch.** A site-wide outage (router, internet,
   or pve01 down) silences both Path 1 and Path 2 at once — see the
   architecture section above. Deferred by design; highest-value future add.
2. **Nothing watches Uptime Kuma.** If the Kuma LXC or container dies, Path 2
   goes silent with no meta-alert to say so.
3. **`PVENICHang` and `PVEKernelOOM` cannot fire yet.** These Loki-ruler
   rules are deployed but structurally dead: PVE 9 is Debian 13, and Debian
   13 ships with rsyslog installed but **inactive** by default. Promtail's
   PVE scrape config reads `/var/log/syslog` and `/var/log/kern.log`, but
   those files are never created because nothing is writing them — kernel
   messages on PVE 9 live only in journald. Promtail has shipped zero lines
   from any PVE host as a result. Fixing this (point promtail at journald,
   or reactivate rsyslog) is separate work, tracked outside this project.

## Outstanding operator steps

These require actions this implementation could not take (write access to
vault, the n8n UI, or a browser session) and were deliberately left for a
human:

1. **Four vault vars**, if not already set — `ansible-vault encrypt_string`
   each and paste the resulting `!vault |` blocks into
   `ansible/inventory/group_vars/all.yml`:
   - `alert_smtp_user` — Gmail sending address
   - `alert_smtp_password` — Gmail app password
   - `alert_email_to` — recipient address
   - `alertmanager_basicauth_hash` — bcrypt hash from `htpasswd -nbB admin '<password>'`
     (the plaintext password itself is not recoverable from git or vault —
     keep a copy somewhere safe if Uptime Kuma or any other consumer ever
     needs auth against the non-`/-/healthy` routes)
2. **Fix the onboot flags**: `qm set 117 --onboot 1` on pve07 and
   `qm set 118 --onboot 1` on pve08 — k3s-worker-4/5 will not restart after a
   host reboot without this. Verify with `qm config <id> | grep onboot` on
   each host; `PVEGuestOnbootDisabled` should clear within an hour of the fix.
3. **Deactivate the n8n `PVE Host Watchdog` workflow** (id `bbLA156cH6tPwRlC`)
   once Uptime Kuma is confirmed probing all 8 PVE hosts. Toggle inactive,
   don't delete — it costs nothing dormant and preserves the SSH-probe logic
   as a fallback.
4. **Uptime Kuma UI setup**: the 12 monitors and the SMTP notification are
   not stored in git (Kuma keeps them in SQLite). Follow
   `docs/runbooks/uptime-kuma.md` to create them if this is a fresh instance
   or a restore.
