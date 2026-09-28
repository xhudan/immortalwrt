# QDM530 — downlink stall under sustained load (MHI ring starvation) and its fix

A hunt that looked like a modem/firmware dead end but turned out to be a host-side
MHI RX-ring starvation bug, fixed with two small in-tree kernel patches. No
out-of-tree vendor driver, no auto-reset watchdog — native and zero added latency.

## Symptom

On the RG520N-EB (PCIe/MHI, driven by `mhi_net` + rmnet/QMAP + wwand), under
**sustained downlink** (repeated speedtests, large downloads, even a busy media
feed), the WAN would wedge:

- `wwand0`/`mhi_hwip0` **rx_packets freeze** mid-transfer; `tx_packets` keep rising.
- `ifstatus wan` stays `"up": true`, registration fine, `logread` silent — no error.
- Internet is dead until a **modem reset or reboot** (`ifup wan` and `wwandctl
  reset` did *not* recover a hard wedge).

It reproduced on both boards and across two operators (XL, Smartfren); the same SIM
in a phone was fine. So it was the RG520N-in-the-router datapath, not the SIM or network.

## What it was NOT (eliminated, HW-tested)

operator · SIM · band lock · kernel version (6.18.44 == .54) · QMAP version (v1 and
v5 both stalled) · WDA endpoint / "mode EP" · MRU (32768 only *delayed* it) ·
`coherent_pool`/`swiotlb` (already set) · PCIe ASPM / `pcie_port_pm` (no AER/CmpltTO
here) · MHI M-state runtime PM (forcing M0 via `device_wake` didn't help) · IRQ
moderation (set to 0, still stalled) · QMAP in-band flow-control commands (mainline
rmnet handles them identically to the vendor).

## The misleading debugfs picture

Captured at a stall from `/sys/kernel/debug/mhi/mhi0/`:

- `IP_HW0(101)` DL channel: `wp` ~56 elements **ahead of** `rp`, and the doorbell
  `db >= wp` — i.e. the host *had* queued RX buffers and *had* rung the doorbell.
- Its event ring (ev5): `rp` caught up to `wp` (empty), and **IRQ 45 frozen** — the
  device posted no more DL completion events. Device still in `M0` (not crashed).

Read naively this says "the modem ignores buffers it was given" → a firmware dead
end. That reading was wrong.

## Root cause: RX ring starvation → modem IPA deadlock

Two mainline defaults combine badly on this hardware:

1. **The DL ring is tiny.** `mhi_pci_generic`'s generic `modem_qcom_v1` config gives
   `IP_HW0` only **128** descriptors (`MHI_CHANNEL_CONFIG_HW_DL(101, "IP_HW0", 128, 5)`).
2. **`mhi_net` refills lazily.** `mhi_net_dl_callback()` only kicks a refill once the
   ring has already drained to half (`free_desc_count >= rx_queue_sz / 2`), and it
   does so via `schedule_delayed_work()` on `system_wq`.

On the IPQ5018 (dual Cortex-A53 @ 1 GHz) busy with 5G NAT/routing/Wi-Fi, the kworker
scheduling latency is several ms. Under sustained DL the modem drains the remaining
~64 buffers (≈96 KB at MTU 1500) in a few ms — *before* the worker runs. The ring
hits empty. The SDX6x modem's hardware DL path (IPA) then **deadlocks on descriptor
starvation** and stops advancing: it reads no more buffers and posts no more events.
The modem firmware has no internal watchdog to recover the IPA, so it stays wedged.

The debugfs picture now makes sense: `wp > rp` + `db` rung is the kworker's refill
arriving a few ms **too late** — after the IPA had already halted. `rp` frozen and
IRQ 45 silent are the halted engine, not an ignored buffer.

Corroboration: the earlier `mru=32768` experiment *reduced* (but didn't cure) the
stall — bigger buffers make the 128-slot ring hold more bytes, so it drains slower.
And Qualcomm's own vendor `pcie_mhi` driver, plus mainline's other SDX6x profiles,
use **512**, not 128.

## The fix (two patches)

**`0958-bus-mhi-pci_generic-sdx-ip_hw0-ring-512.patch`** — enlarge the `IP_HW0`
UL/DL rings in `modem_qcom_v1` from 128 to **512** descriptors (512 × 16-byte TRE =
8 KiB of ring; trivial DMA memory). Matches the vendor's
`NUM_MHI_IPA_IN/OUT_RING_ELEMENTS = 512` and mainline's other SDX6x modem profiles.
The dedicated HW DL event ring (2048) already satisfies "event ≥ 2× channel".

**`0959-net-mhi_net-direct-inline-rx-refill.patch`** — refill the DL ring **in-line**
from `mhi_net_dl_callback()`: for each buffer the device just consumed, hand one back
immediately (`netdev_alloc_skb()` + `mhi_queue_skb()`), so the ring never runs dry.
The `delayed_work` is kept only as the fallback for a real allocation/queue failure
(memory pressure) — exactly what the vendor driver does. This is the standard Linux
NIC RX pattern (stmmac, igb, virtio_net, ath11k …): refill from the receive path, not
a workqueue. Benefits vs the workqueue: zero context switches, cache-hot, and the ring
stays ~100 % full regardless of CPU load.

**Why in-line refill is safe here:** the MHI host drops `mhi_chan->lock` around the
transfer callback — in `drivers/bus/mhi/host/main.c:parse_xfer_event()` the DL path is
`read_unlock_bh(&mhi_chan->lock)` → `mhi_chan->xfer_cb(...)` → `read_lock_bh(...)` — and
the callback runs in softirq/bh context. So `mhi_queue_skb()` (which takes the pm/chan
locks itself) can be called directly from the callback without deadlock. Verified in
the 6.18.54 source.

Ring size alone narrows the window; the in-line refill closes it (1-in-1-out keeps the
ring full even if the CPU is saturated). Both together are belt-and-braces.

## Verification

Built on kernel 6.18.54 + wwand 1.7.0_pre7, flashed, heavy sustained download:

- `IP_HW0(101)` ring length confirmed `0x2000` (= 512 descriptors).
- **rx climbed 733,879 packets in ~5 min, `freeze_terlama = 0 s`** — zero stall under
  load that previously wedged at ~30–43 k packets.
- `loadavg 0.08` (in-line refill is *cheaper* than the old kworker), IRQ 45 ~143/s,
  internet stayed up throughout.
- Followed by a **6-hour soak / endurance run** (sustained + idle→burst): stable, no
  stall.

## Scope / upstreaming notes

- `0959` lives under `target/linux/qualcommax/patches-6.18/`, so it only affects this
  target's MHI modems (effectively this board). It is a general improvement and a good
  upstream candidate for `drivers/net/mhi_net.c`.
- `0958` edits the shared `modem_qcom_v1` channel config (also used by the sdx55m/sdx24
  profiles in `pci_generic.c`); only the sdx65m board is built here, so it is safe in
  this tree. For an upstream submission, give the RG520N/QDM530 its own
  `mhi_pci_dev_info` + config rather than changing the shared one.

See `pcie1-modem-combo-phy.md` for how the modem is brought up on PCIe1/MHI in the
first place, and `README.md` for the port status table.
