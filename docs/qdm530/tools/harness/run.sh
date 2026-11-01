#!/bin/bash
# Exercises the FAILURE branches of the qdm530 slot tooling against a fake board.
# Each case runs the real script, unmodified, inside its own mount namespace.
REPO=${REPO:-/home/huda/Documents/immortalwrt}
HERE=$(cd "$(dirname "$0")" && pwd)
SI=$REPO/docs/qdm530/tools/slot-install.sh
RV=$REPO/docs/qdm530/tools/restore-vendor.sh
BS=$REPO/target/linux/qualcommax/ipq50xx/base-files/usr/sbin/bootslot
pass=0; fail=0
IMGOK=$(mktemp /tmp/himg.XXXXXX); printf 'UBI#' > "$IMGOK"; truncate -s 4096 "$IMGOK"
IMGBAD=$(mktemp /tmp/himg.XXXXXX); printf 'JUNK' > "$IMGBAD"; truncate -s 4096 "$IMGBAD"

# run <name> <script+args> <env assignments...> ; then assert_* on $OUT/$RC/$MARKDIR
runcase() {
	NAME=$1; shift
	SCRIPT=$1; shift
	WORK=$(mktemp -d /tmp/hcase.XXXXXX)
	OUTF=$WORK/out
	env "$@" WORK="$WORK" REPO="$REPO" STDIN_DATA="${STDIN_DATA:-}" unshare -rm sh -c '
		. '"$HERE"'/env.sh
		printf '%s' "$STDIN_DATA" | sh '"$SCRIPT"' 2>&1
		echo "RC=$?"
	' > "$OUTF" 2>&1
	RC=$(sed -n 's/^RC=//p' "$OUTF" | tail -1)
	OUT=$(cat "$OUTF")
	MARKD=$WORK/mark
}
ok()   { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; printf '        %s\n' "$2"; }
want_rc()      { [ "$RC" = "$1" ] && ok "$2" || bad "$2" "expected rc=$1, got rc=$RC"; }
want_noreboot(){ [ -e "$MARKD/reboot" ] && bad "$1" "reboot WAS called" || ok "$1"; }
want_reboot()  { [ -e "$MARKD/reboot" ] && ok "$1" || bad "$1" "reboot was NOT called"; }
want_out()     { case "$OUT" in *"$1"*) ok "$2";; *) bad "$2" "output lacks: $1";; esac; }
want_nofile()  { [ -e "$MARKD/$1" ] && bad "$2" "$1 marker exists (ran when it should not)" || ok "$2"; }

echo "== slot-install.sh: argument validation (must refuse before anything destructive)"
runcase a1 "$SI detect" PRIMARYBOOT=7
want_rc 1 "primaryboot=7 refused";          want_nofile ubiformat "nothing formatted"
runcase a2 "$SI detect" UPGRADEPART=bogus
want_rc 1 "upgradepartition=bogus refused"; want_nofile ubiformat "nothing formatted"

echo "== slot-install.sh: required tools checked before destruction"
runcase a3 "$SI detect" MISSING_TOOL=fw_setenv
want_rc 1 "missing fw_setenv refused";      want_out "missing required tool" "says which tool"
want_nofile ubiformat "nothing formatted"

echo "== bootslot: refuses a disagreeing pair and an occupied scratch"
runcase b1 "$BS status"
want_rc 0 "status works on an agreeing pair"
runcase b2 "$BS switch" UBI9_BUSY=1
want_out "already attached" "occupied ubi9 refused"

echo "== slot-install.sh: the round-10 blocker - fw_setenv failure must NOT reboot"
STDIN_DATA=YES runcase c1 "$SI $IMGOK" FW_SETENV_FAIL=1
want_noreboot "no reboot when fw_setenv fails"
want_rc 1     "exits non-zero"
want_out "NOT rebooting" "tells the operator it stopped"
want_out "may then MIRROR" "explains what is at risk"

echo "== slot-install.sh: success path still reboots (so the test above means something)"
STDIN_DATA=YES runcase c2 "$SI $IMGOK"
want_reboot "reboot happens when everything succeeds"

echo "== slot-install.sh: truncated serializer output refused before any flash write"
STDIN_DATA=YES runcase c3 "$SI $IMGOK" BC_TRUNCATE=1
want_rc 1 "truncated record refused"
[ -e "$MARKD/mtdwrite" ] && bad "no flash write attempted" "mtd was called" || ok "no flash write attempted"
want_noreboot "no reboot"

echo "== slot-install.sh: serializer disagreeing with itself is refused"
STDIN_DATA=YES runcase c4 "$SI $IMGOK" BC_DISAGREE=1
want_rc 1 "inconsistent pair refused"
[ -e "$MARKD/mtdwrite" ] && bad "no flash write attempted" "mtd was called" || ok "no flash write attempted"

echo "== slot-install.sh: second BOOTCONFIG write fails -> no reboot"
STDIN_DATA=YES runcase c5 "$SI $IMGOK" MTD_WRITE_FAIL_N=2
want_noreboot "no reboot after a failed second copy"
want_rc 1 "exits non-zero"

echo "== slot-install.sh: lock is shared with bootslot"
WORK0=$(mktemp -d /tmp/hlock.XXXXXX)
grep -q "LOCKDIR=/tmp/bootslot.lock" "$SI" && ok "slot-install uses bootslot's lock dir" \
  || bad "slot-install uses bootslot's lock dir" "it does not"
grep -q "LOCKDIR=/tmp/bootslot.lock" "$BS" && ok "bootslot uses the same dir" \
  || bad "bootslot uses the same dir" "it does not"

echo "== restore-vendor.sh: refuses a non-UBI image before formatting"
STDIN_DATA=YES runcase d1 "$RV $IMGBAD" VENDOR_VOLS=1
want_rc 1 "non-UBI image refused"
want_nofile ubiformat "nothing formatted"
want_out "UBI EC-header magic" "says why"

echo "== restore-vendor.sh: refuses an active mtd outside the rootfs pair"
STDIN_DATA=YES runcase d2 "$RV $IMGOK" ACTIVE_MTD=9 VENDOR_VOLS=1
want_out "neither rootfs" "refuses an unrelated active slot"
want_nofile ubiformat "nothing formatted"

echo "== restore-vendor.sh: refuses an occupied scratch before formatting"
STDIN_DATA=YES runcase d3 "$RV $IMGOK" UBI9_BUSY=1 VENDOR_VOLS=1
want_nofile ubiformat "nothing formatted"
want_out "already attached" "says why"

echo "== bootslot: refuses when the two copies disagree"
runcase e1 "$BS switch" BC_MTD3_DIFFERENT=1
want_out "differ" "disagreeing copies refused"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
