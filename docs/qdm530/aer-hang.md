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

**A scoped replacement now exists in the tree, unvalidated.**
`0962-PCI-qcom-do-not-claim-aer-and-pme-on-ipq5018.patch` clears
`host->native_aer` and `host->native_pme` in `qcom_pcie_host_init()`, which is what
`portdrv` consults in `get_port_device_capability()`, so the two services are never
instantiated on this host. It has to happen there rather than after
`dw_pcie_host_init()` returns, because that function calls `pci_host_probe()` and
that is what creates and binds the service devices. Gated on an IPQ5018-specific cfg,
since the other SoCs sharing `ops_2_9_0` also disable the completion timeout but have
not been shown to behave the same way on a dead-link transaction.

That is narrower than the command line, which disables AER machine-wide and puts every
port service on every host into compat mode — but it is **not equivalent**, and the
boot arguments stay until it is tested on hardware. `pcie_ports=native` would override
the flags, compat suppresses more than these two, and the remaining services stay
eligible on their own terms. None of them performs the AER source-discovery walk, but
hotplug can enumerate and remove downstream devices, so that wants its own look.

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

### Three ways to recover the modem were tried on hardware. All three failed.

The wedge this port keeps hitting leaves the modem unusable with no reset that
works, so the recovery question was chased to the end. Recording the dead ends
because each one looked right until it was tested.

A further approach is carried in the tree and has **never been executed** — see
*"Unvalidated follow-up"* at the end. It is not a fourth data point and not a recovery
procedure; it is recorded so that nobody reads the three measured failures below as the
final word, and so the attempt is not rediscovered from scratch.

**1. Re-bind the PCIe host controller from the kernel ("Fix A").**
PERST# (GPIO 18) is the only modem control line this board has -- there is no
power line, see above -- and `pcie-qcom` drives it in
`qcom_ep_reset_{assert,deassert}()` around its probe. No userspace path reaches
it: the GPIO is claimed by the driver, `qcom-pcie` sets `suppress_bind_attrs` so
`/sys/bus/platform/drivers/qcom-pcie/` has no `bind`/`unbind`, runtime PM is
pinned active by a `pm_runtime_get_sync()` with no matching put, and there is
neither an FLR knob nor a secondary-bus-reset method (`reset_subordinate` ->
`-ENOTTY`). From kernel code it *is* reachable, because that flag hides the
sysfs attributes and not the capability, so `device_release_driver()` +
`device_attach()` on the host bridge's parent re-runs host deinit/init.

Deliberately triggered (`AT+CFUN=1,1` crashes the modem's PCIe link, so
`health_check` reads the vendor ID back as 0xffff) the chain fired exactly as
designed, and then made things worse:

```
mhi-pci-generic 0001:01:00.0: Device died
mhi-pci-generic 0001:01:00.0: Recovery failed: -25
recovery: re-binding PCIe host 80000000.pcie to re-assert PERST# (no reboot)
qcom-pcie 80000000.pcie: Unbalanced pm_runtime_enable!
qcom-pcie 80000000.pcie: Phy link never came up
qcom-pcie 80000000.pcie: probe with driver qcom-pcie failed with error -28
```

The controller was left unbound and the modem could not return until a reboot.
Without the re-bind the controller stays bound and the modem has time to
re-enumerate on its own -- the re-probe gave the link one second (549.0 ->
550.0) while a modem restarting needs 20-30. And the deeper reason is not the
timing: **`qcom-pcie` has no `.remove` callback at all** and never calls
`pm_runtime_disable()`, which is what `suppress_bind_attrs` is saying. The
teardown leaves runtime PM unbalanced, `dw_pcie_host_deinit()` unrun and the old
PCI bus in place. Upstream is adding `shutdown()` to this driver, not
`remove()`, and is not dropping `suppress_bind_attrs`.

**2. A PCI device-specific reset for 17cb:0308.**
The SDX6x has a hardware reset -- the MHI SoC reset request at BAR0 + 0xb0 --
and a pending upstream series registers it in `pci_dev_reset_methods[]`, which
would make `pci_try_reset_function()` succeed so rung 1 is never reached. It was
backported (modem entry only; the series' WLAN entries are 17cb:1103/1107 while
this board carries a QCN9074, 17cb:1104, which already has a working reset).

It registers and executes correctly. `/sys/bus/pci/devices/0001:01:00.0/reset`
appeared, and writing to it drove a clean teardown:

```
mhi-pci-generic 0001:01:00.0: reset
wwan wwan0: port wwan0qcdm0 disconnected   (and mbim0, qmi0, at0)
```

Then the console stops. No `.reset_done`, no MHI power-on, UBIFS needing
recovery on the next boot and **no new pstore panic record** -- a watchdog bite,
not a panic. The reset write is not the problem: the console ran for two more
seconds, through the quirk's `msleep(2000)`. The stall is in what follows, when
the driver re-initialises MHI and does MMIO to a modem whose link is still down.
Upstream tested the quirk on x86 desktops, where the host bridge synthesises an
all-ones response instead of hanging.

**3. Enabling PCIe completion timeouts. Do not.**
The root port has the capability -- `DevCap2 = 0x00001c1f` advertises all four
ranges -- but `pcie-qcom` disables it: `qcom_pcie_post_init_2_9_0()` (the config
`qcom,pcie-ipq5018` selects) writes `PCI_EXP_DEVCTL2_COMP_TMOUT_DIS`, and the
root port reads back `DevCtl2 = 0x0410`. That is deliberate. On ARM64 Qualcomm
parts a completion timeout does not synthesise an all-ones response the way x86
root complexes do; it asserts **SError** -- asynchronous and unrecoverable --
plus a storm of Completion Timeout AERs. Turning it on trades a hang the
watchdog recovers from for a panic, and gains nothing.

### The common root cause

All three are the same failure in different clothes: **an access to a downed
PCIe link never completes, and this SoC has no timeout to end it.** The AER
handler hit it from an interrupt, the re-bind hit it during host re-probe, the
quirk hit it during post-reset re-init. And because the external tlmm26 watchdog
bites at ~1.5 s -- a hardware property of the supervisor chip, not a software
setting; `hw_margin_ms` only controls how often the kernel feeds it -- any such
stall becomes a silent board reset.

### The actual fix, and when it can be taken

Upstream's **outbound (ECAM) blocker** for `pcie-qcom`: on the link-down
interrupt the driver enables `ECAM_BLOCKER_EN` in `PARF_SYS_CTRL` over the whole
PCIe address space, so the hardware terminates these accesses locally instead of
letting them hang. It covers IP revisions 2.3.3, 2.7.0 and **2.9.0, which is
this board**.

It is **not in any released kernel**: absent from v6.18 and v6.19, present only
in mainline master, so v6.20 at the earliest. It cannot be backported alone --
it needs the global-interrupt handler, `INT_ALL_LINK_DOWN` and
`pci_host_handle_link_down()` (a PCI core addition), none of which 6.18 has; a
dry run leaves 2 of 12 hunks failing and several others applying with fuzz. And
bumping this tree's kernel for it is not sensible either: 544 patches would have
to be forward-ported (176 generic backport, 201 pending, 67 hack, 100
qualcommax) to reach a release that still does not contain the blocker.

**When the kernel here reaches >= 6.20, in this order and separately:**

1. take the outbound blocker;
2. **keep `pci=noaer`** -- the blocker is best-effort by its author's own
   account, with a race window between link-down and activation, and on this
   board a stall in that window is a reboot rather than a logged error. The two
   are complementary: the blocker catches accesses that happen, `noaer` removes
   one source of them;
3. only then re-evaluate the 17cb:0308 reset quirk, which may well be safe once
   post-reset MMIO is terminated rather than hanging.

### Unvalidated follow-up — not a recovery procedure

`0963-PCI-add-a-host-bridge-link-recovery-hook.patch` adds a `->link_recover` hook to
`struct pci_host_bridge`, implements it in `pcie-qcom` as a deinit/PERST/init/setup_rc/
start_link cycle that touches only SoC-local resources, and drives it from
`mhi-pci-generic` as one operation behind a single sysfs write: quiesce MHI, cycle the
link, restore the endpoint.

It exists because each earlier attempt had half of it right. The host re-bind cycled
PERST# but left `qcom-pcie` unbound for good; the reset quirk cleared the modem's
SYSERR but then stalled re-initialising an endpoint across a link that was not up yet.

**What is established:** it compiles, the implementation is what the paragraphs above
describe, and it survived several review rounds against the MHI and PCI source.

**What is not:** anything about recovery. No recovery has ever been run on this board, and
both observed wedge modes remain exactly as unresolved as they were before the patch
existed — link down after an SSR, and link up with MHI SYSERR latched while
`health_check` still reads a valid vendor ID. The patch is the experiment, not the result.
It will either move up into the measured history above as a fourth failure, or out of this
section as a fix, once it has been run.

Until then the modem's recovery is wwand's ladder reaching its reboot rung, and
the mitigation that matters most is not a kernel patch at all: the band-lock fix
took RSRP from -113 to -93 dBm, which removes the RF stress that triggers the
modem SSRs in the first place.

### The vendor has no recovery for this at any layer

Checked against the extracted QSDK rootfs, Quectel's out-of-tree `pcie_mhi`
(what the vendor loads instead of mainline `mhi-pci-generic`), and the vendor
kernel itself (LZMA inside the FIT in the `kernel` UBI volume):

- `mhi_qti.c mhi_power_up()`: on `MHI_STATE_SYS_ERR` it writes
  `MHI_STATE_RESET`, polls for `timeout_ms`, and if the device is still in
  SYS_ERR **returns `-EIO` and aborts** -- the same give-up mainline showed us.
- `mhi_status_cb()` for `MHI_CB_SYS_ERROR`: only `pm_runtime_forbid()`.
- `mhi_pm_sys_err_worker()`: only `mhi_pm_disable_transition()` -- a teardown.
- the endpoint's QSDK PCIe integration (`QCOM_AP_AND_EFUSE_PCIE_SLEEP`)
  registers for `MSM_PCIE_EVENT_WAKEUP` only and calls
  `msm_pcie_pm_control(SUSPEND/RESUME)`: power management, never recovery.
- the vendor kernel does carry a debugfs menu with `enumerate: de-assert PERST,
  enumerate PCIe` / `linkdown: bring down PCIe link`, but it belongs to **cnss2
  (WLAN)**, not the modem -- its neighbours are `cnss/dev_boot`,
  `cnss/reg_read`, `WLAN_EN`.
- no userspace script in the vendor rootfs resets, re-powers or refreshes it.

Structurally the vendor could not fix it anyway: in this failure the PCIe link
stays up (it trains at 5 GT/s x1 while MHI is dead), so no PCIe-layer mechanism
has an event to react to, and the MHI layer -- the only one that knows -- never
signals the PCIe layer.

One thing the vendor exposes that mainline does not:
`mhi_debugfs_trigger_reset` (plus `_m0`/`_m3`). It drives the same MHI reset
that gives up under SYS_ERR, so it is a manual handle on a known-insufficient
mechanism.

### Reproducing the wedge on purpose

`AT+CFUN=1,1` through `/dev/wwan0at0` (patch 0960's channel) crashes the modem's
PCIe link reliably, which is what `health_check` detects -- it reads the PCI
vendor ID and only treats 0xffff/0 as death, so it catches a **link** loss and
not an MHI-level wedge. That is why `Device died` never appeared during the
40-hour freeze on 28 Oct, when MHI was dead but the link was up.

Do not use `AT+QPOWD`: it powers the modem down and it does not come back
without a power cycle.

## Related

- `patches-6.18/0958-bus-mhi-pci_generic-sdx-ip_hw0-ring-512.patch`,
  `0959-net-mhi_net-direct-inline-rx-refill.patch` — see [downlink-stall.md](downlink-stall.md)
- `patches-6.18/0960-bus-mhi-pci_generic-sdx-add-dun-at-channel.patch` — see [modem-modes.md](modem-modes.md)
- [bootloop-postmortem.md](bootloop-postmortem.md) — the *other* watchdog reset, fixed much earlier
