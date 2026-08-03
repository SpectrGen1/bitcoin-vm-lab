#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/lib/common.sh"
failed=0
bad() { echo "FAIL $*" >&2; failed=1; }
ok() { echo "ok   $*"; }

for cmd in virsh qemu-img flock sha256sum jq xmllint virt-ls virt-cat virt-customize virt-filesystems xorriso file tesseract sshpass; do
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
  else bad "system QEMU cannot traverse $BVML_STORAGE"; fi
else bad "storage missing: run bvml init"; fi

if [[ -f "$CANONICAL" ]]; then
  canonical_preflight >/dev/null 2>&1 &&
    ok "canonical full fast preflight (format/layout/profile/protection/QEMU access)" ||
    bad "canonical full fast preflight failed"
elif [[ -f "$BOOTSTRAP" ]]; then
  ok "canonical absent while fresh bootstrap is $(meta_get "$BOOTSTRAP_META" state)"
else
  ok "no checkpoint initialized; fresh bootstrap is available"
fi

if [[ -f "$ROLLBACK" ]]; then
  validate_checkpoint_image "$ROLLBACK" && ok "rollback independently valid" || bad "rollback checkpoint invalid"
  [[ ! -w "$ROLLBACK" ]] || bad "rollback is writable"
fi
if [[ -e "$OVERLAY" || -e "$OVERLAY_META" ]]; then
  [[ -f "$OVERLAY" && -f "$OVERLAY_META" ]] || bad "partial overlay state"
  assert_overlay_chain >/dev/null 2>&1 && ok "overlay backing/generation/ID" || bad "overlay chain or manifest invalid"
fi
extra="$(find "$ACTIVE_DIR" -maxdepth 1 -type f -name '*.qcow2' \
  ! -path "$OVERLAY" ! -path "$BOOTSTRAP" -print -quit 2>/dev/null)"
[[ -z "$extra" ]] || bad "unexpected extra overlay: $extra"
[[ ! -f "$OVERLAY" || ! -f "$BOOTSTRAP" ]] || bad "ordinary overlay and bootstrap coexist"

errors="$(lifecycle_invariant_errors)"
[[ -z "$errors" ]] && ok "lifecycle owner/manifest/attachment/process invariants" ||
  bad "lifecycle invariant failure: ${errors//$'\n'/; }"

if [[ -f "$VERIFY_META" ]]; then
  [[ -f "$OVERLAY" && "$(meta_get "$VERIFY_META" overlay_id)" == "$(overlay_id)" ]] ||
    bad "stale verification evidence"
fi
if [[ -f "$BOOTSTRAP_VERIFY" ]]; then
  [[ -f "$BOOTSTRAP" && "$(meta_get "$BOOTSTRAP_VERIFY" bootstrap_id)" == "$(meta_get "$BOOTSTRAP_META" bootstrap_id)" ]] ||
    bad "stale bootstrap verification evidence"
fi

for v in KNOTS_VERSION_NORMALIZED KNOTS_ARTIFACT_SHA256 KNOTS_RELEASE_PROFILE \
  KNOTS_RELEASE_PROFILE_SHA256 KNOTS_RDTS_PROFILE KNOTS_RDTS_PROFILE_SHA256 \
  KNOTS_RDTS_PROFILE_NAME KNOTS_RDTS_REQUIRED_ARGS_JSON; do
  [[ -n "${!v:-}" ]] || bad "$v not configured"
done
if [[ -f "$KNOTS_RDTS_PROFILE" && -n "$KNOTS_RDTS_PROFILE_SHA256" ]]; then
  [[ "$(sha256sum "$KNOTS_RDTS_PROFILE" | awk '{print $1}')" == "$KNOTS_RDTS_PROFILE_SHA256" ]] ||
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
[[ "$MAX_TIP_AGE_SECONDS" =~ ^[1-9][0-9]*$ ]] || bad "MAX_TIP_AGE_SECONDS must be a positive integer"
for vm in ubuntu umbrel startos; do
  if [[ "$vm" == ubuntu && "$UBUNTU_IMAGE_MODE" == cloud ]]; then
    if [[ -f "$UBUNTU_CLOUD_IMAGE" && "$UBUNTU_CLOUD_IMAGE_SHA256" =~ ^[0-9a-fA-F]{64}$ &&
          "$(sha256sum "$UBUNTU_CLOUD_IMAGE" | awk '{print $1}')" == "${UBUNTU_CLOUD_IMAGE_SHA256,,}" ]]; then
      qemu-img check "$UBUNTU_CLOUD_IMAGE" >/dev/null &&
        ok "Ubuntu cloud image digest/format check" || bad "Ubuntu cloud image qemu-img check failed"
    else
      bad "Ubuntu cloud image is missing or does not match its pinned digest"
    fi
    [[ "$UBUNTU_CLOUD_SSH_KEY" == /* && -f "$UBUNTU_CLOUD_SSH_KEY" ]] &&
      ok "Ubuntu cloud SSH public key" || bad "Ubuntu cloud SSH public key is missing"
    [[ -r "$LIBGUESTFS_APPLIANCE_PATH/kernel" && -r "$LIBGUESTFS_APPLIANCE_PATH/initrd" &&
       -r "$LIBGUESTFS_APPLIANCE_PATH/root" ]] ||
      bad "libguestfs appliance is incomplete at $LIBGUESTFS_APPLIANCE_PATH"
    continue
  fi
  iso_var="${vm^^}_ISO"; sum_var="${vm^^}_ISO_SHA256"; iso="${!iso_var:-}"; sum="${!sum_var:-}"
  [[ -n "$iso" && -f "$iso" && "$sum" =~ ^[0-9a-fA-F]{64}$ ]] ||
    { bad "$vm installation media/checksum not configured"; continue; }
  [[ "$(sha256sum "$iso" | awk '{print $1}')" == "${sum,,}" ]] &&
    ok "$vm installation media checksum" || bad "$vm installation media checksum mismatch"
done
for platform in umbrel startos; do
  if [[ "$platform" == umbrel ]]; then
    [[ -f "$UMBREL_PROFILE" && -x "$ROOT/scripts/vm/guest/umbrel-adapter.sh" &&
       "$(sha256sum "$UMBREL_PROFILE" | awk '{print $1}')" == "${UMBREL_PROFILE_SHA256,,}" ]] ||
      bad "Umbrel immutable profile or native-package adapter is missing"
    if [[ -f "$UMBREL_ISO" ]]; then
      [[ "$(sha256sum "$UMBREL_ISO" | awk '{print $1}')" == "${UMBREL_ISO_SHA256,,}" &&
         -f "$UMBREL_ISO.manifest.json" ]] &&
        ok "Umbrel installer is digest-pinned and profile-bound" ||
        bad "Umbrel installer or generation manifest is invalid"
    fi
  else
    [[ -f "$ROOT/templates/$platform/profile.env.example" &&
       -x "$ROOT/scripts/vm/guest/$platform-adapter.sh" ]] ||
      bad "$platform package adapter module missing"
  fi
  metadata="$ADAPTER_STATE_DIR/$platform.json"
  if [[ -f "$metadata" ]] && jq -e --arg platform "$platform" '
    .platform == $platform and .last_validation_result == "ok" and
    ([.os_version,.package_version,.profile_digest,.knots_binary_digest,
      .adapter_implementation_version,.validated_at] | all(type == "string" and length > 0))
  ' "$metadata" >/dev/null; then
    ok "$platform verified guest adapter profile metadata"
  else
    bad "$platform has no current verified guest adapter metadata (adapter remains unavailable)"
  fi
done

if [[ -d "$BVML_STORAGE" ]]; then
  available="$(df -B1 --output=avail "$BVML_STORAGE" | tail -1 | tr -d ' ')"
  bootstrap_required=$((BOOTSTRAP_SIZE_GIB * 1073741824))
  echo "info available_bytes=$available bootstrap_virtual_bytes=$bootstrap_required"
  [[ -f "$CANONICAL" ]] && echo "info promotion_rollback_estimate_bytes=$(du -B1 "$CANONICAL" | awk '{print $1}')"
fi
exit "$failed"
