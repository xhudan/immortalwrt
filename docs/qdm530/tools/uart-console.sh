#!/bin/sh
# QDM530 serial-console helper (PC side).
#
# Opens the UART console (ttyMSM0 @ 115200 8N1), auto-finding the USB-serial device. With
# -c it floods the U-Boot password ("quectel") so you can break into U-Boot even on a
# bootlooping board — the flood keeps retrying across every reset until you catch the prompt.
#
# Usage:
#   ./uart-console.sh            [device] [baud]     # just open the console
#   ./uart-console.sh -c         [device] [baud]     # flood 'quectel' to catch U-Boot (bootloop / first flash)
#
#   device   serial node (default: newest /dev/ttyUSB* or /dev/ttyACM*)
#   baud     default 115200
#
# Needs one of: picocom (preferred) / screen / minicom.
# Exit picocom with  Ctrl-A Ctrl-X  ; exit screen with  Ctrl-A \  (or k).

CATCH=0
case "$1" in -c|--catch) CATCH=1; shift ;; esac
PORT="$1"; BAUD="${2:-115200}"

# --- auto-detect the serial device ---
if [ -z "$PORT" ]; then
	PORT=$(ls -t /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | head -1)
fi
[ -n "$PORT" ] && [ -e "$PORT" ] || {
	echo "No serial device found. Plug the RJ12-to-USB console cable, or pass one explicitly:"
	echo "  $0 [-c] /dev/ttyUSB0"
	echo "(after plugging in, check:  dmesg | tail  — it usually appears as /dev/ttyUSB0)"
	exit 1
}
echo ">> console: $PORT @ $BAUD 8N1"

# --- pick a terminal program ---
if   command -v picocom >/dev/null 2>&1; then TERMCMD="picocom -b $BAUD $PORT"
elif command -v screen  >/dev/null 2>&1; then TERMCMD="screen $PORT $BAUD"
elif command -v minicom >/dev/null 2>&1; then TERMCMD="minicom -D $PORT -b $BAUD"
else echo "Install picocom (preferred), or screen / minicom."; exit 1; fi

# --- optional: catch U-Boot by flooding the password ---
if [ "$CATCH" = 1 ]; then
	echo ">> CATCH mode — flooding 'quectel' to break into U-Boot."
	echo ">> Now POWER-CYCLE the board. The flood retries on every reset (good for bootloops)."
	echo ">> When you see the U-Boot prompt (=> or #), press ENTER here to go interactive."
	stty -F "$PORT" "$BAUD" cs8 -cstopb -parenb -icrnl raw -echo 2>/dev/null
	cat "$PORT" & RD=$!
	( while :; do printf 'quectel\r' > "$PORT"; sleep 0.25; done ) & FL=$!
	trap 'kill $FL $RD 2>/dev/null' INT
	read _
	kill $FL $RD 2>/dev/null
	trap - INT
	# let the tty settle before the terminal re-opens it
	sleep 1
	echo ">> handing over to the interactive console ($TERMCMD)"
fi

exec $TERMCMD
