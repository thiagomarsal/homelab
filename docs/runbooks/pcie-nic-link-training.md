# Runbook: NIC missing after a reboot (PCIe link training failure)

Distinct from `pve-nic-hang.md`. There the NIC exists and stops passing traffic;
here the NIC is **not on the PCI bus at all**, so the host boots without it.

## Symptom

- A `bridge-ports` interface is simply absent — `ip -br link` never lists it
- `ifup` fails at boot with `error: vmbr1: bridge port enp2s0 does not exist`
- Any guest bridged onto that interface has a dead network on that leg, while the
  guest itself is `running` and the host is quorate — so `pve-upgrade-reboot.yml`
  and `qm list` both look healthy
- Repeated **warm** reboots do not fix it

The 2026-09-01 case: the monthly patch rebooted pve03 at 02:39 and pfSense lost
its WAN. Three warm reboots (02:40, 08:38, 09:16) all came up without the card.
Internet was down for the whole site until the card was physically reseated.

## Confirm it

```bash
journalctl -b 0 -k | grep -c r8169            # 0 = the driver never even saw a device
journalctl -b 0 -k | grep '0000:00:1c.0'      # the root port, and whether it retrained
lspci -nnk | grep -i ethernet
```

A link-training failure looks like this — note the root port **is** enumerated,
it is only the downstream link that is dead, leaving the bus behind it empty:

```
pci 0000:00:1c.0: [8086:a116] type 01 class 0x060400 PCIe Root Port
pci 0000:00:1c.0: PCI bridge to [bus 02]
pci 0000:00:1c.0: removing 2.5GT/s downstream link speed restriction
pci 0000:00:1c.0: retraining failed
```

Compare against a healthy boot, which has no retrain lines and populates the bus:

```
pci 0000:02:00.0: [10ec:8125] type 00 class 0x020000 PCIe Endpoint
r8169 0000:02:00.0 eth0: RTL8125B, XID 641, IRQ 136
r8169 0000:02:00.0 enp2s0: renamed from eth0
```

## Cause

A warm reset leaves 3.3V on the M.2 slot and the platform never asserts a
fundamental reset to the card, so the controller stays in whatever state the
previous boot left it in and does not answer link training. Cutting power is what
clears it.

Two plausible-sounding causes that are **ruled out** on pve03, so don't spend time
on them:

- **Not ASPM.** The kernel logs `ACPI FADT declares the system doesn't support
  PCIe ASPM, so disable it`, so ASPM is already off globally. The r8169
  `can't disable ASPM; OS doesn't have ASPM control` line is cosmetic, and
  `pcie_aspm=off` on the cmdline would be a no-op.
- **Not Wake-on-LAN** holding the card in an aux-powered state. `ethtool enp2s0`
  reports `Wake-on: d` — already disabled.

## Recover

**Cold power cycle.** Not `reboot` — the machine must actually lose power:

```bash
# from the host, if you can still reach it (the LAN NIC is usually fine)
poweroff
# then pull power at the wall for ~10s, or hold the power button, and boot it
```

Physically reseating the M.2 card also works, and is what was done on
2026-09-01, but it is strictly more invasive than removing power.

Try the software recovery first — it is installed and costs seconds:

```bash
systemctl start pcie-nic-recovery.service
journalctl -t pcie-nic-recovery -b
```

## Mitigate

```bash
ansible-playbook playbooks/infra/pcie-nic-recovery.yml --limit pve03
ansible-playbook playbooks/infra/pcie-nic-recovery.yml          # whole pve group
```

Installs `pcie-nic-recovery.service`, which runs **before** `networking.service`
and, for any NIC recorded in `/etc/pcie-nic-recovery.conf` that is missing at
boot, resets its parent port's link state machine and rescans — escalating to
removing the port and re-enumerating from the root complex if a plain rescan is
not enough. If the card comes back after `ifup` has already run, it re-enslaves
it into the right bridge.

It is a no-op on a healthy boot: every action is gated on the interface already
being missing, so it never touches a working link. Only NICs behind a real PCIe
port are registered — a root-complex integrated NIC such as pve03's onboard
`eno1` has no parent port to reset and is filtered out at install time.

**This is best-effort, not a guarantee.** The slot has no software power control:

```bash
lspci -vv -s 00:1c.0 | grep SltCap        # PwrCtrl- HotPlug-
cat /sys/bus/pci/devices/0000:00:1c.0/firmware_node/power_resources_D0    # empty
```

With no ACPI power resources and no slot power control, nothing in Linux can drop
power to that slot. The service can only ask the port to retrain. When that fails
it says so and exits non-zero:

```
pcie-nic-recovery: FAILED to recover enp2s0; this slot has no software power
control, a COLD power cycle is required
```

so `systemctl --failed` shows it and the journal names the required action.

## Detection

Two places check this now, because the monthly patch does not go through the
Ansible play:

- **`n8n-apt-upgrade.sh`, `healthcheck` branch** — this is what the monthly n8n
  job actually calls after each reboot, so it is the one that matters for the
  unattended run. It used to test only `corosync` + `Quorate`, which is exactly
  why 2026-09-01 came back `HEALTHY` with the site offline. It now also fails on
  a bridge missing a port. Detail goes to **stderr and syslog, never stdout** —
  stdout stays exactly `HEALTHY` or `NOT_HEALTHY` so the existing n8n workflow
  keeps parsing it unchanged.
- **`pve-upgrade-reboot.yml`** — the same assertion for manual rolling upgrades,
  retrying 12 × 10s to let a slow NIC settle and to give
  `pcie-nic-recovery.service` its chance.

Re-deploy the wrapper after changing it:

```bash
ansible-playbook playbooks/infra/n8n-pve-access.yml
```

To exercise the check by hand, run the script directly as root with the branch
selected explicitly. **Never** probe it through the forced-command key — sshd
ignores the client's command and runs whatever branch the script decides, so a
"harmless" test can trigger a real `upgrade` and reboot:

```bash
SSH_ORIGINAL_COMMAND=healthcheck /usr/local/sbin/n8n-apt-upgrade.sh; echo "exit=$?"
```

Note the PVE hosts ship no logs to Loki (`promtail` has never worked there — PVE 9
is Debian 13 and `rsyslog` is inactive), so nothing alerts on the
`pcie-nic-recovery` journal tag. The n8n healthcheck going `NOT_HEALTHY` is the
signal that reaches a human.

## Affected hardware

pve03 only, so far: a **Realtek RTL8125B** (`10ec:8125`, `r8169`) in the M.2 slot
of a **Lenovo ThinkCentre M900 Tiny**, on chipset root port `00:1c.0`
(`8086:a116`, Q170/Skylake). BIOS `FWKTBFA` 1.191, 2022-06-23.

This is the host that runs pfSense, so its WAN leg is the site's internet. Treat
any reboot of pve03 as internet-affecting until the recovery service has been
proven against a real warm reboot.
