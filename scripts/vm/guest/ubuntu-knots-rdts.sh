#!/usr/bin/env bash
# Run in Ubuntu. Configuration is read from /etc/bvml/knots.env.
set -Eeuo pipefail
CONF=/etc/bvml/knots.env
[[ -r "$CONF" ]] && source "$CONF"
MOUNT="${BITCOIN_MOUNT:-/srv/bitcoin}"
DEVICE="${BITCOIN_DEVICE:-/dev/vdc}"
KNOTS_CONFIG="$MOUNT/bitcoin.conf"

fail() { echo "error: $*" >&2; exit 1; }
require_release_config() {
  [[ -n "${KNOTS_VERSION:-}" ]] || fail "KNOTS_VERSION is required"
  [[ -n "${KNOTS_RDTS_ARGS:-}" ]] || fail "KNOTS_RDTS_ARGS must be explicit for this Knots release"
}
validate_rdts_args() {
  local help arg option
  help="$(/usr/local/bin/bitcoind -help-debug 2>&1)"
  read -r -a args <<<"$KNOTS_RDTS_ARGS"
  for arg in "${args[@]}"; do
    option="${arg%%=*}"; option="${option#-}"
    grep -Eq -- "-${option}(=|[[:space:]])" <<<"$help" ||
      fail "RDTS option '$option' is unsupported by Knots $KNOTS_VERSION"
  done
}
mount_datadir() {
  [[ -b "$DEVICE" ]] || fail "attached overlay not found at $DEVICE"
  if ! blkid "$DEVICE" >/dev/null 2>&1; then fail "overlay has no filesystem; initial checkpoint import is required"; fi
  uuid="$(blkid -s UUID -o value "$DEVICE")"
  sudo install -d -m 0750 "$MOUNT"
  grep -q "UUID=$uuid " /etc/fstab ||
    echo "UUID=$uuid $MOUNT ext4 defaults,nofail,x-systemd.device-timeout=30 0 2" | sudo tee -a /etc/fstab >/dev/null
  sudo mountpoint -q "$MOUNT" || sudo mount "$MOUNT"
  touch "$MOUNT/.bvml-write-test" 2>/dev/null ||
    fail "$USER cannot write the imported datadir; correct guest ownership before starting Knots"
  rm -f -- "$MOUNT/.bvml-write-test"
}
install_knots() {
  require_release_config
  if [[ -n "${KNOTS_BINARY:-}" ]]; then
    [[ -x "$KNOTS_BINARY" ]] || fail "configured KNOTS_BINARY is not executable"
    sudo install -m 0755 "$KNOTS_BINARY" /usr/local/bin/bitcoind
    sibling="$(dirname "$KNOTS_BINARY")/bitcoin-cli"
    [[ -x "$sibling" ]] && sudo install -m 0755 "$sibling" /usr/local/bin/bitcoin-cli ||
      fail "bitcoin-cli must accompany KNOTS_BINARY"
  else
    for v in KNOTS_ARCHIVE_NAME KNOTS_RELEASE_BASE_URL KNOTS_SHA256SUMS KNOTS_SHA256SUMS_ASC KNOTS_SIGNING_KEY KNOTS_SIGNER_FINGERPRINT; do
      [[ -n "${!v:-}" ]] || fail "$v is required for authenticated download"
    done
    work="$(mktemp -d)"; trap 'rm -rf -- "$work"' EXIT
    gpg --batch --no-default-keyring --keyring "$work/release.gpg" --import "$KNOTS_SIGNING_KEY" >/dev/null
    status="$(gpgv --status-fd 1 --keyring "$work/release.gpg" "$KNOTS_SHA256SUMS_ASC" "$KNOTS_SHA256SUMS" 2>/dev/null)"
    grep -q "VALIDSIG $KNOTS_SIGNER_FINGERPRINT " <<<"$status" || fail "release metadata signer fingerprint mismatch"
    curl -fL "$KNOTS_RELEASE_BASE_URL/$KNOTS_ARCHIVE_NAME" -o "$work/$KNOTS_ARCHIVE_NAME"
    grep " $KNOTS_ARCHIVE_NAME$" "$KNOTS_SHA256SUMS" | (cd "$work" && sha256sum -c -)
    tar -xf "$work/$KNOTS_ARCHIVE_NAME" -C "$work"
    binary="$(find "$work" -type f -path '*/bin/bitcoind' -print -quit)"
    cli="$(find "$work" -type f -path '*/bin/bitcoin-cli' -print -quit)"
    [[ -n "$binary" && -n "$cli" ]] || fail "archive lacks Knots binaries"
    sudo install -m 0755 "$binary" "$cli" /usr/local/bin/
  fi
  /usr/local/bin/bitcoind --version | grep -qi knots || fail "installed binary does not identify as Bitcoin Knots"
  validate_rdts_args
}
install_service() {
  mount_datadir; install_knots
  sudo install -d -m 0755 /etc/bvml
  sudo touch "$KNOTS_CONFIG"; sudo chown "$USER:$USER" "$KNOTS_CONFIG"
  printf 'datadir=%s\nblocksxor=0\n' "$MOUNT" >"$KNOTS_CONFIG"
  sudo tee /etc/systemd/system/bvml-knots.service >/dev/null <<EOF
[Unit]
Description=Bitcoin Knots with release-specific RDTS
After=srv-bitcoin.mount network-online.target
[Service]
User=$USER
ExecStart=/usr/local/bin/bitcoind -conf=$KNOTS_CONFIG $KNOTS_RDTS_ARGS
ExecStop=/usr/local/bin/bitcoin-cli -conf=$KNOTS_CONFIG stop
TimeoutStopSec=600
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable bvml-knots.service
}
verify_shutdown() {
  require_release_config; validate_rdts_args
  info="$(bitcoin-cli -conf="$KNOTS_CONFIG" getblockchaininfo)"
  [[ "$(jq -r .chain <<<"$info")" == main ]] || fail "Knots is not on mainnet"
  [[ "$(jq -r .initialblockdownload <<<"$info")" == false ]] || fail "initial block download is incomplete"
  awk -v p="$(jq -r .verificationprogress <<<"$info")" 'BEGIN {exit !(p >= 0.99999)}' || fail "verification progress is incomplete"
  indexes="$(bitcoin-cli -conf="$KNOTS_CONFIG" getindexinfo 2>/dev/null | jq -c 'keys' || echo '[]')"
  sudo systemctl stop bvml-knots.service
  systemctl is-active --quiet bvml-knots.service && fail "Knots service did not stop"
  pgrep -x bitcoind >/dev/null && fail "bitcoind is still running"
  sudo install -d -m 0750 "$MOUNT/.bvml"
  sudo tee "$MOUNT/.bvml/ubuntu-verification.env" >/dev/null <<EOF
vm=ubuntu
network=main
blocksxor=0
synced=1
clean_shutdown=1
datadir_layout=root-datadir
rdts_validated=1
knots_version=$KNOTS_VERSION
indexes_json=$indexes
verified=$(date -u +%FT%TZ)
EOF
  sync
  echo "Knots stopped cleanly. Shut Ubuntu down, then run host checkpoint-verify."
}
case "${1:-status}" in
  install) install_service ;;
  start) mount_datadir; sudo systemctl start bvml-knots.service ;;
  verify-shutdown) verify_shutdown ;;
  status)
    echo "Ubuntu Knots version=${KNOTS_VERSION:-UNSET} RDTS=${KNOTS_RDTS_ARGS:-UNSET}"
    [[ -x /usr/local/bin/bitcoind ]] && /usr/local/bin/bitcoind --version | head -1 || true
    findmnt "$MOUNT" 2>/dev/null || true
    systemctl status bvml-knots.service --no-pager 2>/dev/null || true
    ;;
  *) fail "usage: $0 {install|start|verify-shutdown|status}" ;;
esac
