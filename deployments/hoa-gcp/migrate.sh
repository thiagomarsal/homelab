#!/bin/bash
# Run from your LOCAL machine (WSL/Linux) to migrate homelab → GCP VM
# Prerequisites: kubectl configured for homelab, gcloud CLI authenticated
# Usage: GCP_IP=x.x.x.x GCP_USER=your_gcp_user ./migrate.sh
set -euo pipefail

GCP_IP="${GCP_IP:?Set GCP_IP=<vm-external-ip>}"
GCP_USER="${GCP_USER:?Set GCP_USER=<gcp-ssh-user>}"
GCP_DEST="${GCP_USER}@${GCP_IP}:/opt/hoa"
NAMESPACE="hoa"
WP_POD=$(kubectl get pod -n "$NAMESPACE" -l app=wordpress -o jsonpath='{.items[0].metadata.name}')
DB_POD=$(kubectl get pod -n "$NAMESPACE" -l app=mariadb -o jsonpath='{.items[0].metadata.name}')

echo "==> WordPress pod: $WP_POD"
echo "==> MariaDB pod:   $DB_POD"

echo "==> Dumping database..."
kubectl exec -n "$NAMESPACE" "$DB_POD" -- \
  mysqldump -u root --single-transaction wordpress > /tmp/hoa-db.sql
echo "    DB dump: /tmp/hoa-db.sql ($(wc -c < /tmp/hoa-db.sql) bytes)"

echo "==> Copying wp-content/uploads from pod..."
rm -rf /tmp/hoa-uploads
kubectl cp "$NAMESPACE/$WP_POD:/var/www/html/wp-content/uploads" /tmp/hoa-uploads

echo "==> Uploading DB dump to GCP VM..."
scp /tmp/hoa-db.sql "${GCP_DEST}/hoa-db.sql"

echo "==> Uploading uploads to GCP VM..."
rsync -az --progress /tmp/hoa-uploads/ "${GCP_DEST}/uploads/"

echo "==> Importing DB on GCP VM..."
ssh "${GCP_USER}@${GCP_IP}" bash <<'EOF'
  cd /opt/hoa
  # Wait for MariaDB to be ready
  until docker compose exec mariadb mariadb -u root -p"${DB_ROOT_PASSWORD}" -e "SELECT 1" &>/dev/null; do
    echo "Waiting for MariaDB..."; sleep 3
  done
  docker compose exec -T mariadb \
    mariadb -u root -p"${DB_ROOT_PASSWORD}" wordpress < hoa-db.sql
  echo "DB imported."
EOF

echo "==> Copying uploads into WordPress container..."
ssh "${GCP_USER}@${GCP_IP}" bash <<'EOF'
  WP_CONTAINER=$(docker compose -f /opt/hoa/docker-compose.yml ps -q wordpress)
  docker cp /opt/hoa/uploads/. "${WP_CONTAINER}:/var/www/html/wp-content/uploads/"
  docker exec "$WP_CONTAINER" chown -R www-data:www-data /var/www/html/wp-content/uploads
  echo "Uploads copied."
EOF

echo "==> Updating WordPress URLs to auburn-fields.com..."
ssh "${GCP_USER}@${GCP_IP}" bash <<'EOF'
  docker compose -f /opt/hoa/docker-compose.yml exec -T mariadb \
    mariadb -u root -p"${DB_ROOT_PASSWORD}" wordpress <<SQL
UPDATE wp_options SET option_value='https://auburn-fields.com'
  WHERE option_name IN ('siteurl','home');
UPDATE wp_posts SET post_content =
  REPLACE(post_content, 'hoa.tmf-solutions.com', 'auburn-fields.com');
UPDATE wp_postmeta SET meta_value =
  REPLACE(meta_value, 'hoa.tmf-solutions.com', 'auburn-fields.com');
SQL
  echo "URLs updated."
EOF

echo ""
echo "==> Migration complete."
echo "    Test at http://$GCP_IP before switching DNS."
echo "    When ready, set Cloudflare A record @ -> $GCP_IP (proxied)"
