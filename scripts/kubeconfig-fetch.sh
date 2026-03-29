#!/usr/bin/env bash
set -euo pipefail

DEST="${KUBECONFIG:-$HOME/.kube/config}"
mkdir -p "$(dirname "$DEST")"

echo "Fetching kubeconfig from k3s-master-1..."
scp -i ~/.ssh/id_k3s tfarias@192.168.1.50:/etc/rancher/k3s/k3s.yaml "$DEST"
sed -i 's|https://127.0.0.1:6443|https://192.168.1.60:6443|g' "$DEST"
chmod 600 "$DEST"
echo "Kubeconfig saved to $DEST"
