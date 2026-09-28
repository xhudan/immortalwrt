#!/bin/sh
# QDM530 vendor-firmware restore — RUN ON IMMORTALWRT (the board must have `bootslot`).
#
# Writes a vendor rootfs image (a raw `dd` dump of the vendor "rootfs" mtd, e.g.
# mtd15.bin from an MTD backup) to the *inactive* A/B slot and flips BOOTCONFIG to it,
# so the board dual-boots again: one slot ImmortalWrt, one slot vendor. The running
# (active) slot is never touched, so everything up to the final flip is reversible.
#
#   *** NO RECOVERY NET WITHOUT UART ***
#   If the restored vendor slot fails to boot, only a serial console can recover it.
#   Until the flip you can still stay on the ImmortalWrt slot.
#
# The inactive slot is found the same way as slot-install.sh (by partition name + which
# mtd the running rootfs/ubi0 is on), so it is robust to any mtd numbering. Pick which
# slot gets vendor by booting the OTHER one first (see boot-slots.md): run `bootslot
# status`, and if you want vendor in the currently-active slot, `bootslot switch`+reboot
# first so it becomes the inactive one.
#
# Honest caveat: the backup is a raw dd dump (no OOB); `ubiformat -f` rebuilds UBI from
# the in-band headers, which *should* work but is not HW-proven on this board. Writing to
# the inactive slot keeps the risk bounded (the ImmortalWrt slot stays bootable).
#
# Modes:
#   sh restore-vendor.sh detect              # read-only: report the slot layout
#   sh restore-vendor.sh stage <img> [md5]   # detect + write inactive slot + verify (NO flip)
#   sh restore-vendor.sh       <img> [md5]   # detect + stage + verify + confirm + flip + reboot
#
# [md5] (optional) = the image's expected md5 (md5sum vendor-rootfs.bin on your PC).

log() { echo "[restore-vendor] $*"; }
die() { echo "[restore-vendor] ERROR: $*" >&2; exit 1; }

MODE=full
case "$1" in
	detect) MODE=detect ;;
	stage)  MODE=stage; IMG="$2"; EXP_MD5="$3" ;;
	*)      MODE=full;  IMG="$1"; EXP_MD5="$2" ;;
esac

command -v bootslot >/dev/null 2>&1 || die "no 'bootslot' command — this image is too old; flash a current ImmortalWrt first."

mtd_num_of() {   # $1 = partition label as printed in /proc/mtd (without quotes); case-insensitive
	grep -i "\"$1\"" /proc/mtd | sed -n 's/^mtd\([0-9][0-9]*\):.*/\1/p' | head -1
}

# ---- detect active/inactive rootfs slot (same logic as slot-install.sh) ----
a_mtd=$(mtd_num_of "rootfs"); b_mtd=$(mtd_num_of "rootfs_1")
[ -n "$a_mtd" ] && [ -n "$b_mtd" ] || die "could not find rootfs / rootfs_1 in /proc/mtd"
act=$(cat /sys/class/ubi/ubi0/mtd_num 2>/dev/null)
[ -n "$act" ] || act=$(dmesg 2>/dev/null | sed -n 's/.*ubi0: attached mtd\([0-9][0-9]*\).*/\1/p' | tail -1)
[ -n "$act" ] || die "could not determine the running rootfs mtd (ubi0)"
if [ "$a_mtd" = "$act" ]; then inact=$b_mtd; else inact=$a_mtd; fi
[ "$inact" != "$act" ] || die "inactive slot resolved to the active mtd ($act) — refusing"

log "running (ImmortalWrt, KEPT) rootfs = mtd$act"
log "==> vendor will be written to the INACTIVE slot = /dev/mtd$inact"
log "    (to put vendor in the other physical slot: bootslot switch + reboot first, then re-run)"

[ "$MODE" = detect ] && { log "detect-only — nothing written."; exit 0; }

# ---- verify the image ----
[ -n "$IMG" ] && [ -f "$IMG" ] || die "image not found: ${IMG:-<none>}  (usage: restore-vendor.sh <vendor-rootfs.bin> [md5])"
head4=$(dd if="$IMG" bs=4 count=1 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' ')
# UBI image magic is "UBI#" = 55 42 49 23; if `od` is absent, skip this soft check.
[ -z "$head4" ] || [ "$head4" = "55424923" ] || die "image does not start with UBI# magic (got $head4) — not a vendor rootfs UBI dump?"
md5=$(md5sum "$IMG" | cut -d' ' -f1)
log "image: $IMG   md5=$md5"
if [ -n "$EXP_MD5" ]; then
	[ "$md5" = "$EXP_MD5" ] || die "md5 mismatch (expected $EXP_MD5) — transfer corrupt, aborting"
	log "md5 matches expected — OK"
fi

# ---- write the INACTIVE slot (active untouched) ----
log "ubiformat /dev/mtd$inact (erases the inactive slot, writes the vendor UBI)"
ubidetach -p "/dev/mtd$inact" 2>/dev/null
ubiformat "/dev/mtd$inact" -f "$IMG" -y || die "ubiformat failed"

# ---- verify it really is the vendor firmware (by UBI volume names) ----
log "verifying the written slot holds vendor volumes..."
ubidetach -d 9 2>/dev/null
ubiattach -m "$inact" -d 9 >/dev/null 2>&1 || die "ubiattach failed on mtd$inact — written image is not a valid UBI"
vols=$(ubinfo -a -d 9 2>/dev/null | sed -n 's/^Name:[[:space:]]*//p' | tr '\n' ' ')
ubidetach -d 9 2>/dev/null
log "volumes: $vols"
echo "$vols" | grep -qi 'ubi_rootfs' || die "no 'ubi_rootfs' volume — this is NOT the vendor firmware; NOT flipping (still on ImmortalWrt)."
log "vendor volumes confirmed (ubi_rootfs present)."

if [ "$MODE" = stage ]; then
	log "stage-only: vendor written + verified on mtd$inact; boot pointer NOT changed."
	log "to switch later: bootslot switch  (then reboot)."
	exit 0
fi

# ---- confirm, then flip via bootslot ----
echo
echo "############################################################"
echo "#  POINT OF NO RETURN                                       #"
echo "#  About to switch boot to the vendor slot (mtd$inact).         "
echo "#  If vendor fails to boot there is NO recovery without a   #"
echo "#  UART/serial console. The ImmortalWrt slot stays intact   #"
echo "#  until you confirm.                                       #"
echo "############################################################"
printf "Type YES to flip to vendor and reboot: "
read ans
[ "$ans" = "YES" ] || die "aborted — nothing flipped (vendor is staged on mtd$inact)."

bootslot switch || die "bootslot switch failed — not rebooting; investigate."
log "BOOTCONFIG flipped to the vendor slot. Rebooting in 3s."
log "If it answers on neither vendor nor ImmortalWrt after ~3 min, the vendor slot failed to boot"
log "-> UART/TFTP recovery. To go back to ImmortalWrt from the vendor side, use its /proc/boot_info"
log "flip or the slot-install flow (see boot-slots.md / build-and-flash.md)."
sleep 3
reboot
