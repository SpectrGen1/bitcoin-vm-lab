#!/usr/bin/env bash
set -Eeuo pipefail

BVML_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BVML_ROOT/config/defaults.env"
if [[ "${BVML_TESTING:-0}" != 1 && -f "$BVML_ROOT/config/local.env" ]]; then
  source "$BVML_ROOT/config/local.env"
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
OVERLAY="$ACTIVE_DIR/bitcoin-mainnet-overlay.qcow2"
OVERLAY_META="$ACTIVE_DIR/manifest.env"
VERIFY_META="$ACTIVE_DIR/ubuntu-verification.env"
BOOTSTRAP="$ACTIVE_DIR/bitcoin-mainnet-bootstrap.qcow2"
BOOTSTRAP_META="$ACTIVE_DIR/bootstrap-manifest.env"
BOOTSTRAP_VERIFY="$ACTIVE_DIR/bootstrap-verification.env"
IMPORT_CANDIDATE="$CANONICAL_DIR/import-candidate.qcow2"
IMPORT_META="$CANONICAL_DIR/import-candidate-manifest.env"
BOOTSTRAP_CANDIDATE="$CANONICAL_DIR/bootstrap-promotion-candidate.qcow2"
BOOTSTRAP_CANDIDATE_META="$CANONICAL_DIR/bootstrap-promotion-manifest.env"
RUN_DIR="$BVML_STORAGE/run"
OWNER_FILE="$RUN_DIR/owner.env"
LOCK_FILE="$RUN_DIR/storage.lock"
RECOVERY_META="$RUN_DIR/recovery.env"
ADAPTER_STATE_DIR="$RUN_DIR/adapters"

die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*"; }
need() { command -v "$1" >/dev/null || die "missing command: $1"; }
domain() { printf 'bvml-%s' "$1"; }
valid_vm() { [[ "${1:-}" =~ ^(ubuntu|umbrel|startos)$ ]] || die "VM must be ubuntu, umbrel, or startos"; }
vm_dir() { printf '%s/vms/%s' "$BVML_STORAGE" "$1"; }
virshq() { virsh -c "$LIBVIRT_URI" "$@"; }
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
is_defined() { virshq dominfo "$(domain "$1")" >/dev/null 2>&1; }
domain_state() { virshq domstate "$(domain "$1")" 2>/dev/null | sed -n '1{s/[[:space:]]*$//;p;}'; }
is_shut_off() { [[ "$(domain_state "$1")" == "shut off" ]]; }
meta_get() {
  local file="$1" key="$2"
  [[ -f "$file" ]] && sed -n "s/^${key}=//p" "$file" | head -1
  return 0
}
overlay_vm() { meta_get "$OVERLAY_META" vm; }
owner_vm() { meta_get "$OWNER_FILE" vm; }
owner_kind() { meta_get "$OWNER_FILE" kind; }
owner_image() { meta_get "$OWNER_FILE" image; }
canonical_id() { meta_get "$CANONICAL_META" id; }
overlay_id() { meta_get "$OVERLAY_META" overlay_id; }
checkpoint_generation() { meta_get "$CANONICAL_META" generation; }
new_id() {
  if command -v uuidgen >/dev/null; then uuidgen
  else printf '%s-%s-%s\n' "$(date +%s%N)" "$$" "$RANDOM" | sha256sum | cut -d' ' -f1
  fi
}

validate_host_config_values() {
  local name value
  for name in BVML_STORAGE CHECKPOINT_PROFILE_FILE; do
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
     "$MAX_TIP_AGE_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
    die "timeout and chain-tip-age settings must be positive integers"
}
validate_host_config_values

init_layout() {
  if [[ "${BVML_TESTING:-0}" == 1 ]]; then
    install -d -m 0750 "$BVML_STORAGE" "$CANONICAL_DIR" "$ACTIVE_DIR" "$RUN_DIR" "$ADAPTER_STATE_DIR" "$BVML_STORAGE/vms"
  else
    need sudo
    sudo install -d -o "$USER" -g "$QEMU_GROUP" -m 0750 \
      "$BVML_STORAGE" "$CANONICAL_DIR" "$ACTIVE_DIR" "$RUN_DIR" "$ADAPTER_STATE_DIR" "$BVML_STORAGE/vms"
  fi
  touch "$LOCK_FILE"; chmod 0640 "$LOCK_FILE"
  if [[ "${BVML_TESTING:-0}" != 1 ]] && command -v setfacl >/dev/null; then
    setfacl -m "u:$QEMU_USER:--x" "$BVML_STORAGE" "$CANONICAL_DIR" "$ACTIVE_DIR" "$BVML_STORAGE/vms"
  fi
}

with_lock() {
  init_layout
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "another bitcoin-vm-lab storage operation is running"
  "$@"
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

attached_vm_for_path() {
  local wanted="$1" vm src
  for vm in ubuntu umbrel startos; do
    is_defined "$vm" || continue
    while IFS= read -r src; do [[ "$src" == "$wanted" ]] && printf '%s\n' "$vm"; done < <(disk_sources "$vm")
  done
}

attachment_serial_for_path() {
  local vm="$1" image="$2"
  if [[ "${BVML_TESTING:-0}" == 1 ]]; then
    if [[ "$image" == "$OVERLAY" ]]; then meta_get "$OVERLAY_META" disk_serial
    elif [[ "$image" == "$BOOTSTRAP" ]]; then meta_get "$BOOTSTRAP_META" disk_serial
    fi
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
          "$OVERLAY"|"$BOOTSTRAP"|"$CANONICAL"|"$ROLLBACK"|"$IMPORT_CANDIDATE"|"$BOOTSTRAP_CANDIDATE")
          printf '%s\t%s\n' "$vm" "$src"
          ;;
        esac
      fi
    done < <(disk_target_sources "$vm")
  done
}

bitcoin_attachment_count() {
  all_attached_pairs | awk 'END {print NR+0}'
}

assert_no_bitcoin_attachments() {
  local count; count="$(bitcoin_attachment_count)"
  [[ "$count" == 0 ]] || die "$count VM Bitcoin-disk attachment(s) remain"
}

assert_no_extra_overlays() {
  local extra
  extra="$(find "$ACTIVE_DIR" -maxdepth 1 -type f -name '*.qcow2' ! -path "$OVERLAY" ! -path "$BOOTSTRAP" -print -quit 2>/dev/null)"
  [[ -z "$extra" ]] || die "unexpected extra overlay exists: $extra"
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
  [[ "$(stat -c %a "$CANONICAL")" == 440 ]] || die "canonical mode must be 0440"
  image_immutable "$CANONICAL" || die "canonical immutable protection is missing"
  qemu_can_read_image "$CANONICAL" || die "system QEMU cannot traverse/read the canonical image"
  assert_no_process_reference "$CANONICAL"
  [[ -z "$(attached_vm_for_path "$CANONICAL")" ]] || die "canonical checkpoint is attached directly to a VM"
}

assert_initialization_state_empty() {
  local requested="$1" path
  all_shut_off
  assert_no_bitcoin_attachments
  for path in "$CANONICAL" "$CANONICAL_META" "$BOOTSTRAP" "$BOOTSTRAP_META" \
    "$BOOTSTRAP_VERIFY" "$BOOTSTRAP_CANDIDATE" "$BOOTSTRAP_CANDIDATE_META" \
    "$IMPORT_CANDIDATE" "$IMPORT_META" "$OVERLAY" "$OVERLAY_META" "$VERIFY_META" \
    "$OWNER_FILE" "$RECOVERY_META"; do
    [[ ! -e "$path" ]] || die "$requested cannot begin while lifecycle state exists: $path"
  done
}

lifecycle_invariant_errors() {
  local count owner kind image attached manifest_id owner_id manifest_vm manifest_serial vm state src
  if { [[ -e "$CANONICAL" ]] && [[ ! -e "$CANONICAL_META" ]]; } ||
     { [[ ! -e "$CANONICAL" ]] && [[ -e "$CANONICAL_META" ]]; }; then echo "partial canonical image/manifest state"; fi
  if { [[ -e "$OVERLAY" ]] && [[ ! -e "$OVERLAY_META" ]]; } ||
     { [[ ! -e "$OVERLAY" ]] && [[ -e "$OVERLAY_META" ]]; }; then echo "partial ordinary overlay image/manifest state"; fi
  if { [[ -e "$BOOTSTRAP" ]] && [[ ! -e "$BOOTSTRAP_META" ]]; } ||
     { [[ ! -e "$BOOTSTRAP" ]] && [[ -e "$BOOTSTRAP_META" ]]; }; then echo "partial bootstrap image/manifest state"; fi
  if { [[ -e "$IMPORT_CANDIDATE" ]] && [[ ! -e "$IMPORT_META" ]]; } ||
     { [[ ! -e "$IMPORT_CANDIDATE" ]] && [[ -e "$IMPORT_META" ]]; }; then echo "partial import candidate/manifest state"; fi
  if { [[ -e "$BOOTSTRAP_CANDIDATE" ]] && [[ ! -e "$BOOTSTRAP_CANDIDATE_META" ]]; } ||
     { [[ ! -e "$BOOTSTRAP_CANDIDATE" ]] && [[ -e "$BOOTSTRAP_CANDIDATE_META" ]]; }; then
    echo "partial bootstrap promotion candidate/manifest state"
  fi
  [[ ! -f "$CANONICAL" || ! -f "$BOOTSTRAP" ]] || echo "canonical checkpoint and bootstrap coexist"
  [[ ! -f "$OVERLAY" || ! -f "$BOOTSTRAP" ]] || echo "bootstrap and ordinary overlay coexist"
  [[ ! -f "$IMPORT_CANDIDATE" || ! -f "$BOOTSTRAP" ]] || echo "import candidate and bootstrap coexist"
  [[ ! -f "$RECOVERY_META" ]] || echo "recovery metadata requires explicit review"
  count="$(bitcoin_attachment_count)"
  [[ "$count" -le 1 ]] || echo "more than one Bitcoin storage attachment exists"
  [[ -z "$(attached_vm_for_path "$CANONICAL")" ]] || echo "canonical checkpoint is attached directly"
  [[ -z "$(attached_vm_for_path "$ROLLBACK")" ]] || echo "rollback checkpoint is attached directly"
  owner="$(owner_vm)"; kind="$(owner_kind)"; image="$(owner_image)"
  if [[ -n "$owner" ]]; then
    owner_id="$(meta_get "$OWNER_FILE" identity)"
    manifest_serial=
    case "$kind" in
      overlay)
        manifest_vm="$(overlay_vm)"; manifest_id="$(overlay_id)"
        manifest_serial="$(meta_get "$OVERLAY_META" disk_serial)"
        [[ "$image" == "$OVERLAY" && -f "$OVERLAY" && -f "$OVERLAY_META" ]] ||
          echo "overlay owner path or manifest disagrees"
        ;;
      bootstrap)
        manifest_vm="$(meta_get "$BOOTSTRAP_META" vm)"
        manifest_id="$(meta_get "$BOOTSTRAP_META" bootstrap_id)"
        manifest_serial="$(meta_get "$BOOTSTRAP_META" disk_serial)"
        [[ "$image" == "$BOOTSTRAP" && -f "$BOOTSTRAP" && -f "$BOOTSTRAP_META" ]] ||
          echo "bootstrap owner path or manifest disagrees"
        ;;
      *) echo "owner kind is missing or unsupported"; manifest_vm= manifest_id= ;;
    esac
    [[ "$manifest_vm" == "$owner" && -n "$owner_id" && "$manifest_id" == "$owner_id" ]] ||
      echo "owner metadata disagrees with image manifest"
    [[ -n "$manifest_serial" && "$manifest_serial" == "$(meta_get "$OWNER_FILE" disk_serial)" ]] ||
      echo "owner disk serial disagrees with image manifest"
    attached="$(attached_vm_for_path "$image" | paste -sd, -)"
    [[ "$attached" == "$owner" ]] || echo "owner says $owner but image attachment is '${attached:-none}'"
    if [[ "$attached" == "$owner" ]]; then
      [[ -n "$(meta_get "$OWNER_FILE" disk_serial)" &&
         "$(attachment_serial_for_path "$owner" "$image")" == "$(meta_get "$OWNER_FILE" disk_serial)" ]] ||
        echo "owner disk serial disagrees with libvirt domain XML"
    fi
  elif [[ "$count" != 0 ]]; then
    echo "Bitcoin storage is attached without owner metadata"
  fi
  while IFS=$'\t' read -r vm src; do
    [[ -n "$vm" ]] || continue
    [[ "$owner" == "$vm" && "$image" == "$src" ]] ||
      echo "$vm attachment has no matching owner/image record"
  done < <(all_attached_pairs)
  for vm in ubuntu umbrel startos; do
    is_defined "$vm" || continue
    state="$(domain_state "$vm")"
    if [[ "$state" != "shut off" ]]; then
      [[ "$owner" == "$vm" && -n "$image" ]] ||
        echo "$(domain "$vm") is '$state' without matching Bitcoin owner state"
    fi
  done
  if [[ -f "$VERIFY_META" ]]; then
    [[ -f "$OVERLAY" &&
       "$(meta_get "$VERIFY_META" overlay_id)" == "$(overlay_id)" &&
       "$(meta_get "$VERIFY_META" checkpoint_generation)" == "$(meta_get "$OVERLAY_META" checkpoint_generation)" ]] ||
      echo "ordinary verification evidence belongs to another image or generation"
  fi
  if [[ -f "$BOOTSTRAP_VERIFY" ]]; then
    [[ -f "$BOOTSTRAP" &&
       "$(meta_get "$BOOTSTRAP_VERIFY" bootstrap_id)" == "$(meta_get "$BOOTSTRAP_META" bootstrap_id)" ]] ||
      echo "bootstrap verification evidence belongs to another image"
  fi
  for image in "$OVERLAY" "$BOOTSTRAP" "$CANONICAL" "$ROLLBACK"; do
    if process_references_path "$image" && [[ -z "$(attached_vm_for_path "$image")" ]]; then
      if [[ "$image" == "$CANONICAL" && "$(owner_kind)" == overlay &&
         -n "$(attached_vm_for_path "$OVERLAY")" ]]; then
        : # Expected read-only backing-file reference from the attached overlay.
      else
        echo "process references $image without libvirt attachment metadata"
      fi
    fi
  done
}

assert_lifecycle_invariants() {
  local errors
  errors="$(lifecycle_invariant_errors)"
  [[ -z "$errors" ]] || die "unsafe lifecycle state: ${errors//$'\n'/; }"
}

image_filesystem_uuid() {
  virt-filesystems -a "$1" --filesystems --uuid 2>/dev/null |
    awk 'NR > 1 && $2 != "" {print $2; exit}'
}
