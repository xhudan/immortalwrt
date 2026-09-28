# QDM530 — restoring the vendor firmware to one A/B slot

How to put the **vendor firmware back into one rootfs slot** of a board whose both
slots are now ImmortalWrt, so it dual-boots again (one slot ImmortalWrt, one slot
vendor). Read [boot-slots.md](boot-slots.md) first for the A/B model and `bootslot`.

The idea is the mirror image of the non-UART install in
[build-and-flash.md](build-and-flash.md) §4: write the vendor UBI to the **inactive**
slot (the running ImmortalWrt slot is never touched), verify it, then flip the boot
pointer to it with `bootslot`.

> **No recovery net without UART.** If the restored vendor slot cannot boot, only a
> serial console ([uart-console.md](uart-console.md)) can recover it. Until the final
> flip you can still stay on the intact ImmortalWrt slot.

## What you need

- The board running **ImmortalWrt with the `bootslot` command** (a current image). Check
  with `bootslot status`; if "not found", flash a current ImmortalWrt first.
- A **vendor rootfs image** = a raw `dd` dump of the vendor `rootfs` mtd partition, e.g.
  `mtd15.bin` from an MTD backup taken while the board still ran the vendor firmware. It
  is a UBI image (starts with `UBI#`) carrying the vendor volumes `kernel`, `wifi_fw`,
  `bt_fw`, `ubi_rootfs`, `rootfs_data`.

> **Honest caveat.** The backup is a raw `dd` dump (no OOB); `ubiformat -f` rebuilds the
> UBI from its in-band headers, which *should* work but is **not HW-proven** on this
> board. Because it is written to the *inactive* slot, the risk is bounded — the running
> ImmortalWrt slot stays bootable and you can decline the flip.

## Which slot gets vendor

`bootslot` and the script always write the **inactive** slot (the one you are not booted
from). So **boot the slot you want to KEEP as ImmortalWrt first**, then the other
(inactive) slot is the one that receives vendor:

```sh
bootslot status
# flag = 1  -> booted slot 1; the inactive slot 0 will get vendor
# flag = 0  -> booted slot 0; if you'd rather keep this one, that's fine — the inactive
#              slot 1 gets vendor. To force vendor into a specific slot, `bootslot switch`
#              + reboot first so the slot you want overwritten becomes "the other slot".
```

## Automated (recommended): `tools/restore-vendor.sh`

Runs on the board. Modes mirror `slot-install.sh`:

```sh
# 1. copy the vendor dump to the board (from your PC):
ssh root@192.168.1.1 'cat > /tmp/vendor-rootfs.bin' < mtd15.bin

# 2. on the board — read-only check of the slot layout:
sh /tmp/restore-vendor.sh detect

# 3. write the inactive slot + verify vendor volumes, WITHOUT flipping yet:
sh /tmp/restore-vendor.sh stage /tmp/vendor-rootfs.bin <md5-optional>

# 4. full run: stage + verify + confirm (type YES) + flip to vendor + reboot:
sh /tmp/restore-vendor.sh /tmp/vendor-rootfs.bin <md5-optional>
```

The script finds the inactive slot by partition name + which mtd `ubi0` is on (robust to
any mtd numbering), refuses to write/flip unless the image is a UBI with a `ubi_rootfs`
volume, and only flips after you type `YES`. It flips with `bootslot switch`.

## Manual (if you prefer step by step)

```sh
# inactive slot = the rootfs/rootfs_1 mtd that ubi0 is NOT on
act=$(cat /sys/class/ubi/ubi0/mtd_num)
a=$(grep -i '"rootfs"'   /proc/mtd | cut -d: -f1 | tr -dc 0-9)
b=$(grep -i '"rootfs_1"' /proc/mtd | cut -d: -f1 | tr -dc 0-9)
[ "$a" = "$act" ] && inact=$b || inact=$a
echo "writing vendor to inactive mtd$inact (active mtd$act kept)"

ubidetach -p /dev/mtd$inact 2>/dev/null
ubiformat /dev/mtd$inact -f /tmp/vendor-rootfs.bin -y

# verify it is the vendor image (expect ubi_rootfs / wifi_fw / bt_fw)
ubidetach -d 9 2>/dev/null
ubiattach -m $inact -d 9 && ubinfo -a -d 9 | grep Name
ubidetach -d 9 2>/dev/null

# flip to the vendor slot + reboot
bootslot status      # confirm "other slot ... contents: OTHER-OS"
bootslot switch
reboot
```

## Going back to ImmortalWrt later

The vendor firmware has `/proc/boot_info`, so from the vendor side you install
ImmortalWrt into the inactive slot and flip using the vendor serializer — exactly the
non-UART flow in [build-and-flash.md](build-and-flash.md) §4b (or `slot-install.sh`).
The ImmortalWrt slot you kept also remains, so `bootslot switch` from vendor can simply
return to it as long as it is still there.
