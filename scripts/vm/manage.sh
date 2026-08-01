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
  local vm="$1" nonce
  nonce="$(new_id)"
  write_env_file "$OVERLAY_META" \
    "vm=$vm" "canonical_id=$(canonical_id)" "created=$(date -u +%FT%TZ)" \
    "backing=$CANONICAL" "overlay_id=$nonce" "checkpoint_generation=$(checkpoint_generation)"
  invalidate_verification
}

write_owner() {
  local vm="$1"
  [[ "${BVML_FAIL_OWNER_WRITE:-0}" != 1 ]] || return 1
  write_env_file "$OWNER_FILE" "vm=$vm" "domain=$(domain "$vm")" \
    "overlay=$OVERLAY" "overlay_id=$(overlay_id)" "attached_target=vdc" \
    "started=$(date -u +%FT%TZ)"
}

assert_overlay_chain() {
  [[ -f "$OVERLAY" && -f "$OVERLAY_META" ]] || die "active overlay or manifest is missing"
  [[ "$(meta_get "$OVERLAY_META" backing)" == "$CANONICAL" ]] || die "overlay manifest backing path is invalid"
  [[ "$(meta_get "$OVERLAY_META" canonical_id)" == "$(canonical_id)" ]] ||
    die "overlay survived a checkpoint replacement; discard it"
  [[ -n "$(overlay_id)" ]] || die "overlay manifest lacks a unique overlay ID"
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
    [[ "$(meta_get "$OWNER_FILE" overlay_id)" == "$(overlay_id)" ]] ||
      die "owner record belongs to another overlay"
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
  all_shut_off
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
  if ! write_owner "$vm"; then
    detach_overlay "$vm" || die "owner write failed and attachment could not be rolled back"
    [[ -z "$(attached_vm_for_path "$OVERLAY")" ]] ||
      die "owner write failed and domain XML still references overlay; image retained"
    rm -f -- "$OVERLAY" "$OVERLAY_META"
    die "owner write failed; attachment and overlay rolled back"
  fi
  if ! virshq start "$(domain "$vm")"; then
    if is_shut_off "$vm"; then
      detach_overlay "$vm" || die "VM start failed and detach failed; overlay and owner retained"
      [[ -z "$(attached_vm_for_path "$OVERLAY")" ]] ||
        die "VM start failed and domain XML still references overlay; state retained"
      rm -f -- "$OVERLAY" "$OVERLAY_META" "$OWNER_FILE" "$VERIFY_META"
      die "VM start failed; attachment, overlay, and owner were rolled back"
    fi
    die "VM start returned failure but domain is active; state retained for safe recovery"
  fi
  note "$vm started with the single disposable overlay"
}

guest_application_stop() {
  local vm="$1"
  [[ "${BVML_TESTING:-0}" == 1 ]] && return 0
  need jq
  local script
  case "$vm" in
    ubuntu) script=/usr/local/libexec/bvml/ubuntu-knots-rdts.sh ;;
    umbrel) script=/usr/local/libexec/bvml/umbrel-adapter.sh ;;
    startos) script=/usr/local/libexec/bvml/startos-adapter.sh ;;
  esac
  local response pid status waited=0
  response="$(virshq qemu-agent-command "$(domain "$vm")" \
    "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"$script\",\"arg\":[\"stop\"],\"capture-output\":true}}" \
    2>/dev/null)" || die "could not request clean $vm Bitcoin shutdown through QEMU guest agent"
  pid="$(jq -er '.return.pid' <<<"$response")" || die "guest agent did not return an application-stop PID"
  while :; do
    status="$(virshq qemu-agent-command "$(domain "$vm")" \
      "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}" 2>/dev/null)" ||
      die "lost guest-agent status while waiting for $vm Bitcoin shutdown"
    if [[ "$(jq -r '.return.exited // false' <<<"$status")" == true ]]; then
      [[ "$(jq -r '.return.exitcode // 1' <<<"$status")" == 0 ]] ||
        die "$vm Bitcoin shutdown hook failed; guest and attachment retained"
      break
    fi
    (( waited++ < SHUTDOWN_TIMEOUT )) || die "$vm Bitcoin shutdown hook timed out"
    sleep 1
  done
}

stop_vm() {
  local vm="$1" waited=0; valid_vm "$vm"; is_defined "$vm" || die "VM is not defined: $vm"
  assert_consistent_owner
  [[ "$(owner_vm)" == "$vm" && "$(overlay_vm)" == "$vm" ]] || die "$vm does not own the active overlay"
  if ! is_shut_off "$vm"; then
    guest_application_stop "$vm"
    virshq shutdown "$(domain "$vm")"
    while ! is_shut_off "$vm"; do
      (( waited >= SHUTDOWN_TIMEOUT )) && die "shutdown timeout; attachment and ownership retained"
      sleep 2; ((waited+=2))
    done
  fi
  detach_overlay "$vm"
  [[ -z "$(attached_vm_for_path "$OVERLAY")" ]] || die "overlay still attached; ownership retained"
  assert_no_process_reference "$OVERLAY"
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
  assert_no_process_reference "$OVERLAY"
  rm -f -- "$OVERLAY" "$OVERLAY_META" "$VERIFY_META" "$BOOTSTRAP_VERIFY"
  note "discarded $vm overlay; persistent VM disks and canonical checkpoint are unchanged"
}

reconcile_owner() {
  local attached owner
  all_shut_off
  attached="$(attached_vm_for_path "$OVERLAY" | paste -sd, -)"
  [[ -z "$attached" ]] || die "cannot reconcile: overlay remains attached to $attached"
  assert_no_process_reference "$OVERLAY"
  owner="$(owner_vm)"
  if [[ -n "$owner" ]]; then
    [[ -f "$OVERLAY" && "$(overlay_vm)" == "$owner" ]] ||
      die "owner cannot be reconciled automatically: overlay manifest disagrees"
    rm -f -- "$OWNER_FILE"
    note "cleared stale inactive owner record for retained $owner overlay"
  else note "owner state is already reconciled"; fi
}

bootstrap_attached_vm() { attached_vm_for_path "$BOOTSTRAP"; }

checkpoint_bootstrap() {
  need qemu-img; need virsh
  [[ ! -e "$CANONICAL" && ! -e "$CANONICAL_META" ]] ||
    die "canonical checkpoint already exists; use an Ubuntu overlay to update it"
  all_shut_off; assert_no_bitcoin_attachments
  [[ ! -e "$OVERLAY" && ! -e "$OVERLAY_META" && ! -e "$OWNER_FILE" ]] ||
    die "ordinary overlay/owner state exists"
  [[ ! -e "$BOOTSTRAP" && ! -e "$BOOTSTRAP_META" ]] ||
    die "bootstrap state already exists; inspect bootstrap-status"
  [[ "$BOOTSTRAP_SIZE_GIB" =~ ^[1-9][0-9]*$ ]] || die "BOOTSTRAP_SIZE_GIB must be a positive integer"
  is_defined ubuntu || die "Ubuntu VM is not defined"
  local bootstrap_id
  bootstrap_id="$(new_id)"
  qemu-img create -f qcow2 "$BOOTSTRAP" "${BOOTSTRAP_SIZE_GIB}G"
  chmod 0640 "$BOOTSTRAP"
  write_env_file "$BOOTSTRAP_META" "kind=fresh-ibd-incomplete" "bootstrap_id=$bootstrap_id" \
    "vm=ubuntu" "created=$(date -u +%FT%TZ)" "size_gib=$BOOTSTRAP_SIZE_GIB" \
    "filesystem_initialized=0" "state=created"
  invalidate_verification
  if ! virshq attach-disk "$(domain ubuntu)" "$BOOTSTRAP" vdc --config \
      --driver qemu --subdriver qcow2 --targetbus virtio; then
    rm -f -- "$BOOTSTRAP" "$BOOTSTRAP_META"
    die "bootstrap attachment failed; image rolled back"
  fi
  write_env_file "$OWNER_FILE" "vm=ubuntu" "domain=$(domain ubuntu)" "overlay=$BOOTSTRAP" \
    "bootstrap_id=$bootstrap_id" "attached_target=vdc" "kind=bootstrap"
  if ! virshq start "$(domain ubuntu)"; then
    if is_shut_off ubuntu; then
      virshq detach-disk "$(domain ubuntu)" vdc --config ||
        die "Ubuntu start failed and bootstrap detach failed; state retained"
      [[ -z "$(bootstrap_attached_vm)" ]] ||
        die "Ubuntu XML still references bootstrap; state retained"
      rm -f -- "$BOOTSTRAP" "$BOOTSTRAP_META" "$OWNER_FILE"
    fi
    die "Ubuntu bootstrap start failed"
  fi
  note "empty, unformatted bootstrap image attached; run bootstrap-init explicitly inside the new Ubuntu lifecycle"
}

bootstrap_init() {
  [[ "$(meta_get "$OWNER_FILE" kind)" == bootstrap ]] || die "no active bootstrap owner"
  [[ "$(owner_vm)" == ubuntu && "$(bootstrap_attached_vm)" == ubuntu ]] ||
    die "bootstrap owner and attachment disagree"
  [[ ! "$(is_shut_off ubuntu && echo yes)" == yes ]] || die "Ubuntu must be running for filesystem initialization"
  [[ "$(meta_get "$BOOTSTRAP_META" filesystem_initialized)" == 0 ]] ||
    die "bootstrap filesystem is already initialized"
  [[ "${1:-}" == "--confirm-device-vdc" && $# == 1 ]] ||
    die "explicit disk initialization requires --confirm-device-vdc"
  if [[ "${BVML_TESTING:-0}" != 1 ]]; then
    need jq
    local response pid status waited=0
    response="$(virshq qemu-agent-command "$(domain ubuntu)" \
      '{"execute":"guest-exec","arguments":{"path":"/usr/local/libexec/bvml/ubuntu-knots-rdts.sh","arg":["init-filesystem","--confirm-device-vdc"],"capture-output":true}}' \
      2>/dev/null)" || die "guest filesystem initialization request failed"
    pid="$(jq -er '.return.pid' <<<"$response")" || die "guest agent returned no filesystem-initialization PID"
    while :; do
      status="$(virshq qemu-agent-command "$(domain ubuntu)" \
        "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}" 2>/dev/null)" ||
        die "lost guest-agent status during filesystem initialization"
      if [[ "$(jq -r '.return.exited // false' <<<"$status")" == true ]]; then
        [[ "$(jq -r '.return.exitcode // 1' <<<"$status")" == 0 ]] ||
          die "guest refused or failed filesystem initialization; bootstrap remains uninitialized"
        break
      fi
      (( waited++ < SHUTDOWN_TIMEOUT )) || die "filesystem initialization timed out"
      sleep 1
    done
  fi
  sed -i 's/^filesystem_initialized=.*/filesystem_initialized=1/;s/^state=.*/state=ibd-in-progress/' "$BOOTSTRAP_META"
  note "bootstrap filesystem initialization explicitly requested; verify guest completion before starting Knots"
}

bootstrap_stop() {
  local waited=0
  [[ "$(meta_get "$OWNER_FILE" kind)" == bootstrap && "$(owner_vm)" == ubuntu ]] ||
    die "Ubuntu does not own an active bootstrap image"
  if ! is_shut_off ubuntu; then
    guest_application_stop ubuntu
    virshq shutdown "$(domain ubuntu)"
    while ! is_shut_off ubuntu; do
      (( waited >= SHUTDOWN_TIMEOUT )) && die "shutdown timeout; bootstrap remains attached and owned"
      sleep 2; ((waited+=2))
    done
  fi
  virshq detach-disk "$(domain ubuntu)" vdc --config ||
    die "bootstrap detach failed; ownership retained"
  [[ -z "$(bootstrap_attached_vm)" ]] || die "bootstrap remains attached; ownership retained"
  assert_no_process_reference "$BOOTSTRAP"
  rm -f -- "$OWNER_FILE"
  sed -i 's/^state=.*/state=retained-awaiting-verification/' "$BOOTSTRAP_META"
  note "bootstrap retained, detached, and awaiting overlay-specific verification"
}

bootstrap_verify() {
  need virt-cat; need virt-filesystems
  [[ -f "$BOOTSTRAP" && -f "$BOOTSTRAP_META" ]] || die "bootstrap image is missing"
  [[ "$(meta_get "$BOOTSTRAP_META" filesystem_initialized)" == 1 ]] || die "bootstrap filesystem was never initialized"
  all_shut_off; assert_no_bitcoin_attachments; [[ ! -e "$OWNER_FILE" ]] || die "bootstrap owner remains"
  assert_no_process_reference "$BOOTSTRAP"
  local tmp="$BOOTSTRAP_VERIFY.new"
  rm -f -- "$tmp"
  virt-cat -a "$BOOTSTRAP" -m /dev/sda /.bvml/ubuntu-verification.env >"$tmp" ||
    { rm -f -- "$tmp"; die "current bootstrap verification evidence is missing"; }
  printf 'bootstrap_id=%s\n' "$(meta_get "$BOOTSTRAP_META" bootstrap_id)" >>"$tmp"
  mv -- "$tmp" "$BOOTSTRAP_VERIFY"
  [[ "$(meta_get "$BOOTSTRAP_VERIFY" bootstrap_id)" == "$(meta_get "$BOOTSTRAP_META" bootstrap_id)" ]] ||
    die "verification belongs to another bootstrap image"
  [[ "$(meta_get "$BOOTSTRAP_VERIFY" filesystem_uuid)" == "$(image_filesystem_uuid "$BOOTSTRAP")" ]] ||
    die "bootstrap verification filesystem UUID does not match the image"
  verify_promotion_evidence "$BOOTSTRAP_VERIFY" bootstrap
  sed -i 's/^state=.*/state=verified-complete/' "$BOOTSTRAP_META"
  note "fresh IBD bootstrap evidence validated"
}

bootstrap_promote() {
  [[ "${1:-}" == "--confirm-synced-clean" && $# == 1 ]] ||
    die "bootstrap promotion requires --confirm-synced-clean"
  [[ ! -e "$CANONICAL" ]] || die "canonical checkpoint already exists"
  [[ "$(meta_get "$BOOTSTRAP_META" state)" == verified-complete ]] ||
    die "bootstrap is incomplete or has not been verified"
  all_shut_off; assert_no_bitcoin_attachments; [[ ! -e "$OWNER_FILE" ]] || die "bootstrap owner remains"
  assert_no_process_reference "$BOOTSTRAP"
  verify_promotion_evidence "$BOOTSTRAP_VERIFY" bootstrap
  need virt-customize
  virt-customize -a "$BOOTSTRAP" --rm /.bvml/ubuntu-verification.env >/dev/null ||
    die "could not remove transient verification evidence from bootstrap"
  validate_checkpoint_image "$BOOTSTRAP" || die "completed bootstrap image validation failed"
  local generation id
  id="$(sha256sum "$BOOTSTRAP" | awk '{print $1}')"; generation="$(new_id)"
  write_env_file "$CANONICAL_DIR/bootstrap-install-manifest.env" "id=$id" "generation=$generation" \
    "created=$(date -u +%FT%TZ)" "network=main" "blocksxor=0" "layout=root-datadir" \
    "kind=fresh-knots-rdts-ibd" "knots_version=$(meta_get "$BOOTSTRAP_VERIFY" knots_actual_version)"
  rm -f -- "$BOOTSTRAP_VERIFY"
  mv -- "$BOOTSTRAP" "$CANONICAL"
  mv -- "$CANONICAL_DIR/bootstrap-install-manifest.env" "$CANONICAL_META"
  if ! (protect_image "$CANONICAL" && validate_checkpoint_image "$CANONICAL"); then
    unprotect_image "$CANONICAL" || true
    mv -- "$CANONICAL" "$BOOTSTRAP"; mv -- "$CANONICAL_META" "$CANONICAL_DIR/bootstrap-install-manifest.env"
    die "bootstrap installation/protection failed; incomplete image restored at bootstrap path"
  fi
  rm -f -- "$BOOTSTRAP_META"
  note "fresh Knots/RDTS IBD installed as the first protected canonical checkpoint"
}

bootstrap_cleanup() {
  all_shut_off; [[ -z "$(bootstrap_attached_vm)" ]] || die "bootstrap remains attached"
  [[ ! -e "$OWNER_FILE" ]] || die "owner remains; reconcile or stop first"
  assert_no_process_reference "$BOOTSTRAP"
  rm -f -- "$BOOTSTRAP" "$BOOTSTRAP_META" "$BOOTSTRAP_VERIFY"
  note "incomplete bootstrap state removed"
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
  local source="" source_mode="" mainnet_asserted=0
  while (($#)); do case "$1" in
    --assert-source-stopped) source_mode=stopped; shift ;;
    --consistent-snapshot) source_mode=snapshot; shift ;;
    --assert-mainnet) mainnet_asserted=1; shift ;;
    --*) die "checkpoint-import SOURCE (--assert-source-stopped|--consistent-snapshot) --assert-mainnet" ;;
    *) [[ -z "$source" ]] || die "only one import source may be supplied"; source="$1"; shift ;;
  esac; done
  [[ -n "$source" ]] || die "checkpoint-import requires an explicit source path"
  [[ -n "$source_mode" ]] || die "assert a clean stop or consistent snapshot explicitly"
  (( mainnet_asserted == 1 )) || die "explicit --assert-mainnet is required after source validation"
  need qemu-img; need virt-make-fs; need virt-ls; need virt-customize; need tar
  all_shut_off; assert_no_bitcoin_attachments
  [[ ! -e "$OVERLAY" && ! -e "$OWNER_FILE" ]] || die "discard the active overlay before initial import"
  [[ ! -e "$CANONICAL" ]] || die "canonical checkpoint already exists"
  [[ -d "$source" ]] || die "source datadir does not exist: $source"
  if [[ "$source_mode" == stopped ]]; then
    [[ ! -e "$source/.lock" ]] ||
      die "source .lock exists; remove it only after proving the source node stopped cleanly"
    if command -v lsof >/dev/null && lsof +D "$source" 2>/dev/null | grep -q .; then
      die "a process has the asserted-stopped source datadir open"
    fi
  fi
  source_xor_check "$source"
  local candidate="$CANONICAL_DIR/import-candidate.qcow2" bytes size_bytes id generation
  rm -f -- "$candidate"
  local import_paths=(blocks chainstate)
  [[ ! -d "$source/indexes" ]] || import_paths+=(indexes)
  bytes="$(du -sb "${import_paths[@]/#/$source/}" | awk '{s+=$1} END {print s+0}')"
  (( bytes > 0 )) || die "source allocation could not be measured"
  size_bytes=$(( bytes + (bytes * CHECKPOINT_HEADROOM_PERCENT / 100) ))
  (( size_bytes > bytes )) || size_bytes=$((bytes + 1073741824))
  note "creating an absolute ${size_bytes}-byte import image from ${bytes} source bytes"
  tar -C "$source" -cf - --exclude='blocks/.lock' --exclude='*.log' \
    "${import_paths[@]}" |
    virt-make-fs --format=qcow2 --type=ext4 --size="$size_bytes" - "$candidate"
  virt-customize -a "$candidate" \
    --run-command "chown -R $BITCOIN_DATADIR_UID:$BITCOIN_DATADIR_GID /blocks /chainstate; chmod 0750 /blocks /chainstate; if test -d /indexes; then chown -R $BITCOIN_DATADIR_UID:$BITCOIN_DATADIR_GID /indexes; chmod 0750 /indexes; fi" \
    >/dev/null
  qemu-img check "$candidate"
  virt-ls -a "$candidate" -m /dev/sda / | grep -qx blocks || die "candidate lacks blocks/"
  virt-ls -a "$candidate" -m /dev/sda / | grep -qx chainstate || die "candidate lacks chainstate/"
  if [[ "$CHECKPOINT_INDEX_PROFILE" != none ]]; then
    virt-ls -a "$candidate" -m /dev/sda / | grep -qx indexes || die "candidate lacks verified indexes/"
  fi
  id="$(sha256sum "$candidate" | awk '{print $1}')"
  generation="$(new_id)"
  write_env_file "$CANONICAL_DIR/import-manifest.env" \
    "id=$id" "generation=$generation" "created=$(date -u +%FT%TZ)" \
    "source=$source" "source_consistency=$source_mode" "source_network_assertion=mainnet" \
    "source_bytes=$bytes" "image_bytes=$size_bytes" \
    "network=main" "blocksxor=0" "layout=root-datadir" "kind=initial-import"
  mv -- "$candidate" "$CANONICAL"
  mv -- "$CANONICAL_DIR/import-manifest.env" "$CANONICAL_META"
  if ! (protect_image "$CANONICAL" && validate_checkpoint_image "$CANONICAL"); then
    unprotect_image "$CANONICAL" || true
    mv -- "$CANONICAL" "$candidate"; mv -- "$CANONICAL_META" "$CANONICAL_DIR/import-manifest.env"
    die "import installation/protection failed; candidate restored without canonical state"
  fi
  note "protected canonical checkpoint imported from $source"
}

verify_promotion_evidence() {
  local evidence="${1:-$VERIFY_META}" kind="${2:-overlay}" key expected
  [[ -f "$evidence" ]] || die "missing current Ubuntu Knots verification evidence"
  for key in vm network blocksxor synced clean_shutdown datadir_layout rdts_validated \
    knots_actual_version artifact_sha256 rdts_profile rdts_effective_args block_height \
    header_height best_block_hash tip_time filesystem_uuid indexes_json index_sync_json shutdown_id; do
    [[ -n "$(meta_get "$evidence" "$key")" ]] || die "verification metadata missing $key"
  done
  for expected in "vm=ubuntu" "network=main" "blocksxor=0" "synced=1" \
                  "clean_shutdown=1" "datadir_layout=root-datadir" "rdts_validated=1"; do
    [[ "$(meta_get "$evidence" "${expected%%=*}")" == "${expected#*=}" ]] ||
      die "verification requirement failed: $expected"
  done
  [[ "$(meta_get "$evidence" knots_actual_version)" == "$KNOTS_VERSION" ]] ||
    die "actual Knots version does not match configured release"
  [[ "$(meta_get "$evidence" artifact_sha256)" == "$KNOTS_ARTIFACT_SHA256" ]] ||
    die "artifact digest does not match authenticated release configuration"
  [[ "$(meta_get "$evidence" rdts_profile)" == "$KNOTS_RDTS_PROFILE" ]] ||
    die "verification used another RDTS profile"
  [[ "$(meta_get "$evidence" block_height)" == "$(meta_get "$evidence" header_height)" ]] ||
    die "block and header heights differ"
  [[ "$(meta_get "$evidence" index_sync_json)" != *false* ]] ||
    die "one or more required indexes are unsynchronized"
  if [[ "$kind" == overlay ]]; then
    [[ "$(meta_get "$evidence" overlay_id)" == "$(overlay_id)" ]] ||
      die "verification belongs to another overlay"
    [[ "$(meta_get "$evidence" checkpoint_generation)" == "$(checkpoint_generation)" ]] ||
      die "verification belongs to another checkpoint generation"
  else
    [[ "$(meta_get "$evidence" bootstrap_id)" == "$(meta_get "$BOOTSTRAP_META" bootstrap_id)" ]] ||
      die "verification belongs to another bootstrap"
  fi
}

validate_checkpoint_image() {
  local image="$1" xor_bytes
  qemu-img check "$image" >/dev/null || return 1
  qemu-img info --output=json "$image" | grep -q '"backing-filename"' && return 1
  virt-ls -a "$image" -m /dev/sda / | grep -qx blocks || return 1
  virt-ls -a "$image" -m /dev/sda / | grep -qx chainstate || return 1
  xor_bytes="$(virt-cat -a "$image" -m /dev/sda /blocks/xor.dat 2>/dev/null |
    od -An -v -tu1 | tr -s ' ' '\n' | sed '/^$/d' || true)"
  [[ -z "$xor_bytes" ]] || ! grep -qv '^0$' <<<"$xor_bytes"
}

checkpoint_verify() {
  need virt-cat; need virt-filesystems
  [[ "$(overlay_vm)" == ubuntu ]] || die "verification is only valid for an Ubuntu overlay"
  [[ ! -e "$OWNER_FILE" ]] || die "stop Ubuntu before extracting verification"
  all_shut_off; assert_no_bitcoin_attachments; assert_overlay_chain
  local candidate="$ACTIVE_DIR/ubuntu-verification.new"
  rm -f -- "$candidate"
  virt-cat -a "$OVERLAY" -m /dev/sda /.bvml/ubuntu-verification.env >"$candidate" ||
    { rm -f -- "$candidate"; die "guest verification file missing; run ubuntu-knots-rdts.sh verify-shutdown"; }
  printf 'overlay_id=%s\ncheckpoint_generation=%s\n' "$(overlay_id)" "$(checkpoint_generation)" >>"$candidate"
  chmod 0600 "$candidate"
  mv -- "$candidate" "$VERIFY_META"
  [[ "$(meta_get "$VERIFY_META" filesystem_uuid)" == "$(image_filesystem_uuid "$OVERLAY")" ]] ||
    die "verification filesystem UUID does not match the current overlay"
  verify_promotion_evidence "$VERIFY_META" overlay
  note "Ubuntu Knots/RDTS shutdown verification imported"
}

checkpoint_promote() {
  [[ "${1:-}" == "--confirm-synced-clean" && $# == 1 ]] ||
    die "promotion requires --confirm-synced-clean after guest verification"
  need qemu-img; need virt-ls; need virt-cat; need virt-customize; require_canonical
  [[ "$(overlay_vm)" == ubuntu ]] || die "only an Ubuntu overlay may be promoted"
  [[ ! -e "$OWNER_FILE" ]] || die "runtime owner remains; stop Ubuntu first"
  all_shut_off; assert_consistent_owner; assert_no_bitcoin_attachments; assert_no_extra_overlays
  assert_no_process_reference "$OVERLAY"; assert_no_process_reference "$CANONICAL"
  assert_overlay_chain; verify_promotion_evidence "$VERIFY_META" overlay
  qemu-img check -r leaks "$OVERLAY"
  local candidate="$CANONICAL_DIR/promotion-candidate.qcow2"
  local candidate_meta="$CANONICAL_DIR/promotion-manifest.env" id
  rm -f -- "$candidate" "$candidate_meta"
  qemu-img convert -p -O qcow2 "$OVERLAY" "$candidate"
  virt-customize -a "$candidate" --rm /.bvml/ubuntu-verification.env >/dev/null
  validate_checkpoint_image "$candidate" || { rm -f -- "$candidate"; die "promotion candidate validation failed"; }
  id="$(sha256sum "$candidate" | awk '{print $1}')"
  write_env_file "$candidate_meta" "id=$id" "created=$(date -u +%FT%TZ)" \
    "generation=$(new_id)" \
    "network=main" "blocksxor=0" "layout=root-datadir" "kind=knots-rdts-promotion" \
    "knots_version=$(meta_get "$VERIFY_META" knots_actual_version)"
  local required available pending="$CANONICAL_DIR/previous-canonical.pending"
  local pending_meta="$CANONICAL_DIR/previous-manifest.pending"
  required="$(du -B1 "$CANONICAL" | awk '{print $1}')"
  available="$(df -B1 --output=avail "${ROLLBACK_DESTINATION:-$CANONICAL_DIR}" | tail -1 | tr -d ' ')"
  note "rollback retention requires approximately $required bytes; $available bytes available"
  if [[ "$ROLLBACK_RETENTION" != none && "$available" -lt "$required" ]]; then
    die "insufficient rollback space; configure a larger ROLLBACK_DESTINATION or ROLLBACK_RETENTION=none"
  fi
  [[ ! -e "$ROLLBACK" && ! -e "$ROLLBACK_META" ]] ||
    die "rollback checkpoint already exists; remove it explicitly first"
  if [[ "$ROLLBACK_RETENTION" != none && -n "$ROLLBACK_DESTINATION" ]]; then
    [[ -d "$ROLLBACK_DESTINATION" ]] || die "external rollback destination must be an existing directory"
    cp --reflink=auto --sparse=always "$CANONICAL" "$ROLLBACK"
    cp "$CANONICAL_META" "$ROLLBACK_META"
    validate_checkpoint_image "$ROLLBACK" || { rm -f -- "$ROLLBACK" "$ROLLBACK_META"; die "external rollback copy validation failed"; }
    protect_image "$ROLLBACK"
  fi
  unprotect_image "$CANONICAL"
  mv -- "$CANONICAL" "$pending"; mv -- "$CANONICAL_META" "$pending_meta"
  if ! mv -- "$candidate" "$CANONICAL"; then
    mv -- "$pending" "$CANONICAL"; mv -- "$pending_meta" "$CANONICAL_META"
    protect_image "$CANONICAL"; die "candidate installation failed; previous canonical restored"
  fi
  mv -- "$candidate_meta" "$CANONICAL_META"
  if ! (protect_image "$CANONICAL" && validate_checkpoint_image "$CANONICAL"); then
    unprotect_image "$CANONICAL"
    mv -- "$CANONICAL" "$candidate"; mv -- "$CANONICAL_META" "$candidate_meta"
    mv -- "$pending" "$CANONICAL"; mv -- "$pending_meta" "$CANONICAL_META"
    protect_image "$CANONICAL"
    write_env_file "$RECOVERY_META" "operation=promotion" "result=automatic-restore" "failed_candidate=$candidate"
    die "installed candidate validation failed; previous canonical automatically restored and protected"
  fi
  if [[ "$ROLLBACK_RETENTION" != none && -z "$ROLLBACK_DESTINATION" ]]; then
    mv -- "$pending" "$ROLLBACK"; mv -- "$pending_meta" "$ROLLBACK_META"; protect_image "$ROLLBACK"
  else
    rm -f -- "$pending" "$pending_meta"
  fi
  rm -f -- "$OVERLAY" "$OVERLAY_META" "$VERIFY_META"
  note "checkpoint promoted; previous canonical preserved as rollback"
}

checkpoint_rollback() {
  require_canonical; [[ -f "$ROLLBACK" && -f "$ROLLBACK_META" ]] || die "rollback checkpoint is missing"
  all_shut_off; assert_no_bitcoin_attachments
  assert_no_process_reference "$CANONICAL"; assert_no_process_reference "$ROLLBACK"
  [[ ! -e "$OVERLAY" && ! -e "$OWNER_FILE" ]] || die "discard the active overlay before rollback"
  validate_checkpoint_image "$ROLLBACK" || die "rollback candidate failed independent validation; canonical unchanged"
  local swap="$CANONICAL_DIR/rollback-swap.qcow2" swapmeta="$CANONICAL_DIR/rollback-swap.env"
  if [[ -n "$ROLLBACK_DESTINATION" ]]; then
    local install_candidate="$CANONICAL_DIR/rollback-install-candidate.qcow2"
    local install_meta="$CANONICAL_DIR/rollback-install-candidate.env"
    cp --reflink=auto --sparse=always "$ROLLBACK" "$install_candidate"
    cp "$ROLLBACK_META" "$install_meta"
    validate_checkpoint_image "$install_candidate" ||
      { rm -f -- "$install_candidate" "$install_meta"; die "local rollback installation candidate invalid"; }
    unprotect_image "$CANONICAL"
    mv -- "$CANONICAL" "$swap"; mv -- "$CANONICAL_META" "$swapmeta"
    mv -- "$install_candidate" "$CANONICAL"; mv -- "$install_meta" "$CANONICAL_META"
    if ! validate_checkpoint_image "$CANONICAL"; then
      mv -- "$CANONICAL" "$install_candidate"; mv -- "$CANONICAL_META" "$install_meta"
      mv -- "$swap" "$CANONICAL"; mv -- "$swapmeta" "$CANONICAL_META"
      protect_image "$CANONICAL"
      write_env_file "$RECOVERY_META" "operation=rollback" "result=automatic-reverse"
      die "external rollback post-install validation failed; previous canonical restored"
    fi
    unprotect_image "$ROLLBACK"
    cp --reflink=auto --sparse=always "$swap" "$ROLLBACK.new"
    cp "$swapmeta" "$ROLLBACK_META.new"
    mv -- "$ROLLBACK.new" "$ROLLBACK"; mv -- "$ROLLBACK_META.new" "$ROLLBACK_META"
    rm -f -- "$swap" "$swapmeta"
    protect_image "$CANONICAL"; protect_image "$ROLLBACK"
    note "canonical and external rollback checkpoints exchanged safely"
    return
  fi
  unprotect_image "$CANONICAL"; unprotect_image "$ROLLBACK"
  mv -- "$CANONICAL" "$swap"; mv -- "$CANONICAL_META" "$swapmeta"
  if ! mv -- "$ROLLBACK" "$CANONICAL"; then mv -- "$swap" "$CANONICAL"; mv -- "$swapmeta" "$CANONICAL_META"; protect_image "$CANONICAL"; die "rollback installation failed"; fi
  mv -- "$ROLLBACK_META" "$CANONICAL_META"; mv -- "$swap" "$ROLLBACK"; mv -- "$swapmeta" "$ROLLBACK_META"
  if ! validate_checkpoint_image "$CANONICAL"; then
    mv -- "$CANONICAL" "$swap.failed"; mv -- "$CANONICAL_META" "$swapmeta.failed"
    mv -- "$ROLLBACK" "$CANONICAL"; mv -- "$ROLLBACK_META" "$CANONICAL_META"
    mv -- "$swap.failed" "$ROLLBACK"; mv -- "$swapmeta.failed" "$ROLLBACK_META"
    protect_image "$CANONICAL"; protect_image "$ROLLBACK"
    write_env_file "$RECOVERY_META" "operation=rollback" "result=automatic-reverse"
    die "rollback post-install validation failed; previous canonical automatically restored"
  fi
  protect_image "$CANONICAL"; protect_image "$ROLLBACK"
  note "canonical and rollback checkpoints exchanged"
}

rollback_remove() {
  [[ "${1:-}" == "--confirm-remove" && $# == 1 ]] || die "rollback-remove requires --confirm-remove"
  all_shut_off; assert_no_bitcoin_attachments
  [[ -f "$ROLLBACK" ]] || die "no rollback checkpoint exists"
  assert_no_process_reference "$ROLLBACK"
  validate_checkpoint_image "$ROLLBACK" || die "refusing to remove an invalid image without manual recovery"
  unprotect_image "$ROLLBACK"
  rm -f -- "$ROLLBACK" "$ROLLBACK_META"
  note "obsolete rollback checkpoint removed"
}

adapter_status() {
  local vm="${1:-}"
  [[ -z "$vm" ]] || valid_vm "$vm"
  [[ -z "$vm" || "$vm" == ubuntu ]] && echo "ubuntu: module=guest/ubuntu-knots-rdts.sh knots=${KNOTS_VERSION:-UNCONFIGURED} rdts_profile=${KNOTS_RDTS_PROFILE:-UNCONFIGURED}"
  [[ -z "$vm" || "$vm" == umbrel ]] && echo "umbrel: module=guest/umbrel-adapter.sh supported_release=${UMBREL_SUPPORTED_VERSION:-UNCONFIGURED}; run adapter verify inside guest"
  [[ -z "$vm" || "$vm" == startos ]] && echo "startos: module=guest/startos-adapter.sh supported_release=${STARTOS_SUPPORTED_VERSION:-UNCONFIGURED}; run adapter verify inside guest"
}

adapter_guest_action() {
  local vm="$1" action="$2"; valid_vm "$vm"
  [[ "$vm" != ubuntu ]] || die "Ubuntu uses its Knots bootstrap module, not a platform package adapter"
  [[ "$(owner_vm)" == "$vm" && ! "$(is_shut_off "$vm" && echo yes)" == yes ]] ||
    die "$vm must actively own the overlay"
  local script="/usr/local/libexec/bvml/${vm}-adapter.sh"
  virshq qemu-agent-command "$(domain "$vm")" \
    "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"$script\",\"arg\":[\"$action\"],\"capture-output\":true}}" \
    >/dev/null || die "$vm adapter $action request failed; inspect guest-agent output"
  note "$vm adapter $action requested; run adapter-status/guest verify before claiming readiness"
}

validate_all() { exec "$ROOT/scripts/vm/validate.sh"; }
status_all() { exec "$ROOT/scripts/vm/status.sh"; }

case "$command" in
  init) with_lock note "storage initialized at $BVML_STORAGE" ;;
  create) with_lock "$ROOT/scripts/vm/create.sh" "${1:?VM required}" ;;
  start) with_lock start_vm "${1:?VM required}" ;;
  stop) with_lock stop_vm "${1:?VM required}" ;;
  discard) with_lock discard_overlay "${1:-}" ;;
  reset) with_lock reset_vm "${1:?VM required}" ;;
  reconcile) with_lock reconcile_owner ;;
  checkpoint-bootstrap) with_lock checkpoint_bootstrap ;;
  bootstrap-init) with_lock bootstrap_init "$@" ;;
  bootstrap-stop) with_lock bootstrap_stop ;;
  bootstrap-verify) with_lock bootstrap_verify ;;
  bootstrap-promote) with_lock bootstrap_promote "$@" ;;
  bootstrap-cleanup) with_lock bootstrap_cleanup ;;
  bootstrap-status) status_all ;;
  checkpoint-import) with_lock checkpoint_import "$@" ;;
  checkpoint-verify) with_lock checkpoint_verify ;;
  checkpoint-promote) with_lock checkpoint_promote "$@" ;;
  checkpoint-protect) with_lock protect_image "$CANONICAL" ;;
  checkpoint-rollback) with_lock checkpoint_rollback ;;
  rollback-remove) with_lock rollback_remove "$@" ;;
  adapter-setup) with_lock adapter_guest_action "${1:?VM required}" setup ;;
  adapter-validate) with_lock adapter_guest_action "${1:?VM required}" verify ;;
  adapter-status) adapter_status "${1:-}" ;;
  validate) with_lock validate_all ;;
  status) status_all ;;
  *) die "unknown command: $command" ;;
esac
