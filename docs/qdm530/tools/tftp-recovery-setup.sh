#!/bin/bash
# Set up a USB-Ethernet interface + dnsmasq TFTP server for booting the QDM530 over
# TFTP from U-Boot. Plug the USB-Ethernet adapter into the board's LAN port FIRST,
# then run this with sudo. TFTP root = /tmp/tftp (place the image, e.g. imm.itb,
# there first). Matches the board's factory U-Boot env (serverip 192.168.10.19).
set -u
SRV=192.168.10.19

# find a USB-ethernet interface (enpXsYfZuW pattern, or any non-wifi/non-virtual
# ethernet that is not lo)
# The interface MUST be named explicitly. This script flushes the addresses off it and
# takes it away from NetworkManager - and auto-picking "the first en*" can just as easily
# select the built-in NIC, i.e. the only working LAN on the machine running this.
IF="${1:-}"
if [ -z "$IF" ]; then
  echo "usage: $0 <interface>   (the USB-Ethernet adapter facing the board)" >&2
  echo "" >&2
  echo "This flushes addresses on that interface and sets it unmanaged, so it will not" >&2
  echo "guess. Candidates, newest first - check against 'dmesg | tail' after plugging in:" >&2
  for n in $(ls -t /sys/class/net); do
    [ -e "/sys/class/net/$n/device" ] || continue
    case "$n" in lo|wl*|docker*|virbr*|veth*|br-*) continue;; esac
    printf '  %-12s %s\n' "$n" "$(cat "/sys/class/net/$n/operstate" 2>/dev/null)" >&2
  done
  exit 1
fi
[ -e "/sys/class/net/$IF" ] || { echo "ERROR: no such interface: $IF" >&2; exit 1; }
echo "interface = $IF"

# Only kill an instance this script started, recorded in its pidfile - 'pkill -f dnsmasq.*tftp'
# also matches somebody else's TFTP server.
# A pidfile plus kill -0 does not establish ownership: the file can be stale and its pid
# recycled by something unrelated, and removing it unconditionally throws away the
# identifier of a process that may still be alive. So: do not kill anything automatically.
# Serialise instead, and make the operator deal with a leftover.
PIDF=/run/qdm530-tftp.pid
[ -w /run ] || PIDF=/tmp/qdm530-tftp.pid
LOCKDIR=/tmp/qdm530-tftp.lock
mkdir "$LOCKDIR" 2>/dev/null || { echo "ERROR: another $0 appears to be running ($LOCKDIR)" >&2; exit 1; }
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

if [ -s "$PIDF" ]; then
  oldpid=$(cat "$PIDF")
  if kill -0 "$oldpid" 2>/dev/null && grep -qa dnsmasq "/proc/$oldpid/cmdline" 2>/dev/null; then
    echo "ERROR: a dnsmasq from a previous run is still live (pid $oldpid, $PIDF)." >&2
    echo "       Stop it yourself - this will not kill a process it cannot prove it owns:" >&2
    echo "         kill $oldpid && rm -f $PIDF" >&2
    exit 1
  fi
  echo "note: stale $PIDF (pid $oldpid is gone or not dnsmasq) - removing"
  rm -f "$PIDF"
fi

# Stop NetworkManager from managing this adapter, otherwise it strips the static IP
# every time the board reboots and flaps the link - which kills TFTP after the first
# block (the "Loading: *" stall).
nmcli device set "$IF" managed no 2>/dev/null || true
sleep 1

# set -u is not error handling: a failed address or link setup used to leave a half
# configured recovery interface and carry on starting services on it.
ip addr flush dev "$IF" 2>/dev/null
ip addr add "$SRV/24" dev "$IF" || { echo "ERROR: could not add $SRV/24 to $IF" >&2; exit 1; }
ip link set "$IF" up            || { echo "ERROR: could not bring $IF up" >&2; exit 1; }
sleep 1
ip -br addr show "$IF"

mkdir -p /tmp/tftp
dnsmasq --port=0 --enable-tftp --tftp-root=/tmp/tftp --interface="$IF" --bind-interfaces --listen-address="$SRV" --pid-file="$PIDF"
sleep 1
# Check OUR pid, not "is any dnsmasq running" - the latter reports success when an
# unrelated instance happens to be up and ours failed.
if [ -s "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  echo "dnsmasq TFTP up on $SRV ($IF), pid $(cat "$PIDF")"
else
  echo "dnsmasq FAILED to start" >&2; exit 1
fi
ss -ulnp 2>/dev/null | grep "$SRV:69" && echo "port 69 listening OK"
echo "contents of /tmp/tftp:"; ls -l /tmp/tftp/ 2>/dev/null
