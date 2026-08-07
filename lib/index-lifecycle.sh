#!/usr/bin/env bash
set -Eeuo pipefail

# The caller must source lib/common.sh first and hold the selected VM lifecycle
# lock for per-VM operations or the global lock for base mutation.

index_image_size_gib() {
  case "$1" in
    electrs) printf '%s' "$ELECTRS_BASE_SIZE_GIB" ;;
    fulcrum) printf '%s' "$FULCRUM_BASE_SIZE_GIB" ;;
    *) valid_index_service "$1" ;;
  esac
}

index_profile_id() { jq -er .profile_id "$INDEX_PROFILE"; }
index_database_layout() { jq -er --arg service "$1" '.[$service].database_layout' "$INDEX_PROFILE"; }

index_attach_image() {
  local vm="$1" service="$2" image="$3" serial="$4"
  local target existing
  target="$(index_target "$service")"
  existing="$(virshq domblklist "$(domain "$vm")" --details 2>/dev/null |
    awk -v target="$target" 'NR>2 && $3 == target {print $4; exit}')"
  [[ -z "$existing" || "$existing" == "-" ]] ||
    die "$(domain "$vm") target $target is already occupied by $existing"
  [[ -z "$(attached_vm_for_path "$image")" ]] ||
    die "$service image is already attached to a domain"
  virshq attach-disk "$(domain "$vm")" "$image" "$target" --config \
    --driver qemu --subdriver qcow2 --targetbus virtio --serial "$serial"
  [[ "$(target_for_source "$vm" "$image")" == "$target" &&
     "$(attachment_serial_for_path "$vm" "$image")" == "$serial" ]] ||
    die "$vm $service attachment identity verification failed"
}

index_detach_image() {
  local vm="$1" image="$2" target
  target="$(target_for_source "$vm" "$image")"
  [[ -z "$target" ]] || virshq detach-disk "$(domain "$vm")" "$target" --config
  [[ -z "$(attached_vm_for_path "$image")" ]] ||
    die "$vm index image remains attached after detach"
  assert_no_process_reference "$image"
}

create_index_bootstrap() {
  local service="$1" image meta id serial nonce size_gib size_bytes
  valid_index_service "$service"; validate_index_profile; canonical_preflight
  # Attachment is persistent domain XML only. Creating while Ubuntu is running
  # leaves the disk detached until the next clean stop/resume cycle.
  if is_defined ubuntu && [[ "$(domain_state ubuntu)" != "shut off" ]]; then
    die "$service bootstrap must be created while Ubuntu is exactly shut off so resume can attach it"
  fi
  image="$(index_bootstrap "$service")"; meta="$(index_bootstrap_meta "$service")"
  [[ ! -e "$(index_base "$service")" && ! -e "$(index_base_meta "$service")" ]] ||
    die "$service protected base already exists"
  [[ ! -e "$image" && ! -e "$meta" && ! -e "$(index_bootstrap_verify "$service")" ]] ||
    die "$service bootstrap state already exists"
  local vm
  for vm in ubuntu umbrel startos; do
    [[ ! -e "$(index_overlay "$vm" "$service")" &&
       ! -e "$(index_overlay_meta "$vm" "$service")" ]] ||
      die "$vm retains a $service overlay"
  done
  id="$(new_id)"; serial="$(index_serial_prefix "$service")-${id:0:12}"
  nonce="$(new_id)"; size_gib="$(index_image_size_gib "$service")"
  size_bytes=$((size_gib * 1073741824))
  qemu-img create -f qcow2 "$image" "${size_gib}G"
  chmod 0640 "$image"
  if [[ "${BVML_TESTING:-0}" != 1 ]]; then
    setfacl -m "u:$QEMU_USER:rw-" "$image" ||
      { rm -f -- "$image"; die "could not grant QEMU access to $service bootstrap"; }
  fi
  write_env_file "$meta" \
    "kind=index-bootstrap" "service=$service" "id=$id" \
    "created=$(date -u +%FT%TZ)" "size_bytes=$size_bytes" \
    "disk_serial=$serial" "bootstrap_nonce=$nonce" \
    "filesystem_initialized=0" "state=created" \
    "bitcoin_canonical_id=$(canonical_id)" \
    "bitcoin_checkpoint_generation=$(checkpoint_generation)" \
    "profile_id=$(index_profile_id)" "profile_sha256=${INDEX_PROFILE_SHA256,,}" \
    "database_layout=$(index_database_layout "$service")"
  note "created incomplete $service bootstrap; resume Ubuntu, then run index-bootstrap-init"
}

create_index_overlay() {
  local vm="$1" service="$2" image meta base id serial
  index_supported_for_vm "$vm" "$service" ||
    die "$service is unsupported on $vm"
  index_base_preflight "$service"
  image="$(index_overlay "$vm" "$service")"
  meta="$(index_overlay_meta "$vm" "$service")"
  base="$(index_base "$service")"
  [[ ! -e "$image" && ! -e "$meta" ]] || die "$vm retains a $service overlay"
  id="$(new_id)"; serial="$(index_serial_prefix "$service")-${id:0:12}"
  qemu-img create -f qcow2 -F qcow2 -b "$base" "$image"
  chmod 0640 "$image"
  if [[ "${BVML_TESTING:-0}" != 1 ]]; then
    setfacl -m "u:$QEMU_USER:rw-" "$image" ||
      { rm -f -- "$image"; die "could not grant QEMU access to $vm $service overlay"; }
  fi
  write_env_file "$meta" \
    "kind=index-overlay" "vm=$vm" "service=$service" "overlay_id=$id" \
    "base=$(index_base "$service")" \
    "base_id=$(meta_get "$(index_base_meta "$service")" id)" \
    "bitcoin_canonical_id=$(canonical_id)" \
    "bitcoin_checkpoint_generation=$(checkpoint_generation)" \
    "profile_id=$(index_profile_id)" "profile_sha256=${INDEX_PROFILE_SHA256,,}" \
    "disk_serial=$serial" \
    "filesystem_uuid=$(meta_get "$(index_base_meta "$service")" filesystem_uuid)" \
    "created=$(date -u +%FT%TZ)" "owner_state=retained" \
    "attachment_state=detached" "mount_state=unmounted" \
    "adapter_state=pending" "recovery_required=0"
}

prepare_missing_index_overlays() {
  local vm="$1" service
  while read -r service; do
    [[ -f "$(index_base "$service")" || -f "$(index_base_meta "$service")" ]] || continue
    if [[ -e "$(index_overlay "$vm" "$service")" ||
       -e "$(index_overlay_meta "$vm" "$service")" ]]; then
      index_overlay_preflight "$vm" "$service"
    else
      create_index_overlay "$vm" "$service"
    fi
  done < <(index_services_for_vm "$vm")
}

attach_retained_indexes() {
  local vm="$1" service image meta
  while read -r service; do
    image="$(index_overlay "$vm" "$service")"
    meta="$(index_overlay_meta "$vm" "$service")"
    [[ -e "$image" || -e "$meta" ]] || continue
    index_overlay_preflight "$vm" "$service"
    index_attach_image "$vm" "$service" "$image" "$(meta_get "$meta" disk_serial)"
    meta_set "$meta" owner_state active
    meta_set "$meta" attachment_state attached
  done < <(index_services_for_vm "$vm")
  if [[ "$vm" == ubuntu ]]; then
    while read -r service; do
      image="$(index_bootstrap "$service")"; meta="$(index_bootstrap_meta "$service")"
      [[ -e "$image" || -e "$meta" ]] || continue
      [[ -f "$image" && -f "$meta" &&
         "$(meta_get "$meta" bitcoin_canonical_id)" == "$(canonical_id)" &&
         "$(meta_get "$meta" bitcoin_checkpoint_generation)" == "$(checkpoint_generation)" ]] ||
        die "$service bootstrap state is incomplete or stale"
      index_attach_image ubuntu "$service" "$image" "$(meta_get "$meta" disk_serial)"
      meta_set "$meta" state attached
    done < <(printf '%s\n' electrs fulcrum)
  fi
}

detach_retained_indexes() {
  local vm="$1" service image meta
  while read -r service; do
    image="$(index_overlay "$vm" "$service")"
    meta="$(index_overlay_meta "$vm" "$service")"
    [[ -e "$image" || -e "$meta" ]] || continue
    index_detach_image "$vm" "$image"
    meta_set "$meta" owner_state retained
    meta_set "$meta" attachment_state detached
    meta_set "$meta" mount_state unmounted
    meta_set "$meta" adapter_state stopped
  done < <(index_services_for_vm "$vm")
  if [[ "$vm" == ubuntu ]]; then
    while read -r service; do
      image="$(index_bootstrap "$service")"; meta="$(index_bootstrap_meta "$service")"
      [[ -e "$image" || -e "$meta" ]] || continue
      index_detach_image ubuntu "$image"
      [[ "$(meta_get "$meta" state)" != attached ]] || meta_set "$meta" state retained
    done < <(printf '%s\n' electrs fulcrum)
  fi
}

rollback_index_attachments() {
  local vm="$1" service image meta
  while read -r service; do
    for image in "$(index_overlay "$vm" "$service")" \
      "$([[ "$vm" == ubuntu ]] && index_bootstrap "$service" || true)"; do
      [[ -n "$image" && -f "$image" ]] || continue
      if [[ -n "$(attached_vm_for_path "$image")" ]]; then
        index_detach_image "$vm" "$image" || true
      fi
    done
    meta="$(index_overlay_meta "$vm" "$service")"
    [[ ! -f "$meta" ]] || {
      meta_set "$meta" owner_state retained
      meta_set "$meta" attachment_state detached
    }
  done < <(index_services_for_vm "$vm")
}

discard_index_overlays() {
  local vm="$1" service image meta
  is_shut_off "$vm" || die "$vm must be exactly shut off"
  while read -r service; do
    image="$(index_overlay "$vm" "$service")"; meta="$(index_overlay_meta "$vm" "$service")"
    [[ -e "$image" || -e "$meta" ]] || continue
    [[ -f "$image" && -f "$meta" ]] || die "$vm $service overlay state is partial"
    [[ -z "$(attached_vm_for_path "$image")" ]] || die "$vm $service overlay remains attached"
    assert_no_process_reference "$image"
    rm -f -- "$image" "$meta" "$(index_recovery "$vm" "$service")"
  done < <(index_services_for_vm "$vm")
}

index_active_json() {
  local vm="$1" service meta base_meta result='{}' entry tip
  while read -r service; do
    meta="$(index_overlay_meta "$vm" "$service")"
    [[ -f "$meta" ]] || continue
    base_meta="$(index_base_meta "$service")"
    tip="$(meta_get "$base_meta" tip_height)"
    [[ "$tip" =~ ^[0-9]+$ ]] || tip=0
    entry="$(jq -n --arg id "$(meta_get "$meta" overlay_id)" --arg kind overlay \
      --arg serial "$(meta_get "$meta" disk_serial)" \
      --arg uuid "$(meta_get "$meta" filesystem_uuid)" \
      --arg base_id "$(meta_get "$meta" base_id)" \
      --arg binary "$(meta_get "$base_meta" binary_sha256)" \
      --arg canonical "$(meta_get "$meta" bitcoin_canonical_id)" \
      --arg generation "$(meta_get "$meta" bitcoin_checkpoint_generation)" \
      --argjson size "$(qemu_img_info_json "$(index_overlay "$vm" "$service")" |
        jq -r '.["virtual-size"]')" \
      --argjson base_tip_height "$tip" \
      '{id:$id,kind:$kind,disk_serial:$serial,filesystem_uuid:$uuid,
        size_bytes:$size,base_id:$base_id,binary_sha256:$binary,
        base_tip_height:$base_tip_height,
        bitcoin_canonical_id:$canonical,bitcoin_checkpoint_generation:$generation}')"
    result="$(jq --arg service "$service" --argjson entry "$entry" \
      '.services[$service]=$entry' <<<"$result")"
  done < <(index_services_for_vm "$vm")
  printf '%s\n' "$result"
}
