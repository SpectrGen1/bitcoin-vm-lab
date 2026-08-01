#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/lib/common.sh"
echo "storage: $BVML_STORAGE"
unsafe=0
if [[ -f "$CANONICAL" ]]; then
  echo "lifecycle: canonical checkpoint ready"
  echo "canonical: id=$(canonical_id) generation=$(checkpoint_generation) protected=$([[ ! -w "$CANONICAL" ]] && echo yes || echo NO)"
  qemu-img info --backing-chain "$CANONICAL" 2>/dev/null | sed 's/^/  /'
elif [[ -f "$BOOTSTRAP" ]]; then
  case "$(meta_get "$BOOTSTRAP_META" state)" in
    created) label="fresh bootstrap image created" ;;
    ibd-in-progress) label="fresh IBD in progress" ;;
    retained-awaiting-verification) label="bootstrap retained and awaiting verification" ;;
    verified-complete) label="promotion candidate present" ;;
    *) label="inconsistent bootstrap state"; unsafe=1 ;;
  esac
  echo "lifecycle: $label"
  echo "bootstrap: id=$(meta_get "$BOOTSTRAP_META" bootstrap_id) initialized=$(meta_get "$BOOTSTRAP_META" filesystem_initialized)"
else echo "lifecycle: no checkpoint initialized"; fi
[[ -f "$ROLLBACK" ]] && echo "rollback: available id=$(meta_get "$ROLLBACK_META" id)" || echo "rollback: absent"
if [[ -f "$OVERLAY" ]]; then
  if [[ -f "$OWNER_FILE" ]]; then label="disposable test overlay active"; else label="disposable test overlay retained"; fi
  echo "lifecycle: $label"
  echo "overlay: vm=$(overlay_vm) id=$(overlay_id) generation=$(meta_get "$OVERLAY_META" checkpoint_generation)"
  qemu-img info --backing-chain "$OVERLAY" 2>/dev/null | sed 's/^/  /'
else echo "overlay: absent"; fi
owner="$(owner_vm)"; echo "owner: ${owner:-none}"
echo "verification: overlay=$([[ -f "$VERIFY_META" ]] && echo present || echo absent) bootstrap=$([[ -f "$BOOTSTRAP_VERIFY" ]] && echo present || echo absent)"
attached_list=
for vm in ubuntu umbrel startos; do
  state=undefined; is_defined "$vm" && state="$(domain_state "$vm")"
  printf '%-13s %s\n' "$(domain "$vm"):" "$state"
  for image in "$OVERLAY" "$BOOTSTRAP" "$CANONICAL" "$ROLLBACK"; do
    [[ -n "$(attached_vm_for_path "$image")" ]] && attached_list="${attached_list}${vm}:$image "
  done
  [[ "$state" == undefined || "$state" == "shut off" ]] || unsafe=1
done
echo "attachments: ${attached_list:-none}"
[[ "$(bitcoin_attachment_count)" -le 1 ]] || unsafe=1
if ((unsafe)); then
  echo "safety: INCONSISTENT/ACTIVE - no destructive operation is safe"
elif [[ -f "$OWNER_FILE" ]]; then
  echo "safety: stop is safe; discard/promotion/rollback are not"
elif [[ -f "$BOOTSTRAP" ]]; then
  [[ "$(meta_get "$BOOTSTRAP_META" state)" == verified-complete ]] &&
    echo "safety: bootstrap promotion or cleanup checks may proceed" ||
    echo "safety: bootstrap verification/cleanup checks may proceed"
elif [[ -f "$OVERLAY" ]]; then
  [[ "$(overlay_vm)" == ubuntu && -f "$VERIFY_META" ]] &&
    echo "safety: discard or promotion prerequisite checks may proceed" ||
    echo "safety: discard is safe; promotion is not"
elif [[ -f "$CANONICAL" ]]; then
  echo "safety: start or rollback prerequisite checks may proceed"
else echo "safety: fresh checkpoint bootstrap may proceed"; fi
