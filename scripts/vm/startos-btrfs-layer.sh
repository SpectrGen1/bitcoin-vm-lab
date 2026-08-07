#!/usr/bin/env bash
# Build and validate the immutable Btrfs filesystem adapter for StartOS.
set -Eeuo pipefail
source "$(cd "$(dirname "$0")/../.." && pwd)/lib/common.sh"

action="${1:-status}"; shift || true
serial=BVML-STARTOS-BTRFS
maintenance_script="$BVML_ROOT/scripts/vm/guest/startos-btrfs-maintenance.sh"

canonical_snapshot() {
  {
    stat -c 'size=%s blocks=%b mtime=%Y mode=%a uid=%u gid=%g' "$CANONICAL"
    lsattr "$CANONICAL"
    qemu-img info --output=json "$CANONICAL"
    sha256sum "$CANONICAL_META"
  } | sha256sum | awk '{print $1}'
}

wait_qga() {
  local waited=0
  while ! virshq qemu-agent-command "$(domain ubuntu)" \
    '{"execute":"guest-ping"}' >/dev/null 2>&1; do
    (( waited < GUEST_EXEC_TIMEOUT )) || die "Ubuntu maintenance QGA did not become ready"
    sleep 2
    waited=$((waited+2))
  done
}

shutdown_maintenance_guest() {
  local waited=0
  # A successful guest-shutdown normally disconnects QGA before libvirt can
  # return a reply, so command failure is not itself a shutdown failure.
  virshq qemu-agent-command "$(domain ubuntu)" \
    '{"execute":"guest-shutdown","arguments":{"mode":"powerdown"}}' \
    >/dev/null 2>&1 || true
  while ! is_shut_off ubuntu; do
    (( waited < SHUTDOWN_TIMEOUT )) ||
      die "Ubuntu maintenance guest did not reach exact shut off"
    sleep 2
    waited=$((waited+2))
  done
}

set_ubuntu_maintenance_mode() {
  is_shut_off ubuntu || die "Ubuntu must be shut off before changing maintenance boot mode"
  virt_customize_offline -a "$(vm_dir ubuntu)/system.qcow2" \
    --run-command 'rm -f /etc/systemd/system/multi-user.target.wants/bvml-knots.service' \
    --run-command 'install -d -m 0700 /etc/bvml && touch /etc/bvml/startos-btrfs-maintenance'
}

clear_ubuntu_maintenance_mode() {
  is_shut_off ubuntu || die "Ubuntu must be shut off before restoring normal boot mode"
  virt_customize_offline -a "$(vm_dir ubuntu)/system.qcow2" \
    --run-command 'ln -sfn /etc/systemd/system/bvml-knots.service /etc/systemd/system/multi-user.target.wants/bvml-knots.service' \
    --run-command 'rm -f /etc/bvml/startos-btrfs-maintenance'
}

maintenance_phase() {
  local phase="$1" image="$2" output="" started=0 attached=0 phase_status=0 waited virtual_size
  is_shut_off ubuntu || die "Ubuntu must be exactly shut off before StartOS adapter maintenance"
  virtual_size="$(qemu-img info --output=json "$image" | jq -r '.["virtual-size"]')"
  virshq attach-disk "$(domain ubuntu)" "$image" vdc --config \
    --driver qemu --subdriver qcow2 --targetbus virtio --serial "$serial"
  attached=1
  [[ "$(attached_vm_for_path "$image" | paste -sd, -)" == ubuntu ]] ||
    die "maintenance candidate attachment verification failed"
  virshq start "$(domain ubuntu)" >/dev/null
  started=1
  wait_qga
  guest_exec_sync ubuntu /bin/bash 600 -c '
    set -Eeuo pipefail
    test -e /etc/bvml/startos-btrfs-maintenance
    systemctl stop bvml-knots.service 2>/dev/null || true
    ! pgrep -x bitcoind
    mountpoint -q /srv/bitcoin && umount /srv/bitcoin || true
    command -v btrfs-convert >/dev/null ||
      { export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get install -y btrfs-progs e2fsprogs; }
  '
  script64="$(base64 -w0 "$maintenance_script")"
  guest_exec_sync ubuntu /bin/bash 60 -c "
    set -Eeuo pipefail
    printf %s '$script64' | base64 -d >/run/bvml-startos-btrfs-maintenance.sh
    chown root:root /run/bvml-startos-btrfs-maintenance.sh
    chmod 0700 /run/bvml-startos-btrfs-maintenance.sh
    bash -n /run/bvml-startos-btrfs-maintenance.sh
  "
  wait_qga
  sleep 5
  phase_status=1
  for attempt in 1 2 3; do
    set +e
    output="$(guest_exec_sync ubuntu /bin/bash \
      "$STARTOS_BTRFS_CONVERT_TIMEOUT" /run/bvml-startos-btrfs-maintenance.sh \
      "$phase" "$serial" \
      "$virtual_size" \
      "$(jq -c .indexes "$CHECKPOINT_PROFILE_FILE")" 2>&1)"
    phase_status=$?
    set -e
    (( phase_status == 0 )) && break
    grep -Fq 'guest-agent transport failed while submitting' <<<"$output" ||
      break
    (( attempt < 3 )) || break
    wait_qga
    sleep 5
  done
  if (( started )); then
    shutdown_maintenance_guest || phase_status=1
  fi
  if (( attached )) && is_shut_off ubuntu; then
    virshq detach-disk "$(domain ubuntu)" vdc --config || phase_status=1
    [[ -z "$(attached_vm_for_path "$image")" ]] || phase_status=1
  fi
  [[ -z "$output" ]] || printf '%s\n' "$output"
  (( phase_status == 0 )) || die "StartOS Btrfs maintenance phase '$phase' failed; candidate preserved"
}

validate_allocation() {
  local actual canonical_actual max_abs max_ratio
  actual="$(qemu-img info --output=json "$STARTOS_LAYER_CANDIDATE" | jq -r '.["actual-size"]')"
  canonical_actual="$(qemu-img info --output=json "$CANONICAL" | jq -r '.["actual-size"]')"
  max_abs=$((STARTOS_BTRFS_ADAPTER_MAX_GIB * 1073741824))
  max_ratio=$((canonical_actual * STARTOS_BTRFS_ADAPTER_MAX_PERCENT / 100))
  (( actual <= max_abs && actual <= max_ratio )) ||
    die "StartOS conversion allocated $actual bytes; exceeds metadata-layer limits ($max_abs bytes and ${STARTOS_BTRFS_ADAPTER_MAX_PERCENT}% of canonical)"
  meta_set "$STARTOS_LAYER_CANDIDATE_META" allocation_bytes "$actual"
  meta_set "$STARTOS_LAYER_CANDIDATE_META" allocation_limit_bytes "$max_abs"
}

finish_converted_layer() {
  local snapshot="$1" evidence filesystem_uuid
  maintenance_phase finalize "$STARTOS_LAYER_CANDIDATE"
  evidence="$(maintenance_phase inspect "$STARTOS_LAYER_CANDIDATE")"
  filesystem_uuid="$(sed -n 's/^filesystem_uuid=//p' <<<"$evidence" | tail -1)"
  [[ "$filesystem_uuid" =~ ^[0-9a-fA-F-]{16,}$ ]] ||
    die "final StartOS Btrfs UUID evidence is invalid"
  [[ "$(canonical_snapshot)" == "$snapshot" ]] ||
    die "canonical checkpoint fingerprint changed during StartOS conversion"

  exec 9>"$GLOBAL_LOCK_FILE"; flock -n 9 ||
    die "canonical state changed before adapter installation"
  canonical_preflight
  [[ "$(canonical_snapshot)" == "$snapshot" ]] ||
    die "canonical checkpoint fingerprint changed before adapter installation"
  mv -- "$STARTOS_LAYER_CANDIDATE" "$STARTOS_LAYER"
  mv -- "$STARTOS_LAYER_CANDIDATE_META" "$STARTOS_LAYER_META"
  meta_set "$STARTOS_LAYER_META" state ready
  meta_set "$STARTOS_LAYER_META" filesystem btrfs
  meta_set "$STARTOS_LAYER_META" filesystem_uuid "$filesystem_uuid"
  meta_set "$STARTOS_LAYER_META" rollback_subvolume_removed 1
  meta_set "$STARTOS_LAYER_META" checkpoint_profile_id "$(checkpoint_profile_id)"
  meta_set "$STARTOS_LAYER_META" checkpoint_profile_sha256 "${CHECKPOINT_PROFILE_SHA256,,}"
  meta_set "$STARTOS_LAYER_META" validated_at "$(date -u +%FT%TZ)"
  protect_image "$STARTOS_LAYER"
  startos_adapter_preflight
  rm -f -- "$STARTOS_LAYER_RECOVERY"
  clear_ubuntu_maintenance_mode
  sync -f "$STARTOS_LAYER_DIR"
  flock -u 9
  note "installed protected metadata-sized StartOS Btrfs adapter"
}

build_layer() {
  [[ "${1:-}" == --confirm-convert && $# == 1 ]] ||
    die "usage: bvml startos-adapter-build --confirm-convert"
  init_layout
  exec 8>"$STARTOS_LAYER_LOCK"; flock -n 8 ||
    die "StartOS filesystem adapter operation is already running"
  exec 9>"$GLOBAL_LOCK_FILE"; flock -n 9 ||
    die "canonical state is being changed"
  canonical_preflight
  all_shut_off
  assert_no_bitcoin_attachments
  [[ "$(dependent_overlay_count)" == 0 ]] ||
    die "all dependent overlays and partial adapter state must be absent"
  [[ ! -e "$STARTOS_LAYER" && ! -e "$STARTOS_LAYER_META" ]] ||
    die "StartOS Btrfs adapter already exists"
  snapshot="$(canonical_snapshot)"
  qemu-img create -f qcow2 -F qcow2 -b "$CANONICAL" "$STARTOS_LAYER_CANDIDATE"
  chmod 0640 "$STARTOS_LAYER_CANDIDATE"
  setfacl -m "u:$QEMU_USER:rw-" "$STARTOS_LAYER_CANDIDATE"
  write_env_file "$STARTOS_LAYER_CANDIDATE_META" \
    "state=converting" "id=$(new_id)" "canonical_id=$(canonical_id)" \
    "checkpoint_generation=$(checkpoint_generation)" "backing=$CANONICAL" \
    "canonical_snapshot=$snapshot" "created=$(date -u +%FT%TZ)"
  write_env_file "$STARTOS_LAYER_RECOVERY" "operation=convert" \
    "candidate=$STARTOS_LAYER_CANDIDATE" "recorded=$(date -u +%FT%TZ)"
  flock -u 9

  set_ubuntu_maintenance_mode
  maintenance_phase convert "$STARTOS_LAYER_CANDIDATE"
  qemu-img check "$STARTOS_LAYER_CANDIDATE" >/dev/null ||
    die "converted StartOS candidate failed qemu-img check"
  validate_allocation
  meta_set "$STARTOS_LAYER_CANDIDATE_META" state converted-validated
  finish_converted_layer "$snapshot"
}

resume_layer() {
  [[ "${1:-}" == --confirm-resume && $# == 1 ]] ||
    die "usage: bvml startos-adapter-resume --confirm-resume"
  init_layout
  exec 8>"$STARTOS_LAYER_LOCK"; flock -n 8 ||
    die "StartOS filesystem adapter operation is already running"
  [[ -f "$STARTOS_LAYER_CANDIDATE" && -f "$STARTOS_LAYER_CANDIDATE_META" &&
     -f "$STARTOS_LAYER_RECOVERY" ]] ||
    die "no complete StartOS conversion recovery state exists"
  [[ ! -e "$STARTOS_LAYER" && ! -e "$STARTOS_LAYER_META" ]] ||
    die "an installed StartOS adapter already exists"
  local candidate_state
  candidate_state="$(meta_get "$STARTOS_LAYER_CANDIDATE_META" state)"
  [[ "$candidate_state" == converting || "$candidate_state" == converted-validated ]] ||
    die "StartOS conversion candidate has an unsupported recovery state: $candidate_state"
  [[ "$(meta_get "$STARTOS_LAYER_CANDIDATE_META" backing)" == "$CANONICAL" &&
     "$(meta_get "$STARTOS_LAYER_CANDIDATE_META" canonical_id)" == "$(canonical_id)" &&
     "$(meta_get "$STARTOS_LAYER_CANDIDATE_META" checkpoint_generation)" == "$(checkpoint_generation)" ]] ||
    die "conversion candidate no longer matches the canonical checkpoint"
  snapshot="$(meta_get "$STARTOS_LAYER_CANDIDATE_META" canonical_snapshot)"
  [[ -n "$snapshot" && "$(canonical_snapshot)" == "$snapshot" ]] ||
    die "canonical checkpoint fingerprint changed since conversion began"

  if ! is_shut_off ubuntu; then
    [[ "$(domain_state ubuntu)" == running &&
       "$(attached_vm_for_path "$STARTOS_LAYER_CANDIDATE" | paste -sd, -)" == ubuntu ]] ||
      die "Ubuntu recovery state is not an exact running candidate attachment"
    wait_qga
    guest_exec_sync ubuntu /bin/bash 60 -c '
      set -Eeuo pipefail
      ! pgrep -x btrfs-convert
      ! pgrep -x e2fsck
      ! findmnt -rn -S /dev/vdc | grep -q .
      sync
    '
    shutdown_maintenance_guest
  fi
  if [[ -n "$(attached_vm_for_path "$STARTOS_LAYER_CANDIDATE")" ]]; then
    [[ "$(attached_vm_for_path "$STARTOS_LAYER_CANDIDATE" | paste -sd, -)" == ubuntu ]] ||
      die "conversion candidate is attached to an unexpected domain"
    virshq detach-disk "$(domain ubuntu)" vdc --config
    [[ -z "$(attached_vm_for_path "$STARTOS_LAYER_CANDIDATE")" ]] ||
      die "conversion candidate remains attached after recovery detach"
  fi
  qemu-img check "$STARTOS_LAYER_CANDIDATE" >/dev/null ||
    die "resumed StartOS candidate failed qemu-img check"
  validate_allocation
  # A host interruption can occur after the guest completed btrfs-convert but
  # before the host persisted converted-validated. The idempotent finalizer
  # below independently requires Btrfs, checks it read-only, and removes the
  # conversion rollback subvolume before installation.
  meta_set "$STARTOS_LAYER_CANDIDATE_META" state converted-validated
  finish_converted_layer "$snapshot"
}

cleanup_candidate() {
  [[ "${1:-}" == --confirm-remove-candidate && $# == 1 ]] ||
    die "usage: bvml startos-adapter-cleanup --confirm-remove-candidate"
  init_layout
  exec 8>"$STARTOS_LAYER_LOCK"; flock -n 8 ||
    die "StartOS filesystem adapter operation is already running"
  all_shut_off
  for image in "$STARTOS_LAYER_CANDIDATE" "$STARTOS_LAYER"; do
    [[ -z "$(attached_vm_for_path "$image")" ]] ||
      die "refusing cleanup while $image is attached"
    [[ ! -e "$image" ]] || assert_no_process_reference "$image"
  done
  [[ ! -e "$STARTOS_LAYER" && ! -e "$STARTOS_LAYER_META" ]] ||
    die "installed StartOS adapter is not a partial candidate"
  rm -f -- "$STARTOS_LAYER_CANDIDATE" "$STARTOS_LAYER_CANDIDATE_META" \
    "$STARTOS_LAYER_RECOVERY"
  clear_ubuntu_maintenance_mode
  note "removed the incomplete StartOS conversion candidate and restored Ubuntu boot"
}

remove_layer() {
  [[ "${1:-}" == --confirm-remove && $# == 1 ]] ||
    die "usage: bvml startos-adapter-remove --confirm-remove"
  init_layout
  exec 8>"$STARTOS_LAYER_LOCK"; flock -n 8 ||
    die "StartOS filesystem adapter operation is already running"
  exec 9>"$GLOBAL_LOCK_FILE"; flock -n 9 ||
    die "canonical state is being changed"
  all_shut_off
  assert_no_bitcoin_attachments
  local vm
  for vm in ubuntu umbrel startos; do
    set_lifecycle_context "$vm"
    [[ ! -e "$OVERLAY" && ! -e "$OVERLAY_META" && ! -e "$OWNER_FILE" ]] ||
      die "discard every per-VM overlay before removing the StartOS adapter"
  done
  [[ ! -e "$STARTOS_LAYER_CANDIDATE" && ! -e "$STARTOS_LAYER_RECOVERY" ]] ||
    die "resolve partial StartOS adapter recovery state first"
  startos_adapter_preflight
  assert_no_process_reference "$STARTOS_LAYER"
  unprotect_image "$STARTOS_LAYER"
  rm -f -- "$STARTOS_LAYER" "$STARTOS_LAYER_META"
  sync -f "$STARTOS_LAYER_DIR"
  canonical_preflight
  note "removed the obsolete StartOS Btrfs adapter; canonical remains protected"
}

case "$action" in
  build) build_layer "$@" ;;
  resume) resume_layer "$@" ;;
  cleanup) cleanup_candidate "$@" ;;
  remove) remove_layer "$@" ;;
  validate) canonical_preflight; startos_adapter_preflight; note "StartOS Btrfs adapter is valid" ;;
  status)
    if [[ -f "$STARTOS_LAYER" && -f "$STARTOS_LAYER_META" ]]; then
      printf 'startos-btrfs-adapter: state=%s id=%s filesystem=%s allocation=%s backing=%s\n' \
        "$(meta_get "$STARTOS_LAYER_META" state)" "$(meta_get "$STARTOS_LAYER_META" id)" \
        "$(meta_get "$STARTOS_LAYER_META" filesystem)" \
        "$(meta_get "$STARTOS_LAYER_META" allocation_bytes)" \
        "$(meta_get "$STARTOS_LAYER_META" backing)"
      qemu-img info --backing-chain "$STARTOS_LAYER"
    elif [[ -e "$STARTOS_LAYER_CANDIDATE" || -e "$STARTOS_LAYER_RECOVERY" ]]; then
      echo "startos-btrfs-adapter: incomplete conversion; inspect recovery state"
      exit 1
    else
      echo "startos-btrfs-adapter: absent"
    fi
    ;;
  *) die "usage: $0 {build --confirm-convert|resume --confirm-resume|cleanup --confirm-remove-candidate|remove --confirm-remove|validate|status}" ;;
esac
