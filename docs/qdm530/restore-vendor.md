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
# 1. copy the dump AND the script to the board (from your PC) — an earlier version of
#    this block forgot the script, which is in this repo, not on the board:
ssh root@192.168.1.1 'cat > /tmp/vendor-rootfs.bin' < mtd15.bin
ssh root@192.168.1.1 'cat > /tmp/restore-vendor.sh'  < docs/qdm530/tools/restore-vendor.sh

# 2. on the board — read-only check of the slot layout:
sh /tmp/restore-vendor.sh detect

# 3. write the inactive slot + verify vendor volumes, WITHOUT flipping yet.
#    The md5 argument is optional; if you pass one it is the dump's md5. Do NOT type the
#    angle brackets — in a shell they are redirection:
sh /tmp/restore-vendor.sh stage /tmp/vendor-rootfs.bin 2f3a...   # or omit the md5

# 4. flip and reboot. NOTE: running the full command after step 3 formats and writes the
#    slot a SECOND time — step 3 is a dry run of the write, not a stage it reuses. Either
#    do step 3 alone and then flip manually, or skip straight to this:
sh /tmp/restore-vendor.sh /tmp/vendor-rootfs.bin 2f3a...         # or omit the md5
```

The script finds the inactive slot by partition name + which mtd `ubi0` is on (robust to
any mtd numbering), and only flips after you type `YES`. It flips with `bootslot switch`.

**What it does not do, despite an earlier claim here.** It does *not* refuse to write unless
the image is a UBI with a `ubi_rootfs` volume: that check happens **after** `ubiformat` has
already written the slot, so it can tell you the result was wrong but cannot stop it. The
preliminary magic check in front is skipped entirely when `od` is unavailable, which it is on
some images. So the slot's previous contents are gone either way — verify the dump on your PC
before copying it over, because the script cannot protect you from a bad one.

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
bootslot inspect     # confirm "other slot ... contents: OTHER-OS"
                     # (`status` is read-only now and does not attach UBI; `inspect` does.
                     #  OTHER-OS is a volume-name heuristic, not positive proof it is the
                     #  vendor firmware, and not proof that it boots)
bootslot switch
reboot
```

## Going back to ImmortalWrt later

From the vendor side you flip with the vendor serializer (`/proc/boot_info`) **and must clear
the two auto-sync flags** so the vendor slot is kept as a backup — the vendor firmware sets
`sys_upgrade=1` on every boot, and without the clear the next boot mirrors the now-active
ImmortalWrt over the vendor slot and wipes it:

```sh
c=$(cat /proc/boot_info/rootfs/primaryboot); echo $((1-c)) > /proc/boot_info/rootfs/primaryboot
b0=$(sed -n 's/^mtd\([0-9]*\):.*"0:BOOTCONFIG".*/\1/p' /proc/mtd)
b1=$(sed -n 's/^mtd\([0-9]*\):.*"0:BOOTCONFIG1".*/\1/p' /proc/mtd)
cat /proc/boot_info/getbinary_bootconfig  > /tmp/bc0.bin; mtd write /tmp/bc0.bin /dev/mtd$b0
cat /proc/boot_info/getbinary_bootconfig1 > /tmp/bc1.bin; mtd write /tmp/bc1.bin /dev/mtd$b1
fw_setenv sys_upgrade 0; fw_setenv sys_recovery 0        # REQUIRED to keep the vendor slot
reboot
```

If the ImmortalWrt slot you kept is still intact this just boots it; otherwise install
ImmortalWrt into the inactive slot first (the non-UART flow in
[build-and-flash.md](build-and-flash.md) §4b, or `slot-install.sh` — both clear the flags for
you). See [boot-slots.md](boot-slots.md) → "Keeping both slots". (`bootslot` is an ImmortalWrt
command and does **not** exist on the vendor side.)
