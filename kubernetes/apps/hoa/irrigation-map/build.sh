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
#
# The admin build's storage path stays under the old "irrigation-admin" name —
# it's Apache-denied and only ever reached through the plugin's URL gate
# (AF_IRR_PATH in irrigation-plugin.yaml), so the on-disk name is invisible to
# everyone and not worth re-touching. The public build's storage path IS the
# URL residents hit directly, so it moved to community-map/ to match the
# public rename.
sed 's/__MODE__/admin/g'  "$SRC" > "$DIST/irrigation-admin.html"
sed 's/__MODE__/public/g' "$SRC" > "$DIST/community-map.html"

# __AF_NONCE__ stays literal in both. The mu-plugin substitutes it at request
# time for the admin build; the public build never calls the save endpoint.
echo "built:"
echo "  $DIST/irrigation-admin.html"
echo "  $DIST/community-map.html"

[[ "${1:-}" == "deploy" ]] || exit 0

POD="$(kubectl get pods -n "$NAMESPACE" --context "$CONTEXT" \
        -l "$SELECTOR" -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$POD" ]] || { echo "no pod matching $SELECTOR" >&2; exit 1; }
echo "deploying to $POD"

# kubectl cp needs the destination directory to already exist.
kubectl exec -n "$NAMESPACE" --context "$CONTEXT" "$POD" -- \
  mkdir -p "$WPROOT/community-map"

kubectl cp --context "$CONTEXT" "$DIST/irrigation-admin.html" \
  "$NAMESPACE/$POD:$WPROOT/irrigation-admin/irrigation-admin.html"
kubectl cp --context "$CONTEXT" "$DIST/community-map.html" \
  "$NAMESPACE/$POD:$WPROOT/community-map/community-map.html"

kubectl exec -n "$NAMESPACE" --context "$CONTEXT" "$POD" -- \
  chown www-data:www-data \
    "$WPROOT/irrigation-admin/irrigation-admin.html" \
    "$WPROOT/community-map/community-map.html"

# Legacy path (pre-rename): 301 everything there to the new location, so any
# bookmark or external link to the old irrigation-maps/ URL keeps working.
# mod_rewrite (not RedirectMatch) because: (1) the html filename changed too
# (irrigation-map.html -> community-map.html), needing an explicit mapping,
# not just a directory swap, and (2) the site sits behind a TLS-terminating
# ingress, so Apache sees plain HTTP internally — a scheme-relative target
# would 301 to http:// and downgrade the connection. Forcing https explicitly
# is safe here since this site has no non-TLS entry point.
# The old html/geojson copies underneath are dead weight once the redirect is
# in place — removed below. zones.geojson.pre-migration.bak (the earlier
# controller/zone/head/light migration's rollback point) is left untouched.
cat > "$DIST/legacy-redirect.htaccess" <<'HTACCESS'
RewriteEngine On
RewriteRule ^irrigation-map\.html$ https://%{HTTP_HOST}/wp-content/uploads/community-map/community-map.html [R=301,L]
RewriteRule ^(.*)$ https://%{HTTP_HOST}/wp-content/uploads/community-map/$1 [R=301,L]
HTACCESS
kubectl cp --context "$CONTEXT" "$DIST/legacy-redirect.htaccess" \
  "$NAMESPACE/$POD:$WPROOT/irrigation-maps/.htaccess"
kubectl exec -n "$NAMESPACE" --context "$CONTEXT" "$POD" -- sh -c "
  chown www-data:www-data '$WPROOT/irrigation-maps/.htaccess'
  rm -f '$WPROOT/irrigation-maps/irrigation-map.html' \
        '$WPROOT/irrigation-maps/zones.geojson' \
        '$WPROOT/irrigation-maps/zones.geojson.bak'
"

echo "deployed"
