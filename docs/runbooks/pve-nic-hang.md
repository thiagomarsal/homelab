# Runbook: PVE host alive but off the network (e1000e NIC hang)

> Not the same as a NIC that is **missing** after a reboot. If the interface does
> not exist at all and `ifup` says `bridge port <iface> does not exist`, that is a
> PCIe link-training failure — see `pcie-nic-link-training.md`.

## Symptom

A PVE host vanishes from the network but is clearly still running:

- Power LED on, disk activity LED flickering normally
- Ping fails, SSH fails with **"No route to host"**, `ip neigh` shows the IP as `FAILED`
- Corosync shows the node `disconnected`; the dashboard shows it offline
- Any k3s guest on that host goes `NotReady`
- The switch port still shows link

The host keeps running and writing to disk the entire time. It will **not** recover on
its own — the driver detects the fault but never resets the adapter.

## Confirm it

The host is unreachable over the network, so this has to wait until after a reboot,
or be run from a locally attached console:

```bash
journalctl -b -1 -k | grep -c "Detected Hardware Unit Hang"   # previous boot
journalctl -b  0 -k | grep -c "Detected Hardware Unit Hang"   # current boot
```

A confirmed hang looks like this, repeating every 2 seconds:

```
e1000e 0000:00:1f.6 nic0: Detected Hardware Unit Hang:
  TDH <a3>  TDT <54>  next_to_use <54>  next_to_clean <a2>
  next_to_watch.status <0>
  MAC Status <80083>  PHY Status <796d>
```

`TDH` stuck ahead of `TDT` with `next_to_clean` frozen means the transmit ring is
wedged. `PHY Status <796d>` means the physical link is still **up** — which is why the
switch sees link while nothing is transmitted.

## Recover

Reboot is the only recovery. Before cutting power, if you can attach a console, grab
`dmesg` — but the persistent journal survives a reboot, so little is lost either way.

After it boots, if the host does not rejoin the cluster, check for a stale corosync
config (this bites any node that was offline while cluster membership changed):

```bash
grep config_version /etc/corosync/corosync.conf          # on the offline node
grep config_version /etc/pve/corosync.conf               # on a healthy node
```

If they differ, corosync exits with
`[CMAP] Received config version (N) is different than my config version (M)! Exiting`:

```bash
cp -a /etc/corosync/corosync.conf /root/corosync.conf.bak
scp root@<healthy-node>:/etc/pve/corosync.conf /etc/corosync/corosync.conf
systemctl restart corosync && sleep 5 && systemctl restart pve-cluster
pvecm status | grep -E "Nodes|Quorate"
```

**Without quorum, Proxmox refuses to autostart guests** — a VM with `onboot: 1` stays
`stopped` until quorum returns, then starts by itself.

## Mitigate

Disable segmentation offload, the standard workaround for this errata:

```bash
ansible-playbook playbooks/infra/nic-offload-fix.yml --limit <host>
ansible-playbook playbooks/infra/nic-offload-fix.yml            # whole pve group
```

Installs `e1000e-offload-fix.service`, which reapplies `tso/gso/gro off` at every boot
and auto-detects the interface name (pve03 and pve05 use `eno1`, pve06-08 use `nic0`).
Runs `serial: 1` so a NIC reconfigure can never disturb quorum on two nodes at once.

## Affected hardware

Any host with an **Intel I219-LM** on the `e1000e` driver — **pve02, pve03, pve05,
pve06, pve07, pve08**. All shipped with offloads on. Only **pve01 and pve04** use
Realtek `r8169` NICs and are unaffected.

That ratio got worse on 2026-08-25: the replacement pve02 (ThinkCentre M80q) is
I219-LM, where the Kamrui E2 it replaced was Realtek. Six of eight hosts now share
this single failure mode. Since pve01 is itself a retirement candidate, **pve04 is
effectively the last immune host** — which is the argument for putting LAN DNS
there rather than on `e1000e` hardware.

pve03 is the one that matters most: it runs pfSense, so a hang there takes the whole
LAN's routing down, not just one k3s node. Replacing its chassis on 2026-08-24 (HP
EliteDesk 800 G2 DM → Lenovo ThinkCentre M900 Tiny) did **not** remove the exposure —
the M900 Tiny uses the same I219-LM. The mitigation survived the swap because it lives
on the transplanted boot disk.

Verified 2026-08-24 on the then-five, and again on the new pve02 when it joined
2026-08-25: unit `enabled` + `active`, `tso/gso/gro` all `off`, zero hang events on
the current boot. **Run this playbook against any newly added host before it takes
production load** — the mitigation is not part of `site.yml`.

## History

pve06 hung twice on kernel `7.0.14-5-pve`:

| Boot window | Hang events |
|---|---|
| 2026-08-02 16:46 → 08-08 16:00 | 0 (clean) |
| 2026-08-08 16:09 → 08-10 09:23 | 11,311 |
| 2026-08-10 09:24 → 08-16 11:23 | 25,710 (onset 08-15 21:06) |

Same kernel on the clean boot and both bad ones, and pve05 runs the identical kernel
and NIC without hanging — so this is **degrading hardware on pve06**, not a regression.
If pve06 hangs again with offloads disabled, replace the NIC (USB3 gigabit adapter) or
retire the host.

## Why guests stayed down for 14 hours

A StatefulSet pod holding an RWO Longhorn volume cannot be rescheduled while its
node is unreachable: kubelet never confirms the delete, so the pod sits in
`Terminating` and the volume stays attached to a node nobody can reach. `loki-0`,
`porquinho-postgres-0` and a Longhorn instance-manager were stuck this way for the
whole outage. This is true of **every** node, not just pve06 — it is not a
placement problem, so pinning or excluding nodes does not help.

Longhorn ships `node-down-pod-deletion-policy: do-nothing`, which is what allows
that. Changed 2026-08-16 to:

```bash
kubectl -n longhorn-system patch setting.longhorn.io node-down-pod-deletion-policy \
  --type=merge -p '{"value":"delete-statefulset-pod"}'
```

Longhorn now force-deletes StatefulSet pods on a confirmed-down node, releasing the
volume so the StatefulSet reschedules itself.

Longhorn here is a Rancher catalog app with `longhorn.default_setting: false`, so
the chart does not manage settings and this survives a chart upgrade. It is not
represented anywhere in this repo — reapply the command above if Longhorn is ever
reinstalled.

**Caveat specific to this hardware:** the e1000e hang leaves a host *running* with a
dead NIC rather than powered off, so the old pod may still be writing locally when
the replacement starts. Longhorn's RWO attachment guard is what prevents an actual
dual-mount; the safety margin is thinner than the default policy's. Accepted here
because a 14-hour blind outage is the worse risk.

## Detection

`PVE Host Watchdog` (n8n, id `bbLA156cH6tPwRlC`) SSH-probes every PVE host every 10
minutes via the `healthcheck` forced command and emails on state change — one alert
when a host goes unreachable, one when it recovers.

There is no earlier warning available: the hang wedges the NIC immediately and takes
the host off the network, so nothing in-band can report it. Unreachability is the
signal. Note the watchdog runs inside the cluster, so it cannot alert on a total
cluster outage.
