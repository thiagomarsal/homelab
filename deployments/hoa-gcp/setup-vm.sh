#!/bin/bash
# Run once on a fresh GCP e2-micro VM (Debian/Ubuntu)
set -euo pipefail

echo "==> Installing Docker..."
apt-get update -q
apt-get install -y ca-certificates curl gnupg lsb-release
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -q
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

echo "==> Adding swap (2GB) — required for e2-micro stability..."
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl vm.swappiness=10
  echo 'vm.swappiness=10' >> /etc/sysctl.conf
fi

echo "==> Creating app directory..."
mkdir -p /opt/hoa
cd /opt/hoa

echo "==> VM setup complete."
echo "Next: copy docker-compose.yml and .env to /opt/hoa, then run:"
echo "  docker compose up -d"
