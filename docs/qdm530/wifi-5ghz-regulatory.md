# QDM530 — 5 GHz width is governed by the regulatory country, not caldata

The 5 GHz radio (QCN9074) looked permanently stuck at **20 MHz** on ImmortalWrt while
the vendor firmware ran it at **160 MHz**. The obvious suspect — missing per-board
calibration (`board_id` reads `0xff`) — was a **red herring**. The real lever is the
regulatory **country code**: `country=CN` unlocks the full band; `country=ID` (and the
`00`/world default) collapse it to 20 MHz. The fix is config-only — no driver patch, no
caldata.

## Symptom

- `iw dev phy1-ap0 info` → `width: 20 MHz` on ch149, `txpower 20 dBm`, no matter the
  configured `htmode`. Station tx rate tops out around HE 20 MHz 2SS MCS8 (~206 Mbit/s).
- Vendor firmware on the same hardware runs ch36 @ **160 MHz**, 23 dBm.
- `iw reg get` for the self-managed phy under `country ID` shows only
  `(5735 - 5815 @ 20)` — a single 20 MHz UNII-3 slice.

## What it was NOT (eliminated, HW-tested)

The chip reports `board_id 0xff` because its OTP/ART holds no calibration (`0:ART` is all
`0xFF`). That led to a long, wrong assumption that full-band 5 GHz needed real vendor
caldata. Every data/firmware experiment failed **and was beside the point**:

- Swapping `QCN9074-board.bin` to the vendor `bdwlan.*` variants — still 20 MHz.
- Replacing `cal-pci-0000:01:00.0.bin` — `board_id` stays `0xff` (it comes from chip OTP
  via QMI, not from any file).
- A hand-built `board-2.bin` with a `qmi-board-id=255` entry — still 20 MHz.
- The vendor's QSDK QCN9074 firmware on mainline `ath11k` — `MHI_CB_EE_RDDM` crash
  (WMI/QMI mismatch); incompatible, not usable.
- `ath11k` has `supports_regdb=false` for IPQ5018/QCN9074, so shipping a `regdb.bin` does
  nothing here.

## Root cause

`ath11k` registers the QCN9074 phy as **self-managed** (`REGULATORY_WIPHY_SELF_MANAGED`):
cfg80211's global regdomain does not drive it — the **firmware** does, from the country
code `ath11k` sends it (`current_cc_support=false` → the `init_country` path). With a
blank OTP the firmware has no regpair of its own, so the country code is the *only* input
that selects a regulatory domain:

| country sent | firmware regdomain | 5 GHz result |
|---|---|---|
| `ID` | `"FW Regdomain 0"` (unmapped) | minimal `(5735-5815 @ 20)` → **20 MHz / 20 dBm** |
| `CN` | `DFS-FCC` | `(5170-5250 @ 80)`, `(5250-5330 @ 80 DFS)`, `(5735-5835 @ 80)` → **up to 160 MHz** |

So `ID` was never mapped to a usable domain by this firmware build and fell back to a
20 MHz floor; `CN` maps to a permissive DFS-FCC domain that exposes the whole band. The
vendor firmware does exactly this — it ships `country=CN` (regdomain 87) — which is why
it reached 160 MHz on identical hardware.

## The fix (config-only)

Set `country=CN` on the radios; the width then follows normally.

Baked into the port so a fresh flash gets it:

- `base-files/etc/uci-defaults/25_set-wireless-country` — sets `country=CN` on every
  `wifi-device` on first boot.
- `base-files/etc/hotplug.d/ieee80211/13-qdm530-5ghz-channel` — the QCN9074 enumerates
  over PCIe ~20 s into boot, *after* uci-defaults have run, so its channel/width is pinned
  here when the phy appears: **ch36 / HE160 / CN**, then a `wifi` reload brings both radios
  up cleanly.

(Both scripts previously forced `ID` + `HE20` — that was the 20 MHz cause.)

## Default and the non-DFS alternative — both HW-verified

| | **ch36 / HE160** (default, matches vendor) | **ch149 / HE80** (non-DFS alt) |
|---|---|---|
| Width | 160 MHz | 80 MHz |
| Tx power | 23 dBm (CN limit on the 5.2 band) | 33 dBm reg / 30 dBm actual (5.8 band) |
| DFS | Yes — spans 5250–5330 | No |
| Bring-up | one-time **~60 s CAC** each time the radio starts | instant, no CAC |
| Peak PHY (2SS) | ~2.4 Gbit/s | ~1.2 Gbit/s |

The default follows the vendor (`ch36 / HE160`). To use the non-DFS 80 MHz profile
instead:

```sh
uci set wireless.radio1.channel=149
uci set wireless.radio1.htmode=HE80
uci commit wireless
wifi down; wifi up
```

(and, to make it survive a reflash, change `channel`/`htmode` in
`13-qdm530-5ghz-channel` to `149`/`HE80`).

## Operational notes / gotchas

- **5 GHz is silent for ~60 s after every boot/reload on the default (ch36/HE160).**
  This is the DFS CAC (channel availability check on 5250–5330), **not a fault**. The log
  shows `DFS-CAC-START` → `DFS-CAC-COMPLETED success=1 radar_detected=0` → `AP-ENABLED`.
  2.4 GHz and the wired LAN are up immediately; only the 5 GHz AP waits for CAC. If this
  delay matters, use the non-DFS ch149/HE80 profile above.
- **Radar events** on a DFS channel force the AP to vacate ch36 (a brief 5 GHz outage).
  Expected for any DFS channel; ch149/HE80 avoids it entirely.
- **Both self-managed radios `-95` ("Not supported") their first setup attempt** before
  the country code settles; the hotplug's `wifi` reload re-applies the country and clears
  it. That reload touches only the wireless stack, so the cellular WAN (wwand on PCIe/MHI)
  is **not** bounced — unlike `ubus call network reload`.
- **Power is per-band:** CN allows 23 dBm on the 5.2 GHz band (ch36) but 33 dBm on the
  5.8 GHz UNII-3 band (ch149). So the 80 MHz profile actually transmits *stronger* (longer
  range) than the 160 MHz one.
- **This is a 5G CPE.** The internet path is the cellular WAN (hundreds of Mbit/s), far
  below either Wi-Fi profile's PHY rate — so 160 vs 80 MHz changes **LAN-to-LAN** Wi-Fi
  speed only, not internet throughput.

## Regulatory caveat

`CN` is China's regulatory profile; it permits wider channels and higher power than
Indonesia's. We use it because it is what the vendor firmware ships on this device, so the
behavior matches the unit as sold — but it is operating under a foreign regulatory profile.
That is a deliberate choice, not a default to apply blindly to other markets.

## Troubleshooting

- **5 GHz stuck at 20 MHz again** → check `uci get wireless.radio1.country` is `CN` (and
  `iw reg get` shows the self-managed phy as `country CN: DFS-FCC`). `ID`/`00` clamps to
  20 MHz.
- **5 GHz radio won't come up after a config change** → `wifi down; wifi up` (full reload,
  re-applies the country and clears the first-attempt `-95`). A plain `wifi reload` is
  usually enough.
- **5 GHz missing for the first minute after boot** → expected DFS CAC on ch36; wait, or
  switch to ch149/HE80.
