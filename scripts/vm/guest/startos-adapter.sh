#!/usr/bin/env bash
# Builds/installs an exact-version StartOS package override supplied by a profile.
set -Eeuo pipefail
fail() { echo "error: $*" >&2; exit 1; }
PROFILE=/etc/bvml/startos-profile.env
load() {
  [[ -r "$PROFILE" ]] || fail "missing exact StartOS package profile: $PROFILE"
  source "$PROFILE"
  for v in SUPPORTED_OS_VERSION DETECTED_OS_VERSION SUPPORTED_PACKAGE_VERSION DETECTED_PACKAGE_VERSION \
    PACKAGE_ID PACKAGE_PROJECT_DIR PACKAGE_BUILD_COMMAND PACKAGE_INSTALL_COMMAND \
    PACKAGE_CONTAINER_NAME CONTAINER_DATADIR KNOTS_RELEASE_DIR KNOTS_BITCOIND_SHA256 \
    BITCOIN_DEVICE BITCOIN_MOUNT; do
    [[ -n "${!v:-}" ]] || fail "$PROFILE must declare $v"
  done
  [[ "$SUPPORTED_OS_VERSION" == "$DETECTED_OS_VERSION" ]] || fail "unsupported StartOS version"
  [[ "$SUPPORTED_PACKAGE_VERSION" == "$DETECTED_PACKAGE_VERSION" ]] || fail "unsupported StartOS package version"
}
mount_disk() {
  load; [[ -b "$BITCOIN_DEVICE" ]] || fail "overlay disk absent"
  local uuid; uuid="$(blkid -s UUID -o value "$BITCOIN_DEVICE")"; [[ -n "$uuid" ]] || fail "overlay has no filesystem"
  sudo install -d -m 0750 "$BITCOIN_MOUNT"
  grep -q "^UUID=$uuid " /etc/fstab ||
    echo "UUID=$uuid $BITCOIN_MOUNT ext4 defaults,x-systemd.device-timeout=30 0 2" | sudo tee -a /etc/fstab >/dev/null
  mountpoint -q "$BITCOIN_MOUNT" || sudo mount "$BITCOIN_MOUNT"
}
generate() {
  mount_disk
  [[ -d "$PACKAGE_PROJECT_DIR" ]] || fail "versioned StartOS package source is missing"
  [[ "$(sha256sum "$KNOTS_RELEASE_DIR/bin/bitcoind" | awk '{print $1}')" == "$KNOTS_BITCOIND_SHA256" ]] ||
    fail "pinned Knots binary digest mismatch"
  sudo install -d -m 0755 "$PACKAGE_PROJECT_DIR/bvml"
  sudo tee "$PACKAGE_PROJECT_DIR/bvml/runtime.env" >/dev/null <<EOF
BVML_DATADIR=$CONTAINER_DATADIR
BVML_HOST_DATADIR=$BITCOIN_MOUNT
BVML_KNOTS_RELEASE=$KNOTS_RELEASE_DIR
BVML_KNOTS_SHA256=$KNOTS_BITCOIND_SHA256
BVML_BITCOIND_ARGS=-chain=main -blocksxor=0 -datadir=$CONTAINER_DATADIR
EOF
  [[ -x "$PACKAGE_PROJECT_DIR/bvml/apply-package-override" ]] ||
    fail "profiled package source lacks bvml/apply-package-override; host bind mounts are not accepted"
  "$PACKAGE_PROJECT_DIR/bvml/apply-package-override" "$PACKAGE_PROJECT_DIR/bvml/runtime.env"
}
setup() {
  generate
  (cd "$PACKAGE_PROJECT_DIR" && bash -Eeuo pipefail -c "$PACKAGE_BUILD_COMMAND")
  bash -Eeuo pipefail -c "$PACKAGE_INSTALL_COMMAND"
  verify
}
verify() {
  mount_disk
  local mounts args digest
  mounts="$(podman inspect "$PACKAGE_CONTAINER_NAME" --format '{{json .Mounts}}')"
  jq -e --arg s "$BITCOIN_MOUNT" --arg d "$CONTAINER_DATADIR" \
    'any(.[]; .Source == $s and .Destination == $d and .RW == true)' <<<"$mounts" >/dev/null ||
    fail "actual StartOS package container does not use overlay datadir"
  jq -e --arg s "$KNOTS_RELEASE_DIR" \
    'any(.[]; .Source == $s and .RW == false)' <<<"$mounts" >/dev/null ||
    fail "Knots release is not mounted read-only in the package"
  args="$(podman exec "$PACKAGE_CONTAINER_NAME" tr '\\0' ' ' </proc/1/cmdline)"
  grep -q -- "-datadir=$CONTAINER_DATADIR" <<<"$args" || fail "managed service uses another datadir"
  grep -q -- '-blocksxor=0' <<<"$args" || fail "managed service lacks blocksxor=0"
  digest="$(podman exec "$PACKAGE_CONTAINER_NAME" sha256sum /opt/bvml-knots/bin/bitcoind | awk '{print $1}')"
  [[ "$digest" == "$KNOTS_BITCOIND_SHA256" ]] || fail "in-package Knots digest mismatch"
}
stop() {
  load
  podman exec "$PACKAGE_CONTAINER_NAME" /opt/bvml-knots/bin/bitcoin-cli "-datadir=$CONTAINER_DATADIR" stop
  local n=0
  while podman exec "$PACKAGE_CONTAINER_NAME" pgrep -x bitcoind >/dev/null 2>&1; do
    ((n++ < 120)) || fail "StartOS Knots did not stop"; sleep 1
  done
  sync
}
case "${1:-status}" in
  generate) generate ;;
  setup) setup ;;
  verify|status) verify ;;
  stop) stop ;;
  *) fail "usage: $0 {generate|setup|verify|stop|status}" ;;
esac
