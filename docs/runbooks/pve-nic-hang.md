# Runbook: PVE host alive but off the network (e1000e NIC hang)

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
and auto-detects the interface name (pve05 uses `eno1`, pve06-08 use `nic0`). Runs
`serial: 1` so a NIC reconfigure can never disturb quorum on two nodes at once.

## Affected hardware

HP ProDesk 600 G4 DM with **Intel I219-LM** on the `e1000e` driver — pve05, pve06,
pve07, pve08. All shipped with offloads on.

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

## Detection

`PVE Host Watchdog` (n8n, id `bbLA156cH6tPwRlC`) SSH-probes every PVE host every 10
minutes via the `healthcheck` forced command and emails on state change — one alert
when a host goes unreachable, one when it recovers.

There is no earlier warning available: the hang wedges the NIC immediately and takes
the host off the network, so nothing in-band can report it. Unreachability is the
signal. Note the watchdog runs inside the cluster, so it cannot alert on a total
cluster outage.
