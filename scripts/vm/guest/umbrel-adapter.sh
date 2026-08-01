#!/usr/bin/env bash
# Exact-profile Umbrel app override. No guessed host datadir bind mounts.
set -Eeuo pipefail
fail() { echo "error: $*" >&2; exit 1; }
PROFILE=/etc/bvml/umbrel-profile.env
load() {
  [[ -r "$PROFILE" ]] || fail "missing exact Umbrel package profile: $PROFILE"
  source "$PROFILE"
  for v in SUPPORTED_OS_VERSION DETECTED_OS_VERSION SUPPORTED_APP_VERSION DETECTED_APP_VERSION \
    APP_ID COMPOSE_PROJECT COMPOSE_FILE BITCOIN_SERVICE CONTAINER_DATADIR \
    KNOTS_RELEASE_DIR KNOTS_BITCOIND_SHA256 BITCOIN_DEVICE BITCOIN_MOUNT; do
    [[ -n "${!v:-}" ]] || fail "$PROFILE must declare $v"
  done
  [[ "$SUPPORTED_OS_VERSION" == "$DETECTED_OS_VERSION" ]] || fail "unsupported UmbrelOS version"
  [[ "$SUPPORTED_APP_VERSION" == "$DETECTED_APP_VERSION" ]] || fail "unsupported Umbrel Bitcoin package version"
}
mount_disk() {
  load; [[ -b "$BITCOIN_DEVICE" ]] || fail "overlay disk absent"
  local uuid; uuid="$(blkid -s UUID -o value "$BITCOIN_DEVICE")"; [[ -n "$uuid" ]] || fail "overlay has no filesystem"
  sudo install -d -m 0750 "$BITCOIN_MOUNT"
  grep -q "^UUID=$uuid " /etc/fstab ||
    echo "UUID=$uuid $BITCOIN_MOUNT ext4 defaults,x-systemd.device-timeout=30 0 2" | sudo tee -a /etc/fstab >/dev/null
  mountpoint -q "$BITCOIN_MOUNT" || sudo mount "$BITCOIN_MOUNT"
}
install_override() {
  mount_disk
  [[ -f "$COMPOSE_FILE" ]] || fail "actual Umbrel application compose file is missing"
  [[ -x "$KNOTS_RELEASE_DIR/bin/bitcoind" ]] || fail "pinned Knots release is missing"
  [[ "$(sha256sum "$KNOTS_RELEASE_DIR/bin/bitcoind" | awk '{print $1}')" == "$KNOTS_BITCOIND_SHA256" ]] ||
    fail "pinned Knots binary digest mismatch"
  local override="/etc/bvml/umbrel-${APP_ID}-override.yml"
  sudo tee "$override" >/dev/null <<EOF
services:
  $BITCOIN_SERVICE:
    volumes:
      - $BITCOIN_MOUNT:$CONTAINER_DATADIR
      - $KNOTS_RELEASE_DIR:/opt/bvml-knots:ro
    command:
      - /opt/bvml-knots/bin/bitcoind
      - -datadir=$CONTAINER_DATADIR
      - -chain=main
      - -blocksxor=0
EOF
  printf '%s\n' "$override" | sudo tee /etc/bvml/umbrel-active-override >/dev/null
  echo "override generated; use 'setup' to recreate the actual package container"
}
setup() {
  install_override
  local override; override="$(</etc/bvml/umbrel-active-override)"
  docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" -f "$override" down
  docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" -f "$override" up -d
  verify
}
verify() {
  mount_disk
  local cid mounts command digest
  cid="$(docker compose -p "$COMPOSE_PROJECT" ps -q "$BITCOIN_SERVICE")"; [[ -n "$cid" ]] || fail "Umbrel Bitcoin container is absent"
  mounts="$(docker inspect "$cid" --format '{{json .Mounts}}')"
  jq -e --arg s "$BITCOIN_MOUNT" --arg d "$CONTAINER_DATADIR" \
    'any(.[]; .Source == $s and .Destination == $d and .RW == true)' <<<"$mounts" >/dev/null ||
    fail "actual container does not use the overlay as its complete datadir"
  jq -e --arg s "$KNOTS_RELEASE_DIR" \
    'any(.[]; .Source == $s and .Destination == "/opt/bvml-knots" and .RW == false)' <<<"$mounts" >/dev/null ||
    fail "Knots release is not mounted read-only"
  command="$(docker inspect "$cid" --format '{{json .Config.Cmd}}')"
  grep -q -- "-datadir=$CONTAINER_DATADIR" <<<"$command" || fail "container command uses another datadir"
  grep -q -- '-blocksxor=0' <<<"$command" || fail "container command lacks blocksxor=0"
  digest="$(docker exec "$cid" sha256sum /opt/bvml-knots/bin/bitcoind | awk '{print $1}')"
  [[ "$digest" == "$KNOTS_BITCOIND_SHA256" ]] || fail "in-container executable digest mismatch"
}
stop() {
  load
  local cid; cid="$(docker compose -p "$COMPOSE_PROJECT" ps -q "$BITCOIN_SERVICE")"
  [[ -z "$cid" ]] || docker exec "$cid" /opt/bvml-knots/bin/bitcoin-cli "-datadir=$CONTAINER_DATADIR" stop
  local n=0
  while [[ -n "$cid" ]] && docker exec "$cid" pgrep -x bitcoind >/dev/null 2>&1; do
    ((n++ < 120)) || fail "Umbrel Knots did not stop"; sleep 1
  done
  sync
}
case "${1:-status}" in
  generate) install_override ;;
  setup) setup ;;
  verify|status) verify ;;
  stop) stop ;;
  *) fail "usage: $0 {generate|setup|verify|stop|status}" ;;
esac
