#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/lib/common.sh"
echo "storage:   $BVML_STORAGE"
if [[ -f "$CANONICAL" ]]; then
  echo "canonical: present id=$(canonical_id) protected=$([[ ! -w "$CANONICAL" ]] && echo yes || echo NO)"
  qemu-img info --backing-chain "$CANONICAL" 2>/dev/null | sed 's/^/           /'
else echo "canonical: absent"; fi
if [[ -f "$OVERLAY" ]]; then
  echo "overlay:   retained vm=$(overlay_vm) checkpoint=$(meta_get "$OVERLAY_META" canonical_id)"
  qemu-img info --backing-chain "$OVERLAY" 2>/dev/null | sed 's/^/           /'
else echo "overlay:   absent"; fi
owner="$(owner_vm)"
echo "owner:     ${owner:-none}"
attached="$(attached_vm_for_path "$OVERLAY" | paste -sd, -)"
echo "attached:  ${attached:-none}"
for vm in ubuntu umbrel startos; do
  is_defined "$vm" && printf '%-11s %s\n' "$(domain "$vm"):" "$(domain_state "$vm")" || printf '%-11s undefined\n' "$(domain "$vm"):"
done
if [[ ! -f "$OVERLAY" && ! -f "$OWNER_FILE" && "$(bitcoin_attachment_count)" == 0 ]]; then
  echo "safe:       start"
elif [[ -f "$OVERLAY" && ! -f "$OWNER_FILE" && "$(bitcoin_attachment_count)" == 0 ]]; then
  [[ "$(overlay_vm)" == ubuntu && -f "$VERIFY_META" ]] && echo "safe:       discard or promotion checks" || echo "safe:       discard"
else echo "safe:       stop/recover ownership; do not discard or promote"; fi
