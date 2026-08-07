#!/usr/bin/env bash
# Ubuntu guest bootstrap/updater. Profiles are privileged operator configuration.
set -Eeuo pipefail
CONF=/etc/bvml/knots.env
MOUNT=/srv/bitcoin
DEVICE=/dev/vdc
KNOTS_CONFIG=/etc/bvml/bitcoin.conf
UUID_FILE=/etc/bvml/bitcoin-filesystem.uuid
BOOTSTRAP_STAGE=/run/bvml/bootstrap-init.env
EVIDENCE="$MOUNT/.bvml/ubuntu-verification.env"
fail() { echo "error: $*" >&2; exit 1; }

safe_scalar() {
  local name="$1" value="${!1:-}"
  [[ -n "$value" && ! "$value" =~ [[:cntrl:]] ]] ||
    fail "$name is empty or contains control characters"
}

safe_path_value() {
  local name="$1" value="${!1:-}"
  [[ "$value" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
    fail "$name must be an absolute path with only safe path characters"
}

safe_privileged_file() {
  local file="$1" expected_digest="${2:-}" mode owner
  [[ "$file" == /* && -f "$file" ]] || fail "profile path must be an absolute regular file: $file"
  owner="$(stat -c %u "$file")"; mode="$(stat -c %a "$file")"
  [[ "$owner" == 0 ]] || fail "privileged profile is not root-owned: $file"
  (( (8#$mode & 022) == 0 )) || fail "privileged profile is group/world writable: $file"
  if [[ -n "$expected_digest" ]]; then
    [[ "$expected_digest" =~ ^[0-9a-fA-F]{64}$ ]] || fail "invalid configured profile digest"
    [[ "$(sha256sum "$file" | awk '{print $1}')" == "${expected_digest,,}" ]] ||
      fail "profile digest mismatch: $file"
  fi
}

load_conf() {
  [[ "${CONF_LOADED:-0}" == 1 ]] && return
  [[ -r "$CONF" ]] || fail "missing operator configuration: $CONF"
  safe_privileged_file "$CONF"
  # shellcheck source=/dev/null
  source "$CONF"
  MOUNT="${BITCOIN_MOUNT:-$MOUNT}"
  DEVICE="${BITCOIN_DEVICE:-$DEVICE}"
  EVIDENCE="$MOUNT/.bvml/ubuntu-verification.env"
  for v in BITCOIN_SERVICE_USER BITCOIN_SERVICE_GROUP MAX_TIP_AGE_SECONDS; do safe_scalar "$v"; done
  for v in MOUNT DEVICE; do safe_path_value "$v"; done
  id "$BITCOIN_SERVICE_USER" >/dev/null 2>&1 || fail "configured Bitcoin service user does not exist"
  getent group "$BITCOIN_SERVICE_GROUP" >/dev/null || fail "configured Bitcoin service group does not exist"
  CONF_LOADED=1
}

normalize_version() {
  sed -En '1{s/^Bitcoin Knots (daemon )?version[[:space:]]+v?//;s/[[:space:]]//g;p;}'
}

load_profiles() {
  load_conf
  for v in KNOTS_RELEASE_PROFILE KNOTS_RELEASE_PROFILE_SHA256 KNOTS_RDTS_PROFILE \
    KNOTS_RDTS_PROFILE_SHA256 CHECKPOINT_PROFILE_FILE CHECKPOINT_PROFILE_SHA256; do
    safe_scalar "$v"
  done
  safe_privileged_file "$KNOTS_RELEASE_PROFILE" "$KNOTS_RELEASE_PROFILE_SHA256"
  safe_privileged_file "$KNOTS_RDTS_PROFILE" "$KNOTS_RDTS_PROFILE_SHA256"
  safe_privileged_file "$CHECKPOINT_PROFILE_FILE" "$CHECKPOINT_PROFILE_SHA256"
  # shellcheck source=/dev/null
  source "$KNOTS_RELEASE_PROFILE"
  # shellcheck source=/dev/null
  source "$KNOTS_RDTS_PROFILE"
  for v in KNOTS_VERSION_NORMALIZED KNOTS_ARCHIVE_NAME KNOTS_RELEASE_BASE_URL \
    KNOTS_ARTIFACT_SHA256 KNOTS_SHA256SUMS KNOTS_SHA256SUMS_ASC \
    KNOTS_SIGNING_KEY KNOTS_SIGNER_FINGERPRINT RDTS_PROFILE_NAME \
    RDTS_PROFILE_KNOTS_VERSION_NORMALIZED RDTS_REQUIRED_ARGS_JSON; do
    safe_scalar "$v"
  done
  [[ "$KNOTS_ARCHIVE_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || fail "unsafe Knots archive name"
  [[ "$KNOTS_SIGNER_FINGERPRINT" =~ ^[0-9A-Fa-f]{40,64}$ ]] || fail "invalid signer fingerprint"
  safe_privileged_file "$KNOTS_SIGNING_KEY"
  safe_privileged_file "$KNOTS_SHA256SUMS"
  safe_privileged_file "$KNOTS_SHA256SUMS_ASC"
  [[ "$RDTS_PROFILE_KNOTS_VERSION_NORMALIZED" == "$KNOTS_VERSION_NORMALIZED" ]] ||
    fail "RDTS profile is not for the selected normalized Knots release"
  jq -e 'type == "array" and length > 0 and all(.[]; type == "string")' \
    <<<"$RDTS_REQUIRED_ARGS_JSON" >/dev/null || fail "RDTS required arguments must be a nonempty JSON string array"
  jq -e '.id | type == "string" and length > 0' "$CHECKPOINT_PROFILE_FILE" >/dev/null ||
    fail "checkpoint profile ID is invalid"
  jq -e '.indexes | type == "array" and all(.[]; type == "string")' \
    "$CHECKPOINT_PROFILE_FILE" >/dev/null || fail "checkpoint index profile is invalid"
}

expected_mount() {
  load_conf
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

stage_bootstrap() {
  load_conf
  (($# == 4)) || fail "stage-bootstrap requires ID, serial, size, and nonce"
  local id="$1" serial="$2" size="$3" nonce="$4"
  [[ "$id" =~ ^[A-Za-z0-9-]{16,128}$ && "$serial" =~ ^BVMLB-[A-Za-z0-9-]{8,16}$ &&
     "$size" =~ ^[1-9][0-9]*$ && "$nonce" =~ ^[A-Za-z0-9-]{16,128}$ ]] ||
    fail "bootstrap initialization metadata is malformed"
  sudo install -d -o root -g root -m 0700 "$(dirname "$BOOTSTRAP_STAGE")"
  printf 'bootstrap_id=%s\ndisk_serial=%s\nsize_bytes=%s\nbootstrap_nonce=%s\n' \
    "$id" "$serial" "$size" "$nonce" |
    sudo tee "$BOOTSTRAP_STAGE" >/dev/null
  sudo chown root:root "$BOOTSTRAP_STAGE"
  sudo chmod 0600 "$BOOTSTRAP_STAGE"
}

stage_get() { sudo sed -n "s/^$1=//p" "$BOOTSTRAP_STAGE" | head -1; }

init_filesystem() {
  load_conf
  [[ "${1:-}" == "--confirm-bootstrap-format" && $# == 5 ]] ||
    fail "formatting requires explicit confirmation plus ID, serial, size, and nonce"
  shift
  local id="$1" serial="$2" size="$3" nonce="$4" actual_serial actual_size by_id signatures children mounts
  [[ -f "$BOOTSTRAP_STAGE" ]] || fail "host bootstrap identity metadata was not staged"
  [[ "$(stage_get bootstrap_id)" == "$id" && "$(stage_get disk_serial)" == "$serial" &&
     "$(stage_get size_bytes)" == "$size" && "$(stage_get bootstrap_nonce)" == "$nonce" ]] ||
    fail "host nonce or bootstrap identity does not match guest-visible initialization metadata"
  [[ -b "$DEVICE" ]] || fail "$DEVICE is not a block device"
  actual_serial="$(lsblk -dn -o SERIAL "$DEVICE" | sed 's/[[:space:]]*$//')"
  [[ -n "$actual_serial" && "$actual_serial" == "$serial" ]] || fail "bootstrap disk serial mismatch"
  by_id="/dev/disk/by-id/virtio-$serial"
  [[ -b "$by_id" && "$(readlink -f "$by_id")" == "$(readlink -f "$DEVICE")" ]] ||
    fail "expected unambiguous by-id bootstrap device is unavailable"
  actual_size="$(blockdev --getsize64 "$DEVICE")"
  [[ "$actual_size" == "$size" ]] || fail "bootstrap virtual size mismatch"
  children="$(lsblk -nrpo NAME "$DEVICE" | tail -n +2)"
  [[ -z "$children" ]] || fail "bootstrap disk has child partitions or mappings"
  mounts="$(lsblk -nrpo MOUNTPOINTS "$DEVICE" | sed '/^[[:space:]]*$/d')"
  [[ -z "$mounts" ]] || fail "bootstrap disk or child is mounted"
  signatures="$(sudo wipefs -n "$DEVICE" 2>&1)" || fail "wipefs could not inspect the bootstrap disk"
  [[ -z "$signatures" ]] || fail "bootstrap disk has a filesystem, partition, RAID, LVM, or other signature"
  local probe_status
  set +e
  signatures="$(sudo blkid -p "$DEVICE" 2>&1)"; probe_status=$?
  set -e
  if ((probe_status == 0)); then fail "blkid recognizes existing content on bootstrap disk"; fi
  ((probe_status == 2)) && [[ -z "$signatures" ]] ||
    fail "blkid could not unambiguously prove the bootstrap disk is empty"
  sudo mkfs.ext4 -L BVML_BITCOIN "$by_id"
  local uuid; uuid="$(blkid -s UUID -o value "$by_id")"; [[ -n "$uuid" ]] || fail "filesystem UUID unavailable"
  sudo install -d -m 0755 /etc/bvml
  printf '%s\n' "$uuid" | sudo tee "$UUID_FILE" >/dev/null
  sudo install -d -m 0750 "$MOUNT"
  grep -q "^UUID=$uuid " /etc/fstab ||
    echo "UUID=$uuid $MOUNT ext4 defaults,x-systemd.device-timeout=30 0 2" | sudo tee -a /etc/fstab >/dev/null
  sudo mount "$MOUNT"
  sudo chown "$BITCOIN_SERVICE_USER:$BITCOIN_SERVICE_GROUP" "$MOUNT"
  sudo rm -f -- "$BOOTSTRAP_STAGE"
  echo "initialized bootstrap_id=$id serial=$serial UUID=$uuid; no Bitcoin process was started"
}

install_knots() {
  load_profiles
  local work status binary cli actual digest normalized
  work="$(mktemp -d)"
  gpg --batch --no-default-keyring --keyring "$work/release.gpg" --import "$KNOTS_SIGNING_KEY" >/dev/null
  # Release signature files are multisigned. gpgv can return nonzero when the
  # deliberately minimal keyring lacks unrelated signers, even though the
  # operator-pinned signer validated. Trust only the exact required VALIDSIG.
  status="$(gpgv --status-fd 1 --keyring "$work/release.gpg" \
    "$KNOTS_SHA256SUMS_ASC" "$KNOTS_SHA256SUMS" 2>/dev/null || true)"
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
  normalized="$(normalize_version <<<"$actual")"
  [[ "$normalized" == "$KNOTS_VERSION_NORMALIZED" ]] ||
    fail "normalized Knots version '$normalized' does not match '$KNOTS_VERSION_NORMALIZED'"
  printf '%s\n' "$digest" | sudo tee /etc/bvml/knots-artifact.sha256 >/dev/null
  printf '%s\n' "$actual" | sudo tee /etc/bvml/knots-actual-version >/dev/null
  printf '%s\n' "$normalized" | sudo tee /etc/bvml/knots-version-normalized >/dev/null
  rm -rf -- "$work"
}

validate_rdts_supported() {
  load_profiles
  [[ -x /usr/local/bin/bitcoind ]] || fail "Knots is not installed"
  local help arg option
  help="$(/usr/local/bin/bitcoind -help-debug 2>&1)"
  while IFS= read -r arg; do
    [[ "$arg" =~ ^-[A-Za-z0-9][A-Za-z0-9-]*=[A-Za-z0-9._:/,+-]+$ ]] ||
      fail "RDTS argument is not a safe explicit option=value: $arg"
    option="${arg%%=*}"
    grep -Eq -- "(^|[[:space:]])${option}(=|[[:space:]])" <<<"$help" ||
      fail "installed Knots does not support $option"
  done < <(jq -r '.[]' <<<"$RDTS_REQUIRED_ARGS_JSON")
  jq -e 'map(split("=")[0]) | length == (unique | length)' <<<"$RDTS_REQUIRED_ARGS_JSON" >/dev/null ||
    fail "RDTS profile duplicates an option"
}

process_args_json() {
  local pid="$1"
  sudo sh -c 'tr "\\0" "\\n" <"/proc/$1/cmdline"' sh "$pid" | jq -Rsc 'split("\n")[:-1]'
}

find_knots_pid() {
  local pids pid exe matches=()
  pids="$(pgrep -x bitcoind || true)"
  for pid in $pids; do
    exe="$(sudo readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    [[ "$exe" == /usr/local/bin/bitcoind ]] && matches+=("$pid")
  done
  ((${#matches[@]} == 1)) || fail "expected exactly one running approved Knots process, found ${#matches[@]}"
  printf '%s\n' "${matches[0]}"
}

validate_rdts_runtime() {
  validate_rdts_supported
  local pid observed required_names option expected count actual
  pid="$(find_knots_pid)"
  observed="$(process_args_json "$pid")"
  required_names="$(jq -c 'map(split("=")[0])' <<<"$RDTS_REQUIRED_ARGS_JSON")"
  while IFS= read -r option; do
    expected="$(jq -r --arg o "$option" '.[] | select(startswith($o + "="))' <<<"$RDTS_REQUIRED_ARGS_JSON")"
    count="$(jq --arg o "$option" '[.[] | select(startswith($o + "=") or . == $o)] | length' <<<"$observed")"
    [[ "$count" == 1 ]] || fail "live Knots process has missing or duplicated RDTS option $option"
    actual="$(jq -r --arg o "$option" '.[] | select(startswith($o + "=") or . == $o)' <<<"$observed")"
    [[ "$actual" == "$expected" ]] || fail "live Knots process uses '$actual', expected '$expected'"
  done < <(jq -r '.[]' <<<"$required_names")
  RDTS_OBSERVED_ARGS_JSON="$(jq -c --argjson names "$required_names" '
    map(select((split("=")[0]) as $name | $names | index($name))) | sort
  ' <<<"$observed")"
}

write_checkpoint_indexes_conf() {
  # Map checkpoint profile index names to bitcoin.conf settings.
  local conf_extra=()
  if jq -e '.indexes | index("basic block filter index") != null' \
       "$CHECKPOINT_PROFILE_FILE" >/dev/null; then
    conf_extra+=('blockfilterindex=basic')
  fi
  if jq -e '.indexes | index("txindex") != null' \
       "$CHECKPOINT_PROFILE_FILE" >/dev/null; then
    conf_extra+=('txindex=1')
  else
    conf_extra+=('txindex=0')
  fi
  printf '%s\n' "${conf_extra[@]}"
}

install_service() {
  expected_mount; install_knots; validate_rdts_supported; load_profiles
  local rdts_args index_conf
  rdts_args="$(jq -r 'join(" ")' <<<"$RDTS_REQUIRED_ARGS_JSON")"
  index_conf="$(write_checkpoint_indexes_conf)"
  sudo install -d -m 0755 /etc/bvml
  sudo tee "$KNOTS_CONFIG" >/dev/null <<EOF
chain=signet
datadir=$MOUNT
blocksxor=0
$index_conf
EOF
  sudo tee /etc/systemd/system/bvml-knots.service >/dev/null <<EOF
[Unit]
Description=Bitcoin Knots with authenticated release-specific RDTS
RequiresMountsFor=$MOUNT
ConditionPathIsMountPoint=$MOUNT
After=network-online.target
[Service]
User=$BITCOIN_SERVICE_USER
Group=$BITCOIN_SERVICE_GROUP
ExecStartPre=$0 check-mount
ExecStartPre=$0 invalidate-evidence
ExecStart=/usr/local/bin/bitcoind -conf=$KNOTS_CONFIG $rdts_args
ExecStop=/usr/local/bin/bitcoin-cli -conf=$KNOTS_CONFIG stop
TimeoutStopSec=900
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable bvml-knots.service
}

invalidate_evidence() {
  expected_mount
  sudo rm -f -- "$EVIDENCE"
  [[ ! -e "$EVIDENCE" ]] || fail "could not invalidate stale verification evidence"
}
start_knots() {
  expected_mount; validate_rdts_supported; invalidate_evidence
  sudo systemctl start bvml-knots.service
  local waited=0
  while ! pgrep -x bitcoind >/dev/null; do
    ((waited++ < 30)) || fail "Knots service started but no bitcoind process appeared"
    sleep 1
  done
  validate_rdts_runtime
}

stop_knots() {
  if ! systemctl list-unit-files --no-legend bvml-knots.service 2>/dev/null | grep -q '^bvml-knots.service'; then
    echo "application already stopped: Knots service is not installed"
    return 0
  fi
  if ! systemctl is-active --quiet bvml-knots.service; then
    pgrep -x bitcoind >/dev/null && fail "service is inactive but a bitcoind process remains"
    echo "application already stopped"
    return 0
  fi
  sudo systemctl stop bvml-knots.service || fail "Knots service exists but failed to stop"
  systemctl is-active --quiet bvml-knots.service && fail "Knots service did not stop"
  pgrep -x bitcoind >/dev/null && fail "bitcoind remains active"
  sync
  echo "application stopped successfully"
}

verify_shutdown() {
  expected_mount; validate_rdts_runtime
  systemctl is-active --quiet bvml-knots.service || fail "Knots must be running to collect current node state"
  load_profiles
  local info indexes height headers ibd best best_header best_time median_time now tip_age
  local actual normalized digest uuid index_state expected_indexes profile_id verified_epoch
  info="$(/usr/local/bin/bitcoin-cli -conf="$KNOTS_CONFIG" getblockchaininfo)"
  [[ "$(jq -r .chain <<<"$info")" == signet ]] || fail "Knots is not on signet"
  ibd="$(jq -r .initialblockdownload <<<"$info")"; [[ "$ibd" == false ]] || fail "IBD is incomplete"
  height="$(jq -r .blocks <<<"$info")"; headers="$(jq -r .headers <<<"$info")"
  [[ "$height" == "$headers" ]] || fail "headers remain ahead of blocks"
  best="$(jq -r .bestblockhash <<<"$info")"
  best_header="$(/usr/local/bin/bitcoin-cli -conf="$KNOTS_CONFIG" getblockheader "$best")"
  best_time="$(jq -er '.time' <<<"$best_header")"
  median_time="$(jq -er '.mediantime' <<<"$info")"
  now="$(date +%s)"; ((now >= best_time)) || fail "best block time is in the future"
  tip_age=$((now - best_time))
  [[ "${MAX_TIP_AGE_SECONDS:-}" =~ ^[1-9][0-9]*$ ]] || fail "MAX_TIP_AGE_SECONDS is invalid"
  ((tip_age <= MAX_TIP_AGE_SECONDS)) ||
    fail "best block is ${tip_age}s old, exceeding ${MAX_TIP_AGE_SECONDS}s"
  indexes="$(/usr/local/bin/bitcoin-cli -conf="$KNOTS_CONFIG" getindexinfo)"
  index_state="$(jq -c 'with_entries(.value = {synced:(.value.synced == true),best_block_height:(.value.best_block_height // null)})' <<<"$indexes")"
  expected_indexes="$(jq -c '.indexes | unique | sort' "$CHECKPOINT_PROFILE_FILE")"
  jq -e --argjson expected "$expected_indexes" '
    . as $state |
    all($expected[]; $state[.] != null and $state[.].synced == true) and
    all(to_entries[]; .value.synced == true)
  ' <<<"$index_state" >/dev/null || fail "required index set is missing, conflicting, or unsynchronized"
  profile_id="$(jq -er .id "$CHECKPOINT_PROFILE_FILE")"
  actual="$(</etc/bvml/knots-actual-version)"
  normalized="$(</etc/bvml/knots-version-normalized)"
  [[ "$normalized" == "$KNOTS_VERSION_NORMALIZED" ]] || fail "installed normalized version changed"
  digest="$(</etc/bvml/knots-artifact.sha256)"
  uuid="$(</etc/bvml/bitcoin-filesystem.uuid)"
  stop_knots
  verified_epoch="$(date +%s)"
  sudo install -d -m 0750 "$MOUNT/.bvml"
  sudo tee "$EVIDENCE" >/dev/null <<EOF
vm=ubuntu
network=signet
blocksxor=0
synced=1
clean_shutdown=1
datadir_layout=signet-subdir
rdts_validated=1
rdts_profile_name=$RDTS_PROFILE_NAME
rdts_profile_sha256=${KNOTS_RDTS_PROFILE_SHA256,,}
rdts_observed_args_json=$RDTS_OBSERVED_ARGS_JSON
knots_actual_version=$actual
knots_version_normalized=$normalized
artifact_sha256=$digest
block_height=$height
header_height=$headers
best_block_hash=$best
best_block_time=$best_time
median_time=$median_time
tip_age_seconds=$tip_age
max_tip_age_seconds=$MAX_TIP_AGE_SECONDS
verified_epoch=$verified_epoch
filesystem_uuid=$uuid
checkpoint_profile_id=$profile_id
checkpoint_profile_sha256=${CHECKPOINT_PROFILE_SHA256,,}
index_state_json=$index_state
shutdown_id=$(date +%s%N)-$$
verified=$(date -u +%FT%TZ)
EOF
  sync
}

case "${1:-status}" in
  stage-bootstrap) shift; stage_bootstrap "$@" ;;
  init-filesystem) shift; init_filesystem "$@" ;;
  install) install_service ;;
  check-mount) expected_mount ;;
  invalidate-evidence) invalidate_evidence ;;
  start) start_knots ;;
  stop) stop_knots ;;
  verify-shutdown) verify_shutdown ;;
  status) expected_mount; systemctl status bvml-knots.service --no-pager ;;
  *) fail "usage: $0 {stage-bootstrap ID SERIAL SIZE NONCE|init-filesystem --confirm-bootstrap-format ID SERIAL SIZE NONCE|install|check-mount|start|stop|verify-shutdown|status}" ;;
esac
