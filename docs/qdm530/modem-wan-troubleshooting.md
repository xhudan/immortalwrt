# QDM530 cellular WAN — troubleshooting

Field notes for the 5G WAN (Quectel RG520N-EB over PCIe/MHI, dialed by **wwand**).
Each entry is: **symptom → how to confirm → fix**. All HW-observed.

Two layers matter and they are configured in different places:
- **Router config** — uci (`/etc/config/network`): the `wan` interface + the
  `wwand_modem` section. Set by `uci-defaults/26_wwand-modem`, travels with the flash.
- **Modem NV** — AT settings stored *inside the modem* (`usbnet`, `QMAPWAC`,
  `data_interface`, `pcie/mode`). **These do NOT travel with the router flash** — they are
  per-modem, set over AT. A board that "flashed the same image" can still behave differently
  because its modem NV differs.

Working reference (this project's modems, confirmed on HW, dual-stack internet live):
- modem AT: `usbnet=0`, `data_interface=1,0`, `pcie/mode=0`, **`QMAPWAC=0`**
- router uci: `wwand_modem 'wwmodem'` = `device 'qrtr'`, `protocol 'qmi'`,
  `netdev 'mhi_hwip0'`; `wan` = `modem 'wwmodem'`, `mux_id '1'`
- result: `wda format negotiated: QMAP v5 … dl max 32 x 4096`, netdev
  `wwand0@mhi_hwip0`, WAN up.

---

## 1. WAN gets an IPv4 address but IPv6 is refused (carrier-dependent)

**Symptom.** WAN comes up with an IPv4 address, but `logread` shows the IPv6 leg
failing; on some carriers the repeated IPv6 attempt/teardown churns the link (WAN flaps,
`ifstatus wan` shows `CONNECT_FAILED` / `pending`). Seen on **Smartfren (MCC/MNC 510/09)**;
**XL Axiata (510/11)** gives clean dual-stack.

**How to confirm.**
```sh
logread | grep -iE 'wwmodem|wan:|ipv6|ipv4 up|activation|reason|CONNECT'
```
The tell-tale line:
```
interface wan: ipv6 activation failed, continuing: PDN IPv6 call disallowed
  (internal 210) … "error":"qmi","result":1,"code":14 … "reason":210
```
`reason 210` = the network does not allow an IPv6 PDN on this APN/profile. The IPv4 leg
succeeds right before it (`ipv4 up … 10.x.x.x/32`), so SIM / signal / data path are fine —
only the IPv6 call is refused by the carrier.
```sh
ifstatus wan | grep -iE '"up"|ipv4-address|ipv6'
```

**Fix.** Use an IPv4-only PDP type for that SIM:
```sh
uci set network.wan.pdp_type='ipv4'
uci commit network
ifup wan        # or reboot
```

**Which default to ship** (`pdp_type` is on the `wan` interface, set by
`uci-defaults/26_wwand-modem`, currently `ipv4v6`):
- `ipv4v6` (dual-stack): IPv6 where the carrier supports it (XL), but IPv6-refusing
  carriers (Smartfren) log `reason 210` and may flap.
- `ipv4`: works on **every** carrier, no IPv6 negotiation — the robust "insert any SIM and
  it works" choice. No IPv6 (fine for most CPE use; cellular is usually CGNAT IPv4 anyway).

For units shipped to end users with unknown SIMs, `ipv4` is the safer default; switch a unit
to `ipv4v6` only when IPv6 is wanted and the carrier provides it.

> **Note.** The `reason 210` IPv6 refusal is itself **non-fatal** to IPv4 (wwand logs
> "continuing"). If the WAN still drops with `pdp_type='ipv4'` — e.g. `logread` shows
> `qrtr: modem node … gone` / `device disappeared` *after* CONNECTED — that is a **separate
> modem-reset issue**, not the IPv6 refusal; diagnose from
> `dmesg | grep -iE 'mhi|pcie|aer|modem|reset'`.

---

## 2. WAN shows TX only, RX = 0 (and/or `DEVICE_CLAIM_FAILED`)

**Symptom.** The `wan` has an IP and TX climbs but **RX stays 0** (no download); or LuCI
shows `Unknown error (DEVICE_CLAIM_FAILED)` and `ifstatus wan` is `"up": false`. This is a
**data-plane topology** problem, not RF/SIM (RX=0 at the *netdev counter* means DL frames
never reach the interface at all — a firewall/route problem would still count them).

**How to confirm.**
```sh
ip -br link | grep -iE 'mhi_hwip0|wwand0'
readlink /sys/class/net/wwand0/device          # expect it via mhi_hwip0, not raw mhi0_IP_HW0
logread | grep -iE 'wda format|datapath|mux|MBIM|wwmodem'
```
Compare against the working reference:

| | Working | Broken |
|---|---|---|
| modem name in log | `wwmodem` | `wwmodem_auto` (auto-probe) or MBIM |
| control path | QMI (`services: 66 43 15 …`) | `MBIM session 0`, or `/dev/wwan0qmi0` timeouts |
| `wda format` | `QMAP v5 … dl max 32 x 4096` | `QMAP v1 … dl max 0 x 0`, or none |
| datapath | `rmnet/qmap v5 … mux [wwand0]` | `raw_ip, mux []` |
| netdev | `mhi_hwip0` **+** `wwand0@mhi_hwip0` | only `mhi_hwip0` (no `wwand0`) |

Two root causes, often together:

**(a) Modem shipped in MBIM mode** (`usbnet=2`). The OEM/vendor firmware uses MBIM, so the
modem's NV is left at `usbnet=2`; flashing ImmortalWrt does not change it, and wwand then
runs MBIM (no QMAP mux). Confirm/fix over AT (`/dev/at_mdm0` via adb on the modem's USB-C, or
a `/dev/wwan*at*` port):
```
AT+QCFG="usbnet"          → if 2 (MBIM), that's it
AT+QCFG="usbnet",0        AT+QCFG="data_interface",1,0
AT+QCFG="pcie/mode",0     AT+QMAPWAC=0
AT+CFUN=1,1               (reset modem)   → then reboot the board
```

**(b) Missing `wwand_modem` qrtr config.** If `wan.modem` is not pointed at a
`wwand_modem` section with `device 'qrtr'`, wwand auto-probes and picks the wrong transport
(MBIM, or a dead `/dev/wwan0qmi0`). Fix (matches the shipped `uci-defaults`):
```sh
uci batch <<'EOF'
set network.wwmodem='wwand_modem'
set network.wwmodem.device='qrtr'
set network.wwmodem.protocol='qmi'
set network.wwmodem.netdev='mhi_hwip0'
set network.wan.modem='wwmodem'
set network.wan.mux_id='1'
commit network
EOF
reboot
```
After the reboot: `wda format … QMAP v5`, `wwand0@mhi_hwip0` appears, RX climbs.

> **`QMAPWAC` is `0`, not `1`** — the HW reference modem (QMAP v5 working) reads
> `+QMAPWAC: 0`. (An earlier guess of `1` was wrong.) `QMAPWAC` only matters on the
> QMI/RMNET path; MBIM does not use it.

---

## 3. WAN stuck at REGISTERING / "No Service" (CSQ 99,99)

**Symptom.** SIM ready, data path fine (`wwand0@mhi_hwip0` present), but the modem never
registers → no data call, `ping: Network unreachable`.

**How to confirm (AT via `/dev/at_mdm0`):**
```
AT+CPIN?      → READY  (SIM ok)
AT+CSQ        → 99,99  = NO SIGNAL
AT+CREG?      → 0,2    = searching
AT+QNWINFO    → No Service
```

**Fix.** It is RF, not config: **connect the antennas** (CSQ 99,99 = no antenna / no
coverage), or the modem just reset and is re-acquiring (wait ~30–60 s). If it persists with
antennas on, check the band lock (`lte_band` / `nr5g_band`) isn't excluding the carrier's
bands. Once CSQ shows a real value and `+CREG: 0,1` (registered), the data call comes up.

---

## Sending AT to the modem

The modem is a separate SDX6x running its own Linux. On this board the router's USB host is
off, so reach it over the **modem's USB-C to a PC** (adb):
```sh
adb shell           # drops into the modem
# AT port = /dev/at_mdm0 ; send + read:
(cat /dev/at_mdm0 & sleep 0.4; printf 'AT+QCFG="usbnet"\r' > /dev/at_mdm0; sleep 1.5; kill %1)
```
See `pcie1-modem-combo-phy.md` for why the router-side USB host is disabled, and
`modem-modes.md` for the full board/EP mode recipes.
