#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../ansible"
echo "WARNING: This will completely destroy the k3s cluster!"
read -r -p "Are you sure? [y/N] " confirm
[[ "$confirm" == [yY] ]] || { echo "Aborted."; exit 1; }
ansible-playbook playbooks/k3s/reset.yml "$@"
