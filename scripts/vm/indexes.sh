#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/index-lifecycle.sh"
command="${1:?command required}"; shift

ubuntu_index_script=/usr/local/libexec/bvml/ubuntu-indexers.sh

require_active_ubuntu() {
  set_lifecycle_context ubuntu
  [[ "$(domain_state ubuntu)" == running &&
     "$(owner_vm)" == ubuntu &&
     "$(attached_vm_for_path "$OVERLAY" | paste -sd, -)" == ubuntu ]] ||
    die "Ubuntu must actively own its Bitcoin overlay"
}

stage_bootstrap_identity() {
  local service="$1" meta image json
  meta="$(index_bootstrap_meta "$service")"; image="$(index_bootstrap "$service")"
  [[ -f "$meta" && -f "$image" ]] || die "$service bootstrap is absent"
  [[ "$(attached_vm_for_path "$image" | paste -sd, -)" == ubuntu ]] ||
    die "$service bootstrap is not attached exclusively to Ubuntu"
  json="$(jq -n --arg service "$service" \
    --arg id "$(meta_get "$meta" id)" \
    --arg kind bootstrap \
    --arg serial "$(meta_get "$meta" disk_serial)" \
    --arg nonce "$(meta_get "$meta" bootstrap_nonce)" \
    --arg canonical "$(canonical_id)" \
    --arg generation "$(checkpoint_generation)" \
    --argjson size "$(meta_get "$meta" size_bytes)" \
    '{services:{($service):{id:$id,kind:$kind,disk_serial:$serial,nonce:$nonce,
      size_bytes:$size,bitcoin_canonical_id:$canonical,
      bitcoin_checkpoint_generation:$generation}}}')"
  guest_exec_sync ubuntu "$ubuntu_index_script" 60 stage "$service" "$json"
}

bootstrap_init() {
  local service="${1:?service required}"
  [[ "${2:-}" == --confirm-index-format && $# == 2 ]] ||
    die "usage: bvml index-bootstrap-init SERVICE --confirm-index-format"
  valid_index_service "$service"; require_active_ubuntu
  stage_bootstrap_identity "$service"
  guest_exec_sync ubuntu "$ubuntu_index_script" 600 init "$service" --confirm-index-format
  local device uuid
  device="$(index_device "$service")"
  guest_exec_sync ubuntu /bin/bash 30 -c \
    "blkid -s UUID -o value '$device'"
  uuid="$(tr -d '[:space:]' <<<"$GUEST_EXEC_STDOUT")"
  [[ "$uuid" =~ ^[0-9a-fA-F-]{16,64}$ ]] || die "$service filesystem UUID was not returned"
  meta_set "$(index_bootstrap_meta "$service")" filesystem_uuid "$uuid"
  meta_set "$(index_bootstrap_meta "$service")" filesystem_initialized 1
  meta_set "$(index_bootstrap_meta "$service")" state initialized
}

stage_runtime_identity() {
  local service="$1" kind="${2:-bootstrap}" meta image id uuid json
  if [[ "$kind" == bootstrap ]]; then
    meta="$(index_bootstrap_meta "$service")"; image="$(index_bootstrap "$service")"
    id="$(meta_get "$meta" id)"
  else
    meta="$(index_overlay_meta ubuntu "$service")"; image="$(index_overlay ubuntu "$service")"
    id="$(meta_get "$meta" overlay_id)"
  fi
  [[ -f "$meta" && -f "$image" ]] || die "$service $kind state is absent"
  uuid="$(meta_get "$meta" filesystem_uuid)"
  [[ -n "$uuid" ]] || die "$service $kind filesystem has not been initialized"
  json="$(jq -n --arg service "$service" --arg id "$id" --arg kind "$kind" \
    --arg serial "$(meta_get "$meta" disk_serial)" --arg uuid "$uuid" \
    --arg nonce "$(meta_get "$meta" bootstrap_nonce)" \
    --arg canonical "$(canonical_id)" --arg generation "$(checkpoint_generation)" \
    --argjson size "$(qemu_img_info_json "$image" | jq -r '.["virtual-size"]')" \
    '{services:{($service):{id:$id,kind:$kind,disk_serial:$serial,nonce:$nonce,
      filesystem_uuid:$uuid,size_bytes:$size,bitcoin_canonical_id:$canonical,
      bitcoin_checkpoint_generation:$generation}}}')"
  guest_exec_sync ubuntu "$ubuntu_index_script" 60 stage "$service" "$json"
}

bootstrap_start() {
  local service="${1:?service required}"
  valid_index_service "$service"; require_active_ubuntu
  [[ "$(meta_get "$(index_bootstrap_meta "$service")" filesystem_initialized)" == 1 ]] ||
    die "$service bootstrap filesystem is not initialized"
  stage_runtime_identity "$service" bootstrap
  guest_exec_sync ubuntu "$ubuntu_index_script" "$GUEST_EXEC_TIMEOUT" start "$service"
  meta_set "$(index_bootstrap_meta "$service")" state indexing
}

bootstrap_verify() {
  local service="${1:?service required}" output tmp
  valid_index_service "$service"; require_active_ubuntu
  stage_runtime_identity "$service" bootstrap
  guest_exec_sync ubuntu "$ubuntu_index_script" "$INDEX_BUILD_TIMEOUT" verify-stop "$service"
  output="$GUEST_EXEC_STDOUT"; tmp="$(index_bootstrap_verify "$service").new"
  # Guest scripts may emit log lines before the final evidence object.
  if ! printf '%s\n' "$output" | jq -e --arg service "$service" --arg id "$(meta_get "$(index_bootstrap_meta "$service")" id)" '
      select(type=="object") |
      .service==$service and .index_id==$id and .synchronized==true and
      .clean_shutdown==true and (.binary_sha256|test("^[0-9a-f]{64}$")) and
      (.height|type=="number" and .>0)
    ' >/dev/null 2>&1; then
    # Extract the last complete JSON object from mixed stdout.
    printf '%s\n' "$output" | awk '
      BEGIN{obj=""}
      /^\{/{obj=$0; next}
      { if(obj!="") obj=obj"\n"$0 }
      END{ if(obj!="") print obj }
    ' >"$tmp"
  else
    printf '%s\n' "$output" | jq -c --arg service "$service" --arg id "$(meta_get "$(index_bootstrap_meta "$service")" id)" '
      select(type=="object") |
      select(.service==$service and .index_id==$id and .synchronized==true and
        .clean_shutdown==true)
    ' | tail -1 >"$tmp"
  fi
  jq -e --arg service "$service" --arg id "$(meta_get "$(index_bootstrap_meta "$service")" id)" '
    .service==$service and .index_id==$id and .synchronized==true and
    .clean_shutdown==true and (.binary_sha256|test("^[0-9a-f]{64}$")) and
    (.height|type=="number" and .>0)
  ' "$tmp" >/dev/null || { rm -f "$tmp"; die "$service returned invalid bootstrap evidence"; }
  mv "$tmp" "$(index_bootstrap_verify "$service")"
  meta_set "$(index_bootstrap_meta "$service")" state verified
  note "$service bootstrap is synchronized and cleanly stopped; stop Ubuntu before promotion"
}

bootstrap_promote() {
  local service="${1:?service required}" image meta evidence base base_meta tmp id
  [[ "${2:-}" == --confirm-index-synced && $# == 2 ]] ||
    die "usage: bvml index-bootstrap-promote SERVICE --confirm-index-synced"
  valid_index_service "$service"; is_shut_off ubuntu ||
    die "Ubuntu must be exactly shut off"
  image="$(index_bootstrap "$service")"; meta="$(index_bootstrap_meta "$service")"
  evidence="$(index_bootstrap_verify "$service")"
  base="$(index_base "$service")"; base_meta="$(index_base_meta "$service")"
  [[ -f "$image" && -f "$meta" && -f "$evidence" &&
     "$(meta_get "$meta" state)" == verified ]] ||
    die "$service requires a verified retained bootstrap"
  [[ -z "$(attached_vm_for_path "$image")" ]] || die "$service bootstrap remains attached"
  assert_no_process_reference "$image"
  qemu-img check "$image" >/dev/null
  [[ -z "$(qemu-img info --output=json "$image" | jq -r '.["backing-filename"] // empty')" ]] ||
    die "$service bootstrap is not standalone"
  [[ "$(jq -r .filesystem_uuid "$evidence")" == "$(meta_get "$meta" filesystem_uuid)" &&
     "$(jq -r .bitcoin_canonical_id "$evidence")" == "$(canonical_id)" &&
     "$(jq -r .bitcoin_checkpoint_generation "$evidence")" == "$(checkpoint_generation)" ]] ||
    die "$service evidence does not match current storage identity"
  id="$(sha256sum "$image" | awk '{print $1}')"
  tmp="$base_meta.new"
  write_env_file "$tmp" "id=$id" "service=$service" "created=$(date -u +%FT%TZ)" \
    "bitcoin_canonical_id=$(canonical_id)" \
    "bitcoin_checkpoint_generation=$(checkpoint_generation)" \
    "filesystem=btrfs" "filesystem_uuid=$(meta_get "$meta" filesystem_uuid)" \
    "profile_id=$(index_profile_id)" "profile_sha256=${INDEX_PROFILE_SHA256,,}" \
    "version=$(jq -r --arg s "$service" '.[$s].version' "$INDEX_PROFILE")" \
    "image=$(jq -r --arg s "$service" '.[$s].ubuntu.image' "$INDEX_PROFILE")" \
    "binary_sha256=$(jq -r .binary_sha256 "$evidence")" \
    "tip_height=$(jq -r .height "$evidence")" \
    "tip_hash=$(meta_get "$CANONICAL_META" best_block_hash)" \
    "database_layout=$(index_database_layout "$service")"
  mv "$image" "$base"; mv "$tmp" "$base_meta"
  if ! (protect_image "$base" && index_base_preflight "$service"); then
    unprotect_image "$base" || true
    mv "$base" "$image"; rm -f "$base_meta"
    die "$service base installation failed; verified bootstrap image was restored"
  fi
  rm -f "$meta" "$evidence"
  note "installed protected $service base bound to Bitcoin generation $(checkpoint_generation)"
}

prepare_vm() {
  local vm="${1:?VM required}"; valid_vm "$vm"
  is_shut_off "$vm" || die "$vm must be exactly shut off"
  prepare_missing_index_overlays "$vm"
  note "prepared retained index overlays for $vm"
}

discard_vm() {
  local vm="${1:?VM required}"; valid_vm "$vm"
  discard_index_overlays "$vm"
  note "discarded only $vm index overlays"
}

status_indexes() {
  local service vm base meta overlay ometa
  validate_index_profile
  echo "index-profile: $(index_profile_id) ${INDEX_PROFILE_SHA256,,}"
  for service in electrs fulcrum; do
    base="$(index_base "$service")"; meta="$(index_base_meta "$service")"
    if [[ -f "$base" && -f "$meta" ]]; then
      echo "$service-base: ready id=$(meta_get "$meta" id) height=$(meta_get "$meta" tip_height) generation=$(meta_get "$meta" bitcoin_checkpoint_generation)"
    elif [[ -f "$(index_bootstrap "$service")" || -f "$(index_bootstrap_meta "$service")" ]]; then
      echo "$service-base: bootstrap state=$(meta_get "$(index_bootstrap_meta "$service")" state)"
    else
      echo "$service-base: absent"
    fi
    for vm in ubuntu umbrel startos; do
      index_supported_for_vm "$vm" "$service" || continue
      overlay="$(index_overlay "$vm" "$service")"; ometa="$(index_overlay_meta "$vm" "$service")"
      [[ -e "$overlay" || -e "$ometa" ]] || continue
      echo "  $vm: $(meta_get "$ometa" attachment_state) overlay_id=$(meta_get "$ometa" overlay_id) attached=$(attached_vm_for_path "$overlay" | paste -sd, -)"
    done
  done
}

case "$command" in
  bootstrap-create) with_global_lock create_index_bootstrap "${1:?service required}" ;;
  bootstrap-init) with_vm_lock ubuntu bootstrap_init "$@" ;;
  bootstrap-start) with_vm_lock ubuntu bootstrap_start "$@" ;;
  bootstrap-verify) with_vm_lock ubuntu bootstrap_verify "$@" ;;
  bootstrap-promote) with_global_lock bootstrap_promote "$@" ;;
  prepare) with_vm_lock "${1:?VM required}" prepare_vm "$1" ;;
  discard) with_vm_lock "${1:?VM required}" discard_vm "$1" ;;
  status) status_indexes ;;
  *) die "unknown index command: $command" ;;
esac
