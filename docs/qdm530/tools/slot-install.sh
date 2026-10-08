#!/bin/sh
# QDM530 non-UART A/B slot installer — RUN ON THE VENDOR FIRMWARE (via `ssh -t`).
#
# Installs an ImmortalWrt factory.ubi by writing the *inactive* A/B rootfs slot and
# flipping the BOOTCONFIG boot pointer to it. The running (active) slot is never touched,
# so everything up to the final flip is reversible.
#
#   *** NO RECOVERY NET WITHOUT UART ***
#   If the new slot fails to boot, only a serial console can recover the board.
#
# Robust to any mtd numbering: the inactive slot is taken from /proc/boot_info's own
# `upgradepartition` and resolved to its mtd by NAME in /proc/mtd — so it works whether the
# rootfs pair is mtd15/16, mtd17/18, or anything else, and does NOT rely on ubi0 sysfs
# (/sys/class/ubi/ubi0/mtd_num is absent on some vendor kernels). A best-effort ubi0
# cross-check refuses to overwrite the running slot when it can be determined.
#
# Modes:
#   sh slot-install.sh detect                 # read-only: just report the slot layout
#   sh slot-install.sh stage  <img> [md5]     # detect + write inactive slot + verify (NO flip)
#   sh slot-install.sh        <img> [md5]     # detect + stage + verify + confirm + flip + reboot
#
# [md5] (optional) = the image's expected md5; if given, a transfer-corruption check aborts
# on mismatch. Get it on your PC with:  md5sum factory.ubi

log() { echo "[slot-install] $*"; }
die() { echo "[slot-install] ERROR: $*" >&2; exit 1; }

# ---- parse mode / args ----
MODE=full
case "$1" in
	detect) MODE=detect ;;
	stage)  MODE=stage; IMG="$2"; EXP_MD5="$3" ;;
	*)      MODE=full;  IMG="$1"; EXP_MD5="$2" ;;
esac

# ---- preconditions ----
[ -r /proc/boot_info/rootfs/primaryboot ] || die \
	"/proc/boot_info missing — this is not the QSDK vendor firmware (or the bootconfig driver is absent). Use UART/TFTP instead (see build-and-flash.md 4a)."

mtd_num_of() {   # $1 = partition label as printed in /proc/mtd (without quotes); case-insensitive
	grep -i "\"$1\"" /proc/mtd | sed -n 's/^mtd\([0-9][0-9]*\):.*/\1/p' | head -1
}

# ---- 1. detect the inactive A/B slot from /proc/boot_info ----
cur=$(cat /proc/boot_info/rootfs/primaryboot)                 # 0 or 1
other=$(cat /proc/boot_info/rootfs/upgradepartition)          # QSDK's own name for the inactive slot, e.g. rootfs_1
[ -n "$cur" ] && [ -n "$other" ] || die "could not read primaryboot/upgradepartition from /proc/boot_info"
inact=$(mtd_num_of "$other")
[ -n "$inact" ] || die "could not find the \"$other\" partition in /proc/mtd"
new=$(( 1 - cur ))

# best-effort safety: the running rootfs (ubi0) must not be the slot we are about to write.
# /sys/class/ubi/ubi0/mtd_num is absent on some vendor kernels, so this is skipped when the
# active mtd cannot be determined — upgradepartition is authoritative either way.
act=$(cat /sys/class/ubi/ubi0/mtd_num 2>/dev/null)
[ -n "$act" ] || act=$(dmesg 2>/dev/null | sed -n 's/.*ubi0: attached mtd\([0-9][0-9]*\).*/\1/p' | tail -1)
[ -z "$act" ] || [ "$act" != "$inact" ] || die "upgradepartition ($other = mtd$inact) is the RUNNING rootfs (ubi0) — refusing to overwrite the active slot"

bc0_mtd=$(mtd_num_of "0:BOOTCONFIG")
bc1_mtd=$(mtd_num_of "0:BOOTCONFIG1")
[ -n "$bc0_mtd" ] && [ -n "$bc1_mtd" ] || die "could not find 0:BOOTCONFIG / 0:BOOTCONFIG1 in /proc/mtd"

log "primaryboot=$cur   running rootfs = mtd${act:-unknown}"
log "inactive slot (upgradepartition \"$other\") = mtd$inact"
log "BOOTCONFIG: mtd$bc0_mtd + mtd$bc1_mtd (backup)"
log "==> INACTIVE slot to write = /dev/mtd$inact   ;   will set primaryboot=$new to boot it"

[ "$MODE" = detect ] && { log "detect-only mode — nothing written."; exit 0; }

# ---- 2. verify the image ----
[ -n "$IMG" ] && [ -f "$IMG" ] || die "image not found: ${IMG:-<none>}  (usage: slot-install.sh <factory.ubi> [md5])"
md5=$(md5sum "$IMG" | cut -d' ' -f1)
log "image: $IMG   md5=$md5"
if [ -n "$EXP_MD5" ]; then
	[ "$md5" = "$EXP_MD5" ] || die "md5 mismatch (expected $EXP_MD5) — transfer is corrupt, aborting (nothing written)"
	log "md5 matches expected — OK"
else
	log "no expected md5 given — compare the above with your local md5sum before trusting it."
fi

# ---- 3. write the INACTIVE slot (active slot untouched) ----
log "ubiformat /dev/mtd$inact  (erases the whole inactive partition, purging any vendor volumes)"
ubidetach -p "/dev/mtd$inact" 2>/dev/null
ubiformat "/dev/mtd$inact" -f "$IMG" -y || die "ubiformat failed"

log "sanity-checking the staged slot (read-only)..."
ubidetach -d 9 2>/dev/null
ubiattach -m "$inact" -d 9 >/dev/null 2>&1 || die "ubiattach failed on mtd$inact"
vols=$(ubinfo -a -d 9 2>/dev/null | sed -n 's/^Name:[[:space:]]*//p' | tr '\n' ' ')
# verify the first 4 bytes via md5sum (busybox has md5sum; `od`/`hexdump` may be absent):
#   FIT magic      d0 0d fe ed -> md5 51ac24e042ded1e5a13eed50d144d16b
#   squashfs magic 68 73 71 73 -> md5 1f6c3d88f61e1d6961d3d9eea8062cbb
kmd5=$(dd if=/dev/ubi9_0 bs=4 count=1 2>/dev/null | md5sum | cut -d' ' -f1)
rmd5=$(dd if=/dev/ubi9_1 bs=4 count=1 2>/dev/null | md5sum | cut -d' ' -f1)
ubidetach -d 9 2>/dev/null
log "staged volumes: $vols"
log "kernel magic md5=$kmd5 (want 51ac24e042ded1e5a13eed50d144d16b = FIT)"
log "rootfs magic md5=$rmd5 (want 1f6c3d88f61e1d6961d3d9eea8062cbb = squashfs)"
[ "$kmd5" = "51ac24e042ded1e5a13eed50d144d16b" ] || die "staged kernel is NOT a FIT image — aborting BEFORE the flip. The boot pointer is unchanged, so you are still on the working slot."
[ "$rmd5" = "1f6c3d88f61e1d6961d3d9eea8062cbb" ] || die "staged rootfs is NOT squashfs — aborting before the flip (still on the working slot)."
log "staged slot looks bootable (FIT kernel + squashfs rootfs)."

if [ "$MODE" = stage ]; then
	log "stage-only mode: image written + verified on mtd$inact; boot pointer NOT changed."
	log "to switch later: re-run without 'stage', or flip manually (see build-and-flash.md 4b step 4)."
	exit 0
fi

# ---- 4. confirm, then flip ----
echo
echo "############################################################"
echo "#  POINT OF NO RETURN                                       #"
echo "#  About to switch boot to mtd$inact (primaryboot=$new).        "
echo "#  If the new slot fails to boot there is NO recovery       #"
echo "#  without a UART/serial console. The active slot is still  #"
echo "#  intact until you confirm.                                #"
echo "############################################################"
printf "Type YES to flip BOOTCONFIG and reboot: "
read ans
[ "$ans" = "YES" ] || die "aborted by user — nothing flipped (image is staged on mtd$inact)."

log "writing primaryboot=$new via the kernel's BOOTCONFIG serializer (never hand-edited)"
echo "$new" > /proc/boot_info/rootfs/primaryboot
cat /proc/boot_info/getbinary_bootconfig  > /tmp/bc0.bin
cat /proc/boot_info/getbinary_bootconfig1 > /tmp/bc1.bin
mtd write /tmp/bc0.bin "/dev/mtd$bc0_mtd" || die "mtd write BOOTCONFIG failed"
mtd write /tmp/bc1.bin "/dev/mtd$bc1_mtd" || die "mtd write BOOTCONFIG1 failed"

# Keep the slot you are leaving as a usable dormant backup. The vendor firmware sets the
# U-Boot env flag sys_upgrade=1 on every boot; on the next boot the bootloader's
# ql_partition_init would then MIRROR the (now active) primary over the inactive slot and
# overwrite it. Clearing both auto-sync flags here preserves the inactive slot, giving a
# real dual-boot. HW-verified on this board. (sys_upgrade/sys_recovery live in 0:appsblenv,
# not the rootfs slots.)
if command -v fw_setenv >/dev/null 2>&1; then
	fw_setenv sys_upgrade 0 2>/dev/null
	fw_setenv sys_recovery 0 2>/dev/null
	log "cleared sys_upgrade/sys_recovery env (keep the other slot as a backup)"
else
	log "WARNING: fw_setenv not found — the inactive slot may be overwritten by the bootloader auto-sync"
fi

log "BOOTCONFIG updated. The board will boot mtd$inact next."
log "rebooting in 3s — reconnect at 192.168.1.1 (ImmortalWrt). If it answers on NEITHER the"
log "new nor the old IP after ~3 min, the new slot failed to boot -> UART/TFTP recovery."
sleep 3
reboot
