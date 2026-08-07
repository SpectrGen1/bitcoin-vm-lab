#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/lib/common.sh"

echo "storage: $BVML_STORAGE"
if [[ -f "$CANONICAL" ]]; then
  echo "canonical: ready id=$(canonical_id) generation=$(checkpoint_generation) profile=$(meta_get "$CANONICAL_META" checkpoint_profile_id)"
  qemu-img info --backing-chain "$CANONICAL" 2>/dev/null | sed 's/^/  /'
else
  echo "canonical: not initialized"
fi
if [[ -f "$STARTOS_LAYER" && -f "$STARTOS_LAYER_META" ]]; then
  echo "startos-btrfs-adapter: state=$(meta_get "$STARTOS_LAYER_META" state) id=$(meta_get "$STARTOS_LAYER_META" id) filesystem=$(meta_get "$STARTOS_LAYER_META" filesystem) allocation=$(meta_get "$STARTOS_LAYER_META" allocation_bytes)"
  qemu-img info --backing-chain "$STARTOS_LAYER" 2>/dev/null | sed 's/^/  /'
elif [[ -e "$STARTOS_LAYER_CANDIDATE" || -e "$STARTOS_LAYER_CANDIDATE_META" ||
        -e "$STARTOS_LAYER_RECOVERY" ]]; then
  echo "startos-btrfs-adapter: conversion/recovery state present"
else
  echo "startos-btrfs-adapter: absent"
fi

if [[ -f "$BOOTSTRAP" || -f "$BOOTSTRAP_META" ]]; then
  echo "bootstrap: state=$(meta_get "$BOOTSTRAP_META" state) id=$(meta_get "$BOOTSTRAP_META" bootstrap_id)"
else
  echo "bootstrap: absent"
fi
[[ -f "$IMPORT_CANDIDATE" || -f "$IMPORT_META" ]] &&
  echo "import: candidate or partial state present" || echo "import: absent"
if [[ "$ROLLBACK_RETENTION" == none ]]; then
  echo "rollback: disabled by storage policy"
  echo "disaster recovery: re-IBD"
elif [[ -f "$ROLLBACK" ]]; then
  echo "rollback: available id=$(meta_get "$ROLLBACK_META" id) generation=$(meta_get "$ROLLBACK_META" generation)"
else
  echo "rollback: absent"
fi

echo "lifecycles:"
for vm in ubuntu umbrel startos; do
  overlay="$(lifecycle_overlay "$vm")"; meta="$(lifecycle_meta "$vm")"
  owner_file="$(lifecycle_owner "$vm")"; verify="$(lifecycle_verify "$vm")"
  recovery="$(lifecycle_recovery "$vm")"
  state=undefined; is_defined "$vm" && state="$(domain_state "$vm")"
  if [[ -f "$overlay" || -f "$meta" ]]; then
    [[ -f "$owner_file" ]] && phase=active || phase=retained
    printf '  %s: %s state=%s overlay_id=%s generation=%s owner=%s attached=%s mount=%s adapter=%s recovery=%s verification=%s\n' \
      "$vm" "$phase" "$state" "$(overlay_id "$meta")" \
      "$(meta_get "$meta" checkpoint_generation)" "$(owner_vm "$owner_file")" \
      "$(attached_vm_for_path "$overlay" | paste -sd, -)" \
      "$(meta_get "$meta" mount_state)" "$(meta_get "$meta" adapter_state)" \
      "$([[ -f "$recovery" ]] && echo required || echo none)" \
      "$([[ -f "$verify" ]] && echo present || echo absent)"
    if info="$(qemu_img_info_json "$overlay" 2>/dev/null)"; then
      jq -r '"    format=\(.format) virtual_size=\(.["virtual-size"]) actual_size=\(.["actual-size"]) backing=\(.["backing-filename"] // "none")"' \
        <<<"$info"
    else
      echo "    image-info=unavailable"
    fi
  else
    printf '  %s: absent state=%s recovery=%s\n' "$vm" "$state" \
      "$([[ -f "$recovery" ]] && echo required || echo none)"
  fi
done

if is_defined startos && [[ "$(domain_state startos)" != "shut off" ]]; then
  echo "startos-native:"
  startos_adapter="$(jq -r .os.management_root "$STARTOS_PROFILE")/bin/startos-adapter.sh"
  if observation="$(startos_exec_sync "$startos_adapter" 30 observe 2>/dev/null)"; then
    jq -r '"  desired=\(.desired_state) actual=\(.actual_state) lxc=\(.lxc_state) subcontainer=\(.subcontainer_state) native_source=\(.native_volume_source) private_uuid=\(.private_uuid) managed_uuid=\(.managed_uuid)"' \
      <<<"$observation"
  else
    echo "  unavailable (management transport or native adapter observation failed)"
  fi
fi

echo "attachments:"
attachments="$(all_attached_pairs)"
if [[ -n "$attachments" ]]; then
  while IFS=$'\t' read -r vm image; do
    printf '  domain=%s image=%s\n' "$(domain "$vm")" "$image"
  done <<<"$attachments"
else
  echo "  none"
fi

echo "electrum-indexes:"
if validate_index_profile >/dev/null 2>&1; then
  echo "  profile: $(jq -r .profile_id "$INDEX_PROFILE") ${INDEX_PROFILE_SHA256,,}"
else
  echo "  profile: INVALID"
fi
for service in electrs fulcrum; do
  base="$(index_base "$service")"; meta="$(index_base_meta "$service")"
  if [[ -f "$base" && -f "$meta" ]]; then
    echo "  $service-base: ready id=$(meta_get "$meta" id) height=$(meta_get "$meta" tip_height) generation=$(meta_get "$meta" bitcoin_checkpoint_generation)"
  elif [[ -e "$(index_bootstrap "$service")" || -e "$(index_bootstrap_meta "$service")" ]]; then
    echo "  $service-base: bootstrap state=$(meta_get "$(index_bootstrap_meta "$service")" state)"
  else
    echo "  $service-base: absent"
  fi
  for vm in ubuntu umbrel startos; do
    index_supported_for_vm "$vm" "$service" || continue
    image="$(index_overlay "$vm" "$service")"
    imeta="$(index_overlay_meta "$vm" "$service")"
    [[ -e "$image" || -e "$imeta" ]] || continue
    echo "    $vm: state=$(meta_get "$imeta" attachment_state) overlay_id=$(meta_get "$imeta" overlay_id) attached=$(attached_vm_for_path "$image" | paste -sd, -)"
  done
done
index_attachments="$(all_index_attached_pairs)"
if [[ -n "$index_attachments" ]]; then
  echo "  attachments:"
  while IFS=$'\t' read -r vm service image; do
    echo "    $service -> $vm ($image)"
  done <<<"$index_attachments"
else
  echo "  attachments: none"
fi

errors="$(lifecycle_invariant_errors)"
if [[ -f "$CANONICAL" ]] && ! canonical_error="$(canonical_preflight 2>&1)"; then
  errors="${errors}${errors:+$'\n'}canonical preflight failed: ${canonical_error#*: }"
fi
for vm in ubuntu umbrel startos; do
  overlay="$(lifecycle_overlay "$vm")"; meta="$(lifecycle_meta "$vm")"
  [[ -f "$overlay" && -f "$meta" ]] || continue
  backing="$(qemu_img_info_json "$overlay" 2>/dev/null |
    jq -r '.["backing-filename"] // empty' 2>/dev/null || true)"
  expected_backing="$(backing_image_for_vm "$vm")"
  [[ "$backing" == "$expected_backing" ]] ||
    errors="${errors}${errors:+$'\n'}$vm overlay backing path is not the expected platform layer"
  [[ "$(meta_get "$meta" canonical_id)" == "$(canonical_id)" ]] ||
    errors="${errors}${errors:+$'\n'}$vm overlay canonical ID is stale"
  [[ "$(meta_get "$meta" checkpoint_generation)" == "$(checkpoint_generation)" ]] ||
    errors="${errors}${errors:+$'\n'}$vm overlay generation is stale"
done
if [[ -f "$STARTOS_LAYER" || -f "$STARTOS_LAYER_META" ]]; then
  startos_adapter_preflight >/dev/null 2>&1 ||
    errors="${errors}${errors:+$'\n'}StartOS Btrfs adapter preflight failed"
elif [[ -e "$STARTOS_LAYER_CANDIDATE" || -e "$STARTOS_LAYER_CANDIDATE_META" ||
        -e "$STARTOS_LAYER_RECOVERY" ]]; then
  errors="${errors}${errors:+$'\n'}StartOS Btrfs adapter conversion requires recovery"
fi

if [[ -n "$errors" ]]; then
  echo "safety: UNSAFE"
  while IFS= read -r error; do echo "  - $error"; done <<<"$errors"
else
  echo "safety: lifecycle state is consistent"
  echo "canonical-mutation: $([[ "$(dependent_overlay_count)" == 0 ]] && echo safe || echo blocked-by-dependent-overlays)"
fi
