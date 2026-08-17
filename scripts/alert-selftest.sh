#!/usr/bin/env bash
#
# Push synthetic alerts into Alertmanager to prove the delivery path without
# breaking anything real. Port-forwards rather than going through the ingress so
# the test does not depend on Traefik or DNS.
#
# Usage: ./alert-selftest.sh critical|warning|info|inhibit|silence
#
# Assumes GNU date (date -u -d '+10 min ...'). This runs on WSL/Debian, where
# GNU coreutils is the default, so it is fine here; it will not work as-is on
# macOS/BSD date.
set -euo pipefail

KCTX=homelab
# ClusterIP service for the kube-prometheus-stack Alertmanager (chart 83.7.0,
# verified in Task 5). Not "alertmanager-operated" — both exist, but this is
# the one the IngressRoute targets, so it is what should be exercised here.
SVC=kube-prometheus-stack-alertmanager
PORT=19093
AM="http://localhost:$PORT"

kubectl --context "$KCTX" port-forward -n monitoring "svc/$SVC" "$PORT:9093" \
  >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT

ready=false
for _ in $(seq 1 30); do
  if curl -sf -m1 "$AM/-/ready" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
if [[ "$ready" != true ]]; then
  echo "ERROR: Alertmanager at $AM did not become ready within 30s." >&2
  echo "  Check: kubectl --context $KCTX get pods,svc -n monitoring | grep -i alertmanager" >&2
  exit 1
fi

# POST a synthetic alert. Fails loudly (clear stderr message, non-zero exit)
# instead of leaving callers with an empty variable or a raw Python traceback
# from feeding an empty/error response into a JSON parser.
post_alert() {  # name severity extra_label_json
  local name="$1" severity="$2" extra="$3" resp
  if ! resp=$(curl -sf -m5 -XPOST "$AM/api/v2/alerts" -H 'Content-Type: application/json' -d "[{
    \"labels\": {\"alertname\": \"$name\", \"severity\": \"$severity\", \"selftest\": \"true\" $extra},
    \"annotations\": {\"summary\": \"synthetic $name\", \"description\": \"alert-selftest.sh — safe to ignore\"},
    \"startsAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
  }]" 2>&1); then
    echo "ERROR: POST $AM/api/v2/alerts failed for $name/$severity: $resp" >&2
    return 1
  fi
  echo "posted $name/$severity"
}

# GET alerts and print a labeled field via python3, without piping curl
# straight into python3 — pipefail plus a failed curl there would otherwise
# hand python3 an empty stdin, which surfaces as a confusing JSON traceback
# rather than a clear "Alertmanager did not respond" error.
get_alerts_field() {  # query_string print_prefix
  local qs="$1" prefix="$2" resp
  if ! resp=$(curl -sf -m5 "$AM/api/v2/alerts?$qs" 2>&1); then
    echo "ERROR: GET $AM/api/v2/alerts?$qs failed: $resp" >&2
    return 1
  fi
  printf '%s' "$resp" | python3 -c "
import json, sys
for a in json.load(sys.stdin):
    print('$prefix' + a['labels']['alertname'])
"
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
    get_alerts_field 'silenced=false&inhibited=true' ''
    ;;
  silence)
    silence_resp=$(curl -sf -m5 -XPOST "$AM/api/v2/silences" -H 'Content-Type: application/json' -d "{
      \"matchers\": [{\"name\": \"pve_host\", \"value\": \"pve99\", \"isRegex\": false}],
      \"startsAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
      \"endsAt\": \"$(date -u -d '+10 min' +%Y-%m-%dT%H:%M:%SZ)\",
      \"createdBy\": \"alert-selftest\", \"comment\": \"selftest\"
    }") || { echo "ERROR: POST $AM/api/v2/silences failed: $silence_resp" >&2; exit 1; }
    ID=$(printf '%s' "$silence_resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["silenceID"])') \
      || { echo "ERROR: could not parse silenceID from: $silence_resp" >&2; exit 1; }
    echo "silence $ID created"
    post_alert SelfTestCritical critical ', "pve_host": "pve99"'
    sleep 5
    get_alerts_field 'silenced=true' 'silenced: '
    curl -sf -m5 -XDELETE "$AM/api/v2/silence/$ID" && echo "silence $ID deleted"
    ;;
esac
