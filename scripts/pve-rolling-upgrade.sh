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
  HOSTS=(pve08 pve04 pve05 pve06 pve01 pve02 pve03)
fi

KCTX=homelab
log() { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

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

log "pre-flight cluster health check"
wait_cluster_healthy || { echo "ABORT: cluster not healthy before we started" >&2; exit 1; }

for h in "${HOSTS[@]}"; do
  log "=== $h : upgrade + reboot ==="
  if ! ansible-playbook playbooks/infra/pve-upgrade-reboot.yml --limit "$h"; then
    echo "ABORT: $h failed its upgrade/reboot. Fleet left partially upgraded." >&2
    echo "Remaining hosts not attempted: ${HOSTS[*]}" >&2
    exit 1
  fi
  log "$h back up; waiting for k3s + Longhorn to settle before the next host"
  if ! wait_cluster_healthy; then
    echo "ABORT: cluster did not return to health after $h." >&2
    exit 1
  fi
done

log "all hosts upgraded"
for h in "${HOSTS[@]}"; do
  ansible "$h" -m shell -a 'printf "  %-7s %-9s %s\n" "$(hostname)" \
    "$(pveversion|head -1|cut -d/ -f2|cut -d\  -f1)" "$(uname -r)"' 2>/dev/null \
    | grep -v '|' | grep -v '^$'
done
