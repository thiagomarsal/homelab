#!/usr/bin/env bash
#
# Provision a k3s worker VM on a Proxmox host from a Debian 12 cloud-init template.
#
# The fleet had no VM templates — every node so far was built by hand. This script
# creates a reusable template once per PVE host (local-lvm is node-local storage, so
# the template cannot be shared across hosts) and then clones workers from it.
#
# VMIDs are unique cluster-wide, not per-node, so each host needs its own template
# VMID. Convention: 9000 + pve host number (pve07 -> 9007, pve08 -> 9008).
#
# Usage:
#   TEMPLATE_VMID=<id> ./pve-worker-provision.sh template <pve-host-ip>
#   TEMPLATE_VMID=<id> ./pve-worker-provision.sh clone    <pve-host-ip> <vmid> <name> <ip>
#
# Examples:
#   TEMPLATE_VMID=9007 ./pve-worker-provision.sh template 192.168.1.16
#   TEMPLATE_VMID=9007 ./pve-worker-provision.sh clone    192.168.1.16 117 k3s-worker-4 192.168.1.56
#   TEMPLATE_VMID=9008 ./pve-worker-provision.sh template 192.168.1.17
#   TEMPLATE_VMID=9008 ./pve-worker-provision.sh clone    192.168.1.17 118 k3s-worker-5 192.168.1.57
#
set -euo pipefail

# --- VM profile: matches the existing workers (VM 114/115/116) -------------------
TEMPLATE_VMID="${TEMPLATE_VMID:?set TEMPLATE_VMID (convention: 9000 + pve host number)}"
TEMPLATE_NAME="debian12-cloudinit"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
CORES="${CORES:-4}"
MEMORY="${MEMORY:-12288}"
DISK_SIZE="${DISK_SIZE:-100G}"
CIUSER="${CIUSER:-tfarias}"
GATEWAY="${GATEWAY:-192.168.1.1}"
NAMESERVER="${NAMESERVER:-192.168.1.5}"

# SSH access
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_k3s}"          # key used to reach the PVE host
CI_PUBKEY="${CI_PUBKEY:-$HOME/.ssh/id_k3s.pub}"  # key injected into the guest via cloud-init

IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
IMAGE_PATH="/var/lib/vz/template/iso/debian-12-genericcloud-amd64.qcow2"

die() { echo "error: $*" >&2; exit 1; }

pve_ssh() {
  local host="$1"; shift
  ssh -o ConnectTimeout=10 -i "$SSH_KEY" "root@${host}" "$@"
}

create_template() {
  local host="$1"
  [[ -f "$CI_PUBKEY" ]] || die "cloud-init public key not found: $CI_PUBKEY"

  echo ">> [${host}] creating template ${TEMPLATE_VMID} (${TEMPLATE_NAME})"

  # Push the pubkey separately — embedding it in the remote heredoc mangles it.
  pve_ssh "$host" "cat > /tmp/ci-authorized-key.pub" < "$CI_PUBKEY"

  pve_ssh "$host" bash -s <<EOF
set -euo pipefail

if qm status ${TEMPLATE_VMID} &>/dev/null; then
  echo "   template ${TEMPLATE_VMID} already exists — nothing to do"
  exit 0
fi

if [[ ! -f "${IMAGE_PATH}" ]]; then
  echo "   downloading Debian 12 genericcloud image"
  mkdir -p "\$(dirname "${IMAGE_PATH}")"
  wget -q --show-progress -O "${IMAGE_PATH}.part" "${IMAGE_URL}"
  mv "${IMAGE_PATH}.part" "${IMAGE_PATH}"
fi

qm create ${TEMPLATE_VMID} \
  --name ${TEMPLATE_NAME} \
  --cores ${CORES} \
  --cpu host \
  --memory ${MEMORY} \
  --balloon 0 \
  --numa 0 \
  --sockets 1 \
  --net0 virtio,bridge=${BRIDGE} \
  --scsihw virtio-scsi-pci \
  --agent enabled=1 \
  --serial0 socket \
  --vga serial0 \
  --ostype l26

qm importdisk ${TEMPLATE_VMID} "${IMAGE_PATH}" ${STORAGE}
qm set ${TEMPLATE_VMID} --scsi0 ${STORAGE}:vm-${TEMPLATE_VMID}-disk-0
qm set ${TEMPLATE_VMID} --boot order=scsi0
qm set ${TEMPLATE_VMID} --ide2 ${STORAGE}:cloudinit
qm set ${TEMPLATE_VMID} --ciuser ${CIUSER}
qm set ${TEMPLATE_VMID} --nameserver ${NAMESERVER}
qm set ${TEMPLATE_VMID} --sshkeys /tmp/ci-authorized-key.pub
# qemu-guest-agent is absent from the cloud image; without it PVE reports no guest IP.
qm set ${TEMPLATE_VMID} --ciupgrade 1

qm template ${TEMPLATE_VMID}
rm -f /tmp/ci-authorized-key.pub
echo "   template ${TEMPLATE_VMID} ready"
EOF
}

clone_worker() {
  local host="$1" vmid="$2" name="$3" ip="$4"

  echo ">> [${host}] cloning ${TEMPLATE_VMID} -> ${vmid} (${name} @ ${ip})"

  pve_ssh "$host" bash -s <<EOF
set -euo pipefail

qm status ${TEMPLATE_VMID} &>/dev/null || { echo "template ${TEMPLATE_VMID} missing — run 'template' first" >&2; exit 1; }

if qm status ${vmid} &>/dev/null; then
  echo "   VM ${vmid} already exists — refusing to overwrite" >&2
  exit 1
fi

qm clone ${TEMPLATE_VMID} ${vmid} --name ${name} --full --storage ${STORAGE}
qm set ${vmid} --cores ${CORES} --memory ${MEMORY} --balloon 0
qm set ${vmid} --ipconfig0 ip=${ip}/24,gw=${GATEWAY}
qm set ${vmid} --onboot 1
qm resize ${vmid} scsi0 ${DISK_SIZE}
qm start ${vmid}
echo "   VM ${vmid} started"
EOF

  echo ">> waiting for ${ip} to answer SSH"
  for _ in $(seq 1 60); do
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes \
         -i "$SSH_KEY" "${CIUSER}@${ip}" true &>/dev/null; then
      echo "   ${name} reachable at ${ip}"
      return 0
    fi
    sleep 10
  done

  die "${name} did not become reachable at ${ip} within 10 minutes"
}

main() {
  local action="${1:-}"
  case "$action" in
    template)
      [[ $# -eq 2 ]] || die "usage: $0 template <pve-host-ip>"
      create_template "$2"
      ;;
    clone)
      [[ $# -eq 5 ]] || die "usage: $0 clone <pve-host-ip> <vmid> <name> <ip>"
      clone_worker "$2" "$3" "$4" "$5"
      ;;
    *)
      die "usage: $0 {template|clone} ..."
      ;;
  esac
}

main "$@"
