#!/usr/bin/env bash
#
# Roll a PVE apt dist-upgrade + reboot across the fleet, one host at a time.
#
# Between hosts it waits for k3s to report every node Ready and for Longhorn to
# report every volume healthy. That gate is the point of the script: each PVE
# reboot takes its k3s guest with it, and starting the next host before Longhorn
# has rebuilt would risk two of three replicas being offline at once.
#
# Host order is deliberate:
#   - workers first (lowest blast radius)
#   - masters next, one at a time (etcd tolerates losing only one of three)
#   - pve03 LAST, because it runs the pfSense VM; rebooting it drops the router
#     and would break apt on every host after it
#
# Usage: ./pve-rolling-upgrade.sh [host ...]      (defaults to the order below)
set -uo pipefail

cd "$(dirname "$0")/../ansible" || exit 1

HOSTS=("${@:-}")
if [ -z "${HOSTS[0]:-}" ]; then
  HOSTS=(pve08 pve07 pve04 pve05 pve06 pve01 pve02 pve03)
fi

KCTX=homelab
log() { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

AM_PF_PORT=19093
AM="http://localhost:$AM_PF_PORT"
AM_PF_PID=""
SID=""

# Silence a host's alerts for the duration of its upgrade. Without this, every
# rolling upgrade emails a full set of host-down and Longhorn-degraded alerts
# that are expected and therefore trains you to ignore real ones.
#
# Never lets an Alertmanager problem block the upgrade: every curl here is
# best-effort (-sf, short timeout) and every caller treats "no silence" as a
# warning, not a reason to stop patching.
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
  curl -sf -m5 -XPOST "$AM/api/v2/silences" -H 'Content-Type: application/json' -d "{
    \"matchers\": [{\"name\": \"pve_host\", \"value\": \"$1\", \"isRegex\": false}],
    \"startsAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
    \"endsAt\": \"$(date -u -d '+45 min' +%Y-%m-%dT%H:%M:%SZ)\",
    \"createdBy\": \"pve-rolling-upgrade\",
    \"comment\": \"apt upgrade + reboot of $1\"
  }" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["silenceID"])' 2>/dev/null
}

am_silence_delete() {  # $1 = silence id
  [ -n "${1:-}" ] && curl -sf -m5 -XDELETE "$AM/api/v2/silence/$1" >/dev/null 2>&1
}

# Belt-and-braces cleanup for every exit path — normal completion, either
# ABORT branch below, and an operator Ctrl-C mid-host. $SID is whatever
# silence (if any) is currently open; deleting an empty/already-cleared SID
# is a no-op. This is the same pattern alert-selftest.sh uses and for the
# same reason: a lingering silence during a partially-upgraded fleet is
# exactly when alerts are needed most.
cleanup() {
  am_silence_delete "$SID"
  [ -n "$AM_PF_PID" ] && kill "$AM_PF_PID" 2>/dev/null
}
trap cleanup EXIT
# INT/TERM get their own trap that exits explicitly. Without this, a Ctrl-C
# during e.g. the wait_cluster_healthy sleep only interrupts that one sleep —
# bash resumes the script right after it once the (non-exiting) trap handler
# returns, which would leave the upgrade limping along unsilenced instead of
# actually stopping. Exiting here both stops the run and re-fires the EXIT
# trap above (harmless — cleanup is idempotent on an already-empty SID).
trap 'echo "interrupted; lifting any open silence and stopping" >&2; exit 130' INT TERM

wait_cluster_healthy() {
  local tries=60
  while [ $tries -gt 0 ]; do
    local notready volumes unhealthy
    notready=$(kubectl --context "$KCTX" get nodes --no-headers 2>/dev/null \
               | awk '$2!="Ready"' | wc -l)
    volumes=$(kubectl --context "$KCTX" get volumes.longhorn.io -n longhorn-system \
              --no-headers 2>/dev/null | wc -l)
    unhealthy=$(kubectl --context "$KCTX" get volumes.longhorn.io -n longhorn-system \
                -o custom-columns=R:.status.robustness --no-headers 2>/dev/null \
                | grep -cv '^healthy$')
    if [ "$notready" = "0" ] && [ "$volumes" -gt 0 ] && [ "$unhealthy" = "0" ]; then
      echo "   k3s all Ready, $volumes/$volumes Longhorn volumes healthy"
      return 0
    fi
    echo "   waiting: k3s notReady=$notready, longhorn unhealthy=$unhealthy ($tries left)"
    sleep 20
    tries=$((tries-1))
  done
  echo "   TIMED OUT waiting for cluster health" >&2
  return 1
}

am_start_portforward

log "pre-flight cluster health check"
wait_cluster_healthy || { echo "ABORT: cluster not healthy before we started" >&2; exit 1; }

for h in "${HOSTS[@]}"; do
  log "=== $h : upgrade + reboot ==="
  SID=$(am_silence_create "$h")
  [ -n "$SID" ] && echo "   silenced $h alerts (id $SID)"
  if ! ansible-playbook playbooks/infra/pve-upgrade-reboot.yml --limit "$h"; then
    am_silence_delete "$SID"
    SID=""
    echo "ABORT: $h failed its upgrade/reboot. Fleet left partially upgraded." >&2
    echo "Remaining hosts not attempted: ${HOSTS[*]}" >&2
    exit 1
  fi
  log "$h back up; waiting for k3s + Longhorn to settle before the next host"
  if ! wait_cluster_healthy; then
    am_silence_delete "$SID"
    SID=""
    echo "ABORT: cluster did not return to health after $h." >&2
    exit 1
  fi
  am_silence_delete "$SID"
  SID=""
  echo "   silence for $h lifted"
done

log "all hosts upgraded"
for h in "${HOSTS[@]}"; do
  ansible "$h" -m shell -a 'printf "  %-7s %-9s %s\n" "$(hostname)" \
    "$(pveversion|head -1|cut -d/ -f2|cut -d\  -f1)" "$(uname -r)"' 2>/dev/null \
    | grep -v '|' | grep -v '^$'
done
