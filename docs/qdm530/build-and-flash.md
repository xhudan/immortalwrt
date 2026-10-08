# QDM530 — building and flashing

How to build an ImmortalWrt image for the Unbranded QDM530 5G CPE and get it onto
the board. Read `README.md` first for the board overview; this is the hands-on
build/flash recipe.

> **Cellular WAN = QMI-over-QRTR via wwand.** This transport is now upstream: the
> daemon (`ddimension/wwand`) ships `qmi_over_qrtr.uc`, and the feed
> (`ddimension/openwrt-repo`) pins a release that includes it (wwand ≥ 1.7.0_pre7).
> No feed override is needed — the stock feed builds it as-is.

## 1. Feeds

`feeds.conf.default` already lists the wwand feed:

```
src-git wwand https://github.com/ddimension/openwrt-repo.git
```

Update and install feeds as usual:

```sh
./scripts/feeds update -a
./scripts/feeds install -a
```

## 2. wwand version

No feed override is required. The `ddimension/openwrt-repo` feed pins a wwand that
ships `qmi_over_qrtr.uc` (the QRTR transport this board's modem needs) in its
`wwand-qmi` package — wwand **1.7.0_pre7** or newer. HW-verified on the QDM530:
plain bring-up with no `qmap_version`/`ep_type`/`ep_id` overrides (the PCIe/MHI
endpoint and QMAP version are auto-derived), IPv4 + IPv6 dual-stack, and modem
reset recovery all work on the stock feed.

## 3. Configure and build

A ready-made build seed lives in `qdm530.diffconfig` (web UI + relayd repeater on top
of the board defaults; the modem stack and board firmware — including `kmod-tun` —
come from `DEVICE_PACKAGES`, so they are not listed there):

```sh
cp qdm530.diffconfig .config
make defconfig
make -j"$(nproc)"
```

Sanity-check the resulting `.config` before the long build if you like:

```sh
grep -E 'DEVICE_unbranded_qdm530=y|PACKAGE_wwand=y|PACKAGE_wwand-mhi=y|PACKAGE_kmod-qrtr=y|WWAND_UCODE_SOURCE' .config
# expect the packages =y and `# CONFIG_WWAND_UCODE_SOURCE is not set` (bytecode build)
```

Output lands in `bin/targets/qualcommax/ipq50xx/`:

- `...-unbranded_qdm530-squashfs-sysupgrade.bin` — upgrade an already-flashed board
- `...-unbranded_qdm530-squashfs-factory.ubi` — first install over the vendor firmware
- `...-unbranded_qdm530-initramfs-uImage.itb` — RAM-boot image for recovery/bring-up

Confirm the modem stack made it into the image:

```sh
grep -E '^wwand|kmod-qrtr|luci-(app|proto)-wwand' \
  bin/targets/qualcommax/ipq50xx/*unbranded_qdm530*.manifest
```

## 4. First flash (from the vendor firmware)

The device ships on vendor OpenWrt (Chaos Calmer 15.05.1, kernel 4.4.60).

> **`sysupgrade` of an ImmortalWrt image from the vendor OS does NOT work.** Its ancient
> sysupgrade cannot parse a modern image and aborts with `mandatory section(s) missing`;
> with `-F` it only rewrites the BOOTCONFIG structs and never writes the rootfs (the board
> just reboots back into vendor). Do not rely on it.

The NAND is A/B: `rootfs` (mtd15, slot A) and `rootfs_1` (mtd16, slot B); the active slot
is chosen by the `BOOTCONFIG`/`BOOTCONFIG1` structs (mtd2/mtd3). U-Boot **remaps the active
slot to be presented to Linux as `rootfs`/`ubi0`**, so a booted system always shows
`ubi.mtd=rootfs` no matter which physical slot it runs from (confirm the running firmware by
`board_name`/`uname -r`, not by the slot name in the cmdline).

### 4a. UART / TFTP — recommended, the only recoverable path
Needs the **serial console** (front RJ12 port, see `README.md` → "Boot, console and
recovery"); U-Boot stops at a password prompt (`quectel`). Serve the `initramfs-uImage.itb`
from a host at `192.168.10.19` (the U-Boot `serverip`), RAM-boot it, then from the booted
initramfs `sysupgrade` the `factory.ubi` (or write the UBI to both `rootfs`/`rootfs_1`
slots). See `tools/tftp-recovery-setup.sh` and `bootloop-postmortem.md`. Recoverable: if a
flash goes wrong the serial console gets you back into U-Boot.

### 4b. Non-UART from the vendor root shell — advanced, NO recovery net
If you have root SSH on the vendor firmware and no serial cable, install by writing the
**inactive** slot and flipping the boot pointer. The running (active) slot is never touched,
so every step except the final flip is reversible. **The flip has no recovery net without
UART — if the new slot fails to boot, only serial can recover it.** (HW-verified on a twin
unit, Oct 2026.)

1. **Find the inactive slot — do NOT assume slot A/B or a fixed mtd.** `/proc/boot_info`'s
   `upgradepartition` names the inactive slot directly (QSDK's own value, so it is correct
   whichever slot is booted); resolve it to an mtd via `/proc/mtd` (never hardcode numbers):
   ```sh
   cur=$(cat /proc/boot_info/rootfs/primaryboot)          # current boot flag (0 or 1)
   other=$(cat /proc/boot_info/rootfs/upgradepartition)   # QSDK's own name for the INACTIVE slot
   inact=/dev/$(grep "\"$other\"" /proc/mtd | cut -d: -f1) # inactive partition (e.g. mtd16)
   m=$(echo "$inact" | tr -dc 0-9)                        # inactive mtd number
   newflag=$((1 - cur))
   echo "flag=$cur; inactive=$other ($inact); will set primaryboot=$newflag"
   ```
   Everything below uses `$inact`/`$m`/`$newflag`, so it is correct whichever slot is active.
   (The active rootfs is the one UBI is mounted from — that one is never written.)
2. Copy `factory.ubi` to the board and verify md5 (a corrupt image + flash = brick):
   ```sh
   # from your PC:
   ssh root@<vendor-ip> 'cat > /tmp/factory.ubi' < *-unbranded_qdm530-squashfs-factory.ubi
   ssh root@<vendor-ip> 'md5sum /tmp/factory.ubi'         # must match the local md5
   ```
3. Write to the **inactive** slot `$inact` (the active, mounted slot is never touched).
   `ubiformat` erases the whole partition, so any vendor volumes are purged:
   ```sh
   ubidetach -p "$inact" 2>/dev/null
   ubiformat "$inact" -f /tmp/factory.ubi -y
   # sanity-check the staged slot read-only (use any free ubi number, e.g. 9):
   ubiattach -m "$m" -d 9
   ubinfo -a -d 9 | grep -E 'Name:'                       # expect: kernel, rootfs, rootfs_data
   dd if=/dev/ubi9_0 bs=4 count=1 2>/dev/null | hexdump -C # kernel: d0 0d fe ed (FIT)
   dd if=/dev/ubi9_1 bs=4 count=1 2>/dev/null | hexdump -C # rootfs: 68 73 71 73 (hsqs)
   ubidetach -d 9
   ```
4. Flip the boot pointer to the staged slot with the kernel's own serializer — **never
   hand-edit the struct**. `getbinary_bootconfig` always emits a valid struct, so a wrong
   flag at worst keeps booting the current slot; it cannot corrupt BOOTCONFIG:
   ```sh
   echo "$newflag" > /proc/boot_info/rootfs/primaryboot   # RAM only until the mtd write
   cat /proc/boot_info/getbinary_bootconfig  > /tmp/bc0.bin
   cat /proc/boot_info/getbinary_bootconfig1 > /tmp/bc1.bin
   mtd write /tmp/bc0.bin /dev/mtd2                        # BOOTCONFIG
   mtd write /tmp/bc1.bin /dev/mtd3                        # BOOTCONFIG1 (backup)
   fw_setenv sys_upgrade 0     # keep vendor as a dual-boot backup (see note below);
   fw_setenv sys_recovery 0    # omit both lines to mirror ImmortalWrt into both slots
   reboot
   ```
   Optional read-back before rebooting: `dd if=/dev/mtd2 bs=4 count=1 | hexdump -C` → magic
   `a0 a1 a2 a3`. After reboot ImmortalWrt comes up on `192.168.1.1` (new SSH host key). If it
   answers on **neither** the new nor the old IP after ~3 min, the staged slot failed to boot
   → UART/TFTP recovery is required.

   > **What happens to the old vendor slot.** The vendor firmware sets the U-Boot env flag
   > `sys_upgrade=1` on every boot; on the first boot after this flip the bootloader's
   > `ql_partition_init` would mirror the now-active ImmortalWrt over the slot you came from and
   > **overwrite the vendor firmware** (you would end up with ImmortalWrt in *both* slots — a
   > clean single-OS install with ImmortalWrt A/B). The two `fw_setenv … 0` lines above stop
   > that, **preserving the vendor firmware as a dormant dual-boot backup** (HW-verified: it
   > survives normal reboots, and you can switch back and forth — see `boot-slots.md`). Keep the
   > lines for dual-boot; drop them if you want a plain ImmortalWrt-only board. `tools/slot-install.sh`
   > keeps the vendor slot by default (it runs the same clear).

> **Automated.** `tools/slot-install.sh` does all of 4b — detect the active/inactive slot,
> write the inactive one, verify the staged FIT+squashfs, then flip only after you type YES.
> It is robust to any mtd numbering (it takes the inactive slot from `upgradepartition` and
> resolves it by name, so mtd17/18 works exactly like mtd15/16). From your
> PC, `tools/slot-install-push.sh "<ssh target + opts>" factory.ubi` transfers the image +
> script and runs it live (`ssh -t`). Run it with `detect` first (read-only, prints the slot
> layout) or `stage` (writes the inactive slot without flipping) before the full run.

Either way, keep the vendor firmware backed up (dump the MTD partitions) before overwriting.
Doing both slots (repeat 4b for the other slot once ImmortalWrt boots, or write both via
UART) stops U-Boot ever falling back to a leftover vendor image.

## 5. Upgrading an already-flashed board

```sh
# copy the sysupgrade.bin to the board, then on the board:
sysupgrade -n /tmp/immortalwrt-...-unbranded_qdm530-squashfs-sysupgrade.bin
```

Use **`-n` (reset config)** when you want the board to come up on its shipped
defaults — in particular so the first-boot `uci-defaults` run, including
`26_wwand-modem`, re-seeds the cellular WAN. A config-preserving upgrade (without
`-n`) keeps your existing `/etc/config/network` and does **not** re-run those
scripts.

## 6. Verify

After boot (LAN default is `192.168.1.1`):

```sh
# cellular WAN was auto-seeded and dialed
uci show network.wwmodem network.wan
ifstatus wan | grep -E '"up"|address'
ping -c3 -I wwand0 8.8.8.8

# both Wi-Fi bands (2.4 GHz built-in + 5 GHz QCN9074 on pcie0)
iw dev; logread | grep -iE 'ath11k|wifi'

# a LAN/Wi-Fi client should reach the internet (interface is named `wan`,
# so it lands in the `wan` firewall zone and is NAT'd automatically)
```

If the WAN does not come up, check `logread -e wwand` — the QMI-over-QRTR bring-up
logs its modem-node discovery and the WDA data-format negotiation there.
