# QDM530 — IPv6 dual-stack crash loop (Smartfren) and the wwand fix

On some carriers, running the cellular WAN as `pdp_type='ipv4v6'` puts the modem
into an **endless crash loop**: the WAN connects for ~1 s, the modem resets, and it
repeats forever. HW-observed on the Quectel RG520N-EB with **Smartfren (MCC/MNC
510/09)**. **XL Axiata (510/11)** is unaffected (it grants IPv6, so there is no
refusal to trip over).

This note records the diagnosis and the fix. The fix is two **wwand** patches
(upstream `ddimension/wwand`), kept here under `wwand-patches/` so they survive a
`./scripts/feeds update` and can be submitted upstream.

## Symptom

With `network.wan.pdp_type='ipv4v6'` on Smartfren, `logread` repeats every ~35–40 s:

```
interface wan: ipv4 up, pdh … (cid 2)
interface wan: starting ipv6: apn '(profile default)', profile 1
interface wan: ipv6 activation failed, continuing: PDN IPv6 call disallowed
   (internal 210) … "verbose": { "type": 2, "reason": 210 }
interface wan: state ACTIVATING -> CONNECTED
modem wwmodem: qrtr: modem node 3 gone (socket error on the client for service 1)
modem wwmodem: device disappeared
interface wan: state CONNECTED -> IDLE
   … ~35 s later the modem is back and the whole thing repeats …
```

`ifstatus wan` flaps between `up` and `pending`; there is no usable internet.

## Diagnosis

1. The network **refuses the IPv6 PDN** with WDS call-end **reason 210** ("PDN IPv6
   call disallowed"). This is carrier policy, not a SIM/signal/data-path fault — the
   IPv4 leg comes up fine right before it.
2. wwand already degrades gracefully in ucode ("IPv4 failure is fatal, IPv6 failure
   degrades to v4-only") and reaches CONNECTED on v4.
3. **But the modem's own data stack then crashes** on the teardown of the refused
   IPv6 WDS client — `qrtr: modem node … gone` / `device disappeared`, a full modem
   reset (~35–40 s). This is a **modem-firmware bug**; the router cannot stop the
   crash itself.
4. The crash makes the daemon **re-detect the modem and REBUILD the wwand context**
   (`daemon.uc` → `factory.create`). Because `pdp_type` is still `ipv4v6`, the fresh
   context re-requests IPv6 on the next connect → refusal → crash → rebuild → **loop**.

Confirmation that it is v6-specific: setting `pdp_type='ipv4'` stops the loop outright
(v4 comes up and stays, no `device disappeared`).

## The fix (two wwand patches)

Goal: keep `ipv4v6` as the default (so IPv6-capable carriers like XL still get
dual-stack) **and** stop the crash loop on carriers that refuse IPv6.

Approach: after IPv6 is shown to be unavailable, **stop re-attempting it** for the
rest of the session. The subtlety is **where** the "v6 unavailable" flag lives: a
field in the context's `self` is reset by the crash-driven context rebuild, so it
must live on the daemon's **per-interface entry**, which is carried across the
rebuild via the existing `prev?.…` mechanism (next to `_failed_at`).

- **`0001-context-no-v6-retry-after-reason-210.patch`** (`src-ucode/context.uc`)
  - keeps the decision on `opts.v6state` (`{ refused?, fails? }`), not `self`;
  - `wanted_families()` drops IPv6 when `v6state.refused`;
  - pins `v6state.refused` **immediately** on reason 210, **or** after **2**
    consecutive IPv6 failures of **any** reason (carriers report different codes);
  - a v6 family that actually comes up resets `v6state.fails`, so a dual-stack
    carrier never pins even across a one-off transient.
- **`0002-daemon-persist-v6state-across-context-rebuild.patch`** (`src-ucode/daemon.uc`)
  - carries `v6state` from the previous entry (`prev?.v6state ?? {}`) when a context
    is (re)built, and hands the live object to `factory.create`. **This is what makes
    the flag outlive the crash.**

Net behaviour per carrier:

| carrier | first connect | steady state |
|---|---|---|
| Smartfren (refuses v6) | 1 refusal + 1 modem crash | **stable IPv4**, v6 no longer attempted |
| XL (grants v6) | v6 succeeds, resets the counter | **dual-stack**, never pins |

A SIM swap / reboot / `ifdown`+`ifup` rebuilds state and re-probes v6 once.

## HW evidence (2026-10-11, RG520N-EB + Smartfren)

With the patched ucode and `pdp_type='ipv4v6'`:

```
wwand[5350]: starting ipv6 … → ipv6 activation failed … reason 210 → device disappeared   (1 crash)
wwand[5350]: starting ipv4 … → ipv4 up 10.122.208.44/32 → ACTIVATING -> CONNECTED           (next cycle: NO "starting ipv6")
```

`device disappeared` count then stays frozen (no new crashes over 60 s), `ifstatus wan`
is `up`, and `ping 1.1.1.1` returns 0 % loss. The loop is gone; IPv6 is simply dropped
on this carrier while IPv4 stays up.

## Upstream status

Not present in `ddimension/wwand` as of the version this project pins
(`1.7.0_pre7`, commit `4c6448277d5f587cd23d500f4b91c73d622ab5e8`). The nearest recent
upstream work (operator detach/attach + `with_sessions_released`, IPv6 prefix
delegation) is adjacent but does **not** address the refused-v6 crash loop.

**TODO (PR):** submit these two patches to `ddimension/wwand`, **rebased onto the
latest upstream** (context.uc / daemon.uc have moved since `4c6448277`; re-verify the
hunks — `0002` applied with fuzz 1 even against our pinned version). The daemon's new
`with_sessions_released` / failure-accounting path may suggest a tidier home for the
decision; defer to the maintainer on placement.
