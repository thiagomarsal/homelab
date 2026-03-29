#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../ansible"
echo "Deploying k3s HA cluster..."
ansible-playbook playbooks/k3s/site.yml "$@"
