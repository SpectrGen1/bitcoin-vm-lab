#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/lib/common.sh"
command="${1:?command required}"; shift

source "$ROOT/lib/index-lifecycle.sh"

detach_image() {
  local vm="$1" image="$2" target
  target="$(target_for_source "$vm" "$image")"
  [[ -z "$target" ]] || virshq detach-disk "$(domain "$vm")" "$target" --config
}

write_owner_record() {
  local kind="$1" vm="$2" image="$3" identity="$4" serial="$5"
  [[ "${BVML_FAIL_OWNER_WRITE:-0}" != 1 ]] || return 1
  write_env_file "$OWNER_FILE" "kind=$kind" "vm=$vm" "domain=$(domain "$vm")" \
    "image=$image" "overlay=$image" "identity=$identity" "attached_target=vdc" \
    "disk_serial=$serial" "started=$(date -u +%FT%TZ)"
  if [[ "$kind" == overlay ]]; then printf 'overlay_id=%s\n' "$identity" >>"$OWNER_FILE"; fi
  if [[ "$kind" == bootstrap ]]; then printf 'bootstrap_id=%s\n' "$identity" >>"$OWNER_FILE"; fi
  return 0
}

assert_consistent_owner() {
  assert_lifecycle_invariants
}

transactional_attach_start() {
  local kind="$1" vm="$2" image meta identity serial nonce size_bytes backing
  case "$kind" in
    overlay)
      image="$OVERLAY"; meta="$OVERLAY_META"; identity="$(new_id)"
      serial="BVMLO-${identity:0:12}"
      backing="$(backing_image_for_vm "$vm")"
      qemu-img create -f qcow2 -F qcow2 -b "$backing" "$image" ||
        die "overlay creation failed"
      write_env_file "$meta" \
        "kind=overlay" "vm=$vm" "canonical_id=$(canonical_id)" "created=$(date -u +%FT%TZ)" \
        "backing=$backing" "overlay_id=$identity" "checkpoint_generation=$(checkpoint_generation)" \
        "size_bytes=$(qemu-img info --output=json "$backing" | jq -r '.["virtual-size"]')" \
        "disk_serial=$serial" "owner_state=creating" "attachment_state=detached" \
        "mount_state=unmounted" "adapter_state=pending" "recovery_required=0"
      if [[ "$vm" == startos ]]; then
        meta_set "$meta" startos_adapter_id "$(meta_get "$STARTOS_LAYER_META" id)"
      fi
      ;;
    bootstrap)
      image="$BOOTSTRAP"; meta="$BOOTSTRAP_META"; identity="$(new_id)"
      serial="BVMLB-${identity:0:12}"; nonce="$(new_id)"
      size_bytes=$((BOOTSTRAP_SIZE_GIB * 1073741824))
      qemu-img create -f qcow2 "$image" "${BOOTSTRAP_SIZE_GIB}G" ||
        die "bootstrap image creation failed"
      write_env_file "$meta" "kind=bootstrap" "bootstrap_id=$identity" \
        "vm=$vm" "created=$(date -u +%FT%TZ)" "size_gib=$BOOTSTRAP_SIZE_GIB" \
        "size_bytes=$size_bytes" "disk_serial=$serial" "bootstrap_nonce=$nonce" \
        "profile_generation_id=$(profile_generation_id)" \
        "profile_generation_digest=$(active_profile_generation_digest)" \
        "filesystem_initialized=0" "state=created"
      ;;
    *) die "unsupported transactional image kind: $kind" ;;
  esac
  chmod 0640 "$image"
  if [[ "${BVML_TESTING:-0}" != 1 ]]; then
    setfacl -m "u:$QEMU_USER:rw-" "$image" ||
      { rm -f -- "$image" "$meta"; die "could not grant QEMU image access"; }
  fi
  invalidate_verification
  if ! virshq attach-disk "$(domain "$vm")" "$image" vdc --config \
      --driver qemu --subdriver qcow2 --targetbus virtio --serial "$serial"; then
    rm -f -- "$image" "$meta"
    die "$kind attachment failed; image and manifest rolled back"
  fi
  meta_set "$meta" attachment_state attached
  if [[ "$(attached_vm_for_path "$image" | paste -sd, -)" != "$vm" ||
        "$(attachment_serial_for_path "$vm" "$image")" != "$serial" ]]; then
    if detach_image "$vm" "$image" && [[ -z "$(attached_vm_for_path "$image")" ]]; then
      assert_no_process_reference "$image"
      rm -f -- "$image" "$meta"
      die "$kind attachment identity verification failed; attachment and files rolled back"
    fi
    write_owner_record "$kind" "$vm" "$image" "$identity" "$serial" ||
      write_env_file "$RECOVERY_META" "operation=attachment-verification" "kind=$kind" \
        "vm=$vm" "image=$image" "identity=$identity" "disk_serial=$serial"
    die "$kind attachment identity verification failed and detach failed; recoverable state was retained"
  fi
  if [[ "$kind" == overlay ]] && ! attach_retained_indexes "$vm"; then
    rollback_index_attachments "$vm"
    detach_image "$vm" "$image" || true
    [[ -z "$(attached_vm_for_path "$image")" ]] ||
      die "$kind index attachment failed and Bitcoin detach failed; state retained"
    assert_no_process_reference "$image"
    rm -f -- "$image" "$meta"
    die "$kind index attachment failed; all attachments and new Bitcoin state rolled back"
  fi
  if ! write_owner_record "$kind" "$vm" "$image" "$identity" "$serial"; then
    local original="$kind owner metadata write failed"
    [[ "$kind" != overlay ]] || rollback_index_attachments "$vm"
    detach_image "$vm" "$image" ||
      die "$original; detach also failed, so image and manifest were retained"
    [[ -z "$(attached_vm_for_path "$image")" ]] ||
      die "$original; domain XML still references the image, so it was retained"
    assert_no_process_reference "$image"
    rm -f -- "$image" "$meta"
    die "$original; attachment, image, and manifest rolled back"
  fi
  meta_set "$meta" owner_state active
  if ! virshq start "$(domain "$vm")"; then
    if is_shut_off "$vm"; then
      rollback_index_attachments "$vm"
      detach_image "$vm" "$image" || die "VM start failed and detach failed; state retained"
      [[ -z "$(attached_vm_for_path "$image")" ]] ||
        die "VM start failed and domain XML still references image; state retained"
      assert_no_process_reference "$image"
      rm -f -- "$image" "$meta" "$OWNER_FILE" "$VERIFY_META" "$BOOTSTRAP_VERIFY"
      die "VM start failed; attachment, image, manifest, and owner were rolled back"
    fi
    die "VM start returned failure but domain is active; state retained for safe recovery"
  fi
}

start_vm() {
  local vm="$1" mode="${2:-}"
  set_lifecycle_context "$vm"
  valid_vm "$vm"; need qemu-img; need virsh
  [[ -z "$mode" || "$mode" == --adapter-setup ]] || die "unsupported start option: $mode"
  if [[ "$vm" != ubuntu ]]; then
    if [[ "$mode" == --adapter-setup ]]; then
      note "$vm is entering explicit unverified adapter-setup mode"
    else
      jq -e --arg platform "$vm" --arg umbrel_profile "${UMBREL_PROFILE_SHA256,,}" \
        --arg startos_profile "${STARTOS_PROFILE_SHA256,,}" '
        .platform == $platform and
        (.last_validation_result == "ok" or
          ($platform == "umbrel" and .provisioning_result == "ok" and
           .profile_digest == $umbrel_profile) or
          ($platform == "startos" and .provisioning_result == "ok" and
           .profile_digest == $startos_profile))
      ' \
        "$ADAPTER_STATE_DIR/$vm.json" >/dev/null 2>&1 ||
        die "$vm adapter is not provisioned; run guest-provision or use explicit adapter-setup recovery mode"
    fi
  elif [[ -n "$mode" ]]; then
    die "--adapter-setup is only valid for UmbrelOS or StartOS"
  fi
  exec 7>"$GLOBAL_LOCK_FILE"
  flock -n 7 || die "canonical state is being changed; retry $vm start"
  canonical_preflight; is_defined "$vm" || die "VM is not defined: $vm"
  [[ "$vm" != startos ]] || startos_adapter_preflight
  is_shut_off "$vm" || die "$(domain "$vm") is $(domain_state "$vm"); exact 'shut off' required"
  [[ -e "$OVERLAY" || -e "$OVERLAY_META" ]] || rm -f -- "$VERIFY_META"
  [[ ! -e "$OVERLAY" && ! -e "$OVERLAY_META" && ! -e "$OWNER_FILE" &&
     ! -e "$ADAPTER_RECOVERY_META" ]] ||
    die "$vm Bitcoin lifecycle state is retained; discard or reconcile it first"
  [[ ! -e "$BOOTSTRAP" && ! -e "$BOOTSTRAP_META" ]] ||
    die "fresh checkpoint bootstrap state blocks ordinary consumer startup"
  [[ "$(all_attached_pairs | awk -F '\t' -v vm="$vm" '$1 == vm {n++} END {print n+0}')" == 0 ]] ||
    die "$vm already has a Bitcoin storage attachment"
  assert_no_extra_overlays
  prepare_missing_index_overlays "$vm"
  transactional_attach_start overlay "$vm"
  flock -u 7
  note "$vm started with its disposable overlay"
}

resume_vm() {
  local vm="$1" mode="${2:-}"
  valid_vm "$vm"; set_lifecycle_context "$vm"
  [[ -z "$mode" || "$mode" == --adapter-setup ]] ||
    die "unsupported resume option: $mode"
  canonical_preflight
  [[ -f "$OVERLAY" && -f "$OVERLAY_META" && ! -e "$OWNER_FILE" ]] ||
    die "$vm requires one detached retained Bitcoin overlay and no owner record"
  is_defined "$vm" && is_shut_off "$vm" ||
    die "$vm must be defined and exactly shut off"
  assert_overlay_chain
  [[ -z "$(attached_vm_for_path "$OVERLAY")" ]] ||
    die "$vm Bitcoin overlay is already attached"
  prepare_missing_index_overlays "$vm"
  local serial id
  serial="$(meta_get "$OVERLAY_META" disk_serial)"; id="$(overlay_id)"
  if ! virshq attach-disk "$(domain "$vm")" "$OVERLAY" vdc --config \
      --driver qemu --subdriver qcow2 --targetbus virtio --serial "$serial"; then
    die "$vm retained Bitcoin overlay attachment failed"
  fi
  if ! attach_retained_indexes "$vm"; then
    rollback_index_attachments "$vm"
    detach_image "$vm" "$OVERLAY" || true
    die "$vm retained index attachment failed; attachments were rolled back"
  fi
  if ! write_owner_record overlay "$vm" "$OVERLAY" "$id" "$serial"; then
    rollback_index_attachments "$vm"
    detach_image "$vm" "$OVERLAY" || true
    die "$vm retained owner write failed; attachments were rolled back"
  fi
  meta_set "$OVERLAY_META" owner_state active
  meta_set "$OVERLAY_META" attachment_state attached
  if ! virshq start "$(domain "$vm")"; then
    if is_shut_off "$vm"; then
      rollback_index_attachments "$vm"
      detach_image "$vm" "$OVERLAY" || true
      rm -f -- "$OWNER_FILE"
      meta_set "$OVERLAY_META" owner_state retained
      meta_set "$OVERLAY_META" attachment_state detached
    fi
    die "$vm failed to resume; retained images were preserved"
  fi
  note "$vm resumed with its retained Bitcoin and index overlays"
}

guest_application_stop() {
  local vm="$1" script
  case "$vm" in
    ubuntu)
      guest_exec_sync ubuntu /bin/bash "$GUEST_EXEC_TIMEOUT" -c '
        set -Eeuo pipefail
        index=/usr/local/libexec/bvml/ubuntu-indexers.sh
        if [[ -x "$index" ]]; then
          "$index" stop electrs
          "$index" stop fulcrum
        fi
        knots=/usr/local/libexec/bvml/ubuntu-knots-rdts.sh
        if [[ -x "$knots" ]]; then exec "$knots" stop; fi
        echo "application already stopped: Knots lifecycle script is absent"
      '
      return
      ;;
    umbrel) script="$(jq -r .os.data_directory "$UMBREL_PROFILE")/.bvml/bin/umbrel-adapter.sh" ;;
    startos) script="$(jq -r .os.management_root "$STARTOS_PROFILE")/bin/startos-adapter.sh" ;;
  esac
  if [[ "$vm" == umbrel ]]; then
    local guest_bvml index_script
    guest_bvml="$(jq -r .os.data_directory "$UMBREL_PROFILE")/.bvml"
    index_script="$guest_bvml/bin/umbrel-indexers.sh"
    umbrel_exec_sync /bin/bash "$GUEST_EXEC_TIMEOUT" -c '
      set -Eeuo pipefail
      index="$1"; bitcoin="$2"
      if [[ -x "$index" ]]; then "$index" stop; fi
      if [[ -x "$bitcoin" ]]; then exec "$bitcoin" stop; fi
      echo "applications already stopped: adapters are absent"
    ' bash "$index_script" "$script"
    return
  fi
  if [[ "$vm" == startos ]]; then
    local startos_root
    startos_root="$(jq -r .os.management_root "$STARTOS_PROFILE")"
    startos_exec_sync /bin/bash "$GUEST_EXEC_TIMEOUT" -c '
        set -Eeuo pipefail
        script="$1"; fulcrum="$2"; electrs="$3"
        # Stop index packages before bitcoind so volume unmounts stay clean.
        if [[ -x "$fulcrum" ]]; then "$fulcrum" stop; fi
        if [[ -x "$electrs" ]]; then "$electrs" stop; fi
        if [[ -x "$script" ]]; then
          exec "$script" stop
        fi
        status="$(start-cli package list --format json |
          jq -er ".[] | select(.id==\"bitcoind\") | .status")"
        case "$status" in
          installed|stopped) ;;
          *) start-cli package stop bitcoind ;;
        esac
        for _ in $(seq 1 180); do
          status="$(start-cli package list --format json |
            jq -er ".[] | select(.id==\"bitcoind\") | .status")"
          case "$status" in installed|stopped) break;; esac
          sleep 2
        done
        case "$status" in installed|stopped) ;; *) exit 1;; esac
        ! mountpoint -q /media/bvml-startos-overlay
        dev="$(readlink -f /dev/disk/by-id/virtio-BVMLO-* 2>/dev/null || true)"
        [[ -z "$dev" ]] || ! findmnt -rn -S "$dev" | grep -q .
        sync
      ' bash "$script" "$startos_root/bin/startos-fulcrum.sh" \
        "$startos_root/bin/startos-electrs.sh"
    return
  fi
  platform_exec_sync "$vm" "$script" "$GUEST_EXEC_TIMEOUT" stop
}

stage_guest_index_identity() {
  local vm="$1" json encoded path
  json="$(index_active_json "$vm")"
  [[ "$(jq '.services|length' <<<"$json")" != 0 ]] || return 0
  encoded="$(base64 -w0 <<<"$json")"
  case "$vm" in
    ubuntu)
      path=/etc/bvml/active-indexes.json
      guest_exec_sync ubuntu /bin/bash 60 -c \
        "printf %s '$encoded' | base64 -d >'$path'; chown root:root '$path'; chmod 0600 '$path'"
      ;;
    umbrel)
      path="$(jq -r .os.data_directory "$UMBREL_PROFILE")/.bvml/etc/active-indexes.json"
      umbrel_exec_sync /bin/bash 60 -c \
        "printf %s '$encoded' | base64 -d >'$path'; chown root:root '$path'; chmod 0600 '$path'"
      ;;
    startos)
      path="$(jq -r .os.management_root "$STARTOS_PROFILE")/active-indexes.json"
      startos_exec_sync /bin/bash 60 -c \
        "printf %s '$encoded' | base64 -d >'$path'; chown root:root '$path'; chmod 0600 '$path'"
      ;;
  esac
}

index_adapter_guest_action() {
  local vm="$1" action="$2" service present=0 script evidence timeout="$GUEST_EXEC_TIMEOUT"
  local -a services=()
  while read -r service; do
    if [[ -f "$(index_overlay "$vm" "$service")" && -f "$(index_overlay_meta "$vm" "$service")" ]]; then
      services+=("$service")
      present=1
    fi
  done < <(index_services_for_vm "$vm")
  ((present)) || return 0
  stage_guest_index_identity "$vm"
  case "$vm" in
    ubuntu)
      script=/usr/local/libexec/bvml/ubuntu-indexers.sh
      for service in "${services[@]}"; do
        if [[ "$action" == setup ]]; then
          guest_exec_sync ubuntu "$script" "$INDEX_BUILD_TIMEOUT" start "$service"
        fi
        guest_exec_sync ubuntu "$script" "$INDEX_BUILD_TIMEOUT" verify "$service"
      done
      return
      ;;
    umbrel)
      script="$(jq -r .os.data_directory "$UMBREL_PROFILE")/.bvml/bin/umbrel-indexers.sh"
      evidence="$(jq -r .os.data_directory "$UMBREL_PROFILE")/.bvml/etc/indexers-verification.json"
      timeout="$INDEX_BUILD_TIMEOUT"
      ;;
    startos)
      # StartOS runs one native package adapter per index service.
      timeout="$INDEX_BUILD_TIMEOUT"
      local startos_root part_file tmp
      startos_root="$(jq -r .os.management_root "$STARTOS_PROFILE")"
      tmp="$ADAPTER_STATE_DIR/$vm-indexers.json.new"
      jq -n --arg platform startos --arg profile "${INDEX_PROFILE_SHA256,,}" \
        '{platform:$platform,profile_digest:$profile,last_validation_result:"ok",
          validated_at:(now|todateiso8601),services:{}}' >"$tmp"
      for service in "${services[@]}"; do
        script="$startos_root/bin/startos-${service}.sh"
        evidence="$startos_root/${service}-verification.json"
        platform_exec_sync "$vm" "$script" "$timeout" "$action"
        platform_exec_sync "$vm" /bin/cat 30 "$evidence"
        part_file="$ADAPTER_STATE_DIR/$vm-indexers-$service.json.new"
        printf '%s\n' "$GUEST_EXEC_STDOUT" >"$part_file"
        jq -e '
          .last_validation_result=="ok" and .synchronized==true and
          (.height|type=="number" and .>0) and
          (.reused_existing_database==true)
        ' "$part_file" >/dev/null ||
          { rm -f "$part_file" "$tmp"; die "$vm $service index adapter returned invalid evidence"; }
        jq --arg service "$service" --slurpfile part "$part_file" \
          '.services[$service]=$part[0]' "$tmp" >"$tmp.next"
        mv "$tmp.next" "$tmp"
        rm -f "$part_file"
      done
      jq -e --arg platform "$vm" '
        .platform==$platform and .last_validation_result=="ok" and
        (.profile_digest|type=="string" and length>0) and
        (.services|length>0)
      ' "$tmp" >/dev/null || { rm -f "$tmp"; die "$vm returned invalid index adapter evidence"; }
      chmod 0600 "$tmp"; mv "$tmp" "$ADAPTER_STATE_DIR/$vm-indexers.json"
      return
      ;;
  esac
  platform_exec_sync "$vm" "$script" "$timeout" "$action"
  platform_exec_sync "$vm" /bin/cat 30 "$evidence"
  local tmp="$ADAPTER_STATE_DIR/$vm-indexers.json.new"
  printf '%s\n' "$GUEST_EXEC_STDOUT" >"$tmp"
  jq -e --arg platform "$vm" '
    .platform==$platform and .last_validation_result=="ok" and
    (.profile_digest|type=="string" and length>0)
  ' "$tmp" >/dev/null || { rm -f "$tmp"; die "$vm returned invalid index adapter evidence"; }
  chmod 0600 "$tmp"; mv "$tmp" "$ADAPTER_STATE_DIR/$vm-indexers.json"
}

stop_vm() {
  local vm="$1" waited=0; valid_vm "$vm"; set_lifecycle_context "$vm"
  is_defined "$vm" || die "VM is not defined: $vm"
  [[ "$(owner_vm)" == "$vm" && "$(overlay_vm)" == "$vm" ]] || die "$vm does not own the active overlay"
  if ! is_shut_off "$vm"; then
    if ! (guest_application_stop "$vm"); then
      write_env_file "$ADAPTER_RECOVERY_META" "operation=application-stop" "vm=$vm" \
        "image=$OVERLAY" "result=recovery-required" "recorded=$(date -u +%FT%TZ)"
      meta_set "$OVERLAY_META" recovery_required 1
      meta_set "$OVERLAY_META" adapter_state stop-failed
      die "$vm application stop failed; VM, mount, attachment, owner, and overlay were preserved"
    fi
    virshq shutdown "$(domain "$vm")"
    while ! is_shut_off "$vm"; do
      (( waited >= SHUTDOWN_TIMEOUT )) && die "shutdown timeout; attachment and ownership retained"
      sleep 2; ((waited+=2))
    done
  fi
  detach_image "$vm" "$OVERLAY"
  [[ -z "$(attached_vm_for_path "$OVERLAY")" ]] || die "overlay still attached; ownership retained"
  assert_no_process_reference "$OVERLAY"
  detach_retained_indexes "$vm"
  rm -f -- "$OWNER_FILE"
  meta_set "$OVERLAY_META" owner_state retained
  meta_set "$OVERLAY_META" attachment_state detached
  meta_set "$OVERLAY_META" mount_state unmounted
  meta_set "$OVERLAY_META" adapter_state stopped
  meta_set "$OVERLAY_META" recovery_required 0
  rm -f -- "$ADAPTER_RECOVERY_META"
  note "$vm is shut off and detached; its overlay is retained for discard or promotion"
}

discard_overlay() {
  local requested="${1:?VM required}" vm="$1"
  valid_vm "$vm"; set_lifecycle_context "$vm"
  is_shut_off "$vm" || die "$(domain "$vm") is $(domain_state "$vm"); exact 'shut off' required"
  assert_no_extra_overlays
  [[ ! -e "$OWNER_FILE" ]] || die "owner record remains; run stop for the owning VM"
  if [[ ! -e "$OVERLAY" && ! -e "$OVERLAY_META" ]]; then note "no active overlay"; return; fi
  [[ "$(overlay_vm)" == "$requested" ]] || die "retained overlay does not belong to $requested"
  [[ -z "$(attached_vm_for_path "$OVERLAY")" ]] || die "$vm overlay remains attached"
  assert_no_process_reference "$OVERLAY"
  rm -f -- "$OVERLAY" "$OVERLAY_META" "$VERIFY_META" "$BOOTSTRAP_VERIFY"
  discard_index_overlays "$vm"
  note "discarded $vm overlay; persistent VM disks and canonical checkpoint are unchanged"
}

reconcile_owner() {
  local vm="${1:?VM required}" attached owner kind image meta manifest_vm manifest_id owner_id manifest_serial owner_serial
  valid_vm "$vm"; set_lifecycle_context "$vm"
  if [[ -f "$ADAPTER_RECOVERY_META" ]] && ! is_shut_off "$vm"; then
    die "$vm recovery is active while the VM is $(domain_state "$vm"); inspect application, mount, attachment, and owner state before clean stop"
  fi
  is_shut_off "$vm" || die "$(domain "$vm") must be exactly shut off for reconciliation"
  owner="$(owner_vm)"
  if [[ -n "$owner" ]]; then
    kind="$(owner_kind)"; image="$(owner_image)"; owner_id="$(meta_get "$OWNER_FILE" identity)"
    case "$kind" in
      overlay) meta="$OVERLAY_META"; manifest_vm="$(overlay_vm)"; manifest_id="$(overlay_id)";
        [[ "$image" == "$OVERLAY" ]] || die "stale overlay owner has an unexpected image path" ;;
      bootstrap) meta="$BOOTSTRAP_META"; manifest_vm="$(meta_get "$meta" vm)";
        manifest_id="$(meta_get "$meta" bootstrap_id)"
        [[ "$image" == "$BOOTSTRAP" ]] || die "stale bootstrap owner has an unexpected image path" ;;
      *) die "owner kind is missing or unsupported; automatic reconciliation is unsafe" ;;
    esac
    manifest_serial="$(meta_get "$meta" disk_serial)"
    owner_serial="$(meta_get "$OWNER_FILE" disk_serial)"
    attached="$(attached_vm_for_path "$image" | paste -sd, -)"
    [[ -z "$attached" ]] || die "cannot reconcile: $kind image remains attached to $attached"
    assert_no_process_reference "$image"
    [[ -f "$image" && -f "$meta" && "$manifest_vm" == "$owner" && "$manifest_id" == "$owner_id" &&
       -n "$owner_serial" && "$manifest_serial" == "$owner_serial" ]] ||
      die "owner cannot be reconciled automatically: $kind image/manifest disagrees"
    [[ -z "$(attached_vm_for_path "$image")" ]] || die "conflicting $vm Bitcoin storage attachment exists"
    [[ ! -f "$OVERLAY" || ! -f "$BOOTSTRAP" ]] || die "bootstrap and ordinary overlay coexist"
    rm -f -- "$OWNER_FILE"
    [[ "$kind" != overlay ]] || {
      meta_set "$meta" owner_state retained
      meta_set "$meta" attachment_state detached
    }
    rm -f -- "$ADAPTER_RECOVERY_META"
    note "cleared stale detached $kind owner for retained $owner image"
  else note "owner state is already reconciled"; fi
}

bootstrap_attached_vm() { attached_vm_for_path "$BOOTSTRAP"; }

checkpoint_bootstrap() {
  need qemu-img; need virsh
  assert_initialization_state_empty "fresh bootstrap"
  [[ "$BOOTSTRAP_SIZE_GIB" =~ ^[1-9][0-9]*$ ]] || die "BOOTSTRAP_SIZE_GIB must be a positive integer"
  is_defined ubuntu || die "Ubuntu VM is not defined"
  transactional_attach_start bootstrap ubuntu
  note "empty, unformatted bootstrap image attached; run bootstrap-init explicitly inside the new Ubuntu lifecycle"
}

bootstrap_init() {
  [[ "$(meta_get "$OWNER_FILE" kind)" == bootstrap ]] || die "no active bootstrap owner"
  [[ "$(owner_vm)" == ubuntu && "$(bootstrap_attached_vm)" == ubuntu ]] ||
    die "bootstrap owner and attachment disagree"
  [[ ! "$(is_shut_off ubuntu && echo yes)" == yes ]] || die "Ubuntu must be running for filesystem initialization"
  [[ "$(meta_get "$BOOTSTRAP_META" filesystem_initialized)" == 0 ]] ||
    die "bootstrap filesystem is already initialized"
  [[ "${1:-}" == "--confirm-bootstrap-format" && $# == 1 ]] ||
    die "explicit disk initialization requires --confirm-bootstrap-format"
  guest_exec_sync ubuntu /usr/local/libexec/bvml/ubuntu-knots-rdts.sh 30 \
    stage-bootstrap \
    "$(meta_get "$BOOTSTRAP_META" bootstrap_id)" \
    "$(meta_get "$BOOTSTRAP_META" disk_serial)" \
    "$(meta_get "$BOOTSTRAP_META" size_bytes)" \
    "$(meta_get "$BOOTSTRAP_META" bootstrap_nonce)"
  guest_exec_sync ubuntu /usr/local/libexec/bvml/ubuntu-knots-rdts.sh "$GUEST_EXEC_TIMEOUT" \
    init-filesystem --confirm-bootstrap-format \
    "$(meta_get "$BOOTSTRAP_META" bootstrap_id)" \
    "$(meta_get "$BOOTSTRAP_META" disk_serial)" \
    "$(meta_get "$BOOTSTRAP_META" size_bytes)" \
    "$(meta_get "$BOOTSTRAP_META" bootstrap_nonce)"
  sed -i 's/^filesystem_initialized=.*/filesystem_initialized=1/;s/^state=.*/state=ibd-in-progress/' "$BOOTSTRAP_META"
  note "bootstrap filesystem initialized after guest identity and signature checks completed"
}

bootstrap_stop() {
  local waited=0
  [[ "$(meta_get "$OWNER_FILE" kind)" == bootstrap && "$(owner_vm)" == ubuntu ]] ||
    die "Ubuntu does not own an active bootstrap image"
  assert_consistent_owner
  if ! is_shut_off ubuntu; then
    guest_application_stop ubuntu
    virshq shutdown "$(domain ubuntu)"
    while ! is_shut_off ubuntu; do
      (( waited >= SHUTDOWN_TIMEOUT )) && die "shutdown timeout; bootstrap remains attached and owned"
      sleep 2; ((waited+=2))
    done
  fi
  detach_image ubuntu "$BOOTSTRAP" ||
    die "bootstrap detach failed; ownership retained"
  [[ -z "$(bootstrap_attached_vm)" ]] || die "bootstrap remains attached; ownership retained"
  assert_no_process_reference "$BOOTSTRAP"
  rm -f -- "$OWNER_FILE"
  sed -i 's/^state=.*/state=retained-awaiting-verification/' "$BOOTSTRAP_META"
  note "bootstrap retained, detached, and awaiting overlay-specific verification"
}

bootstrap_verify() {
  need virt-cat; need virt-filesystems
  [[ -f "$BOOTSTRAP" && -f "$BOOTSTRAP_META" ]] || die "bootstrap image is missing"
  [[ "$(meta_get "$BOOTSTRAP_META" filesystem_initialized)" == 1 ]] || die "bootstrap filesystem was never initialized"
  all_shut_off; assert_no_bitcoin_attachments; [[ ! -e "$OWNER_FILE" ]] || die "bootstrap owner remains"
  assert_no_process_reference "$BOOTSTRAP"
  local tmp="$BOOTSTRAP_VERIFY.new"
  rm -f -- "$tmp"
  virt-cat -a "$BOOTSTRAP" -m /dev/sda /.bvml/ubuntu-verification.env >"$tmp" ||
    { rm -f -- "$tmp"; die "current bootstrap verification evidence is missing"; }
  validate_profile_generation
  local system_image release_guest rdts_guest checkpoint_guest
  system_image="$(vm_dir ubuntu)/system.qcow2"
  release_guest="$(virt-cat -a "$system_image" /etc/bvml/releases/knots-version.env | sha256sum | awk '{print $1}')"
  rdts_guest="$(virt-cat -a "$system_image" /etc/bvml/releases/knots-rdts.env | sha256sum | awk '{print $1}')"
  checkpoint_guest="$(virt-cat -a "$system_image" /etc/bvml/checkpoint-profile.json | sha256sum | awk '{print $1}')"
  [[ "$release_guest" == "${KNOTS_RELEASE_PROFILE_SHA256,,}" &&
     "$rdts_guest" == "${KNOTS_RDTS_PROFILE_SHA256,,}" &&
     "$checkpoint_guest" == "${CHECKPOINT_PROFILE_SHA256,,}" ]] ||
    { rm -f -- "$tmp"; die "stopped Ubuntu profile generation differs from the host-approved generation"; }
  printf '%s\n' \
    "bootstrap_id=$(meta_get "$BOOTSTRAP_META" bootstrap_id)" \
    "release_profile_sha256=$release_guest" \
    "profile_generation_id=$(profile_generation_id)" \
    "profile_generation_digest=$(active_profile_generation_digest)" >>"$tmp"
  [[ "$(meta_get "$BOOTSTRAP_META" profile_generation_id)" == "$(profile_generation_id)" ||
     -z "$(meta_get "$BOOTSTRAP_META" profile_generation_id)" ]] ||
    { rm -f -- "$tmp"; die "bootstrap manifest belongs to another profile generation"; }
  mv -- "$tmp" "$BOOTSTRAP_VERIFY"
  [[ "$(meta_get "$BOOTSTRAP_VERIFY" bootstrap_id)" == "$(meta_get "$BOOTSTRAP_META" bootstrap_id)" ]] ||
    die "verification belongs to another bootstrap image"
  [[ "$(meta_get "$BOOTSTRAP_VERIFY" filesystem_uuid)" == "$(image_filesystem_uuid "$BOOTSTRAP")" ]] ||
    die "bootstrap verification filesystem UUID does not match the image"
  verify_promotion_evidence "$BOOTSTRAP_VERIFY" bootstrap
  sed -i 's/^state=.*/state=verified-complete/' "$BOOTSTRAP_META"
  note "fresh IBD bootstrap evidence validated"
}

bootstrap_promote() {
  [[ "${1:-}" == "--confirm-synced-clean" && $# == 1 ]] ||
    die "bootstrap promotion requires --confirm-synced-clean"
  [[ ! -e "$CANONICAL" ]] || die "canonical checkpoint already exists"
  [[ "$(meta_get "$BOOTSTRAP_META" state)" == verified-complete ]] ||
    die "bootstrap is incomplete or has not been verified"
  all_shut_off; assert_no_bitcoin_attachments; [[ ! -e "$OWNER_FILE" ]] || die "bootstrap owner remains"
  assert_no_process_reference "$BOOTSTRAP"
  verify_promotion_evidence "$BOOTSTRAP_VERIFY" bootstrap
  [[ "$ROLLBACK_RETENTION" == none ]] ||
    die "first low-space promotion requires ROLLBACK_RETENTION=none"
  need guestfish; need qemu-img; need sha256sum
  validate_checkpoint_image "$BOOTSTRAP" ||
    die "verified bootstrap image failed final checkpoint validation"
  local generation id bundle raw_evidence info_file check_file domain_xml meta_tmp
  generation="$(new_id)"
  bundle="$RUN_DIR/recovery-bundles/$(meta_get "$BOOTSTRAP_META" bootstrap_id)-promotion"
  raw_evidence="$bundle/guest-verification.env"
  if [[ -d "$bundle" ]]; then
    [[ -s "$raw_evidence" && -s "$bundle/host-verification.env" &&
       "$(meta_get "$bundle/bootstrap-manifest.env" bootstrap_id)" == "$(meta_get "$BOOTSTRAP_META" bootstrap_id)" ]] ||
      die "existing promotion recovery bundle is incomplete or belongs to another bootstrap: $bundle"
  else
    install -d -m 0700 "$bundle"
    virt-cat -a "$BOOTSTRAP" -m /dev/sda /.bvml/ubuntu-verification.env >"$raw_evidence" ||
      { rm -f -- "$bundle"/*; rmdir "$bundle"; die "could not preserve in-image verification evidence"; }
    cp -- "$BOOTSTRAP_META" "$bundle/bootstrap-manifest.env"
    cp -- "$BOOTSTRAP_VERIFY" "$bundle/host-verification.env"
    cp -- "$KNOTS_RELEASE_PROFILE" "$bundle/knots-release-profile.env"
    cp -- "$KNOTS_RDTS_PROFILE" "$bundle/knots-rdts-profile.env"
    cp -- "$CHECKPOINT_PROFILE_FILE" "$bundle/checkpoint-profile.json"
    domain_xml="$bundle/ubuntu-domain.xml"
    virshq dumpxml "$(domain ubuntu)" --inactive >"$domain_xml"
    info_file="$bundle/qemu-img-info.json"; check_file="$bundle/qemu-img-check.txt"
    qemu-img info --output=json "$BOOTSTRAP" >"$info_file"
    qemu-img check "$BOOTSTRAP" >"$check_file"
    {
      printf 'bootstrap_id=%s\n' "$(meta_get "$BOOTSTRAP_META" bootstrap_id)"
      printf 'filesystem_uuid=%s\n' "$(meta_get "$BOOTSTRAP_VERIFY" filesystem_uuid)"
      printf 'profile_generation_id=%s\n' "$(meta_get "$BOOTSTRAP_VERIFY" profile_generation_id)"
      printf 'knots_binary_sha256=%s\n' "$(meta_get "$BOOTSTRAP_VERIFY" artifact_sha256)"
      printf 'block_height=%s\n' "$(meta_get "$BOOTSTRAP_VERIFY" block_height)"
      printf 'best_block_hash=%s\n' "$(meta_get "$BOOTSTRAP_VERIFY" best_block_hash)"
      printf 'best_block_time=%s\n' "$(meta_get "$BOOTSTRAP_VERIFY" best_block_time)"
    } >"$bundle/recovery-summary.env"
    sha256sum "$bundle"/* >"$bundle/bundle.sha256"
  fi
  sync -f "$BOOTSTRAP"; sync -f "$ACTIVE_DIR"; sync -f "$bundle"

  # The only blockchain-sized image is modified only to remove transient
  # evidence, then renamed atomically on the same filesystem.
  guestfish_data_disk "$BOOTSTRAP" rm /.bvml/ubuntu-verification.env >/dev/null ||
    die "transient evidence cleanup failed; bootstrap path and host evidence remain intact"
  sync -f "$BOOTSTRAP"; sync -f "$ACTIVE_DIR"
  id="$(sha256sum "$BOOTSTRAP" | awk '{print $1}')"
  printf '%s  %s\n' "$id" "$(basename "$CANONICAL")" >"$bundle/canonical-image.sha256"
  meta_tmp="$CANONICAL_META.new"
  write_env_file "$meta_tmp" "id=$id" "generation=$generation" \
    "created=$(date -u +%FT%TZ)" "network=signet" "blocksxor=0" "layout=signet-subdir" \
    "kind=fresh-knots-rdts-ibd" "rollback_retention=none" "disaster_recovery=re-IBD" \
    "source_bootstrap_id=$(meta_get "$BOOTSTRAP_META" bootstrap_id)" \
    "filesystem_uuid=$(meta_get "$BOOTSTRAP_VERIFY" filesystem_uuid)" \
    "knots_version_normalized=$(meta_get "$BOOTSTRAP_VERIFY" knots_version_normalized)" \
    "knots_artifact_sha256=$(meta_get "$BOOTSTRAP_VERIFY" artifact_sha256)" \
    "release_profile_sha256=$(meta_get "$BOOTSTRAP_VERIFY" release_profile_sha256)" \
    "rdts_profile_name=$(meta_get "$BOOTSTRAP_VERIFY" rdts_profile_name)" \
    "rdts_profile_sha256=$(meta_get "$BOOTSTRAP_VERIFY" rdts_profile_sha256)" \
    "rdts_observed_args_json=$(meta_get "$BOOTSTRAP_VERIFY" rdts_observed_args_json)" \
    "profile_generation_id=$(meta_get "$BOOTSTRAP_VERIFY" profile_generation_id)" \
    "profile_generation_digest=$(meta_get "$BOOTSTRAP_VERIFY" profile_generation_digest)" \
    "checkpoint_profile_id=$(checkpoint_profile_id)" \
    "checkpoint_profile_sha256=${CHECKPOINT_PROFILE_SHA256,,}" \
    "block_height=$(meta_get "$BOOTSTRAP_VERIFY" block_height)" \
    "header_height=$(meta_get "$BOOTSTRAP_VERIFY" header_height)" \
    "best_block_hash=$(meta_get "$BOOTSTRAP_VERIFY" best_block_hash)" \
    "best_block_time=$(meta_get "$BOOTSTRAP_VERIFY" best_block_time)" \
    "median_time=$(meta_get "$BOOTSTRAP_VERIFY" median_time)" \
    "verified_epoch=$(meta_get "$BOOTSTRAP_VERIFY" verified_epoch)" \
    "index_state_json=$(meta_get "$BOOTSTRAP_VERIFY" index_state_json)"
  mv -- "$BOOTSTRAP" "$CANONICAL"
  mv -- "$meta_tmp" "$CANONICAL_META"
  sync -f "$ACTIVE_DIR"; sync -f "$CANONICAL_DIR"
  if ! (protect_image "$CANONICAL" && canonical_preflight); then
    unprotect_image "$CANONICAL" || true
    mv -- "$CANONICAL" "$BOOTSTRAP"
    rm -f -- "$CANONICAL_META"
    guestfish_data_disk "$BOOTSTRAP" upload "$raw_evidence" /.bvml/ubuntu-verification.env >/dev/null || true
    sync -f "$BOOTSTRAP"; sync -f "$ACTIVE_DIR"
    write_env_file "$RECOVERY_META" "operation=bootstrap-promotion" "result=source-preserved" \
      "bootstrap_id=$(meta_get "$BOOTSTRAP_META" bootstrap_id)" "recovery_bundle=$bundle"
    die "bootstrap installation/protection failed; bootstrap path and recovery evidence were restored"
  fi
  sync -f "$CANONICAL"; sync -f "$CANONICAL_DIR"
  rm -f -- "$BOOTSTRAP_META" "$BOOTSTRAP_VERIFY" "$RECOVERY_META"
  note "fresh Knots/RDTS IBD renamed in place as the first protected canonical checkpoint"
}

bootstrap_cleanup() {
  all_shut_off; [[ -z "$(bootstrap_attached_vm)" ]] || die "bootstrap remains attached"
  [[ ! -e "$OWNER_FILE" ]] || die "owner remains; reconcile or stop first"
  assert_no_process_reference "$BOOTSTRAP"
  rm -f -- "$BOOTSTRAP" "$BOOTSTRAP_META" "$BOOTSTRAP_VERIFY" \
    "$BOOTSTRAP_CANDIDATE" "$BOOTSTRAP_CANDIDATE_META"
  if [[ "$(meta_get "$RECOVERY_META" operation)" == bootstrap-promotion ]]; then
    rm -f -- "$RECOVERY_META"
  fi
  note "incomplete bootstrap state removed"
}

reset_vm() {
  local vm="$1"; valid_vm "$vm"
  set_lifecycle_context "$vm"
  if [[ -f "$OVERLAY_META" && "$(overlay_vm)" != "$vm" ]]; then
    die "active overlay belongs to $(overlay_vm), not $vm"
  fi
  if [[ -f "$OWNER_FILE" ]]; then stop_vm "$vm"; else
    is_defined "$vm" && is_shut_off "$vm" || die "$vm is active without consistent ownership; run validate"
  fi
  discard_overlay "$vm"
}

source_xor_check() {
  local source="$1" xor="$source/signet/blocks/xor.dat" byte
  [[ -d "$source/signet/blocks" && -d "$source/signet/chainstate" ]] ||
    die "source must contain signet/blocks and signet/chainstate (full Knots datadir)"
  [[ -e "$xor" ]] || return 0
  while read -r byte; do
    [[ "$byte" == 0 ]] || die "source signet/blocks/xor.dat contains a non-zero XOR key. blocksxor=0 does not convert block files. Start Knots with the source's current format and perform a deliberate non-XOR rebuild/reindex into a new datadir before importing."
  done < <(od -An -v -tu1 "$xor" | tr -s ' ' '\n' | sed '/^$/d')
}

checkpoint_import() {
  local source="" source_mode="" signet_asserted=0
  while (($#)); do case "$1" in
    --assert-source-stopped) source_mode=stopped; shift ;;
    --consistent-snapshot) source_mode=snapshot; shift ;;
    --assert-signet) signet_asserted=1; shift ;;
    --*) die "checkpoint-import SOURCE (--assert-source-stopped|--consistent-snapshot) --assert-signet" ;;
    *) [[ -z "$source" ]] || die "only one import source may be supplied"; source="$1"; shift ;;
  esac; done
  [[ -n "$source" ]] || die "checkpoint-import requires an explicit source path"
  [[ "$source" == /* && "$source" != *$'\n'* && "$source" != *$'\r'* ]] ||
    die "checkpoint-import source must be an absolute path without control characters"
  [[ -n "$source_mode" ]] || die "assert a clean stop or consistent snapshot explicitly"
  (( signet_asserted == 1 )) || die "explicit --assert-signet is required after source validation"
  need qemu-img; need virt-make-fs; need virt-ls; need virt-customize; need tar
  assert_initialization_state_empty "checkpoint import"
  [[ -d "$source" ]] || die "source datadir does not exist: $source"
  if [[ "$source_mode" == stopped ]]; then
    [[ ! -e "$source/.lock" ]] ||
      die "source .lock exists; remove it only after proving the source node stopped cleanly"
    if command -v lsof >/dev/null && lsof +D "$source" 2>/dev/null | grep -q .; then
      die "a process has the asserted-stopped source datadir open"
    fi
  fi
  source_xor_check "$source"
  local candidate="$IMPORT_CANDIDATE" bytes size_bytes id generation
  rm -f -- "$candidate"
  # Import the full signet network subdirectory (blocks, chainstate, indexes).
  local import_paths=(signet)
  bytes="$(du -sb "$source/signet" | awk '{print $1+0}')"
  (( bytes > 0 )) || die "source allocation could not be measured"
  size_bytes=$(( bytes + (bytes * CHECKPOINT_HEADROOM_PERCENT / 100) ))
  (( size_bytes > bytes )) || size_bytes=$((bytes + 1073741824))
  note "creating an absolute ${size_bytes}-byte import image from ${bytes} source bytes"
  tar -C "$source" -cf - --exclude='signet/blocks/.lock' --exclude='*.log' \
    "${import_paths[@]}" |
    virt-make-fs --format=qcow2 --type=ext4 --size="$size_bytes" - "$candidate"
  virt-customize -a "$candidate" \
    --run-command "chown -R $BITCOIN_DATADIR_UID:$BITCOIN_DATADIR_GID /signet; chmod 0750 /signet /signet/blocks /signet/chainstate; if test -d /signet/indexes; then chmod 0750 /signet/indexes; fi" \
    >/dev/null
  qemu-img check "$candidate"
  virt-ls -a "$candidate" -m /dev/sda / | grep -qx signet || die "candidate lacks signet/"
  virt-ls -a "$candidate" -m /dev/sda /signet | grep -qx blocks || die "candidate lacks signet/blocks/"
  virt-ls -a "$candidate" -m /dev/sda /signet | grep -qx chainstate || die "candidate lacks signet/chainstate/"
  validate_checkpoint_profile
  if [[ "$(checkpoint_profile_indexes_json)" != '[]' ]]; then
    virt-ls -a "$candidate" -m /dev/sda /signet | grep -qx indexes || die "candidate lacks verified signet/indexes/"
  fi
  id="$(sha256sum "$candidate" | awk '{print $1}')"
  generation="$(new_id)"
  write_env_file "$IMPORT_META" \
    "id=$id" "generation=$generation" "created=$(date -u +%FT%TZ)" \
    "source=$source" "source_consistency=$source_mode" "source_network_assertion=signet" \
    "source_bytes=$bytes" "image_bytes=$size_bytes" \
    "network=signet" "blocksxor=0" "layout=signet-subdir" "kind=initial-import" \
    "checkpoint_profile_id=$(checkpoint_profile_id)" \
    "checkpoint_profile_sha256=${CHECKPOINT_PROFILE_SHA256,,}"
  mv -- "$candidate" "$CANONICAL"
  mv -- "$IMPORT_META" "$CANONICAL_META"
  if ! (protect_image "$CANONICAL" && validate_checkpoint_image "$CANONICAL"); then
    unprotect_image "$CANONICAL" || true
    mv -- "$CANONICAL" "$candidate"; mv -- "$CANONICAL_META" "$IMPORT_META"
    die "import installation/protection failed; candidate restored without canonical state"
  fi
  note "protected canonical checkpoint imported from $source"
}

verify_promotion_evidence() {
  local evidence="${1:-$VERIFY_META}" kind="${2:-overlay}" key expected
  [[ -f "$evidence" ]] || die "missing current Ubuntu Knots verification evidence"
  for key in vm network blocksxor synced clean_shutdown datadir_layout rdts_validated \
    knots_version_normalized artifact_sha256 rdts_profile_name rdts_profile_sha256 \
    rdts_observed_args_json block_height header_height best_block_hash best_block_time \
    median_time tip_age_seconds max_tip_age_seconds verified_epoch filesystem_uuid \
    checkpoint_profile_id checkpoint_profile_sha256 index_state_json shutdown_id; do
    [[ -n "$(meta_get "$evidence" "$key")" ]] || die "verification metadata missing $key"
  done
  for expected in "vm=ubuntu" "network=signet" "blocksxor=0" "synced=1" \
                  "clean_shutdown=1" "datadir_layout=signet-subdir" "rdts_validated=1"; do
    [[ "$(meta_get "$evidence" "${expected%%=*}")" == "${expected#*=}" ]] ||
      die "verification requirement failed: $expected"
  done
  [[ -n "$KNOTS_VERSION_NORMALIZED" ]] || die "KNOTS_VERSION_NORMALIZED is not configured"
  [[ "$(meta_get "$evidence" knots_version_normalized)" == "$KNOTS_VERSION_NORMALIZED" ]] ||
    die "normalized Knots version does not match configured release"
  [[ "$(meta_get "$evidence" artifact_sha256)" == "$KNOTS_ARTIFACT_SHA256" ]] ||
    die "artifact digest does not match authenticated release configuration"
  [[ "$(meta_get "$evidence" rdts_profile_sha256)" == "${KNOTS_RDTS_PROFILE_SHA256,,}" ]] ||
    die "verification used another RDTS profile digest"
  [[ -n "$KNOTS_RDTS_PROFILE_NAME" &&
     "$(meta_get "$evidence" rdts_profile_name)" == "$KNOTS_RDTS_PROFILE_NAME" ]] ||
    die "verification used another RDTS profile name"
  jq -e 'type == "array" and length > 0 and all(.[]; type == "string")' \
    <<<"$KNOTS_RDTS_REQUIRED_ARGS_JSON" >/dev/null ||
    die "host approved RDTS required-argument JSON is missing or invalid"
  jq -e 'type == "array" and length > 0 and all(.[]; type == "string")' \
    <<<"$(meta_get "$evidence" rdts_observed_args_json)" >/dev/null ||
    die "observed RDTS evidence is not a nonempty JSON string array"
  local observed_rdts_sorted approved_rdts_sorted
  observed_rdts_sorted="$(jq -c 'sort' <<<"$(meta_get "$evidence" rdts_observed_args_json)")"
  approved_rdts_sorted="$(jq -c 'sort' <<<"$KNOTS_RDTS_REQUIRED_ARGS_JSON")"
  [[ "$observed_rdts_sorted" == "$approved_rdts_sorted" ]] ||
    die "observed runtime RDTS arguments do not exactly match the host-approved set"
  [[ "$(meta_get "$evidence" block_height)" == "$(meta_get "$evidence" header_height)" ]] ||
    die "block and header heights differ"
  validate_checkpoint_profile
  [[ "$(meta_get "$evidence" checkpoint_profile_id)" == "$(checkpoint_profile_id)" ]] ||
    die "verification used another checkpoint index profile"
  [[ "$(meta_get "$evidence" checkpoint_profile_sha256)" == "${CHECKPOINT_PROFILE_SHA256,,}" ]] ||
    die "verification checkpoint profile digest mismatch"
  local expected_indexes index_state now best_time max_age
  expected_indexes="$(checkpoint_profile_indexes_json)"
  index_state="$(meta_get "$evidence" index_state_json)"
  jq -e --argjson expected "$expected_indexes" '
    . as $state |
    type == "object" and
    all($expected[]; $state[.] != null and $state[.].synced == true) and
    all(to_entries[]; (.value.synced // false) == true)
  ' <<<"$index_state" >/dev/null || die "required index set is missing, conflicting, or unsynchronized"
  best_time="$(meta_get "$evidence" best_block_time)"
  max_age="$(meta_get "$evidence" max_tip_age_seconds)"
  [[ "$best_time" =~ ^[0-9]+$ && "$max_age" =~ ^[0-9]+$ ]] ||
    die "verification tip freshness fields are invalid"
  [[ "$max_age" == "$MAX_TIP_AGE_SECONDS" ]] ||
    die "verification used another maximum tip age"
  now="$(date +%s)"
  (( now >= best_time && now - best_time <= MAX_TIP_AGE_SECONDS )) ||
    die "verified chain tip is now older than the configured ${MAX_TIP_AGE_SECONDS}s limit"
  if [[ "$kind" == overlay ]]; then
    [[ "$(meta_get "$evidence" overlay_id)" == "$(overlay_id)" ]] ||
      die "verification belongs to another overlay"
    [[ "$(meta_get "$evidence" checkpoint_generation)" == "$(checkpoint_generation)" ]] ||
      die "verification belongs to another checkpoint generation"
  else
    [[ "$(meta_get "$evidence" bootstrap_id)" == "$(meta_get "$BOOTSTRAP_META" bootstrap_id)" ]] ||
      die "verification belongs to another bootstrap"
    [[ "$(meta_get "$evidence" release_profile_sha256)" == "${KNOTS_RELEASE_PROFILE_SHA256,,}" &&
       "$(meta_get "$evidence" profile_generation_id)" == "$(profile_generation_id)" &&
       "$(meta_get "$evidence" profile_generation_digest)" == "$(active_profile_generation_digest)" ]] ||
      die "verification is not bound to the current host/guest profile generation"
  fi
}

checkpoint_verify() {
  need virt-cat; need virt-filesystems
  set_lifecycle_context ubuntu
  [[ "$(overlay_vm)" == ubuntu ]] || die "verification is only valid for an Ubuntu overlay"
  [[ ! -e "$OWNER_FILE" ]] || die "stop Ubuntu before extracting verification"
  is_shut_off ubuntu || die "Ubuntu must be exactly shut off before verification"
  [[ -z "$(attached_vm_for_path "$OVERLAY")" ]] || die "Ubuntu overlay remains attached"
  assert_overlay_chain
  local candidate="$(lifecycle_dir ubuntu)/verification.new"
  rm -f -- "$candidate"
  virt-cat -a "$OVERLAY" -m /dev/sda /.bvml/ubuntu-verification.env >"$candidate" ||
    { rm -f -- "$candidate"; die "guest verification file missing; run ubuntu-knots-rdts.sh verify-shutdown"; }
  printf 'overlay_id=%s\ncheckpoint_generation=%s\n' "$(overlay_id)" "$(checkpoint_generation)" >>"$candidate"
  chmod 0600 "$candidate"
  mv -- "$candidate" "$VERIFY_META"
  [[ "$(meta_get "$VERIFY_META" filesystem_uuid)" == "$(image_filesystem_uuid "$OVERLAY")" ]] ||
    die "verification filesystem UUID does not match the current overlay"
  verify_promotion_evidence "$VERIFY_META" overlay
  note "Ubuntu Knots/RDTS shutdown verification imported"
}

checkpoint_sync_start() {
  [[ $# == 0 ]] || die "usage: bvml checkpoint-sync-start"
  set_lifecycle_context ubuntu
  [[ "$(owner_vm)" == ubuntu && "$(domain_state ubuntu)" == running ]] ||
    die "Ubuntu must actively own and run its disposable checkpoint overlay"
  assert_overlay_chain
  guest_exec_sync ubuntu /usr/local/libexec/bvml/ubuntu-knots-rdts.sh 1200 install
  guest_exec_sync ubuntu /usr/local/libexec/bvml/ubuntu-knots-rdts.sh 120 start
  meta_set "$OVERLAY_META" adapter_state syncing
  rm -f -- "$VERIFY_META"
  note "Ubuntu Knots is synchronizing the chain and configured checkpoint indexes"
}

checkpoint_profile_migrate_guest() {
  [[ $# == 0 ]] || die "usage: bvml checkpoint-profile-migrate-guest"
  set_lifecycle_context ubuntu
  [[ "$(owner_vm)" == ubuntu && "$(domain_state ubuntu)" == running ]] ||
    die "Ubuntu must actively own and run its update overlay"
  validate_checkpoint_profile
  [[ "$(checkpoint_profile_id)" == signet-basic-filter-txindex-v1 ||
     "$(checkpoint_profile_id)" == signet-basic-filter-v1 ]] ||
    die "active host profile is not a supported basic-filter migration target"
  local profile64
  profile64="$(base64 -w0 "$CHECKPOINT_PROFILE_FILE")"
  guest_exec_sync ubuntu /bin/bash 120 -c "
    set -Eeuo pipefail
    conf=/etc/bvml/knots.env
    test -f \"\$conf\"
    tmp_profile=\$(mktemp /etc/bvml/checkpoint-profile.json.XXXXXX)
    tmp_conf=\$(mktemp /etc/bvml/knots.env.XXXXXX)
    trap 'rm -f -- \"\$tmp_profile\" \"\$tmp_conf\"' EXIT
    printf %s '$profile64' | base64 -d >\"\$tmp_profile\"
    test \"\$(sha256sum \"\$tmp_profile\" | cut -d' ' -f1)\" = '${CHECKPOINT_PROFILE_SHA256,,}'
    grep -Ev '^(CHECKPOINT_PROFILE_FILE|CHECKPOINT_PROFILE_SHA256|PROFILE_GENERATION_ID|PROFILE_GENERATION_DIGEST)=' \"\$conf\" >\"\$tmp_conf\"
    printf '%s\n' \
      'CHECKPOINT_PROFILE_FILE=/etc/bvml/checkpoint-profile.json' \
      'CHECKPOINT_PROFILE_SHA256=${CHECKPOINT_PROFILE_SHA256,,}' \
      'PROFILE_GENERATION_ID=$(profile_generation_id)' \
      'PROFILE_GENERATION_DIGEST=$(active_profile_generation_digest)' >>\"\$tmp_conf\"
    chown root:root \"\$tmp_profile\" \"\$tmp_conf\"
    chmod 0644 \"\$tmp_profile\" \"\$tmp_conf\"
    mv -f -- \"\$tmp_profile\" /etc/bvml/checkpoint-profile.json
    mv -f -- \"\$tmp_conf\" \"\$conf\"
    trap - EXIT
  "
  meta_set "$OVERLAY_META" profile_migration_target "$(checkpoint_profile_id)"
  meta_set "$OVERLAY_META" profile_migration_sha256 "${CHECKPOINT_PROFILE_SHA256,,}"
  note "installed the active checkpoint migration profile in Ubuntu"
}

checkpoint_sync_finish() {
  [[ $# == 0 ]] || die "usage: bvml checkpoint-sync-finish"
  set_lifecycle_context ubuntu
  [[ "$(owner_vm)" == ubuntu && "$(domain_state ubuntu)" == running ]] ||
    die "Ubuntu must actively own and run its update overlay"
  guest_exec_sync ubuntu /usr/local/libexec/bvml/ubuntu-knots-rdts.sh 14400 verify-shutdown
  stop_vm ubuntu
  note "Ubuntu checkpoint update is verified, shut off, detached, and retained"
}

checkpoint_promote() {
  [[ "${1:-}" == "--confirm-synced-clean" && $# == 1 ]] ||
    die "promotion requires --confirm-synced-clean after guest verification"
  need qemu-img; need virt-ls; need virt-cat; need virt-customize; require_canonical
  set_lifecycle_context ubuntu
  [[ "$(overlay_vm)" == ubuntu ]] || die "only an Ubuntu overlay may be promoted"
  [[ ! -e "$OWNER_FILE" ]] || die "runtime owner remains; stop Ubuntu first"
  assert_only_dependent_overlay ubuntu
  all_shut_off; assert_consistent_owner; assert_no_bitcoin_attachments; assert_no_extra_overlays
  assert_no_process_reference "$OVERLAY"; assert_no_process_reference "$CANONICAL"
  assert_overlay_chain; verify_promotion_evidence "$VERIFY_META" overlay
  qemu-img check -r leaks "$OVERLAY"
  local candidate="$CANONICAL_DIR/promotion-candidate.qcow2"
  local candidate_meta="$CANONICAL_DIR/promotion-manifest.env" id
  rm -f -- "$candidate" "$candidate_meta"
  qemu-img convert -p -O qcow2 "$OVERLAY" "$candidate"
  virt_customize_offline -a "$candidate" --delete /.bvml/ubuntu-verification.env >/dev/null
  validate_checkpoint_image "$candidate" || { rm -f -- "$candidate"; die "promotion candidate validation failed"; }
  id="$(sha256sum "$candidate" | awk '{print $1}')"
  write_env_file "$candidate_meta" "id=$id" "created=$(date -u +%FT%TZ)" \
    "generation=$(new_id)" \
    "network=signet" "blocksxor=0" "layout=signet-subdir" "kind=knots-rdts-promotion" \
    "knots_version_normalized=$(meta_get "$VERIFY_META" knots_version_normalized)" \
    "checkpoint_profile_id=$(checkpoint_profile_id)" \
    "checkpoint_profile_sha256=${CHECKPOINT_PROFILE_SHA256,,}"
  local required available pending="$CANONICAL_DIR/previous-canonical.pending"
  local pending_meta="$CANONICAL_DIR/previous-manifest.pending"
  required="$(du -B1 "$CANONICAL" | awk '{print $1}')"
  available="$(df -B1 --output=avail "${ROLLBACK_DESTINATION:-$CANONICAL_DIR}" | tail -1 | tr -d ' ')"
  note "rollback retention requires approximately $required bytes; $available bytes available"
  if [[ "$ROLLBACK_RETENTION" != none && "$available" -lt "$required" ]]; then
    die "insufficient rollback space; configure a larger ROLLBACK_DESTINATION or ROLLBACK_RETENTION=none"
  fi
  [[ ! -e "$ROLLBACK" && ! -e "$ROLLBACK_META" ]] ||
    die "rollback checkpoint already exists; remove it explicitly first"
  if [[ "$ROLLBACK_RETENTION" != none && -n "$ROLLBACK_DESTINATION" ]]; then
    [[ -d "$ROLLBACK_DESTINATION" ]] || die "external rollback destination must be an existing directory"
    cp --reflink=auto --sparse=always "$CANONICAL" "$ROLLBACK"
    cp "$CANONICAL_META" "$ROLLBACK_META"
    validate_checkpoint_image "$ROLLBACK" || { rm -f -- "$ROLLBACK" "$ROLLBACK_META"; die "external rollback copy validation failed"; }
    protect_image "$ROLLBACK"
  fi
  unprotect_image "$CANONICAL"
  mv -- "$CANONICAL" "$pending"; mv -- "$CANONICAL_META" "$pending_meta"
  if ! mv -- "$candidate" "$CANONICAL"; then
    mv -- "$pending" "$CANONICAL"; mv -- "$pending_meta" "$CANONICAL_META"
    protect_image "$CANONICAL"; die "candidate installation failed; previous canonical restored"
  fi
  mv -- "$candidate_meta" "$CANONICAL_META"
  if ! (protect_image "$CANONICAL" && validate_checkpoint_image "$CANONICAL"); then
    unprotect_image "$CANONICAL"
    mv -- "$CANONICAL" "$candidate"; mv -- "$CANONICAL_META" "$candidate_meta"
    mv -- "$pending" "$CANONICAL"; mv -- "$pending_meta" "$CANONICAL_META"
    protect_image "$CANONICAL"
    write_env_file "$RECOVERY_META" "operation=promotion" "result=automatic-restore" "failed_candidate=$candidate"
    die "installed candidate validation failed; previous canonical automatically restored and protected"
  fi
  if [[ "$ROLLBACK_RETENTION" != none && -z "$ROLLBACK_DESTINATION" ]]; then
    mv -- "$pending" "$ROLLBACK"; mv -- "$pending_meta" "$ROLLBACK_META"; protect_image "$ROLLBACK"
  else
    rm -f -- "$pending" "$pending_meta"
  fi
  rm -f -- "$OVERLAY" "$OVERLAY_META" "$VERIFY_META"
  note "checkpoint promoted; previous canonical preserved as rollback"
}

checkpoint_commit_no_rollback() {
  [[ "${1:-}" == --confirm-no-rollback && $# == 1 ]] ||
    die "usage: bvml checkpoint-commit --confirm-no-rollback"
  [[ "$ROLLBACK_RETENTION" == none ]] ||
    die "checkpoint-commit is only for the explicit no-rollback storage policy"
  need qemu-img; need guestfish
  local resume_after_commit=0
  if [[ -f "$RECOVERY_META" &&
        "$(meta_get "$RECOVERY_META" operation)" == checkpoint-commit-no-rollback ]]; then
    case "$(meta_get "$RECOVERY_META" state)" in
      transient-cleanup-failed|post-commit-qemu-check-failed|post-commit-datadir-validation-failed)
        resume_after_commit=1
        ;;
    esac
  fi
  set_lifecycle_context ubuntu
  [[ "$(overlay_vm)" == ubuntu && ! -e "$OWNER_FILE" ]] ||
    die "a stopped retained Ubuntu update overlay is required"
  assert_only_dependent_overlay ubuntu
  all_shut_off
  (( resume_after_commit )) || assert_consistent_owner
  assert_no_bitcoin_attachments
  assert_no_extra_overlays
  assert_no_process_reference "$OVERLAY"
  assert_no_process_reference "$CANONICAL"
  assert_overlay_chain
  verify_promotion_evidence "$VERIFY_META" overlay
  [[ "$(meta_get "$VERIFY_META" checkpoint_profile_id)" == signet-basic-filter-txindex-v1 ||
     "$(meta_get "$VERIFY_META" checkpoint_profile_id)" == signet-basic-filter-v1 ]] ||
    die "no-rollback commit requires a basic-filter checkpoint profile"
  qemu-img check -r leaks "$OVERLAY"
  qemu-img check "$CANONICAL"
  [[ "$(meta_get "$OVERLAY_META" canonical_id)" == "$(canonical_id)" &&
     "$(meta_get "$OVERLAY_META" checkpoint_generation)" == "$(checkpoint_generation)" ]] ||
    die "Ubuntu overlay no longer belongs to the installed canonical"
  local old_id old_generation new_id new_generation
  old_id="$(canonical_id)"; old_generation="$(checkpoint_generation)"
  new_generation="$(new_id)"
  if (( resume_after_commit )); then
    [[ "$(meta_get "$RECOVERY_META" overlay)" == "$OVERLAY" &&
       "$(meta_get "$RECOVERY_META" old_canonical_id)" == "$old_id" &&
       "$(meta_get "$RECOVERY_META" old_checkpoint_generation)" == "$old_generation" ]] ||
      die "interrupted commit recovery metadata does not match the retained lifecycle"
    local overlay_actual_size
    overlay_actual_size="$(qemu-img info --output=json "$OVERLAY" | jq -r '."actual-size"')"
    (( overlay_actual_size <= 16777216 )) ||
      die "interrupted commit overlay is not empty enough to resume safely"
    note "resuming the verified post-commit cleanup and canonical finalization"
  else
    write_env_file "$RECOVERY_META" "operation=checkpoint-commit-no-rollback" \
      "state=committing" "old_canonical_id=$old_id" \
      "old_checkpoint_generation=$old_generation" "overlay=$OVERLAY" \
      "started=$(date -u +%FT%TZ)"
    unprotect_image "$CANONICAL"
    if ! qemu-img commit -p "$OVERLAY"; then
      protect_image "$CANONICAL" || true
      meta_set "$RECOVERY_META" state commit-failed-canonical-needs-validation
      die "in-place commit failed; overlay was preserved and canonical requires recovery validation"
    fi
    sync -f "$CANONICAL_DIR"
  fi
  unprotect_image "$CANONICAL"
  guestfish_data_disk "$CANONICAL" rm-f /.bvml/ubuntu-verification.env >/dev/null ||
    { protect_image "$CANONICAL" || true
      meta_set "$RECOVERY_META" state transient-cleanup-failed
      die "commit completed but transient evidence cleanup failed; overlay preserved"; }
  qemu-img check "$CANONICAL" >/dev/null ||
    { protect_image "$CANONICAL" || true
      meta_set "$RECOVERY_META" state post-commit-qemu-check-failed
      die "committed canonical failed qemu-img check; overlay preserved"; }
  validate_checkpoint_image "$CANONICAL" ||
    { protect_image "$CANONICAL" || true
      meta_set "$RECOVERY_META" state post-commit-datadir-validation-failed
      die "committed canonical failed datadir validation; overlay preserved"; }
  new_id="$(sha256sum "$CANONICAL" | awk '{print $1}')"
  write_env_file "$CANONICAL_META" \
    "id=$new_id" "generation=$new_generation" "created=$(date -u +%FT%TZ)" \
    "network=signet" "blocksxor=0" "layout=signet-subdir" \
    "kind=knots-rdts-in-place-commit" \
    "knots_version_normalized=$(meta_get "$VERIFY_META" knots_version_normalized)" \
    "checkpoint_profile_id=$(checkpoint_profile_id)" \
    "checkpoint_profile_sha256=${CHECKPOINT_PROFILE_SHA256,,}" \
    "profile_generation_id=$(profile_generation_id)" \
    "profile_generation_digest=$(active_profile_generation_digest)" \
    "release_profile_sha256=${KNOTS_RELEASE_PROFILE_SHA256,,}" \
    "rdts_profile_sha256=${KNOTS_RDTS_PROFILE_SHA256,,}" \
    "filesystem_uuid=$(meta_get "$VERIFY_META" filesystem_uuid)" \
    "block_height=$(meta_get "$VERIFY_META" block_height)" \
    "best_block_hash=$(meta_get "$VERIFY_META" best_block_hash)" \
    "best_block_time=$(meta_get "$VERIFY_META" best_block_time)" \
    "index_state_json=$(meta_get "$VERIFY_META" index_state_json)"
  protect_image "$CANONICAL"
  canonical_preflight
  rm -f -- "$OVERLAY" "$OVERLAY_META" "$VERIFY_META" "$RECOVERY_META"
  sync -f "$CANONICAL_DIR"
  note "committed Ubuntu update in place with no rollback; disaster recovery remains re-IBD"
}

checkpoint_rollback() {
  assert_no_dependent_overlays
  require_canonical; [[ -f "$ROLLBACK" && -f "$ROLLBACK_META" ]] || die "rollback checkpoint is missing"
  all_shut_off; assert_no_bitcoin_attachments
  assert_no_process_reference "$CANONICAL"; assert_no_process_reference "$ROLLBACK"
  validate_checkpoint_image "$ROLLBACK" || die "rollback candidate failed independent validation; canonical unchanged"
  local swap="$CANONICAL_DIR/rollback-swap.qcow2" swapmeta="$CANONICAL_DIR/rollback-swap.env"
  if [[ -n "$ROLLBACK_DESTINATION" ]]; then
    local install_candidate="$CANONICAL_DIR/rollback-install-candidate.qcow2"
    local install_meta="$CANONICAL_DIR/rollback-install-candidate.env"
    cp --reflink=auto --sparse=always "$ROLLBACK" "$install_candidate"
    cp "$ROLLBACK_META" "$install_meta"
    validate_checkpoint_image "$install_candidate" ||
      { rm -f -- "$install_candidate" "$install_meta"; die "local rollback installation candidate invalid"; }
    unprotect_image "$CANONICAL"
    mv -- "$CANONICAL" "$swap"; mv -- "$CANONICAL_META" "$swapmeta"
    mv -- "$install_candidate" "$CANONICAL"; mv -- "$install_meta" "$CANONICAL_META"
    if ! validate_checkpoint_image "$CANONICAL"; then
      mv -- "$CANONICAL" "$install_candidate"; mv -- "$CANONICAL_META" "$install_meta"
      mv -- "$swap" "$CANONICAL"; mv -- "$swapmeta" "$CANONICAL_META"
      protect_image "$CANONICAL"
      write_env_file "$RECOVERY_META" "operation=rollback" "result=automatic-reverse"
      die "external rollback post-install validation failed; previous canonical restored"
    fi
    unprotect_image "$ROLLBACK"
    cp --reflink=auto --sparse=always "$swap" "$ROLLBACK.new"
    cp "$swapmeta" "$ROLLBACK_META.new"
    mv -- "$ROLLBACK.new" "$ROLLBACK"; mv -- "$ROLLBACK_META.new" "$ROLLBACK_META"
    rm -f -- "$swap" "$swapmeta"
    protect_image "$CANONICAL"; protect_image "$ROLLBACK"
    note "canonical and external rollback checkpoints exchanged safely"
    return
  fi
  unprotect_image "$CANONICAL"; unprotect_image "$ROLLBACK"
  mv -- "$CANONICAL" "$swap"; mv -- "$CANONICAL_META" "$swapmeta"
  if ! mv -- "$ROLLBACK" "$CANONICAL"; then mv -- "$swap" "$CANONICAL"; mv -- "$swapmeta" "$CANONICAL_META"; protect_image "$CANONICAL"; die "rollback installation failed"; fi
  mv -- "$ROLLBACK_META" "$CANONICAL_META"; mv -- "$swap" "$ROLLBACK"; mv -- "$swapmeta" "$ROLLBACK_META"
  if ! validate_checkpoint_image "$CANONICAL"; then
    mv -- "$CANONICAL" "$swap.failed"; mv -- "$CANONICAL_META" "$swapmeta.failed"
    mv -- "$ROLLBACK" "$CANONICAL"; mv -- "$ROLLBACK_META" "$CANONICAL_META"
    mv -- "$swap.failed" "$ROLLBACK"; mv -- "$swapmeta.failed" "$ROLLBACK_META"
    protect_image "$CANONICAL"; protect_image "$ROLLBACK"
    write_env_file "$RECOVERY_META" "operation=rollback" "result=automatic-reverse"
    die "rollback post-install validation failed; previous canonical automatically restored"
  fi
  protect_image "$CANONICAL"; protect_image "$ROLLBACK"
  note "canonical and rollback checkpoints exchanged"
}

rollback_remove() {
  [[ "${1:-}" == "--confirm-remove" && $# == 1 ]] || die "rollback-remove requires --confirm-remove"
  assert_no_dependent_overlays
  all_shut_off; assert_no_bitcoin_attachments
  [[ -f "$ROLLBACK" ]] || die "no rollback checkpoint exists"
  assert_no_process_reference "$ROLLBACK"
  validate_checkpoint_image "$ROLLBACK" || die "refusing to remove an invalid image without manual recovery"
  unprotect_image "$ROLLBACK"
  rm -f -- "$ROLLBACK" "$ROLLBACK_META"
  note "obsolete rollback checkpoint removed"
}

recovery_ack() {
  [[ "${1:-}" == --confirm-reviewed && $# == 1 ]] ||
    die "recovery-ack requires --confirm-reviewed after inspecting status and recovery metadata"
  [[ -f "$RECOVERY_META" ]] || die "no recovery metadata exists"
  assert_no_dependent_overlays
  all_shut_off; assert_no_bitcoin_attachments
  [[ ! -f "$CANONICAL" ]] || canonical_preflight
  local operation result
  operation="$(meta_get "$RECOVERY_META" operation)"
  result="$(meta_get "$RECOVERY_META" result)"
  case "$operation:$result" in
    promotion:automatic-restore)
      assert_no_process_reference "$CANONICAL_DIR/promotion-candidate.qcow2"
      rm -f -- "$CANONICAL_DIR/promotion-candidate.qcow2" "$CANONICAL_DIR/promotion-manifest.env"
      ;;
    rollback:automatic-reverse) : ;;
    bootstrap-promotion:source-preserved)
      assert_no_process_reference "$BOOTSTRAP_CANDIDATE"
      rm -f -- "$BOOTSTRAP_CANDIDATE" "$BOOTSTRAP_CANDIDATE_META"
      [[ -f "$BOOTSTRAP" && -f "$BOOTSTRAP_VERIFY" ]] ||
        die "bootstrap recovery source/evidence is missing; do not acknowledge automatically"
      ;;
    *) die "unrecognized recovery state '$operation:$result'; manual forensic review is required" ;;
  esac
  rm -f -- "$RECOVERY_META"
  note "reviewed recovery metadata cleared; valuable canonical/bootstrap/overlay state was preserved"
}

checkpoint_protect() {
  assert_no_dependent_overlays
  all_shut_off
  assert_no_bitcoin_attachments
  protect_image "$CANONICAL"
}

adapter_status() {
  local vm="${1:-}" platform file
  [[ -z "$vm" ]] || valid_vm "$vm"
  [[ -z "$vm" || "$vm" == ubuntu ]] &&
    echo "ubuntu: module=guest/ubuntu-knots-rdts.sh knots=${KNOTS_VERSION_NORMALIZED:-UNCONFIGURED} rdts_profile=${KNOTS_RDTS_PROFILE_NAME:-UNCONFIGURED}"
  for platform in umbrel startos; do
    [[ -z "$vm" || "$vm" == "$platform" ]] || continue
    file="$ADAPTER_STATE_DIR/$platform.json"
    if [[ -f "$file" ]] && jq -e '.last_validation_result == "ok"' "$file" >/dev/null 2>&1; then
      jq -r '"\(.platform): os=\(.os_version) package=\(.package_version) profile=\(.profile_digest) adapter=\(.adapter_implementation_version) validated=\(.validated_at)"' "$file"
    else
      echo "$platform: UNVERIFIED (run adapter-setup and adapter-validate with an exact guest profile)"
    fi
  done
}

adapter_guest_action() {
  local vm="$1" action="$2"; valid_vm "$vm"
  [[ "$vm" != ubuntu ]] || die "Ubuntu uses its Knots bootstrap module, not a platform package adapter"
  [[ "$(owner_vm)" == "$vm" && ! "$(is_shut_off "$vm" && echo yes)" == yes ]] ||
    die "$vm must actively own the overlay"
  local script="/usr/local/libexec/bvml/${vm}-adapter.sh" evidence=/etc/bvml/adapter-verification.json
  # Bitcoin adapter setup waits for tip catch-up; use the platform operation
  # timeout (not the short guest-exec default) so the host does not kill SSH
  # while the guest is still legitimately waiting on IBD/indexes.
  local action_timeout="$GUEST_EXEC_TIMEOUT"
  if [[ "$vm" == umbrel ]]; then
    action_timeout="$UMBREL_OPERATION_TIMEOUT"
    local active_json active64 guest_bvml
    guest_bvml="$(jq -r .os.data_directory "$UMBREL_PROFILE")/.bvml"
    script="$guest_bvml/bin/umbrel-adapter.sh"
    evidence="$guest_bvml/etc/adapter-verification.json"
    active_json="$(jq -n --arg overlay "$(overlay_id)" --arg canonical "$(canonical_id)" \
      --arg generation "$(checkpoint_generation)" \
      --arg serial "$(meta_get "$OVERLAY_META" disk_serial)" \
	      --arg uuid "$(meta_get "$CANONICAL_META" filesystem_uuid)" \
      --arg checkpoint_profile_id "$(meta_get "$CANONICAL_META" checkpoint_profile_id)" \
      --arg checkpoint_profile_sha256 "$(meta_get "$CANONICAL_META" checkpoint_profile_sha256)" \
      --argjson size "$(meta_get "$OVERLAY_META" size_bytes)" \
      --argjson height "$(meta_get "$CANONICAL_META" block_height)" \
      '{overlay_id:$overlay,canonical_id:$canonical,checkpoint_generation:$generation,
        disk_serial:$serial,filesystem_uuid:$uuid,size_bytes:$size,
        expected_minimum_height:$height,checkpoint_profile_id:$checkpoint_profile_id,
        checkpoint_profile_sha256:$checkpoint_profile_sha256}')"
    active64="$(base64 -w0 <<<"$active_json")"
    umbrel_exec_sync /bin/bash 60 -c \
	      "printf %s '$active64' | base64 -d > '$guest_bvml/etc/active-overlay.json'; chown root:root '$guest_bvml/etc/active-overlay.json'; chmod 0600 '$guest_bvml/etc/active-overlay.json'"
  elif [[ "$vm" == startos ]]; then
    action_timeout="$STARTOS_OPERATION_TIMEOUT"
    local active_json active64 startos_guest_root
    startos_guest_root="$(jq -r .os.management_root "$STARTOS_PROFILE")"
    script="$startos_guest_root/bin/startos-adapter.sh"
    evidence="$startos_guest_root/adapter-verification.json"
    active_json="$(jq -n --arg lifecycle "$(overlay_id)" \
      --arg overlay "$(overlay_id)" --arg canonical "$(canonical_id)" \
      --arg generation "$(checkpoint_generation)" \
      --arg serial "$(meta_get "$OVERLAY_META" disk_serial)" \
      --arg uuid "$(meta_get "$STARTOS_LAYER_META" filesystem_uuid)" \
      --arg startos_profile "${STARTOS_PROFILE_SHA256,,}" \
      --argjson size "$(meta_get "$OVERLAY_META" size_bytes)" \
      '{lifecycle_id:$lifecycle,overlay_id:$overlay,canonical_id:$canonical,
        checkpoint_generation:$generation,disk_serial:$serial,
        filesystem_uuid:$uuid,size_bytes:$size,
        startos_profile_sha256:$startos_profile}')"
    active64="$(base64 -w0 <<<"$active_json")"
    startos_exec_sync /bin/bash 60 -c \
      "mountpoint -q /media/startos/data/main; install -d -o root -g root -m 0700 '$startos_guest_root'; printf %s '$active64' | base64 -d > '$startos_guest_root/active-overlay.json'; chown root:root '$startos_guest_root/active-overlay.json'; chmod 0600 '$startos_guest_root/active-overlay.json'"
  fi
  stage_guest_index_identity "$vm"
  if ! (platform_exec_sync "$vm" "$script" "$action_timeout" "$action"); then
    write_env_file "$ADAPTER_RECOVERY_META" "operation=adapter-$action" "vm=$vm" \
      "image=$OVERLAY" "result=recovery-required" "recorded=$(date -u +%FT%TZ)"
    meta_set "$OVERLAY_META" recovery_required 1
    meta_set "$OVERLAY_META" adapter_state failed
    die "$vm adapter $action failed; active state and diagnostics were preserved"
  fi
  if ! (index_adapter_guest_action "$vm" "$action"); then
    write_env_file "$ADAPTER_RECOVERY_META" "operation=index-adapter-$action" "vm=$vm" \
      "image=$OVERLAY" "result=recovery-required" "recorded=$(date -u +%FT%TZ)"
    meta_set "$OVERLAY_META" recovery_required 1
    meta_set "$OVERLAY_META" adapter_state failed
    die "$vm index adapter $action failed; all overlays and diagnostics were preserved"
  fi
  if [[ "$action" != verify ]] &&
     ! (platform_exec_sync "$vm" "$script" "$action_timeout" verify); then
    write_env_file "$ADAPTER_RECOVERY_META" "operation=adapter-verify" "vm=$vm" \
      "image=$OVERLAY" "result=recovery-required" "recorded=$(date -u +%FT%TZ)"
    meta_set "$OVERLAY_META" recovery_required 1
    meta_set "$OVERLAY_META" adapter_state failed
    die "$vm post-setup verification failed; active state and diagnostics were preserved"
  fi
  platform_exec_sync "$vm" /bin/cat 30 "$evidence"
  local tmp="$ADAPTER_STATE_DIR/$vm.json.new"
  printf '%s\n' "$GUEST_EXEC_STDOUT" >"$tmp"
  jq -e --arg platform "$vm" '
    .platform == $platform and .last_validation_result == "ok" and
    ([.os_version,.package_version,.profile_digest,.knots_binary_digest,
      .adapter_implementation_version,.validated_at] | all(type == "string" and length > 0))
  ' "$tmp" >/dev/null || { rm -f -- "$tmp"; die "$vm returned invalid adapter verification metadata"; }
  chmod 0600 "$tmp"
  mv -- "$tmp" "$ADAPTER_STATE_DIR/$vm.json"
  meta_set "$OVERLAY_META" mount_state mounted
  meta_set "$OVERLAY_META" adapter_state validated
  meta_set "$OVERLAY_META" recovery_required 0
  rm -f -- "$ADAPTER_RECOVERY_META"
  note "$vm adapter $action completed and verified guest profile metadata was recorded"
}

validate_all() { exec "$ROOT/scripts/vm/validate.sh"; }
status_all() { exec "$ROOT/scripts/vm/status.sh"; }

case "$command" in
  init) with_global_lock note "storage initialized at $BVML_STORAGE" ;;
  create) with_vm_lock "${1:?VM required}" "$ROOT/scripts/vm/create.sh" "$1" ;;
  create-resume) with_vm_lock "${1:?VM required}" "$ROOT/scripts/vm/create-resume.sh" "$1" ;;
  start) with_vm_lock "${1:?VM required}" start_vm "$@" ;;
  resume) with_vm_lock "${1:?VM required}" resume_vm "$@" ;;
  stop) with_vm_lock "${1:?VM required}" stop_vm "$1" ;;
  discard) with_vm_lock "${1:?VM required}" discard_overlay "$1" ;;
  reset) with_vm_lock "${1:?VM required}" reset_vm "$1" ;;
  reconcile)
    if (($#)); then
      with_vm_lock "$1" reconcile_owner "$1"
    else
      for vm in ubuntu umbrel startos; do with_vm_lock "$vm" reconcile_owner "$vm"; done
    fi
    ;;
  checkpoint-bootstrap) with_global_lock checkpoint_bootstrap ;;
  bootstrap-init) with_global_lock bootstrap_init "$@" ;;
  bootstrap-stop) with_global_lock bootstrap_stop ;;
  bootstrap-verify) with_global_lock bootstrap_verify ;;
  bootstrap-promote) with_global_lock bootstrap_promote "$@" ;;
  bootstrap-cleanup) with_global_lock bootstrap_cleanup ;;
  bootstrap-status) status_all ;;
  checkpoint-import) with_global_lock checkpoint_import "$@" ;;
  checkpoint-sync-start) with_vm_lock ubuntu checkpoint_sync_start "$@" ;;
  checkpoint-profile-migrate-guest) with_vm_lock ubuntu checkpoint_profile_migrate_guest "$@" ;;
  checkpoint-sync-finish) with_vm_lock ubuntu checkpoint_sync_finish "$@" ;;
  checkpoint-verify) with_vm_lock ubuntu checkpoint_verify ;;
  checkpoint-promote) with_global_lock checkpoint_promote "$@" ;;
  checkpoint-commit) with_global_lock checkpoint_commit_no_rollback "$@" ;;
  checkpoint-protect) with_global_lock checkpoint_protect ;;
  checkpoint-rollback) with_global_lock checkpoint_rollback ;;
  rollback-remove) with_global_lock rollback_remove "$@" ;;
  recovery-ack) with_global_lock recovery_ack "$@" ;;
  adapter-setup) with_vm_lock "${1:?VM required}" adapter_guest_action "$1" setup ;;
  adapter-validate) with_vm_lock "${1:?VM required}" adapter_guest_action "$1" verify ;;
  index-adapter-setup) with_vm_lock "${1:?VM required}" index_adapter_guest_action "$1" setup ;;
  index-adapter-validate) with_vm_lock "${1:?VM required}" index_adapter_guest_action "$1" verify ;;
  adapter-status) adapter_status "${1:-}" ;;
  validate) with_all_vm_locks validate_all ;;
  status) status_all ;;
  *) die "unknown command: $command" ;;
esac
