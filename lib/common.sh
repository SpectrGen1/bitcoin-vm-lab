#!/usr/bin/env bash
set -Eeuo pipefail

BVML_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BVML_ROOT/config/defaults.env"
if [[ "${BVML_TESTING:-0}" != 1 && -f "$BVML_ROOT/config/local.env" ]]; then
  source "$BVML_ROOT/config/local.env"
fi
if [[ "${BVML_TESTING:-0}" != 1 && -f "$BVML_HOST_CONFIG_DIR/host.env" ]]; then
  [[ "$(stat -c %u "$BVML_HOST_CONFIG_DIR/host.env")" == 0 &&
     -z "$(find "$BVML_HOST_CONFIG_DIR/host.env" -maxdepth 0 -perm /022 -print -quit)" ]] ||
    die_early="unsafe ownership or mode on $BVML_HOST_CONFIG_DIR/host.env"
  [[ -z "${die_early:-}" ]] || { echo "error: $die_early" >&2; exit 1; }
  # shellcheck source=/dev/null
  source "$BVML_HOST_CONFIG_DIR/host.env"
fi

CANONICAL_DIR="$BVML_STORAGE/canonical"
CANONICAL="$CANONICAL_DIR/bitcoin-mainnet.qcow2"
CANONICAL_META="$CANONICAL_DIR/manifest.env"
ROLLBACK="$CANONICAL_DIR/bitcoin-mainnet.rollback.qcow2"
ROLLBACK_META="$CANONICAL_DIR/rollback-manifest.env"
if [[ -n "$ROLLBACK_DESTINATION" ]]; then
  ROLLBACK="$ROLLBACK_DESTINATION/bitcoin-mainnet.rollback.qcow2"
  ROLLBACK_META="$ROLLBACK_DESTINATION/rollback-manifest.env"
fi
ACTIVE_DIR="$BVML_STORAGE/active"
BOOTSTRAP="$ACTIVE_DIR/bitcoin-mainnet-bootstrap.qcow2"
BOOTSTRAP_META="$ACTIVE_DIR/bootstrap-manifest.env"
BOOTSTRAP_VERIFY="$ACTIVE_DIR/bootstrap-verification.env"
IMPORT_CANDIDATE="$CANONICAL_DIR/import-candidate.qcow2"
IMPORT_META="$CANONICAL_DIR/import-candidate-manifest.env"
BOOTSTRAP_CANDIDATE="$CANONICAL_DIR/bootstrap-promotion-candidate.qcow2"
BOOTSTRAP_CANDIDATE_META="$CANONICAL_DIR/bootstrap-promotion-manifest.env"
RUN_DIR="$BVML_STORAGE/run"
LIFECYCLE_ROOT="$RUN_DIR/lifecycles"
GLOBAL_LOCK_FILE="$RUN_DIR/canonical.lock"
LOCK_FILE="$GLOBAL_LOCK_FILE"
RECOVERY_META="$RUN_DIR/recovery.env"
ADAPTER_STATE_DIR="$RUN_DIR/adapters"
STARTOS_LAYER_DIR="$BVML_STORAGE/adapters/startos"
STARTOS_LAYER="$STARTOS_LAYER_DIR/bitcoin-mainnet-btrfs.qcow2"
STARTOS_LAYER_META="$STARTOS_LAYER_DIR/manifest.env"
STARTOS_LAYER_CANDIDATE="$STARTOS_LAYER_DIR/conversion-candidate.qcow2"
STARTOS_LAYER_CANDIDATE_META="$STARTOS_LAYER_DIR/conversion-candidate.env"
STARTOS_LAYER_RECOVERY="$STARTOS_LAYER_DIR/recovery.env"
STARTOS_LAYER_LOCK="$STARTOS_LAYER_DIR/adapter.lock"
INDEX_ROOT="$BVML_STORAGE/indexes"
INDEX_RUN_ROOT="$RUN_DIR/indexes"
LEGACY_OVERLAY="$ACTIVE_DIR/bitcoin-mainnet-overlay.qcow2"
LEGACY_OVERLAY_META="$ACTIVE_DIR/manifest.env"
LEGACY_VERIFY_META="$ACTIVE_DIR/ubuntu-verification.env"
LEGACY_OWNER_FILE="$RUN_DIR/owner.env"
LEGACY_ADAPTER_RECOVERY_META="$RUN_DIR/umbrel-recovery.env"

lifecycle_dir() { printf '%s/%s' "$LIFECYCLE_ROOT" "$1"; }
lifecycle_active_dir() { printf '%s/%s' "$ACTIVE_DIR" "$1"; }
lifecycle_overlay() { printf '%s/bitcoin-mainnet-overlay.qcow2' "$(lifecycle_active_dir "$1")"; }
lifecycle_meta() { printf '%s/manifest.env' "$(lifecycle_dir "$1")"; }
lifecycle_owner() { printf '%s/owner.env' "$(lifecycle_dir "$1")"; }
lifecycle_verify() { printf '%s/verification.env' "$(lifecycle_dir "$1")"; }
lifecycle_recovery() { printf '%s/recovery.env' "$(lifecycle_dir "$1")"; }
lifecycle_lock() { printf '%s/lifecycle.lock' "$(lifecycle_dir "$1")"; }
valid_index_service() {
  [[ "${1:-}" =~ ^(electrs|fulcrum)$ ]] ||
    die "index service must be electrs or fulcrum"
}
index_supported_for_vm() {
  local vm="$1" service="$2"
  valid_vm "$vm"; valid_index_service "$service"
  # Ubuntu and Umbrel run both Electrs and Fulcrum. StartOS runs both via the
  # official Fulcrum package and the community Electrs package.
  return 0
}
index_base_dir() { valid_index_service "$1"; printf '%s/%s' "$INDEX_ROOT" "$1"; }
index_base() { printf '%s/base.qcow2' "$(index_base_dir "$1")"; }
index_base_meta() { printf '%s/manifest.env' "$(index_base_dir "$1")"; }
index_bootstrap() { printf '%s/bootstrap.qcow2' "$(index_base_dir "$1")"; }
index_bootstrap_meta() { printf '%s/bootstrap-manifest.env' "$(index_base_dir "$1")"; }
index_bootstrap_verify() { printf '%s/bootstrap-verification.json' "$(index_base_dir "$1")"; }
index_service_dir() { printf '%s/services/%s' "$(lifecycle_dir "$1")" "$2"; }
index_overlay() { printf '%s/%s-overlay.qcow2' "$(lifecycle_active_dir "$1")" "$2"; }
index_overlay_meta() { printf '%s/manifest.env' "$(index_service_dir "$1" "$2")"; }
index_recovery() { printf '%s/recovery.env' "$(index_service_dir "$1" "$2")"; }
index_target() {
  case "$1" in electrs) printf vdd ;; fulcrum) printf vde ;; *) valid_index_service "$1" ;; esac
}
index_device() {
  case "$1" in electrs) printf '%s' "$INDEX_DEVICE_ELECTRS" ;;
    fulcrum) printf '%s' "$INDEX_DEVICE_FULCRUM" ;; *) valid_index_service "$1" ;; esac
}
index_serial_prefix() {
  case "$1" in electrs) printf BVMLE ;; fulcrum) printf BVMLF ;; *) valid_index_service "$1" ;; esac
}
index_services_for_vm() {
  case "$1" in
    ubuntu|umbrel|startos) printf '%s\n' electrs fulcrum ;;
    *) valid_vm "$1" ;;
  esac
}
backing_image_for_vm() {
  if [[ "$1" == startos ]]; then printf '%s' "$STARTOS_LAYER"
  else printf '%s' "$CANONICAL"
  fi
}

set_lifecycle_context() {
  local vm="$1"; valid_vm "$vm"
  LIFECYCLE_VM="$vm"
  OVERLAY="$(lifecycle_overlay "$vm")"
  OVERLAY_META="$(lifecycle_meta "$vm")"
  OWNER_FILE="$(lifecycle_owner "$vm")"
  VERIFY_META="$(lifecycle_verify "$vm")"
  ADAPTER_RECOVERY_META="$(lifecycle_recovery "$vm")"
}

die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*"; }
need() { command -v "$1" >/dev/null || die "missing command: $1"; }
domain() { printf 'bvml-%s' "$1"; }
valid_vm() { [[ "${1:-}" =~ ^(ubuntu|umbrel|startos)$ ]] || die "VM must be ubuntu, umbrel, or startos"; }
# Ubuntu is the default only for producer/bootstrap functions that predate explicit
# lifecycle arguments. Consumer commands always select their VM before acting.
set_lifecycle_context ubuntu
vm_dir() { printf '%s/vms/%s' "$BVML_STORAGE" "$1"; }
virshq() { virsh -c "$LIBVIRT_URI" "$@"; }
qemu_img_info_json() {
  local image="$1"
  if [[ -r "$image" ]]; then
    qemu-img info --force-share --output=json "$image"
  else
    sudo -n -u "$QEMU_USER" qemu-img info --force-share --output=json "$image"
  fi
}
guest_exec_request_json() {
  local path="$1"; shift
  jq -cn --arg path "$path" --args '$ARGS.positional |
    {execute:"guest-exec",arguments:{path:$path,arg:.,"capture-output":true}}' -- "$@"
}
guest_exec_sync() {
  local vm="$1" path="$2" timeout="$3"; shift 3
  if [[ "${BVML_TESTING:-0}" == 1 && "${BVML_TEST_GUEST_EXEC:-0}" != 1 ]]; then return 0; fi
  need jq
  local response pid status waited=0 request stdout stderr exitcode
  GUEST_EXEC_STDOUT=
  request="$(guest_exec_request_json "$path" "$@")"
  response="$(virshq qemu-agent-command "$(domain "$vm")" \
    "$request" 2>/dev/null)" || die "$vm guest-agent transport failed while submitting $path"
  pid="$(jq -er '.return.pid' <<<"$response")" ||
    die "$vm guest agent returned no PID for $path"
  while :; do
    status="$(virshq qemu-agent-command "$(domain "$vm")" \
      "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}" 2>/dev/null)" ||
      die "$vm guest-agent transport failed while polling PID $pid"
    if [[ "$(jq -r '.return.exited // false' <<<"$status")" == true ]]; then
      stdout="$(jq -r '.return["out-data"] // empty' <<<"$status" | base64 -d 2>/dev/null || true)"
      stderr="$(jq -r '.return["err-data"] // empty' <<<"$status" | base64 -d 2>/dev/null || true)"
      [[ -z "$stdout" ]] || printf '%s\n' "$stdout"
      [[ -z "$stderr" ]] || printf '%s\n' "$stderr" >&2
      exitcode="$(jq -r '.return.exitcode // 255' <<<"$status")"
      [[ "$exitcode" == 0 ]] || die "$vm guest command '$path $*' failed with exit $exitcode"
      GUEST_EXEC_STDOUT="$stdout"
      break
    fi
    (( waited++ < timeout )) || die "$vm guest command '$path $*' timed out after ${timeout}s"
    sleep 1
  done
}
domain_ipv4() {
  local vm="$1" address
  address="$({ virshq domifaddr "$(domain "$vm")" --source agent 2>/dev/null || true; } |
    awk '$3 == "ipv4" && $4 !~ /^127\./ && $4 !~ /^169\.254\./ {
      sub(/\/.*/, "", $4); print $4; exit
    }')"
  [[ -n "$address" ]] || address="$({ virshq domifaddr "$(domain "$vm")" --source lease 2>/dev/null || true; } |
    awk '$3 == "ipv4" && $4 !~ /^127\./ && $4 !~ /^169\.254\./ {
      sub(/\/.*/, "", $4); print $4; exit
    }')"
  printf '%s\n' "$address"
}
umbrel_exec_sync() {
  local path="$1" timeout="$2"; shift 2
  if virshq qemu-agent-command "$(domain umbrel)" '{"execute":"guest-ping"}' >/dev/null 2>&1; then
    guest_exec_sync umbrel "$path" "$timeout" "$@"
    return
  fi
  [[ "$UMBREL_SSH_PRIVATE_KEY" == /* && -f "$UMBREL_SSH_PRIVATE_KEY" ]] ||
    die "Umbrel QGA is unavailable and UMBREL_SSH_PRIVATE_KEY is not configured"
  local address="${UMBREL_MANAGEMENT_ADDRESS:-}" output status password remote_command arg
  local waited=0 attempt_timeout
  [[ "$UMBREL_CREDENTIALS_FILE" == /* && -f "$UMBREL_CREDENTIALS_FILE" ]] ||
    die "Umbrel SSH management requires the protected UMBREL_CREDENTIALS_FILE"
  password="$(jq -er '.password | select(type=="string" and length>=12)' "$UMBREL_CREDENTIALS_FILE")" ||
    die "Umbrel management credential file lacks a valid password"
  printf -v remote_command 'sudo -S -p %q -- %q' '' "$path"
  for arg in "$@"; do
    printf -v remote_command '%s %q' "$remote_command" "$arg"
  done
  while :; do
    if virshq qemu-agent-command "$(domain umbrel)" \
      '{"execute":"guest-ping"}' >/dev/null 2>&1; then
      unset password
      guest_exec_sync umbrel "$path" "$timeout" "$@"
      return
    fi
    [[ -n "$address" ]] || address="$(domain_ipv4 umbrel)"
    if [[ ! "$address" =~ ^[A-Za-z0-9:.%-]+$ ]]; then
      status=255
      output="Umbrel management address is not available"
    else
      attempt_timeout=$((timeout-waited))
      (( attempt_timeout > 0 )) || break
      set +e
      output="$(printf '%s\n' "$password" | timeout "$attempt_timeout" ssh -i "$UMBREL_SSH_PRIVATE_KEY" \
        -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
        "$UMBREL_SSH_USER@$address" "$remote_command" 2>&1)"
      status=$?
      set -e
      (( status == 0 )) && break
      if (( status != 255 && status != 124 )) ||
        ! grep -Eqi 'connection refused|no route to host|connection timed out|operation timed out|network is unreachable' <<<"$output"; then
        break
      fi
    fi
    (( waited < timeout )) || break
    sleep 2
    waited=$((waited+2))
    address=
  done
  unset password
  [[ -z "$output" ]] || printf '%s\n' "$output"
  [[ "$status" == 0 ]] || die "Umbrel SSH command '$path $*' failed with exit $status"
  GUEST_EXEC_STDOUT="$output"
}
startos_exec_sync() {
  local path="$1" timeout="$2"; shift 2
  if virshq qemu-agent-command "$(domain startos)" '{"execute":"guest-ping"}' >/dev/null 2>&1; then
    guest_exec_sync startos "$path" "$timeout" "$@"
    return
  fi
  [[ "$STARTOS_SSH_PRIVATE_KEY" == /* && -f "$STARTOS_SSH_PRIVATE_KEY" ]] ||
    die "StartOS QGA is unavailable and STARTOS_SSH_PRIVATE_KEY is not configured"
  local address="${STARTOS_MANAGEMENT_ADDRESS:-}" output status remote_command arg
  local waited=0 attempt_timeout
  printf -v remote_command 'sudo -- %q' "$path"
  for arg in "$@"; do printf -v remote_command '%s %q' "$remote_command" "$arg"; done
  while :; do
    if virshq qemu-agent-command "$(domain startos)" \
      '{"execute":"guest-ping"}' >/dev/null 2>&1; then
      guest_exec_sync startos "$path" "$timeout" "$@"
      return
    fi
    [[ -n "$address" ]] || address="$(domain_ipv4 startos)"
    if [[ ! "$address" =~ ^[A-Za-z0-9:.%-]+$ ]]; then
      status=255
      output="StartOS management address is not available"
    else
      attempt_timeout=10
      (( timeout - waited < attempt_timeout )) && attempt_timeout=$((timeout-waited))
      (( attempt_timeout > 0 )) || break
      set +e
      output="$(timeout "$attempt_timeout" ssh -i "$STARTOS_SSH_PRIVATE_KEY" \
        -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
        "$STARTOS_SSH_USER@$address" "$remote_command" 2>&1)"
      status=$?
      set -e
      (( status == 0 )) && break
      if (( status != 255 && status != 124 )) ||
        ! grep -Eqi 'connection refused|no route to host|connection timed out|operation timed out|network is unreachable' <<<"$output"; then
        break
      fi
    fi
    (( waited < timeout )) || break
    sleep 2
    waited=$((waited+2))
    address=
  done
  [[ -z "$output" ]] || printf '%s\n' "$output"
  [[ "$status" == 0 ]] ||
    die "StartOS SSH command '$path $*' failed with exit $status"
  GUEST_EXEC_STDOUT="$output"
}
platform_exec_sync() {
  local vm="$1" path="$2" timeout="$3"; shift 3
  if [[ "$vm" == umbrel ]]; then umbrel_exec_sync "$path" "$timeout" "$@"
  elif [[ "$vm" == startos ]]; then startos_exec_sync "$path" "$timeout" "$@"
  else guest_exec_sync "$vm" "$path" "$timeout" "$@"
  fi
}
virt_customize_offline() {
  LIBGUESTFS_PATH="$LIBGUESTFS_APPLIANCE_PATH" LIBGUESTFS_BACKEND=direct \
    virt-customize "$@"
}
guestfish_data_disk() {
  LIBGUESTFS_PATH="$LIBGUESTFS_APPLIANCE_PATH" LIBGUESTFS_BACKEND=direct \
    guestfish --rw -a "$1" -m /dev/sda "${@:2}"
}
is_defined() { virshq dominfo "$(domain "$1")" >/dev/null 2>&1; }
domain_state() { virshq domstate "$(domain "$1")" 2>/dev/null | sed -n '1{s/[[:space:]]*$//;p;}'; }
is_shut_off() { [[ "$(domain_state "$1")" == "shut off" ]]; }
meta_get() {
  local file="$1" key="$2"
  [[ -f "$file" ]] && sed -n "s/^${key}=//p" "$file" | head -1
  return 0
}
overlay_vm() { meta_get "${1:-$OVERLAY_META}" vm; }
owner_vm() { meta_get "${1:-$OWNER_FILE}" vm; }
owner_kind() { meta_get "${1:-$OWNER_FILE}" kind; }
owner_image() { meta_get "${1:-$OWNER_FILE}" image; }
canonical_id() { meta_get "$CANONICAL_META" id; }
overlay_id() { meta_get "${1:-$OVERLAY_META}" overlay_id; }
checkpoint_generation() { meta_get "$CANONICAL_META" generation; }
profile_generation_digest() {
  printf '%s\n' \
    "release=${KNOTS_RELEASE_PROFILE_SHA256,,}" \
    "rdts=${KNOTS_RDTS_PROFILE_SHA256,,}" \
    "checkpoint=${CHECKPOINT_PROFILE_SHA256,,}" |
    sha256sum | awk '{print $1}'
}
profile_generation_id() {
  printf '%s' "${PROFILE_GENERATION_ID:-$(profile_generation_digest)}"
}
active_profile_generation_digest() {
  printf '%s' "${PROFILE_GENERATION_DIGEST:-$(profile_generation_digest)}"
}
assert_overlay_chain() {
  [[ -f "$OVERLAY" && -f "$OVERLAY_META" ]] || die "active overlay or manifest is missing"
  local expected_backing
  expected_backing="$(backing_image_for_vm "$LIFECYCLE_VM")"
  [[ "$(meta_get "$OVERLAY_META" backing)" == "$expected_backing" ]] ||
    die "overlay manifest backing path is invalid"
  [[ "$(meta_get "$OVERLAY_META" canonical_id)" == "$(canonical_id)" ]] ||
    die "overlay survived a checkpoint replacement; discard it"
  [[ "$(meta_get "$OVERLAY_META" checkpoint_generation)" == "$(checkpoint_generation)" ]] ||
    die "overlay checkpoint generation does not match the canonical checkpoint"
  [[ -n "$(overlay_id)" ]] || die "overlay manifest lacks a unique overlay ID"
  local backing
  if [[ -r "$OVERLAY" ]]; then
    backing="$(qemu-img info --force-share --output=json "$OVERLAY" | jq -er '.["backing-filename"]')"
  else
    backing="$(sudo -n qemu-img info --force-share --output=json "$OVERLAY" |
      jq -er '.["backing-filename"]')"
  fi
  [[ "$backing" == "$expected_backing" ]] ||
    die "overlay qcow2 backing is '$backing', expected '$expected_backing'"
  if [[ "$LIFECYCLE_VM" == startos ]]; then
    [[ "$(meta_get "$OVERLAY_META" startos_adapter_id)" == "$(meta_get "$STARTOS_LAYER_META" id)" ]] ||
      die "StartOS overlay belongs to another filesystem-adapter generation"
  fi
}
new_id() {
  if command -v uuidgen >/dev/null; then uuidgen
  else printf '%s-%s-%s\n' "$(date +%s%N)" "$$" "$RANDOM" | sha256sum | cut -d' ' -f1
  fi
}

validate_host_config_values() {
  local name value
  for name in BVML_STORAGE BVML_MEDIA_DIR BVML_HOST_CONFIG_DIR CHECKPOINT_PROFILE_FILE CHECKPOINT_PROFILE_SOURCE UMBREL_PROFILE STARTOS_PROFILE INDEX_PROFILE STARTOS_ISO STARTOS_PACKAGE STARTOS_CLI; do
    value="${!name:-}"
    [[ "$value" == /* && ! "$value" =~ [[:cntrl:]] && "$value" != *'"'* ]] ||
      die "$name must be an absolute path without quotes or control characters"
  done
  for name in ROLLBACK_DESTINATION KNOTS_RELEASE_PROFILE KNOTS_RDTS_PROFILE; do
    value="${!name:-}"
    [[ -z "$value" || ( "$value" == /* && ! "$value" =~ [[:cntrl:]] ) ]] ||
      die "$name must be empty or an absolute path without control characters"
  done
  [[ "$SHUTDOWN_TIMEOUT" =~ ^[1-9][0-9]*$ && "$GUEST_EXEC_TIMEOUT" =~ ^[1-9][0-9]*$ &&
     "$MAX_TIP_AGE_SECONDS" =~ ^[1-9][0-9]*$ &&
     "$STARTOS_OPERATION_TIMEOUT" =~ ^[1-9][0-9]*$ &&
     "$STARTOS_BTRFS_CONVERT_TIMEOUT" =~ ^[1-9][0-9]*$ &&
     "$STARTOS_BTRFS_ADAPTER_MAX_GIB" =~ ^[1-9][0-9]*$ &&
     "$STARTOS_BTRFS_ADAPTER_MAX_PERCENT" =~ ^[1-9][0-9]*$ &&
     "$ELECTRS_BASE_SIZE_GIB" =~ ^[1-9][0-9]*$ &&
     "$FULCRUM_BASE_SIZE_GIB" =~ ^[1-9][0-9]*$ &&
     "$INDEX_BUILD_TIMEOUT" =~ ^[1-9][0-9]*$ ]] ||
    die "timeout and chain-tip-age settings must be positive integers"
}
validate_host_config_values

init_layout() {
  local vm
  if [[ "${BVML_TESTING:-0}" == 1 ]]; then
    install -d -m 0750 "$BVML_STORAGE" "$CANONICAL_DIR" "$ACTIVE_DIR" "$RUN_DIR" \
      "$LIFECYCLE_ROOT" "$ADAPTER_STATE_DIR" "$STARTOS_LAYER_DIR" "$INDEX_ROOT" \
      "$INDEX_RUN_ROOT" "$BVML_STORAGE/vms"
  else
    need sudo
    sudo install -d -o "$USER" -g "$QEMU_GROUP" -m 0750 \
      "$BVML_STORAGE" "$CANONICAL_DIR" "$ACTIVE_DIR" "$RUN_DIR" \
      "$LIFECYCLE_ROOT" "$ADAPTER_STATE_DIR" "$STARTOS_LAYER_DIR" "$INDEX_ROOT" \
      "$INDEX_RUN_ROOT" "$BVML_STORAGE/vms"
  fi
  touch "$GLOBAL_LOCK_FILE"; chmod 0640 "$GLOBAL_LOCK_FILE"
  touch "$STARTOS_LAYER_LOCK"; chmod 0640 "$STARTOS_LAYER_LOCK"
  for vm in ubuntu umbrel startos; do
    if [[ "${BVML_TESTING:-0}" == 1 ]]; then
      install -d -m 0750 "$(lifecycle_dir "$vm")" "$(lifecycle_active_dir "$vm")"
    else
      sudo install -d -o "$USER" -g "$QEMU_GROUP" -m 0750 \
        "$(lifecycle_dir "$vm")" "$(lifecycle_active_dir "$vm")"
    fi
    touch "$(lifecycle_lock "$vm")"; chmod 0640 "$(lifecycle_lock "$vm")"
    local service
    while read -r service; do
      if [[ "${BVML_TESTING:-0}" == 1 ]]; then
        install -d -m 0750 "$(index_service_dir "$vm" "$service")"
      else
        sudo install -d -o "$USER" -g "$QEMU_GROUP" -m 0750 \
          "$(index_service_dir "$vm" "$service")"
      fi
    done < <(index_services_for_vm "$vm")
  done
  local service
  for service in electrs fulcrum; do
    if [[ "${BVML_TESTING:-0}" == 1 ]]; then
      install -d -m 0750 "$(index_base_dir "$service")"
    else
      sudo install -d -o "$USER" -g "$QEMU_GROUP" -m 0750 "$(index_base_dir "$service")"
    fi
  done
  if [[ "${BVML_TESTING:-0}" != 1 ]] && command -v setfacl >/dev/null; then
    setfacl -m "u:$QEMU_USER:--x" "$BVML_STORAGE" "$CANONICAL_DIR" "$ACTIVE_DIR" "$BVML_STORAGE/vms"
    for vm in ubuntu umbrel startos; do
      setfacl -m "u:$QEMU_USER:--x" "$(lifecycle_active_dir "$vm")"
    done
    setfacl -m "u:$QEMU_USER:--x" "$INDEX_ROOT"
    for service in electrs fulcrum; do
      setfacl -m "u:$QEMU_USER:--x" "$(index_base_dir "$service")"
    done
  fi
}

with_global_lock() {
  init_layout
  exec 9>"$GLOBAL_LOCK_FILE"
  flock -n 9 || die "another canonical bitcoin-vm-lab operation is running"
  migrate_legacy_lifecycle_state
  "$@"
}

with_vm_lock() {
  local vm="$1"; shift
  valid_vm "$vm"; init_layout
  exec 9>"$GLOBAL_LOCK_FILE"
  flock -n 9 || die "another canonical bitcoin-vm-lab operation is running"
  migrate_legacy_lifecycle_state
  flock -u 9
  exec 8>"$(lifecycle_lock "$vm")"
  flock -n 8 || die "another $vm lifecycle operation is running"
  set_lifecycle_context "$vm"
  "$@"
}

with_all_vm_locks() {
  init_layout
  exec 9>"$GLOBAL_LOCK_FILE"
  flock -n 9 || die "canonical state is being changed; retry validation"
  migrate_legacy_lifecycle_state
  flock -u 9
  exec 6>"$(lifecycle_lock ubuntu)"
  exec 7>"$(lifecycle_lock umbrel)"
  exec 8>"$(lifecycle_lock startos)"
  flock -n 6 || die "Ubuntu lifecycle is changing; retry validation"
  flock -n 7 || die "Umbrel lifecycle is changing; retry validation"
  flock -n 8 || die "StartOS lifecycle is changing; retry validation"
  "$@"
}

with_lock() { with_global_lock "$@"; }

legacy_lifecycle_paths() {
  for path in "$LEGACY_OVERLAY" "$LEGACY_OVERLAY_META" "$LEGACY_VERIFY_META" \
    "$LEGACY_OWNER_FILE" "$LEGACY_ADAPTER_RECOVERY_META"; do
    [[ -e "$path" ]] && printf '%s\n' "$path"
  done
  return 0
}

migrate_legacy_lifecycle_state() {
  local found vm manifest_vm owner_vm_value recovery_vm
  found="$(legacy_lifecycle_paths)"
  [[ -n "$found" ]] || return 0
  manifest_vm="$(meta_get "$LEGACY_OVERLAY_META" vm)"
  owner_vm_value="$(meta_get "$LEGACY_OWNER_FILE" vm)"
  recovery_vm="$(meta_get "$LEGACY_ADAPTER_RECOVERY_META" vm)"
  vm="${manifest_vm:-${owner_vm_value:-$recovery_vm}}"
  valid_vm "$vm"
  [[ -z "$manifest_vm" || "$manifest_vm" == "$vm" ]] ||
    die "legacy overlay manifest and owner identify different VMs"
  [[ -z "$owner_vm_value" || "$owner_vm_value" == "$vm" ]] ||
    die "legacy owner and overlay manifest identify different VMs"
  [[ -z "$recovery_vm" || "$recovery_vm" == "$vm" ]] ||
    die "legacy recovery metadata identifies another VM"
  local target
  for target in "$(lifecycle_overlay "$vm")" "$(lifecycle_meta "$vm")" \
    "$(lifecycle_verify "$vm")" "$(lifecycle_owner "$vm")" "$(lifecycle_recovery "$vm")"; do
    [[ ! -e "$target" ]] || die "cannot migrate legacy lifecycle: target already exists: $target"
  done
  [[ ! -e "$LEGACY_OVERLAY" || -e "$LEGACY_OVERLAY_META" ]] ||
    die "cannot migrate legacy overlay without its manifest"
  [[ ! -e "$LEGACY_OVERLAY_META" || -e "$LEGACY_OVERLAY" ]] ||
    die "cannot migrate legacy manifest without its overlay"
  [[ ! -e "$LEGACY_OWNER_FILE" || -e "$LEGACY_OVERLAY_META" ]] ||
    die "cannot migrate legacy owner without an overlay manifest"
  [[ ! -e "$LEGACY_VERIFY_META" || "$vm" == ubuntu ]] ||
    die "legacy producer evidence is attached to non-Ubuntu lifecycle state"
  if [[ -e "$LEGACY_OVERLAY" ]]; then
    [[ -z "$(attached_vm_for_path "$LEGACY_OVERLAY")" ]] ||
      die "legacy overlay is still attached; stop and detach it before automatic layout migration"
    if is_defined "$vm"; then
      is_shut_off "$vm" ||
        die "legacy $vm lifecycle is active; exact 'shut off' is required for layout migration"
    fi
    assert_no_process_reference "$LEGACY_OVERLAY"
  fi
  [[ ! -e "$LEGACY_OVERLAY" ]] ||
    mv -- "$LEGACY_OVERLAY" "$(lifecycle_overlay "$vm")"
  [[ ! -e "$LEGACY_OVERLAY_META" ]] ||
    mv -- "$LEGACY_OVERLAY_META" "$(lifecycle_meta "$vm")"
  [[ ! -e "$LEGACY_VERIFY_META" ]] ||
    mv -- "$LEGACY_VERIFY_META" "$(lifecycle_verify "$vm")"
  [[ ! -e "$LEGACY_OWNER_FILE" ]] ||
    mv -- "$LEGACY_OWNER_FILE" "$(lifecycle_owner "$vm")"
  [[ ! -e "$LEGACY_ADAPTER_RECOVERY_META" ]] ||
    mv -- "$LEGACY_ADAPTER_RECOVERY_META" "$(lifecycle_recovery "$vm")"
  if [[ -f "$(lifecycle_owner "$vm")" ]]; then
    sed -i \
      -e "s#^image=$LEGACY_OVERLAY\$#image=$(lifecycle_overlay "$vm")#" \
      -e "s#^overlay=$LEGACY_OVERLAY\$#overlay=$(lifecycle_overlay "$vm")#" \
      "$(lifecycle_owner "$vm")"
  fi
  note "migrated legacy singleton lifecycle state to $vm"
}

write_env_file() {
  local path="$1"; shift
  local item
  for item in "$@"; do
    [[ "$item" =~ ^[A-Za-z_][A-Za-z0-9_]*= && ! "$item" =~ [[:cntrl:]] ]] ||
      die "refusing malformed manifest value for $path"
  done
  umask 077
  : >"$path"
  for item in "$@"; do printf '%s\n' "$item" >>"$path"; done
}

meta_set() {
  local path="$1" key="$2" value="$3" tmp
  [[ -f "$path" ]] || die "cannot update missing manifest: $path"
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && ! "$value" =~ [[:cntrl:]] ]] ||
    die "refusing malformed manifest update for $path"
  tmp="${path}.new.$$"
  awk -F= -v key="$key" '$1 != key' "$path" >"$tmp"
  printf '%s=%s\n' "$key" "$value" >>"$tmp"
  chmod --reference="$path" "$tmp"
  mv -- "$tmp" "$path"
}

all_shut_off() {
  local vm
  for vm in ubuntu umbrel startos; do
    is_defined "$vm" || continue
    is_shut_off "$vm" || die "$(domain "$vm") is $(domain_state "$vm"); exact 'shut off' required"
  done
}

disk_sources() {
  local vm="$1"
  virshq domblklist "$(domain "$vm")" --details 2>/dev/null |
    awk 'NR>2 && $4 != "-" {print $4}'
}

disk_target_sources() {
  local vm="$1"
  virshq domblklist "$(domain "$vm")" --details 2>/dev/null |
    awk 'NR>2 && $4 != "-" {print $3 "\t" $4}'
}

target_for_source() {
  local vm="$1" source="$2"
  virshq domblklist "$(domain "$vm")" --details 2>/dev/null |
    awk -v wanted="$source" 'NR>2 && $4 == wanted {print $3; exit}'
}

attached_vm_for_path() {
  local wanted="$1" vm src
  for vm in ubuntu umbrel startos; do
    is_defined "$vm" || continue
    while IFS= read -r src; do [[ "$src" == "$wanted" ]] && printf '%s\n' "$vm"; done < <(disk_sources "$vm")
  done
}

attachment_serial_for_path() {
  local vm="$1" image="$2" candidate
  if [[ "${BVML_TESTING:-0}" == 1 ]]; then
    for candidate in ubuntu umbrel startos; do
      if [[ "$image" == "$(lifecycle_overlay "$candidate")" ]]; then
        meta_get "$(lifecycle_meta "$candidate")" disk_serial
        return
      fi
    done
    [[ "$image" != "$BOOTSTRAP" ]] || meta_get "$BOOTSTRAP_META" disk_serial
    local service meta
    for service in electrs fulcrum; do
      if [[ "$image" == "$(index_bootstrap "$service")" ]]; then
        meta_get "$(index_bootstrap_meta "$service")" disk_serial
        return
      fi
      for candidate in ubuntu umbrel startos; do
        if [[ "$image" == "$(index_overlay "$candidate" "$service")" ]]; then
          meta="$(index_overlay_meta "$candidate" "$service")"
          meta_get "$meta" disk_serial
          return
        fi
      done
    done
    return
  fi
  command -v xmllint >/dev/null || return 1
  [[ "$image" != *'"'* && "$image" != *$'\n'* ]] || die "image path cannot be represented safely in libvirt XML query"
  virshq dumpxml "$(domain "$vm")" --inactive |
    xmllint --xpath "string(//devices/disk[source/@file=\"$image\"]/serial)" - 2>/dev/null
}

all_attached_pairs() {
  local vm target src
  for vm in ubuntu umbrel startos; do
    is_defined "$vm" || continue
    while IFS=$'\t' read -r target src; do
      if [[ "$target" == vdc ]]; then
        printf '%s\t%s\n' "$vm" "$src"
      else
        case "$src" in
          "$OVERLAY"|"$BOOTSTRAP"|"$CANONICAL"|"$ROLLBACK"|"$IMPORT_CANDIDATE"|"$BOOTSTRAP_CANDIDATE"|"$STARTOS_LAYER"|"$STARTOS_LAYER_CANDIDATE")
          printf '%s\t%s\n' "$vm" "$src"
          ;;
        esac
      fi
    done < <(disk_target_sources "$vm")
  done
}

all_index_attached_pairs() {
  local vm owner_vm service src candidate
  for vm in ubuntu umbrel startos; do
    is_defined "$vm" || continue
    while read -r src; do
      for service in electrs fulcrum; do
        for candidate in "$(index_base "$service")" "$(index_bootstrap "$service")"; do
          [[ "$src" != "$candidate" ]] || printf '%s\t%s\t%s\n' "$vm" "$service" "$src"
        done
        for owner_vm in ubuntu umbrel startos; do
          index_supported_for_vm "$owner_vm" "$service" || continue
          candidate="$(index_overlay "$owner_vm" "$service")"
          [[ "$src" != "$candidate" ]] ||
            printf '%s\t%s\t%s\n' "$vm" "$service" "$src"
        done
      done
    done < <(disk_sources "$vm")
  done
}

validate_index_profile() {
  [[ "$INDEX_PROFILE" == /* && -f "$INDEX_PROFILE" ]] ||
    die "INDEX_PROFILE must name an absolute existing file"
  [[ "$INDEX_PROFILE_SHA256" =~ ^[0-9a-fA-F]{64}$ &&
     "$(sha256sum "$INDEX_PROFILE" | awk '{print $1}')" == "${INDEX_PROFILE_SHA256,,}" ]] ||
    die "index-service profile digest mismatch"
  jq -e '
    .profile_version == 1 and
    (.profile_id | type == "string" and length > 0) and
    .filesystems.base == "btrfs" and
    (.electrs.version | type == "string" and length > 0) and
    (.fulcrum.version | type == "string" and length > 0) and
    (.electrs.umbrel.store_commit | test("^[0-9a-f]{40}$")) and
    (.fulcrum.umbrel.store_commit | test("^[0-9a-f]{40}$")) and
    (.fulcrum.startos.release_sha256 | test("^[0-9a-f]{64}$"))
  ' "$INDEX_PROFILE" >/dev/null || die "index-service profile schema is invalid"
}

index_base_preflight() {
  local service="$1" image meta info
  valid_index_service "$service"; validate_index_profile
  image="$(index_base "$service")"; meta="$(index_base_meta "$service")"
  [[ -f "$image" && -f "$meta" ]] || die "$service protected index base is absent"
  for field in id bitcoin_canonical_id bitcoin_checkpoint_generation filesystem_uuid \
    profile_id profile_sha256 tip_hash tip_height database_layout; do
    [[ -n "$(meta_get "$meta" "$field")" ]] ||
      die "$service base manifest lacks $field"
  done
  [[ "$(meta_get "$meta" bitcoin_canonical_id)" == "$(canonical_id)" &&
     "$(meta_get "$meta" bitcoin_checkpoint_generation)" == "$(checkpoint_generation)" ]] ||
    die "$service base belongs to another Bitcoin canonical generation"
  [[ "$(meta_get "$meta" profile_sha256)" == "${INDEX_PROFILE_SHA256,,}" ]] ||
    die "$service base used another index-service profile"
  info="$(qemu-img info --force-share --output=json "$image")"
  [[ "$(jq -r .format <<<"$info")" == qcow2 &&
     -z "$(jq -r '.["backing-filename"] // empty' <<<"$info")" ]] ||
    die "$service base must be a standalone qcow2"
  qemu-img check "$image" >/dev/null || die "$service base qemu-img check failed"
  [[ "$(stat -c %a "$image")" == 440 ]] || die "$service base mode must be 0440"
  image_immutable "$image" || die "$service base immutable protection is missing"
  qemu_can_read_image "$image" || die "system QEMU cannot read the $service base"
  [[ -z "$(attached_vm_for_path "$image")" ]] ||
    die "$service base is attached directly to a VM"
}

index_overlay_preflight() {
  local vm="$1" service="$2" image meta base backing
  index_supported_for_vm "$vm" "$service" ||
    die "$service is unsupported on $vm"
  image="$(index_overlay "$vm" "$service")"
  meta="$(index_overlay_meta "$vm" "$service")"
  base="$(index_base "$service")"
  [[ -f "$image" && -f "$meta" ]] || die "$vm $service overlay state is incomplete"
  [[ "$(meta_get "$meta" vm)" == "$vm" &&
     "$(meta_get "$meta" service)" == "$service" &&
     "$(meta_get "$meta" bitcoin_canonical_id)" == "$(canonical_id)" &&
     "$(meta_get "$meta" bitcoin_checkpoint_generation)" == "$(checkpoint_generation)" ]] ||
    die "$vm $service overlay manifest does not match its protected bases"
  backing="$(qemu-img info --force-share --output=json "$image" |
    jq -er '.["backing-filename"]')"
  [[ "$backing" == "$base" ]] ||
    die "$vm $service overlay backing path is '$backing', expected '$base'"
  qemu-img check "$image" >/dev/null || die "$vm $service overlay qemu-img check failed"
}

bitcoin_attachment_count() {
  all_attached_pairs | awk 'END {print NR+0}'
}

assert_no_bitcoin_attachments() {
  local count; count="$(bitcoin_attachment_count)"
  [[ "$count" == 0 ]] || die "$count VM Bitcoin-disk attachment(s) remain"
}

assert_no_extra_overlays() {
  local extra="" path allowed vm service
  while IFS= read -r path; do
    allowed=0
    [[ "$path" == "$BOOTSTRAP" ]] && allowed=1
    for vm in ubuntu umbrel startos; do
      [[ "$path" == "$(lifecycle_overlay "$vm")" ]] && allowed=1
      for service in electrs fulcrum; do
        index_supported_for_vm "$vm" "$service" || continue
        [[ "$path" == "$(index_overlay "$vm" "$service")" ]] && allowed=1
      done
    done
    (( allowed == 1 )) || { extra="$path"; break; }
  done < <(find "$ACTIVE_DIR" -type f -name '*.qcow2' 2>/dev/null)
  [[ -z "$extra" ]] || die "unexpected extra overlay exists: $extra"
}

dependent_overlay_count() {
  local vm service count=0
  for vm in ubuntu umbrel startos; do
    [[ -e "$(lifecycle_overlay "$vm")" || -e "$(lifecycle_meta "$vm")" ]] && ((count+=1))
  done
  if [[ -e "$STARTOS_LAYER" || -e "$STARTOS_LAYER_META" ||
        -e "$STARTOS_LAYER_CANDIDATE" || -e "$STARTOS_LAYER_CANDIDATE_META" ||
        -e "$STARTOS_LAYER_RECOVERY" ]]; then
    ((count+=1))
  fi
  for service in electrs fulcrum; do
    [[ -e "$(index_base "$service")" || -e "$(index_base_meta "$service")" ||
       -e "$(index_bootstrap "$service")" || -e "$(index_bootstrap_meta "$service")" ]] &&
      ((count+=1))
    for vm in ubuntu umbrel startos; do
      index_supported_for_vm "$vm" "$service" || continue
      [[ -e "$(index_overlay "$vm" "$service")" ||
         -e "$(index_overlay_meta "$vm" "$service")" ]] && ((count+=1))
    done
  done
  printf '%s\n' "$count"
}

assert_no_dependent_overlays() {
  local count; count="$(dependent_overlay_count)"
  [[ "$count" == 0 ]] || die "canonical mutation is blocked by $count dependent overlay lifecycle(s)"
}

assert_only_dependent_overlay() {
  local allowed="$1" vm
  [[ ! -e "$STARTOS_LAYER" && ! -e "$STARTOS_LAYER_META" &&
     ! -e "$STARTOS_LAYER_CANDIDATE" && ! -e "$STARTOS_LAYER_CANDIDATE_META" &&
     ! -e "$STARTOS_LAYER_RECOVERY" ]] ||
    die "canonical mutation is blocked by the StartOS filesystem adapter"
  for vm in ubuntu umbrel startos; do
    [[ "$vm" == "$allowed" ]] && continue
    [[ ! -e "$(lifecycle_overlay "$vm")" && ! -e "$(lifecycle_meta "$vm")" ]] ||
      die "canonical mutation is blocked by the $vm dependent overlay"
  done
}

startos_adapter_preflight() {
  [[ -f "$STARTOS_LAYER" && -f "$STARTOS_LAYER_META" ]] ||
    die "StartOS Btrfs adapter is not ready; run startos-adapter-build"
  [[ "$(meta_get "$STARTOS_LAYER_META" state)" == ready &&
     "$(meta_get "$STARTOS_LAYER_META" filesystem)" == btrfs &&
     "$(meta_get "$STARTOS_LAYER_META" rollback_subvolume_removed)" == 1 ]] ||
    die "StartOS Btrfs adapter manifest is incomplete"
  [[ "$(meta_get "$STARTOS_LAYER_META" canonical_id)" == "$(canonical_id)" &&
     "$(meta_get "$STARTOS_LAYER_META" checkpoint_generation)" == "$(checkpoint_generation)" ]] ||
    die "StartOS Btrfs adapter belongs to another canonical generation"
  [[ -n "$(meta_get "$STARTOS_LAYER_META" id)" ]] ||
    die "StartOS Btrfs adapter lacks a generation ID"
  local info
  info="$(qemu-img info --output=json "$STARTOS_LAYER")"
  [[ "$(jq -r .format <<<"$info")" == qcow2 &&
     "$(jq -r '.["backing-filename"] // empty' <<<"$info")" == "$CANONICAL" ]] ||
    die "StartOS Btrfs adapter backing chain is invalid"
  qemu-img check "$STARTOS_LAYER" >/dev/null ||
    die "StartOS Btrfs adapter qemu-img check failed"
  [[ "$(stat -c %a "$STARTOS_LAYER")" == 440 ]] ||
    die "StartOS Btrfs adapter mode must be 0440"
  image_immutable "$STARTOS_LAYER" ||
    die "StartOS Btrfs adapter immutable protection is missing"
  qemu_can_read_image "$STARTOS_LAYER" ||
    die "system QEMU cannot read the StartOS Btrfs adapter"
  [[ -z "$(attached_vm_for_path "$STARTOS_LAYER")" ]] ||
    die "StartOS Btrfs adapter is attached directly to a VM"
}

image_immutable() {
  if [[ "${BVML_TESTING:-0}" == 1 ]]; then
    [[ ! -e "${TEST_ROOT:-/nonexistent}/immutable-missing" ]]
    return
  fi
  lsattr "$1" 2>/dev/null | awk '{print $1}' | grep -q i
}

protect_image() {
  local image="$1"
  [[ -f "$image" ]] || die "image to protect does not exist: $image"
  if [[ "${BVML_TESTING:-0}" != 1 ]]; then
    need sudo
    sudo chattr -i "$image" 2>/dev/null || true
    sudo chown "$USER:$QEMU_GROUP" "$image"
  fi
  chmod 0440 "$image"
  if [[ "${BVML_TESTING:-0}" != 1 ]]; then
    need chattr; need setfacl
    setfacl -m "u:$QEMU_USER:r--" "$image" || die "could not grant read-only QEMU access to $image"
    sudo -u "$QEMU_USER" test -r "$image" || die "system QEMU cannot read $image"
    sudo chattr +i "$image" || die "could not set immutable protection on $image"
    image_immutable "$image" || die "immutable protection verification failed for $image"
  fi
  [[ ! -w "$image" ]] || die "$image remains writable"
}

unprotect_image() {
  local image="$1"
  [[ -e "$image" ]] || return 0
  if [[ "${BVML_TESTING:-0}" != 1 ]]; then need sudo; sudo chattr -i "$image"; fi
  chmod u+w "$image"
}

require_canonical() {
  canonical_preflight
}

assert_no_process_reference() {
  local image="$1"
  [[ "${BVML_TESTING:-0}" == 1 ]] && return 0
  need lsof
  if lsof "$image" 2>/dev/null | grep -q .; then
    die "a process still has $image open"
  fi
}

process_references_path() {
  local image="$1"
  [[ -e "$image" && "${BVML_TESTING:-0}" != 1 ]] || return 1
  command -v lsof >/dev/null && lsof "$image" 2>/dev/null | grep -q .
}

invalidate_verification() {
  rm -f -- "$VERIFY_META" "$BOOTSTRAP_VERIFY"
}

validate_checkpoint_image() {
  local image="$1" xor_bytes
  qemu-img check "$image" >/dev/null || return 1
  qemu-img info --output=json "$image" | grep -q '"backing-filename"' && return 1
  virt-ls -a "$image" -m /dev/sda / | grep -qx blocks || return 1
  virt-ls -a "$image" -m /dev/sda / | grep -qx chainstate || return 1
  xor_bytes="$(virt-cat -a "$image" -m /dev/sda /blocks/xor.dat 2>/dev/null |
    od -An -v -tu1 | tr -s ' ' '\n' | sed '/^$/d' || true)"
  [[ -z "$xor_bytes" ]] || ! grep -qv '^0$' <<<"$xor_bytes"
}

checkpoint_profile_id() {
  jq -er '.id | select(type == "string" and length > 0)' "$CHECKPOINT_PROFILE_FILE"
}

checkpoint_profile_indexes_json() {
  jq -ec '.indexes | select(type == "array") | map(select(type == "string")) | unique | sort' \
    "$CHECKPOINT_PROFILE_FILE"
}

validate_checkpoint_profile() {
  [[ -f "$CHECKPOINT_PROFILE_FILE" ]] || die "checkpoint profile is missing: $CHECKPOINT_PROFILE_FILE"
  [[ "$CHECKPOINT_PROFILE_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] ||
    die "CHECKPOINT_PROFILE_SHA256 must be a SHA-256 digest"
  [[ "$(sha256sum "$CHECKPOINT_PROFILE_FILE" | awk '{print $1}')" == "${CHECKPOINT_PROFILE_SHA256,,}" ]] ||
    die "checkpoint profile digest mismatch"
  checkpoint_profile_id >/dev/null || die "checkpoint profile ID is invalid"
  checkpoint_profile_indexes_json >/dev/null || die "checkpoint profile indexes are invalid"
}

validate_profile_generation() {
  [[ "$KNOTS_RELEASE_PROFILE_SHA256" =~ ^[0-9a-fA-F]{64}$ &&
     "$KNOTS_RDTS_PROFILE_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] ||
    die "release and RDTS profile digests must be configured"
  [[ "$(sha256sum "$KNOTS_RELEASE_PROFILE" | awk '{print $1}')" == "${KNOTS_RELEASE_PROFILE_SHA256,,}" ]] ||
    die "Knots release profile digest mismatch"
  [[ "$(sha256sum "$KNOTS_RDTS_PROFILE" | awk '{print $1}')" == "${KNOTS_RDTS_PROFILE_SHA256,,}" ]] ||
    die "Knots RDTS profile digest mismatch"
  validate_checkpoint_profile
}

qemu_can_read_image() {
  local image="$1"
  if [[ "${BVML_TESTING:-0}" == 1 ]]; then
    [[ ! -e "${TEST_ROOT:-/nonexistent}/inaccessible-storage" ]]
    return
  fi
  sudo -u "$QEMU_USER" test -x "$BVML_STORAGE" &&
    sudo -u "$QEMU_USER" test -x "$(dirname "$image")" &&
    sudo -u "$QEMU_USER" test -r "$image"
}

quarantine_media() {
  local image="$1" rejected="${image}.rejected.$(date -u +%Y%m%dT%H%M%SZ)"
  chmod u+w "$image" 2>/dev/null || true
  mv -- "$image" "$rejected"
  echo "$rejected"
}

validate_cloud_image() {
  local image="$1" expected="$2" actual info reason=
  [[ -f "$image" ]] || die "cloud image is missing: $image"
  actual="$(sha256sum "$image" | awk '{print $1}')"
  [[ "$actual" == "${expected,,}" ]] || reason="pinned SHA-256 mismatch"
  if [[ -z "$reason" ]]; then
    info="$(qemu-img info --output=json "$image" 2>/dev/null)" || reason="qemu-img info failed"
  fi
  if [[ -z "$reason" ]]; then
    jq -e '.format == "qcow2" and ((.["backing-filename"] // "") == "")' \
      <<<"$info" >/dev/null || reason="image is not standalone qcow2"
  fi
  if [[ -z "$reason" ]]; then
    qemu-img check "$image" >/dev/null 2>&1 || reason="qemu-img check failed"
  fi
  if [[ -n "$reason" ]]; then
    local rejected; rejected="$(quarantine_media "$image")"
    die "$reason; quarantined staged image at $rejected"
  fi
  chmod 0444 "$image"
  [[ "$(stat -c %a "$image")" == 444 ]] || die "could not make staged image read-only"
}

canonical_preflight() {
  need jq
  [[ -f "$CANONICAL" && -f "$CANONICAL_META" ]] ||
    die "canonical checkpoint and manifest are required; run checkpoint-bootstrap"
  local id generation format backing profile_id
  id="$(canonical_id)"; generation="$(checkpoint_generation)"
  [[ -n "$id" ]] || die "canonical manifest lacks an ID"
  [[ -n "$generation" ]] || die "canonical manifest lacks a checkpoint generation"
  format="$(qemu-img info --output=json "$CANONICAL" | jq -er '.format')"
  backing="$(qemu-img info --output=json "$CANONICAL" | jq -r '.["backing-filename"] // empty')"
  [[ "$format" == qcow2 ]] || die "canonical image format is '$format', expected qcow2"
  [[ -z "$backing" ]] || die "canonical checkpoint is not standalone"
  qemu-img check "$CANONICAL" >/dev/null || die "canonical qemu-img check failed"
  validate_checkpoint_image "$CANONICAL" || die "canonical datadir layout or non-XOR validation failed"
  [[ "$(meta_get "$CANONICAL_META" network)" == main ]] || die "canonical network is not mainnet"
  [[ "$(meta_get "$CANONICAL_META" blocksxor)" == 0 ]] || die "canonical manifest is not non-XOR"
  [[ "$(meta_get "$CANONICAL_META" layout)" == root-datadir ]] || die "unsupported canonical datadir layout"
  validate_checkpoint_profile
  profile_id="$(checkpoint_profile_id)"
  [[ "$(meta_get "$CANONICAL_META" checkpoint_profile_id)" == "$profile_id" ]] ||
    die "canonical checkpoint profile does not match configured profile"
  [[ "$(meta_get "$CANONICAL_META" checkpoint_profile_sha256)" == "${CHECKPOINT_PROFILE_SHA256,,}" ]] ||
    die "canonical checkpoint profile digest does not match configured profile"
  validate_profile_generation
  [[ "$(meta_get "$CANONICAL_META" profile_generation_id)" == "$(profile_generation_id)" ]] ||
    die "canonical checkpoint belongs to another profile generation"
  if [[ -n "$(meta_get "$CANONICAL_META" profile_generation_digest)" ]]; then
    [[ "$(meta_get "$CANONICAL_META" profile_generation_digest)" == "$(active_profile_generation_digest)" ]] ||
      die "canonical profile generation digest does not match configured profiles"
  fi
  [[ "$(meta_get "$CANONICAL_META" release_profile_sha256)" == "${KNOTS_RELEASE_PROFILE_SHA256,,}" &&
     "$(meta_get "$CANONICAL_META" rdts_profile_sha256)" == "${KNOTS_RDTS_PROFILE_SHA256,,}" ]] ||
    die "canonical release/RDTS profile digests do not match configured profiles"
  [[ "$(stat -c %a "$CANONICAL")" == 440 ]] || die "canonical mode must be 0440"
  image_immutable "$CANONICAL" || die "canonical immutable protection is missing"
  qemu_can_read_image "$CANONICAL" || die "system QEMU cannot traverse/read the canonical image"
  [[ -z "$(attached_vm_for_path "$CANONICAL")" ]] || die "canonical checkpoint is attached directly to a VM"
}

assert_initialization_state_empty() {
  local requested="$1" path vm
  all_shut_off
  assert_no_bitcoin_attachments
  for path in "$CANONICAL" "$CANONICAL_META" "$BOOTSTRAP" "$BOOTSTRAP_META" \
    "$BOOTSTRAP_VERIFY" "$BOOTSTRAP_CANDIDATE" "$BOOTSTRAP_CANDIDATE_META" \
    "$IMPORT_CANDIDATE" "$IMPORT_META" "$RECOVERY_META"; do
    [[ ! -e "$path" ]] || die "$requested cannot begin while lifecycle state exists: $path"
  done
  for vm in ubuntu umbrel startos; do
    for path in "$(lifecycle_overlay "$vm")" "$(lifecycle_meta "$vm")" \
      "$(lifecycle_verify "$vm")" "$(lifecycle_owner "$vm")" "$(lifecycle_recovery "$vm")"; do
      [[ ! -e "$path" ]] || die "$requested cannot begin while lifecycle state exists: $path"
    done
  done
}

assert_provisioning_safe() {
  local vm state
  assert_no_bitcoin_lifecycle
  for vm in ubuntu umbrel startos; do
    is_defined "$vm" || continue
    state="$(domain_state "$vm")"
    [[ "$state" == "shut off" ]] ||
      die "provisioning is blocked while $(domain "$vm") is '$state'"
  done
}

assert_no_bitcoin_lifecycle() {
  local vm
  for vm in ubuntu umbrel startos; do
    [[ ! -e "$(lifecycle_owner "$vm")" ]] ||
      die "provisioning is blocked while lifecycle ownership exists for $vm"
  done
  [[ "$(bitcoin_attachment_count)" == 0 ]] ||
    die "provisioning is blocked while a Bitcoin data image is attached"
}

lifecycle_invariant_errors() {
  local owner kind image attached manifest_id owner_id manifest_vm manifest_serial
  local vm state src meta owner_file verify recovery overlay id other attachments
  local legacy service index_image index_meta index_attached index_owner_state
  legacy="$(legacy_lifecycle_paths)"
  [[ -z "$legacy" ]] ||
    echo "legacy singleton state awaits automatic per-VM migration"
  if { [[ -e "$CANONICAL" ]] && [[ ! -e "$CANONICAL_META" ]]; } ||
     { [[ ! -e "$CANONICAL" ]] && [[ -e "$CANONICAL_META" ]]; }; then echo "partial canonical image/manifest state"; fi
  if { [[ -e "$BOOTSTRAP" ]] && [[ ! -e "$BOOTSTRAP_META" ]]; } ||
     { [[ ! -e "$BOOTSTRAP" ]] && [[ -e "$BOOTSTRAP_META" ]]; }; then echo "partial bootstrap image/manifest state"; fi
  if { [[ -e "$IMPORT_CANDIDATE" ]] && [[ ! -e "$IMPORT_META" ]]; } ||
     { [[ ! -e "$IMPORT_CANDIDATE" ]] && [[ -e "$IMPORT_META" ]]; }; then echo "partial import candidate/manifest state"; fi
  if { [[ -e "$BOOTSTRAP_CANDIDATE" ]] && [[ ! -e "$BOOTSTRAP_CANDIDATE_META" ]]; } ||
     { [[ ! -e "$BOOTSTRAP_CANDIDATE" ]] && [[ -e "$BOOTSTRAP_CANDIDATE_META" ]]; }; then
    echo "partial bootstrap promotion candidate/manifest state"
  fi
  [[ ! -f "$CANONICAL" || ! -f "$BOOTSTRAP" ]] || echo "canonical checkpoint and bootstrap coexist"
  [[ ! -f "$IMPORT_CANDIDATE" || ! -f "$BOOTSTRAP" ]] || echo "import candidate and bootstrap coexist"
  [[ ! -f "$RECOVERY_META" ]] || echo "recovery metadata requires explicit review"
  [[ -z "$(attached_vm_for_path "$CANONICAL")" ]] || echo "canonical checkpoint is attached directly"
  [[ -z "$(attached_vm_for_path "$ROLLBACK")" ]] || echo "rollback checkpoint is attached directly"
  for vm in ubuntu umbrel startos; do
    attached=
    overlay="$(lifecycle_overlay "$vm")"; meta="$(lifecycle_meta "$vm")"
    owner_file="$(lifecycle_owner "$vm")"; verify="$(lifecycle_verify "$vm")"
    recovery="$(lifecycle_recovery "$vm")"
    if { [[ -e "$overlay" ]] && [[ ! -e "$meta" ]]; } ||
       { [[ ! -e "$overlay" ]] && [[ -e "$meta" ]]; }; then
      echo "$vm has partial overlay image/manifest state"
    fi
    [[ ! -f "$BOOTSTRAP" || ! -f "$overlay" ]] || echo "bootstrap and $vm overlay coexist"
    [[ ! -f "$recovery" ]] || echo "$vm recovery metadata requires explicit review"
    owner="$(owner_vm "$owner_file")"; kind="$(owner_kind "$owner_file")"
    image="$(owner_image "$owner_file")"
    if [[ -n "$owner" ]]; then
      owner_id="$(meta_get "$owner_file" identity)"
      case "$kind" in
        overlay)
          manifest_vm="$(overlay_vm "$meta")"; manifest_id="$(overlay_id "$meta")"
          manifest_serial="$(meta_get "$meta" disk_serial)"
          if ! [[ "$owner" == "$vm" && "$image" == "$overlay" &&
                  -f "$overlay" && -f "$meta" ]]; then
            echo "$vm overlay owner path or manifest disagrees"
          fi
          ;;
        bootstrap)
          manifest_vm="$(meta_get "$BOOTSTRAP_META" vm)"
          manifest_id="$(meta_get "$BOOTSTRAP_META" bootstrap_id)"
          manifest_serial="$(meta_get "$BOOTSTRAP_META" disk_serial)"
          if ! [[ "$vm" == ubuntu && "$owner" == ubuntu && "$image" == "$BOOTSTRAP" &&
                  -f "$BOOTSTRAP" && -f "$BOOTSTRAP_META" ]]; then
            echo "$vm bootstrap owner path or manifest disagrees"
          fi
          ;;
        *) echo "$vm owner kind is missing or unsupported"; manifest_vm= manifest_id= manifest_serial= ;;
      esac
      [[ "$manifest_vm" == "$owner" && -n "$owner_id" && "$manifest_id" == "$owner_id" ]] ||
        echo "$vm owner metadata disagrees with image manifest"
      [[ -n "$manifest_serial" && "$manifest_serial" == "$(meta_get "$owner_file" disk_serial)" ]] ||
        echo "$vm owner serial disagrees with image manifest"
      attached="$(attached_vm_for_path "$image" | paste -sd, -)"
      [[ "$attached" == "$vm" ]] ||
        echo "$vm owner attachment is '${attached:-none}'"
      [[ "$attached" != "$vm" ||
         "$(attachment_serial_for_path "$vm" "$image")" == "$(meta_get "$owner_file" disk_serial)" ]] ||
        echo "$vm owner serial disagrees with domain XML"
    fi
    attachments="$(all_attached_pairs | awk -F '\t' -v vm="$vm" '$1 == vm {n++} END {print n+0}')"
    [[ "$attachments" -le 1 ]] || echo "$vm has more than one Bitcoin storage attachment"
    while IFS=$'\t' read -r other src; do
      [[ "$other" != "$vm" ]] || {
        [[ -n "$owner" && "$owner" == "$vm" && "$image" == "$src" ]] ||
          echo "$vm attachment has no matching owner/image record"
      }
    done < <(all_attached_pairs)
    is_defined "$vm" || continue
    state="$(domain_state "$vm")"
    if [[ "$state" != "shut off" ]]; then
      [[ "$owner" == "$vm" && -n "$image" && "$attached" == "$vm" ]] ||
        echo "$(domain "$vm") is '$state' without matching Bitcoin owner state"
    fi
    if [[ -f "$verify" ]]; then
      [[ -f "$overlay" &&
         "$(meta_get "$verify" overlay_id)" == "$(overlay_id "$meta")" &&
         "$(meta_get "$verify" checkpoint_generation)" == "$(meta_get "$meta" checkpoint_generation)" ]] ||
        echo "$vm verification evidence belongs to another image or generation"
    fi
    id="$(overlay_id "$meta")"
    if [[ -n "$id" ]]; then
      for other in ubuntu umbrel startos; do
        [[ "$other" == "$vm" || "$(overlay_id "$(lifecycle_meta "$other")")" != "$id" ]] ||
          echo "$vm and $other have duplicate overlay IDs"
      done
    fi
  done
  if [[ -f "$BOOTSTRAP_VERIFY" ]]; then
    [[ -f "$BOOTSTRAP" &&
       "$(meta_get "$BOOTSTRAP_VERIFY" bootstrap_id)" == "$(meta_get "$BOOTSTRAP_META" bootstrap_id)" ]] ||
      echo "bootstrap verification evidence belongs to another image"
  fi
  for vm in ubuntu umbrel startos; do
    image="$(lifecycle_overlay "$vm")"
    if process_references_path "$image" && [[ -z "$(attached_vm_for_path "$image")" ]]; then
      echo "process references $vm overlay without libvirt attachment metadata"
    fi
  done
  for image in "$BOOTSTRAP" "$ROLLBACK"; do
    if process_references_path "$image" && [[ -z "$(attached_vm_for_path "$image")" ]]; then
      echo "process references $image without libvirt attachment metadata"
    fi
  done
  for service in electrs fulcrum; do
    index_image="$(index_base "$service")"; index_meta="$(index_base_meta "$service")"
    if { [[ -e "$index_image" ]] && [[ ! -e "$index_meta" ]]; } ||
       { [[ ! -e "$index_image" ]] && [[ -e "$index_meta" ]]; }; then
      echo "$service has partial protected base state"
    fi
    [[ -z "$(attached_vm_for_path "$index_image")" ]] ||
      echo "$service protected base is attached directly"
    index_image="$(index_bootstrap "$service")"; index_meta="$(index_bootstrap_meta "$service")"
    if { [[ -e "$index_image" ]] && [[ ! -e "$index_meta" ]]; } ||
       { [[ ! -e "$index_image" ]] && [[ -e "$index_meta" ]]; }; then
      echo "$service has partial bootstrap state"
    fi
    index_attached="$(attached_vm_for_path "$index_image" | paste -sd, -)"
    [[ -z "$index_attached" || "$index_attached" == ubuntu ]] ||
      echo "$service bootstrap is attached outside Ubuntu"
    if process_references_path "$index_image" && [[ -z "$index_attached" ]]; then
      echo "process references detached $service bootstrap"
    fi
    for vm in ubuntu umbrel startos; do
      index_supported_for_vm "$vm" "$service" || continue
      index_image="$(index_overlay "$vm" "$service")"
      index_meta="$(index_overlay_meta "$vm" "$service")"
      if { [[ -e "$index_image" ]] && [[ ! -e "$index_meta" ]]; } ||
         { [[ ! -e "$index_image" ]] && [[ -e "$index_meta" ]]; }; then
        echo "$vm has partial $service overlay state"
        continue
      fi
      [[ -f "$index_image" && -f "$index_meta" ]] || continue
      index_attached="$(attached_vm_for_path "$index_image" | paste -sd, -)"
      index_owner_state="$(meta_get "$index_meta" owner_state)"
      [[ -z "$index_attached" || "$index_attached" == "$vm" ]] ||
        echo "$vm $service overlay is attached to $index_attached"
      if [[ "$index_owner_state" == active ]]; then
        [[ "$index_attached" == "$vm" ]] ||
          echo "$vm $service active owner state lacks its attachment"
      elif [[ "$index_owner_state" == retained ]]; then
        [[ -z "$index_attached" ]] ||
          echo "$vm $service retained owner state remains attached"
      else
        echo "$vm $service owner state is missing or unsupported"
      fi
      if [[ "$index_attached" == "$vm" ]]; then
        [[ "$(target_for_source "$vm" "$index_image")" == "$(index_target "$service")" ]] ||
          echo "$vm $service overlay uses the wrong block target"
        [[ "$(attachment_serial_for_path "$vm" "$index_image")" == "$(meta_get "$index_meta" disk_serial)" ]] ||
          echo "$vm $service overlay serial disagrees with domain XML"
      fi
      if process_references_path "$index_image" && [[ -z "$index_attached" ]]; then
        echo "process references detached $vm $service overlay"
      fi
    done
  done
}

assert_lifecycle_invariants() {
  local errors
  errors="$(lifecycle_invariant_errors)"
  [[ -z "$errors" ]] || die "unsafe lifecycle state: ${errors//$'\n'/; }"
}

image_filesystem_uuid() {
  virt-filesystems -a "$1" --filesystems --uuid --long 2>/dev/null |
    awk '
      NR == 1 { for (i = 1; i <= NF; i++) if ($i == "UUID") uuid_column = i; next }
      uuid_column && $uuid_column != "" && $uuid_column != "-" { print $uuid_column; exit }
    '
}
