#!/usr/bin/env bash
set -euo pipefail

CONTEXT_NAME="homelab"
KUBECONFIG_FILE="${HOME}/.kube/config"
TEMP_FILE="$(mktemp /tmp/kubeconfig-homelab-XXXXXX.yaml)"

echo "Fetching kubeconfig from k3s-master-1..."
scp -i ~/.ssh/id_k3s tfarias@192.168.1.50:/etc/rancher/k3s/k3s.yaml "$TEMP_FILE"

# Point to HA VIP instead of localhost
sed -i 's|https://127.0.0.1:6443|https://192.168.1.60:6443|g' "$TEMP_FILE"

# Rename default context/cluster/user to homelab
sed -i "s/: default$/: ${CONTEXT_NAME}/g" "$TEMP_FILE"

# Merge into existing kubeconfig (preserves all existing contexts)
mkdir -p "$(dirname "$KUBECONFIG_FILE")"
if [ -f "$KUBECONFIG_FILE" ]; then
  KUBECONFIG="${KUBECONFIG_FILE}:${TEMP_FILE}" kubectl config view --flatten > "${TEMP_FILE}.merged"
  mv "${TEMP_FILE}.merged" "$KUBECONFIG_FILE"
else
  mv "$TEMP_FILE" "$KUBECONFIG_FILE"
fi

chmod 600 "$KUBECONFIG_FILE"
rm -f "$TEMP_FILE"

echo "Merged context '${CONTEXT_NAME}' into ${KUBECONFIG_FILE}"
echo ""
echo "To use this cluster:"
echo "  kubectl config use-context ${CONTEXT_NAME}"
echo "  kubectl config get-contexts"
