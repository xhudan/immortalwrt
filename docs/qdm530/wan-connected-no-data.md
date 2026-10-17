# QDM530 — "connected but no internet" after hours, and the WAN watchdog that fixes it

A recurring stall where the cellular WAN reports **CONNECTED** but no packets flow,
left unrecovered for hours. The fix is a small active-probe service that resets the
modem when the data path is provably dead. It took one wrong turn first — see "Why not
`context_failed`" — so this records both the fix and the trap.

## Symptom

After the board had been up a while (seen at ~8–10 h, and reproducibly right after a
reboot while the modem settles), the WAN goes dead while everything *says* it is fine:

- `ubus call wwand status` → bearer `"state": "CONNECTED"`, modem registered, signal
  present.
- But `wwand0` **rx frozen**, **100 % packet loss** to any public host, DNS dead. The
  control plane is up; the data path is not.
- It does **not** self-recover: internet stays down until a `ubus call wwand
  modem_reset` (or reboot). HW-seen the stall persist 9 h+.

The trigger is a modem **re-registration** (`state REGISTERING -> READY`, sometimes with
`carrier aggregation: no transport can serve this`): the data bearer is torn down and
does not re-establish, but QMI keeps reporting the old `CONNECTED` state, so wwand sees
nothing wrong.

Distinguish from two look-alikes before touching software:

- **Weak signal** — partial loss (e.g. 20–40 %) because the air link drops some packets,
  rsrp ≈ -105…-110 / rsrq ≈ -15…-17 / snr < 10 dB. Data still flows; a reset does not
  help (it is coverage, not bearer state). The stall here is **100 %** loss.
- **A marginal SIM contact** — HW-seen 2026-10-17: a Smartfren SIM that worked in a phone
  went `uim session closed: card error` → `SIM card not responding, possibly removed` →
  `SIM_BLOCKED` in this board (pin1 still had 3 retries, so NOT a PIN/PUK block), while an
  XL SIM ran fine in the same slot. Reseating / a reboot cleared it. A flaky SIM contact
  can itself cause the re-registrations that start the stall, so rule it out first
  (does the SIM work in a phone? does another SIM work in the board?).

## Why wwand does not catch it on its own

wwand *has* a zero-rx backstop (`context_monitor_qmi.uc` → `context_common.rx_stall_watch`,
threshold `zero_rx_timeout`), but on this board it cannot recover the link:

1. **The threshold is 6 h.** `config.uc` defaults `zero_rx_timeout` to 21600 s — sensible
   for battery/solar installs, far too long for a daily driver.
2. **Its recovery action is a no-op here.** On a trip it calls `trip_zero_rx() ->
   recovery.usb_repower()`, which needs a board repower profile (`board.uc` has none for
   `unbranded,qdm530`), a modem `reset_gpio`, or an external `usb-repower` tool — this
   PCIe/MHI board has none of the three, and it never falls back to `modem_reset`.

And active L3 probing inside the daemon is **by design** not wwand's job (an in-daemon
ping would guess source/route/zone and false-alarm under mwan3/VRF — ddimension/wwand#13).
L3 is measured outside; the daemon exposes `context_failed` as the join to its recovery
ladder.

## Why NOT `context_failed` (the trap)

The obvious wiring — probe fails → `ubus call wwand context_failed` → the daemon redials —
**crashes this modem.** `context_failed` tears the session down with a QMI `STOP_NETWORK`
(`daemon.uc context_failed` → `context.uc down` → `qmi_backend.stop_network`), and the
RG520N-EB **crashes its own data stack on STOP_NETWORK**: `device disappeared`, the modem
drops off MHI, goes `ABSENT`, and re-registers ~40 s later. (Same firmware fragility as
the refused-IPv6 teardown crash — see [ipv6-dualstack-crash-fix.md](ipv6-dualstack-crash-fix.md).)
HW-seen 2026-10-17: with a `context_failed`-based watchdog, **every** fire was followed in
the same second by `device disappeared -> ABSENT`; the watchdog then re-fired during the
re-register window, and the modem churned until it wedged (SIM read failed, needed a
reboot). The gentle, "native" rung was the most damaging thing we could do.

`modem_reset` (`modem.uc self.reset`: DMS offline→reset) does **not** issue a STOP_NETWORK —
it reboots the modem cleanly and recovers in ~40 s. So the watchdog resets; it never redials.

## The fix

`/usr/sbin/qdm530-wan-watchdog` (procd service `qdm530-wan-watchdog`, board-guarded,
enabled by `uci-defaults/29_enable-wan-watchdog`):

- Pings `8.8.8.8` / `1.1.1.1` every 30 s (public hosts — the modem gateway blocks ICMP on
  this carrier). A cycle "fails" only if **no** host answers.
- After `FAIL_LIMIT` (6) consecutive all-fail cycles — i.e. **~3 min of sustained 100 %
  loss** — **and only while wwand still reports CONNECTED**, it runs `ubus call wwand
  modem_reset`. The long window rides out boot-settle, transient fades, and weak-signal
  *partial* loss (which is never a sustained 100 %); the CONNECTED guard keeps it out of
  wwand's way while the modem is dialing/registering/absent.
- `MIN_RESET_GAP` (600 s) caps it to **at most one reset per 10 min** — resetting a modem
  this fragile is not free — and `SETTLE` (90 s) lets a reset re-register before probing
  resumes. All env-overridable at the top of the script.

No STOP_NETWORK, one clean reset per episode at most, nothing done to a link that is merely
weak or that wwand is already recovering.

## HW proof (2026-10-17, RG520N-EB)

The `context_failed` version: every fire → `device disappeared -> ABSENT`, churn, and a
wedged modem (the trap above). The `modem_reset` version: on a healthy / weak-signal link
(0–20 % loss) it stays **quiet** (6 min CONNECTED, 0 % loss, zero device-disappeared, zero
resets) — correctly idle because the loss is not a sustained 100 %. A manual `modem_reset`
is the proven recovery for the real stall (~40 s, no device-disappeared), which is exactly
what the watchdog now issues.

Related: [downlink-stall.md](downlink-stall.md) (a *different* rx-freeze — host MHI ring
starvation under load, fixed in-kernel), [ipv6-dualstack-crash-fix.md](ipv6-dualstack-crash-fix.md)
(the STOP_NETWORK/teardown crash fragility), [modem-wan-troubleshooting.md](modem-wan-troubleshooting.md).
