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

detach_image() {
  local vm="$1" image="$2" target
  target="$(target_for_source "$vm" "$image")"
  [[ -z "$target" ]] || virshq detach-disk "$(domain "$vm")" "$target" --config
}

write_owner_record() {
  local kind="$1" vm="$2" image="$3" identity="$4" serial="$5"
  [[ "${BVML_FAIL_OWNER_WRITE:-0}" != 1 ]] || return 1
  write_env_file "$OWNER_FILE" "kind=$kind" "vm=$vm" "domain=$(domain "$vm")" \
    "image=$image" "overlay=$image" "identity=$identity" "attached_target=vdc" \
    "disk_serial=$serial" "started=$(date -u +%FT%TZ)"
  if [[ "$kind" == overlay ]]; then printf 'overlay_id=%s\n' "$identity" >>"$OWNER_FILE"; fi
  if [[ "$kind" == bootstrap ]]; then printf 'bootstrap_id=%s\n' "$identity" >>"$OWNER_FILE"; fi
  return 0
}

assert_overlay_chain() {
  [[ -f "$OVERLAY" && -f "$OVERLAY_META" ]] || die "active overlay or manifest is missing"
  [[ "$(meta_get "$OVERLAY_META" backing)" == "$CANONICAL" ]] || die "overlay manifest backing path is invalid"
  [[ "$(meta_get "$OVERLAY_META" canonical_id)" == "$(canonical_id)" ]] ||
    die "overlay survived a checkpoint replacement; discard it"
  [[ "$(meta_get "$OVERLAY_META" checkpoint_generation)" == "$(checkpoint_generation)" ]] ||
    die "overlay checkpoint generation does not match the canonical checkpoint"
  [[ -n "$(overlay_id)" ]] || die "overlay manifest lacks a unique overlay ID"
  local backing
  backing="$(qemu-img info --output=json "$OVERLAY" | sed -n 's/.*"backing-filename":[[:space:]]*"\([^"]*\)".*/\1/p')"
  [[ "$backing" == "$CANONICAL" ]] || die "overlay qcow2 backing is '$backing', expected '$CANONICAL'"
}

assert_consistent_owner() {
  assert_lifecycle_invariants
}

transactional_attach_start() {
  local kind="$1" vm="$2" image meta identity serial nonce size_bytes
  case "$kind" in
    overlay)
      image="$OVERLAY"; meta="$OVERLAY_META"; identity="$(new_id)"
      serial="BVMLO-${identity:0:12}"
      qemu-img create -f qcow2 -F qcow2 -b "$CANONICAL" "$image" ||
        die "overlay creation failed"
      write_env_file "$meta" \
        "kind=overlay" "vm=$vm" "canonical_id=$(canonical_id)" "created=$(date -u +%FT%TZ)" \
        "backing=$CANONICAL" "overlay_id=$identity" "checkpoint_generation=$(checkpoint_generation)" \
        "size_bytes=$(qemu-img info --output=json "$CANONICAL" | jq -r '.["virtual-size"]')" \
        "disk_serial=$serial"
      ;;
    bootstrap)
      image="$BOOTSTRAP"; meta="$BOOTSTRAP_META"; identity="$(new_id)"
      serial="BVMLB-${identity:0:12}"; nonce="$(new_id)"
      size_bytes=$((BOOTSTRAP_SIZE_GIB * 1073741824))
      qemu-img create -f qcow2 "$image" "${BOOTSTRAP_SIZE_GIB}G" ||
        die "bootstrap image creation failed"
      write_env_file "$meta" "kind=bootstrap" "bootstrap_id=$identity" \
        "vm=$vm" "created=$(date -u +%FT%TZ)" "size_gib=$BOOTSTRAP_SIZE_GIB" \
        "size_bytes=$size_bytes" "disk_serial=$serial" "bootstrap_nonce=$nonce" \
        "profile_generation_id=$(profile_generation_id)" \
        "profile_generation_digest=$(active_profile_generation_digest)" \
        "filesystem_initialized=0" "state=created"
      ;;
    *) die "unsupported transactional image kind: $kind" ;;
  esac
  chmod 0640 "$image"
  if [[ "${BVML_TESTING:-0}" != 1 ]]; then
    setfacl -m "u:$QEMU_USER:rw-" "$image" ||
      { rm -f -- "$image" "$meta"; die "could not grant QEMU image access"; }
  fi
  invalidate_verification
  if ! virshq attach-disk "$(domain "$vm")" "$image" vdc --config \
      --driver qemu --subdriver qcow2 --targetbus virtio --serial "$serial"; then
    rm -f -- "$image" "$meta"
    die "$kind attachment failed; image and manifest rolled back"
  fi
  if [[ "$(attached_vm_for_path "$image" | paste -sd, -)" != "$vm" ||
        "$(attachment_serial_for_path "$vm" "$image")" != "$serial" ]]; then
    if detach_image "$vm" "$image" && [[ -z "$(attached_vm_for_path "$image")" ]]; then
      assert_no_process_reference "$image"
      rm -f -- "$image" "$meta"
      die "$kind attachment identity verification failed; attachment and files rolled back"
    fi
    write_owner_record "$kind" "$vm" "$image" "$identity" "$serial" ||
      write_env_file "$RECOVERY_META" "operation=attachment-verification" "kind=$kind" \
        "vm=$vm" "image=$image" "identity=$identity" "disk_serial=$serial"
    die "$kind attachment identity verification failed and detach failed; recoverable state was retained"
  fi
  if ! write_owner_record "$kind" "$vm" "$image" "$identity" "$serial"; then
    local original="$kind owner metadata write failed"
    detach_image "$vm" "$image" ||
      die "$original; detach also failed, so image and manifest were retained"
    [[ -z "$(attached_vm_for_path "$image")" ]] ||
      die "$original; domain XML still references the image, so it was retained"
    assert_no_process_reference "$image"
    rm -f -- "$image" "$meta"
    die "$original; attachment, image, and manifest rolled back"
  fi
  if ! virshq start "$(domain "$vm")"; then
    if is_shut_off "$vm"; then
      detach_image "$vm" "$image" || die "VM start failed and detach failed; state retained"
      [[ -z "$(attached_vm_for_path "$image")" ]] ||
        die "VM start failed and domain XML still references image; state retained"
      assert_no_process_reference "$image"
      rm -f -- "$image" "$meta" "$OWNER_FILE" "$VERIFY_META" "$BOOTSTRAP_VERIFY"
      die "VM start failed; attachment, image, manifest, and owner were rolled back"
    fi
    die "VM start returned failure but domain is active; state retained for safe recovery"
  fi
}

start_vm() {
  local vm="$1" mode="${2:-}"
  valid_vm "$vm"; need qemu-img; need virsh
  [[ -z "$mode" || "$mode" == --adapter-setup ]] || die "unsupported start option: $mode"
  if [[ "$vm" != ubuntu ]]; then
    if [[ "$mode" == --adapter-setup ]]; then
      note "$vm is entering explicit unverified adapter-setup mode"
    else
      jq -e --arg platform "$vm" --arg umbrel_profile "${UMBREL_PROFILE_SHA256,,}" '
        .platform == $platform and
        (.last_validation_result == "ok" or
          ($platform == "umbrel" and .provisioning_result == "ok" and
           .profile_digest == $umbrel_profile))
      ' \
        "$ADAPTER_STATE_DIR/$vm.json" >/dev/null 2>&1 ||
        die "$vm adapter is not provisioned; run guest-provision or use explicit adapter-setup recovery mode"
    fi
  elif [[ -n "$mode" ]]; then
    die "--adapter-setup is only valid for UmbrelOS or StartOS"
  fi
  canonical_preflight; is_defined "$vm" || die "VM is not defined: $vm"
  all_shut_off
  [[ -e "$OVERLAY" || -e "$OVERLAY_META" ]] || rm -f -- "$VERIFY_META"
  assert_consistent_owner; assert_no_extra_overlays
  [[ ! -e "$OVERLAY" && ! -e "$OVERLAY_META" && ! -e "$BOOTSTRAP" && ! -e "$BOOTSTRAP_META" ]] ||
    die "Bitcoin working state is retained; discard, clean up, or promote it first"
  assert_no_bitcoin_attachments
  transactional_attach_start overlay "$vm"
  note "$vm started with the single disposable overlay"
}

guest_application_stop() {
  local vm="$1" script
  case "$vm" in
    ubuntu) script=/usr/local/libexec/bvml/ubuntu-knots-rdts.sh ;;
    umbrel) script="$(jq -r .os.data_directory "$UMBREL_PROFILE")/.bvml/bin/umbrel-adapter.sh" ;;
    startos) script=/usr/local/libexec/bvml/startos-adapter.sh ;;
  esac
  platform_exec_sync "$vm" "$script" "$GUEST_EXEC_TIMEOUT" stop
}

stop_vm() {
  local vm="$1" waited=0; valid_vm "$vm"; is_defined "$vm" || die "VM is not defined: $vm"
  assert_consistent_owner
  [[ "$(owner_vm)" == "$vm" && "$(overlay_vm)" == "$vm" ]] || die "$vm does not own the active overlay"
  if ! is_shut_off "$vm"; then
    if ! (guest_application_stop "$vm"); then
      write_env_file "$ADAPTER_RECOVERY_META" "operation=application-stop" "vm=$vm" \
        "image=$OVERLAY" "result=recovery-required" "recorded=$(date -u +%FT%TZ)"
      die "$vm application stop failed; VM, mount, attachment, owner, and overlay were preserved"
    fi
    virshq shutdown "$(domain "$vm")"
    while ! is_shut_off "$vm"; do
      (( waited >= SHUTDOWN_TIMEOUT )) && die "shutdown timeout; attachment and ownership retained"
      sleep 2; ((waited+=2))
    done
  fi
  detach_image "$vm" "$OVERLAY"
  [[ -z "$(attached_vm_for_path "$OVERLAY")" ]] || die "overlay still attached; ownership retained"
  assert_no_process_reference "$OVERLAY"
  rm -f -- "$OWNER_FILE"
  [[ "$vm" != umbrel ]] || rm -f -- "$ADAPTER_RECOVERY_META"
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
  local attached owner kind image meta manifest_vm manifest_id owner_id manifest_serial owner_serial
  if [[ -f "$ADAPTER_RECOVERY_META" ]] && ! is_shut_off umbrel; then
    die "Umbrel recovery is active while the VM is $(domain_state umbrel); inspect umbreld app state, container process, datadir mount, attachment, and owner before clean stop"
  fi
  all_shut_off
  owner="$(owner_vm)"
  if [[ -n "$owner" ]]; then
    kind="$(owner_kind)"; image="$(owner_image)"; owner_id="$(meta_get "$OWNER_FILE" identity)"
    case "$kind" in
      overlay) meta="$OVERLAY_META"; manifest_vm="$(overlay_vm)"; manifest_id="$(overlay_id)";
        [[ "$image" == "$OVERLAY" ]] || die "stale overlay owner has an unexpected image path" ;;
      bootstrap) meta="$BOOTSTRAP_META"; manifest_vm="$(meta_get "$meta" vm)";
        manifest_id="$(meta_get "$meta" bootstrap_id)"
        [[ "$image" == "$BOOTSTRAP" ]] || die "stale bootstrap owner has an unexpected image path" ;;
      *) die "owner kind is missing or unsupported; automatic reconciliation is unsafe" ;;
    esac
    manifest_serial="$(meta_get "$meta" disk_serial)"
    owner_serial="$(meta_get "$OWNER_FILE" disk_serial)"
    attached="$(attached_vm_for_path "$image" | paste -sd, -)"
    [[ -z "$attached" ]] || die "cannot reconcile: $kind image remains attached to $attached"
    assert_no_process_reference "$image"
    [[ -f "$image" && -f "$meta" && "$manifest_vm" == "$owner" && "$manifest_id" == "$owner_id" &&
       -n "$owner_serial" && "$manifest_serial" == "$owner_serial" ]] ||
      die "owner cannot be reconciled automatically: $kind image/manifest disagrees"
    [[ "$(bitcoin_attachment_count)" == 0 ]] || die "conflicting Bitcoin storage attachment exists"
    [[ ! -f "$OVERLAY" || ! -f "$BOOTSTRAP" ]] || die "bootstrap and ordinary overlay coexist"
    rm -f -- "$OWNER_FILE"
    [[ "$owner" != umbrel ]] || rm -f -- "$ADAPTER_RECOVERY_META"
    note "cleared stale detached $kind owner for retained $owner image"
  else note "owner state is already reconciled"; fi
}

bootstrap_attached_vm() { attached_vm_for_path "$BOOTSTRAP"; }

checkpoint_bootstrap() {
  need qemu-img; need virsh
  assert_initialization_state_empty "fresh bootstrap"
  [[ "$BOOTSTRAP_SIZE_GIB" =~ ^[1-9][0-9]*$ ]] || die "BOOTSTRAP_SIZE_GIB must be a positive integer"
  is_defined ubuntu || die "Ubuntu VM is not defined"
  transactional_attach_start bootstrap ubuntu
  note "empty, unformatted bootstrap image attached; run bootstrap-init explicitly inside the new Ubuntu lifecycle"
}

bootstrap_init() {
  [[ "$(meta_get "$OWNER_FILE" kind)" == bootstrap ]] || die "no active bootstrap owner"
  [[ "$(owner_vm)" == ubuntu && "$(bootstrap_attached_vm)" == ubuntu ]] ||
    die "bootstrap owner and attachment disagree"
  [[ ! "$(is_shut_off ubuntu && echo yes)" == yes ]] || die "Ubuntu must be running for filesystem initialization"
  [[ "$(meta_get "$BOOTSTRAP_META" filesystem_initialized)" == 0 ]] ||
    die "bootstrap filesystem is already initialized"
  [[ "${1:-}" == "--confirm-bootstrap-format" && $# == 1 ]] ||
    die "explicit disk initialization requires --confirm-bootstrap-format"
  guest_exec_sync ubuntu /usr/local/libexec/bvml/ubuntu-knots-rdts.sh 30 \
    stage-bootstrap \
    "$(meta_get "$BOOTSTRAP_META" bootstrap_id)" \
    "$(meta_get "$BOOTSTRAP_META" disk_serial)" \
    "$(meta_get "$BOOTSTRAP_META" size_bytes)" \
    "$(meta_get "$BOOTSTRAP_META" bootstrap_nonce)"
  guest_exec_sync ubuntu /usr/local/libexec/bvml/ubuntu-knots-rdts.sh "$GUEST_EXEC_TIMEOUT" \
    init-filesystem --confirm-bootstrap-format \
    "$(meta_get "$BOOTSTRAP_META" bootstrap_id)" \
    "$(meta_get "$BOOTSTRAP_META" disk_serial)" \
    "$(meta_get "$BOOTSTRAP_META" size_bytes)" \
    "$(meta_get "$BOOTSTRAP_META" bootstrap_nonce)"
  sed -i 's/^filesystem_initialized=.*/filesystem_initialized=1/;s/^state=.*/state=ibd-in-progress/' "$BOOTSTRAP_META"
  note "bootstrap filesystem initialized after guest identity and signature checks completed"
}

bootstrap_stop() {
  local waited=0
  [[ "$(meta_get "$OWNER_FILE" kind)" == bootstrap && "$(owner_vm)" == ubuntu ]] ||
    die "Ubuntu does not own an active bootstrap image"
  assert_consistent_owner
  if ! is_shut_off ubuntu; then
    guest_application_stop ubuntu
    virshq shutdown "$(domain ubuntu)"
    while ! is_shut_off ubuntu; do
      (( waited >= SHUTDOWN_TIMEOUT )) && die "shutdown timeout; bootstrap remains attached and owned"
      sleep 2; ((waited+=2))
    done
  fi
  detach_image ubuntu "$BOOTSTRAP" ||
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
  validate_profile_generation
  local system_image release_guest rdts_guest checkpoint_guest
  system_image="$(vm_dir ubuntu)/system.qcow2"
  release_guest="$(virt-cat -a "$system_image" /etc/bvml/releases/knots-version.env | sha256sum | awk '{print $1}')"
  rdts_guest="$(virt-cat -a "$system_image" /etc/bvml/releases/knots-rdts.env | sha256sum | awk '{print $1}')"
  checkpoint_guest="$(virt-cat -a "$system_image" /etc/bvml/checkpoint-profile.json | sha256sum | awk '{print $1}')"
  [[ "$release_guest" == "${KNOTS_RELEASE_PROFILE_SHA256,,}" &&
     "$rdts_guest" == "${KNOTS_RDTS_PROFILE_SHA256,,}" &&
     "$checkpoint_guest" == "${CHECKPOINT_PROFILE_SHA256,,}" ]] ||
    { rm -f -- "$tmp"; die "stopped Ubuntu profile generation differs from the host-approved generation"; }
  printf '%s\n' \
    "bootstrap_id=$(meta_get "$BOOTSTRAP_META" bootstrap_id)" \
    "release_profile_sha256=$release_guest" \
    "profile_generation_id=$(profile_generation_id)" \
    "profile_generation_digest=$(active_profile_generation_digest)" >>"$tmp"
  [[ "$(meta_get "$BOOTSTRAP_META" profile_generation_id)" == "$(profile_generation_id)" ||
     -z "$(meta_get "$BOOTSTRAP_META" profile_generation_id)" ]] ||
    { rm -f -- "$tmp"; die "bootstrap manifest belongs to another profile generation"; }
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
  [[ "$ROLLBACK_RETENTION" == none ]] ||
    die "first low-space promotion requires ROLLBACK_RETENTION=none"
  need guestfish; need qemu-img; need sha256sum
  validate_checkpoint_image "$BOOTSTRAP" ||
    die "verified bootstrap image failed final checkpoint validation"
  local generation id bundle raw_evidence info_file check_file domain_xml meta_tmp
  generation="$(new_id)"
  bundle="$RUN_DIR/recovery-bundles/$(meta_get "$BOOTSTRAP_META" bootstrap_id)-promotion"
  raw_evidence="$bundle/guest-verification.env"
  if [[ -d "$bundle" ]]; then
    [[ -s "$raw_evidence" && -s "$bundle/host-verification.env" &&
       "$(meta_get "$bundle/bootstrap-manifest.env" bootstrap_id)" == "$(meta_get "$BOOTSTRAP_META" bootstrap_id)" ]] ||
      die "existing promotion recovery bundle is incomplete or belongs to another bootstrap: $bundle"
  else
    install -d -m 0700 "$bundle"
    virt-cat -a "$BOOTSTRAP" -m /dev/sda /.bvml/ubuntu-verification.env >"$raw_evidence" ||
      { rm -f -- "$bundle"/*; rmdir "$bundle"; die "could not preserve in-image verification evidence"; }
    cp -- "$BOOTSTRAP_META" "$bundle/bootstrap-manifest.env"
    cp -- "$BOOTSTRAP_VERIFY" "$bundle/host-verification.env"
    cp -- "$KNOTS_RELEASE_PROFILE" "$bundle/knots-release-profile.env"
    cp -- "$KNOTS_RDTS_PROFILE" "$bundle/knots-rdts-profile.env"
    cp -- "$CHECKPOINT_PROFILE_FILE" "$bundle/checkpoint-profile.json"
    domain_xml="$bundle/ubuntu-domain.xml"
    virshq dumpxml "$(domain ubuntu)" --inactive >"$domain_xml"
    info_file="$bundle/qemu-img-info.json"; check_file="$bundle/qemu-img-check.txt"
    qemu-img info --output=json "$BOOTSTRAP" >"$info_file"
    qemu-img check "$BOOTSTRAP" >"$check_file"
    {
      printf 'bootstrap_id=%s\n' "$(meta_get "$BOOTSTRAP_META" bootstrap_id)"
      printf 'filesystem_uuid=%s\n' "$(meta_get "$BOOTSTRAP_VERIFY" filesystem_uuid)"
      printf 'profile_generation_id=%s\n' "$(meta_get "$BOOTSTRAP_VERIFY" profile_generation_id)"
      printf 'knots_binary_sha256=%s\n' "$(meta_get "$BOOTSTRAP_VERIFY" artifact_sha256)"
      printf 'block_height=%s\n' "$(meta_get "$BOOTSTRAP_VERIFY" block_height)"
      printf 'best_block_hash=%s\n' "$(meta_get "$BOOTSTRAP_VERIFY" best_block_hash)"
      printf 'best_block_time=%s\n' "$(meta_get "$BOOTSTRAP_VERIFY" best_block_time)"
    } >"$bundle/recovery-summary.env"
    sha256sum "$bundle"/* >"$bundle/bundle.sha256"
  fi
  sync -f "$BOOTSTRAP"; sync -f "$ACTIVE_DIR"; sync -f "$bundle"

  # The only blockchain-sized image is modified only to remove transient
  # evidence, then renamed atomically on the same filesystem.
  guestfish_data_disk "$BOOTSTRAP" rm /.bvml/ubuntu-verification.env >/dev/null ||
    die "transient evidence cleanup failed; bootstrap path and host evidence remain intact"
  sync -f "$BOOTSTRAP"; sync -f "$ACTIVE_DIR"
  id="$(sha256sum "$BOOTSTRAP" | awk '{print $1}')"
  printf '%s  %s\n' "$id" "$(basename "$CANONICAL")" >"$bundle/canonical-image.sha256"
  meta_tmp="$CANONICAL_META.new"
  write_env_file "$meta_tmp" "id=$id" "generation=$generation" \
    "created=$(date -u +%FT%TZ)" "network=main" "blocksxor=0" "layout=root-datadir" \
    "kind=fresh-knots-rdts-ibd" "rollback_retention=none" "disaster_recovery=re-IBD" \
    "source_bootstrap_id=$(meta_get "$BOOTSTRAP_META" bootstrap_id)" \
    "filesystem_uuid=$(meta_get "$BOOTSTRAP_VERIFY" filesystem_uuid)" \
    "knots_version_normalized=$(meta_get "$BOOTSTRAP_VERIFY" knots_version_normalized)" \
    "knots_artifact_sha256=$(meta_get "$BOOTSTRAP_VERIFY" artifact_sha256)" \
    "release_profile_sha256=$(meta_get "$BOOTSTRAP_VERIFY" release_profile_sha256)" \
    "rdts_profile_name=$(meta_get "$BOOTSTRAP_VERIFY" rdts_profile_name)" \
    "rdts_profile_sha256=$(meta_get "$BOOTSTRAP_VERIFY" rdts_profile_sha256)" \
    "rdts_observed_args_json=$(meta_get "$BOOTSTRAP_VERIFY" rdts_observed_args_json)" \
    "profile_generation_id=$(meta_get "$BOOTSTRAP_VERIFY" profile_generation_id)" \
    "profile_generation_digest=$(meta_get "$BOOTSTRAP_VERIFY" profile_generation_digest)" \
    "checkpoint_profile_id=$(checkpoint_profile_id)" \
    "checkpoint_profile_sha256=${CHECKPOINT_PROFILE_SHA256,,}" \
    "block_height=$(meta_get "$BOOTSTRAP_VERIFY" block_height)" \
    "header_height=$(meta_get "$BOOTSTRAP_VERIFY" header_height)" \
    "best_block_hash=$(meta_get "$BOOTSTRAP_VERIFY" best_block_hash)" \
    "best_block_time=$(meta_get "$BOOTSTRAP_VERIFY" best_block_time)" \
    "median_time=$(meta_get "$BOOTSTRAP_VERIFY" median_time)" \
    "verified_epoch=$(meta_get "$BOOTSTRAP_VERIFY" verified_epoch)" \
    "index_state_json=$(meta_get "$BOOTSTRAP_VERIFY" index_state_json)"
  mv -- "$BOOTSTRAP" "$CANONICAL"
  mv -- "$meta_tmp" "$CANONICAL_META"
  sync -f "$ACTIVE_DIR"; sync -f "$CANONICAL_DIR"
  if ! (protect_image "$CANONICAL" && canonical_preflight); then
    unprotect_image "$CANONICAL" || true
    mv -- "$CANONICAL" "$BOOTSTRAP"
    rm -f -- "$CANONICAL_META"
    guestfish_data_disk "$BOOTSTRAP" upload "$raw_evidence" /.bvml/ubuntu-verification.env >/dev/null || true
    sync -f "$BOOTSTRAP"; sync -f "$ACTIVE_DIR"
    write_env_file "$RECOVERY_META" "operation=bootstrap-promotion" "result=source-preserved" \
      "bootstrap_id=$(meta_get "$BOOTSTRAP_META" bootstrap_id)" "recovery_bundle=$bundle"
    die "bootstrap installation/protection failed; bootstrap path and recovery evidence were restored"
  fi
  sync -f "$CANONICAL"; sync -f "$CANONICAL_DIR"
  rm -f -- "$BOOTSTRAP_META" "$BOOTSTRAP_VERIFY" "$RECOVERY_META"
  note "fresh Knots/RDTS IBD renamed in place as the first protected canonical checkpoint"
}

bootstrap_cleanup() {
  all_shut_off; [[ -z "$(bootstrap_attached_vm)" ]] || die "bootstrap remains attached"
  [[ ! -e "$OWNER_FILE" ]] || die "owner remains; reconcile or stop first"
  assert_no_process_reference "$BOOTSTRAP"
  rm -f -- "$BOOTSTRAP" "$BOOTSTRAP_META" "$BOOTSTRAP_VERIFY" \
    "$BOOTSTRAP_CANDIDATE" "$BOOTSTRAP_CANDIDATE_META"
  if [[ "$(meta_get "$RECOVERY_META" operation)" == bootstrap-promotion ]]; then
    rm -f -- "$RECOVERY_META"
  fi
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
  [[ "$source" == /* && "$source" != *$'\n'* && "$source" != *$'\r'* ]] ||
    die "checkpoint-import source must be an absolute path without control characters"
  [[ -n "$source_mode" ]] || die "assert a clean stop or consistent snapshot explicitly"
  (( mainnet_asserted == 1 )) || die "explicit --assert-mainnet is required after source validation"
  need qemu-img; need virt-make-fs; need virt-ls; need virt-customize; need tar
  assert_initialization_state_empty "checkpoint import"
  [[ -d "$source" ]] || die "source datadir does not exist: $source"
  if [[ "$source_mode" == stopped ]]; then
    [[ ! -e "$source/.lock" ]] ||
      die "source .lock exists; remove it only after proving the source node stopped cleanly"
    if command -v lsof >/dev/null && lsof +D "$source" 2>/dev/null | grep -q .; then
      die "a process has the asserted-stopped source datadir open"
    fi
  fi
  source_xor_check "$source"
  local candidate="$IMPORT_CANDIDATE" bytes size_bytes id generation
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
  validate_checkpoint_profile
  if [[ "$(checkpoint_profile_indexes_json)" != '[]' ]]; then
    virt-ls -a "$candidate" -m /dev/sda / | grep -qx indexes || die "candidate lacks verified indexes/"
  fi
  id="$(sha256sum "$candidate" | awk '{print $1}')"
  generation="$(new_id)"
  write_env_file "$IMPORT_META" \
    "id=$id" "generation=$generation" "created=$(date -u +%FT%TZ)" \
    "source=$source" "source_consistency=$source_mode" "source_network_assertion=mainnet" \
    "source_bytes=$bytes" "image_bytes=$size_bytes" \
    "network=main" "blocksxor=0" "layout=root-datadir" "kind=initial-import" \
    "checkpoint_profile_id=$(checkpoint_profile_id)" \
    "checkpoint_profile_sha256=${CHECKPOINT_PROFILE_SHA256,,}"
  mv -- "$candidate" "$CANONICAL"
  mv -- "$IMPORT_META" "$CANONICAL_META"
  if ! (protect_image "$CANONICAL" && validate_checkpoint_image "$CANONICAL"); then
    unprotect_image "$CANONICAL" || true
    mv -- "$CANONICAL" "$candidate"; mv -- "$CANONICAL_META" "$IMPORT_META"
    die "import installation/protection failed; candidate restored without canonical state"
  fi
  note "protected canonical checkpoint imported from $source"
}

verify_promotion_evidence() {
  local evidence="${1:-$VERIFY_META}" kind="${2:-overlay}" key expected
  [[ -f "$evidence" ]] || die "missing current Ubuntu Knots verification evidence"
  for key in vm network blocksxor synced clean_shutdown datadir_layout rdts_validated \
    knots_version_normalized artifact_sha256 rdts_profile_name rdts_profile_sha256 \
    rdts_observed_args_json block_height header_height best_block_hash best_block_time \
    median_time tip_age_seconds max_tip_age_seconds verified_epoch filesystem_uuid \
    checkpoint_profile_id checkpoint_profile_sha256 index_state_json shutdown_id; do
    [[ -n "$(meta_get "$evidence" "$key")" ]] || die "verification metadata missing $key"
  done
  for expected in "vm=ubuntu" "network=main" "blocksxor=0" "synced=1" \
                  "clean_shutdown=1" "datadir_layout=root-datadir" "rdts_validated=1"; do
    [[ "$(meta_get "$evidence" "${expected%%=*}")" == "${expected#*=}" ]] ||
      die "verification requirement failed: $expected"
  done
  [[ -n "$KNOTS_VERSION_NORMALIZED" ]] || die "KNOTS_VERSION_NORMALIZED is not configured"
  [[ "$(meta_get "$evidence" knots_version_normalized)" == "$KNOTS_VERSION_NORMALIZED" ]] ||
    die "normalized Knots version does not match configured release"
  [[ "$(meta_get "$evidence" artifact_sha256)" == "$KNOTS_ARTIFACT_SHA256" ]] ||
    die "artifact digest does not match authenticated release configuration"
  [[ "$(meta_get "$evidence" rdts_profile_sha256)" == "${KNOTS_RDTS_PROFILE_SHA256,,}" ]] ||
    die "verification used another RDTS profile digest"
  [[ -n "$KNOTS_RDTS_PROFILE_NAME" &&
     "$(meta_get "$evidence" rdts_profile_name)" == "$KNOTS_RDTS_PROFILE_NAME" ]] ||
    die "verification used another RDTS profile name"
  jq -e 'type == "array" and length > 0 and all(.[]; type == "string")' \
    <<<"$KNOTS_RDTS_REQUIRED_ARGS_JSON" >/dev/null ||
    die "host approved RDTS required-argument JSON is missing or invalid"
  jq -e 'type == "array" and length > 0 and all(.[]; type == "string")' \
    <<<"$(meta_get "$evidence" rdts_observed_args_json)" >/dev/null ||
    die "observed RDTS evidence is not a nonempty JSON string array"
  local observed_rdts_sorted approved_rdts_sorted
  observed_rdts_sorted="$(jq -c 'sort' <<<"$(meta_get "$evidence" rdts_observed_args_json)")"
  approved_rdts_sorted="$(jq -c 'sort' <<<"$KNOTS_RDTS_REQUIRED_ARGS_JSON")"
  [[ "$observed_rdts_sorted" == "$approved_rdts_sorted" ]] ||
    die "observed runtime RDTS arguments do not exactly match the host-approved set"
  [[ "$(meta_get "$evidence" block_height)" == "$(meta_get "$evidence" header_height)" ]] ||
    die "block and header heights differ"
  validate_checkpoint_profile
  [[ "$(meta_get "$evidence" checkpoint_profile_id)" == "$(checkpoint_profile_id)" ]] ||
    die "verification used another checkpoint index profile"
  [[ "$(meta_get "$evidence" checkpoint_profile_sha256)" == "${CHECKPOINT_PROFILE_SHA256,,}" ]] ||
    die "verification checkpoint profile digest mismatch"
  local expected_indexes index_state now best_time max_age
  expected_indexes="$(checkpoint_profile_indexes_json)"
  index_state="$(meta_get "$evidence" index_state_json)"
  jq -e --argjson expected "$expected_indexes" '
    . as $state |
    type == "object" and
    all($expected[]; $state[.] != null and $state[.].synced == true) and
    all(to_entries[]; (.value.synced // false) == true)
  ' <<<"$index_state" >/dev/null || die "required index set is missing, conflicting, or unsynchronized"
  best_time="$(meta_get "$evidence" best_block_time)"
  max_age="$(meta_get "$evidence" max_tip_age_seconds)"
  [[ "$best_time" =~ ^[0-9]+$ && "$max_age" =~ ^[0-9]+$ ]] ||
    die "verification tip freshness fields are invalid"
  [[ "$max_age" == "$MAX_TIP_AGE_SECONDS" ]] ||
    die "verification used another maximum tip age"
  now="$(date +%s)"
  (( now >= best_time && now - best_time <= MAX_TIP_AGE_SECONDS )) ||
    die "verified chain tip is now older than the configured ${MAX_TIP_AGE_SECONDS}s limit"
  if [[ "$kind" == overlay ]]; then
    [[ "$(meta_get "$evidence" overlay_id)" == "$(overlay_id)" ]] ||
      die "verification belongs to another overlay"
    [[ "$(meta_get "$evidence" checkpoint_generation)" == "$(checkpoint_generation)" ]] ||
      die "verification belongs to another checkpoint generation"
  else
    [[ "$(meta_get "$evidence" bootstrap_id)" == "$(meta_get "$BOOTSTRAP_META" bootstrap_id)" ]] ||
      die "verification belongs to another bootstrap"
    [[ "$(meta_get "$evidence" release_profile_sha256)" == "${KNOTS_RELEASE_PROFILE_SHA256,,}" &&
       "$(meta_get "$evidence" profile_generation_id)" == "$(profile_generation_id)" &&
       "$(meta_get "$evidence" profile_generation_digest)" == "$(active_profile_generation_digest)" ]] ||
      die "verification is not bound to the current host/guest profile generation"
  fi
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
  virt_customize_offline -a "$candidate" --delete /.bvml/ubuntu-verification.env >/dev/null
  validate_checkpoint_image "$candidate" || { rm -f -- "$candidate"; die "promotion candidate validation failed"; }
  id="$(sha256sum "$candidate" | awk '{print $1}')"
  write_env_file "$candidate_meta" "id=$id" "created=$(date -u +%FT%TZ)" \
    "generation=$(new_id)" \
    "network=main" "blocksxor=0" "layout=root-datadir" "kind=knots-rdts-promotion" \
    "knots_version_normalized=$(meta_get "$VERIFY_META" knots_version_normalized)" \
    "checkpoint_profile_id=$(checkpoint_profile_id)" \
    "checkpoint_profile_sha256=${CHECKPOINT_PROFILE_SHA256,,}"
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

recovery_ack() {
  [[ "${1:-}" == --confirm-reviewed && $# == 1 ]] ||
    die "recovery-ack requires --confirm-reviewed after inspecting status and recovery metadata"
  [[ -f "$RECOVERY_META" ]] || die "no recovery metadata exists"
  all_shut_off; assert_no_bitcoin_attachments
  [[ ! -f "$CANONICAL" ]] || canonical_preflight
  local operation result
  operation="$(meta_get "$RECOVERY_META" operation)"
  result="$(meta_get "$RECOVERY_META" result)"
  case "$operation:$result" in
    promotion:automatic-restore)
      assert_no_process_reference "$CANONICAL_DIR/promotion-candidate.qcow2"
      rm -f -- "$CANONICAL_DIR/promotion-candidate.qcow2" "$CANONICAL_DIR/promotion-manifest.env"
      ;;
    rollback:automatic-reverse) : ;;
    bootstrap-promotion:source-preserved)
      assert_no_process_reference "$BOOTSTRAP_CANDIDATE"
      rm -f -- "$BOOTSTRAP_CANDIDATE" "$BOOTSTRAP_CANDIDATE_META"
      [[ -f "$BOOTSTRAP" && -f "$BOOTSTRAP_VERIFY" ]] ||
        die "bootstrap recovery source/evidence is missing; do not acknowledge automatically"
      ;;
    *) die "unrecognized recovery state '$operation:$result'; manual forensic review is required" ;;
  esac
  rm -f -- "$RECOVERY_META"
  note "reviewed recovery metadata cleared; valuable canonical/bootstrap/overlay state was preserved"
}

adapter_status() {
  local vm="${1:-}" platform file
  [[ -z "$vm" ]] || valid_vm "$vm"
  [[ -z "$vm" || "$vm" == ubuntu ]] &&
    echo "ubuntu: module=guest/ubuntu-knots-rdts.sh knots=${KNOTS_VERSION_NORMALIZED:-UNCONFIGURED} rdts_profile=${KNOTS_RDTS_PROFILE_NAME:-UNCONFIGURED}"
  for platform in umbrel startos; do
    [[ -z "$vm" || "$vm" == "$platform" ]] || continue
    file="$ADAPTER_STATE_DIR/$platform.json"
    if [[ -f "$file" ]] && jq -e '.last_validation_result == "ok"' "$file" >/dev/null 2>&1; then
      jq -r '"\(.platform): os=\(.os_version) package=\(.package_version) profile=\(.profile_digest) adapter=\(.adapter_implementation_version) validated=\(.validated_at)"' "$file"
    else
      echo "$platform: UNVERIFIED (run adapter-setup and adapter-validate with an exact guest profile)"
    fi
  done
}

adapter_guest_action() {
  local vm="$1" action="$2"; valid_vm "$vm"
  [[ "$vm" != ubuntu ]] || die "Ubuntu uses its Knots bootstrap module, not a platform package adapter"
  [[ "$(owner_vm)" == "$vm" && ! "$(is_shut_off "$vm" && echo yes)" == yes ]] ||
    die "$vm must actively own the overlay"
  local script="/usr/local/libexec/bvml/${vm}-adapter.sh" evidence=/etc/bvml/adapter-verification.json
  if [[ "$vm" == umbrel ]]; then
    local active_json active64 guest_bvml
    guest_bvml="$(jq -r .os.data_directory "$UMBREL_PROFILE")/.bvml"
    script="$guest_bvml/bin/umbrel-adapter.sh"
    evidence="$guest_bvml/etc/adapter-verification.json"
    active_json="$(jq -n --arg overlay "$(overlay_id)" --arg canonical "$(canonical_id)" \
      --arg generation "$(checkpoint_generation)" \
      --arg serial "$(meta_get "$OVERLAY_META" disk_serial)" \
	      --arg uuid "$(meta_get "$CANONICAL_META" filesystem_uuid)" \
      --arg checkpoint_profile_id "$(meta_get "$CANONICAL_META" checkpoint_profile_id)" \
      --arg checkpoint_profile_sha256 "$(meta_get "$CANONICAL_META" checkpoint_profile_sha256)" \
      --argjson size "$(meta_get "$OVERLAY_META" size_bytes)" \
      --argjson height "$(meta_get "$CANONICAL_META" block_height)" \
      '{overlay_id:$overlay,canonical_id:$canonical,checkpoint_generation:$generation,
        disk_serial:$serial,filesystem_uuid:$uuid,size_bytes:$size,
        expected_minimum_height:$height,checkpoint_profile_id:$checkpoint_profile_id,
        checkpoint_profile_sha256:$checkpoint_profile_sha256}')"
    active64="$(base64 -w0 <<<"$active_json")"
    umbrel_exec_sync /bin/bash 60 -c \
	      "printf %s '$active64' | base64 -d > '$guest_bvml/etc/active-overlay.json'; chown root:root '$guest_bvml/etc/active-overlay.json'; chmod 0600 '$guest_bvml/etc/active-overlay.json'"
  fi
  if ! (platform_exec_sync "$vm" "$script" "$GUEST_EXEC_TIMEOUT" "$action"); then
    write_env_file "$ADAPTER_RECOVERY_META" "operation=adapter-$action" "vm=$vm" \
      "image=$OVERLAY" "result=recovery-required" "recorded=$(date -u +%FT%TZ)"
    die "$vm adapter $action failed; active state and diagnostics were preserved"
  fi
  if [[ "$action" != verify ]] &&
     ! (platform_exec_sync "$vm" "$script" "$GUEST_EXEC_TIMEOUT" verify); then
    write_env_file "$ADAPTER_RECOVERY_META" "operation=adapter-verify" "vm=$vm" \
      "image=$OVERLAY" "result=recovery-required" "recorded=$(date -u +%FT%TZ)"
    die "$vm post-setup verification failed; active state and diagnostics were preserved"
  fi
  platform_exec_sync "$vm" /bin/cat 30 "$evidence"
  local tmp="$ADAPTER_STATE_DIR/$vm.json.new"
  printf '%s\n' "$GUEST_EXEC_STDOUT" >"$tmp"
  jq -e --arg platform "$vm" '
    .platform == $platform and .last_validation_result == "ok" and
    ([.os_version,.package_version,.profile_digest,.knots_binary_digest,
      .adapter_implementation_version,.validated_at] | all(type == "string" and length > 0))
  ' "$tmp" >/dev/null || { rm -f -- "$tmp"; die "$vm returned invalid adapter verification metadata"; }
  chmod 0600 "$tmp"
  mv -- "$tmp" "$ADAPTER_STATE_DIR/$vm.json"
  [[ "$vm" != umbrel ]] || rm -f -- "$ADAPTER_RECOVERY_META"
  note "$vm adapter $action completed and verified guest profile metadata was recorded"
}

validate_all() { exec "$ROOT/scripts/vm/validate.sh"; }
status_all() { exec "$ROOT/scripts/vm/status.sh"; }

case "$command" in
  init) with_lock note "storage initialized at $BVML_STORAGE" ;;
  create) with_lock "$ROOT/scripts/vm/create.sh" "${1:?VM required}" ;;
  start) with_lock start_vm "${1:?VM required}" "${2:-}" ;;
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
  recovery-ack) with_lock recovery_ack "$@" ;;
  adapter-setup) with_lock adapter_guest_action "${1:?VM required}" setup ;;
  adapter-validate) with_lock adapter_guest_action "${1:?VM required}" verify ;;
  adapter-status) adapter_status "${1:-}" ;;
  validate) with_lock validate_all ;;
  status) status_all ;;
  *) die "unknown command: $command" ;;
esac
