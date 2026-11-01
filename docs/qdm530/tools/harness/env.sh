# Builds a fake board inside an already-created mount namespace.
# Called as: . env.sh   (after unshare -rm)
# Knobs via env: FW_SETENV_FAIL, MTD_WRITE_FAIL_N, UBIFORMAT_FAIL, UBI9_BUSY,
#                PRIMARYBOOT, UPGRADEPART, BC_TRUNCATE, BC_DISAGREE, MISSING_TOOL
set -e
: "${WORK:?WORK must be set}"
STUB=$WORK/stub; MARK=$WORK/mark
mkdir -p "$STUB" "$MARK"

# ---- /proc ----
mount -t tmpfs tmpfs /proc
mkdir -p /proc/boot_info/rootfs
printf '%s' "${PRIMARYBOOT:-0}"            > /proc/boot_info/rootfs/primaryboot
printf '%s' "${UPGRADEPART:-rootfs_1}"     > /proc/boot_info/rootfs/upgradepartition
cat > /proc/mtd <<'MTD'
dev:    size   erasesize  name
mtd2: 00040000 00020000 "0:bootconfig"
mtd3: 00040000 00020000 "0:bootconfig1"
mtd14: 03000000 00020000 "rootfs"
mtd15: 03000000 00020000 "rootfs_1"
MTD

# a 336-byte BOOTCONFIG: magic a0a1a2a3, flag at offset 128, end magic at 0x14c.
# Built without /dev/zero, because /dev gets replaced by a tmpfs below.
mkbc() { # $1=out  $2=flag
  : > "$1"; truncate -s 336 "$1"
  printf '\240\241\242\243' | dd of="$1" bs=1 conv=notrunc 2>/dev/null
  printf "$(printf '\\%03o' "$2")" | dd of="$1" bs=1 seek=128 conv=notrunc 2>/dev/null
  printf '\260\261\262\263' | dd of="$1" bs=1 seek=332 conv=notrunc 2>/dev/null
}
mkbc /proc/boot_info/getbinary_bootconfig  "${PRIMARYBOOT_NEW:-1}"
cp /proc/boot_info/getbinary_bootconfig /proc/boot_info/getbinary_bootconfig1
[ -n "${BC_TRUNCATE:-}" ] && truncate -s 1 /proc/boot_info/getbinary_bootconfig
[ -n "${BC_DISAGREE:-}" ] && mkbc /proc/boot_info/getbinary_bootconfig1 0

# ---- /dev: regular files for the mtds ----
# /dev/null is a plain writable file here, not the real device: binding a char device onto
# a path under /tmp fails to open, because /tmp is mounted nodev. For these scripts a
# write-only sink that reads as EOF is indistinguishable.
mount -t tmpfs tmpfs /dev
: > /dev/null; chmod 666 /dev/null
for n in 2 3 14 15; do mkbc /dev/mtd$n 0; done
[ -n "${BC_MTD3_DIFFERENT:-}" ] && mkbc /dev/mtd3 1
truncate -s 33554432 /dev/mtd14; truncate -s 33554432 /dev/mtd15

# ---- /sys ----
mount -t tmpfs tmpfs /sys
mkdir -p /sys/class/ubi/ubi0 /sys/class/net/br-lan
printf '%s' "${ACTIVE_MTD:-14}" > /sys/class/ubi/ubi0/mtd_num
printf '92:65:b6:a1:f4:46' > /sys/class/net/br-lan/address
[ -n "${UBI9_BUSY:-}" ] && mkdir -p /sys/class/ubi/ubi9

# ---- stubs ----
stub() { printf '#!/bin/sh\n%s\n' "$2" > "$STUB/$1"; chmod 755 "$STUB/$1"; }
stub reboot      "touch $MARK/reboot; exit 0"
stub ubiformat   "touch $MARK/ubiformat; [ -n \"${UBIFORMAT_FAIL:-}\" ] && exit 1; exit 0"
# A real ubiattach creates the volume nodes; the magic checks read them, so the stub must
# too, or the script stops before the branch under test.
stub ubiattach   'mkdir -p /sys/class/ubi/ubi9
                  printf "\\320\\015\\376\\355" > /dev/ubi9_0   # FIT  d0 0d fe ed
                  printf "hsqs"                       > /dev/ubi9_1   # squashfs
                  [ -n "'"${VENDOR_VOLS:-}"'" ] && printf "ubi_rootfs" > /dev/ubi9_0
                  exit 0'

stub ubidetach   "touch $MARK/ubidetach; rm -rf /sys/class/ubi/ubi9; exit 0"
if [ -n "${VENDOR_VOLS:-}" ]; then
  stub ubinfo "printf 'Name:   ubi_rootfs\nName:   wifi_fw\nName:   bt_fw\n'; exit 0"
else
  stub ubinfo "printf 'Name:   kernel\nName:   rootfs\n'; exit 0"
fi
stub fw_setenv   "touch $MARK/fw_setenv; [ -n \"${FW_SETENV_FAIL:-}\" ] && exit 1; echo \"\$2\" > $MARK/env.\$1; exit 0"
stub fw_printenv "n=\${2:-\$1}; cat $MARK/env.\$n 2>/dev/null || echo 0"
stub mtd         'op=$1; src=$2; dst=$3; echo "$dst" >> '"$MARK"'/mtdwrite
                  c=$(wc -l < '"$MARK"'/mtdwrite)
                  [ -n "'"${MTD_WRITE_FAIL_N:-}"'" ] && [ "$c" = "'"${MTD_WRITE_FAIL_N:-0}"'" ] && exit 1
                  cat "$src" > "$dst"; exit 0'
[ -n "${MISSING_TOOL:-}" ] && stub "$MISSING_TOOL" "exit 127" && rm -f "$STUB/$MISSING_TOOL"
# restore-vendor.sh shells out to bootslot; give it the real one from the repo so the
# harness exercises the actual interaction rather than a stub of it.
cp "${REPO:-/home/huda/Documents/immortalwrt}/target/linux/qualcommax/ipq50xx/base-files/usr/sbin/bootslot" "$STUB/bootslot" 2>/dev/null
chmod +x "$STUB/bootslot" 2>/dev/null
export PATH="$STUB:$PATH"
set +e
