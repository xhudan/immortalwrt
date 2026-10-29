# QDM530 silent resets — the PCIe AER handler hangs on the modem's dead link

**Symptom:** the board resets **silently** and repeatedly — no panic, no oops, `logread`
empty after the reset. It correlates with poor cellular RF: the worse the signal, the
more often it happens. SBL reports a watchdog reset, same as the old boot loop, which
is why the two were confused for a while (that one was
[the external tlmm26 watchdog](bootloop-postmortem.md); this one feeds it fine and
still dies).

**Root cause (proven 2026-10-24 by pstore-ftrace):**

1. The RG520N-EB on `pcie1` **crashes its own PCIe link** whenever it does a subsystem
   restart (SSR) — triggered by poor RF, or by a D3hot power transition.
2. The root port raises a **PCIe AER** interrupt.
3. The kernel AER service walks the bus to find the source:
   `aer_isr -> pci_walk_bus -> find_device_iter`, reading the **config space of every
   device** — including the modem, whose link is now down.
4. That config read is an MMIO to a dead link. It never completes (CmpltTO) and
   **hangs the CPU inside the interrupt handler**.
5. With the CPU stuck in the handler, the external tlmm26 watchdog is not fed for
   >1.5 s. It bites. The board resets, silently, with no path to log anything.

The hanging call chain was captured directly: `aer_isr -> ... -> dw_pcie_rd_other_conf`.

**Fix** — `bootargs-append` in the DTS:

```
pci=noaer pcie_ports=compat
```

- `pci=noaer` disables AER, so nothing walks the bus on a link error.
- `pcie_ports=compat` is needed **as well**: PME is another port service that reads
  config space on an error and can hang in exactly the same way. Compat mode keeps
  every port service out of the way, not just AER.

**Why not a bus reset:** a runtime SBR is not available here — the root port's
`reset_subordinate` returns `-ENOTTY`, i.e. no bus-reset method.

## The instrument: ramoops

A `ramoops@4a300000` node carves 1 MiB of DRAM below the firmware reserve
(`tz_apps@4a400000`) for a persistent RAM console plus function trace. A warm watchdog
reset keeps DRAM, so the pre-reset state survives into `/sys/fs/pstore`. It needs
`CONFIG_PSTORE*` and `CONFIG_REED_SOLOMON*` (in `ipq50xx/config-default`).

**It is kept deliberately**, even though it has already done its job. This board resets
silently by design — external WDT, no panic path — so without a persistent console a
future reset leaves no trace at all. The cost is 1 MiB of DRAM.

## Recovering the modem afterwards

`pci=noaer` stops the *host* from dying. It does not bring the *modem* back. That is
left to wwand's recovery ladder: modem reset first, a board reboot as the top rung.

**HW-tested 2026-10-29**, after the modem latched `MHI SYSERR`
(`mhi mhi0: Failed to reset MHI due to syserr state`, probe `-110`):

| Action | Result |
|---|---|
| unbind/rebind `mhi-pci-generic` on `0001:01:00.0` | frees a daemon wedged on the dead link; **does not** clear SYSERR |
| PCI `remove` + `rescan` (full re-enumeration, link retrains at 5 GT/s x1) | **does not** clear SYSERR |
| board `reboot` | **clears it** — all `mhi0_*` channels return, bearer reconnects |

So host-side resets are not enough for a latched modem: only a reboot is. Any automatic
recovery for this failure mode has to be able to reach that rung — wwand ≥ 1.7.2 does
(`vanish_reboot_after`, default 900 s, gated by `failreboot`).

**The vendor firmware cannot do better** (checked 2026-10-29 against the extracted QSDK
rootfs and Quectel's out-of-tree `pcie_mhi`, which is what the vendor loads — not mainline
`mhi-pci-generic`):

- `mhi_qti.c mhi_power_up()`: on finding `MHI_STATE_SYS_ERR` it writes `MHI_STATE_RESET`,
  polls for `timeout_ms`, and if the device is still in SYS_ERR it **returns `-EIO` and
  aborts the power-up** — the same give-up mainline showed us.
- `mhi_status_cb()` for `MHI_CB_SYS_ERROR`: only `pm_runtime_forbid()`. No recovery.
- `mhi_pm_sys_err_worker()`: only `mhi_pm_disable_transition(MHI_PM_SYS_ERR_PROCESS)` — a
  teardown, not a recovery.
- No `esoc` / `subsys_restart` power-cycle path in the driver, and no userspace script in
  the vendor rootfs that resets, re-powers or "refreshes" the modem.

So there is no vendor trick to copy here, and swapping mainline's controller for Quectel's
`pcie_mhi` would not change this outcome. Don't go looking again.

### There is no modem power line on this board

Checked against the **vendor DTB**, extracted from the QSDK kernel volume of the NAND
backup (`model = "Qualcomm Technologies, Inc. IPQ5018/AP-MP03.6-C1"`). Every GPIO the
vendor firmware drives:

| GPIO | vendor property (node) | purpose |
|---|---|---|
| 13 | `gpios` (`gpio_keys/button@2`) | `wlan` button |
| 15 | `perst-gpio` (`pci@a0000000`) | QCN9074 PERST |
| **18** | **`perst-gpio` (`pci@80000000`)** | **modem PERST — the only modem control line** |
| 24 | `device-power-gpio` (`usb3@8A00000`) | USB VBUS, not the modem |
| 32 | `reset-gpio` | AW9523 RSTN |
| 38 | `gpios` (`gpio_keys/button@1`) | `wps` button |
| 39 | `phy-reset-gpio` | ethernet PHY reset |

The modem's PCIe node carries **only** `perst-gpio`. No power GPIO, no `supply`
property, and there is no GPIO-controlled regulator anywhere in the vendor DTB.
`device-power-gpio` sits in the USB3/DWC3 node, and this port disables USB anyway (the
combo PHY is committed to PCIe).

**This is why wwand's `reset_gpio` / `repower_time` cannot power-cycle the modem here.**
Those options exist to hold a modem's power (or reset) line asserted for
`repower_time` seconds — they need such a line to drive, and this board does not have
one. `usb_repower` is a no-op on a PCIe/MHI modem for the same reason. The recovery
ladder consequently has nothing between *"reset the modem over QMI"* (which needs a
modem that still answers) and *"reboot the board"*.

### The one path still untested: a deliberate PERST toggle

PERST# (GPIO 18) is the only modem line that exists, and on SDX6x it is normally wired
to the modem's reset input — so unlike an MHI register reset (which needs the modem's
firmware to cooperate), asserting it may reset the modem SoC outright. **It has not been
tested**, because neither action tried on 2026-10-29 actually drives it:

- unbinding `mhi-pci-generic` rebinds the **endpoint** driver; the host controller keeps
  the link up and never touches PERST
- `remove` + `rescan` re-enumerates from config space; the link is not brought down at
  the host either
- there is no FLR knob (`/sys/bus/pci/devices/0001:01:00.0/reset` does not exist), and
  the root port has no secondary-bus-reset method (`reset_subordinate` → `-ENOTTY`)

What *would* drive PERST is unbinding the **host controller**, which tears the link down
and re-asserts PERST on the way back up. The modem's controller is `80000000.pcie`
(domain `0001`; `a0000000.pcie` is the QCN9074 in domain `0000`):

```sh
echo 80000000.pcie > /sys/bus/platform/drivers/qcom-pcie/unbind
echo 80000000.pcie > /sys/bus/platform/drivers/qcom-pcie/bind
```

Two caveats before trying it. It only means anything **while the modem is actually
latched in SYSERR** — on a healthy modem it proves nothing. And it removes the whole PCI
domain, not just the endpoint, so if the rebind fails the modem is gone until a reboot
(which is the fallback anyway). If it does clear SYSERR, it is a far cheaper rung than
rebooting the router, and worth wiring into the recovery ladder.

## Related

- `patches-6.18/0958-bus-mhi-pci_generic-sdx-ip_hw0-ring-512.patch`,
  `0959-net-mhi_net-direct-inline-rx-refill.patch` — see [downlink-stall.md](downlink-stall.md)
- `patches-6.18/0960-bus-mhi-pci_generic-sdx-add-dun-at-channel.patch` — see [modem-modes.md](modem-modes.md)
- [bootloop-postmortem.md](bootloop-postmortem.md) — the *other* watchdog reset, fixed much earlier
