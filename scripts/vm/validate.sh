#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/lib/common.sh"
failed=0
bad() { echo "FAIL $*" >&2; failed=1; }
ok() { echo "ok   $*"; }

for cmd in virsh qemu-img flock sha256sum jq xmllint virt-ls virt-cat virt-customize \
  virt-filesystems xorriso file tesseract sshpass; do
  command -v "$cmd" >/dev/null && ok "command $cmd" || bad "missing command $cmd"
done
virshq version >/dev/null 2>&1 && ok "libvirt connectivity" || bad "cannot connect to $LIBVIRT_URI"
[[ -c /dev/kvm || "${BVML_TESTING:-0}" == 1 ]] && ok "KVM device" || bad "/dev/kvm unavailable"
if [[ "$BVML_BOOT_UEFI" == 1 && "${BVML_TESTING:-0}" != 1 ]]; then
  firmware="$(find /usr/share/edk2* /usr/share/qemu -type f -iname 'OVMF_CODE*.fd' 2>/dev/null | head -1)"
  [[ -n "$firmware" ]] && ok "UEFI firmware $firmware" || bad "UEFI selected but OVMF firmware missing"
fi
for vm in ubuntu umbrel startos; do
  is_defined "$vm" && ok "defined domain $(domain "$vm") state=$(domain_state "$vm")" ||
    bad "missing exact domain $(domain "$vm")"
done

if [[ -d "$BVML_STORAGE" ]]; then
  if [[ "${BVML_TESTING:-0}" == 1 ]] || sudo -u "$QEMU_USER" test -x "$BVML_STORAGE"; then
    ok "system QEMU can traverse storage"
  else
    bad "system QEMU cannot traverse $BVML_STORAGE"
  fi
else
  bad "storage missing: run bvml init"
fi

if [[ -f "$CANONICAL" ]]; then
  canonical_preflight >/dev/null 2>&1 &&
    ok "canonical full fast preflight" || bad "canonical full fast preflight failed"
elif [[ -f "$BOOTSTRAP" ]]; then
  ok "canonical absent while fresh bootstrap is $(meta_get "$BOOTSTRAP_META" state)"
else
  ok "no checkpoint initialized; fresh bootstrap is available"
fi
if [[ -f "$ROLLBACK" ]]; then
  validate_checkpoint_image "$ROLLBACK" && ok "rollback independently valid" ||
    bad "rollback checkpoint invalid"
  [[ ! -w "$ROLLBACK" ]] || bad "rollback is writable"
fi
if [[ -f "$STARTOS_LAYER" || -f "$STARTOS_LAYER_META" ]]; then
  startos_adapter_preflight >/dev/null 2>&1 &&
    ok "protected StartOS Btrfs adapter/transitive backing chain" ||
    bad "StartOS Btrfs adapter validation failed"
elif [[ -e "$STARTOS_LAYER_CANDIDATE" || -e "$STARTOS_LAYER_CANDIDATE_META" ||
        -e "$STARTOS_LAYER_RECOVERY" ]]; then
  bad "partial StartOS Btrfs adapter conversion/recovery state"
else
  bad "StartOS Btrfs adapter is not initialized"
fi

for vm in ubuntu umbrel startos; do
  set_lifecycle_context "$vm"
  if [[ -e "$OVERLAY" || -e "$OVERLAY_META" ]]; then
    [[ -f "$OVERLAY" && -f "$OVERLAY_META" ]] || bad "$vm partial overlay state"
    assert_overlay_chain >/dev/null 2>&1 &&
      ok "$vm overlay backing/generation/ID" || bad "$vm overlay chain or manifest invalid"
    for field in owner_state attachment_state mount_state adapter_state recovery_required; do
      [[ -n "$(meta_get "$OVERLAY_META" "$field")" ]] ||
        bad "$vm overlay manifest lacks $field"
    done
  fi
  if [[ -f "$VERIFY_META" ]]; then
    [[ -f "$OVERLAY" && "$(meta_get "$VERIFY_META" overlay_id)" == "$(overlay_id)" ]] ||
      bad "$vm stale verification evidence"
  fi
done
assert_no_extra_overlays >/dev/null 2>&1 || bad "unexpected overlay image exists"
errors="$(lifecycle_invariant_errors)"
[[ -z "$errors" ]] && ok "per-VM owner/manifest/attachment/process invariants" ||
  bad "lifecycle invariant failure: ${errors//$'\n'/; }"

validate_index_profile >/dev/null 2>&1 &&
  ok "Electrs/Fulcrum pinned index profile" || bad "Electrs/Fulcrum index profile invalid"
for service in electrs fulcrum; do
  base="$(index_base "$service")"; bmeta="$(index_base_meta "$service")"
  bootstrap="$(index_bootstrap "$service")"; bootstrap_meta="$(index_bootstrap_meta "$service")"
  if { [[ -e "$base" ]] && [[ ! -e "$bmeta" ]]; } ||
     { [[ ! -e "$base" ]] && [[ -e "$bmeta" ]]; }; then
    bad "$service has partial protected base state"
  elif [[ -f "$base" ]]; then
    index_base_preflight "$service" >/dev/null 2>&1 &&
      ok "$service protected base integrity/generation/protection" ||
      bad "$service protected base preflight failed"
  fi
  if { [[ -e "$bootstrap" ]] && [[ ! -e "$bootstrap_meta" ]]; } ||
     { [[ ! -e "$bootstrap" ]] && [[ -e "$bootstrap_meta" ]]; }; then
    bad "$service has partial bootstrap state"
  fi
  [[ ! -e "$base" || ! -e "$bootstrap" ]] ||
    bad "$service protected base and bootstrap coexist"
  for vm in ubuntu umbrel startos; do
    index_supported_for_vm "$vm" "$service" || continue
    image="$(index_overlay "$vm" "$service")"; imeta="$(index_overlay_meta "$vm" "$service")"
    if { [[ -e "$image" ]] && [[ ! -e "$imeta" ]]; } ||
       { [[ ! -e "$image" ]] && [[ -e "$imeta" ]]; }; then
      bad "$vm $service has partial overlay state"
    elif [[ -f "$image" ]]; then
      index_overlay_preflight "$vm" "$service" >/dev/null 2>&1 &&
        ok "$vm $service overlay backing/generation" ||
        bad "$vm $service overlay preflight failed"
      attached="$(attached_vm_for_path "$image" | paste -sd, -)"
      [[ -z "$attached" || "$attached" == "$vm" ]] ||
        bad "$vm $service overlay is attached to '${attached:-none}'"
    fi
  done
done
for service in electrs fulcrum; do
  [[ -z "$(attached_vm_for_path "$(index_base "$service")")" ]] ||
    bad "$service protected base is attached directly"
done

if [[ -f "$BOOTSTRAP_VERIFY" ]]; then
  [[ -f "$BOOTSTRAP" &&
     "$(meta_get "$BOOTSTRAP_VERIFY" bootstrap_id)" == "$(meta_get "$BOOTSTRAP_META" bootstrap_id)" ]] ||
    bad "stale bootstrap verification evidence"
fi

for v in KNOTS_VERSION_NORMALIZED KNOTS_ARTIFACT_SHA256 KNOTS_RELEASE_PROFILE \
  KNOTS_RELEASE_PROFILE_SHA256 KNOTS_RDTS_PROFILE KNOTS_RDTS_PROFILE_SHA256 \
  KNOTS_RDTS_PROFILE_NAME KNOTS_RDTS_REQUIRED_ARGS_JSON; do
  [[ -n "${!v:-}" ]] || bad "$v not configured"
done
if [[ -f "$KNOTS_RDTS_PROFILE" && -n "$KNOTS_RDTS_PROFILE_SHA256" ]]; then
  [[ "$(sha256sum "$KNOTS_RDTS_PROFILE" | awk '{print $1}')" == "${KNOTS_RDTS_PROFILE_SHA256,,}" ]] ||
    bad "RDTS profile authenticated digest mismatch"
fi
if [[ -f "$KNOTS_RELEASE_PROFILE" && "$KNOTS_RELEASE_PROFILE_SHA256" =~ ^[0-9a-fA-F]{64}$ ]]; then
  [[ "$(sha256sum "$KNOTS_RELEASE_PROFILE" | awk '{print $1}')" == "${KNOTS_RELEASE_PROFILE_SHA256,,}" ]] &&
    ok "Knots release profile digest" || bad "Knots release profile digest mismatch"
fi
jq -e 'type == "array" and length > 0 and all(.[]; type == "string")' \
  <<<"$KNOTS_RDTS_REQUIRED_ARGS_JSON" >/dev/null ||
  bad "host-approved RDTS required arguments must be a nonempty JSON string array"
validate_checkpoint_profile >/dev/null 2>&1 && ok "checkpoint index profile digest/structure" ||
  bad "checkpoint index profile is missing, malformed, or has the wrong digest"
[[ "$MAX_TIP_AGE_SECONDS" =~ ^[1-9][0-9]*$ ]] || bad "MAX_TIP_AGE_SECONDS must be positive"

if [[ -f "$STARTOS_PROFILE" &&
   "$(sha256sum "$STARTOS_PROFILE" | awk '{print $1}')" == "${STARTOS_PROFILE_SHA256,,}" ]] &&
   jq -e '.os.release=="0.4.0.1" and .registry.package_id=="bitcoind" and
     .registry.package_version=="#knots:29.3.1:16" and
     .package.subcontainer=="bitcoind-sub" and
     .package.subcontainer_datadir=="/root/.bitcoin"' "$STARTOS_PROFILE" >/dev/null; then
  ok "StartOS immutable OS/package adapter profile"
else
  bad "StartOS profile is missing, malformed, or has the wrong digest"
fi
if [[ -f "$STARTOS_ISO" ]]; then
  [[ "$(sha256sum "$STARTOS_ISO" | awk '{print $1}')" == "${STARTOS_ISO_SHA256,,}" ]] &&
    ok "StartOS installer digest" || bad "StartOS installer digest mismatch"
fi
if [[ -f "$STARTOS_PACKAGE" ]]; then
  [[ "$(sha256sum "$STARTOS_PACKAGE" | awk '{print $1}')" == "${STARTOS_PACKAGE_SHA256,,}" ]] &&
    ok "StartOS official Knots s9pk digest" || bad "StartOS package digest mismatch"
fi

for platform in umbrel startos; do
  metadata="$ADAPTER_STATE_DIR/$platform.json"
  if [[ -f "$metadata" ]] && jq -e --arg platform "$platform" '
    .platform == $platform and .last_validation_result == "ok" and
    ([.os_version,.package_version,.profile_digest,.knots_binary_digest,
      .adapter_implementation_version,.validated_at] | all(type == "string" and length > 0))
  ' "$metadata" >/dev/null; then
    ok "$platform verified guest adapter profile metadata"
  else
    bad "$platform has no current verified guest adapter metadata"
  fi
done

if [[ -d "$BVML_STORAGE" ]]; then
  available="$(df -B1 --output=avail "$BVML_STORAGE" | tail -1 | tr -d ' ')"
  echo "info available_bytes=$available dependent_overlays=$(dependent_overlay_count)"
fi
exit "$failed"
