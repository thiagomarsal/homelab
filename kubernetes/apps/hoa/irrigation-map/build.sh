#!/usr/bin/env bash
# Build and deploy the Auburn Fields irrigation map.
#
#   ./build.sh          build both variants into ./dist
#   ./build.sh deploy   build, then kubectl cp into the WordPress pod
#
# One source, two outputs. The admin/public split is a single token swap, which
# is what stops the two deployed copies from drifting apart.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/irrigation-map.src.html"
DIST="$HERE/dist"

CONTEXT="${CONTEXT:-homelab}"
NAMESPACE="${NAMESPACE:-hoa}"
SELECTOR="${SELECTOR:-app=wordpress}"
WPROOT="/var/www/html/wp-content/uploads"

[[ -f "$SRC" ]] || { echo "missing source: $SRC" >&2; exit 1; }

mkdir -p "$DIST"

# The public build must not merely hide operational detail — it never receives
# it. loadCollection() filters on MODE, so the token swap is the whole gate.
sed 's/__MODE__/admin/g'  "$SRC" > "$DIST/irrigation-admin.html"
sed 's/__MODE__/public/g' "$SRC" > "$DIST/irrigation-map.html"

# __AF_NONCE__ stays literal in both. The mu-plugin substitutes it at request
# time for the admin build; the public build never calls the save endpoint.
echo "built:"
echo "  $DIST/irrigation-admin.html"
echo "  $DIST/irrigation-map.html"

[[ "${1:-}" == "deploy" ]] || exit 0

POD="$(kubectl get pods -n "$NAMESPACE" --context "$CONTEXT" \
        -l "$SELECTOR" -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$POD" ]] || { echo "no pod matching $SELECTOR" >&2; exit 1; }
echo "deploying to $POD"

kubectl cp --context "$CONTEXT" "$DIST/irrigation-admin.html" \
  "$NAMESPACE/$POD:$WPROOT/irrigation-admin/irrigation-admin.html"
kubectl cp --context "$CONTEXT" "$DIST/irrigation-map.html" \
  "$NAMESPACE/$POD:$WPROOT/irrigation-maps/irrigation-map.html"

kubectl exec -n "$NAMESPACE" --context "$CONTEXT" "$POD" -- \
  chown www-data:www-data \
    "$WPROOT/irrigation-admin/irrigation-admin.html" \
    "$WPROOT/irrigation-maps/irrigation-map.html"

echo "deployed"
