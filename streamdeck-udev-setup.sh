#!/usr/bin/env bash
# Stream Deck Plus udev setup — steps 2+3 of the install plan.
# Run with: sudo bash streamdeck-udev-setup.sh
set -euo pipefail

RULE='/etc/udev/rules.d/10-streamdeck.rules'

printf 'SUBSYSTEMS=="usb", ATTRS{idVendor}=="0fd9", GROUP="users", TAG+="uaccess"\n' > "$RULE"
echo "wrote $RULE:"
cat "$RULE"

udevadm control --reload-rules
udevadm trigger
echo
echo "RULE + RELOAD + TRIGGER OK"
echo ">>> Now physically unplug and replug the Stream Deck Plus, then tell Claude."
