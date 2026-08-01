#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/lib/common.sh"
failed=0
bad() { echo "FAIL $*" >&2; failed=1; }
ok() { echo "ok   $*"; }

for cmd in virsh qemu-img flock sha256sum; do command -v "$cmd" >/dev/null && ok "command $cmd" || bad "missing command $cmd"; done
virshq version >/dev/null 2>&1 && ok "libvirt connectivity" || bad "cannot connect to $LIBVIRT_URI"
[[ -c /dev/kvm || "${BVML_TESTING:-0}" == 1 ]] && ok "KVM device" || bad "/dev/kvm unavailable"
if [[ "$BVML_BOOT_UEFI" == 1 && "${BVML_TESTING:-0}" != 1 ]]; then
  firmware="$(find /usr/share/edk2* /usr/share/qemu -type f -iname 'OVMF_CODE*.fd' 2>/dev/null | head -1)"
  [[ -n "$firmware" ]] && ok "UEFI firmware $firmware" || bad "UEFI selected but OVMF firmware missing"
fi

if [[ -d "$BVML_STORAGE" ]]; then
  if [[ "${BVML_TESTING:-0}" == 1 ]] || sudo -u "$QEMU_USER" test -x "$BVML_STORAGE"; then ok "QEMU can traverse storage"; else bad "QEMU user cannot traverse $BVML_STORAGE"; fi
else bad "storage missing"; fi

if [[ -f "$CANONICAL" ]]; then
  qemu-img check "$CANONICAL" >/dev/null || bad "canonical qcow2 check failed"
  [[ "$(qemu-img info --output=json "$CANONICAL" | sed -n 's/.*"format":[[:space:]]*"\([^"]*\)".*/\1/p')" == qcow2 ]] || bad "canonical is not qcow2"
  qemu-img info --output=json "$CANONICAL" | grep -q '"backing-filename"' && bad "canonical has backing file" || ok "canonical is standalone"
  [[ ! -w "$CANONICAL" ]] && ok "canonical is read-only" || bad "canonical is writable"
  [[ "$(meta_get "$CANONICAL_META" blocksxor)" == 0 ]] || bad "canonical manifest lacks blocksxor=0"
  if command -v virt-cat >/dev/null; then
    xor_bytes="$(virt-cat -a "$CANONICAL" -m /dev/sda /blocks/xor.dat 2>/dev/null |
      od -An -v -tu1 | tr -s ' ' '\n' | sed '/^$/d' || true)"
    [[ -z "$xor_bytes" ]] || ! grep -qv '^0$' <<<"$xor_bytes" || bad "canonical block store is XOR encoded"
  fi
  if [[ "${BVML_TESTING:-0}" == 1 ]] || sudo -u "$QEMU_USER" test -r "$CANONICAL"; then ok "QEMU can read canonical"; else bad "QEMU cannot read canonical"; fi
  if command -v lsattr >/dev/null && lsattr "$CANONICAL" 2>/dev/null | awk '{print $1}' | grep -q i; then ok "canonical immutable"; else bad "canonical immutable bit absent"; fi
else bad "canonical missing"; fi

if [[ -e "$OVERLAY" || -e "$OVERLAY_META" ]]; then
  [[ -f "$OVERLAY" && -f "$OVERLAY_META" ]] || bad "partial overlay state"
  qemu-img check "$OVERLAY" >/dev/null || bad "overlay qcow2 check failed"
  backing="$(qemu-img info --output=json "$OVERLAY" | sed -n 's/.*"backing-filename":[[:space:]]*"\([^"]*\)".*/\1/p')"
  [[ "$backing" == "$CANONICAL" ]] || bad "overlay backing mismatch"
  [[ "$(meta_get "$OVERLAY_META" canonical_id)" == "$(canonical_id)" ]] || bad "overlay belongs to an older checkpoint"
  if [[ "${BVML_TESTING:-0}" == 1 ]] || sudo -u "$QEMU_USER" test -r "$OVERLAY"; then ok "QEMU can access overlay"; else bad "QEMU cannot access overlay"; fi
fi
extra="$(find "$ACTIVE_DIR" -maxdepth 1 -type f -name '*.qcow2' ! -path "$OVERLAY" -print -quit 2>/dev/null)"
[[ -z "$extra" ]] || bad "unexpected extra overlay: $extra"

attachments="$(bitcoin_attachment_count)"
[[ "$attachments" -le 1 ]] || bad "multiple Bitcoin disk attachments"
[[ -z "$(attached_vm_for_path "$CANONICAL)" ]] || bad "canonical attached directly"
owner="$(owner_vm)"; attached="$(attached_vm_for_path "$OVERLAY" | paste -sd, -)"
if [[ -n "$owner" ]]; then
  [[ "$owner" == "$(overlay_vm)" && "$owner" == "$attached" ]] || bad "owner/overlay/attachment mismatch"
  is_defined "$owner" && ! is_shut_off "$owner" || bad "stale owner for inactive domain"
elif [[ -n "$attached" ]]; then bad "attachment without owner"; fi

for vm in ubuntu umbrel startos; do
  if is_defined "$vm"; then ok "$(domain "$vm") state=$(domain_state "$vm")"; fi
done
[[ -n "$KNOTS_VERSION" ]] || bad "KNOTS_VERSION not configured"
[[ -n "$KNOTS_RDTS_ARGS" ]] || bad "release-specific KNOTS_RDTS_ARGS not configured"
if [[ -d "$BITCOIN_SOURCE" ]]; then
  if [[ -e "$BITCOIN_SOURCE/blocks/xor.dat" ]] &&
     od -An -v -tu1 "$BITCOIN_SOURCE/blocks/xor.dat" | tr -s ' ' '\n' | sed '/^$/d' | grep -qv '^0$'; then
    bad "source datadir uses XOR-encoded blocks"
  else ok "source datadir is non-XOR-compatible"; fi
  if [[ -e "$BITCOIN_SOURCE/.lock" ]] && ! flock -n "$BITCOIN_SOURCE/.lock" true; then
    bad "source datadir is actively locked"
  fi
else bad "configured source datadir missing: $BITCOIN_SOURCE"; fi
for vm in ubuntu umbrel startos; do
  iso_var="${vm^^}_ISO"; sum_var="${vm^^}_ISO_SHA256"; iso="${!iso_var:-}"; sum="${!sum_var:-}"
  if [[ -n "$iso" || -n "$sum" ]]; then
    [[ -f "$iso" && "$sum" =~ ^[0-9a-fA-F]{64}$ ]] || { bad "$vm ISO path/checksum incomplete"; continue; }
    [[ "$(sha256sum "$iso" | awk '{print $1}')" == "${sum,,}" ]] && ok "$vm ISO checksum" || bad "$vm ISO checksum mismatch"
  fi
done
[[ -n "${UMBREL_SUPPORTED_VERSION:-}" ]] || bad "Umbrel supported release/profile not declared"
[[ -n "${STARTOS_SUPPORTED_VERSION:-}" ]] || bad "StartOS supported release/profile not declared"
for adapter in ubuntu-knots-rdts umbrel startos; do
  [[ -x "$ROOT/scripts/vm/guest/${adapter}-adapter.sh" || "$adapter" == ubuntu-knots-rdts && -x "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" ]] ||
    bad "adapter missing: $adapter"
done
exit "$failed"
