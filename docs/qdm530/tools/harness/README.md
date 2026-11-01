# Failure-branch harness for the slot tooling

`slot-install.sh`, `restore-vendor.sh` and `bootslot` format slots and flip the boot
pointer. Their **failure** branches are the ones that decide whether a bad moment costs a
reboot or a board — and across several review rounds those branches were only ever read,
never run. Three times a fix to them introduced a new defect in the same file, every one of
them on a path that nothing had executed.

This runs them. Unmodified, against a fake board, in a mount namespace:

```sh
bash docs/qdm530/tools/harness/run.sh        # needs unprivileged user namespaces
```

`unshare -rm` gives a private mount namespace, `env.sh` builds `/proc/boot_info`,
`/proc/mtd`, `/dev/mtd*`, `/sys/class/ubi` and a stub `PATH`, and the scripts run as-is —
no test hooks in production code, so a path bug is still a path bug.

The stubs record what was called. `reboot` touches a marker instead of rebooting, which is
what makes the central assertion possible: **`fw_setenv` fails → the script must stop and
must NOT reboot**, with the success path asserted to reboot as the control. Without that
control the first assertion passes for a script that died anywhere earlier — which it did,
twice, while this was being written.

## What it covers

- argument validation before anything destructive (`primaryboot` not 0/1,
  `upgradepartition` not the rootfs pair, a required tool missing)
- the serialized BOOTCONFIG: truncated record, and the two copies disagreeing
- `fw_setenv` failure → no reboot, non-zero exit, and the message naming the risk
- a failing second BOOTCONFIG write → no reboot
- `slot-install.sh` and `bootslot` sharing one lock directory
- `restore-vendor.sh`: non-UBI image, an active mtd outside the rootfs pair, and an
  occupied scratch UBI — each refused *before* `ubiformat`
- `bootslot`: refuses a disagreeing pair

## What it does NOT cover

Everything about the hardware. `ubiformat` on real NAND, whether the bootloader honours
the descriptor, whether a written slot boots, power loss between the two BOOTCONFIG
writes, and `tftp-recovery-setup.sh` against a real interface. A green run here means the
logic behaves as intended on the paths listed above — nothing more.
