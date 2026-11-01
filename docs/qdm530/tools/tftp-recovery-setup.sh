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
PIDF=/tmp/qdm530-tftp.pid
if [ -s "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  kill "$(cat "$PIDF")" 2>/dev/null; sleep 1
fi
rm -f "$PIDF"

# Stop NetworkManager from managing this adapter, otherwise it strips the static IP
# every time the board reboots and flaps the link - which kills TFTP after the first
# block (the "Loading: *" stall).
nmcli device set "$IF" managed no 2>/dev/null || true
sleep 1

ip addr flush dev "$IF" 2>/dev/null
ip addr add "$SRV/24" dev "$IF"
ip link set "$IF" up
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
