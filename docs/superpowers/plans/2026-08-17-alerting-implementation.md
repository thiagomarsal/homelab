# PVE + k3s Alerting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a working alert path from Prometheus/Loki to email, plus an off-cluster watcher, so no host or volume failure goes unnoticed again.

**Architecture:** Alertmanager is enabled inside the existing kube-prometheus-stack release and delivers over Gmail SMTP. Curated `PrometheusRule` CRs live in `kubernetes/monitoring/rules/` and are applied by the Ansible `rancher` role. A Loki ruler covers log-only failures. An Uptime Kuma LXC on pve01 probes the fleet from outside the cluster.

**Tech Stack:** Ansible (vault-encrypted vars, Jinja2 templates), Helm via the `rancher` role, kube-prometheus-stack 83.7.0, Prometheus rules + PromQL, Loki 6.55.0 ruler + LogQL, Traefik IngressRoute + basic-auth middleware, Proxmox `pct`/`qm`, Docker inside an LXC, `promtool` via Docker for rule tests.

**Spec:** `docs/superpowers/specs/2026-08-17-alerting-design.md`

## Global Constraints

- **kubectl context is always `homelab`.** Never switch it. Every `kubectl` command in this plan passes `--context homelab` explicitly.
- **Any write/mutating cluster operation requires explicit user confirmation** before executing (per `CLAUDE.md`). Steps that mutate are marked **[CONFIRM]**.
- **Never run the full `rancher` role.** Re-running it re-installs Longhorn and Loki, which has crashed etcd masters. Always use `--tags monitoring` (created in Task 1).
- **No secrets in git.** Gmail app password, SMTP user, and recipient address go in `ansible/inventory/group_vars/all.yml` as `ansible-vault encrypt_string` values only. This repository is public.
- **Ansible renders the Helm values file, so Go template braces must be wrapped in `{% raw %}…{% endraw %}`** inside `.j2` files, or Ansible tries to evaluate Alertmanager's own templating and the run fails.
- **Chart version pin:** `kube_prometheus_stack_version` is already set in group_vars; do not change it. Loki stays on 6.55.0.
- **Loki has no Helm release record** (`helm list -A` does not show it). Never run `helm upgrade` against Loki — patch its ConfigMap/StatefulSet directly.
- **Alertmanager storage is `emptyDir`, never Longhorn.** A Longhorn outage must not be able to suppress the alert about Longhorn.
- Every PVE rule aggregates with `max by (id)` — each of the 6 pve-exporter targets returns the whole cluster, so raw series are 6× duplicated.
- Rule/label naming is fixed: `pve_host` = PVE hostname (`pve01`…`pve08`), `node` = k3s node name (`k3s-worker-3`), `name` = PVE guest name, `id` = PVE object id (`node/pve06`, `qemu/117`, `storage/pve01/local-lvm`). No other label names are introduced.

---

## File Structure

| Path | Responsibility |
|---|---|
| `ansible/inventory/group_vars/all.yml` | vault secrets + Kuma/Alertmanager vars |
| `ansible/roles/rancher/templates/kube-prometheus-stack-values.yml.j2` | single source of truth for the monitoring release: Alertmanager on/off, config, routing, inhibition, default-rule toggles, relabelings |
| `ansible/roles/rancher/tasks/main.yml` | deploy orchestration; gains a `monitoring` tag and rule-apply tasks |
| `kubernetes/monitoring/rules/pve.yml` | PVE host/guest/storage/meta rules |
| `kubernetes/monitoring/rules/longhorn.yml` | Longhorn volume + node storage rules |
| `kubernetes/monitoring/rules/certs.yml` | certificate expiry/renewal rules |
| `kubernetes/monitoring/cert-manager/servicemonitor.yml` | makes `certmanager_*` metrics exist |
| `kubernetes/monitoring/alertmanager/ingressroute.yml` | external reachability for Kuma + silence UI |
| `kubernetes/monitoring/alertmanager/basicauth.yml` | Traefik middleware guarding that route |
| `kubernetes/monitoring/loki/ruler-rules.yml` | LogQL rules ConfigMap (NIC hang, OOM) |
| `scripts/check-rules.sh` | extracts `.spec` from each PrometheusRule CR and runs `promtool check`/`test` in Docker |
| `tests/rules/pve_rules_test.yml` | promtool unit tests for the dedup and template-exclusion logic |
| `ansible/roles/uptime-kuma/tasks/main.yml` | LXC creation, Docker, Kuma container, nightly DB backup |
| `ansible/playbooks/lxc/uptime-kuma.yml` | entry point for the above |
| `scripts/pve-rolling-upgrade.sh` | gains per-host Alertmanager silences |
| `docs/runbooks/alerting.md` | what each alert means and the first response |
| `docs/runbooks/uptime-kuma.md` | all 12 monitors + restore procedure |

---

## Task 1: Deploy-path prerequisites

Nothing else in this plan is safely deployable until these three defects are fixed. No alerting behaviour changes here — this task only makes `--tags monitoring` exist and work.

**Files:**
- Modify: `ansible/roles/rancher/tasks/main.yml` (Phase 9 block starting line 238; temp-file deletion at 266-269; redundant upgrade at 451-459)
- Modify: `kubernetes/monitoring/kube-prometheus-stack/values.yaml` (replace body with pointer)

**Interfaces:**
- Consumes: nothing.
- Produces: `ansible-playbook … --tags monitoring` deploys only monitoring; `pve_nodes`-driven scrape config covers 8 targets.

- [ ] **Step 1: Record the current broken state as the baseline**

```bash
cd /home/tfarias/homelab
export KUBECONFIG=~/.kube/config
kubectl --context homelab get pods -n monitoring | grep -c alertmanager    # expect 0
grep -n "tags:" ansible/roles/rancher/tasks/main.yml                       # expect only [hoa]
```

Expected: no Alertmanager pod, no `monitoring` tag anywhere.

- [ ] **Step 2: Add the `monitoring` tag to Phase 9 and Phase 10 tasks**

In `ansible/roles/rancher/tasks/main.yml`, add `tags: [monitoring]` to every task from `- name: Add prometheus-community Helm repo` (line ~241) through `- name: Apply PVE exporter deployment and service`. Also add it to the `- name: Copy kubernetes manifests to master node` task (line ~296), which currently carries `tags: [hoa]` — it becomes `tags: [hoa, monitoring]` because the monitoring tasks read manifests from `/tmp/homelab-k8s/`.

Example of the shape:

```yaml
- name: Render kube-prometheus-stack values
  template:
    src: kube-prometheus-stack-values.yml.j2
    dest: /tmp/kube-prometheus-stack-values.yml
    mode: '0600'
  tags: [monitoring]
```

- [ ] **Step 3: Fix the deleted values file**

Delete this task block (currently lines 266-269):

```yaml
- name: Remove kube-prometheus-stack values temp file
  file:
    path: /tmp/kube-prometheus-stack-values.yml
    state: absent
```

Delete the redundant second upgrade (currently lines 451-459), whose only purpose was adding the Loki datasource that the template already contains:

```yaml
- name: Upgrade kube-prometheus-stack to add Loki datasource
  command: >-
    helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack
    --namespace monitoring
    --version {{ kube_prometheus_stack_version }}
    --values /tmp/kube-prometheus-stack-values.yml
    --wait --timeout 10m
  environment:
    KUBECONFIG: /etc/rancher/k3s/k3s.yaml
```

Then add the deletion back at the very end, immediately before `- name: Display deployment summary`:

```yaml
- name: Remove kube-prometheus-stack values temp file
  file:
    path: /tmp/kube-prometheus-stack-values.yml
    state: absent
  tags: [monitoring]
```

- [ ] **Step 4: Replace the orphan values file with a pointer**

Overwrite `kubernetes/monitoring/kube-prometheus-stack/values.yaml` with exactly this:

```yaml
# NOT THE DEPLOYED CONFIG.
#
# The authoritative kube-prometheus-stack values live in the Ansible template:
#   ansible/roles/rancher/templates/kube-prometheus-stack-values.yml.j2
#
# That template is rendered with vault-encrypted vars (SMTP credentials, Grafana
# admin password) and the pve_nodes list, then passed to `helm upgrade --install`
# by ansible/roles/rancher/tasks/main.yml (tags: monitoring).
#
# This file previously held a stale copy of those values — including a Prometheus
# nodeSelector that was never applied, because nothing reads this path. It is kept
# only as a signpost so nobody edits it expecting a deployment to change.
```

- [ ] **Step 5: Verify the tag selects the right tasks and nothing else**

```bash
cd /home/tfarias/homelab/ansible
ansible-playbook playbooks/k3s/site.yml --tags monitoring --list-tasks 2>/dev/null \
  || ls playbooks/k3s/
```

Expected: only the monitoring/pve-exporter tasks plus the manifest-copy task are listed. **No Longhorn task, no Loki task, no Promtail task.** If the playbook path differs, find the playbook that includes the `rancher` role and use it consistently for the rest of this plan.

- [ ] **Step 6: Commit**

```bash
git add ansible/roles/rancher/tasks/main.yml kubernetes/monitoring/kube-prometheus-stack/values.yaml
git commit -m "fix: make monitoring deployable without re-running Longhorn and Loki

The monitoring phases carried no tags, so touching Prometheus meant running
the whole rancher role, which re-installs Longhorn and Loki — the thing that
has crashed etcd masters before.

Also fixes a helm upgrade that ran against a values file deleted 185 lines
earlier, and retires an orphan values.yaml that deployed nothing while
looking authoritative."
```

- [ ] **Step 7: Deploy and confirm the scrape targets go 6 → 8** **[CONFIRM]**

```bash
cd /home/tfarias/homelab/ansible
ansible-playbook playbooks/k3s/site.yml --tags monitoring --ask-vault-pass
```

Then:

```bash
export KUBECONFIG=~/.kube/config
kubectl --context homelab port-forward -n monitoring svc/kube-prometheus-stack-prometheus 19090:9090 &
sleep 5
curl -s --data-urlencode 'query=count(up{job="pve"})' localhost:19090/api/v1/query
kill %1
```

Expected: `8`. Before this change it was `6`.

---

## Task 2: PVE rules with promtool unit tests

Rules only — Alertmanager stays off, so nothing can email yet. This is deliberate: thresholds get calibrated against the real fleet before any delivery path exists.

**Files:**
- Create: `kubernetes/monitoring/rules/pve.yml`
- Create: `tests/rules/pve_rules_test.yml`
- Create: `scripts/check-rules.sh`
- Modify: `ansible/roles/rancher/tasks/main.yml` (add rule-apply task)

**Interfaces:**
- Consumes: `--tags monitoring` from Task 1.
- Produces: alerts labelled `pve_host`, `node`, `guest`, `severity` — Task 5's inhibition rules match on exactly these label names.

- [ ] **Step 1: Write the rule-checking harness**

Create `scripts/check-rules.sh`:

```bash
#!/usr/bin/env bash
#
# Lint and unit-test the PrometheusRule CRs.
#
# promtool cannot read a PrometheusRule CR directly — it expects a bare rule file
# (top-level `groups:`). This extracts .spec from each CR into a temp dir, then
# runs promtool from the official image so no local install is needed.
#
# Usage: ./check-rules.sh            # lint all rule CRs, then run unit tests
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1
RULES_DIR=kubernetes/monitoring/rules
TESTS_DIR=tests/rules
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

for f in "$RULES_DIR"/*.yml; do
  python3 - "$f" "$WORK/$(basename "$f")" <<'PY'
import sys, yaml
src, dst = sys.argv[1], sys.argv[2]
with open(src) as fh:
    cr = yaml.safe_load(fh)
with open(dst, "w") as fh:
    yaml.safe_dump({"groups": cr["spec"]["groups"]}, fh, sort_keys=False)
PY
  echo "extracted $(basename "$f")"
done

cp "$TESTS_DIR"/*.yml "$WORK/" 2>/dev/null || true

docker run --rm -v "$WORK:/work" -w /work --entrypoint promtool \
  prom/prometheus:latest check rules ./*.yml

for t in "$TESTS_DIR"/*_test.yml; do
  [ -e "$t" ] || continue
  echo "running unit tests: $(basename "$t")"
  docker run --rm -v "$WORK:/work" -w /work --entrypoint promtool \
    prom/prometheus:latest test rules "$(basename "$t")"
done
```

```bash
chmod +x scripts/check-rules.sh
```

- [ ] **Step 2: Write the failing unit tests**

Create `tests/rules/pve_rules_test.yml`. These encode the two pieces of non-obvious logic — cross-view dedup, and template/stopped-guest exclusion:

```yaml
---
rule_files:
  - pve.yml

evaluation_interval: 1m

tests:
  # A node is down only when EVERY surviving exporter view agrees.
  - interval: 1m
    input_series:
      - series: 'pve_up{id="node/pve06",instance="192.168.1.10",job="pve"}'
        values: '0+0x10'
      - series: 'pve_up{id="node/pve06",instance="192.168.1.11",job="pve"}'
        values: '0+0x10'
    alert_rule_test:
      - eval_time: 6m
        alertname: PVEHostDown
        exp_alerts:
          - exp_labels:
              severity: critical
              id: node/pve06
              pve_host: pve06
            exp_annotations:
              summary: "PVE host pve06 is down"
              description: "Every reporting pve-exporter view agrees node/pve06 is down. Guests on it are gone."

  # One dissenting view means no alert — do not page on a single stale exporter.
  - interval: 1m
    input_series:
      - series: 'pve_up{id="node/pve06",instance="192.168.1.10",job="pve"}'
        values: '0+0x10'
      - series: 'pve_up{id="node/pve06",instance="192.168.1.11",job="pve"}'
        values: '1+0x10'
    alert_rule_test:
      - eval_time: 6m
        alertname: PVEHostDown
        exp_alerts: []

  # Templates must never alert: template="1" in pve_guest_info.
  - interval: 1m
    input_series:
      - series: 'pve_up{id="qemu/9007",instance="192.168.1.10",job="pve"}'
        values: '0+0x15'
      - series: 'pve_onboot_status{id="qemu/9007",instance="192.168.1.10",job="pve"}'
        values: '1+0x15'
      - series: 'pve_guest_info{id="qemu/9007",instance="192.168.1.10",job="pve",node="pve05",name="debian12-template",template="1",type="qemu"}'
        values: '1+0x15'
    alert_rule_test:
      - eval_time: 12m
        alertname: PVEGuestDownUnexpectedly
        exp_alerts: []

  # An intentionally stopped guest (onboot=0) must never alert.
  - interval: 1m
    input_series:
      - series: 'pve_up{id="lxc/100",instance="192.168.1.10",job="pve"}'
        values: '0+0x15'
      - series: 'pve_onboot_status{id="lxc/100",instance="192.168.1.10",job="pve"}'
        values: '0+0x15'
      - series: 'pve_guest_info{id="lxc/100",instance="192.168.1.10",job="pve",node="pve03",name="immich",template="0",type="lxc"}'
        values: '1+0x15'
    alert_rule_test:
      - eval_time: 12m
        alertname: PVEGuestDownUnexpectedly
        exp_alerts: []

  # A real k3s VM going down must alert AND carry the k3s node name, because
  # inhibition keys on `node` to mute the whole k8s cascade.
  - interval: 1m
    input_series:
      - series: 'pve_up{id="qemu/116",instance="192.168.1.10",job="pve"}'
        values: '0+0x15'
      - series: 'pve_onboot_status{id="qemu/116",instance="192.168.1.10",job="pve"}'
        values: '1+0x15'
      - series: 'pve_guest_info{id="qemu/116",instance="192.168.1.10",job="pve",node="pve06",name="k3s-worker-3",template="0",type="qemu"}'
        values: '1+0x15'
    alert_rule_test:
      - eval_time: 12m
        alertname: PVEGuestDownUnexpectedly
        exp_alerts:
          - exp_labels:
              severity: critical
              id: qemu/116
              pve_host: pve06
              node: k3s-worker-3
              name: k3s-worker-3
            exp_annotations:
              summary: "PVE guest k3s-worker-3 (qemu/116) is down on pve06"
              description: "Guest has onboot=1 but is not running. It did not stop on purpose."

  # Storage alerts must name the host so inhibition can mute them on host death.
  - interval: 1m
    input_series:
      - series: 'pve_disk_usage_bytes{id="storage/pve01/local-lvm",instance="192.168.1.10",job="pve"}'
        values: '96+0x40'
      - series: 'pve_disk_size_bytes{id="storage/pve01/local-lvm",instance="192.168.1.10",job="pve"}'
        values: '100+0x40'
    alert_rule_test:
      - eval_time: 35m
        alertname: PVEStorageCritical
        exp_alerts:
          - exp_labels:
              severity: critical
              id: storage/pve01/local-lvm
              pve_host: pve01
            exp_annotations:
              summary: "PVE storage storage/pve01/local-lvm is 96% full"
              description: "Above 95%. Proxmox writes fail hard when a storage fills."
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
./scripts/check-rules.sh
```

Expected: FAIL — `kubernetes/monitoring/rules/pve.yml` does not exist yet, so extraction errors out.

- [ ] **Step 4: Write the PVE rules**

Create `kubernetes/monitoring/rules/pve.yml`:

```yaml
---
# PVE fleet rules.
#
# Every PVE series is duplicated across pve-exporter targets: each scraped host
# returns the WHOLE cluster (node/pve01..node/pve08). So every expression here
# aggregates with `max by (id)` — a node counts as down only when every surviving
# view agrees, which is corosync's own quorum truth rather than one host's opinion.
#
# Label contract (Alertmanager inhibition depends on these exact names):
#   pve_host — PVE hostname, e.g. pve06
#   node     — k3s node name, e.g. k3s-worker-3 (guest alerts only)
#   guest    — PVE guest id, e.g. qemu/116
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: pve-rules
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: pve.hosts
      rules:
        - alert: PVEHostDown
          expr: |
            label_replace(
              max by (id) (pve_up{id=~"node/.*"}) == 0,
              "pve_host", "$1", "id", "node/(.*)"
            )
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "PVE host {{ $labels.pve_host }} is down"
            description: "Every reporting pve-exporter view agrees {{ $labels.id }} is down. Guests on it are gone."

        - alert: PVEClusterNotQuorate
          expr: max by (id) (pve_up{id=~"cluster/.*"}) == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "PVE cluster {{ $labels.id }} lost quorum"
            description: "Corosync is not quorate. Expect a partition, not a single host failure."

        - alert: PVEHostMemoryPressure
          expr: |
            label_replace(
              max by (id) (
                pve_memory_usage_bytes{id=~"node/.*"} / pve_memory_size_bytes{id=~"node/.*"}
              ) > 0.92,
              "pve_host", "$1", "id", "node/(.*)"
            )
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "PVE host {{ $labels.pve_host }} memory at {{ $value | humanizePercentage }}"
            description: "Sustained above 92% for 30m. Guests risk OOM kills."

    - name: pve.guests
      rules:
        # onboot=1 is the intent signal: a guest that is supposed to start on boot
        # but is not running did not stop on purpose. template="1" excludes VM
        # templates. Together these need no hardcoded exclusion list.
        #
        # Label surgery matters here. In pve_guest_info, `node` is the PVE HOST
        # (pve06) and `name` is the guest (k3s-worker-3). Alertmanager inhibits the
        # k8s cascade by matching `node` against kubelet/kube-state-metrics alerts,
        # which use the k3s node name — so node must end up holding `name`, and the
        # PVE host moves to pve_host. Copy node -> pve_host FIRST, then overwrite
        # node from name; reversing the order loses the host.
        - alert: PVEGuestDownUnexpectedly
          expr: |
            label_replace(
              label_replace(
                (
                  max by (id) (pve_up{id=~"qemu/.*|lxc/.*"}) == 0
                  and on (id) max by (id) (pve_onboot_status) == 1
                )
                * on (id) group_left(node, name)
                  max by (id, node, name) (pve_guest_info{template="0"}),
                "pve_host", "$1", "node", "(.*)"
              ),
              "node", "$1", "name", "(.*)"
            )
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "PVE guest {{ $labels.name }} ({{ $labels.id }}) is down on {{ $labels.pve_host }}"
            description: "Guest has onboot=1 but is not running. It did not stop on purpose."

        - alert: PVEGuestOnbootDisabled
          expr: |
            label_replace(
              label_replace(
                (
                  max by (id) (pve_up{id=~"qemu/.*|lxc/.*"}) == 1
                  and on (id) max by (id) (pve_onboot_status) == 0
                )
                * on (id) group_left(node, name)
                  max by (id, node, name) (pve_guest_info{template="0"}),
                "pve_host", "$1", "node", "(.*)"
              ),
              "node", "$1", "name", "(.*)"
            )
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: "PVE guest {{ $labels.name }} ({{ $labels.id }}) is running with onboot=0"
            description: "It will NOT come back after {{ $labels.pve_host }} reboots. Fix with: qm set <vmid> --onboot 1"

    - name: pve.storage
      rules:
        - alert: PVEStorageCritical
          expr: |
            label_replace(
              max by (id) (
                pve_disk_usage_bytes{id=~"storage/.*"} / pve_disk_size_bytes{id=~"storage/.*"}
              ) > 0.95,
              "pve_host", "$1", "id", "storage/([^/]+)/.*"
            )
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "PVE storage {{ $labels.id }} is {{ $value | humanizePercentage }} full"
            description: "Above 95%. Proxmox writes fail hard when a storage fills."

        - alert: PVEStorageFillingUp
          expr: |
            label_replace(
              max by (id) (
                pve_disk_usage_bytes{id=~"storage/.*"} / pve_disk_size_bytes{id=~"storage/.*"}
              ) > 0.85,
              "pve_host", "$1", "id", "storage/([^/]+)/.*"
            )
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "PVE storage {{ $labels.id }} is {{ $value | humanizePercentage }} full"
            description: "Above 85%. Highest normal fill in this fleet is ~72% (pve01/pve02 local-lvm)."

    - name: pve.monitoring-health
      rules:
        # A rule whose metric vanished never fires and looks exactly like health.
        - alert: PVEMetricsAbsent
          expr: absent(pve_up)
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "pve_up has disappeared — PVE monitoring is blind"
            description: "pve-exporter is not producing metrics. Every PVE alert above is silently dead."

        - alert: PVEExporterTargetDown
          expr: |
            label_replace(
              up{job="pve"} == 0,
              "pve_host", "$1", "instance", "192.168.1.1([0-7])"
            )
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "pve-exporter cannot reach {{ $labels.instance }}"
            description: "One exporter view is gone. The other views still cover the fleet, so this is redundancy loss, not blindness."
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
./scripts/check-rules.sh
```

Expected: `SUCCESS: 0 rule files failed` for the lint, then `SUCCESS` for the unit tests. If the `PVEExporterTargetDown` regex assertion is the only failure, note that its `pve_host` derivation maps `192.168.1.1X` → `pveX` positionally; correct the replacement string until the test passes rather than changing the test's expectation.

- [ ] **Step 6: Add the rule-apply task to the Ansible role**

In `ansible/roles/rancher/tasks/main.yml`, immediately after `- name: Apply Grafana IngressRoute`, insert:

```yaml
- name: Apply Prometheus alerting rules
  command: k3s kubectl apply -f /tmp/homelab-k8s/monitoring/rules/
  environment:
    KUBECONFIG: /etc/rancher/k3s/k3s.yaml
  changed_when: false
  tags: [monitoring]
```

- [ ] **Step 7: Commit**

```bash
git add kubernetes/monitoring/rules/pve.yml tests/rules/pve_rules_test.yml \
        scripts/check-rules.sh ansible/roles/rancher/tasks/main.yml
git commit -m "feat: add PVE alerting rules with promtool unit tests

Each pve-exporter target returns the whole cluster view, so rules aggregate
with max by (id): a host counts as down only when every surviving exporter
agrees. Unit tests pin that behaviour, including the case where one view
dissents and must not page.

Guest-down uses onboot=1 plus template=0 as the intent signal, so VM
templates and deliberately stopped guests are excluded without a hardcoded
list."
```

- [ ] **Step 8: Deploy the rules** **[CONFIRM]**

```bash
cd /home/tfarias/homelab/ansible
ansible-playbook playbooks/k3s/site.yml --tags monitoring --ask-vault-pass
export KUBECONFIG=~/.kube/config
kubectl --context homelab get prometheusrule -n monitoring pve-rules
```

Expected: the CR exists. Alertmanager is still absent, so nothing can be delivered — correct at this stage.

---

## Task 3: Longhorn rules, cert-manager scraping, certificate rules

**Files:**
- Create: `kubernetes/monitoring/rules/longhorn.yml`
- Create: `kubernetes/monitoring/rules/certs.yml`
- Create: `kubernetes/monitoring/cert-manager/servicemonitor.yml`
- Modify: `ansible/roles/rancher/tasks/main.yml`

**Interfaces:**
- Consumes: the rule-apply task from Task 2.
- Produces: `LonghornVolumeFaulted`/`Degraded` with a `volume` label (Task 5 inhibits on it); `certmanager_*` metrics.

- [ ] **Step 1: Confirm cert-manager metrics do not exist yet**

```bash
export KUBECONFIG=~/.kube/config
kubectl --context homelab port-forward -n monitoring svc/kube-prometheus-stack-prometheus 19090:9090 &
sleep 5
curl -s 'localhost:19090/api/v1/label/__name__/values' | tr ',' '\n' | grep -c certmanager
kill %1
```

Expected: `0`. Any certificate rule written now would be permanently silent — that is why the ServiceMonitor comes first.

- [ ] **Step 2: Create the cert-manager ServiceMonitor**

```yaml
---
# cert-manager exposes metrics on 9402 but ships no ServiceMonitor by default,
# so certmanager_* series did not exist at all before this.
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: cert-manager
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
      - cert-manager
  selector:
    matchLabels:
      app.kubernetes.io/name: cert-manager
      app.kubernetes.io/component: controller
  endpoints:
    - port: http-metrics
      interval: 60s
      path: /metrics
```

- [ ] **Step 3: Write the Longhorn rules**

Create `kubernetes/monitoring/rules/longhorn.yml`:

```yaml
---
# Longhorn robustness encoding: 0=unknown, 1=healthy, 2=degraded, 3=faulted.
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: longhorn-rules
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: longhorn.volumes
      rules:
        - alert: LonghornVolumeFaulted
          expr: longhorn_volume_robustness == 3
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "Longhorn volume {{ $labels.volume }} is faulted"
            description: "All replicas are unavailable. The workload using it cannot read or write."

        # 20m rides out the rebuild churn a rolling host upgrade always causes.
        - alert: LonghornVolumeDegraded
          expr: longhorn_volume_robustness == 2
          for: 20m
          labels:
            severity: warning
          annotations:
            summary: "Longhorn volume {{ $labels.volume }} degraded for 20m"
            description: "Running on fewer replicas than configured and not rebuilding fast enough."

        - alert: LonghornNodeStorageFillingUp
          expr: |
            longhorn_node_storage_usage_bytes / longhorn_node_storage_capacity_bytes > 0.85
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "Longhorn storage on {{ $labels.node }} is {{ $value | humanizePercentage }} full"
            description: "Above 85%. Longhorn stops scheduling replicas before it fills completely."
```

- [ ] **Step 4: Write the certificate rules**

Create `kubernetes/monitoring/rules/certs.yml`:

```yaml
---
# Requires kubernetes/monitoring/cert-manager/servicemonitor.yml — without it
# these metrics do not exist and CertMetricsAbsent is what fires instead.
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cert-rules
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: certificates
      rules:
        - alert: CertExpiringSoon
          expr: |
            certmanager_certificate_expiration_timestamp_seconds - time() < 14 * 86400
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: "Certificate {{ $labels.name }} expires in under 14 days"
            description: "cert-manager has not renewed it yet. Every *.tmf-solutions.com route depends on the wildcard cert."

        - alert: CertRenewalFailed
          expr: |
            certmanager_certificate_ready_status{condition="False"} == 1
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: "Certificate {{ $labels.name }} is not ready"
            description: "Renewal is failing. Check the DNS-01 solver and the Cloudflare API token."

        - alert: CertMetricsAbsent
          expr: absent(certmanager_certificate_expiration_timestamp_seconds)
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: "cert-manager metrics have disappeared"
            description: "The certificate rules above are silently dead. Check the cert-manager ServiceMonitor."
```

- [ ] **Step 5: Lint everything**

```bash
./scripts/check-rules.sh
```

Expected: all three rule files pass lint; the Task 2 unit tests still pass.

- [ ] **Step 6: Add the ServiceMonitor apply task**

In `ansible/roles/rancher/tasks/main.yml`, immediately after the `Apply Prometheus alerting rules` task from Task 2:

```yaml
- name: Apply cert-manager ServiceMonitor
  command: k3s kubectl apply -f /tmp/homelab-k8s/monitoring/cert-manager/servicemonitor.yml
  environment:
    KUBECONFIG: /etc/rancher/k3s/k3s.yaml
  changed_when: false
  tags: [monitoring]
```

- [ ] **Step 7: Commit**

```bash
git add kubernetes/monitoring/rules/longhorn.yml kubernetes/monitoring/rules/certs.yml \
        kubernetes/monitoring/cert-manager/servicemonitor.yml ansible/roles/rancher/tasks/main.yml
git commit -m "feat: add Longhorn and certificate rules, scrape cert-manager

cert-manager exposes metrics on 9402 but ships no ServiceMonitor, so no
certmanager_* series existed and any certificate rule would have been
silent from birth. The ServiceMonitor lands with the rules that need it.

Longhorn degraded uses a 20m window so a rolling host upgrade's normal
rebuild churn does not page."
```

- [ ] **Step 8: Deploy and confirm the new metrics appear** **[CONFIRM]**

```bash
cd /home/tfarias/homelab/ansible
ansible-playbook playbooks/k3s/site.yml --tags monitoring --ask-vault-pass
export KUBECONFIG=~/.kube/config
kubectl --context homelab port-forward -n monitoring svc/kube-prometheus-stack-prometheus 19090:9090 &
sleep 5
curl -s 'localhost:19090/api/v1/label/__name__/values' | tr ',' '\n' | grep -c certmanager
kill %1
```

Expected: greater than `0`.

---

## Task 4: Observation window and threshold calibration

No code. This is the step that decides whether the finished system gets read or filtered, so it has its own gate.

**Files:**
- Modify: `kubernetes/monitoring/rules/*.yml` (only if observation says a threshold is wrong)

**Interfaces:**
- Consumes: rules deployed by Tasks 2-3.
- Produces: a tuned rule set, and the list of default rules to disable in Task 5.

- [ ] **Step 1: Record what is firing right now**

```bash
export KUBECONFIG=~/.kube/config
kubectl --context homelab port-forward -n monitoring svc/kube-prometheus-stack-prometheus 19090:9090 &
sleep 5
curl -s localhost:19090/api/v1/alerts | python3 -c '
import json,sys
d=json.load(sys.stdin)
for a in d["data"]["alerts"]:
    print(a["state"], a["labels"].get("severity","-"), a["labels"]["alertname"],
          a["labels"].get("pve_host") or a["labels"].get("node") or "")
' | sort | uniq -c | sort -rn
kill %1
```

Expected on a healthy fleet: `PVEGuestOnbootDisabled` firing for `qemu/117` and `qemu/118` (correct — Task 9 fixes the underlying config), plus whatever upstream defaults are chronically firing. Save this output.

- [ ] **Step 2: Wait 24-48 hours, then re-run Step 1**

Compare. Any alert firing in both samples on a healthy fleet is noise and must be either disabled (if it is an upstream default) or re-thresholded (if it is one of ours).

- [ ] **Step 3: Confirm the default-rule disable list against observation**

The spec names these for disabling: `kubeApiserverAvailability`, `kubeApiserverBurnrate`, `kubeApiserverHistogram`, `kubeApiserverSlos`, `kubernetesResources`, `kubernetesSystem`. Verify each actually fires here before disabling it, and add any other chronically-firing group found in Step 2:

```bash
export KUBECONFIG=~/.kube/config
kubectl --context homelab port-forward -n monitoring svc/kube-prometheus-stack-prometheus 19090:9090 &
sleep 5
curl -s localhost:19090/api/v1/rules | python3 -c '
import json,sys
d=json.load(sys.stdin)
for g in d["data"]["groups"]:
    firing=[r["name"] for r in g["rules"]
            if r.get("type")=="alerting" and r.get("state")=="firing"]
    if firing: print(g["name"], "->", firing)
'
kill %1
```

- [ ] **Step 4: Adjust any of our thresholds that proved wrong, then re-lint and commit**

```bash
./scripts/check-rules.sh
git add kubernetes/monitoring/rules/
git commit -m "tune: adjust alert thresholds against 48h of real fleet behaviour"
```

Skip the commit if nothing needed changing — that is a valid outcome and worth stating in the task notes rather than inventing a change.

---

## Task 5: Enable Alertmanager with SMTP, routing, and inhibition

The delivery path. After this task, alerts reach the inbox.

**Files:**
- Modify: `ansible/inventory/group_vars/all.yml`
- Modify: `ansible/roles/rancher/templates/kube-prometheus-stack-values.yml.j2`
- Create: `kubernetes/monitoring/alertmanager/ingressroute.yml`
- Create: `kubernetes/monitoring/alertmanager/basicauth.yml`
- Create: `ansible/roles/rancher/templates/alertmanager-basicauth-secret.yml.j2`
- Modify: `ansible/roles/rancher/tasks/main.yml`

**Interfaces:**
- Consumes: alerts labelled `pve_host`, `node`, `guest`, `volume`, `severity` from Tasks 2-3.
- Produces: a reachable Alertmanager at `https://alertmanager.tmf-solutions.com` (basic-auth) and at `alertmanager-operated.monitoring.svc:9093` in-cluster — Tasks 6-9 use both.

- [ ] **Step 1: Create the Gmail app password and add the vault vars**

Generate an app password at <https://myaccount.google.com/apppasswords> (requires 2FA on the account). **This credential grants send-as authority over the entire Gmail account — it goes in vault only, never in a `kubernetes/` manifest, because this repository is public.**

```bash
cd /home/tfarias/homelab/ansible
ansible-vault encrypt_string '<16-char-app-password>' --name alert_smtp_password
ansible-vault encrypt_string '<sending-address@gmail.com>' --name alert_smtp_user
ansible-vault encrypt_string '<recipient@address>' --name alert_email_to
ansible-vault encrypt_string '<basic-auth-password-for-alertmanager-ui>' --name alertmanager_basicauth_password
```

Paste each block into `ansible/inventory/group_vars/all.yml` alongside the existing vault vars, then add these plaintext vars near `grafana_hostname` (line ~56):

```yaml
alertmanager_hostname: "alertmanager.tmf-solutions.com"
alertmanager_basicauth_user: "admin"
```

- [ ] **Step 2: Enable Alertmanager in the values template**

In `ansible/roles/rancher/templates/kube-prometheus-stack-values.yml.j2`, replace the existing two-line `alertmanager: enabled: false` block (lines 4-5) with the following.

**Critical Jinja2 gotcha:** Alertmanager's own `{{ }}` templating collides with Ansible's. Every Go template expression is wrapped in `{% raw %}…{% endraw %}`. Omitting this makes the Ansible run fail with an undefined-variable error.

```yaml
alertmanager:
  enabled: true
  alertmanagerSpec:
    replicas: 1
    retention: 120h
    # emptyDir on purpose — NOT Longhorn. Longhorn degradation is one of the
    # things Alertmanager must report, so its state must not depend on Longhorn.
    # Cost: silences and dedup state are lost on restart (one repeat email).
    storage: {}
    resources:
      requests:
        cpu: 10m
        memory: 48Mi
      limits:
        memory: 128Mi
  config:
    global:
      resolve_timeout: 5m
      smtp_smarthost: 'smtp.gmail.com:587'
      smtp_from: '{{ alert_smtp_user }}'
      smtp_auth_username: '{{ alert_smtp_user }}'
      smtp_auth_password: '{{ alert_smtp_password }}'
      smtp_require_tls: true

    route:
      receiver: email-warning
      group_by: ['alertname', 'pve_host']
      group_wait: 45s
      group_interval: 5m
      repeat_interval: 24h
      routes:
        # Watchdog is the upstream always-firing heartbeat. Nothing consumes it
        # yet (no external dead-man's switch by decision), so drop it.
        - matchers: ['alertname="Watchdog"']
          receiver: 'null'
        - matchers: ['severity="info"']
          receiver: 'null'
        - matchers: ['severity="critical"']
          receiver: email-critical
          group_wait: 30s
          repeat_interval: 2h
        - matchers: ['severity="warning"']
          receiver: email-warning

    inhibit_rules:
      # A partition reads as one event, not eight host failures.
      - source_matchers: ['alertname="PVEClusterNotQuorate"']
        target_matchers: ['alertname="PVEHostDown"']

      # The k8s cascade is muted via `node`, which the guest alert carries from
      # pve_guest_info.name. No static IP-to-host map is needed anywhere.
      - source_matchers: ['alertname="PVEGuestDownUnexpectedly"']
        target_matchers: ['alertname!="PVEGuestDownUnexpectedly"']
        equal: ['node']

      # Host-level noise about a host already known to be down. PVEGuestDownUnexpectedly
      # is deliberately NOT a target: you want to know which guests died, and that
      # alert is the inhibitor for the k8s cascade rule above.
      - source_matchers: ['alertname="PVEHostDown"']
        target_matchers: ['alertname=~"PVEStorage.*|PVEHostMemoryPressure|PVEExporterTargetDown"']
        equal: ['pve_host']

      # While a node is down, mute pod-level churn cluster-wide. Coarse on
      # purpose: KSM pod alerts have no reliable node label. Trade-off is that an
      # unrelated pod problem can hide during a node outage — the runbook says to
      # re-check pods after recovery.
      - source_matchers: ['alertname=~"KubeNodeNotReady|KubeNodeUnreachable"']
        target_matchers: ['alertname=~"KubePod.*|KubeDeployment.*|KubeStatefulSet.*|KubeDaemonSet.*"']

      - source_matchers: ['severity="critical"']
        target_matchers: ['severity="warning"']
        equal: ['alertname', 'pve_host']

      - source_matchers: ['alertname="LonghornVolumeFaulted"']
        target_matchers: ['alertname="LonghornVolumeDegraded"']
        equal: ['volume']

    receivers:
      - name: 'null'

      - name: email-critical
        email_configs:
          - to: '{{ alert_email_to }}'
            send_resolved: true
            headers:
              subject: {% raw %}'[CRIT] {{ .CommonLabels.alertname }} {{ .CommonLabels.pve_host }}{{ .CommonLabels.node }}'{% endraw %}

            html: {% raw %}'{{ range .Alerts }}<b>{{ .Labels.alertname }}</b> ({{ .Labels.severity }})<br>{{ .Annotations.summary }}<br>{{ .Annotations.description }}<br>started {{ .StartsAt }}<br><br>{{ end }}'{% endraw %}


      - name: email-warning
        email_configs:
          - to: '{{ alert_email_to }}'
            send_resolved: true
            headers:
              subject: {% raw %}'[warn] {{ .CommonLabels.alertname }} {{ .CommonLabels.pve_host }}{{ .CommonLabels.node }}'{% endraw %}

            html: {% raw %}'{{ range .Alerts }}<b>{{ .Labels.alertname }}</b><br>{{ .Annotations.summary }}<br>{{ .Annotations.description }}<br>started {{ .StartsAt }}<br><br>{{ end }}'{% endraw %}
```

- [ ] **Step 3: Disable the noisy default rule groups and add the node-exporter relabel**

Still in the same template, add these two top-level blocks (place them after the `prometheus:` block). The `defaultRules` list is whatever Task 4 Step 3 confirmed:

```yaml
# k3s trips these permanently — a standing wall of firing alerts trains you to
# ignore email. Confirmed against 48h of live behaviour before disabling.
defaultRules:
  create: true
  rules:
    kubeApiserverAvailability: false
    kubeApiserverBurnrate: false
    kubeApiserverHistogram: false
    kubeApiserverSlos: false
    kubernetesResources: false
    kubernetesSystem: false

nodeExporter:
  enabled: true
  prometheus:
    monitor:
      relabelings:
        # node-exporter series carry only instance=IP:9100 by default, so
        # nothing could correlate them with a k3s node name. Inhibition and the
        # runbook both key on `node`.
        - source_labels: [__meta_kubernetes_pod_node_name]
          target_label: node
```

Also add the Prometheus node pin that the orphan values file documented but never applied — inside the existing `prometheus.prometheusSpec` block, above `retention`:

```yaml
    # Prometheus alone uses ~1.75Gi. Keep it off master-3, which is the tightest
    # host and also fronts the pfSense VM.
    nodeSelector:
      kubernetes.io/hostname: k3s-worker-2
```

- [ ] **Step 4: Create the basic-auth middleware and its secret template**

`ansible/roles/rancher/templates/alertmanager-basicauth-secret.yml.j2`:

```yaml
---
# Managed by Ansible. Credentials come from vault vars in group_vars/all.yml.
# Do NOT apply this file manually or commit rendered values.
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-basicauth
  namespace: monitoring
type: Opaque
stringData:
  users: "{{ alertmanager_basicauth_user }}:{{ alertmanager_basicauth_password | password_hash('bcrypt') }}"
```

`kubernetes/monitoring/alertmanager/basicauth.yml`:

```yaml
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: alertmanager-auth
  namespace: monitoring
spec:
  basicAuth:
    secret: alertmanager-basicauth
```

`kubernetes/monitoring/alertmanager/ingressroute.yml`:

```yaml
---
# Kuma runs outside the cluster and needs a reachable endpoint to probe.
# Basic-auth guards it; the silence UI becomes browser-usable as a side benefit.
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: alertmanager
  namespace: monitoring
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`alertmanager.tmf-solutions.com`)
      kind: Rule
      middlewares:
        - name: alertmanager-auth
      services:
        - name: alertmanager-operated
          port: 9093
  tls: {}  # uses TLSStore default — wildcard cert from traefik namespace
```

- [ ] **Step 5: Add the apply tasks**

In `ansible/roles/rancher/tasks/main.yml`, after the cert-manager ServiceMonitor task from Task 3:

```yaml
- name: Render Alertmanager basic-auth secret
  template:
    src: alertmanager-basicauth-secret.yml.j2
    dest: /tmp/alertmanager-basicauth-secret.yml
    mode: '0600'
  tags: [monitoring]

- name: Create Alertmanager basic-auth secret
  command: k3s kubectl apply -f /tmp/alertmanager-basicauth-secret.yml
  environment:
    KUBECONFIG: /etc/rancher/k3s/k3s.yaml
  changed_when: false
  tags: [monitoring]

- name: Remove Alertmanager basic-auth secret temp file
  file:
    path: /tmp/alertmanager-basicauth-secret.yml
    state: absent
  tags: [monitoring]

- name: Apply Alertmanager middleware and IngressRoute
  command: >-
    k3s kubectl apply
    -f /tmp/homelab-k8s/monitoring/alertmanager/basicauth.yml
    -f /tmp/homelab-k8s/monitoring/alertmanager/ingressroute.yml
  environment:
    KUBECONFIG: /etc/rancher/k3s/k3s.yaml
  changed_when: false
  tags: [monitoring]
```

- [ ] **Step 6: Dry-run the template render to catch Jinja/Go brace collisions before deploying**

```bash
cd /home/tfarias/homelab/ansible
ansible-playbook playbooks/k3s/site.yml --tags monitoring --check --diff --ask-vault-pass 2>&1 | tail -40
```

Expected: no `AnsibleUndefinedVariable`. If you see one naming something like `.CommonLabels`, a `{% raw %}` wrapper is missing.

- [ ] **Step 7: Commit**

```bash
git add ansible/inventory/group_vars/all.yml \
        ansible/roles/rancher/templates/kube-prometheus-stack-values.yml.j2 \
        ansible/roles/rancher/templates/alertmanager-basicauth-secret.yml.j2 \
        ansible/roles/rancher/tasks/main.yml \
        kubernetes/monitoring/alertmanager/
git commit -m "feat: enable Alertmanager with SMTP delivery and inhibition

Alertmanager state lives on emptyDir rather than Longhorn: Longhorn
degradation is one of the conditions it must report, so its own storage
must not be able to suppress that alert. The cost is losing silences on
restart, which is cheaper than a blind spot.

Inhibition keys on the node label that the guest-down alert derives from
pve_guest_info, so a host death produces two emails instead of thirty
without any static IP-to-hostname map to maintain."
```

- [ ] **Step 8: Deploy** **[CONFIRM]**

```bash
cd /home/tfarias/homelab/ansible
ansible-playbook playbooks/k3s/site.yml --tags monitoring --ask-vault-pass
export KUBECONFIG=~/.kube/config
kubectl --context homelab get pods -n monitoring | grep alertmanager
kubectl --context homelab get prometheus -n monitoring -o jsonpath='{.items[0].spec.nodeSelector}'; echo
```

Expected: `alertmanager-kube-prometheus-stack-alertmanager-0` Running 2/2, and the nodeSelector showing `k3s-worker-2`.

---

## Task 6: Prove delivery, routing, inhibition, and silences

Synthetic alerts only — no real failure needed. `amtool` is not installed locally, so this uses the HTTP API directly.

**Files:**
- Create: `scripts/alert-selftest.sh`

**Interfaces:**
- Consumes: Alertmanager from Task 5.
- Produces: `scripts/alert-selftest.sh`, reused by Task 9's silence work.

- [ ] **Step 1: Write the self-test script**

Create `scripts/alert-selftest.sh`:

```bash
#!/usr/bin/env bash
#
# Push synthetic alerts into Alertmanager to prove the delivery path without
# breaking anything real. Port-forwards rather than going through the ingress so
# the test does not depend on Traefik or DNS.
#
# Usage: ./alert-selftest.sh critical|warning|info|inhibit|silence
set -euo pipefail

KCTX=homelab
PORT=19093
AM="http://localhost:$PORT"

kubectl --context "$KCTX" port-forward -n monitoring svc/alertmanager-operated "$PORT:9093" \
  >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do
  curl -sf -m1 "$AM/-/ready" >/dev/null 2>&1 && break
  sleep 1
done

post_alert() {  # name severity extra_label_json
  curl -sf -XPOST "$AM/api/v2/alerts" -H 'Content-Type: application/json' -d "[{
    \"labels\": {\"alertname\": \"$1\", \"severity\": \"$2\", \"selftest\": \"true\" $3},
    \"annotations\": {\"summary\": \"synthetic $1\", \"description\": \"alert-selftest.sh — safe to ignore\"},
    \"startsAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
  }]" && echo "posted $1/$2"
}

case "${1:?usage: critical|warning|info|inhibit|silence}" in
  critical) post_alert SelfTestCritical critical ', "pve_host": "pve99"' ;;
  warning)  post_alert SelfTestWarning  warning  ', "pve_host": "pve99"' ;;
  info)     post_alert SelfTestInfo     info     ', "pve_host": "pve99"' ;;
  inhibit)
    # PVEGuestDownUnexpectedly must mute anything sharing its `node` label.
    post_alert PVEGuestDownUnexpectedly critical ', "node": "k3s-selftest", "pve_host": "pve99"'
    post_alert KubeNodeNotReady         warning  ', "node": "k3s-selftest"'
    sleep 5
    echo "--- alerts Alertmanager considers suppressed ---"
    curl -s "$AM/api/v2/alerts?silenced=false&inhibited=true" \
      | python3 -c 'import json,sys; [print(a["labels"]["alertname"]) for a in json.load(sys.stdin)]'
    ;;
  silence)
    ID=$(curl -sf -XPOST "$AM/api/v2/silences" -H 'Content-Type: application/json' -d "{
      \"matchers\": [{\"name\": \"pve_host\", \"value\": \"pve99\", \"isRegex\": false}],
      \"startsAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
      \"endsAt\": \"$(date -u -d '+10 min' +%Y-%m-%dT%H:%M:%SZ)\",
      \"createdBy\": \"alert-selftest\", \"comment\": \"selftest\"
    }" | python3 -c 'import json,sys; print(json.load(sys.stdin)["silenceID"])')
    echo "silence $ID created"
    post_alert SelfTestCritical critical ', "pve_host": "pve99"'
    sleep 5
    curl -s "$AM/api/v2/alerts?silenced=true" \
      | python3 -c 'import json,sys; [print("silenced:", a["labels"]["alertname"]) for a in json.load(sys.stdin)]'
    curl -sf -XDELETE "$AM/api/v2/silence/$ID" && echo "silence $ID deleted"
    ;;
esac
```

```bash
chmod +x scripts/alert-selftest.sh
```

- [ ] **Step 2: Prove a critical alert emails you** **[CONFIRM]**

```bash
./scripts/alert-selftest.sh critical
```

Expected: within ~1 minute, an email with subject starting `[CRIT] SelfTestCritical pve99`. If nothing arrives:

```bash
kubectl --context homelab logs -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 \
  -c alertmanager --tail=50 | grep -i 'smtp\|error'
```

Gmail rejecting the credential shows as `authentication failed`; a wrong port shows as a timeout.

- [ ] **Step 3: Prove warning routes and info drops**

```bash
./scripts/alert-selftest.sh warning
./scripts/alert-selftest.sh info
```

Expected: the warning arrives with an `[warn]` subject. **The info alert must produce no email at all** — it routes to the `null` receiver.

- [ ] **Step 4: Prove inhibition**

```bash
./scripts/alert-selftest.sh inhibit
```

Expected: the command prints `KubeNodeNotReady` as suppressed, and **only one** email arrives (for `PVEGuestDownUnexpectedly`). Two emails means the `equal: ['node']` inhibit rule is not matching — check that both synthetic alerts carry an identical `node` value.

- [ ] **Step 5: Prove silences work in both directions**

```bash
./scripts/alert-selftest.sh silence
```

Expected: prints `silenced: SelfTestCritical`, then deletes the silence. No email for the silenced alert.

- [ ] **Step 6: Confirm the ingress route and basic-auth**

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://alertmanager.tmf-solutions.com/-/healthy
curl -sk -u "admin:<password>" -o /dev/null -w '%{http_code}\n' https://alertmanager.tmf-solutions.com/-/healthy
```

Expected: `401` without credentials, `200` with them. Kuma will use the authenticated form in Task 8.

- [ ] **Step 7: Commit**

```bash
git add scripts/alert-selftest.sh
git commit -m "test: add Alertmanager self-test for delivery, routing, and inhibition

Pushes synthetic alerts through the API so the whole path can be proven
without stopping a real host. Port-forwards instead of using the ingress,
so a Traefik or DNS problem cannot be mistaken for a delivery problem."
```

---

## Task 7: Loki ruler for log-only failures

Catches the pve06 e1000e NIC hang at the first hang rather than at unreachability.

**Files:**
- Create: `kubernetes/monitoring/loki/ruler-rules.yml`
- Modify: `kubernetes/monitoring/loki/values.yaml` (documentation only — see note)
- Modify: `ansible/roles/rancher/tasks/main.yml`

**Interfaces:**
- Consumes: Alertmanager from Task 5 at `alertmanager-operated.monitoring.svc.cluster.local:9093`.
- Produces: `PVENICHang`, `PVEKernelOOM` alerts carrying `pve_host`.

- [ ] **Step 1: Confirm Loki has no Helm release, so patching is the only path**

```bash
helm list -A --kube-context homelab | grep -c loki
```

Expected: `0`. **Never run `helm upgrade` against Loki** — with resources present but no release record it fails, and `--install` would try to create existing objects.

- [ ] **Step 2: Confirm the log labels the rules will match**

```bash
export KUBECONFIG=~/.kube/config
kubectl --context homelab port-forward -n monitoring svc/loki 13100:3100 &
sleep 5
curl -s 'localhost:13100/loki/api/v1/label/job/values'
curl -s 'localhost:13100/loki/api/v1/label/host/values'
kill %1
```

Expected: `job` includes `kernel`, `syslog`, `auth`, `pve`; `host` lists `pve01`…`pve08`. The `host` value is exactly what `pve_host` needs.

- [ ] **Step 3: Write the ruler rules ConfigMap**

Create `kubernetes/monitoring/loki/ruler-rules.yml`:

```yaml
---
# Loki ruler rules. Mounted at /rules/fake/ — "fake" is the tenant id Loki uses
# when auth_enabled: false.
#
# These cover failures that produce no metric: the e1000e TX ring hang that took
# pve06 off the network on 2026-08-15 appears only as a kernel log line.
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-ruler-rules
  namespace: monitoring
data:
  pve-logs.yaml: |
    groups:
      - name: pve.kernel
        interval: 1m
        rules:
          - alert: PVENICHang
            expr: |
              sum by (host) (
                count_over_time({job="kernel"} |= "Detected Hardware Unit Hang" [10m])
              ) > 0
            for: 0m
            labels:
              severity: critical
              pve_host: '{{ $labels.host }}'
            annotations:
              summary: "e1000e NIC hang on {{ $labels.host }}"
              description: "Kernel reported a TX ring hang. This host drops off the network when it recurs. Mitigation is applied but the hardware fault is unrepaired."

          - alert: PVEKernelOOM
            expr: |
              sum by (host) (
                count_over_time({job="kernel"} |~ "Out of memory: Killed process" [15m])
              ) > 0
            for: 0m
            labels:
              severity: warning
              pve_host: '{{ $labels.host }}'
            annotations:
              summary: "OOM killer fired on {{ $labels.host }}"
              description: "A process was killed for memory. Check which guest or service grew."
```

- [ ] **Step 4: Add the ruler config to the running Loki**

The ruler stanza must exist in Loki's own config. Add it to `kubernetes/monitoring/loki/values.yaml` under the `loki:` key so the file stays truthful for any future reinstall:

```yaml
  ruler:
    enable_api: true
    storage:
      type: local
      local:
        directory: /rules
    rule_path: /tmp/loki-rules
    ring:
      kvstore:
        store: inmemory
    alertmanager_url: http://alertmanager-operated.monitoring.svc.cluster.local:9093
    enable_alertmanager_v2: true
```

Because there is no Helm release, apply it by patching the live ConfigMap and mounting the rules:

```bash
export KUBECONFIG=~/.kube/config
kubectl --context homelab get cm -n monitoring | grep loki
kubectl --context homelab get cm -n monitoring loki -o jsonpath='{.data}' | head -c 400; echo
```

Identify the ConfigMap holding `config.yaml`, then edit it to append the same `ruler:` block:

```bash
kubectl --context homelab edit cm -n monitoring loki
```

- [ ] **Step 5: Mount the rules ConfigMap into the StatefulSet** **[CONFIRM]**

```bash
export KUBECONFIG=~/.kube/config
kubectl --context homelab apply -f kubernetes/monitoring/loki/ruler-rules.yml

kubectl --context homelab patch statefulset loki -n monitoring --type=json -p='[
  {"op":"add","path":"/spec/template/spec/volumes/-",
   "value":{"name":"ruler-rules","configMap":{"name":"loki-ruler-rules"}}},
  {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-",
   "value":{"name":"ruler-rules","mountPath":"/rules/fake"}}
]'

kubectl --context homelab rollout status statefulset/loki -n monitoring --timeout=180s
```

- [ ] **Step 6: Verify the ruler loaded the rules**

```bash
export KUBECONFIG=~/.kube/config
kubectl --context homelab port-forward -n monitoring svc/loki 13100:3100 &
sleep 5
curl -s localhost:13100/loki/api/v1/rules
curl -s localhost:13100/prometheus/api/v1/rules | head -c 500; echo
kill %1
```

Expected: both rules listed. An empty response means the mount path is wrong — it must be `/rules/<tenant>` and the tenant is `fake` when `auth_enabled: false`.

- [ ] **Step 7: End-to-end drill with a synthetic kernel line** **[CONFIRM]**

```bash
cd /home/tfarias/homelab/ansible
ansible pve05 -m shell -a 'logger -p kern.err -t kernel "Detected Hardware Unit Hang TEST alert drill"'
```

Expected: within ~2-3 minutes an email `[CRIT] PVENICHang pve05`. This exercises promtail → Loki → ruler → Alertmanager → SMTP in one shot and changes nothing on the host.

If no email arrives, check in order:

```bash
export KUBECONFIG=~/.kube/config
kubectl --context homelab port-forward -n monitoring svc/loki 13100:3100 &
sleep 5
curl -sG 'localhost:13100/loki/api/v1/query_range' \
  --data-urlencode 'query={job="kernel"} |= "Hardware Unit Hang"' \
  --data-urlencode "start=$(date -u -d '-15 min' +%s)000000000" \
  --data-urlencode "end=$(date -u +%s)000000000" | head -c 300; echo
kill %1
```

No results means promtail did not ship it (remember: PVE promtail pushes through the Traefik ingress, so ingress must be up). Results but no email means the ruler or its Alertmanager URL is wrong.

- [ ] **Step 8: Commit**

```bash
git add kubernetes/monitoring/loki/ruler-rules.yml kubernetes/monitoring/loki/values.yaml
git commit -m "feat: alert on e1000e NIC hangs from kernel logs via Loki ruler

The pve06 fault that dropped the host off the network produces no metric —
only a kernel log line. This catches the first hang instead of waiting for
unreachability.

Applied by patching the live StatefulSet: Loki has no Helm release record,
so helm upgrade is not available for it."
```

---

## Task 8: Uptime Kuma LXC on pve01

The off-cluster path. Everything above dies with the cluster; this does not.

**Files:**
- Create: `ansible/roles/uptime-kuma/tasks/main.yml`
- Create: `ansible/roles/uptime-kuma/defaults/main.yml`
- Create: `ansible/playbooks/lxc/uptime-kuma.yml`
- Create: `docs/runbooks/uptime-kuma.md`
- Modify: `ansible/inventory/group_vars/all.yml`

**Interfaces:**
- Consumes: the authenticated Alertmanager endpoint from Task 5.
- Produces: a running Kuma at `http://192.168.1.21:3001`.

- [ ] **Step 1: Confirm the address and container id are still free**

```bash
ping -c1 -W1 192.168.1.21 >/dev/null 2>&1 && echo "IN USE — pick another" || echo "192.168.1.21 free"
cd /home/tfarias/homelab/ansible
ansible pve01 -m shell -a 'pct list; pveam list local | grep -c debian-12' 2>&1 | tail -5
```

Expected: `.21` free; `pct list` shows no CTID 102. If the Debian 12 template count is `0`, download it:

```bash
ansible pve01 -m shell -a 'pveam update && pveam download local debian-12-standard_12.7-1_amd64.tar.zst'
```

- [ ] **Step 2: Add the role defaults**

`ansible/roles/uptime-kuma/defaults/main.yml`:

```yaml
---
kuma_ctid: 102
kuma_hostname: uptime-kuma
kuma_ip: "192.168.1.21"
kuma_gateway: "192.168.1.1"
kuma_cidr: 24
kuma_cores: 1
kuma_memory_mb: 512
kuma_disk_gb: 4
kuma_bridge: vmbr0
kuma_storage: local-lvm
kuma_template: "local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
kuma_image: "louislam/uptime-kuma:1"
kuma_port: 3001
```

- [ ] **Step 3: Add the vars to group_vars**

In `ansible/inventory/group_vars/all.yml`, near the other hostnames:

```yaml
# Uptime Kuma — off-cluster watcher, LXC on pve01
kuma_lxc_host: pve01
kuma_hostname_fqdn: "uptime.tmf-solutions.com"
```

- [ ] **Step 4: Write the role**

`ansible/roles/uptime-kuma/tasks/main.yml`:

```yaml
---
# Creates the Uptime Kuma LXC on a PVE host and runs Kuma in Docker inside it.
#
# Docker inside an unprivileged LXC needs nesting=1 and keyctl=1 — without both,
# the Docker daemon fails to start with a cgroup or keyring error.
#
# onboot=1 is deliberate and load-bearing: a watcher that does not come back
# after a host reboot is worse than no watcher, because its silence reads as
# "everything is fine".

- name: Check whether the Kuma container already exists
  command: pct status {{ kuma_ctid }}
  register: kuma_status
  failed_when: false
  changed_when: false

- name: Create the Kuma LXC
  command: >-
    pct create {{ kuma_ctid }} {{ kuma_template }}
    --hostname {{ kuma_hostname }}
    --cores {{ kuma_cores }}
    --memory {{ kuma_memory_mb }}
    --rootfs {{ kuma_storage }}:{{ kuma_disk_gb }}
    --net0 name=eth0,bridge={{ kuma_bridge }},ip={{ kuma_ip }}/{{ kuma_cidr }},gw={{ kuma_gateway }}
    --features nesting=1,keyctl=1
    --onboot 1
    --unprivileged 1
    --start 1
  when: kuma_status.rc != 0

- name: Wait for the container to answer
  command: pct exec {{ kuma_ctid }} -- true
  register: kuma_ready
  retries: 15
  delay: 4
  until: kuma_ready.rc == 0
  changed_when: false

- name: Install Docker and sqlite3 inside the container
  command: >-
    pct exec {{ kuma_ctid }} -- bash -lc
    "apt-get update -qq &&
     DEBIAN_FRONTEND=noninteractive apt-get install -y -qq
     ca-certificates curl gnupg sqlite3 iputils-ping &&
     install -m 0755 -d /etc/apt/keyrings &&
     curl -fsSL https://download.docker.com/linux/debian/gpg
       -o /etc/apt/keyrings/docker.asc &&
     chmod a+r /etc/apt/keyrings/docker.asc &&
     echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc]
       https://download.docker.com/linux/debian bookworm stable'
       > /etc/apt/sources.list.d/docker.list &&
     apt-get update -qq &&
     DEBIAN_FRONTEND=noninteractive apt-get install -y -qq
     docker-ce docker-ce-cli containerd.io"
  args:
    creates: /dev/null
  register: docker_install
  changed_when: "'Setting up docker-ce' in docker_install.stdout"

- name: Run the Uptime Kuma container
  command: >-
    pct exec {{ kuma_ctid }} -- bash -lc
    "docker inspect uptime-kuma >/dev/null 2>&1 ||
     docker run -d --restart=always
       -p {{ kuma_port }}:3001
       -v uptime-kuma:/app/data
       --name uptime-kuma {{ kuma_image }}"
  register: kuma_run
  changed_when: "'Error' not in kuma_run.stderr"

- name: Install the nightly Kuma database backup
  copy:
    dest: /etc/cron.daily/kuma-db-backup
    mode: '0755'
    content: |
      #!/bin/sh
      # Kuma keeps every monitor definition in SQLite, outside git. This is the
      # only thing standing between a pve01 loss and re-clicking 12 monitors.
      set -e
      DEST=/var/lib/vz/dump/kuma
      mkdir -p "$DEST"
      pct exec {{ kuma_ctid }} -- docker exec uptime-kuma \
        sqlite3 /app/data/kuma.db ".backup /app/data/kuma-backup.db"
      pct pull {{ kuma_ctid }} /app/data/kuma-backup.db \
        "$DEST/kuma-$(date +%%Y%%m%%d).db"
      find "$DEST" -name 'kuma-*.db' -mtime +7 -delete

- name: Report how to reach Kuma
  debug:
    msg: "Uptime Kuma: http://{{ kuma_ip }}:{{ kuma_port }} — first visit creates the admin account"
```

`ansible/playbooks/lxc/uptime-kuma.yml`:

```yaml
---
# Off-cluster watcher for the fleet. Deliberately NOT in the k3s cluster: every
# in-cluster monitor dies with the thing it is supposed to report on.
- name: Provision the Uptime Kuma LXC
  hosts: "{{ kuma_lxc_host | default('pve01') }}"
  gather_facts: false
  roles:
    - uptime-kuma
```

- [ ] **Step 5: Run the playbook** **[CONFIRM]**

```bash
cd /home/tfarias/homelab/ansible
ansible-playbook playbooks/lxc/uptime-kuma.yml --ask-vault-pass
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.21:3001
```

Expected: `200` (or `302`). If Docker failed to start, confirm `nesting=1,keyctl=1` took effect:

```bash
ansible pve01 -m shell -a 'pct config 102 | grep features'
```

- [ ] **Step 6: Create the admin account and the SMTP notification**

Open <http://192.168.1.21:3001>, create the admin user, then **Settings → Notifications → Setup Notification**:
- Type: `Email (SMTP)`, Host `smtp.gmail.com`, Port `587`, Secure `STARTTLS`
- Username/Password: the same Gmail address and app password from Task 5 (read them from vault: `ansible-vault view` the encrypted strings — never copy them into a file)
- From/To: the same addresses as Alertmanager
- **Subject prefix `[KUMA]`** so the two alert paths are distinguishable in the inbox
- Set it as the default notification, then **Test** it and confirm the email arrives

- [ ] **Step 7: Create the 12 monitors**

All at **60s interval, 3 retries**, with the default notification enabled. ICMP monitors use hardcoded IPs on purpose — no DNS, no Traefik, no k3s in the probe path:

| Type | Target | Name |
|---|---|---|
| Ping | 192.168.1.10 | pve01 |
| Ping | 192.168.1.11 | pve02 |
| Ping | 192.168.1.12 | pve03 |
| Ping | 192.168.1.13 | pve04 |
| Ping | 192.168.1.14 | pve05 |
| Ping | 192.168.1.15 | pve06 |
| Ping | 192.168.1.16 | pve07 |
| Ping | 192.168.1.17 | pve08 |
| Ping | 192.168.1.1 | pfSense gateway |
| Ping | 1.1.1.1 | internet |
| HTTP(s) | `https://grafana.tmf-solutions.com` (accept 200-399) | grafana |
| HTTP(s) | `https://alertmanager.tmf-solutions.com/-/healthy` with basic-auth from Task 5 | alertmanager |

- [ ] **Step 8: Drill it**

Temporarily change the `pve07` monitor's hostname to `192.168.1.99`, save, and wait ~3 minutes.

Expected: a `[KUMA]` DOWN email. Then set it back to `192.168.1.16` and confirm the recovery email. This proves the second path end to end without touching a real host.

- [ ] **Step 9: Write the runbook**

Create `docs/runbooks/uptime-kuma.md` containing: the LXC facts (pve01, CTID 102, `192.168.1.21:3001`, `onboot=1`), the full 12-monitor table from Step 7 with intervals and retries, the SMTP notification settings (naming vault vars, never values), the nightly backup location (`/var/lib/vz/dump/kuma` on pve01, 7-day retention), and the restore procedure: re-run the playbook, then `pct push` the newest `.db` into `/app/data/kuma.db` and restart the container. State plainly that monitor definitions are not in git and this document is the reproduction path.

- [ ] **Step 10: Commit**

```bash
git add ansible/roles/uptime-kuma/ ansible/playbooks/lxc/uptime-kuma.yml \
        ansible/inventory/group_vars/all.yml docs/runbooks/uptime-kuma.md
git commit -m "feat: add off-cluster Uptime Kuma watcher in an LXC on pve01

Every existing monitor lives inside the cluster it watches, which is why
pve06 sat dead for 14 hours: Loki died with the host whose logs were
needed. This probes the fleet from outside k3s entirely.

ICMP checks target hardcoded IPs so the probe path contains no DNS, no
Traefik, and no k3s. onboot=1 because a watcher that does not return after
a reboot fails silently, and silence reads as health.

Monitor definitions live in Kuma's SQLite rather than git — the runbook
enumerates all 12 and a nightly backup covers the rest."
```

---

## Task 9: Retire the n8n watchdog, close the loose ends

**Files:**
- Modify: `scripts/pve-rolling-upgrade.sh`
- Create: `docs/runbooks/alerting.md`

**Interfaces:**
- Consumes: everything above.
- Produces: the finished system; no follow-on tasks depend on this.

- [ ] **Step 1: Fix the onboot flags found during design** **[CONFIRM]**

```bash
cd /home/tfarias/homelab/ansible
ansible pve07 -m shell -a 'qm set 117 --onboot 1'
ansible pve08 -m shell -a 'qm set 118 --onboot 1'
ansible pve07 -m shell -a 'qm config 117 | grep onboot'
ansible pve08 -m shell -a 'qm config 118 | grep onboot'
```

Expected: `onboot: 1` on both. `PVEGuestOnbootDisabled` should resolve within an hour, which also confirms that rule works against a real state change.

- [ ] **Step 2: Add pve07 to the rolling upgrade host list**

`scripts/pve-rolling-upgrade.sh` line ~23 lists only 7 hosts — pve07 was offline when it was written:

```bash
  HOSTS=(pve08 pve07 pve04 pve05 pve06 pve01 pve02 pve03)
```

pve07 stays early (workers first, lowest blast radius) and pve03 stays last because it runs pfSense.

- [ ] **Step 3: Add silence handling around each host**

In `scripts/pve-rolling-upgrade.sh`, after the `log()` definition, add:

```bash
AM_PF_PORT=19093
AM="http://localhost:$AM_PF_PORT"
AM_PF_PID=""

# Silence a host's alerts for the duration of its upgrade. Without this, every
# rolling upgrade emails a full set of host-down and Longhorn-degraded alerts
# that are expected and therefore trains you to ignore real ones.
am_start_portforward() {
  kubectl --context "$KCTX" port-forward -n monitoring svc/alertmanager-operated \
    "$AM_PF_PORT:9093" >/dev/null 2>&1 &
  AM_PF_PID=$!
  for _ in $(seq 1 20); do
    curl -sf -m1 "$AM/-/ready" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "   WARNING: cannot reach Alertmanager; upgrade will proceed unsilenced" >&2
  return 1
}

am_silence_create() {  # $1 = pve host
  curl -sf -XPOST "$AM/api/v2/silences" -H 'Content-Type: application/json' -d "{
    \"matchers\": [{\"name\": \"pve_host\", \"value\": \"$1\", \"isRegex\": false}],
    \"startsAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
    \"endsAt\": \"$(date -u -d '+45 min' +%Y-%m-%dT%H:%M:%SZ)\",
    \"createdBy\": \"pve-rolling-upgrade\",
    \"comment\": \"apt upgrade + reboot of $1\"
  }" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["silenceID"])' 2>/dev/null
}

am_silence_delete() {  # $1 = silence id
  [ -n "${1:-}" ] && curl -sf -XDELETE "$AM/api/v2/silence/$1" >/dev/null 2>&1
}
```

Call `am_start_portforward` once before the pre-flight health check, add `trap 'kill $AM_PF_PID 2>/dev/null' EXIT` beside it, and wrap the per-host loop body:

```bash
for h in "${HOSTS[@]}"; do
  log "=== $h : upgrade + reboot ==="
  SID=$(am_silence_create "$h")
  [ -n "$SID" ] && echo "   silenced $h alerts (id $SID)"
  if ! ansible-playbook playbooks/infra/pve-upgrade-reboot.yml --limit "$h"; then
    am_silence_delete "$SID"
    echo "ABORT: $h failed its upgrade/reboot. Fleet left partially upgraded." >&2
    echo "Remaining hosts not attempted: ${HOSTS[*]}" >&2
    exit 1
  fi
  log "$h back up; waiting for k3s + Longhorn to settle before the next host"
  if ! wait_cluster_healthy; then
    am_silence_delete "$SID"
    echo "ABORT: cluster did not return to health after $h." >&2
    exit 1
  fi
  am_silence_delete "$SID"
  echo "   silence for $h lifted"
done
```

The silence is lifted on the failure paths too — an abort leaves the fleet needing attention, which is exactly when alerts must not be muted.

- [ ] **Step 4: Verify the silence plumbing without running an upgrade**

```bash
cd /home/tfarias/homelab
bash -n scripts/pve-rolling-upgrade.sh && echo "syntax OK"
./scripts/alert-selftest.sh silence
```

Expected: syntax passes, and the self-test still proves create/mute/delete. (The self-test uses the same API calls the script now makes.)

- [ ] **Step 5: Deactivate the n8n watchdog** **[CONFIRM]**

In the n8n UI, open workflow `PVE Host Watchdog` (id `bbLA156cH6tPwRlC`) and toggle it **inactive**. Do not delete it — leaving it dormant costs nothing and preserves the SSH-probe logic if the new path ever needs a fallback.

Confirm Kuma is covering the same ground first:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.21:3001
```

- [ ] **Step 6: Write the alerting runbook**

Create `docs/runbooks/alerting.md` with: an architecture summary (two paths, what each covers, what neither covers), a table of every alert with its meaning and first response, how to silence during planned work (the browser UI at `alertmanager.tmf-solutions.com`, and that the upgrade script silences automatically), how to run `scripts/alert-selftest.sh` and `scripts/check-rules.sh`, the inhibition trade-off from Task 5 (pod-level alerts are muted cluster-wide while a node is down, so re-check pods after recovery), and the two known open gaps: nothing watches Kuma, and a site-wide outage silences both paths.

- [ ] **Step 7: Commit**

```bash
git add scripts/pve-rolling-upgrade.sh docs/runbooks/alerting.md
git commit -m "feat: silence alerts per host during rolling upgrades, add runbook

A rolling upgrade fires the full host-down and Longhorn-degraded set for
every host in turn. Expected alerts that arrive anyway are how an inbox
becomes noise, so the script now creates and lifts a per-host silence —
including on its abort paths, where alerts matter most.

Also adds pve07 to the host order; it was offline when the script was
written."
```

- [ ] **Step 8: Final end-to-end confirmation**

```bash
export KUBECONFIG=~/.kube/config
kubectl --context homelab get pods -n monitoring | grep -E 'alertmanager|prometheus-kube|loki'
kubectl --context homelab get prometheusrule -n monitoring | grep -E 'pve-rules|longhorn-rules|cert-rules'
curl -s -o /dev/null -w 'kuma:%{http_code}\n' http://192.168.1.21:3001
./scripts/check-rules.sh
```

Expected: Alertmanager/Prometheus/Loki Running, three custom rule CRs present, Kuma answering, all rule tests passing.

---

## Optional: real-failure drill

Not part of the plan's completion criteria. Run only with explicit approval, because it triggers a genuine Longhorn rebuild.

- [ ] **Stop the newest worker and watch what arrives** **[CONFIRM]**

```bash
cd /home/tfarias/homelab/ansible
ansible pve07 -m shell -a 'qm stop 117'
```

Expected after ~10 minutes: **exactly one** email, `[CRIT] PVEGuestDownUnexpectedly` naming `k3s-worker-4` on `pve07`, with the k8s node, pod, and Longhorn cascade inhibited. More than a couple of emails means an inhibit rule is not matching — compare the `node` label values on the alerts in Alertmanager's UI.

Restore:

```bash
ansible pve07 -m shell -a 'qm start 117'
export KUBECONFIG=~/.kube/config
kubectl --context homelab get nodes
kubectl --context homelab get volumes.longhorn.io -n longhorn-system \
  -o custom-columns=V:.metadata.name,R:.status.robustness --no-headers | grep -v healthy
```

Expected: node returns Ready, and no volume remains unhealthy.
