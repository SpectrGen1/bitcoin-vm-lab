#!/usr/bin/env bash
# Each case is re-executed in a new strict Bash process. The parent only
# classifies that process's status; it never runs a test body in an `if`.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ORIGINAL_PATH="$PATH"

assert_file() { [[ -f "$1" ]] || { echo "assertion failed: missing file $1" >&2; return 1; }; }
assert_absent() { [[ ! -e "$1" ]] || { echo "assertion failed: unexpected $1" >&2; return 1; }; }
assert_eq() { [[ "$1" == "$2" ]] || { echo "assertion failed: '$1' != '$2'" >&2; return 1; }; }
assert_contains() { grep -Fq -- "$2" "$1" || { echo "assertion failed: $1 lacks $2" >&2; return 1; }; }
expect_fail() {
  local output="${TEST_ROOT:-/tmp}/bvml-expected-failure.out"
  "$@" >"$output" 2>&1 && { echo "expected failure: $*" >&2; return 1; }
  return 0
}

setup_case() {
  TEST_ROOT="$(mktemp -d)"; export TEST_ROOT
  export BVML_STORAGE="$TEST_ROOT/storage" BVML_TESTING=1 PATH="$TEST_ROOT/bin:$ORIGINAL_PATH"
  export KNOTS_VERSION_NORMALIZED="29.1.knots" KNOTS_ARTIFACT_SHA256=artifact-digest
  export KNOTS_RELEASE_PROFILE="$TEST_ROOT/release.env" KNOTS_RDTS_PROFILE="$TEST_ROOT/rdts.env"
  export KNOTS_RELEASE_PROFILE_SHA256="$(printf release | sha256sum | awk '{print $1}')"
  export KNOTS_RDTS_PROFILE_SHA256="$(printf rdts | sha256sum | awk '{print $1}')"
  export KNOTS_RDTS_PROFILE_NAME=test-rdts MAX_TIP_AGE_SECONDS=86400
  export KNOTS_RDTS_REQUIRED_ARGS_JSON='["-peerblockfilters=1"]'
  export CHECKPOINT_PROFILE_FILE="$ROOT/config/checkpoint-profile-none.json"
  export CHECKPOINT_PROFILE_SHA256=23e591c6313fd780317b483028b96fc89aee268855780edc11092d581d239a49
  mkdir -p "$TEST_ROOT/bin" "$BVML_STORAGE"/{canonical,active,run,vms}
  for vm in ubuntu umbrel startos; do
    mkdir -p "$BVML_STORAGE/active/$vm" "$BVML_STORAGE/run/lifecycles/$vm"
  done
  for vm in ubuntu umbrel startos; do printf 'shut off\n' >"$TEST_ROOT/state-$vm"; done
  cp "$ROOT/tests/support/fake-virsh" "$TEST_ROOT/bin/virsh"
  cp "$ROOT/tests/support/fake-qemu-img" "$TEST_ROOT/bin/qemu-img"
  printf '#!/bin/sh\ncase " $* " in *" /signet "*) printf "blocks\\nchainstate\\nindexes\\n";; *) printf "signet\\n";; esac\n' >"$TEST_ROOT/bin/virt-ls"
  printf '#!/bin/sh\n[[ ! -e "$TEST_ROOT/fail-virt-customize" ]]\n' >"$TEST_ROOT/bin/virt-customize"
  printf '#!/bin/sh\n[[ ! -e "$TEST_ROOT/fail-guestfish" ]]\n' >"$TEST_ROOT/bin/guestfish"
  printf '#!/bin/sh\ncase "$*" in *ubuntu-verification.env*) [[ -f "$TEST_ROOT/guest-evidence" ]] && cat "$TEST_ROOT/guest-evidence" || exit 1;; *knots-version.env*) cat "$TEST_ROOT/release.env";; *knots-rdts.env*) cat "$TEST_ROOT/rdts.env";; *checkpoint-profile.json*) cat "$CHECKPOINT_PROFILE_FILE";; *) exit 0;; esac\n' >"$TEST_ROOT/bin/virt-cat"
  printf '#!/bin/sh\nprintf "Name UUID\\n/dev/sda fs1\\n"\n' >"$TEST_ROOT/bin/virt-filesystems"
  printf '#!/usr/bin/env bash\nset -Eeuo pipefail\nsize=; out="${@: -1}"\nwhile (($#)); do case "$1" in --size) size="$2"; shift 2;; --size=*) size="${1#--size=}"; shift;; *) shift;; esac; done\n[[ "$size" =~ ^[0-9]+$ ]] || exit 9\ndd of=/dev/null status=none\nprintf "backing=\\nimport_size=%s\\n" "$size" >"$out"\n' >"$TEST_ROOT/bin/virt-make-fs"
  chmod +x "$TEST_ROOT/bin"/*
  printf release >"$TEST_ROOT/release.env"; printf rdts >"$TEST_ROOT/rdts.env"
}
teardown_case() { chmod -R u+w "$TEST_ROOT" 2>/dev/null || true; rm -rf -- "$TEST_ROOT"; }
make_canonical() {
  printf 'backing=\ncanonical\n' >"$BVML_STORAGE/canonical/bitcoin-signet.qcow2"
  chmod 0440 "$BVML_STORAGE/canonical/bitcoin-signet.qcow2"
  printf 'id=base-id\ngeneration=base-generation\nblocksxor=0\nnetwork=signet\nlayout=signet-subdir\ncheckpoint_profile_id=signet-no-indexes-v1\ncheckpoint_profile_sha256=%s\nrelease_profile_sha256=%s\nrdts_profile_sha256=%s\nprofile_generation_id=%s\n' \
    "$CHECKPOINT_PROFILE_SHA256" "$KNOTS_RELEASE_PROFILE_SHA256" "$KNOTS_RDTS_PROFILE_SHA256" \
    "$(printf '%s\n' "release=${KNOTS_RELEASE_PROFILE_SHA256,,}" "rdts=${KNOTS_RDTS_PROFILE_SHA256,,}" "checkpoint=${CHECKPOINT_PROFILE_SHA256,,}" | sha256sum | awk '{print $1}')" \
    >"$BVML_STORAGE/canonical/manifest.env"
  assert_file "$BVML_STORAGE/canonical/bitcoin-signet.qcow2"
}
make_startos_layer() {
  mkdir -p "$BVML_STORAGE/adapters/startos"
  qemu-img create -f qcow2 -F qcow2 -b \
    "$BVML_STORAGE/canonical/bitcoin-signet.qcow2" \
    "$BVML_STORAGE/adapters/startos/bitcoin-signet-btrfs.qcow2" >/dev/null
  chmod 0440 "$BVML_STORAGE/adapters/startos/bitcoin-signet-btrfs.qcow2"
  printf '%s\n' state=ready id=startos-adapter-id canonical_id=base-id \
    checkpoint_generation=base-generation filesystem=btrfs \
    rollback_subvolume_removed=1 filesystem_uuid=startos-btrfs-uuid \
    "backing=$BVML_STORAGE/canonical/bitcoin-signet.qcow2" \
    >"$BVML_STORAGE/adapters/startos/manifest.env"
}
make_index_base() {
  local service="$1" image meta profile profile_sha
  image="$BVML_STORAGE/indexes/$service/base.qcow2"
  meta="$BVML_STORAGE/indexes/$service/manifest.env"
  profile="$ROOT/profiles/indexers/indexers-v1.json"
  profile_sha="$(sha256sum "$profile" | awk '{print $1}')"
  mkdir -p "$(dirname "$image")"
  printf 'backing=\nsize=8G\n%s-base\n' "$service" >"$image"
  chmod 0440 "$image"
  printf '%s\n' "id=$service-base-id" "service=$service" \
    bitcoin_canonical_id=base-id bitcoin_checkpoint_generation=base-generation \
    filesystem=btrfs "filesystem_uuid=$service-fs-uuid" \
    profile_id=indexers-signet-v1 "profile_sha256=$profile_sha" \
    version=test image=test-image "binary_sha256=$(printf "$service" | sha256sum | awk '{print $1}')" \
    tip_height=100 tip_hash=abc "database_layout=$(jq -r --arg s "$service" '.[$s].database_layout' "$profile")" \
    >"$meta"
}
bvml() { "$ROOT/bin/bvml" "$@"; }
make_stopped_overlay() {
  bvml start "${1:-ubuntu}" >/dev/null
  assert_file "$BVML_STORAGE/run/lifecycles/ubuntu/owner.env"
  assert_file "$TEST_ROOT/attach-${1:-ubuntu}"
  bvml stop "${1:-ubuntu}" >/dev/null
  assert_absent "$BVML_STORAGE/run/lifecycles/ubuntu/owner.env"
  assert_absent "$TEST_ROOT/attach-${1:-ubuntu}"
  assert_file "$BVML_STORAGE/active/ubuntu/bitcoin-signet-overlay.qcow2"
}
write_verify() {
  local overlay_id generation
  overlay_id="$(sed -n 's/^overlay_id=//p' "$BVML_STORAGE/run/lifecycles/ubuntu/manifest.env")"
  generation="$(sed -n 's/^checkpoint_generation=//p' "$BVML_STORAGE/run/lifecycles/ubuntu/manifest.env")"
  printf '%s\n' vm=ubuntu network=signet blocksxor=0 synced=1 clean_shutdown=1 \
    datadir_layout=signet-subdir rdts_validated=1 "knots_version_normalized=$KNOTS_VERSION_NORMALIZED" \
    "artifact_sha256=$KNOTS_ARTIFACT_SHA256" "rdts_profile_name=$KNOTS_RDTS_PROFILE_NAME" \
    "rdts_profile_sha256=$KNOTS_RDTS_PROFILE_SHA256" \
    'rdts_observed_args_json=["-peerblockfilters=1"]' block_height=100 header_height=100 \
    best_block_hash=abc "best_block_time=$(date +%s)" "median_time=$(date +%s)" \
    tip_age_seconds=0 "max_tip_age_seconds=$MAX_TIP_AGE_SECONDS" "verified_epoch=$(date +%s)" \
    filesystem_uuid=fs1 checkpoint_profile_id=signet-no-indexes-v1 \
    "checkpoint_profile_sha256=$CHECKPOINT_PROFILE_SHA256" 'index_state_json={}' \
    shutdown_id=shutdown-1 "overlay_id=$overlay_id" \
    "checkpoint_generation=$generation" >"$BVML_STORAGE/run/lifecycles/ubuntu/verification.env"
}
write_guest_evidence() {
  printf '%s\n' vm=ubuntu network=signet blocksxor=0 synced=1 clean_shutdown=1 \
    datadir_layout=signet-subdir rdts_validated=1 "knots_version_normalized=$KNOTS_VERSION_NORMALIZED" \
    "artifact_sha256=$KNOTS_ARTIFACT_SHA256" "rdts_profile_name=$KNOTS_RDTS_PROFILE_NAME" \
    "rdts_profile_sha256=$KNOTS_RDTS_PROFILE_SHA256" \
    'rdts_observed_args_json=["-peerblockfilters=1"]' block_height=100 header_height=100 \
    best_block_hash=abc "best_block_time=$(date +%s)" "median_time=$(date +%s)" \
    tip_age_seconds=0 "max_tip_age_seconds=$MAX_TIP_AGE_SECONDS" "verified_epoch=$(date +%s)" \
    filesystem_uuid=fs1 checkpoint_profile_id=signet-no-indexes-v1 \
    "checkpoint_profile_sha256=$CHECKPOINT_PROFILE_SHA256" 'index_state_json={}' \
    shutdown_id=shutdown-bootstrap >"$TEST_ROOT/guest-evidence"
}

t_harness_setup_failure() { setup_case; trap teardown_case EXIT; false; echo unreachable; }
t_concurrent_consumers() {
  setup_case; trap teardown_case EXIT; make_canonical
  bvml start ubuntu >/dev/null
  bvml start umbrel --adapter-setup >/dev/null
  assert_file "$TEST_ROOT/attach-ubuntu"
  assert_file "$TEST_ROOT/attach-umbrel"
  assert_contains "$TEST_ROOT/attach-ubuntu" "$BVML_STORAGE/active/ubuntu/bitcoin-signet-overlay.qcow2"
  assert_contains "$TEST_ROOT/attach-umbrel" "$BVML_STORAGE/active/umbrel/bitcoin-signet-overlay.qcow2"
  ubuntu_id="$(sed -n 's/^overlay_id=//p' "$BVML_STORAGE/run/lifecycles/ubuntu/manifest.env")"
  umbrel_id="$(sed -n 's/^overlay_id=//p' "$BVML_STORAGE/run/lifecycles/umbrel/manifest.env")"
  [[ "$ubuntu_id" != "$umbrel_id" ]]
  bvml stop ubuntu >/dev/null
  bvml discard ubuntu >/dev/null
  assert_file "$TEST_ROOT/attach-umbrel"
  assert_file "$BVML_STORAGE/run/lifecycles/umbrel/owner.env"
  assert_eq "$(<"$TEST_ROOT/state-umbrel")" running
  bvml reset umbrel >/dev/null
}
t_duplicate_attachment_rejected() {
  setup_case; trap teardown_case EXIT; make_canonical
  bvml start ubuntu >/dev/null
  cp "$TEST_ROOT/attach-ubuntu" "$TEST_ROOT/attach-umbrel"
  expect_fail bvml validate
  assert_contains "$TEST_ROOT/bvml-expected-failure.out" "owner attachment is 'ubuntu,umbrel'"
}
t_canonical_mutation_blocked() {
  setup_case; trap teardown_case EXIT; make_canonical
  bvml start ubuntu >/dev/null
  expect_fail bvml checkpoint-protect
  assert_contains "$TEST_ROOT/bvml-expected-failure.out" "dependent overlay"
  assert_file "$TEST_ROOT/attach-ubuntu"
}
t_per_vm_locking() {
  setup_case; trap teardown_case EXIT; make_canonical
  bvml init >/dev/null
  (
    exec 6>"$BVML_STORAGE/run/lifecycles/ubuntu/lifecycle.lock"
    flock 6
    sleep 2
  ) &
  holder=$!
  sleep 1
  bvml start umbrel --adapter-setup >/dev/null
  assert_file "$TEST_ROOT/attach-umbrel"
  wait "$holder"
}
t_recovery_isolated() {
  setup_case; trap teardown_case EXIT; make_canonical
  printf 'operation=test\nvm=umbrel\nresult=recovery-required\n' \
    >"$BVML_STORAGE/run/lifecycles/umbrel/recovery.env"
  bvml start ubuntu >/dev/null
  assert_file "$TEST_ROOT/attach-ubuntu"
  assert_file "$BVML_STORAGE/run/lifecycles/umbrel/recovery.env"
}
t_legacy_layout_migrated() {
  setup_case; trap teardown_case EXIT; make_canonical
  printf 'backing=%s\noverlay\n' "$BVML_STORAGE/canonical/bitcoin-signet.qcow2" \
    >"$BVML_STORAGE/active/bitcoin-signet-overlay.qcow2"
  printf 'kind=overlay\nvm=ubuntu\noverlay_id=legacy-id\ncanonical_id=base-id\ncheckpoint_generation=base-generation\nbacking=%s\ndisk_serial=legacy-serial\n' \
    "$BVML_STORAGE/canonical/bitcoin-signet.qcow2" >"$BVML_STORAGE/active/manifest.env"
  bvml reconcile ubuntu >/dev/null
  assert_absent "$BVML_STORAGE/active/bitcoin-signet-overlay.qcow2"
  assert_file "$BVML_STORAGE/active/ubuntu/bitcoin-signet-overlay.qcow2"
  assert_file "$BVML_STORAGE/run/lifecycles/ubuntu/manifest.env"
}
t_nonoff() { setup_case; trap teardown_case EXIT; make_canonical; printf 'paused\n' >"$TEST_ROOT/state-ubuntu"; expect_fail bvml start ubuntu; printf 'in shutdown\n' >"$TEST_ROOT/state-ubuntu"; expect_fail bvml start ubuntu; }
t_failed_attach() { setup_case; trap teardown_case EXIT; make_canonical; touch "$TEST_ROOT/fail-attach"; expect_fail bvml start ubuntu; assert_absent "$BVML_STORAGE/active/ubuntu/bitcoin-signet-overlay.qcow2"; assert_absent "$BVML_STORAGE/run/lifecycles/ubuntu/owner.env"; }
t_failed_owner() { setup_case; trap teardown_case EXIT; make_canonical; expect_fail env BVML_FAIL_OWNER_WRITE=1 "$ROOT/bin/bvml" start ubuntu; assert_absent "$TEST_ROOT/attach-ubuntu"; assert_absent "$BVML_STORAGE/active/ubuntu/bitcoin-signet-overlay.qcow2"; assert_contains "$TEST_ROOT/virsh.log" 'detach ubuntu'; }
t_failed_start() { setup_case; trap teardown_case EXIT; make_canonical; touch "$TEST_ROOT/fail-start"; expect_fail bvml start ubuntu; assert_absent "$TEST_ROOT/attach-ubuntu"; assert_absent "$BVML_STORAGE/run/lifecycles/ubuntu/owner.env"; assert_absent "$BVML_STORAGE/active/ubuntu/bitcoin-signet-overlay.qcow2"; }
t_detach_preserves() { setup_case; trap teardown_case EXIT; make_canonical; bvml start ubuntu >/dev/null; touch "$TEST_ROOT/fail-detach"; expect_fail bvml stop ubuntu; assert_file "$TEST_ROOT/attach-ubuntu"; assert_file "$BVML_STORAGE/run/lifecycles/ubuntu/owner.env"; assert_file "$BVML_STORAGE/active/ubuntu/bitcoin-signet-overlay.qcow2"; }
t_reset_active() { setup_case; trap teardown_case EXIT; make_canonical; bvml start ubuntu >/dev/null; bvml reset ubuntu >/dev/null; assert_absent "$BVML_STORAGE/active/ubuntu/bitcoin-signet-overlay.qcow2"; assert_eq "$(<"$TEST_ROOT/state-ubuntu")" "shut off"; }
t_reset_inactive() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; bvml reset ubuntu >/dev/null; assert_absent "$BVML_STORAGE/active/ubuntu/bitcoin-signet-overlay.qcow2"; }
t_reconcile() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; id="$(sed -n 's/^overlay_id=//p' "$BVML_STORAGE/run/lifecycles/ubuntu/manifest.env")"; serial="$(sed -n 's/^disk_serial=//p' "$BVML_STORAGE/run/lifecycles/ubuntu/manifest.env")"; printf 'kind=overlay\nvm=ubuntu\nimage=%s\nidentity=%s\ndisk_serial=%s\n' "$BVML_STORAGE/active/ubuntu/bitcoin-signet-overlay.qcow2" "$id" "$serial" >"$BVML_STORAGE/run/lifecycles/ubuntu/owner.env"; bvml reconcile >/dev/null; assert_absent "$BVML_STORAGE/run/lifecycles/ubuntu/owner.env"; assert_file "$BVML_STORAGE/active/ubuntu/bitcoin-signet-overlay.qcow2"; }
t_new_overlay_evidence() { setup_case; trap teardown_case EXIT; make_canonical; touch "$BVML_STORAGE/run/lifecycles/ubuntu/verification.env"; bvml start ubuntu >/dev/null; assert_absent "$BVML_STORAGE/run/lifecycles/ubuntu/verification.env"; }
t_wrong_evidence() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; sed -i 's/^overlay_id=.*/overlay_id=old/' "$BVML_STORAGE/run/lifecycles/ubuntu/verification.env"; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_wrong_filesystem() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_guest_evidence; sed -i 's/^filesystem_uuid=.*/filesystem_uuid=another-fs/' "$TEST_ROOT/guest-evidence"; expect_fail bvml checkpoint-verify; }
t_unsynced_index() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; sed -i 's/^index_state_json=.*/index_state_json={\"txindex\":{\"synced\":false}}/' "$BVML_STORAGE/run/lifecycles/ubuntu/verification.env"; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_wrong_knots() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; sed -i 's/^knots_version_normalized=.*/knots_version_normalized=core/' "$BVML_STORAGE/run/lifecycles/ubuntu/verification.env"; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_arbitrary_rdts() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; sed -i 's/^rdts_profile_sha256=.*/rdts_profile_sha256=wrong/' "$BVML_STORAGE/run/lifecycles/ubuntu/verification.env"; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_nonubuntu_promote() { setup_case; trap teardown_case EXIT; make_canonical; bvml start umbrel --adapter-setup >/dev/null; bvml stop umbrel >/dev/null; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_unverified_adapter_start() { setup_case; trap teardown_case EXIT; make_canonical; make_startos_layer; expect_fail bvml start startos; bvml start startos --adapter-setup >/dev/null; assert_file "$TEST_ROOT/attach-startos"; }
t_promote_active() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; printf 'pmsuspended\n' >"$TEST_ROOT/state-startos"; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_promote_attached() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; printf 'vdc %s\n' "$BVML_STORAGE/active/ubuntu/bitcoin-signet-overlay.qcow2" >"$TEST_ROOT/attach-umbrel"; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_conversion_preserves() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; old="$(sha256sum "$BVML_STORAGE/canonical/bitcoin-signet.qcow2")"; touch "$TEST_ROOT/fail-convert"; expect_fail bvml checkpoint-promote --confirm-synced-clean; assert_eq "$(sha256sum "$BVML_STORAGE/canonical/bitcoin-signet.qcow2")" "$old"; }
t_candidate_preserves() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; old="$(sha256sum "$BVML_STORAGE/canonical/bitcoin-signet.qcow2")"; touch "$TEST_ROOT/fail-virt-customize"; expect_fail bvml checkpoint-promote --confirm-synced-clean; assert_eq "$(sha256sum "$BVML_STORAGE/canonical/bitcoin-signet.qcow2")" "$old"; }
t_post_install_restores() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; old="$(sha256sum "$BVML_STORAGE/canonical/bitcoin-signet.qcow2")"; touch "$TEST_ROOT/fail-post-install"; expect_fail bvml checkpoint-promote --confirm-synced-clean; assert_eq "$(sha256sum "$BVML_STORAGE/canonical/bitcoin-signet.qcow2")" "$old"; assert_file "$BVML_STORAGE/run/recovery.env"; }
t_promote_success() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; bvml checkpoint-promote --confirm-synced-clean >/dev/null; assert_file "$BVML_STORAGE/canonical/bitcoin-signet.qcow2"; assert_absent "$BVML_STORAGE/canonical/bitcoin-signet.rollback.qcow2"; assert_absent "$BVML_STORAGE/active/ubuntu/bitcoin-signet-overlay.qcow2"; [[ ! -w "$BVML_STORAGE/canonical/bitcoin-signet.qcow2" ]]; }
t_bootstrap_no_source() { setup_case; trap teardown_case EXIT; bvml checkpoint-bootstrap >/dev/null; assert_file "$BVML_STORAGE/active/bitcoin-signet-bootstrap.qcow2"; assert_contains "$BVML_STORAGE/active/bootstrap-manifest.env" 'filesystem_initialized=0'; assert_file "$TEST_ROOT/attach-ubuntu"; }
t_bootstrap_format_explicit() { setup_case; trap teardown_case EXIT; bvml checkpoint-bootstrap >/dev/null; expect_fail bvml bootstrap-init; bvml bootstrap-init --confirm-bootstrap-format >/dev/null; assert_contains "$BVML_STORAGE/active/bootstrap-manifest.env" 'filesystem_initialized=1'; }
t_bootstrap_refuse_canonical() { setup_case; trap teardown_case EXIT; make_canonical; expect_fail bvml checkpoint-bootstrap; }
t_bootstrap_refuse_incomplete() { setup_case; trap teardown_case EXIT; bvml checkpoint-bootstrap >/dev/null; expect_fail bvml bootstrap-promote --confirm-synced-clean; assert_file "$BVML_STORAGE/active/bitcoin-signet-bootstrap.qcow2"; }
t_bootstrap_transition() { setup_case; trap teardown_case EXIT; bvml checkpoint-bootstrap >/dev/null; bvml bootstrap-init --confirm-bootstrap-format >/dev/null; write_guest_evidence; bvml bootstrap-stop >/dev/null; bvml bootstrap-verify >/dev/null; bvml bootstrap-promote --confirm-synced-clean >/dev/null; assert_file "$BVML_STORAGE/canonical/bitcoin-signet.qcow2"; assert_absent "$BVML_STORAGE/active/bitcoin-signet-bootstrap.qcow2"; [[ ! -w "$BVML_STORAGE/canonical/bitcoin-signet.qcow2" ]]; }
t_bootstrap_config_guard() { assert_contains "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" 'blocksxor=0'; assert_contains "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" 'KNOTS_RDTS_PROFILE_SHA256'; assert_contains "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" 'RDTS_REQUIRED_ARGS'; }
t_bootstrap_owner_failure() { setup_case; trap teardown_case EXIT; expect_fail env BVML_FAIL_OWNER_WRITE=1 "$ROOT/bin/bvml" checkpoint-bootstrap; assert_absent "$TEST_ROOT/attach-ubuntu"; assert_absent "$BVML_STORAGE/active/bitcoin-signet-bootstrap.qcow2"; assert_absent "$BVML_STORAGE/active/bootstrap-manifest.env"; assert_contains "$TEST_ROOT/virsh.log" 'detach ubuntu'; }
t_bootstrap_reconcile() { setup_case; trap teardown_case EXIT; bvml checkpoint-bootstrap >/dev/null; echo 'shut off' >"$TEST_ROOT/state-ubuntu"; virsh -c test detach-disk bvml-ubuntu vdc --config; bvml reconcile >/dev/null; assert_absent "$BVML_STORAGE/run/lifecycles/ubuntu/owner.env"; assert_file "$BVML_STORAGE/active/bitcoin-signet-bootstrap.qcow2"; }
t_bootstrap_stop_preinstall() { setup_case; trap teardown_case EXIT; bvml checkpoint-bootstrap >/dev/null; bvml bootstrap-stop >/dev/null; assert_absent "$BVML_STORAGE/run/lifecycles/ubuntu/owner.env"; assert_absent "$TEST_ROOT/attach-ubuntu"; assert_file "$BVML_STORAGE/active/bitcoin-signet-bootstrap.qcow2"; }
t_bootstrap_failed_promote_preserves() { setup_case; trap teardown_case EXIT; bvml checkpoint-bootstrap >/dev/null; bvml bootstrap-init --confirm-bootstrap-format >/dev/null; write_guest_evidence; bvml bootstrap-stop >/dev/null; bvml bootstrap-verify >/dev/null; old="$(sha256sum "$BVML_STORAGE/active/bitcoin-signet-bootstrap.qcow2")"; touch "$TEST_ROOT/fail-post-install"; expect_fail bvml bootstrap-promote --confirm-synced-clean; assert_eq "$(sha256sum "$BVML_STORAGE/active/bitcoin-signet-bootstrap.qcow2")" "$old"; assert_file "$BVML_STORAGE/active/bootstrap-verification.env"; assert_contains "$BVML_STORAGE/active/bootstrap-manifest.env" 'state=verified-complete'; }
t_bootstrap_recovery_ack() { setup_case; trap teardown_case EXIT; bvml checkpoint-bootstrap >/dev/null; bvml bootstrap-init --confirm-bootstrap-format >/dev/null; write_guest_evidence; bvml bootstrap-stop >/dev/null; bvml bootstrap-verify >/dev/null; touch "$TEST_ROOT/fail-post-install"; expect_fail bvml bootstrap-promote --confirm-synced-clean; rm -f "$TEST_ROOT/fail-post-install"; bvml recovery-ack --confirm-reviewed >/dev/null; assert_absent "$BVML_STORAGE/run/recovery.env"; assert_file "$BVML_STORAGE/active/bitcoin-signet-bootstrap.qcow2"; assert_file "$BVML_STORAGE/active/bootstrap-verification.env"; bvml bootstrap-promote --confirm-synced-clean >/dev/null; assert_file "$BVML_STORAGE/canonical/bitcoin-signet.qcow2"; }
t_bootstrap_identity_guards() { local file="$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh"; assert_contains "$file" 'disk serial mismatch'; assert_contains "$file" '/dev/disk/by-id/virtio-'; assert_contains "$file" 'blockdev --getsize64'; assert_contains "$file" 'lsblk -nrpo NAME'; assert_contains "$file" 'wipefs -n'; assert_contains "$file" 'bootstrap_nonce'; }
t_import_xor() { setup_case; trap teardown_case EXIT; mkdir -p "$TEST_ROOT/source/signet"/{blocks,chainstate}; printf '\\001\\002' >"$TEST_ROOT/source/signet/blocks/xor.dat"; expect_fail bvml checkpoint-import "$TEST_ROOT/source" --consistent-snapshot --assert-signet; assert_absent "$BVML_STORAGE/canonical/bitcoin-signet.qcow2"; }
t_import_optional_indexes() { setup_case; trap teardown_case EXIT; mkdir -p "$TEST_ROOT/source/signet"/{blocks,chainstate}; printf data >"$TEST_ROOT/source/signet/blocks/blk.dat"; printf state >"$TEST_ROOT/source/signet/chainstate/data"; bvml checkpoint-import "$TEST_ROOT/source" --consistent-snapshot --assert-signet >/dev/null; assert_file "$BVML_STORAGE/canonical/bitcoin-signet.qcow2"; assert_contains "$BVML_STORAGE/canonical/bitcoin-signet.qcow2" 'import_size='; }
t_import_assertion() { setup_case; trap teardown_case EXIT; mkdir -p "$TEST_ROOT/source/signet"/{blocks,chainstate}; expect_fail bvml checkpoint-import "$TEST_ROOT/source"; }
t_import_refuses_bootstrap() { setup_case; trap teardown_case EXIT; bvml checkpoint-bootstrap >/dev/null; bvml bootstrap-stop >/dev/null; mkdir -p "$TEST_ROOT/source/signet"/{blocks,chainstate}; expect_fail bvml checkpoint-import "$TEST_ROOT/source" --consistent-snapshot --assert-signet; assert_file "$BVML_STORAGE/active/bitcoin-signet-bootstrap.qcow2"; }
t_rollback_prevalidate() { setup_case; trap teardown_case EXIT; make_canonical; printf 'backing=/bad\n' >"$BVML_STORAGE/canonical/bitcoin-signet.rollback.qcow2"; printf 'id=bad\n' >"$BVML_STORAGE/canonical/rollback-manifest.env"; old="$(sha256sum "$BVML_STORAGE/canonical/bitcoin-signet.qcow2")"; expect_fail bvml checkpoint-rollback; assert_eq "$(sha256sum "$BVML_STORAGE/canonical/bitcoin-signet.qcow2")" "$old"; }
t_rollback_reverse() { setup_case; trap teardown_case EXIT; make_canonical; printf 'backing=\nrollback-image\n' >"$BVML_STORAGE/canonical/bitcoin-signet.rollback.qcow2"; chmod 0440 "$BVML_STORAGE/canonical/bitcoin-signet.rollback.qcow2"; printf 'id=rollback\ngeneration=old\nblocksxor=0\n' >"$BVML_STORAGE/canonical/rollback-manifest.env"; old="$(sha256sum "$BVML_STORAGE/canonical/bitcoin-signet.qcow2")"; touch "$TEST_ROOT/fail-rollback-install"; expect_fail bvml checkpoint-rollback; assert_eq "$(sha256sum "$BVML_STORAGE/canonical/bitcoin-signet.qcow2")" "$old"; assert_file "$BVML_STORAGE/run/recovery.env"; }
t_mount_fail_closed() { assert_contains "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" 'ConditionPathIsMountPoint='; assert_contains "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" 'RequiresMountsFor='; assert_contains "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" 'bitcoin-filesystem.uuid'; }
t_ubuntu_stop_uninstalled() { env PATH="$ORIGINAL_PATH" bash "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" stop >/dev/null; }
t_start_invalidates() { assert_contains "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" 'start_knots()'; assert_contains "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" 'invalidate_evidence'; }
t_protection_order() { local file="$ROOT/lib/common.sh" chown mode acl readable immutable; chown="$(rg -n 'sudo chown.*image' "$file" | head -1 | cut -d: -f1)"; mode="$(rg -n 'chmod 0440.*image' "$file" | head -1 | cut -d: -f1)"; acl="$(rg -n 'setfacl.*QEMU_USER:r--' "$file" | head -1 | cut -d: -f1)"; readable="$(rg -n 'QEMU_USER.*test -r' "$file" | head -1 | cut -d: -f1)"; immutable="$(rg -n -F 'sudo chattr +i' "$file" | head -1 | cut -d: -f1)"; ((chown < mode && mode < acl && acl < readable && readable < immutable)); }
t_bind_readonly() { ! rg -n 'KNOTS_RELEASE_DIR|bind.*bitcoind|podman|docker' "$ROOT/scripts/vm/guest/startos-adapter.sh"; ! rg -n 'KNOTS_RELEASE_DIR|bind.*bitcoind' "$ROOT/scripts/vm/guest/umbrel-adapter.sh"; }
t_umbrel_official_lifecycle() { local f="$ROOT/scripts/vm/guest/umbrel-adapter.sh"; assert_contains "$f" 'umbreld client'; assert_contains "$f" 'apps.install.mutate'; assert_contains "$f" 'apps.start.mutate'; assert_contains "$f" 'apps.stop.mutate'; ! rg -n 'docker (start|stop|restart)|docker compose|bitcoind .*&' "$f"; }
t_umbrel_guest_provision_boots_inactive() { local f="$ROOT/scripts/provision.sh"; assert_contains "$f" 'Umbrel must be exactly shut off or running for guest provisioning'; assert_contains "$f" 'virshq start "$(domain umbrel)"'; assert_contains "$f" 'Umbrel did not shut off after guest provisioning'; }
t_umbrel_actual_process() { local f="$ROOT/scripts/vm/guest/umbrel-adapter.sh"; assert_contains "$f" 'for proc in /proc/[0-9]*'; assert_contains "$f" 'actual_knots_pid'; ! rg -n '/proc/1/cmdline' "$f"; assert_contains "$f" 'readlink -f "/proc/$pid/exe"'; }
t_umbrel_profile_pinned() { local p="$ROOT/profiles/umbrel/umbrelos-1.7.4-bitcoin-knots-1.2.12-patch.1.json"; jq -e '.os.version=="1.7.4" and .app_store.app_id=="bitcoin-knots" and .app_store.app_version=="1.2.12-patch.1" and (.app_store.image|contains("@sha256:")) and .knots.required_settings.consensusrules==true and .knots.base_config==["blocksxor=0"]' "$p" >/dev/null; }
t_umbrel_fail_closed_mount() { local f="$ROOT/scripts/vm/guest/umbrel-adapter.sh"; assert_contains "$f" 'install -d -o root -g root -m 0700 "$DATADIR"'; assert_contains "$f" 'mount -o rw,nodev,nosuid "$DEVICE" "$DATADIR"'; assert_contains "$f" 'native-datadir-quarantine'; assert_contains "$f" 'clean unmount failed; overlay remains mounted for recovery'; }
t_umbrel_installer_prompt_guard() { local f="$ROOT/scripts/vm/umbrel-install.sh"; assert_contains "$f" 'installer banner/warning fingerprints differ'; assert_contains "$f" 'UMBREL_INSTALL_SERIAL'; assert_contains "$f" 'UMBREL_SYSTEM_DISK_GIB'; assert_contains "$f" 'tesseract'; ! rg -n 'sleep [1-9][0-9][0-9]' "$f"; }
t_umbrel_rdts_runtime() { local f="$ROOT/scripts/vm/guest/umbrel-adapter.sh"; assert_contains "$f" 'consensusrules=rdts'; assert_contains "$f" 'getblockchaininfo'; assert_contains "$f" 'getindexinfo'; assert_contains "$f" 'chain tip is too old'; assert_contains "$f" 'rdts_validated:true'; }
t_umbrel_profile_mismatch() { setup_case; trap teardown_case EXIT; export UMBREL_PROFILE="$ROOT/profiles/umbrel/umbrelos-1.7.4-bitcoin-knots-1.2.12-patch.1.json" UMBREL_PROFILE_SHA256=0000000000000000000000000000000000000000000000000000000000000000; expect_fail bvml media-fetch umbrel; assert_contains "$TEST_ROOT/bvml-expected-failure.out" 'Umbrel profile digest mismatch'; }
t_umbrel_install_fail_propagates() { local f="$ROOT/scripts/vm/guest/umbrel-adapter.sh"; assert_contains "$f" 'Umbrel app installation failed: $output'; assert_contains "$f" 'timed out waiting for Umbrel app state'; assert_contains "$ROOT/scripts/vm/manage.sh" 'active state and diagnostics were preserved'; }
t_umbrel_identity_guards() { local f="$ROOT/scripts/vm/guest/umbrel-adapter.sh"; assert_contains "$f" '/dev/disk/by-id/virtio-'; assert_contains "$f" 'wrong /dev/vdc serial'; assert_contains "$f" 'wrong /dev/vdc filesystem UUID'; assert_contains "$f" 'blockdev --getsize64'; assert_contains "$f" 'overlay marker does not match'; }
t_umbrel_package_fidelity() { local f="$ROOT/scripts/vm/guest/umbrel-adapter.sh"; assert_contains "$f" 'pinned upstream package file drift'; assert_contains "$f" 'Umbrel legacy-compat package transformation drift'; assert_contains "$f" 'live official settings schema/metadata digest mismatch'; assert_contains "$f" 'required pinned $sidecar sidecar'; assert_contains "$f" 'official Compose project, network, or published ports differ'; }
t_umbrel_clean_shutdown() { local f="$ROOT/scripts/vm/guest/umbrel-adapter.sh"; assert_contains "$f" 'umbrel_app_stop'; assert_contains "$f" 'Knots app container remains running'; assert_contains "$f" 'datadir filesystem is still held'; assert_contains "$f" 'umount "$DATADIR"'; }
t_startos_profile_pinned() { local p="$ROOT/profiles/startos/startos-0.4.0.1-bitcoind-knots-29.3.1-16.json"; jq -e '.os.release=="0.4.0.1" and .registry.package_id=="bitcoind" and .registry.package_version=="#knots:29.3.1:16" and .registry.source_commit=="662ba72092b76444bb252acfe2ffbb29e6042703" and .package.knots_version_normalized=="29.3.knots20260508" and .package.lxc_volume_mount=="/media/startos/volumes/main" and .package.subcontainer=="bitcoind-sub" and .package.subcontainer_datadir=="/root/.bitcoin"' "$p" >/dev/null; }
t_startos_native_lifecycle() {
  local f="$ROOT/scripts/vm/guest/startos-adapter.sh"
  assert_contains "$f" 'start-cli --registry "$registry" package install "$PACKAGE_ID" "=$PACKAGE_VERSION"'
  assert_contains "$f" 'start-cli package start "$PACKAGE_ID" --force'
  assert_contains "$f" 'restart_package_observed'
  assert_contains "$f" 'start-cli package stop "$PACKAGE_ID"'
  assert_contains "$f" '.value.public.packageData[$id].stateInfo.manifest.version'
  ! rg -n 'podman|docker|PACKAGE_IMPLEMENTATION_SCRIPT' "$f"
}
t_startos_subcontainer_resolution() {
  local f="$ROOT/scripts/vm/guest/startos-adapter.sh"
  # StartOS 0.4: attach by subcontainer name (-n); list status is install-state only.
  assert_contains "$f" 'package attach "$PACKAGE_ID" -n "$SUBCONTAINER"'
  assert_contains "$f" 'statusInfo.desired.main'
  assert_contains "$f" 'package_desired_state()'
  ! grep -Fq 'start-cli package attach "$PACKAGE_ID" -s "$id"' "$f"
}
t_startos_adapter_operation_lock() { local f="$ROOT/scripts/vm/guest/startos-adapter.sh"; assert_contains "$f" 'adapter-operation.lock'; assert_contains "$f" 'another StartOS adapter operation is running'; }
t_startos_signer_observation() { local f="$ROOT/scripts/vm/guest/startos-adapter.sh"; assert_contains "$f" '.value.public.packageData[$id].developerKey'; assert_contains "$f" 'installed package signer is not observable'; }
t_startos_rdts_runtime() { local f="$ROOT/scripts/vm/guest/startos-adapter.sh"; assert_contains "$f" 'package action run'; assert_contains "$ROOT/profiles/startos/startos-0.4.0.1-bitcoind-knots-29.3.1-16.json" '"rdts_action": "activate-rdts"'; assert_contains "$f" 'getdeploymentinfo'; assert_contains "$f" 'rdts_deployment'; assert_contains "$ROOT/profiles/startos/startos-0.4.0.1-bitcoind-knots-29.3.1-16.json" '"rdts_deployment": "reduced_data"'; }
t_startos_volume_resolution() { local f="$ROOT/scripts/vm/guest/startos-adapter.sh"; assert_contains "$f" '.container_id // .containerId'; assert_contains "$f" '$1=="lxc.rootfs.path"'; assert_contains "$f" 'resolve_lxc_volume'; assert_contains "$f" 'findmnt -rn -o UUID'; ! rg -n 'LXC_VOLUME_SOURCE=.*/bitcoind' "$f"; }
t_startos_cross_namespace_filesystem_identity() { local f="$ROOT/scripts/vm/guest/startos-adapter.sh"; assert_contains "$f" 'stat -f -c %i'; assert_contains "$f" 'lxc_filesystem_id'; assert_contains "$f" '.filesystem_id'; }
t_startos_rpc_readiness() { local f="$ROOT/scripts/vm/guest/startos-adapter.sh"; assert_contains "$f" 'wait_node_ready()'; assert_contains "$f" 'initialblockdownload==false'; assert_contains "$f" 'StartOS Knots did not become synchronized and RPC-ready'; }
t_startos_index_readiness() { local f="$ROOT/scripts/vm/guest/startos-adapter.sh"; assert_contains "$f" 'wait_indexes_ready()'; assert_contains "$f" 'all(.[]; .synced == true)'; assert_contains "$f" 'StartOS package indexes did not become synchronized'; }
t_startos_identity_guards() { local f="$ROOT/scripts/vm/guest/startos-adapter.sh"; assert_contains "$f" '/dev/disk/by-id'; assert_contains "$f" 'disk_serial'; assert_contains "$f" 'filesystem UUID mismatch'; assert_contains "$f" 'checkpoint_generation'; }
t_startos_active_metadata_mount_guard() { assert_contains "$ROOT/scripts/vm/manage.sh" 'mountpoint -q /media/startos/data/main'; assert_contains "$ROOT/scripts/vm/manage.sh" \"install -d -o root -g root -m 0700\"; }
t_startos_native_volume_fallback() { local f="$ROOT/scripts/vm/guest/startos-adapter.sh"; assert_contains "$f" 'native StartOS volume was not restored after unmount'; assert_contains "$f" 'mount --bind --map-users'; assert_contains "$f" '"/proc/$lxc_pid/ns/user"'; assert_contains "$f" 'umount "$LXC_VOLUME_SOURCE"'; }
t_startos_config_contract() { local f="$ROOT/scripts/vm/guest/startos-adapter.sh"; assert_contains "$f" 'blocksxor=0'; assert_contains "$f" 'prune=0'; assert_contains "$f" '.reindexBlockchain=false'; assert_contains "$f" '.reindexChainstate=false'; assert_contains "$f" 'required StartOS checkpoint indexes are absent or unsynchronized'; }
t_startos_busy_unmount() { local f="$ROOT/scripts/vm/guest/startos-adapter.sh"; assert_contains "$f" 'lsof +f -- "$LXC_VOLUME_SOURCE"'; assert_contains "$f" 'main volume remains busy'; assert_contains "$ROOT/scripts/vm/manage.sh" 'state and diagnostics were preserved'; }
t_startos_nocow_fail_closed() { local f="$ROOT/scripts/vm/guest/startos-adapter.sh"; assert_contains "$f" 'verify_native_nocow_contract'; assert_contains "$f" 'chattr +C "$probe"'; assert_contains "$f" 'nocow-incompatible.txt'; assert_contains "$f" 'which the checkpoint filesystem does not support'; }
t_startos_btrfs_conversion_contract() { local host="$ROOT/scripts/vm/startos-btrfs-layer.sh" guest="$ROOT/scripts/vm/guest/startos-btrfs-maintenance.sh"; assert_contains "$guest" 'e2fsck -f -p'; assert_contains "$guest" 'btrfs-convert "$device"'; assert_contains "$guest" 'btrfs check --readonly'; assert_contains "$guest" '"basic block filter index") relative_path=signet/indexes/blockfilter/basic'; assert_contains "$guest" 'btrfs subvolume delete "$mountpoint/ext2_saved"'; ! rg -n 'defrag|balance' "$host" "$guest"; assert_contains "$host" 'STARTOS_BTRFS_ADAPTER_MAX_PERCENT'; assert_contains "$host" 'canonical_snapshot'; assert_contains "$host" 'candidate_state" == converting'; assert_contains "$host" 'meta_set "$STARTOS_LAYER_CANDIDATE_META" state converted-validated'; assert_contains "$host" 'resume_layer'; }
t_startos_adapter_blocks_canonical_mutation() { setup_case; trap teardown_case EXIT; make_canonical; make_startos_layer; expect_fail bvml checkpoint-protect; assert_contains "$TEST_ROOT/bvml-expected-failure.out" 'dependent overlay'; }
t_startos_adapter_removal_contract() { local f="$ROOT/scripts/vm/startos-btrfs-layer.sh"; assert_contains "$f" 'remove_layer()'; assert_contains "$f" 'discard every per-VM overlay'; assert_contains "$f" 'unprotect_image "$STARTOS_LAYER"'; assert_contains "$f" 'canonical remains protected'; }
t_startos_transitive_backing() { setup_case; trap teardown_case EXIT; make_canonical; make_startos_layer; bvml start startos --adapter-setup >/dev/null; assert_contains "$BVML_STORAGE/run/lifecycles/startos/manifest.env" "backing=$BVML_STORAGE/adapters/startos/bitcoin-signet-btrfs.qcow2"; assert_contains "$BVML_STORAGE/run/lifecycles/startos/manifest.env" 'startos_adapter_id=startos-adapter-id'; bvml reset startos >/dev/null; }
t_startos_concurrent_consumer() { setup_case; trap teardown_case EXIT; make_canonical; make_startos_layer; bvml start ubuntu >/dev/null; bvml start startos --adapter-setup >/dev/null; assert_file "$TEST_ROOT/attach-ubuntu"; assert_file "$TEST_ROOT/attach-startos"; assert_contains "$TEST_ROOT/attach-ubuntu" "$BVML_STORAGE/active/ubuntu/bitcoin-signet-overlay.qcow2"; assert_contains "$TEST_ROOT/attach-startos" "$BVML_STORAGE/active/startos/bitcoin-signet-overlay.qcow2"; assert_contains "$BVML_STORAGE/run/lifecycles/startos/manifest.env" "backing=$BVML_STORAGE/adapters/startos/bitcoin-signet-btrfs.qcow2"; bvml reset startos >/dev/null; assert_file "$TEST_ROOT/attach-ubuntu"; assert_eq "$(<"$TEST_ROOT/state-ubuntu")" running; bvml reset ubuntu >/dev/null; }
t_startos_consumer_only() { assert_contains "$ROOT/scripts/vm/manage.sh" 'only an Ubuntu overlay may be promoted'; ! rg -n 'checkpoint-promote startos|promote.*startos' "$ROOT/bin" "$ROOT/scripts" "$ROOT/docs" "$ROOT/README.md"; }
t_checkpoint_sync_start_contract() { local f="$ROOT/scripts/vm/manage.sh"; assert_contains "$f" 'checkpoint_sync_start()'; assert_contains "$f" 'ubuntu-knots-rdts.sh 1200 install'; assert_contains "$f" 'adapter_state syncing'; }
t_checkpoint_sync_finish_contract() { local f="$ROOT/scripts/vm/manage.sh"; assert_contains "$f" 'checkpoint_sync_finish()'; assert_contains "$f" '14400 verify-shutdown'; assert_contains "$f" 'stop_vm ubuntu'; }
t_checkpoint_no_rollback_commit_contract() { local f="$ROOT/scripts/vm/manage.sh"; assert_contains "$f" 'checkpoint_commit_no_rollback()'; assert_contains "$f" 'qemu-img commit -p "$OVERLAY"'; assert_contains "$f" 'guestfish_data_disk "$CANONICAL" rm-f /.bvml/ubuntu-verification.env'; assert_contains "$f" 'resuming the verified post-commit cleanup'; ! grep -Fq 'virt_customize_offline -a "$CANONICAL"' "$f"; assert_contains "$f" 'commit-failed-canonical-needs-validation'; assert_contains "$f" 'disaster recovery remains re-IBD'; }
t_startos_install_identity() { local f="$ROOT/scripts/vm/startos-install.sh"; assert_contains "$f" 'setup disk list --format json'; assert_contains "$f" 'STARTOS_INSTALL_SERIAL'; assert_contains "$f" 'STARTOS_DATA_SERIAL'; assert_contains "$f" '.capacity==$os_size'; assert_contains "$f" '.capacity==$data_size'; assert_contains "$f" 'setup install-os'; ! rg -n 'sleep [1-9][0-9][0-9]|send.*(Down|Enter)' "$f"; }
t_adapters_fail_closed() { expect_fail env PATH="$ORIGINAL_PATH" bash "$ROOT/scripts/vm/guest/umbrel-adapter.sh" status; expect_fail env PATH="$ORIGINAL_PATH" bash "$ROOT/scripts/vm/guest/startos-adapter.sh" status; }
t_info_command_contract() {
  local f="$ROOT/scripts/vm/info.sh"
  assert_contains "$ROOT/bin/bvml" 'info) exec'
  assert_contains "$ROOT/bin/bvml" 'info [VM]'
  assert_contains "$f" 'print_ubuntu'
  assert_contains "$f" 'print_umbrel'
  assert_contains "$f" 'print_startos'
  assert_contains "$f" 'dashboard'
  assert_contains "$f" 'login password'
  assert_contains "$f" 'UMBREL_CREDENTIALS_FILE'
  assert_contains "$f" 'STARTOS_CREDENTIALS_FILE'
  assert_contains "$f" 'domain_ipv4'
  bash -n "$f"
  bash -n "$ROOT/bin/bvml"
}
t_container_proc_inside() { local common="$ROOT/scripts/vm/guest/adapter-common.sh" startos="$ROOT/scripts/vm/guest/startos-adapter.sh"; assert_contains "$common" 'container_knots_pid'; assert_contains "$common" '"/proc/$1/cmdline"'; ! rg -n 'podman exec.*</proc/1/cmdline|/proc/1/cmdline' "$startos" "$ROOT/scripts/vm/guest/umbrel-adapter.sh"; }
t_live_rdts_validation() { local ubuntu="$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" common="$ROOT/scripts/vm/guest/adapter-common.sh"; assert_contains "$ubuntu" 'process_args_json'; assert_contains "$ubuntu" 'live Knots process has missing or duplicated RDTS option'; assert_contains "$ubuntu" 'rdts_profile_sha256='; assert_contains "$common" 'live Knots RDTS value'; }
t_container_runtime_args() { setup_case; trap teardown_case EXIT; cp "$ROOT/tests/support/fake-container-runtime" "$TEST_ROOT/bin/podman"; chmod +x "$TEST_ROOT/bin/podman"; printf '%s\n' /opt/bvml-knots/bin/bitcoind -datadir=/data/.bitcoin -chain=signet -blocksxor=0 -peerblockfilters=1 >"$TEST_ROOT/live-process-args"; source "$ROOT/scripts/vm/guest/adapter-common.sh"; verify_container_knots podman managed /opt/bvml-knots/bin/bitcoind digest /data/.bitcoin '["-peerblockfilters=1"]' 1000; assert_eq "$CONTAINER_KNOTS_PID" 42; printf '%s\n' /opt/bvml-knots/bin/bitcoind -datadir=/data/.bitcoin -chain=signet -blocksxor=0 -peerblockfilters=0 >"$TEST_ROOT/live-process-args"; expect_fail bash -c "source '$ROOT/scripts/vm/guest/adapter-common.sh'; verify_container_knots podman managed /opt/bvml-knots/bin/bitcoind digest /data/.bitcoin '[\"-peerblockfilters=1\"]' 1000"; }
t_guest_exec_waits() { local file="$ROOT/lib/common.sh"; assert_contains "$file" 'guest-exec-status'; assert_contains "$file" 'out-data'; assert_contains "$file" 'err-data'; assert_contains "$file" 'exitcode'; }
t_guest_exec_request_json() { setup_case; trap teardown_case EXIT; source "$ROOT/lib/common.sh"; request="$(guest_exec_request_json /adapter stop 'arg with space')"; assert_eq "$(jq -r '.execute' <<<"$request")" guest-exec; assert_eq "$(jq -r '.arguments.path' <<<"$request")" /adapter; assert_eq "$(jq -r '.arguments.arg[1]' <<<"$request")" 'arg with space'; assert_eq "$(jq -r '.arguments["capture-output"]' <<<"$request")" true; }
t_guest_exec_failure_output() { setup_case; trap teardown_case EXIT; export BVML_TEST_GUEST_EXEC=1; out64="$(printf 'guest stdout' | base64 -w0)"; err64="$(printf 'guest stderr' | base64 -w0)"; printf '{"return":{"exited":true,"exitcode":7,"out-data":"%s","err-data":"%s"}}\n' "$out64" "$err64" >"$TEST_ROOT/agent-status.json"; expect_fail bash -c "source '$ROOT/lib/common.sh'; guest_exec_sync ubuntu /adapter 2 verify"; assert_contains "$TEST_ROOT/bvml-expected-failure.out" 'guest stdout'; assert_contains "$TEST_ROOT/bvml-expected-failure.out" 'guest stderr'; assert_contains "$TEST_ROOT/bvml-expected-failure.out" 'failed with exit 7'; }
t_old_tip_rejected() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; sed -i "s/^best_block_time=.*/best_block_time=$(( $(date +%s) - MAX_TIP_AGE_SECONDS - 1 ))/" "$BVML_STORAGE/run/lifecycles/ubuntu/verification.env"; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_required_index_missing() { setup_case; trap teardown_case EXIT; printf '{"id":"txindex-v1","indexes":["txindex"]}\n' >"$TEST_ROOT/index-profile.json"; export CHECKPOINT_PROFILE_FILE="$TEST_ROOT/index-profile.json" CHECKPOINT_PROFILE_SHA256="$(sha256sum "$TEST_ROOT/index-profile.json" | awk '{print $1}')"; make_canonical; sed -i "s/^checkpoint_profile_id=.*/checkpoint_profile_id=txindex-v1/;s/^checkpoint_profile_sha256=.*/checkpoint_profile_sha256=$CHECKPOINT_PROFILE_SHA256/" "$BVML_STORAGE/canonical/manifest.env"; make_stopped_overlay; write_verify; sed -i "s/^checkpoint_profile_id=.*/checkpoint_profile_id=txindex-v1/;s/^checkpoint_profile_sha256=.*/checkpoint_profile_sha256=$CHECKPOINT_PROFILE_SHA256/" "$BVML_STORAGE/run/lifecycles/ubuntu/verification.env"; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_status_attachment_exact() { setup_case; trap teardown_case EXIT; make_canonical; bvml start ubuntu >/dev/null; bvml status >"$TEST_ROOT/status"; assert_contains "$TEST_ROOT/status" 'domain=bvml-ubuntu image='; [[ "$(grep -c '^  domain=.*bitcoin-signet-overlay' "$TEST_ROOT/status")" == 1 ]]; ! grep -q 'domain=bvml-umbrel image=' "$TEST_ROOT/status"; }
t_canonical_missing_generation() { setup_case; trap teardown_case EXIT; make_canonical; sed -i '/^generation=/d' "$BVML_STORAGE/canonical/manifest.env"; expect_fail bvml start ubuntu; assert_absent "$BVML_STORAGE/active/ubuntu/bitcoin-signet-overlay.qcow2"; }
t_canonical_missing_immutable() { setup_case; trap teardown_case EXIT; make_canonical; touch "$TEST_ROOT/immutable-missing"; expect_fail bvml start ubuntu; }
t_canonical_wrong_profile() { setup_case; trap teardown_case EXIT; make_canonical; sed -i 's/^checkpoint_profile_id=.*/checkpoint_profile_id=wrong/' "$BVML_STORAGE/canonical/manifest.env"; expect_fail bvml start ubuntu; }
t_overlay_generation_mismatch() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; sed -i 's/^checkpoint_generation=.*/checkpoint_generation=wrong/' "$BVML_STORAGE/run/lifecycles/ubuntu/manifest.env"; expect_fail bvml validate; bvml reset ubuntu >/dev/null; assert_absent "$BVML_STORAGE/active/ubuntu/bitcoin-signet-overlay.qcow2"; }
t_adapter_profile_metadata() {
  assert_contains "$ROOT/scripts/vm/manage.sh" 'adapter-verification.json'
  assert_contains "$ROOT/scripts/vm/manage.sh" 'profile_digest'
  assert_contains "$ROOT/scripts/vm/validate.sh" 'verified guest adapter profile metadata'
  # Host must not kill Umbrel/StartOS adapter SSH while tip catch-up is in progress.
  assert_contains "$ROOT/scripts/vm/manage.sh" 'action_timeout="$UMBREL_OPERATION_TIMEOUT"'
  assert_contains "$ROOT/scripts/vm/manage.sh" 'action_timeout="$STARTOS_OPERATION_TIMEOUT"'
}
t_no_deleted_source() { ! rg -n '/home/brian/projects/bitcoin-knots-dev/bitcoin|BITCOIN_SOURCE' "$ROOT/config" "$ROOT/bin" "$ROOT/scripts" "$ROOT/README.md" "$ROOT/docs"; }
t_provisioning_active_guard() {
  setup_case; trap teardown_case EXIT
  bvml checkpoint-bootstrap >/dev/null
  expect_fail bvml media-fetch ubuntu
  assert_contains "$TEST_ROOT/bvml-expected-failure.out" 'provisioning is blocked while lifecycle ownership exists'
  assert_file "$BVML_STORAGE/active/bitcoin-signet-bootstrap.qcow2"
  assert_file "$TEST_ROOT/attach-ubuntu"
}
t_media_existing() {
  setup_case; trap teardown_case EXIT
  export UBUNTU_IMAGE_MODE=cloud BVML_MEDIA_DIR="$TEST_ROOT/media"
  export UBUNTU_CLOUD_IMAGE="$TEST_ROOT/media/ubuntu.qcow2"
  export UBUNTU_CLOUD_IMAGE_URL=https://example.invalid/ubuntu.qcow2
  mkdir -p "$BVML_MEDIA_DIR"
  printf 'backing=\ncloud-image\n' >"$UBUNTU_CLOUD_IMAGE"
  export UBUNTU_CLOUD_IMAGE_SHA256
  UBUNTU_CLOUD_IMAGE_SHA256="$(sha256sum "$UBUNTU_CLOUD_IMAGE" | awk '{print $1}')"
  bvml media-fetch ubuntu >/dev/null
  assert_file "$UBUNTU_CLOUD_IMAGE"
  assert_eq "$(stat -c %a "$UBUNTU_CLOUD_IMAGE")" 444
}
t_media_structural_quarantine() {
  setup_case; trap teardown_case EXIT
  export UBUNTU_IMAGE_MODE=cloud BVML_MEDIA_DIR="$TEST_ROOT/media"
  export UBUNTU_CLOUD_IMAGE="$TEST_ROOT/media/ubuntu.qcow2"
  export UBUNTU_CLOUD_IMAGE_URL=https://example.invalid/ubuntu.qcow2
  mkdir -p "$BVML_MEDIA_DIR"
  printf 'backing=/unexpected\ncloud-image\n' >"$UBUNTU_CLOUD_IMAGE"
  export UBUNTU_CLOUD_IMAGE_SHA256
  UBUNTU_CLOUD_IMAGE_SHA256="$(sha256sum "$UBUNTU_CLOUD_IMAGE" | awk '{print $1}')"
  expect_fail bvml media-fetch ubuntu
  assert_absent "$UBUNTU_CLOUD_IMAGE"
  find "$BVML_MEDIA_DIR" -maxdepth 1 -name 'ubuntu.qcow2.rejected.*' -type f | grep -q .
}
t_profile_mutation_refuses_checkpoint() {
  setup_case; trap teardown_case EXIT
  make_canonical
  expect_fail bvml profiles-install
  assert_contains "$TEST_ROOT/bvml-expected-failure.out" 'profile replacement is blocked'
}
t_create_partial_refuses() {
  setup_case; trap teardown_case EXIT
  touch "$TEST_ROOT/undefined-ubuntu"
  mkdir -p "$BVML_STORAGE/vms/ubuntu"
  printf partial >"$BVML_STORAGE/vms/ubuntu/system.qcow2"
  expect_fail bvml create ubuntu
  assert_contains "$TEST_ROOT/bvml-expected-failure.out" 'partial VM disk state exists'
  assert_file "$BVML_STORAGE/vms/ubuntu/system.qcow2"
}
t_guest_repair_contract() {
  assert_contains "$ROOT/scripts/provision.sh" 'guest_repair_scripts'
  assert_contains "$ROOT/scripts/provision.sh" 'guest profile digests are unchanged'
  assert_contains "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" 'sudo rm -f -- "$EVIDENCE"'
}
t_cloud_create_contract() {
  local file="$ROOT/scripts/vm/create.sh"
  assert_contains "$file" 'UBUNTU_IMAGE_MODE'
  assert_contains "$file" 'UBUNTU_CLOUD_IMAGE_SHA256'
  assert_contains "$file" 'LIBGUESTFS_BACKEND=direct'
  assert_contains "$file" 'qemu-guest-agent,jq,curl,gnupg'
  assert_contains "$file" '--ssh-inject'
  assert_contains "$file" '--print-xml'
  assert_contains "$file" 'virshq define'
  assert_contains "$file" 'assert_provisioning_safe'
}
t_profile_install_contract() {
  local file="$ROOT/scripts/provision.sh"
  assert_contains "$file" 'VALIDSIG'
  assert_contains "$file" 'authenticated metadata does not bind the archive'
  assert_contains "$file" 'BVML_HOST_CONFIG_DIR/host.env'
  assert_contains "$file" 'RDTS_REQUIRED_ARGS_JSON'
  assert_contains "$file" 'assert_no_bitcoin_lifecycle'
}
t_profile_install_success() {
  setup_case; trap teardown_case EXIT
  export BVML_HOST_CONFIG_DIR="$TEST_ROOT/etc/bvml"
  export KNOTS_VERSION_NORMALIZED=29.3.knots20260508
  export KNOTS_ARTIFACT_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  export KNOTS_ARCHIVE_NAME=bitcoin-knots.tar.gz
  export KNOTS_RELEASE_BASE_URL=https://example.invalid/release
  export KNOTS_SHA256SUMS_SOURCE="$TEST_ROOT/SHA256SUMS"
  export KNOTS_SHA256SUMS_ASC_SOURCE="$TEST_ROOT/SHA256SUMS.asc"
  export KNOTS_SIGNING_KEY_SOURCE="$TEST_ROOT/signing-key.gpg"
  export KNOTS_SIGNER_FINGERPRINT=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
  export KNOTS_RDTS_PROFILE_NAME=test-rdts
  export KNOTS_RDTS_REQUIRED_ARGS_JSON='["-consensusrules=rdts"]'
  printf '%s  %s\n' "$KNOTS_ARTIFACT_SHA256" "$KNOTS_ARCHIVE_NAME" >"$KNOTS_SHA256SUMS_SOURCE"
  printf signature >"$KNOTS_SHA256SUMS_ASC_SOURCE"
  printf key >"$KNOTS_SIGNING_KEY_SOURCE"
  printf '#!/bin/sh\ncase "$*" in *--import*) exit 0;; *--with-colons*--fingerprint*) printf "fpr:::::::::AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:\\n";; *--export*) printf normalized-key;; *) exit 0;; esac\n' >"$TEST_ROOT/bin/gpg"
  printf '#!/bin/sh\nprintf "[GNUPG:] VALIDSIG AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 2026-01-01 0 0 0 0 0 0 0 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\\n"\n' >"$TEST_ROOT/bin/gpgv"
  chmod +x "$TEST_ROOT/bin/gpg" "$TEST_ROOT/bin/gpgv"
  bvml profiles-install >/dev/null
  assert_file "$BVML_HOST_CONFIG_DIR/host.env"
  assert_file "$BVML_HOST_CONFIG_DIR/active/releases/knots-version.env"
  assert_contains "$BVML_HOST_CONFIG_DIR/active/releases/knots-rdts.env" 'RDTS_REQUIRED_ARGS_JSON='
  assert_file "$BVML_HOST_CONFIG_DIR/active/generation.json"
  assert_contains "$BVML_HOST_CONFIG_DIR/host.env" 'KNOTS_RELEASE_PROFILE_SHA256='
}
t_cloud_create_success() {
  setup_case; trap teardown_case EXIT
  export UBUNTU_IMAGE_MODE=cloud UBUNTU_CLOUD_USER=ubuntu
  export BVML_HOST_CONFIG_DIR="$TEST_ROOT/etc/bvml"
  export UBUNTU_CLOUD_IMAGE="$TEST_ROOT/ubuntu-cloud.qcow2"
  export UBUNTU_CLOUD_SSH_KEY="$TEST_ROOT/id.pub"
  printf 'backing=\ncloud\n' >"$UBUNTU_CLOUD_IMAGE"
  export UBUNTU_CLOUD_IMAGE_SHA256
  UBUNTU_CLOUD_IMAGE_SHA256="$(sha256sum "$UBUNTU_CLOUD_IMAGE" | awk '{print $1}')"
  printf ssh-key >"$UBUNTU_CLOUD_SSH_KEY"
  mkdir -p "$BVML_HOST_CONFIG_DIR/releases"
  for file in knots-version.env knots-rdts.env SHA256SUMS SHA256SUMS.asc trusted-signers.gpg; do
    printf data >"$BVML_HOST_CONFIG_DIR/releases/$file"
  done
  export KNOTS_RELEASE_PROFILE="$BVML_HOST_CONFIG_DIR/releases/knots-version.env"
  export KNOTS_RDTS_PROFILE="$BVML_HOST_CONFIG_DIR/releases/knots-rdts.env"
  export CHECKPOINT_PROFILE_FILE="$BVML_HOST_CONFIG_DIR/checkpoint-profile.json"
  cp "$ROOT/config/checkpoint-profile-none.json" "$BVML_HOST_CONFIG_DIR/checkpoint-profile.json"
  touch "$TEST_ROOT/undefined-ubuntu"
  printf '#!/usr/bin/env bash\nset -Eeuo pipefail\nif [[ "${1:-}" == -E ]]; then shift; [[ "${1:-}" == env ]] && shift; while [[ "${1:-}" == *=* ]]; do shift; done; exec "$@"; fi\n[[ "${1:-}" == chown ]] && exit 0\nexec "$@"\n' >"$TEST_ROOT/bin/sudo"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >"$TEST_ROOT/virt-customize.log"\n' >"$TEST_ROOT/bin/virt-customize"
  printf '#!/bin/sh\nprintf "<domain type=\\"kvm\\"><name>bvml-ubuntu</name><devices><channel type=\\"unix\\"><target type=\\"virtio\\" name=\\"org.qemu.guest_agent.0\\"/></channel></devices></domain>\\n"\n' >"$TEST_ROOT/bin/virt-install"
  chmod +x "$TEST_ROOT/bin/sudo" "$TEST_ROOT/bin/virt-customize" "$TEST_ROOT/bin/virt-install"
  bvml create ubuntu >/dev/null
  assert_file "$BVML_STORAGE/vms/ubuntu/system.qcow2"
  assert_file "$BVML_STORAGE/vms/ubuntu/application.qcow2"
  assert_contains "$TEST_ROOT/virt-customize.log" '--ssh-inject'
  assert_contains "$TEST_ROOT/virsh.log" 'define'
  assert_absent "$TEST_ROOT/undefined-ubuntu"
}
t_index_overlays_are_per_vm() {
  setup_case; trap teardown_case EXIT; make_canonical
  make_index_base electrs; make_index_base fulcrum
  bvml start ubuntu >/dev/null
  bvml start umbrel --adapter-setup >/dev/null
  for service in electrs fulcrum; do
    local ubuntu_id umbrel_id
    assert_file "$BVML_STORAGE/active/ubuntu/$service-overlay.qcow2"
    assert_file "$BVML_STORAGE/active/umbrel/$service-overlay.qcow2"
    assert_contains "$TEST_ROOT/attach-ubuntu" "$BVML_STORAGE/active/ubuntu/$service-overlay.qcow2"
    assert_contains "$TEST_ROOT/attach-umbrel" "$BVML_STORAGE/active/umbrel/$service-overlay.qcow2"
    ubuntu_id="$(sed -n 's/^overlay_id=//p' "$BVML_STORAGE/run/lifecycles/ubuntu/services/$service/manifest.env")"
    umbrel_id="$(sed -n 's/^overlay_id=//p' "$BVML_STORAGE/run/lifecycles/umbrel/services/$service/manifest.env")"
    [[ "$ubuntu_id" != "$umbrel_id" ]]
  done
  bvml stop ubuntu >/dev/null
  bvml discard ubuntu >/dev/null
  assert_file "$BVML_STORAGE/active/umbrel/electrs-overlay.qcow2"
  assert_file "$BVML_STORAGE/active/umbrel/fulcrum-overlay.qcow2"
  assert_contains "$TEST_ROOT/attach-umbrel" "$BVML_STORAGE/active/umbrel/electrs-overlay.qcow2"
}
t_index_base_blocks_canonical_mutation() {
  setup_case; trap teardown_case EXIT; make_canonical; make_index_base electrs
  expect_fail bvml checkpoint-protect
  assert_contains "$TEST_ROOT/bvml-expected-failure.out" "dependent overlay"
}
t_index_overlay_generation_guard() {
  setup_case; trap teardown_case EXIT; make_canonical; make_index_base electrs
  bvml index-prepare ubuntu >/dev/null
  sed -i 's/^bitcoin_checkpoint_generation=.*/bitcoin_checkpoint_generation=stale/' \
    "$BVML_STORAGE/run/lifecycles/ubuntu/services/electrs/manifest.env"
  expect_fail bvml resume ubuntu
  assert_absent "$TEST_ROOT/attach-ubuntu"
}
t_index_adapters_native_contract() {
  assert_contains "$ROOT/scripts/vm/guest/umbrel-indexers.sh" 'umbreld client'
  assert_contains "$ROOT/scripts/vm/guest/umbrel-indexers.sh" 'docker exec "$cid" sh -ceu'
  assert_contains "$ROOT/scripts/vm/guest/umbrel-indexers.sh" 'protect_fulcrum_pre_start'
  assert_contains "$ROOT/scripts/vm/guest/umbrel-indexers.sh" 'preserving mounted BVML Fulcrum index overlay'
  assert_contains "$ROOT/scripts/vm/guest/umbrel-indexers.sh" 'installed_files'
  assert_contains "$ROOT/scripts/vm/guest/startos-fulcrum.sh" 'start-cli package start "$PACKAGE" --force'
  assert_contains "$ROOT/scripts/vm/guest/startos-fulcrum.sh" 'mount --bind --map-users'
  assert_contains "$ROOT/scripts/vm/guest/startos-fulcrum.sh" 'package attach "$PACKAGE" -n "$SUBCONTAINER"'
  assert_contains "$ROOT/scripts/vm/guest/startos-fulcrum.sh" 'python3 -c'
  assert_contains "$ROOT/scripts/vm/guest/startos-electrs.sh" 'package_id'
  assert_contains "$ROOT/scripts/vm/guest/startos-electrs.sh" '0.11.1:17'
  assert_contains "$ROOT/scripts/vm/guest/startos-electrs.sh" 'mount --bind --map-users'
  assert_contains "$ROOT/scripts/vm/guest/startos-electrs.sh" 'SUBCONTAINER=electrs'
  assert_contains "$ROOT/scripts/vm/guest/startos-electrs.sh" 'community'
  assert_contains "$ROOT/scripts/vm/guest/startos-electrs.sh" 'package attach "$PACKAGE" -n "$SUBCONTAINER"'
  assert_contains "$ROOT/scripts/vm/guest/startos-electrs.sh" 'package install --sideload'
  assert_contains "$ROOT/scripts/vm/guest/umbrel-indexers.sh" 'bitcoin-knots'
  assert_contains "$ROOT/scripts/vm/guest/umbrel-indexers.sh" 'apps.install.mutate'
  assert_contains "$ROOT/scripts/provision.sh" 'platform_exec_sync "$vm" /bin/true'
  assert_contains "$ROOT/scripts/provision.sh" 'startos-electrs.sh'
  assert_contains "$ROOT/scripts/provision.sh" 'installed and stopped StartOS Fulcrum (official) and Electrs (community)'
  assert_contains "$ROOT/lib/common.sh" 'ubuntu|umbrel|startos) printf'
  ! grep -Fq 'docker compose' "$ROOT/scripts/vm/guest/umbrel-indexers.sh"
  ! grep -Fq '127.0.0.1/50002' "$ROOT/scripts/vm/guest/startos-fulcrum.sh"
  bash -n "$ROOT/scripts/vm/guest/umbrel-indexers.sh"
  bash -n "$ROOT/scripts/vm/guest/ubuntu-indexers.sh"
  bash -n "$ROOT/scripts/vm/guest/startos-fulcrum.sh"
  bash -n "$ROOT/scripts/vm/guest/startos-electrs.sh"
  bash -n "$ROOT/lib/index-lifecycle.sh"
  bash -n "$ROOT/scripts/vm/indexes.sh"
  # Protected Fulcrum pre-start body must match the profile installed_files digest.
  local expected actual
  actual="$(python3 -c '
from pathlib import Path
import hashlib, re, sys
text = Path(sys.argv[1]).read_text()
match = re.search(r"cat >\"\$hook\" <<'\''EOF'\''\n(.*?\n)EOF\n", text, re.S)
assert match, "protected pre-start heredoc missing"
print(hashlib.sha256(match.group(1).encode()).hexdigest())
' "$ROOT/scripts/vm/guest/umbrel-indexers.sh")"
  expected="$(jq -r '.fulcrum.umbrel.installed_files["hooks/pre-start"]' \
    "$ROOT/profiles/indexers/indexers-v1.json")"
  [[ "$actual" == "$expected" ]]
}
t_index_bootstrap_requires_shut_off() {
  setup_case; trap teardown_case EXIT; make_canonical
  printf 'running\n' >"$TEST_ROOT/state-ubuntu"
  expect_fail bvml index-bootstrap electrs
  assert_contains "$TEST_ROOT/bvml-expected-failure.out" 'exactly shut off'
  assert_absent "$BVML_STORAGE/indexes/electrs/bootstrap.qcow2"
}
t_index_bootstrap_create_and_attach() {
  setup_case; trap teardown_case EXIT; make_canonical
  bvml index-bootstrap electrs >/dev/null
  assert_file "$BVML_STORAGE/indexes/electrs/bootstrap.qcow2"
  assert_file "$BVML_STORAGE/indexes/electrs/bootstrap-manifest.env"
  assert_contains "$BVML_STORAGE/indexes/electrs/bootstrap-manifest.env" 'state=created'
  assert_contains "$BVML_STORAGE/indexes/electrs/bootstrap-manifest.env" 'filesystem_initialized=0'
  # Resume/start with a retained Bitcoin overlay attaches the bootstrap disk.
  make_stopped_overlay
  bvml resume ubuntu >/dev/null
  assert_contains "$TEST_ROOT/attach-ubuntu" "$BVML_STORAGE/indexes/electrs/bootstrap.qcow2"
  assert_contains "$TEST_ROOT/attach-ubuntu" "$BVML_STORAGE/active/ubuntu/bitcoin-signet-overlay.qcow2"
}
t_index_profile_digest_bound() {
  setup_case; trap teardown_case EXIT
  local actual expected
  actual="$(sha256sum "$ROOT/profiles/indexers/indexers-v1.json" | awk '{print $1}')"
  expected="$(sed -n 's/^INDEX_PROFILE_SHA256="${INDEX_PROFILE_SHA256:-\(.*\)}"/\1/p' \
    "$ROOT/config/defaults.env")"
  [[ "$actual" == "$expected" ]]
  jq -e '.fulcrum.umbrel.installed_files["hooks/pre-start"]|test("^[0-9a-f]{64}$")' \
    "$ROOT/profiles/indexers/indexers-v1.json" >/dev/null
  # Partial base presence must still block canonical mutation.
  make_canonical
  make_index_base fulcrum
  expect_fail bvml checkpoint-protect
}

case_name="${2:-}"
if [[ "${1:-}" == --case ]]; then
  set -Eeuo pipefail
  "t_$case_name"
  exit
fi

tests=(concurrent_consumers duplicate_attachment_rejected canonical_mutation_blocked per_vm_locking
  recovery_isolated legacy_layout_migrated nonoff failed_attach failed_owner failed_start detach_preserves reset_active reset_inactive
  reconcile new_overlay_evidence wrong_evidence wrong_filesystem unsynced_index wrong_knots arbitrary_rdts nonubuntu_promote unverified_adapter_start promote_active
  promote_attached conversion_preserves candidate_preserves post_install_restores promote_success bootstrap_no_source bootstrap_format_explicit
  bootstrap_refuse_canonical bootstrap_refuse_incomplete bootstrap_transition bootstrap_config_guard bootstrap_owner_failure
  bootstrap_reconcile bootstrap_stop_preinstall bootstrap_failed_promote_preserves bootstrap_recovery_ack bootstrap_identity_guards
  import_xor import_optional_indexes import_assertion import_refuses_bootstrap rollback_prevalidate
  rollback_reverse mount_fail_closed ubuntu_stop_uninstalled start_invalidates protection_order bind_readonly adapters_fail_closed
  info_command_contract
  umbrel_official_lifecycle umbrel_actual_process umbrel_profile_pinned umbrel_fail_closed_mount umbrel_installer_prompt_guard umbrel_rdts_runtime
  umbrel_profile_mismatch umbrel_install_fail_propagates umbrel_identity_guards umbrel_package_fidelity umbrel_clean_shutdown
  startos_profile_pinned startos_native_lifecycle startos_subcontainer_resolution startos_adapter_operation_lock startos_signer_observation startos_rdts_runtime startos_volume_resolution startos_cross_namespace_filesystem_identity startos_rpc_readiness startos_index_readiness
  startos_identity_guards startos_active_metadata_mount_guard startos_native_volume_fallback startos_config_contract startos_busy_unmount
  startos_nocow_fail_closed startos_btrfs_conversion_contract
  startos_adapter_blocks_canonical_mutation startos_adapter_removal_contract startos_transitive_backing
  startos_concurrent_consumer startos_consumer_only checkpoint_sync_start_contract checkpoint_sync_finish_contract checkpoint_no_rollback_commit_contract startos_install_identity
  container_proc_inside live_rdts_validation container_runtime_args guest_exec_waits guest_exec_request_json guest_exec_failure_output old_tip_rejected required_index_missing
  status_attachment_exact canonical_missing_generation canonical_missing_immutable canonical_wrong_profile
  overlay_generation_mismatch adapter_profile_metadata no_deleted_source provisioning_active_guard
  media_existing media_structural_quarantine cloud_create_contract profile_install_contract
  profile_mutation_refuses_checkpoint profile_install_success create_partial_refuses
  guest_repair_contract cloud_create_success index_overlays_are_per_vm
  index_base_blocks_canonical_mutation index_overlay_generation_guard
  index_adapters_native_contract index_bootstrap_requires_shut_off
  index_bootstrap_create_and_attach index_profile_digest_bound)
passed=0 failed=0
for test_name in "${tests[@]}"; do
  set +e
  "$BASH" "$0" --case "$test_name"
  status=$?
  set -e
  if ((status == 0)); then echo "ok - $test_name"; ((passed+=1))
  else echo "not ok - $test_name (exit $status)" >&2; ((failed+=1)); fi
done
# Prove the runner sees a strict-mode setup failure as a failure.
set +e
"$BASH" "$0" --case harness_setup_failure >/dev/null 2>&1
status=$?
set -e
if ((status != 0)); then echo "ok - harness detects setup failure"; ((passed+=1))
else echo "not ok - harness ignored setup failure" >&2; ((failed+=1)); fi
echo "$passed passed, $failed failed"
((failed == 0))
