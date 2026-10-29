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

### PERST#: unreachable from userspace, reachable from the kernel

PERST# (GPIO 18) is the only modem control line this board has, and on SDX6x it is
normally wired to the modem's reset input -- so unlike an MHI register reset (which
needs the modem's firmware to cooperate), asserting it may reset the modem SoC
outright.

**No userspace path to it exists** (all verified on 6.18.54):

- the GPIO is claimed by the host controller driver
  (`pcie-qcom.c`: `devm_gpiod_get_optional(dev, "perst", ...)`), so it never appears
  in the gpio sysfs
- `qcom-pcie` sets `suppress_bind_attrs`, so `/sys/bus/platform/drivers/qcom-pcie/`
  has no `bind`/`unbind` -- only the device symlinks and `uevent`
- runtime PM is pinned active: probe calls `pm_runtime_get_sync()` with no matching
  put on the success path, and there are no runtime-PM ops, so `power/control`
  cannot produce a suspend either
- there is no FLR knob (`/sys/bus/pci/devices/0001:01:00.0/reset` does not exist) and
  the root port has no secondary-bus-reset method (`reset_subordinate` -> `-ENOTTY`)

`qcom_perst_assert()` is therefore reachable only from the driver's own host
init/deinit (`qcom_ep_reset_assert` / `qcom_ep_reset_deassert`).

**From kernel code it IS reachable**, and that is what the local "Fix A" does:
`suppress_bind_attrs` only hides the sysfs attributes, it does not remove the
capability, so `device_release_driver()` + `device_attach()` on the host bridge's
parent still run host deinit/init -- and with them PERST assert/de-assert. Fix A adds
to `drivers/bus/mhi/host/pci_generic.c`:

```c
device_release_driver(rb->host);   /* in-kernel equivalent of unbind */
device_attach(rb->host);           /* ...and bind */
```

scheduled from the recovery path:

```c
err_try_reset:
	err = pci_try_reset_function(pdev);
	if (err) {
		dev_err(&pdev->dev, "Recovery failed: %d\n", err);
		mhi_pci_schedule_host_rebind(pdev);
	}
```

**Its trigger is the limitation, not its mechanism.** It fires only after
`mhi_pci_recovery_work()` has run and `pci_try_reset_function()` has failed. In the
failures observed on 2026-10-28/29 that path never ran at all (`Recovery failed` and
`Device died`: zero hits in dmesg, `rebind=0` in the field log), so PERST has still
never actually been asserted. The mechanism is sound and untested, which is not the
same as unavailable.

> WARNING: Fix A currently exists ONLY as an edit to the extracted source under
> `build_dir`; it is not in `target/linux/qualcommax/patches-6.18/`. It is compiled
> into `mhi_pci_generic.ko` (`CONFIG_MHI_BUS_PCI_GENERIC=m`) and ships in the built
> image, but one `make dirclean` loses it. Capture it as a patch.

### The vendor has no recovery for this at any layer

Checked 2026-10-29 against the extracted QSDK rootfs, Quectel's out-of-tree
`pcie_mhi` (what the vendor loads instead of mainline `mhi-pci-generic`), and the
vendor kernel itself (LZMA inside the FIT in the `kernel` UBI volume):

- `mhi_qti.c mhi_power_up()`: on `MHI_STATE_SYS_ERR` it writes `MHI_STATE_RESET`,
  polls for `timeout_ms`, and if the device is still in SYS_ERR **returns `-EIO` and
  aborts the power-up** -- the same give-up mainline showed us.
- `mhi_status_cb()` for `MHI_CB_SYS_ERROR`: only `pm_runtime_forbid()`. No recovery.
- `mhi_pm_sys_err_worker()`: only `mhi_pm_disable_transition(MHI_PM_SYS_ERR_PROCESS)`
  -- a teardown, not a recovery.
- the endpoint's QSDK PCIe integration (`QCOM_AP_AND_EFUSE_PCIE_SLEEP`) registers for
  `MSM_PCIE_EVENT_WAKEUP` only, and calls `msm_pcie_pm_control(SUSPEND/RESUME)`:
  power management, never recovery. No `msm_pcie_recover*`, no link-down handler.
- the vendor kernel does carry a debugfs menu with `enumerate: de-assert PERST,
  enumerate PCIe` / `linkdown: bring down PCIe link` -- but it belongs to **cnss2
  (WLAN)**, not the modem: the neighbouring strings are `cnss/dev_boot`,
  `cnss/reg_read`, `cnss/runtime_pm`, `WLAN_EN`.
- no userspace script in the vendor rootfs resets, re-powers or "refreshes" the modem.

Structurally the vendor could not fix it anyway: in this failure the **PCIe link stays
up** (it trains at 5 GT/s x1 while MHI is dead), so no PCIe-layer mechanism has an
event to react to, and the MHI layer -- the only one that knows -- never signals the
PCIe layer. Nothing connects the two. Fix A is precisely that missing connection,
which is why it is novel rather than copied.

One thing the vendor does expose that mainline does not: `mhi_debugfs_trigger_reset`
(plus `_m0`/`_m3`). It drives the same MHI reset that gives up under SYS_ERR, so it is
a manual handle on a known-insufficient mechanism, not a new one.

## Related

- `patches-6.18/0958-bus-mhi-pci_generic-sdx-ip_hw0-ring-512.patch`,
  `0959-net-mhi_net-direct-inline-rx-refill.patch` — see [downlink-stall.md](downlink-stall.md)
- `patches-6.18/0960-bus-mhi-pci_generic-sdx-add-dun-at-channel.patch` — see [modem-modes.md](modem-modes.md)
- [bootloop-postmortem.md](bootloop-postmortem.md) — the *other* watchdog reset, fixed much earlier
