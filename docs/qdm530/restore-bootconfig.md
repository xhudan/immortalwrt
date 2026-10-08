# QDM530 — restoring the BOOTCONFIG structs (mtd2 / mtd3)

How to overwrite the two `BOOTCONFIG` partitions with a known-good copy when the struct
itself has been damaged or mangled — e.g. a failed rebuild left the wrong partition names,
wrong entry order, or inconsistent `primaryboot` flags. This is a **repair of the struct** —
a separate thing from switching slots (which `bootslot switch` does; see the note below).
Done entirely from a running ImmortalWrt.

## What BOOTCONFIG is

The QSDK bootloader keeps an A/B boot descriptor in two redundant MTD partitions:

| mtd (label)            | role                        |
|------------------------|-----------------------------|
| `mtd2` `0:BOOTCONFIG`  | primary copy                |
| `mtd3` `0:BOOTCONFIG1` | backup copy (kept identical)|

Each partition is 256 KiB but only the first 336 bytes carry the struct
(`ipq_smem_bootconfig_info_t`):

```
offset 0    magic_start  = a0 a1 a2 a3
offset 4    age          = u32 LE   (bumped by the vendor /proc/boot_info serializer)
offset 8    numparts     = u32 LE   (8 on this board)
offset 12   numparts * 20-byte entries: name[16] + primaryboot[4] (u32 LE, 0 or 1)
offset 332  magic_end    = b0 b1 b2 b3
```

A **clean vendor** struct (the reference target of this restore) has these 8 entries, all
`primaryboot = 0`, `age = 1`:

```
0:QSEE  0:DEVCFG  0:CDT  0:APPSBL  0:HLOS  rootfs  0:WIFIFW  0:BTFW
```

There is **no checksum** in the struct, so a bad write is not self-detected — verify by
reading it back (below).

> ### ⚠️ Struct-repair vs. slot switch, and why dual-boot is not persistent
> Switching the boot slot **does work** and is a *separate* operation: `bootslot switch`
> flips **only** the `rootfs` `primaryboot` flag (byte 128 on a clean struct — never
> `0:HLOS`), and U-Boot then remaps and boots the other physical slot. HW-confirmed both
> ways (ImmortalWrt ⇄ vendor, booting a *different OS* from the other slot) — see
> `boot-slots.md`. An earlier note here claimed the flags were ignored; that was wrong — it
> came from a test that also flipped `0:HLOS=1`, which U-Boot rejects (`bad offset of hlos`)
> and falls back. Flip `rootfs` **only**. This BOOTCONFIG restore is for repairing a
> *corrupted* struct (wrong names/order/flags), not for choosing which OS runs.
>
> **The OEM bootloader auto-syncs the two rootfs slots — but you can disable it per switch.**
> `ql_partition_init` in the vendor U-Boot (decoded from the `0:APPSBL` dump) mirrors/clones one
> rootfs slot over the other when a U-Boot env flag in `0:appsblenv` is set: `sys_upgrade=1` ⇒
> mirror primary→backup; `sys_recovery=1` ⇒ restore backup→primary. **The vendor firmware sets
> `sys_upgrade=1` on every boot** (HW-confirmed), so switching *away* from vendor without
> clearing it makes the next boot overwrite the slot you left with the now-active ImmortalWrt —
> that is why a naive round-trip ends with both slots ImmortalWrt. The fix is simple and needs
> **no bootloader patch**: on the vendor→ImmortalWrt leg, `fw_setenv sys_upgrade 0; fw_setenv
> sys_recovery 0` before `reboot`. HW-verified: with the clear, ImmortalWrt boots and the vendor
> slot survives as a dormant backup across plain reboots — a real dual-boot. See
> `boot-slots.md` ("Keeping both slots"); `tools/slot-install.sh` does the clear automatically.
> These flags live in `0:appsblenv` (mtd10), **not** the rootfs slots, so rebuilding mtd15/mtd16
> is irrelevant to them.

## You need a known-good source

A raw dump of a healthy `0:BOOTCONFIG` / `0:BOOTCONFIG1` — either from this board's own
**vendor MTD backup** (`mtd2.bin` / `mtd3.bin`, one dump each), or re-dumped from a sibling
board that still has a clean struct:

```sh
# on a board with a good struct:
ssh root@<good-board> 'dd if=/dev/mtd2 bs=1 count=262144' > bootconfig0.bin
ssh root@<good-board> 'dd if=/dev/mtd3 bs=1 count=262144' > bootconfig1.bin
```

The two copies are normally byte-identical; using the same file for both is fine.

## Restore

`scp`/SFTP does not work against the device's dropbear — push bytes over an ssh pipe.

```sh
# 1) copy the good structs to the target board (/tmp is tmpfs, wiped on reboot)
ssh root@192.168.1.1 'cat > /tmp/bc0.bin' < bootconfig0.bin
ssh root@192.168.1.1 'cat > /tmp/bc1.bin' < bootconfig1.bin

# 2) integrity + sanity on the board (md5 must match the source; magic/size must be right)
ssh root@192.168.1.1 '
  md5sum /tmp/bc0.bin /tmp/bc1.bin
  for f in /tmp/bc0.bin /tmp/bc1.bin; do
    echo "$f size=$(wc -c < $f)" \
         "magic=$(hexdump -v -n 4 -e "4/1 \"%02x \"" $f)" \
         "end=$(hexdump -v -s 332 -n 4 -e "4/1 \"%02x \"" $f)"
  done'
# expect: size=262144  magic=a0 a1 a2 a3  end=b0 b1 b2 b3

# 3) write both copies
ssh root@192.168.1.1 '
  mtd write /tmp/bc0.bin /dev/mtd2 &&
  mtd write /tmp/bc1.bin /dev/mtd3 && echo "write OK"'
```

## Verify the result

```sh
# per-entry dump straight from flash (no reboot needed):
ssh root@192.168.1.1 '
  for off in 4 8; do :; done
  echo "age=$(hexdump -v -s 4 -n 4 -e "1/4 \"%u\"" /dev/mtd2)"
  i=0
  while [ $i -lt 8 ]; do
    noff=$((12 + i*20)); poff=$((noff + 16))
    nm=$(dd if=/dev/mtd2 bs=1 skip=$noff count=16 2>/dev/null | tr -d "\0")
    pb=$(hexdump -v -s $poff -n 4 -e "1/4 \"%u\"" /dev/mtd2)
    echo "  $nm = $pb"; i=$((i+1))
  done'
```

or, if the image has it, `bootslot status` (name-resolves `rootfs`/`0:HLOS` and shows what
the other rootfs slot holds).

## Safety / recovery

- Writing `mtd2`/`mtd3` only touches the BOOTCONFIG partitions; `SBL1`, `MIBIB`, `QSEE`,
  `APPSBL`, and both `rootfs` slots are untouched, so a bad BOOTCONFIG is recoverable from
  U-Boot (password `quectel`) over the serial console. A **wrong-offset** NAND erase/write
  is not — only write the two BOOTCONFIG mtds, by label (never hardcode mtd numbers blindly;
  confirm with `/proc/mtd`).
- Keep both copies identical. `age` only matters for picking the fresher copy if the two
  ever differ — a plain restore that writes both the same value is consistent.
- As always on this board, **UART/TFTP is the only recovery net** if the board stops
  booting. See `uart-console.md`, `build-and-flash.md`, and `boot-slots.md`.
