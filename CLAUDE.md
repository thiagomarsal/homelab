# Homelab Claude Code Configuration

This project is a personal homelab managed with Ansible and Kubernetes (k3s).
Global work standards from `~/.claude/CLAUDE.md` do not apply here.

---

## Kubernetes MCP Rules

- **Read operations** (`get`, `list`, `logs`, `describe`, `events`, `top`) may proceed without asking
- **Any write or mutating operation** (`apply`, `delete`, `patch`, `scale`, `rollout restart`, `cordon`, `drain`, `taint`) requires explicit user confirmation before executing
- **Context awareness**: Always confirm the active kubectl context before any operation. If the context is not clearly homelab (e.g. `homelab`, `k3s`, `default` pointing to 192.168.1.x), stop and ask before proceeding
- **Never switch kubectl context automatically** — context changes must be made explicitly by the user

---

## Infrastructure Overview

- **Cluster**: k3s on Proxmox VMs (homelab context in `~/.kube/config`)
- **Nodes**: k3s-master-1/2/3 (control-plane), k3s-worker-1 (on-demand, may be offline), k3s-worker-2 (always-on)
- **PVE hosts**: pve01–pve06 at 192.168.1.10–15 (bare-metal Proxmox hypervisors), all always-on
- **Ingress IP**: 192.168.1.61 (Traefik LoadBalancer, all `*.tmf-solutions.com` routes here)
- **Namespace layout**: `monitoring`, `networking`, `storage`, and per-app namespaces
- **IaC**: Ansible for bare-metal nodes (`ansible/`), raw manifests + HelmChartConfig for cluster (`kubernetes/`)

---

## General Rules

- Never hardcode secrets — use sealed secrets or vault-encrypted vars
- Do not commit plaintext credentials, tokens, or API keys
- Prefer editing existing files over creating new ones
- Ask before running any destructive Ansible task (`state: absent`, `apt: purge`, file deletion)
- Ask before running git add and commit
