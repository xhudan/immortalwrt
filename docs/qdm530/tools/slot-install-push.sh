#!/bin/sh
# QDM530 non-UART slot installer — PC SIDE.
# Transfers the factory.ubi + the board-side installer to the device and runs it with a
# live console (ssh -t), so you watch every step and confirm the final flip yourself.
#
# Usage:
#   ./slot-install-push.sh "<ssh target + opts>" <factory.ubi> [mode]
#
#   <ssh target + opts>  e.g.  "root@192.168.8.100 -o HostKeyAlgorithms=+ssh-rsa"
#                        (old vendor dropbear needs the legacy HostKeyAlgorithms option)
#   <factory.ubi>        the ImmortalWrt ...-unbranded_qdm530-squashfs-factory.ubi
#   [mode]               detect | stage | (empty = full detect+stage+flip)
#
# Examples:
#   ./slot-install-push.sh "root@192.168.8.100 -o HostKeyAlgorithms=+ssh-rsa" factory.ubi detect
#   ./slot-install-push.sh "root@192.168.8.100 -o HostKeyAlgorithms=+ssh-rsa" factory.ubi stage
#   ./slot-install-push.sh "root@192.168.8.100 -o HostKeyAlgorithms=+ssh-rsa" factory.ubi
#
# The board transfer uses `cat` over ssh (old dropbear has no sftp/scp). The installer
# itself verifies md5, checks the staged image's FIT+squashfs magic, and only flips the
# boot pointer after you type YES. See slot-install.sh for the full logic and the
# "NO UART recovery net" warning.

SSHTGT="$1"
IMG="$2"
RMODE="$3"
DIR=$(dirname "$0")

[ -n "$SSHTGT" ] || { echo "usage: $0 \"<ssh target + opts>\" <factory.ubi> [detect|stage]"; exit 1; }
[ -f "$IMG" ] || { echo "image not found: $IMG"; exit 1; }
[ -f "$DIR/slot-install.sh" ] || { echo "slot-install.sh not found next to this script"; exit 1; }

MD5=$(md5sum "$IMG" | cut -d' ' -f1)
echo ">> local image: $IMG"
echo ">> local md5  : $MD5"

# detect mode never transfers the image
if [ "$RMODE" = detect ]; then
	echo ">> transferring installer..."
	# shellcheck disable=SC2086
	ssh $SSHTGT 'cat > /tmp/slot-install.sh' < "$DIR/slot-install.sh"
	echo ">> running: slot-install.sh detect"
	# shellcheck disable=SC2086
	ssh -t $SSHTGT 'sh /tmp/slot-install.sh detect'
	exit $?
fi

echo ">> transferring image (cat over ssh)..."
# shellcheck disable=SC2086
ssh $SSHTGT 'cat > /tmp/factory.ubi' < "$IMG" || { echo "image transfer failed"; exit 1; }
echo ">> transferring installer..."
# shellcheck disable=SC2086
ssh $SSHTGT 'cat > /tmp/slot-install.sh' < "$DIR/slot-install.sh" || { echo "installer transfer failed"; exit 1; }

if [ "$RMODE" = stage ]; then
	echo ">> running: slot-install.sh stage (writes inactive slot, NO flip)"
	# shellcheck disable=SC2086
	ssh -t $SSHTGT "sh /tmp/slot-install.sh stage /tmp/factory.ubi $MD5"
else
	echo ">> running: slot-install.sh (full — will ask YES before the irreversible flip)"
	# shellcheck disable=SC2086
	ssh -t $SSHTGT "sh /tmp/slot-install.sh /tmp/factory.ubi $MD5"
fi
