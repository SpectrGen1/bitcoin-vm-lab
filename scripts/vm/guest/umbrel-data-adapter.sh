#!/usr/bin/env bash
# Platform adapter: run inside UmbrelOS after determining the local Umbrel
# Bitcoin application's supported external-data setting. It intentionally does
# not overwrite Umbrel-managed configuration.
set -Eeuo pipefail
DEVICE="${BITCOIN_DEVICE:-/dev/vdc}"; MOUNT="${BITCOIN_MOUNT:-/mnt/bitcoin-overlay}"
sudo install -d -m 0755 "$MOUNT"
sudo mount "$DEVICE" "$MOUNT"
echo "Mounted $DEVICE at $MOUNT. Bind/package this path using the Umbrel adapter setting for this release."
