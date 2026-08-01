#!/usr/bin/env bash
# A version profile must declare exact host-visible application paths. Binding
# both the complete datadir and Knots binary prevents a competing chain copy.
set -Eeuo pipefail
adapter_fail() { echo "error: $*" >&2; exit 1; }
adapter_load() {
  local platform="$1" profile="/etc/bvml/${platform}-profile.env"
  [[ -r "$profile" ]] || adapter_fail "missing release profile: $profile"
  source "$profile"
  for v in SUPPORTED_VERSION DETECTED_VERSION APP_SERVICE APP_DATADIR APP_DATADIR_RUNTIME APP_CONFIG APP_BITCOIND_PATH KNOTS_BINARY; do
    [[ -n "${!v:-}" ]] || adapter_fail "$profile must declare $v"
  done
  [[ "$DETECTED_VERSION" == "$SUPPORTED_VERSION" ]] ||
    adapter_fail "unsupported $platform release $DETECTED_VERSION (profile supports $SUPPORTED_VERSION)"
  [[ -x "$KNOTS_BINARY" ]] || adapter_fail "pinned Knots binary missing: $KNOTS_BINARY"
  "$KNOTS_BINARY" --version | grep -qi knots || adapter_fail "configured binary is not Bitcoin Knots"
}
adapter_install() {
  local platform="$1"; adapter_load "$platform"
  local device="${BITCOIN_DEVICE:-/dev/vdc}" mount="${BITCOIN_MOUNT:-/mnt/bvml-bitcoin}"
  [[ -b "$device" ]] || adapter_fail "overlay disk missing: $device"
  sudo systemctl stop "$APP_SERVICE"
  pgrep -x bitcoind >/dev/null && adapter_fail "bitcoind remains active after stopping $APP_SERVICE"
  uuid="$(blkid -s UUID -o value "$device")"; [[ -n "$uuid" ]] || adapter_fail "overlay has no filesystem"
  sudo install -d -m 0750 "$mount" "$APP_DATADIR"
  if [[ -n "$(find "$APP_DATADIR" -mindepth 1 -maxdepth 1 -print -quit)" ]] && ! mountpoint -q "$APP_DATADIR"; then
    adapter_fail "$APP_DATADIR already contains data; move it aside deliberately before installing the adapter"
  fi
  grep -q "UUID=$uuid " /etc/fstab ||
    echo "UUID=$uuid $mount ext4 defaults,nofail,x-systemd.device-timeout=30 0 2" | sudo tee -a /etc/fstab >/dev/null
  sudo mountpoint -q "$mount" || sudo mount "$mount"
  [[ -d "$mount/blocks" && -d "$mount/chainstate" ]] || adapter_fail "mounted disk is not a complete Bitcoin datadir"
  if mountpoint -q "$APP_DATADIR"; then sudo umount "$APP_DATADIR"; fi
  sudo mount --bind "$mount" "$APP_DATADIR"
  grep -qF "$mount $APP_DATADIR none bind" /etc/fstab ||
    echo "$mount $APP_DATADIR none bind,x-systemd.requires-mounts-for=$mount 0 0" | sudo tee -a /etc/fstab >/dev/null
  sudo mount --bind "$KNOTS_BINARY" "$APP_BITCOIND_PATH"
  grep -qF "$KNOTS_BINARY $APP_BITCOIND_PATH none bind" /etc/fstab ||
    echo "$KNOTS_BINARY $APP_BITCOIND_PATH none bind,ro 0 0" | sudo tee -a /etc/fstab >/dev/null
  sudo touch "$APP_CONFIG"
  sudo sed -i '/^[[:space:]]*datadir=/d;/^[[:space:]]*blocksxor=/d' "$APP_CONFIG"
  printf 'datadir=%s\nblocksxor=0\n' "$APP_DATADIR_RUNTIME" | sudo tee -a "$APP_CONFIG" >/dev/null
  sudo install -d -m 0755 /etc/systemd/system/"$APP_SERVICE".d
  sudo tee /etc/systemd/system/"$APP_SERVICE".d/bitcoin-vm-lab.conf >/dev/null <<EOF
[Unit]
RequiresMountsFor=$APP_DATADIR
ConditionPathIsMountPoint=$APP_DATADIR
EOF
  sudo systemctl daemon-reload
}
adapter_verify() {
  local platform="$1"; adapter_load "$platform"
  findmnt -n "$APP_DATADIR" >/dev/null || adapter_fail "$APP_DATADIR is not a mount"
  [[ "$(findmnt -n -o SOURCE "$APP_DATADIR")" == "$(findmnt -n -o SOURCE "${BITCOIN_MOUNT:-/mnt/bvml-bitcoin}")" ]] ||
    adapter_fail "packaged datadir is not backed by the overlay filesystem"
  cmp -s "$KNOTS_BINARY" "$APP_BITCOIND_PATH" || adapter_fail "packaged bitcoind is not pinned Knots"
  grep -Fxq "datadir=$APP_DATADIR_RUNTIME" "$APP_CONFIG" || adapter_fail "packaged configuration does not select overlay datadir"
  grep -Fxq 'blocksxor=0' "$APP_CONFIG" || adapter_fail "packaged configuration lacks blocksxor=0"
  systemctl is-enabled "$APP_SERVICE" >/dev/null
  echo "$platform adapter verified: $APP_DATADIR uses attached overlay and $APP_BITCOIND_PATH is Knots"
}
adapter_stop() {
  local platform="$1"; adapter_load "$platform"
  sudo systemctl stop "$APP_SERVICE"
  pgrep -x bitcoind >/dev/null && adapter_fail "Bitcoin did not stop cleanly"
  sync
}
