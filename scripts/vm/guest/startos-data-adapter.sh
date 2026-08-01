#!/usr/bin/env bash
# Platform adapter: run inside StartOS. StartOS package data ownership is
# release-specific, so mounting is isolated here rather than hard-coded.
set -Eeuo pipefail
DEVICE="${BITCOIN_DEVICE:-/dev/vdc}"; MOUNT="${BITCOIN_MOUNT:-/mnt/bitcoin-overlay}"
sudo install -d -m 0755 "$MOUNT"
sudo mount "$DEVICE" "$MOUNT"
echo "Mounted $DEVICE at $MOUNT. Configure the StartOS Bitcoin package to use this path."
