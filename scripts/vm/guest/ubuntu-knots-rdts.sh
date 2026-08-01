#!/usr/bin/env bash
# Ubuntu guest bootstrap/updater. It deliberately refuses unprofiled releases.
set -Eeuo pipefail
CONF=/etc/bvml/knots.env
[[ -r "$CONF" ]] && source "$CONF"
MOUNT="${BITCOIN_MOUNT:-/srv/bitcoin}"
DEVICE="${BITCOIN_DEVICE:-/dev/vdc}"
KNOTS_CONFIG=/etc/bvml/bitcoin.conf
UUID_FILE=/etc/bvml/bitcoin-filesystem.uuid
EVIDENCE="$MOUNT/.bvml/ubuntu-verification.env"
fail() { echo "error: $*" >&2; exit 1; }

load_profiles() {
  for v in KNOTS_RELEASE_PROFILE KNOTS_RDTS_PROFILE KNOTS_RDTS_PROFILE_SHA256; do
    [[ -n "${!v:-}" ]] || fail "$v must be configured"
  done
  [[ -r "$KNOTS_RELEASE_PROFILE" && -r "$KNOTS_RDTS_PROFILE" ]] || fail "Knots release/RDTS profile missing"
  [[ "$(sha256sum "$KNOTS_RDTS_PROFILE" | awk '{print $1}')" == "$KNOTS_RDTS_PROFILE_SHA256" ]] ||
    fail "RDTS profile digest does not match the operator-approved profile"
  source "$KNOTS_RELEASE_PROFILE"
  source "$KNOTS_RDTS_PROFILE"
  for v in KNOTS_VERSION KNOTS_ARCHIVE_NAME KNOTS_RELEASE_BASE_URL KNOTS_ARTIFACT_SHA256 \
    KNOTS_SHA256SUMS KNOTS_SHA256SUMS_ASC KNOTS_SIGNING_KEY KNOTS_SIGNER_FINGERPRINT \
    RDTS_PROFILE_NAME RDTS_PROFILE_KNOTS_VERSION RDTS_REQUIRED_ARGS; do
    [[ -n "${!v:-}" ]] || fail "profile must declare $v"
  done
  [[ "$RDTS_PROFILE_KNOTS_VERSION" == "$KNOTS_VERSION" ]] ||
    fail "RDTS profile is not for selected Knots release"
}

expected_mount() {
  [[ -b "$DEVICE" ]] || fail "attached Bitcoin disk not found at $DEVICE"
  [[ -s "$UUID_FILE" ]] || fail "expected Bitcoin filesystem UUID has not been initialized"
  local expected actual source
  expected="$(<"$UUID_FILE")"; actual="$(blkid -s UUID -o value "$DEVICE")"
  [[ -n "$actual" && "$actual" == "$expected" ]] || fail "Bitcoin disk UUID does not match expected identity"
  mountpoint -q "$MOUNT" || fail "$MOUNT is not a mount point"
  source="$(findmnt -n -o SOURCE "$MOUNT")"
  [[ "$(readlink -f "$source")" == "$(readlink -f "$DEVICE")" ||
     "$(blkid -s UUID -o value "$source" 2>/dev/null)" == "$expected" ]] ||
    fail "$MOUNT is not backed by the expected disposable Bitcoin disk"
}

init_filesystem() {
  [[ "${1:-}" == "--confirm-device-vdc" && "$DEVICE" == /dev/vdc ]] ||
    fail "refusing to format without --confirm-device-vdc and BITCOIN_DEVICE=/dev/vdc"
  [[ -b "$DEVICE" ]] || fail "$DEVICE is not a block device"
  [[ -z "$(lsblk -no FSTYPE "$DEVICE")" ]] || fail "$DEVICE already contains a filesystem"
  [[ "$(lsblk -ndo TYPE "$DEVICE")" == disk ]] || fail "$DEVICE is not an unpartitioned disk"
  sudo mkfs.ext4 -L BVML_BITCOIN "$DEVICE"
  local uuid; uuid="$(blkid -s UUID -o value "$DEVICE")"; [[ -n "$uuid" ]] || fail "filesystem UUID unavailable"
  sudo install -d -m 0755 /etc/bvml
  printf '%s\n' "$uuid" | sudo tee "$UUID_FILE" >/dev/null
  sudo install -d -m 0750 "$MOUNT"
  grep -q "^UUID=$uuid " /etc/fstab ||
    echo "UUID=$uuid $MOUNT ext4 defaults,x-systemd.device-timeout=30 0 2" | sudo tee -a /etc/fstab >/dev/null
  sudo mount "$MOUNT"
  sudo chown "$USER:$USER" "$MOUNT"
  echo "initialized UUID=$uuid; no Bitcoin process was started"
}

install_knots() {
  load_profiles
  local work status binary cli actual digest
  work="$(mktemp -d)"; trap 'rm -rf -- "$work"' RETURN
  gpg --batch --no-default-keyring --keyring "$work/release.gpg" --import "$KNOTS_SIGNING_KEY" >/dev/null
  status="$(gpgv --status-fd 1 --keyring "$work/release.gpg" "$KNOTS_SHA256SUMS_ASC" "$KNOTS_SHA256SUMS" 2>/dev/null)"
  grep -q "VALIDSIG $KNOTS_SIGNER_FINGERPRINT " <<<"$status" || fail "authenticated metadata signer mismatch"
  curl -fL "$KNOTS_RELEASE_BASE_URL/$KNOTS_ARCHIVE_NAME" -o "$work/$KNOTS_ARCHIVE_NAME"
  digest="$(sha256sum "$work/$KNOTS_ARCHIVE_NAME" | awk '{print $1}')"
  [[ "$digest" == "$KNOTS_ARTIFACT_SHA256" ]] || fail "artifact does not match pinned digest"
  grep -E "^[0-9a-fA-F]{64}[[:space:]]+\\*?$KNOTS_ARCHIVE_NAME$" "$KNOTS_SHA256SUMS" |
    (cd "$work" && sha256sum -c -) || fail "artifact absent from authenticated checksums"
  tar -xf "$work/$KNOTS_ARCHIVE_NAME" -C "$work"
  binary="$(find "$work" -type f -path '*/bin/bitcoind' -print -quit)"
  cli="$(find "$work" -type f -path '*/bin/bitcoin-cli' -print -quit)"
  [[ -x "$binary" && -x "$cli" ]] || fail "archive lacks executable Knots binaries"
  sudo install -m 0755 "$binary" "$cli" /usr/local/bin/
  actual="$(/usr/local/bin/bitcoind --version | head -1)"
  grep -qi knots <<<"$actual" || fail "installed binary is not Bitcoin Knots"
  [[ "$actual" == *"$KNOTS_VERSION"* ]] || fail "actual Knots version '$actual' does not match $KNOTS_VERSION"
  printf '%s\n' "$digest" | sudo tee /etc/bvml/knots-artifact.sha256 >/dev/null
  printf '%s\n' "$actual" | sudo tee /etc/bvml/knots-actual-version >/dev/null
}

validate_rdts() {
  load_profiles
  [[ -x /usr/local/bin/bitcoind ]] || fail "Knots is not installed"
  local help arg option value found
  help="$(/usr/local/bin/bitcoind -help-debug 2>&1)"
  read -r -a required <<<"$RDTS_REQUIRED_ARGS"
  ((${#required[@]} > 0)) || fail "RDTS profile contains no required options"
  for arg in "${required[@]}"; do
    [[ "$arg" == -*=* ]] || fail "RDTS profile option must include an explicit value: $arg"
    option="${arg%%=*}"; value="${arg#*=}"
    [[ -n "$value" ]] || fail "RDTS profile has an empty value: $arg"
    grep -Eq -- "${option}(=|[[:space:]])" <<<"$help" || fail "installed Knots does not support $option"
    found=0
    for configured in "${required[@]}"; do [[ "$configured" == "$arg" ]] && found=1; done
    ((found)) || fail "required RDTS option not effective: $arg"
  done
}

install_service() {
  expected_mount; install_knots; validate_rdts
  sudo install -d -m 0755 /etc/bvml
  sudo tee "$KNOTS_CONFIG" >/dev/null <<EOF
chain=main
datadir=$MOUNT
blocksxor=0
EOF
  sudo tee /etc/systemd/system/bvml-knots.service >/dev/null <<EOF
[Unit]
Description=Bitcoin Knots with authenticated release-specific RDTS
RequiresMountsFor=$MOUNT
ConditionPathIsMountPoint=$MOUNT
After=network-online.target
[Service]
User=$USER
ExecStartPre=$0 check-mount
ExecStartPre=$0 invalidate-evidence
ExecStart=/usr/local/bin/bitcoind -conf=$KNOTS_CONFIG $RDTS_REQUIRED_ARGS
ExecStop=/usr/local/bin/bitcoin-cli -conf=$KNOTS_CONFIG stop
TimeoutStopSec=900
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable bvml-knots.service
}

invalidate_evidence() { expected_mount; rm -f -- "$EVIDENCE"; }
start_knots() { expected_mount; validate_rdts; invalidate_evidence; sudo systemctl start bvml-knots.service; }
stop_knots() {
  sudo systemctl stop bvml-knots.service
  systemctl is-active --quiet bvml-knots.service && fail "Knots service did not stop"
  pgrep -x bitcoind >/dev/null && fail "bitcoind remains active"
  sync
}

verify_shutdown() {
  expected_mount; validate_rdts
  systemctl is-active --quiet bvml-knots.service || fail "Knots must be running to collect current node state"
  local info indexes height headers ibd best tip actual digest uuid index_sync
  info="$(/usr/local/bin/bitcoin-cli -conf="$KNOTS_CONFIG" getblockchaininfo)"
  [[ "$(jq -r .chain <<<"$info")" == main ]] || fail "Knots is not on mainnet"
  ibd="$(jq -r .initialblockdownload <<<"$info")"; [[ "$ibd" == false ]] || fail "IBD is incomplete"
  height="$(jq -r .blocks <<<"$info")"; headers="$(jq -r .headers <<<"$info")"
  [[ "$height" == "$headers" ]] || fail "headers remain ahead of blocks"
  best="$(jq -r .bestblockhash <<<"$info")"; tip="$(jq -r .mediantime <<<"$info")"
  indexes="$(/usr/local/bin/bitcoin-cli -conf="$KNOTS_CONFIG" getindexinfo 2>/dev/null || echo '{}')"
  index_sync="$(jq -c 'with_entries(.value = (.value.synced == true))' <<<"$indexes")"
  [[ "$index_sync" != *false* ]] || fail "one or more enabled indexes are unsynchronized"
  actual="$(</etc/bvml/knots-actual-version)"; digest="$(</etc/bvml/knots-artifact.sha256)"
  uuid="$(</etc/bvml/bitcoin-filesystem.uuid)"
  stop_knots
  sudo install -d -m 0750 "$MOUNT/.bvml"
  sudo tee "$EVIDENCE" >/dev/null <<EOF
vm=ubuntu
network=main
blocksxor=0
synced=1
clean_shutdown=1
datadir_layout=root-datadir
rdts_validated=1
rdts_profile=$KNOTS_RDTS_PROFILE
rdts_effective_args=$RDTS_REQUIRED_ARGS
knots_actual_version=$actual
artifact_sha256=$digest
block_height=$height
header_height=$headers
best_block_hash=$best
tip_time=$tip
filesystem_uuid=$uuid
indexes_json=$(jq -c 'keys' <<<"$indexes")
index_sync_json=$index_sync
shutdown_id=$(date +%s%N)-$$
verified=$(date -u +%FT%TZ)
EOF
  sync
}

case "${1:-status}" in
  init-filesystem) shift; init_filesystem "$@" ;;
  install) install_service ;;
  check-mount) expected_mount ;;
  invalidate-evidence) invalidate_evidence ;;
  start) start_knots ;;
  stop) stop_knots ;;
  verify-shutdown) verify_shutdown ;;
  status) expected_mount; systemctl status bvml-knots.service --no-pager ;;
  *) fail "usage: $0 {init-filesystem --confirm-device-vdc|install|check-mount|start|stop|verify-shutdown|status}" ;;
esac
