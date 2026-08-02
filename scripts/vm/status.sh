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

if [[ -f "$BOOTSTRAP" || -f "$BOOTSTRAP_META" ]]; then
  case "$(meta_get "$BOOTSTRAP_META" state)" in
    created) label="fresh bootstrap image created" ;;
    ibd-in-progress) label="fresh IBD in progress" ;;
    retained-awaiting-verification) label="bootstrap retained and awaiting verification" ;;
    verified-complete) label="verified bootstrap retained for promotion" ;;
    *) label="partial or inconsistent bootstrap state" ;;
  esac
  echo "bootstrap: $label id=$(meta_get "$BOOTSTRAP_META" bootstrap_id) initialized=$(meta_get "$BOOTSTRAP_META" filesystem_initialized)"
else
  echo "bootstrap: absent"
fi
[[ -f "$IMPORT_CANDIDATE" || -f "$IMPORT_META" ]] &&
  echo "import: candidate or partial import state present" || echo "import: absent"
[[ -f "$BOOTSTRAP_CANDIDATE" || -f "$BOOTSTRAP_CANDIDATE_META" ]] &&
  echo "promotion-candidate: bootstrap candidate present" || echo "promotion-candidate: absent"
if [[ "$ROLLBACK_RETENTION" == none ]]; then
  echo "rollback: disabled by storage policy"
  echo "disaster recovery: re-IBD"
elif [[ -f "$ROLLBACK" ]]; then
  echo "rollback: available id=$(meta_get "$ROLLBACK_META" id) generation=$(meta_get "$ROLLBACK_META" generation)"
else
  echo "rollback: absent"
fi

if [[ -f "$OVERLAY" || -f "$OVERLAY_META" ]]; then
  [[ -f "$OWNER_FILE" ]] && label=active || label=retained
  echo "overlay: $label vm=$(overlay_vm) id=$(overlay_id) generation=$(meta_get "$OVERLAY_META" checkpoint_generation)"
  [[ -f "$OVERLAY" ]] && qemu-img info --backing-chain "$OVERLAY" 2>/dev/null | sed 's/^/  /'
else
  echo "overlay: absent"
fi

owner="$(owner_vm)"; owner_kind_value="$(owner_kind)"; owner_image_value="$(owner_image)"
echo "owner: vm=${owner:-none} kind=${owner_kind_value:-none} image=${owner_image_value:-none}"
echo "verification: overlay=$([[ -f "$VERIFY_META" ]] && echo present || echo absent) bootstrap=$([[ -f "$BOOTSTRAP_VERIFY" ]] && echo present || echo absent)"
for vm in ubuntu umbrel startos; do
  state=undefined; is_defined "$vm" && state="$(domain_state "$vm")"
  printf 'domain: %-13s state=%s\n' "$(domain "$vm")" "$state"
done

echo "attachments:"
attachments="$(all_attached_pairs)"
if [[ -n "$attachments" ]]; then
  while IFS=$'\t' read -r vm image; do printf '  domain=%s image=%s\n' "$(domain "$vm")" "$image"; done <<<"$attachments"
else
  echo "  none"
fi

errors="$(lifecycle_invariant_errors)"
if [[ -f "$CANONICAL" ]]; then
  if ! canonical_error="$(canonical_preflight 2>&1)"; then
    errors="${errors}${errors:+$'\n'}canonical preflight failed: ${canonical_error#*: }"
  fi
fi
if [[ -f "$OVERLAY" && -f "$OVERLAY_META" ]]; then
  backing="$(qemu-img info --output=json "$OVERLAY" 2>/dev/null | jq -r '.["backing-filename"] // empty' 2>/dev/null || true)"
  [[ "$backing" == "$CANONICAL" ]] ||
    errors="${errors}${errors:+$'\n'}overlay backing path is not the canonical checkpoint"
  [[ "$(meta_get "$OVERLAY_META" canonical_id)" == "$(canonical_id)" ]] ||
    errors="${errors}${errors:+$'\n'}overlay canonical ID is stale"
  [[ "$(meta_get "$OVERLAY_META" checkpoint_generation)" == "$(checkpoint_generation)" ]] ||
    errors="${errors}${errors:+$'\n'}overlay checkpoint generation is stale"
fi
if [[ -n "$errors" ]]; then
  echo "safety: UNSAFE"
  while IFS= read -r error; do echo "  - $error"; done <<<"$errors"
  if [[ -f "$OVERLAY" && ! -f "$OWNER_FILE" && "$(bitcoin_attachment_count)" == 0 ]] &&
     (all_shut_off) >/dev/null 2>&1; then
    echo "operations: discard is the only safe automatic recovery; other destructive operations are blocked"
  else
    echo "operations: no destructive operation is safe; inspect validate output and use reconcile only when its proof checks pass"
  fi
elif [[ -f "$OWNER_FILE" ]]; then
  echo "safety: consistent active ownership; stop is safe"
elif [[ -f "$BOOTSTRAP" ]]; then
  case "$(meta_get "$BOOTSTRAP_META" state)" in
    verified-complete) echo "safety: bootstrap promotion or cleanup preflight may proceed" ;;
    *) echo "safety: bootstrap verification, cleanup, or restart-specific recovery may proceed" ;;
  esac
elif [[ -f "$OVERLAY" ]]; then
  [[ "$(overlay_vm)" == ubuntu && -f "$VERIFY_META" ]] &&
    echo "safety: discard or promotion preflight may proceed" ||
    echo "safety: discard preflight may proceed"
elif [[ -f "$CANONICAL" ]]; then
  echo "safety: Ubuntu start or rollback preflight may proceed; platform starts also require verified adapter metadata"
else
  echo "safety: exactly one initialization path may begin"
fi
