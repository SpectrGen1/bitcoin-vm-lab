#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/lib/common.sh"
command="${1:?command required}"; shift

target_for_source() {
  local vm="$1" source="$2"
  virshq domblklist "$(domain "$vm")" --details 2>/dev/null |
    awk -v wanted="$source" 'NR>2 && $4 == wanted {print $3; exit}'
}

detach_overlay() {
  local vm="$1" target
  target="$(target_for_source "$vm" "$OVERLAY")"
  [[ -z "$target" ]] || virshq detach-disk "$(domain "$vm")" "$target" --config
}

write_overlay_meta() {
  local vm="$1"
  write_env_file "$OVERLAY_META" \
    "vm=$vm" "canonical_id=$(canonical_id)" "created=$(date -u +%FT%TZ)" \
    "backing=$CANONICAL"
}

write_owner() {
  local vm="$1"
  write_env_file "$OWNER_FILE" "vm=$vm" "domain=$(domain "$vm")" \
    "overlay=$OVERLAY" "attached_target=vdc" "started=$(date -u +%FT%TZ)"
}

assert_overlay_chain() {
  [[ -f "$OVERLAY" && -f "$OVERLAY_META" ]] || die "active overlay or manifest is missing"
  [[ "$(meta_get "$OVERLAY_META" backing)" == "$CANONICAL" ]] || die "overlay manifest backing path is invalid"
  [[ "$(meta_get "$OVERLAY_META" canonical_id)" == "$(canonical_id)" ]] ||
    die "overlay survived a checkpoint replacement; discard it"
  local backing
  backing="$(qemu-img info --output=json "$OVERLAY" | sed -n 's/.*"backing-filename":[[:space:]]*"\([^"]*\)".*/\1/p')"
  [[ "$backing" == "$CANONICAL" ]] || die "overlay qcow2 backing is '$backing', expected '$CANONICAL'"
}

assert_consistent_owner() {
  local owner attached count
  owner="$(owner_vm)"; attached="$(attached_vm_for_path "$OVERLAY" | paste -sd, -)"
  count="$(bitcoin_attachment_count)"
  [[ "$count" -le 1 ]] || die "more than one VM references Bitcoin storage"
  if [[ -n "$owner" ]]; then
    [[ -f "$OVERLAY" && "$(overlay_vm)" == "$owner" ]] || die "owner record disagrees with overlay manifest"
    [[ "$attached" == "$owner" ]] || die "owner record says $owner but attachment is '${attached:-none}'"
  elif [[ -n "$attached" ]]; then
    die "Bitcoin overlay is attached to $attached without an owner record"
  fi
  [[ -z "$(attached_vm_for_path "$CANONICAL")" ]] || die "canonical checkpoint is attached directly to a VM"
  [[ -z "$(attached_vm_for_path "$ROLLBACK")" ]] || die "rollback checkpoint is attached directly to a VM"
}

start_vm() {
  local vm="$1"; valid_vm "$vm"; need qemu-img; need virsh
  require_canonical; is_defined "$vm" || die "VM is not defined: $vm"
  is_shut_off "$vm" || die "$(domain "$vm") is $(domain_state "$vm"); exact 'shut off' required"
  assert_consistent_owner; assert_no_extra_overlays
  [[ ! -e "$OVERLAY" && ! -e "$OVERLAY_META" ]] ||
    die "an overlay for $(overlay_vm || echo unknown) is retained; discard or promote it first"
  assert_no_bitcoin_attachments
  qemu-img create -f qcow2 -F qcow2 -b "$CANONICAL" "$OVERLAY"
  chmod 0640 "$OVERLAY"
  if [[ "${BVML_TESTING:-0}" != 1 ]]; then
    setfacl -m "u:$QEMU_USER:rw-" "$OVERLAY" ||
      { rm -f -- "$OVERLAY"; die "could not grant QEMU overlay access"; }
  fi
  write_overlay_meta "$vm"
  if ! virshq attach-disk "$(domain "$vm")" "$OVERLAY" vdc --config \
      --driver qemu --subdriver qcow2 --targetbus virtio; then
    rm -f -- "$OVERLAY" "$OVERLAY_META"; die "attachment failed; overlay rolled back"
  fi
  write_owner "$vm"
  if ! virshq start "$(domain "$vm")"; then
    if is_shut_off "$vm"; then
      detach_overlay "$vm" || true
      rm -f -- "$OVERLAY" "$OVERLAY_META" "$OWNER_FILE"
      die "VM start failed; attachment, overlay, and owner were rolled back"
    fi
    die "VM start returned failure but domain is active; state retained for safe recovery"
  fi
  note "$vm started with the single disposable overlay"
}

stop_vm() {
  local vm="$1" waited=0; valid_vm "$vm"; is_defined "$vm" || die "VM is not defined: $vm"
  assert_consistent_owner
  [[ "$(owner_vm)" == "$vm" && "$(overlay_vm)" == "$vm" ]] || die "$vm does not own the active overlay"
  if ! is_shut_off "$vm"; then
    virshq shutdown "$(domain "$vm")"
    while ! is_shut_off "$vm"; do
      (( waited >= SHUTDOWN_TIMEOUT )) && die "shutdown timeout; attachment and ownership retained"
      sleep 2; ((waited+=2))
    done
  fi
  detach_overlay "$vm"
  [[ -z "$(attached_vm_for_path "$OVERLAY")" ]] || die "overlay still attached; ownership retained"
  rm -f -- "$OWNER_FILE"
  note "$vm is shut off and detached; its overlay is retained for discard or promotion"
}

discard_overlay() {
  local requested="${1:-}" vm
  all_shut_off; assert_consistent_owner; assert_no_bitcoin_attachments; assert_no_extra_overlays
  [[ ! -e "$OWNER_FILE" ]] || die "owner record remains; run stop for the owning VM"
  if [[ ! -e "$OVERLAY" && ! -e "$OVERLAY_META" ]]; then note "no active overlay"; return; fi
  vm="$(overlay_vm)"; [[ -z "$requested" || "$requested" == "$vm" ]] ||
    die "retained overlay belongs to $vm, not $requested"
  rm -f -- "$OVERLAY" "$OVERLAY_META" "$VERIFY_META"
  note "discarded $vm overlay; persistent VM disks and canonical checkpoint are unchanged"
}

reset_vm() {
  local vm="$1"; valid_vm "$vm"
  if [[ -f "$OVERLAY_META" && "$(overlay_vm)" != "$vm" ]]; then
    die "active overlay belongs to $(overlay_vm), not $vm"
  fi
  if [[ -f "$OWNER_FILE" ]]; then stop_vm "$vm"; else
    is_defined "$vm" && is_shut_off "$vm" || die "$vm is active without consistent ownership; run validate"
  fi
  discard_overlay "$vm"
}

source_xor_check() {
  local source="$1" xor="$source/blocks/xor.dat" byte
  [[ -d "$source/blocks" && -d "$source/chainstate" ]] ||
    die "source must contain mainnet blocks/ and chainstate/"
  [[ -e "$xor" ]] || return 0
  while read -r byte; do
    [[ "$byte" == 0 ]] || die "source blocks/xor.dat contains a non-zero XOR key. blocksxor=0 does not convert block files. Start Knots with the source's current format and perform a deliberate non-XOR rebuild/reindex into a new datadir before importing."
  done < <(od -An -v -tu1 "$xor" | tr -s ' ' '\n' | sed '/^$/d')
}

checkpoint_import() {
  local source="$BITCOIN_SOURCE" snapshot=0
  while (($#)); do case "$1" in
    --source) source="${2:?path required}"; shift 2 ;;
    --snapshot) snapshot=1; shift ;;
    *) die "checkpoint-import options: [--source PATH] [--snapshot]" ;;
  esac; done
  need qemu-img; need virt-make-fs; need virt-ls; need tar
  all_shut_off; assert_no_bitcoin_attachments
  [[ ! -e "$OVERLAY" && ! -e "$OWNER_FILE" ]] || die "discard the active overlay before initial import"
  [[ ! -e "$CANONICAL" ]] || die "canonical checkpoint already exists"
  [[ -d "$source" ]] || die "source datadir does not exist: $source"
  if ((snapshot == 0)) && [[ -e "$source/.lock" ]] && ! flock -n "$source/.lock" true; then
    die "source node holds .lock; shut it down cleanly or import a consistent snapshot with --snapshot"
  fi
  source_xor_check "$source"
  local candidate="$CANONICAL_DIR/import-candidate.qcow2" bytes id
  rm -f -- "$candidate"
  note "streaming reusable blocks, chainstate, and indexes into a qcow2 sized with ${CHECKPOINT_HEADROOM_PERCENT}% headroom"
  local import_paths=(blocks chainstate)
  [[ ! -d "$source/indexes" ]] || import_paths+=(indexes)
  tar -C "$source" -cf - --exclude='blocks/.lock' --exclude='*.log' \
    "${import_paths[@]}" |
    virt-make-fs --format=qcow2 --type=ext4 --size="+${CHECKPOINT_HEADROOM_PERCENT}%" - "$candidate"
  qemu-img check "$candidate"
  virt-ls -a "$candidate" -m /dev/sda / | grep -qx blocks || die "candidate lacks blocks/"
  virt-ls -a "$candidate" -m /dev/sda / | grep -qx chainstate || die "candidate lacks chainstate/"
  if [[ "$(meta_get "$VERIFY_META" indexes_json)" != '[]' ]]; then
    virt-ls -a "$candidate" -m /dev/sda / | grep -qx indexes || die "candidate lacks verified indexes/"
  fi
  bytes="$(du -sb "$source/blocks" "$source/chainstate" "$source/indexes" 2>/dev/null | awk '{s+=$1} END {print s+0}')"
  id="$(sha256sum "$candidate" | awk '{print $1}')"
  write_env_file "$CANONICAL_DIR/import-manifest.env" \
    "id=$id" "created=$(date -u +%FT%TZ)" "source=$source" "source_bytes=$bytes" \
    "network=main" "blocksxor=0" "layout=root-datadir" "kind=initial-import"
  mv -- "$candidate" "$CANONICAL"
  mv -- "$CANONICAL_DIR/import-manifest.env" "$CANONICAL_META"
  protect_image "$CANONICAL"; qemu-img check "$CANONICAL"
  note "protected canonical checkpoint imported from $source"
}

verify_promotion_evidence() {
  [[ -f "$VERIFY_META" ]] || die "missing $VERIFY_META from the Ubuntu Knots verification workflow"
  local key expected
  for key in vm network blocksxor synced clean_shutdown datadir_layout rdts_validated knots_version indexes_json; do
    [[ -n "$(meta_get "$VERIFY_META" "$key")" ]] || die "verification metadata missing $key"
  done
  for expected in "vm=ubuntu" "network=main" "blocksxor=0" "synced=1" \
                  "clean_shutdown=1" "datadir_layout=root-datadir" "rdts_validated=1"; do
    [[ "$(meta_get "$VERIFY_META" "${expected%%=*}")" == "${expected#*=}" ]] ||
      die "verification requirement failed: $expected"
  done
}

checkpoint_verify() {
  need virt-cat
  [[ "$(overlay_vm)" == ubuntu ]] || die "verification is only valid for an Ubuntu overlay"
  [[ ! -e "$OWNER_FILE" ]] || die "stop Ubuntu before extracting verification"
  all_shut_off; assert_no_bitcoin_attachments; assert_overlay_chain
  local candidate="$ACTIVE_DIR/ubuntu-verification.new"
  rm -f -- "$candidate"
  virt-cat -a "$OVERLAY" -m /dev/sda /.bvml/ubuntu-verification.env >"$candidate" ||
    { rm -f -- "$candidate"; die "guest verification file missing; run ubuntu-knots-rdts.sh verify-shutdown"; }
  chmod 0600 "$candidate"
  mv -- "$candidate" "$VERIFY_META"
  verify_promotion_evidence
  note "Ubuntu Knots/RDTS shutdown verification imported"
}

checkpoint_promote() {
  [[ "${1:-}" == "--confirm-synced-clean" && $# == 1 ]] ||
    die "promotion requires --confirm-synced-clean after guest verification"
  need qemu-img; need virt-ls; need virt-cat; require_canonical
  [[ "$(overlay_vm)" == ubuntu ]] || die "only an Ubuntu overlay may be promoted"
  [[ ! -e "$OWNER_FILE" ]] || die "runtime owner remains; stop Ubuntu first"
  all_shut_off; assert_consistent_owner; assert_no_bitcoin_attachments; assert_no_extra_overlays
  assert_overlay_chain; verify_promotion_evidence
  qemu-img check -r leaks "$OVERLAY"
  local candidate="$CANONICAL_DIR/promotion-candidate.qcow2"
  local candidate_meta="$CANONICAL_DIR/promotion-manifest.env" id
  rm -f -- "$candidate" "$candidate_meta"
  qemu-img convert -p -O qcow2 "$OVERLAY" "$candidate"
  qemu-img check "$candidate"
  virt-ls -a "$candidate" -m /dev/sda / | grep -qx blocks || die "candidate lacks blocks/"
  virt-ls -a "$candidate" -m /dev/sda / | grep -qx chainstate || die "candidate lacks chainstate/"
  local xor_bytes
  xor_bytes="$(virt-cat -a "$candidate" -m /dev/sda /blocks/xor.dat 2>/dev/null |
    od -An -v -tu1 | tr -s ' ' '\n' | sed '/^$/d' || true)"
  if [[ -n "$xor_bytes" ]] && grep -qv '^0$' <<<"$xor_bytes"; then
    die "promotion candidate contains XOR-encoded block storage"
  fi
  [[ -z "$(qemu-img info --output=json "$candidate" | sed -n 's/.*"backing-filename".*/yes/p')" ]] ||
    die "standalone promotion candidate unexpectedly has a backing file"
  id="$(sha256sum "$candidate" | awk '{print $1}')"
  write_env_file "$candidate_meta" "id=$id" "created=$(date -u +%FT%TZ)" \
    "network=main" "blocksxor=0" "layout=root-datadir" "kind=knots-rdts-promotion" \
    "knots_version=$(meta_get "$VERIFY_META" knots_version)"
  unprotect_image "$CANONICAL"; unprotect_image "$ROLLBACK"
  rm -f -- "$ROLLBACK" "$ROLLBACK_META"
  mv -- "$CANONICAL" "$ROLLBACK"; mv -- "$CANONICAL_META" "$ROLLBACK_META"
  if ! mv -- "$candidate" "$CANONICAL"; then
    mv -- "$ROLLBACK" "$CANONICAL"; mv -- "$ROLLBACK_META" "$CANONICAL_META"
    protect_image "$CANONICAL"; die "candidate installation failed; previous canonical restored"
  fi
  mv -- "$candidate_meta" "$CANONICAL_META"
  protect_image "$CANONICAL"; protect_image "$ROLLBACK"
  if ! qemu-img check "$CANONICAL"; then
    unprotect_image "$CANONICAL"; unprotect_image "$ROLLBACK"
    mv -- "$CANONICAL" "$candidate"; mv -- "$CANONICAL_META" "$candidate_meta"
    mv -- "$ROLLBACK" "$CANONICAL"; mv -- "$ROLLBACK_META" "$CANONICAL_META"
    protect_image "$CANONICAL"; die "installed candidate validation failed; previous canonical restored"
  fi
  rm -f -- "$OVERLAY" "$OVERLAY_META" "$VERIFY_META"
  note "checkpoint promoted; previous canonical preserved as rollback"
}

checkpoint_rollback() {
  require_canonical; [[ -f "$ROLLBACK" && -f "$ROLLBACK_META" ]] || die "rollback checkpoint is missing"
  all_shut_off; assert_no_bitcoin_attachments
  [[ ! -e "$OVERLAY" && ! -e "$OWNER_FILE" ]] || die "discard the active overlay before rollback"
  local swap="$CANONICAL_DIR/rollback-swap.qcow2" swapmeta="$CANONICAL_DIR/rollback-swap.env"
  unprotect_image "$CANONICAL"; unprotect_image "$ROLLBACK"
  mv -- "$CANONICAL" "$swap"; mv -- "$CANONICAL_META" "$swapmeta"
  if ! mv -- "$ROLLBACK" "$CANONICAL"; then mv -- "$swap" "$CANONICAL"; mv -- "$swapmeta" "$CANONICAL_META"; protect_image "$CANONICAL"; die "rollback installation failed"; fi
  mv -- "$ROLLBACK_META" "$CANONICAL_META"; mv -- "$swap" "$ROLLBACK"; mv -- "$swapmeta" "$ROLLBACK_META"
  qemu-img check "$CANONICAL" || die "rollback image failed validation; both images remain recoverable"
  protect_image "$CANONICAL"; protect_image "$ROLLBACK"
  note "canonical and rollback checkpoints exchanged"
}

adapter_status() {
  local vm="${1:-}"
  [[ -z "$vm" ]] || valid_vm "$vm"
  [[ -z "$vm" || "$vm" == ubuntu ]] && echo "ubuntu: module=guest/ubuntu-knots-rdts.sh knots=${KNOTS_VERSION:-UNCONFIGURED} rdts=$([[ -n "$KNOTS_RDTS_ARGS" ]] && echo configured || echo UNCONFIGURED)"
  [[ -z "$vm" || "$vm" == umbrel ]] && echo "umbrel: module=guest/umbrel-adapter.sh supported_release=${UMBREL_SUPPORTED_VERSION:-UNCONFIGURED}; run adapter verify inside guest"
  [[ -z "$vm" || "$vm" == startos ]] && echo "startos: module=guest/startos-adapter.sh supported_release=${STARTOS_SUPPORTED_VERSION:-UNCONFIGURED}; run adapter verify inside guest"
}

validate_all() { exec "$ROOT/scripts/vm/validate.sh"; }
status_all() { exec "$ROOT/scripts/vm/status.sh"; }

case "$command" in
  init) init_layout; note "storage initialized at $BVML_STORAGE" ;;
  create) with_lock "$ROOT/scripts/vm/create.sh" "${1:?VM required}" ;;
  start) with_lock start_vm "${1:?VM required}" ;;
  stop) with_lock stop_vm "${1:?VM required}" ;;
  discard) with_lock discard_overlay "${1:-}" ;;
  reset) with_lock reset_vm "${1:?VM required}" ;;
  checkpoint-import) with_lock checkpoint_import "$@" ;;
  checkpoint-verify) with_lock checkpoint_verify ;;
  checkpoint-promote) with_lock checkpoint_promote "$@" ;;
  checkpoint-protect) with_lock protect_image "$CANONICAL" ;;
  checkpoint-rollback) with_lock checkpoint_rollback ;;
  adapter-status) adapter_status "${1:-}" ;;
  validate) with_lock validate_all ;;
  status) status_all ;;
  *) die "unknown command: $command" ;;
esac
