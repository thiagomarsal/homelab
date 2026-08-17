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
state, storage, memory, Longhorn volume health, certificate expiry, and two
kernel-level PVE symptoms from the journal. This is the
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
| `HOADatabaseDown` | mariadb in the `hoa` namespace has no available replica. | WordPress cannot serve real content, and may still answer HTTP 200 with an error page — do not trust a green status check. `kubectl get pods -n hoa -o wide`. If a pod is stuck `Terminating` on a dead node, its RWO Longhorn volume is stranded and the replacement hangs in `ContainerCreating`: force-delete the old pod so the volume detaches. |
| `HOASiteDown` | wordpress in the `hoa` namespace has no available replica. | auburn-fields.com is down for residents. Same first response as above. Kuma's "HOA site" keyword monitor should be alerting in parallel — if it is not, investigate that discrepancy too. |
| `HOAMetricsAbsent` | The hoa deployment metrics vanished. | The two rules above are silently dead. Check kube-state-metrics and that the `hoa` namespace still exists. |
| `PVENICHang` (Loki) | Kernel logged "Detected Hardware Unit Hang" — the e1000e TX ring wedge. | Full detail in `docs/runbooks/pve-nic-hang.md`. Host is alive but off the network; reboot is the only recovery. Threshold is >10 hangs in 10m: transient hangs self-recover (~3/day/host, driver logs `Reset adapter`), while a real wedge produced 4,658 in 2h35m with zero resets. |
| `PVEKernelOOM` (Loki) | Kernel OOM-killer fired on a PVE host. | Check which guest or host process grew; not necessarily the same guest that got killed. Threshold is >10 hangs in 10m: transient hangs self-recover (~3/day/host, driver logs `Reset adapter`), while a real wedge produced 4,658 in 2h35m with zero resets. |

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
./scripts/alert-selftest.sh critical   # posts one synthetic critical alert — check your inbox for it
./scripts/alert-selftest.sh warning    # posts one synthetic warning alert — check your inbox (batched, may take up to group_interval)
./scripts/alert-selftest.sh info       # posts one synthetic info alert — check the Alertmanager UI to confirm it never emails (routes to null)
./scripts/alert-selftest.sh inhibit    # posts, then ASSERTS: exits non-zero if the node-down inhibition cascade isn't suppressing KubeNodeNotReady
./scripts/alert-selftest.sh silence    # posts, silences, and prints the silenced set — check the printed output, then confirm no email arrived
```

Only `inhibit` checks its own result and fails the run if the cascade isn't
working. `critical`, `warning`, `info`, and `silence` post the alert and
print what they did — confirming routing (does it email, does it stay
silent, does it land in the right inbox) requires the operator to look.

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
3. **`PVENICHang` and `PVEKernelOOM` are live as of 2026-08-17.** promtail now
   ships from all 8 PVE hosts (journald, not files) and the Loki ruler is
   applied and evaluating. Verified by replaying the pve07 incident through
   Loki: it peaks at 300 hangs per 10m window against a >10 threshold.

## Outstanding operator steps

Deployed and verified 2026-08-17: Alertmanager is delivering email (proven with
both synthetic and real alerts), all 17 Prometheus rules and the 3 Loki ruler
rules are loaded and evaluating, PVE promtail ships from all 8 hosts, and
Uptime Kuma is running on pve01. What is left:

1. **Uptime Kuma UI** — at `http://192.168.1.21:3001`, create the admin account,
   add the SMTP notification (same Gmail credential as Alertmanager, subject
   prefix `[KUMA]`), then create the 12 monitors from
   `docs/runbooks/uptime-kuma.md`. Those monitors live only in Kuma's SQLite,
   so that table is the reproduction path — nothing in git recreates them.
2. **Retire the n8n `PVE Host Watchdog`** (id `bbLA156cH6tPwRlC`) once Kuma is
   confirmed probing all 8 PVE hosts. Toggle inactive, do not delete.
3. **No external dead-man's switch.** This is the one architectural gap left: a
   site-wide outage (pfSense, internet, or pve01 itself) silences both alert
   paths, and nothing watches Kuma. The `Watchdog` alert already fires
   continuously into a null receiver, so pointing it at a Healthchecks.io ping
   URL is nearly free whenever you want the coverage.

### Closed on 2026-08-17

- Four vault vars (`alert_smtp_user`, `alert_smtp_password`, `alert_email_to`,
  `alertmanager_basicauth_hash`) — set, and the template now strips the display
  spaces Google puts in app passwords.
- The onboot flags on VMs 117/118 — **retracted, no action was needed**; both
  always had `onboot: 1`. See the note in the alert table above.
- Prometheus volume grown 8Gi → 16Gi. At 8Gi with `retentionSize: 7GB` it sat at
  ~85% permanently, so `KubePersistentVolumeFillingUp` fired forever.
- Traefik metrics — the old scrape job targeted `traefik.traefik.svc:9100`, a
  port that Service has never exposed, so `TargetDown` fired forever. Traefik
  does serve metrics on container port `metrics` (9100), so a PodMonitor
  (`kubernetes/monitoring/traefik/podmonitor.yml`) scrapes the pods directly
  rather than editing the release that fronts every ingress.
- Cleanup of a retired proof-of-concept: orphaned Helm release records for
  `minio`, `redis` and `strimzi`/`kafka` (namespaces already deleted), three PVs
  stuck `Terminating` since 2026-06-07, and stale failed `nextcloud-cron` Jobs.
  Note the **data directories still exist on disk** — `/mnt/storage/minio`
  (reclaim policy was Retain) and the `local-path` directories under
  `/var/lib/rancher/k3s/storage` — so reclaim that space by hand if you want it.

## Known operational gotchas

- **Changing Alertmanager's SMTP credential requires a reload.** A deploy writes
  the new config and the sidecar rewrites `config_out`, but the running process
  keeps the old value in memory and keeps returning `535` against a file that is
  already correct. `curl -XPOST localhost:9093/-/reload` (via port-forward), or
  restart the pod. Verify a credential in two seconds with
  `python3 -c 'import smtplib...'` instead of a ten-minute deploy cycle.
- **Gmail app passwords are exactly 16 characters.** Google shows them as four
  groups of four; the spaces are display only. The values template strips
  whitespace, so either form works in vault — but a value that strips to any
  length other than 16 is wrong, and Gmail reports it as `BadCredentials`, which
  reads like the wrong password rather than a malformed one.
- **Loki rules are delivered by the chart's `loki-sc-rules` sidecar**, not by
  patching the StatefulSet. Label the ConfigMap `loki_rule: "1"` and annotate it
  `k8s-sidecar-target-directory: /rules/fake`. See the header of
  `kubernetes/monitoring/loki/ruler-rules.yml`.
