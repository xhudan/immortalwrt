# QDM530 A/B boot slots — switching between ImmortalWrt and the vendor firmware

The IPQ5018 QSDK layout is dual-boot: two rootfs partitions (`rootfs` / `rootfs_1`, e.g.
mtd15 / mtd16) plus a `BOOTCONFIG` struct in two redundant copies (`0:BOOTCONFIG` /
`0:BOOTCONFIG1`, e.g. mtd2 / mtd3) whose rootfs *primaryboot* flag tells the bootloader which
slot to boot. Installing ImmortalWrt to the *inactive* slot (see
[build-and-flash.md](build-and-flash.md) §4b) leaves the vendor firmware intact in the other
slot, so you can keep both and switch between them.

> **No recovery net without UART.** Switching only changes which slot boots; if the target
> slot cannot boot, only a serial console ([uart-console.md](uart-console.md)) can recover the
> board. Only ever switch to a slot that actually holds a bootable image.

## Which slot am I on, and what is in the other one?

A booted system is always presented to Linux as `rootfs`/`ubi0` regardless of the physical
slot, so identify firmware by `board_name`/`uname`, never by the slot name. From ImmortalWrt:

```sh
bootslot status
```
```
BOOTCONFIG rootfs flag = 1   (switch would set it to 0)
running rootfs = mtd15 ; the other slot = mtd16
other slot (mtd16) contents: OTHER-OS
```

`bootslot` identifies the other slot by its UBI **volume names**, not by magic (the vendor
kernel is also a FIT image, so magic cannot tell them apart):

- `kernel` + `rootfs` (+ `rootfs_data`) → **IMMORTALWRT**
- `ubi_rootfs` / `wifi_fw` / `bt_fw` → **OTHER-OS** (the vendor firmware)
- fewer than two volumes → **EMPTY** (switch refused)

## Switch FROM ImmortalWrt → the other slot  (`bootslot`)

ImmortalWrt has no `/proc/boot_info` (that is a QSDK vendor-kernel driver), so `bootslot`
edits the `BOOTCONFIG` struct on the mtd directly: it flips the rootfs flag (byte 128) in
**both** copies, written identically from one read of the active copy, then verifies the
read-back. Writing both copies identical keeps the bootloader's two copies consistent, so the
redundancy/age counter is left untouched.

```sh
bootslot switch     # refuses unless the other slot holds a valid UBI image
reboot              # boots the other slot
```

`bootslot switch` only rewrites `BOOTCONFIG`; nothing changes until you `reboot`. If the write
were somehow ignored the board just boots the current slot again (no harm). HW-verified on this
board to switch ImmortalWrt ⇄ the vendor slot.

## Switch FROM the vendor firmware → the other slot  (`/proc/boot_info`)

The vendor firmware *does* have `/proc/boot_info`, so use its own serializer there (never
hand-edit the struct on the vendor side). **You must also clear two U-Boot env flags**, or the
bootloader will wipe the slot you are leaving — see "Keeping both slots" below:

```sh
c=$(cat /proc/boot_info/rootfs/primaryboot); echo $((1-c)) > /proc/boot_info/rootfs/primaryboot
b0=$(sed -n 's/^mtd\([0-9]*\):.*"0:BOOTCONFIG".*/\1/p' /proc/mtd)
b1=$(sed -n 's/^mtd\([0-9]*\):.*"0:BOOTCONFIG1".*/\1/p' /proc/mtd)
cat /proc/boot_info/getbinary_bootconfig  > /tmp/bc0.bin; mtd write /tmp/bc0.bin /dev/mtd$b0
cat /proc/boot_info/getbinary_bootconfig1 > /tmp/bc1.bin; mtd write /tmp/bc1.bin /dev/mtd$b1
fw_setenv sys_upgrade 0      # <-- REQUIRED to keep ImmortalWrt in the other slot
fw_setenv sys_recovery 0     # <-- (see below)
reboot
```

(The vendor `/proc/mtd` labels these partitions UPPERCASE `0:BOOTCONFIG`; ImmortalWrt renders
them lowercase `0:bootconfig`. `bootslot` matches either case.)

## Keeping both slots: the bootloader auto-syncs them

The vendor U-Boot keeps the two rootfs slots **in sync** via `ql_partition_init`, driven by two
env flags in `0:appsblenv` (decoded from the `0:APPSBL` dump, HW-confirmed): `sys_upgrade=1` ⇒
mirror the active/primary slot over the backup; `sys_recovery=1` ⇒ restore the backup over the
primary. **The vendor firmware sets `sys_upgrade=1` on every boot.** So if you switch *away*
from vendor without clearing it, the next boot mirrors the now-active ImmortalWrt over the slot
that held vendor and **overwrites it** — this is why a naive round-trip ends with both slots
ImmortalWrt.

- **ImmortalWrt → vendor** (`bootslot switch`): no clear needed. ImmortalWrt never sets the
  flags, so the ImmortalWrt slot survives as a backup; the vendor slot simply boots.
- **vendor → ImmortalWrt**: you **must** `fw_setenv sys_upgrade 0; fw_setenv sys_recovery 0`
  before `reboot` (as above) to preserve the vendor slot. `tools/slot-install.sh` does this
  automatically.

With the clear, the inactive slot is a true dormant backup and survives normal reboots
(HW-verified: ImmortalWrt running + vendor in the backup slot, intact across a plain reboot).
`sys_upgrade`/`sys_recovery` are in `0:appsblenv` (mtd10), **not** the rootfs slots.

## Summary

| Booted in | Switch to the other slot with |
|---|---|
| ImmortalWrt | `bootslot switch` + `reboot` |
| Vendor firmware | `/proc/boot_info` flip **+ `fw_setenv sys_upgrade 0; fw_setenv sys_recovery 0`** + `reboot` |

Round-trip HW-verified (Oct 2026): ImmortalWrt → vendor (via `bootslot`) → ImmortalWrt (via
`/proc/boot_info` **with the env clear**), with the other firmware preserved intact in its slot
throughout and surviving a plain reboot. Omit the env clear on the vendor→ImmortalWrt leg and
the vendor slot is overwritten (both slots end up ImmortalWrt).

If both slots are already ImmortalWrt and you want the vendor firmware back in one of
them (from an MTD backup of the vendor rootfs), see **[restore-vendor.md](restore-vendor.md)**
(`tools/restore-vendor.sh`).
