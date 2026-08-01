#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/lib/common.sh"
failed=0
bad() { echo "FAIL $*" >&2; failed=1; }
ok() { echo "ok   $*"; }

for cmd in virsh qemu-img flock sha256sum virt-ls virt-cat virt-customize virt-filesystems; do
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
  validate_checkpoint_image "$CANONICAL" && ok "canonical format/layout/non-XOR/standalone" || bad "canonical validation failed"
  [[ ! -w "$CANONICAL" ]] && ok "canonical mode is read-only" || bad "canonical is writable"
  [[ "$(stat -c %a "$CANONICAL")" == 440 ]] || bad "canonical mode must be 0440"
  [[ "$(meta_get "$CANONICAL_META" blocksxor)" == 0 && -n "$(checkpoint_generation)" ]] ||
    bad "canonical manifest profile/generation incomplete"
  if [[ "${BVML_TESTING:-0}" == 1 ]] || sudo -u "$QEMU_USER" test -r "$CANONICAL"; then
    ok "system QEMU can read canonical"
  else bad "system QEMU cannot read canonical"; fi
  image_immutable "$CANONICAL" && ok "canonical immutable" || bad "canonical immutable bit absent"
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

attachments="$(bitcoin_attachment_count)"
[[ "$attachments" -le 1 ]] || bad "multiple Bitcoin disk attachments"
[[ -z "$(attached_vm_for_path "$CANONICAL")" ]] || bad "canonical attached directly"
owner="$(owner_vm)"
if [[ -n "$owner" ]]; then
  attached_path="$(meta_get "$OWNER_FILE" overlay)"
  attached="$(attached_vm_for_path "$attached_path" | paste -sd, -)"
  [[ "$owner" == "$attached" ]] || bad "owner/attachment mismatch; use bvml reconcile only after exact shutdown/detach"
  is_defined "$owner" && ! is_shut_off "$owner" || bad "stale owner for inactive domain"
else
  [[ "$attachments" == 0 ]] || bad "Bitcoin disk attached without owner metadata"
fi

if [[ -f "$VERIFY_META" ]]; then
  [[ -f "$OVERLAY" && "$(meta_get "$VERIFY_META" overlay_id)" == "$(overlay_id)" ]] ||
    bad "stale verification evidence"
fi
if [[ -f "$BOOTSTRAP_VERIFY" ]]; then
  [[ -f "$BOOTSTRAP" && "$(meta_get "$BOOTSTRAP_VERIFY" bootstrap_id)" == "$(meta_get "$BOOTSTRAP_META" bootstrap_id)" ]] ||
    bad "stale bootstrap verification evidence"
fi

for v in KNOTS_VERSION KNOTS_ARTIFACT_SHA256 KNOTS_RELEASE_PROFILE KNOTS_RDTS_PROFILE KNOTS_RDTS_PROFILE_SHA256; do
  [[ -n "${!v:-}" ]] || bad "$v not configured"
done
if [[ -f "$KNOTS_RDTS_PROFILE" && -n "$KNOTS_RDTS_PROFILE_SHA256" ]]; then
  [[ "$(sha256sum "$KNOTS_RDTS_PROFILE" | awk '{print $1}')" == "$KNOTS_RDTS_PROFILE_SHA256" ]] ||
    bad "RDTS profile authenticated digest mismatch"
fi
for vm in ubuntu umbrel startos; do
  iso_var="${vm^^}_ISO"; sum_var="${vm^^}_ISO_SHA256"; iso="${!iso_var:-}"; sum="${!sum_var:-}"
  [[ -n "$iso" && -f "$iso" && "$sum" =~ ^[0-9a-fA-F]{64}$ ]] ||
    { bad "$vm installation media/checksum not configured"; continue; }
  [[ "$(sha256sum "$iso" | awk '{print $1}')" == "${sum,,}" ]] &&
    ok "$vm installation media checksum" || bad "$vm installation media checksum mismatch"
done
for platform in umbrel startos; do
  [[ -f "$ROOT/templates/$platform/profile.env.example" && -x "$ROOT/scripts/vm/guest/$platform-adapter.sh" ]] ||
    bad "$platform package adapter module missing"
  profile_var="${platform^^}_SUPPORTED_VERSION"
  [[ -n "${!profile_var:-}" ]] || bad "$platform exact OS/package profile is not configured (adapter correctly unavailable)"
done

if [[ -d "$BVML_STORAGE" ]]; then
  available="$(df -B1 --output=avail "$BVML_STORAGE" | tail -1 | tr -d ' ')"
  bootstrap_required=$((BOOTSTRAP_SIZE_GIB * 1073741824))
  echo "info available_bytes=$available bootstrap_virtual_bytes=$bootstrap_required"
  [[ -f "$CANONICAL" ]] && echo "info promotion_rollback_estimate_bytes=$(du -B1 "$CANONICAL" | awk '{print $1}')"
fi
exit "$failed"
