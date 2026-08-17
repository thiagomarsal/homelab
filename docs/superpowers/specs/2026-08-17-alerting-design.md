# Alerting and Monitoring Design — PVE + k3s

**Date:** 2026-08-17
**Status:** approved design, not yet implemented
**Scope:** end-to-end alert delivery for the 8-node Proxmox fleet and the 8-node k3s cluster

---

## 1. Problem

Prometheus has scraped both the hypervisors and the cluster for months, but no
Alertmanager is deployed and no custom rules exist. There is no path by which any
alert reaches a human. On 2026-08-15 pve06 sat dead for 14 hours before anyone
noticed. An n8n workflow (`PVE Host Watchdog`, 30-minute SSH probe, email on state
change) is the only interim coverage.

## 2. The governing constraint

**A watcher that runs on the thing it watches will lie to you.** Proven three times
on 2026-08-16:

- Loki ran on k3s-worker-3 on pve06 and died with the host whose logs were needed.
  Every finding in that investigation came from pve06's local journal instead.
- The n8n monthly upgrade job cannot report on pve08, because pve08 hosts n8n and
  rebooting it kills the execution before the mail sends.
- A fleet monitor run from WSL reported all 8 hosts down when pfSense rebooted,
  because its own network path depended on the router.

Every choice below is measured against this constraint.

## 3. Decisions

| # | Decision | Choice | Rationale |
|---|---|---|---|
| 1 | Notification transport | SMTP direct from Alertmanager | Fewest moving parts; no dependency on n8n or other in-cluster workloads |
| 2 | SMTP relay | Gmail app password | Already available, no signup |
| 3 | Off-cluster watcher | Uptime Kuma in an LXC on pve01 | Off-cluster, on-site; richer UI than the YAML-configured alternative |
| 4 | n8n watchdog | Retire immediately once Kuma probes all 8 hosts | Kuma's 60s probe supersedes a 30-minute poll |
| 5 | Rule scope | Curated set; noisy kube-prometheus-stack defaults disabled | A system you trust beats a system that is complete |
| 6 | Alerting brain | Alertmanager (not Grafana unified alerting) | Inhibition is the capability this fleet needs; rules stay in git |

### 3.1 Out of scope

- **The 7-of-8 upgrade reporting gap.** The monthly n8n upgrade job cannot report on
  pve08 because rebooting pve08 kills the execution. This design only touches
  `scripts/pve-rolling-upgrade.sh` to add Alertmanager silences; migrating fleet
  upgrades off n8n onto that script — which would close the gap and also gates on
  Longhorn rebuild between hosts — is separate work.
- **Promtail's ingress dependency** for PVE log shipping (see 6.5).

### 3.2 Accepted open gap

A site-wide failure — pfSense down, internet down, or pve01 itself down — leaves
both alert paths silent. Closing it requires an external dead-man's switch
(Healthchecks.io or equivalent): Prometheus fires a repeating `Watchdog` alert,
Alertmanager pings an external URL, and the absence of pings triggers a
notification from outside the network. This was considered and deliberately
deferred. It remains the single highest-value future addition and needs no
infrastructure.

## 4. Architecture

Two independent paths.

### Path 1 — in-cluster (rich detail, dies with the cluster)

```
Prometheus (worker-2, pinned)
  ├── scrapes: k8s targets, node-exporter x8, kube-state-metrics,
  │            longhorn-backend, traefik, cert-manager (new),
  │            pve-exporter -> 8 PVE hosts
  └── evaluates PrometheusRule CRs (curated)
            | fires
      Alertmanager (in-cluster, 1 replica, emptyDir)
            ^ also receives
      Loki ruler (loki-0) -> POST /api/v2/alerts   [log-based rules]
            | group + inhibit + route
      Gmail SMTP :587 -> inbox
```

### Path 2 — off-cluster (thin, survives cluster death)

```
Uptime Kuma LXC (CTID 102, pve01, 192.168.1.21)
  ├── ICMP x8 PVE hosts (.10-.17)
  ├── ICMP pfSense gateway, ICMP 1.1.1.1
  ├── HTTPS traefik ingress, grafana
  └── HTTP prometheus /-/healthy, alertmanager /-/healthy
            |
      Gmail SMTP :587 -> inbox, subject prefix [KUMA]
```

### 4.1 Storage: Alertmanager uses emptyDir, not Longhorn

Longhorn degradation is one of the conditions Alertmanager must report. Placing
its state on Longhorn means a Longhorn outage can suppress the alert about
Longhorn — the governing constraint again. Cost of `emptyDir`: silences and
notification dedup state are lost on pod restart, so one repeat email is possible
after a restart. Accepted.

### 4.2 Placement

Prometheus stays pinned to k3s-worker-2. Alertmanager is left unpinned so it can
reschedule freely when a host dies. Spreading the two buys nothing — if Prometheus
is down there are no alerts to route either way.

## 5. Metric reality (verified live 2026-08-17)

Facts established by querying Prometheus directly, which shaped the rules:

- **Every pve-exporter target returns the whole cluster.** Each scraped IP exposes
  `node/pve01` … `node/pve08`, so all 8 hosts are already covered for node-down
  detection even though only 6 targets are configured. The missing pve07/pve08
  targets are a *redundancy* gap, not a blindness gap.
- **Consequence: every PVE series is duplicated 6x.** Rules must aggregate with
  `max by (id) (...)`. This converts into a feature — a node counts as down only
  when every surviving exporter view agrees, which is corosync's own quorum truth.
- **`pve_onboot_status` is a reliable guest-down guard.** Currently down and
  correctly excluded by it: `qemu/9007`, `qemu/9008` (VM templates) and `lxc/100`
  (immich, intentionally stopped). Zero false positives today.
- **`qemu/117` and `qemu/118` have `onboot=0`** — k3s-worker-4/5 will not restart
  after a pve07/pve08 reboot. Latent bug, fixed as part of this work.
- **pve03 `local-lvm` is at 0.01%, not 95%.** The old capacity problem is gone;
  content moved to `ssd-storage` (55%). Highest fill in the fleet is pve01 and
  pve02 `local-lvm` at ~72%, so an 85% warning threshold is quiet but meaningful.
- **cert-manager is not scraped at all.** No `certmanager_*` metrics exist; a
  ServiceMonitor is required before any certificate rule can work.
- Available and used: `pve_up`, `pve_onboot_status`, `pve_disk_usage_bytes`,
  `pve_disk_size_bytes`, `pve_memory_usage_bytes`, `pve_memory_size_bytes`,
  `pve_cluster_info`, `longhorn_volume_robustness`,
  `longhorn_node_storage_usage_bytes`, `longhorn_node_storage_capacity_bytes`.

## 6. Rules

All PVE rules aggregate with `max by (id)` to collapse the 6 duplicate views into
one alert.

### 6.1 PVE

| Alert | Expression core | For | Severity |
|---|---|---|---|
| `PVEHostDown` | `max by (id) (pve_up{id=~"node/.*"}) == 0` | 5m | critical |
| `PVEClusterNotQuorate` | `max by (id) (pve_up{id=~"cluster/.*"}) == 0` | 5m | critical |
| `PVEGuestDownUnexpectedly` | `max by (id) (pve_up{id=~"qemu/.*\|lxc/.*"}) == 0 and on(id) max by (id) (pve_onboot_status) == 1` | 10m | critical |
| `PVEExporterTargetDown` | `up{job="pve"} == 0` | 10m | warning |
| `PVEStorageCritical` | `max by (id) (pve_disk_usage_bytes{id=~"storage/.*"} / pve_disk_size_bytes{id=~"storage/.*"}) > 0.95` | 10m | critical |
| `PVEStorageFillingUp` | same ratio `> 0.85` | 30m | warning |
| `PVEHostMemoryPressure` | `max by (id) (pve_memory_usage_bytes{id=~"node/.*"} / pve_memory_size_bytes{id=~"node/.*"}) > 0.92` | 30m | warning |
| `PVEGuestOnbootDisabled` | running guest with `max by (id) (pve_onboot_status) == 0` | 1h | warning |

`PVEGuestOnbootDisabled` fires immediately on worker-4/5 today. That is correct
behaviour, and it is self-maintaining: no hardcoded exclusion list is needed for
templates or intentionally stopped guests.

### 6.2 Longhorn

| Alert | Expression core | For | Severity |
|---|---|---|---|
| `LonghornVolumeFaulted` | `longhorn_volume_robustness == 3` | 1m | critical |
| `LonghornVolumeDegraded` | `longhorn_volume_robustness == 2` | 20m | warning |
| `LonghornNodeStorageFillingUp` | `longhorn_node_storage_usage_bytes / longhorn_node_storage_capacity_bytes > 0.85` | 30m | warning |

The 20m window on `Degraded` is deliberate — it rides out normal rebuild churn
during a rolling host upgrade.

### 6.3 Certificates (requires the new ServiceMonitor)

| Alert | Expression core | For | Severity |
|---|---|---|---|
| `CertExpiringSoon` | `certmanager_certificate_expiration_timestamp_seconds - time() < 14*86400` | 1h | warning |
| `CertRenewalFailed` | `certmanager_certificate_ready_status{condition="False"} == 1` | 1h | warning |

### 6.4 Meta-rules — monitoring that notices its own death

A rule referencing a metric that stopped existing never fires, and looks identical
to "everything is fine". These close that hole:

| Alert | Expression | For | Severity |
|---|---|---|---|
| `PVEMetricsAbsent` | `absent(pve_up)` | 10m | critical |
| `CertMetricsAbsent` | `absent(certmanager_certificate_expiration_timestamp_seconds)` | 1h | warning |

Plus the retained upstream `TargetDown`.

### 6.5 Loki ruler (log-based)

Promtail on the PVE hosts ships four streams — `syslog`, `kernel`, `auth`, `pve` —
each labelled `host: <inventory_hostname>`. That `host` label already carries
exactly the values `pve_host` needs, so the rules copy it across
(`pve_host: '{{ $labels.host }}'`) and inhibition works on log-derived alerts too.

| Alert | LogQL core | Severity |
|---|---|---|
| `PVENICHang` | `count_over_time({job="kernel"} \|= "Detected Hardware Unit Hang" [10m]) > 0` | critical |
| `PVEKernelOOM` | `count_over_time({job="kernel"} \|~ "Out of memory: Killed process" [15m]) > 0` | warning |

`PVENICHang` catches the pve06 e1000e fault at the first hang rather than waiting
for unreachability. Loki has **no Helm release record**, so `helm upgrade` is
unavailable — the ruler stanza and rules ConfigMap are applied by direct
`kubectl apply` / StatefulSet patch.

**Known path dependency:** PVE promtail pushes to
`https://loki.tmf-solutions.com/loki/api/v1/push`, which routes through the k3s
Traefik ingress. Log-based alerting therefore requires the cluster to be reachable
— the governing constraint once more. Kernel messages still land in each host's
local `/var/log/kern.log` regardless, so nothing is lost for post-incident
forensics; only the live alert is affected. Fixing this properly means pointing
promtail at a LAN address that bypasses ingress, which is out of scope here.

### 6.6 Disabled upstream defaults

k3s trips these permanently, producing a standing wall of firing alerts:

`kubeApiserverAvailability`, `kubeApiserverBurnrate`, `kubeApiserverHistogram`,
`kubeApiserverSlos`, `kubernetesResources` (CPU/memory overcommit is always true
on this fleet), `kubernetesSystem` (`KubeVersionMismatch` during k3s upgrades).

**Retained:** `general` (`TargetDown`, `Watchdog`), `nodeExporter*`,
`kubernetesStorage`, `kubernetesApps`, `kubelet`, `kubeStateMetrics`, and the
Prometheus/operator/Alertmanager self-monitoring groups.

## 7. Inhibition

Inhibition is the reason Alertmanager was chosen over Grafana alerting. Without it,
a single host death produces roughly 30 emails: host down, its guests down, the
k3s node NotReady, kubelet down, every pod on that node, Longhorn degraded, and
each affected volume replica.

**Prerequisite — a shared label across the PVE/k8s boundary, derived from live
metrics rather than a hand-maintained map.** `pve_guest_info` already carries both
halves: its `node` label is the PVE host and its `name` label is the guest name,
which for the k3s VMs *is* the k3s node name. So the guest rules copy `node` into
`pve_host`, then overwrite `node` with `name` — after which a PVE guest alert
carries `node="k3s-worker-3"`, exactly matching what kubelet and
kube-state-metrics alerts use. No static IP-to-hostname map exists anywhere.

One relabel is still needed: node-exporter series carry only `instance=IP:9100`,
so `nodeExporter.prometheus.monitor.relabelings` adds
`node` from `__meta_kubernetes_pod_node_name`.

Rules, in precedence order:

1. `PVEClusterNotQuorate` mutes `PVEHostDown` → a partition reads as one event,
   not eight.
2. `PVEGuestDownUnexpectedly` mutes every other alert with an equal `node` → the
   whole k8s cascade for that node collapses into nothing.
3. `PVEHostDown` mutes `PVEStorage*`, `PVEHostMemoryPressure`, and
   `PVEExporterTargetDown` on equal `pve_host`. It deliberately does **not** mute
   `PVEGuestDownUnexpectedly` — that alert must stay alive both because you want
   to know which guests died and because it is the inhibitor for rule 2.
4. `KubeNodeNotReady`/`KubeNodeUnreachable` mute pod-level alerts
   (`KubePod*`, `KubeDeployment*`, `KubeStatefulSet*`, `KubeDaemonSet*`)
   cluster-wide. Coarse on purpose — kube-state-metrics pod alerts have no
   reliable `node` label. **Trade-off:** an unrelated pod problem can hide during
   a node outage, so the runbook requires re-checking pods after recovery.
5. `severity=critical` mutes `severity=warning` on equal `[alertname, pve_host]`.
6. `LonghornVolumeFaulted` mutes `LonghornVolumeDegraded` on equal `volume`.

Net effect of a host death: two emails (`PVEHostDown` + `PVEGuestDownUnexpectedly`)
instead of roughly thirty. Alertmanager inhibition is not transitive, which is why
`PVEHostDown` does not mute the guest alert's own inhibiting power — the guest
alert has to survive in order to suppress the k8s cascade.

## 8. Routing

- `group_by: [alertname, pve_host]`, `group_wait: 45s`, `group_interval: 5m`
- **critical** → email immediately, `repeat_interval: 2h`
- **warning** → batched, `repeat_interval: 24h`
- **info** → null receiver, dashboard only
- Subject templated with severity and `pve_host`

**Upgrade windows are silenced programmatically.**
`scripts/pve-rolling-upgrade.sh` POSTs a silence matching `pve_host=<host>` before
touching a host and deletes it after the Longhorn rebuild gate the script already
waits on. No time-based mute intervals to maintain.

## 9. Off-cluster watcher

**Container:** CTID 102 on pve01, Debian 12 unprivileged, 1 vCPU / 512MB / 4GB
disk, static `192.168.1.21`, **`onboot=1`**. Uptime Kuma runs as a Docker
container with `restart=always`. Address choice: LXCs occupy the `.20`s
(immich is `.20`); MetalLB owns `.61-.199`; `.21` and CTID 102 were both verified
free.

**Provisioning:** new `ansible/playbooks/lxc/uptime-kuma.yml` plus a
`roles/uptime-kuma` role — `pct create`, Docker, the Kuma container, and a nightly
`sqlite3 .backup` of `kuma.db` to pve01 `local` storage with 7-day retention. This
playbook is the first real content in `playbooks/lxc/`; `pihole.yml` and
`immich.yml` are empty `roles: []` stubs.

**Monitors (12), 60s interval, 3 retries before alerting:** ICMP to the 8 PVE
hosts, ICMP to the pfSense gateway and `1.1.1.1`, HTTPS to the traefik ingress and
Grafana, HTTP to `prometheus:9090/-/healthy` and `alertmanager:9093/-/healthy`.
The last two are the watcher watching the watcher.

**Probe path independence.** ICMP checks target hardcoded LAN IPs — no Traefik, no
k3s, no DNS. Only the four HTTPS/HTTP checks resolve names, and those are supposed
to fail when DNS or ingress breaks.

**Configuration is state outside git.** Kuma stores everything in SQLite behind its
UI. Mitigations: `docs/runbooks/uptime-kuma.md` enumerates all 12 monitors with
exact settings so they are re-creatable from scratch, plus the nightly `.db`
backup. A pve01 loss means a restore or roughly 15 minutes of clicking.

## 10. Secrets

Three new vault vars in `ansible/inventory/group_vars/all.yml`: `alert_smtp_user`,
`alert_smtp_password` (Gmail app password), `alert_email_to`. They render into the
Alertmanager config inside `/tmp/kube-prometheus-stack-values.yml`, which is
already written `0600` and deleted after the run — the same mechanism
`grafana_admin_password` uses today. No new secret handling is introduced.

**A Gmail app password is send-as authority over the entire account, and this
repository is public.** It lives in vault only. The recipient address also stays
in vault rather than in any committed `kubernetes/` manifest. Kuma's copy of the
same credential is typed into its UI and lives in its SQLite; the runbook records
that it comes from vault, never the value.

**Alertmanager exposure:** an `IngressRoute` for `alertmanager.tmf-solutions.com`
following the existing Grafana/cert-manager pattern, behind a Traefik basic-auth
middleware. Kuma needs a reachable endpoint from outside the cluster, and the
silence UI becomes usable from a browser as a side benefit.

## 11. Prerequisite defects in the deploy path

These must be fixed before any of the above is safely deployable.

1. **No `monitoring` tag exists.** Phases 9-10 and the Loki phase of
   `roles/rancher/tasks/main.yml` carry no tags, so monitoring cannot be deployed
   without running the whole role — which re-runs the Longhorn and Loki installs
   that have crashed etcd masters before. Adding `tags: [monitoring]` is a
   prerequisite, not a convenience.
2. **Deleted values file.** `tasks/main.yml:266` removes
   `/tmp/kube-prometheus-stack-values.yml`; line 451 then runs
   `helm upgrade --values` against that deleted path. The second upgrade is
   redundant — the Loki datasource is already in the template — so it is dropped
   and the temp-file deletion moves to the end of the role.
3. **Two competing values files.** `kubernetes/monitoring/kube-prometheus-stack/values.yaml`
   is an orphan that deploys nothing; the authoritative source is
   `roles/rancher/templates/kube-prometheus-stack-values.yml.j2`. The orphan's body
   is replaced with a pointer comment — no deletion, no lost information. Its
   Prometheus `nodeSelector` (written down but never applied) moves into the
   template, where it takes effect.

`pve_nodes` in `group_vars/all.yml` already lists all 8 IPs. Live Prometheus
scrapes only 6 because the release has not been re-rendered since pve07/pve08
joined (revision 8, dated 2026-07-17). Phase 0 fixes this by re-running, not by
editing.

## 12. File inventory

| Path | Change |
|---|---|
| `ansible/inventory/group_vars/all.yml` | 3 vault vars, Kuma LXC vars |
| `ansible/roles/rancher/templates/kube-prometheus-stack-values.yml.j2` | Alertmanager enabled, config/route/inhibit rules, `defaultRules` toggles, `pve_host` relabel, Prometheus nodeSelector |
| `ansible/roles/rancher/tasks/main.yml` | `monitoring` tag, apply rule manifests, fix items 2 and 3 above |
| `kubernetes/monitoring/rules/pve.yml` | PVE PrometheusRule + meta-rules |
| `kubernetes/monitoring/rules/longhorn.yml` | Longhorn PrometheusRule |
| `kubernetes/monitoring/rules/certs.yml` | certificate PrometheusRule |
| `kubernetes/monitoring/cert-manager/servicemonitor.yml` | new scrape target (:9402) |
| `kubernetes/monitoring/alertmanager/ingressroute.yml` | exposure |
| `kubernetes/monitoring/alertmanager/basicauth.yml` | Traefik middleware |
| `kubernetes/monitoring/loki/ruler-rules.yml` | NIC-hang + OOM log rules (applied by patch) |
| `kubernetes/monitoring/kube-prometheus-stack/values.yaml` | body replaced with pointer to the `.j2` |
| `ansible/roles/uptime-kuma/*` | new role |
| `ansible/playbooks/lxc/uptime-kuma.yml` | new playbook |
| `scripts/pve-rolling-upgrade.sh` | POST/DELETE Alertmanager silence per host |
| `docs/runbooks/alerting.md` | what each alert means, first response |
| `docs/runbooks/uptime-kuma.md` | all 12 monitors, restore procedure |

**Manual steps that cannot live in git:** deactivate the n8n `PVE Host Watchdog`
workflow, and type the SMTP credential into Kuma once.

**Adjacent fix folded in:** `qm set 117 --onboot 1` and `qm set 118 --onboot 1` so
k3s-worker-4/5 survive a host reboot.

## 13. Rollout

| Phase | Work | Gate to next phase |
|---|---|---|
| 0 | `monitoring` tag, values-file fix, SSOT pointer | `--tags monitoring` runs clean and idempotent; pve targets go 6 → 8 |
| 1 | PrometheusRules only, **Alertmanager still off** | 24-48h observing what fires in the Prometheus UI; thresholds tuned before any email is wired |
| 2 | Alertmanager, SMTP, routing, inhibition | synthetic alert tests pass |
| 3 | Loki ruler rules | `logger` drill fires `PVENICHang` |
| 4 | Kuma LXC and 12 monitors | bogus-target drill delivers email |
| 5 | Retire n8n watchdog, onboot fixes, upgrade-script silences, runbooks | — |

Phase 1 exists because a curated rule set still needs calibration against this
specific fleet. Wiring email before that step is how alerting becomes noise that
gets filtered away.

## 14. Testing

- `promtool check rules` on every rule file — syntax.
- `promtool test rules` unit tests for the two pieces of non-obvious logic:
  `PVEHostDown` must fire when **all** exporter views report 0 and must **not**
  fire while any view still reports up; `PVEGuestDownUnexpectedly` must ignore the
  `onboot=0` templates and the stopped immich LXC.
- Synthetic alerts via `amtool alert add`: one critical (email arrives), one
  warning (batched, arrives), one info (silently dropped).
- Inhibition proof: fire `PVEHostDown{pve_host="pve06"}` plus a warning carrying
  the same `pve_host` — exactly one email must arrive.
- Silence proof: run the upgrade script's silence POST by hand, fire a synthetic
  alert into the window, confirm mute, DELETE, confirm unmute.
- Loki drill: `logger -t kernel "Detected Hardware Unit Hang TEST"` on a PVE host
  → promtail → ruler → email. Harmless and fully end-to-end.
- Kuma drill: repoint one monitor at `192.168.1.99`, confirm email, repoint back.

**Optional real-failure drill, gated on explicit approval at execution time:**
`qm stop 117` (worker-4 — newest node, Longhorn holds 3 replicas). Expected result
is exactly one `PVEGuestDownUnexpectedly` email with the k8s node, pod, and
Longhorn cascade inhibited. It is the only test that exercises the entire chain,
and it does trigger a real Longhorn rebuild, so it is opt-in rather than part of
the plan.

## 15. Failure modes

| Failure | Coverage |
|---|---|
| Gmail throttled or down | Alertmanager retries; nothing lost while the pod lives |
| Alertmanager restarts | `emptyDir` loses dedup state — one repeat email possible. Accepted |
| Alert storm | inhibition, grouping, `repeat_interval` caps |
| Alertmanager or Prometheus dies | Kuma probes both `/-/healthy` |
| A metric silently disappears | `absent()` meta-rules plus `TargetDown` |
| Kuma dies | **Nothing notices.** Accepted gap — see 3.2 |
| Site-wide outage (pfSense, internet, pve01) | **Both paths silent.** Accepted gap — see 3.2 |
| k3s ingress down | PVE log-based alerts stop (promtail pushes through Traefik); metric-based alerts and Kuma unaffected — see 6.5 |

## 16. References

- Fleet inventory and per-host detail: `docs/architecture.md`, `docs/cluster-setup.md`
- pve06 e1000e NIC hang mitigation (unrepaired hardware fault)
- n8n PVE upgrade automation and its 7-of-8 reporting gap
- Longhorn `delete-statefulset-pod` node-down policy
