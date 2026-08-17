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
# ID is set only by the `silence` case, once a silence has actually been
# created and its id parsed. Checking it here (rather than registering a
# second trap later, only after creation) means this single trap is correct
# on every exit path from the moment the script starts: it is a no-op for
# critical/warning/info/inhibit (ID never set), a no-op if silence creation
# itself fails (ID still unset), and a safety-net delete for any exit after
# creation succeeds — a failed post_alert, a failed query, Ctrl-C, or a bug —
# so a synthetic-test silence can never outlive the script and mute real
# alerts indefinitely.
trap 'kill $PF 2>/dev/null || true
  if [ -n "${ID:-}" ]; then
    curl -sf -m5 -XDELETE "$AM/api/v2/silence/$ID" >/dev/null 2>&1 \
      || echo "WARNING: could not delete silence $ID — DELETE IT MANUALLY: curl -XDELETE $AM/api/v2/silence/$ID" >&2
  fi' EXIT

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
# List alert names whose status.<field> is non-empty (optionally containing $2).
#
# NOTE: do NOT use the API's ?silenced=/?inhibited= query params to decide this.
# They are INCLUSIVE filters — "silenced=true" means "include silenced alerts in
# the results", not "return only silenced alerts". Reading them as exclusive
# makes this script report every active alert as silenced/suppressed, which is
# false evidence from the one tool whose job is proving alerting works.
# status.silencedBy / status.inhibitedBy are the authoritative fields.
alerts_with_status() {  # field [id_to_match] -> prints matching alert names
  local field="$1" want="${2:-}" resp
  if ! resp=$(curl -sf -m5 "$AM/api/v2/alerts" 2>&1); then
    echo "ERROR: GET $AM/api/v2/alerts failed: $resp" >&2
    return 1
  fi
  printf '%s' "$resp" | FIELD="$field" WANT="$want" python3 -c "
import json, os, sys
field, want = os.environ['FIELD'], os.environ['WANT']
for a in json.load(sys.stdin):
    ids = a['status'].get(field) or []
    if ids and (not want or want in ids):
        print(a['labels']['alertname'])
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
    # This is a real assertion, not just a printout: a self-test that cannot
    # fail is the failure mode this whole branch exists to eliminate. If
    # KubeNodeNotReady is missing from the inhibited set, the cascade is
    # broken and this must exit non-zero, loudly.
    suppressed=$(alerts_with_status inhibitedBy) || exit 1
    printf '%s\n' "$suppressed"
    if ! printf '%s\n' "$suppressed" | grep -qx 'KubeNodeNotReady'; then
      echo "ERROR: KubeNodeNotReady is not in the inhibited set — the node-down inhibition cascade is broken." >&2
      exit 1
    fi
    ;;
  silence)
    silence_resp=$(curl -sf -m5 -XPOST "$AM/api/v2/silences" -H 'Content-Type: application/json' -d "{
      \"matchers\": [{\"name\": \"pve_host\", \"value\": \"pve99\", \"isRegex\": false}],
      \"startsAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
      \"endsAt\": \"$(date -u -d '+10 min' +%Y-%m-%dT%H:%M:%SZ)\",
      \"createdBy\": \"alert-selftest\", \"comment\": \"selftest\"
    }") || { echo "ERROR: POST $AM/api/v2/silences failed: $silence_resp" >&2; exit 1; }
    # From here down, ID being non-empty is exactly the condition the EXIT
    # trap above checks. If the POST above failed, or the parse below fails,
    # ID stays unset and the trap stays a no-op — there is nothing to clean
    # up because no silence was created (or, for a parse failure, we hold no
    # id to delete it by; this is the one residual gap the API leaves us).
    ID=$(printf '%s' "$silence_resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["silenceID"])') \
      || { echo "ERROR: could not parse silenceID from: $silence_resp" >&2; exit 1; }
    echo "silence $ID created"
    post_alert SelfTestCritical critical ', "pve_host": "pve99"'
    sleep 5
    silenced=$(alerts_with_status silencedBy "$ID") || exit 1
    if [ -z "$silenced" ]; then
      echo "FAIL: silence $ID matched no alerts — expected at least SelfTestCritical" >&2
      exit 1
    fi
    echo "$silenced" | sed 's/^/  silenced by this silence: /'
    if curl -sf -m5 -XDELETE "$AM/api/v2/silence/$ID" >/dev/null 2>&1; then
      echo "silence $ID deleted"
      ID=""  # cleared so the EXIT trap does not redundantly retry a delete that already succeeded
    else
      echo "WARNING: explicit delete of silence $ID failed; the exit trap will retry it" >&2
    fi
    ;;
esac
