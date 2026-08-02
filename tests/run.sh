#!/usr/bin/env bash
# Each case is re-executed in a new strict Bash process. The parent only
# classifies that process's status; it never runs a test body in an `if`.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ORIGINAL_PATH="$PATH"

assert_file() { [[ -f "$1" ]] || { echo "assertion failed: missing file $1" >&2; return 1; }; }
assert_absent() { [[ ! -e "$1" ]] || { echo "assertion failed: unexpected $1" >&2; return 1; }; }
assert_eq() { [[ "$1" == "$2" ]] || { echo "assertion failed: '$1' != '$2'" >&2; return 1; }; }
assert_contains() { grep -q -- "$2" "$1" || { echo "assertion failed: $1 lacks $2" >&2; return 1; }; }
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
  export CHECKPOINT_PROFILE_SHA256=6d99ab029148f9bcb19d10abf7270ef3d2c8f7b4ae022c9e3ac81122ca6b03fa
  mkdir -p "$TEST_ROOT/bin" "$BVML_STORAGE"/{canonical,active,run,vms}
  for vm in ubuntu umbrel startos; do printf 'shut off\n' >"$TEST_ROOT/state-$vm"; done
  cp "$ROOT/tests/support/fake-virsh" "$TEST_ROOT/bin/virsh"
  cp "$ROOT/tests/support/fake-qemu-img" "$TEST_ROOT/bin/qemu-img"
  printf '#!/bin/sh\nprintf "blocks\\nchainstate\\nindexes\\n"\n' >"$TEST_ROOT/bin/virt-ls"
  printf '#!/bin/sh\n[[ ! -e "$TEST_ROOT/fail-virt-customize" ]]\n' >"$TEST_ROOT/bin/virt-customize"
  printf '#!/bin/sh\ncase "$*" in *ubuntu-verification.env*) [[ -f "$TEST_ROOT/guest-evidence" ]] && cat "$TEST_ROOT/guest-evidence" || exit 1;; *) exit 0;; esac\n' >"$TEST_ROOT/bin/virt-cat"
  printf '#!/bin/sh\nprintf "Name UUID\\n/dev/sda fs1\\n"\n' >"$TEST_ROOT/bin/virt-filesystems"
  printf '#!/usr/bin/env bash\nset -Eeuo pipefail\nsize=; out="${@: -1}"\nwhile (($#)); do case "$1" in --size) size="$2"; shift 2;; --size=*) size="${1#--size=}"; shift;; *) shift;; esac; done\n[[ "$size" =~ ^[0-9]+$ ]] || exit 9\ndd of=/dev/null status=none\nprintf "backing=\\nimport_size=%s\\n" "$size" >"$out"\n' >"$TEST_ROOT/bin/virt-make-fs"
  chmod +x "$TEST_ROOT/bin"/*
  printf release >"$TEST_ROOT/release.env"; printf rdts >"$TEST_ROOT/rdts.env"
}
teardown_case() { chmod -R u+w "$TEST_ROOT" 2>/dev/null || true; rm -rf -- "$TEST_ROOT"; }
make_canonical() {
  printf 'backing=\ncanonical\n' >"$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2"
  chmod 0440 "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2"
  printf 'id=base-id\ngeneration=base-generation\nblocksxor=0\nnetwork=main\nlayout=root-datadir\ncheckpoint_profile_id=mainnet-no-indexes-v1\ncheckpoint_profile_sha256=%s\n' \
    "$CHECKPOINT_PROFILE_SHA256" \
    >"$BVML_STORAGE/canonical/manifest.env"
  assert_file "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2"
}
bvml() { "$ROOT/bin/bvml" "$@"; }
make_stopped_overlay() {
  bvml start "${1:-ubuntu}" >/dev/null
  assert_file "$BVML_STORAGE/run/owner.env"
  assert_file "$TEST_ROOT/attach-${1:-ubuntu}"
  bvml stop "${1:-ubuntu}" >/dev/null
  assert_absent "$BVML_STORAGE/run/owner.env"
  assert_absent "$TEST_ROOT/attach-${1:-ubuntu}"
  assert_file "$BVML_STORAGE/active/bitcoin-mainnet-overlay.qcow2"
}
write_verify() {
  local overlay_id generation
  overlay_id="$(sed -n 's/^overlay_id=//p' "$BVML_STORAGE/active/manifest.env")"
  generation="$(sed -n 's/^checkpoint_generation=//p' "$BVML_STORAGE/active/manifest.env")"
  printf '%s\n' vm=ubuntu network=main blocksxor=0 synced=1 clean_shutdown=1 \
    datadir_layout=root-datadir rdts_validated=1 "knots_version_normalized=$KNOTS_VERSION_NORMALIZED" \
    "artifact_sha256=$KNOTS_ARTIFACT_SHA256" "rdts_profile_name=$KNOTS_RDTS_PROFILE_NAME" \
    "rdts_profile_sha256=$KNOTS_RDTS_PROFILE_SHA256" \
    'rdts_observed_args_json=["-peerblockfilters=1"]' block_height=100 header_height=100 \
    best_block_hash=abc "best_block_time=$(date +%s)" "median_time=$(date +%s)" \
    tip_age_seconds=0 "max_tip_age_seconds=$MAX_TIP_AGE_SECONDS" "verified_epoch=$(date +%s)" \
    filesystem_uuid=fs1 checkpoint_profile_id=mainnet-no-indexes-v1 \
    "checkpoint_profile_sha256=$CHECKPOINT_PROFILE_SHA256" 'index_state_json={}' \
    shutdown_id=shutdown-1 "overlay_id=$overlay_id" \
    "checkpoint_generation=$generation" >"$BVML_STORAGE/active/ubuntu-verification.env"
}
write_guest_evidence() {
  printf '%s\n' vm=ubuntu network=main blocksxor=0 synced=1 clean_shutdown=1 \
    datadir_layout=root-datadir rdts_validated=1 "knots_version_normalized=$KNOTS_VERSION_NORMALIZED" \
    "artifact_sha256=$KNOTS_ARTIFACT_SHA256" "rdts_profile_name=$KNOTS_RDTS_PROFILE_NAME" \
    "rdts_profile_sha256=$KNOTS_RDTS_PROFILE_SHA256" \
    'rdts_observed_args_json=["-peerblockfilters=1"]' block_height=100 header_height=100 \
    best_block_hash=abc "best_block_time=$(date +%s)" "median_time=$(date +%s)" \
    tip_age_seconds=0 "max_tip_age_seconds=$MAX_TIP_AGE_SECONDS" "verified_epoch=$(date +%s)" \
    filesystem_uuid=fs1 checkpoint_profile_id=mainnet-no-indexes-v1 \
    "checkpoint_profile_sha256=$CHECKPOINT_PROFILE_SHA256" 'index_state_json={}' \
    shutdown_id=shutdown-bootstrap >"$TEST_ROOT/guest-evidence"
}

t_harness_setup_failure() { setup_case; trap teardown_case EXIT; false; echo unreachable; }
t_parallel() { setup_case; trap teardown_case EXIT; make_canonical; bvml start ubuntu >/dev/null; assert_file "$TEST_ROOT/attach-ubuntu"; expect_fail bvml start umbrel; }
t_nonoff() { setup_case; trap teardown_case EXIT; make_canonical; printf 'paused\n' >"$TEST_ROOT/state-ubuntu"; expect_fail bvml start ubuntu; printf 'in shutdown\n' >"$TEST_ROOT/state-ubuntu"; expect_fail bvml start ubuntu; }
t_failed_attach() { setup_case; trap teardown_case EXIT; make_canonical; touch "$TEST_ROOT/fail-attach"; expect_fail bvml start ubuntu; assert_absent "$BVML_STORAGE/active/bitcoin-mainnet-overlay.qcow2"; assert_absent "$BVML_STORAGE/run/owner.env"; }
t_failed_owner() { setup_case; trap teardown_case EXIT; make_canonical; expect_fail env BVML_FAIL_OWNER_WRITE=1 "$ROOT/bin/bvml" start ubuntu; assert_absent "$TEST_ROOT/attach-ubuntu"; assert_absent "$BVML_STORAGE/active/bitcoin-mainnet-overlay.qcow2"; assert_contains "$TEST_ROOT/virsh.log" 'detach ubuntu'; }
t_failed_start() { setup_case; trap teardown_case EXIT; make_canonical; touch "$TEST_ROOT/fail-start"; expect_fail bvml start ubuntu; assert_absent "$TEST_ROOT/attach-ubuntu"; assert_absent "$BVML_STORAGE/run/owner.env"; assert_absent "$BVML_STORAGE/active/bitcoin-mainnet-overlay.qcow2"; }
t_detach_preserves() { setup_case; trap teardown_case EXIT; make_canonical; bvml start ubuntu >/dev/null; touch "$TEST_ROOT/fail-detach"; expect_fail bvml stop ubuntu; assert_file "$TEST_ROOT/attach-ubuntu"; assert_file "$BVML_STORAGE/run/owner.env"; assert_file "$BVML_STORAGE/active/bitcoin-mainnet-overlay.qcow2"; }
t_reset_active() { setup_case; trap teardown_case EXIT; make_canonical; bvml start ubuntu >/dev/null; bvml reset ubuntu >/dev/null; assert_absent "$BVML_STORAGE/active/bitcoin-mainnet-overlay.qcow2"; assert_eq "$(<"$TEST_ROOT/state-ubuntu")" "shut off"; }
t_reset_inactive() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; bvml reset ubuntu >/dev/null; assert_absent "$BVML_STORAGE/active/bitcoin-mainnet-overlay.qcow2"; }
t_reconcile() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; id="$(sed -n 's/^overlay_id=//p' "$BVML_STORAGE/active/manifest.env")"; serial="$(sed -n 's/^disk_serial=//p' "$BVML_STORAGE/active/manifest.env")"; printf 'kind=overlay\nvm=ubuntu\nimage=%s\nidentity=%s\ndisk_serial=%s\n' "$BVML_STORAGE/active/bitcoin-mainnet-overlay.qcow2" "$id" "$serial" >"$BVML_STORAGE/run/owner.env"; bvml reconcile >/dev/null; assert_absent "$BVML_STORAGE/run/owner.env"; assert_file "$BVML_STORAGE/active/bitcoin-mainnet-overlay.qcow2"; }
t_new_overlay_evidence() { setup_case; trap teardown_case EXIT; make_canonical; touch "$BVML_STORAGE/active/ubuntu-verification.env"; bvml start ubuntu >/dev/null; assert_absent "$BVML_STORAGE/active/ubuntu-verification.env"; }
t_wrong_evidence() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; sed -i 's/^overlay_id=.*/overlay_id=old/' "$BVML_STORAGE/active/ubuntu-verification.env"; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_wrong_filesystem() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_guest_evidence; sed -i 's/^filesystem_uuid=.*/filesystem_uuid=another-fs/' "$TEST_ROOT/guest-evidence"; expect_fail bvml checkpoint-verify; }
t_unsynced_index() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; sed -i 's/^index_state_json=.*/index_state_json={\"txindex\":{\"synced\":false}}/' "$BVML_STORAGE/active/ubuntu-verification.env"; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_wrong_knots() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; sed -i 's/^knots_version_normalized=.*/knots_version_normalized=core/' "$BVML_STORAGE/active/ubuntu-verification.env"; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_arbitrary_rdts() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; sed -i 's/^rdts_profile_sha256=.*/rdts_profile_sha256=wrong/' "$BVML_STORAGE/active/ubuntu-verification.env"; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_nonubuntu_promote() { setup_case; trap teardown_case EXIT; make_canonical; bvml start umbrel --adapter-setup >/dev/null; bvml stop umbrel >/dev/null; write_verify; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_unverified_adapter_start() { setup_case; trap teardown_case EXIT; make_canonical; expect_fail bvml start startos; bvml start startos --adapter-setup >/dev/null; assert_file "$TEST_ROOT/attach-startos"; }
t_promote_active() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; printf 'pmsuspended\n' >"$TEST_ROOT/state-startos"; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_promote_attached() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; printf 'vdc %s\n' "$BVML_STORAGE/active/bitcoin-mainnet-overlay.qcow2" >"$TEST_ROOT/attach-umbrel"; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_conversion_preserves() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; old="$(sha256sum "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2")"; touch "$TEST_ROOT/fail-convert"; expect_fail bvml checkpoint-promote --confirm-synced-clean; assert_eq "$(sha256sum "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2")" "$old"; }
t_candidate_preserves() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; old="$(sha256sum "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2")"; touch "$TEST_ROOT/fail-virt-customize"; expect_fail bvml checkpoint-promote --confirm-synced-clean; assert_eq "$(sha256sum "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2")" "$old"; }
t_post_install_restores() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; old="$(sha256sum "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2")"; touch "$TEST_ROOT/fail-post-install"; expect_fail bvml checkpoint-promote --confirm-synced-clean; assert_eq "$(sha256sum "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2")" "$old"; assert_file "$BVML_STORAGE/run/recovery.env"; }
t_promote_success() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; bvml checkpoint-promote --confirm-synced-clean >/dev/null; assert_file "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2"; assert_file "$BVML_STORAGE/canonical/bitcoin-mainnet.rollback.qcow2"; assert_absent "$BVML_STORAGE/active/bitcoin-mainnet-overlay.qcow2"; [[ ! -w "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2" ]]; }
t_bootstrap_no_source() { setup_case; trap teardown_case EXIT; bvml checkpoint-bootstrap >/dev/null; assert_file "$BVML_STORAGE/active/bitcoin-mainnet-bootstrap.qcow2"; assert_contains "$BVML_STORAGE/active/bootstrap-manifest.env" 'filesystem_initialized=0'; assert_file "$TEST_ROOT/attach-ubuntu"; }
t_bootstrap_format_explicit() { setup_case; trap teardown_case EXIT; bvml checkpoint-bootstrap >/dev/null; expect_fail bvml bootstrap-init; bvml bootstrap-init --confirm-bootstrap-format >/dev/null; assert_contains "$BVML_STORAGE/active/bootstrap-manifest.env" 'filesystem_initialized=1'; }
t_bootstrap_refuse_canonical() { setup_case; trap teardown_case EXIT; make_canonical; expect_fail bvml checkpoint-bootstrap; }
t_bootstrap_refuse_incomplete() { setup_case; trap teardown_case EXIT; bvml checkpoint-bootstrap >/dev/null; expect_fail bvml bootstrap-promote --confirm-synced-clean; assert_file "$BVML_STORAGE/active/bitcoin-mainnet-bootstrap.qcow2"; }
t_bootstrap_transition() { setup_case; trap teardown_case EXIT; bvml checkpoint-bootstrap >/dev/null; bvml bootstrap-init --confirm-bootstrap-format >/dev/null; write_guest_evidence; bvml bootstrap-stop >/dev/null; bvml bootstrap-verify >/dev/null; bvml bootstrap-promote --confirm-synced-clean >/dev/null; assert_file "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2"; assert_absent "$BVML_STORAGE/active/bitcoin-mainnet-bootstrap.qcow2"; [[ ! -w "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2" ]]; }
t_bootstrap_config_guard() { assert_contains "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" 'blocksxor=0'; assert_contains "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" 'KNOTS_RDTS_PROFILE_SHA256'; assert_contains "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" 'RDTS_REQUIRED_ARGS'; }
t_bootstrap_owner_failure() { setup_case; trap teardown_case EXIT; expect_fail env BVML_FAIL_OWNER_WRITE=1 "$ROOT/bin/bvml" checkpoint-bootstrap; assert_absent "$TEST_ROOT/attach-ubuntu"; assert_absent "$BVML_STORAGE/active/bitcoin-mainnet-bootstrap.qcow2"; assert_absent "$BVML_STORAGE/active/bootstrap-manifest.env"; assert_contains "$TEST_ROOT/virsh.log" 'detach ubuntu'; }
t_bootstrap_reconcile() { setup_case; trap teardown_case EXIT; bvml checkpoint-bootstrap >/dev/null; echo 'shut off' >"$TEST_ROOT/state-ubuntu"; virsh -c test detach-disk bvml-ubuntu vdc --config; bvml reconcile >/dev/null; assert_absent "$BVML_STORAGE/run/owner.env"; assert_file "$BVML_STORAGE/active/bitcoin-mainnet-bootstrap.qcow2"; }
t_bootstrap_stop_preinstall() { setup_case; trap teardown_case EXIT; bvml checkpoint-bootstrap >/dev/null; bvml bootstrap-stop >/dev/null; assert_absent "$BVML_STORAGE/run/owner.env"; assert_absent "$TEST_ROOT/attach-ubuntu"; assert_file "$BVML_STORAGE/active/bitcoin-mainnet-bootstrap.qcow2"; }
t_bootstrap_failed_promote_preserves() { setup_case; trap teardown_case EXIT; bvml checkpoint-bootstrap >/dev/null; bvml bootstrap-init --confirm-bootstrap-format >/dev/null; write_guest_evidence; bvml bootstrap-stop >/dev/null; bvml bootstrap-verify >/dev/null; old="$(sha256sum "$BVML_STORAGE/active/bitcoin-mainnet-bootstrap.qcow2")"; touch "$TEST_ROOT/fail-post-install"; expect_fail bvml bootstrap-promote --confirm-synced-clean; assert_eq "$(sha256sum "$BVML_STORAGE/active/bitcoin-mainnet-bootstrap.qcow2")" "$old"; assert_file "$BVML_STORAGE/active/bootstrap-verification.env"; assert_contains "$BVML_STORAGE/active/bootstrap-manifest.env" 'state=verified-complete'; }
t_bootstrap_recovery_ack() { setup_case; trap teardown_case EXIT; bvml checkpoint-bootstrap >/dev/null; bvml bootstrap-init --confirm-bootstrap-format >/dev/null; write_guest_evidence; bvml bootstrap-stop >/dev/null; bvml bootstrap-verify >/dev/null; touch "$TEST_ROOT/fail-post-install"; expect_fail bvml bootstrap-promote --confirm-synced-clean; rm -f "$TEST_ROOT/fail-post-install"; bvml recovery-ack --confirm-reviewed >/dev/null; assert_absent "$BVML_STORAGE/run/recovery.env"; assert_file "$BVML_STORAGE/active/bitcoin-mainnet-bootstrap.qcow2"; assert_file "$BVML_STORAGE/active/bootstrap-verification.env"; bvml bootstrap-promote --confirm-synced-clean >/dev/null; assert_file "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2"; }
t_bootstrap_identity_guards() { local file="$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh"; assert_contains "$file" 'disk serial mismatch'; assert_contains "$file" '/dev/disk/by-id/virtio-'; assert_contains "$file" 'blockdev --getsize64'; assert_contains "$file" 'lsblk -nrpo NAME'; assert_contains "$file" 'wipefs -n'; assert_contains "$file" 'bootstrap_nonce'; }
t_import_xor() { setup_case; trap teardown_case EXIT; mkdir -p "$TEST_ROOT/source"/{blocks,chainstate}; printf '\\001\\002' >"$TEST_ROOT/source/blocks/xor.dat"; expect_fail bvml checkpoint-import "$TEST_ROOT/source" --consistent-snapshot --assert-mainnet; assert_absent "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2"; }
t_import_optional_indexes() { setup_case; trap teardown_case EXIT; mkdir -p "$TEST_ROOT/source"/{blocks,chainstate}; printf data >"$TEST_ROOT/source/blocks/blk.dat"; printf state >"$TEST_ROOT/source/chainstate/data"; bvml checkpoint-import "$TEST_ROOT/source" --consistent-snapshot --assert-mainnet >/dev/null; assert_file "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2"; assert_contains "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2" 'import_size='; }
t_import_assertion() { setup_case; trap teardown_case EXIT; mkdir -p "$TEST_ROOT/source"/{blocks,chainstate}; expect_fail bvml checkpoint-import "$TEST_ROOT/source"; }
t_import_refuses_bootstrap() { setup_case; trap teardown_case EXIT; bvml checkpoint-bootstrap >/dev/null; bvml bootstrap-stop >/dev/null; mkdir -p "$TEST_ROOT/source"/{blocks,chainstate}; expect_fail bvml checkpoint-import "$TEST_ROOT/source" --consistent-snapshot --assert-mainnet; assert_file "$BVML_STORAGE/active/bitcoin-mainnet-bootstrap.qcow2"; }
t_rollback_prevalidate() { setup_case; trap teardown_case EXIT; make_canonical; printf 'backing=/bad\n' >"$BVML_STORAGE/canonical/bitcoin-mainnet.rollback.qcow2"; printf 'id=bad\n' >"$BVML_STORAGE/canonical/rollback-manifest.env"; old="$(sha256sum "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2")"; expect_fail bvml checkpoint-rollback; assert_eq "$(sha256sum "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2")" "$old"; }
t_rollback_reverse() { setup_case; trap teardown_case EXIT; make_canonical; printf 'backing=\nrollback-image\n' >"$BVML_STORAGE/canonical/bitcoin-mainnet.rollback.qcow2"; chmod 0440 "$BVML_STORAGE/canonical/bitcoin-mainnet.rollback.qcow2"; printf 'id=rollback\ngeneration=old\nblocksxor=0\n' >"$BVML_STORAGE/canonical/rollback-manifest.env"; old="$(sha256sum "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2")"; touch "$TEST_ROOT/fail-rollback-install"; expect_fail bvml checkpoint-rollback; assert_eq "$(sha256sum "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2")" "$old"; assert_file "$BVML_STORAGE/run/recovery.env"; }
t_mount_fail_closed() { assert_contains "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" 'ConditionPathIsMountPoint='; assert_contains "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" 'RequiresMountsFor='; assert_contains "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" 'bitcoin-filesystem.uuid'; }
t_ubuntu_stop_uninstalled() { env PATH="$ORIGINAL_PATH" bash "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" stop >/dev/null; }
t_start_invalidates() { assert_contains "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" 'start_knots()'; assert_contains "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" 'invalidate_evidence'; }
t_protection_order() { local file="$ROOT/lib/common.sh" chown mode acl readable immutable; chown="$(rg -n 'sudo chown.*image' "$file" | head -1 | cut -d: -f1)"; mode="$(rg -n 'chmod 0440.*image' "$file" | head -1 | cut -d: -f1)"; acl="$(rg -n 'setfacl.*QEMU_USER:r--' "$file" | head -1 | cut -d: -f1)"; readable="$(rg -n 'QEMU_USER.*test -r' "$file" | head -1 | cut -d: -f1)"; immutable="$(rg -n -F 'sudo chattr +i' "$file" | head -1 | cut -d: -f1)"; ((chown < mode && mode < acl && acl < readable && readable < immutable)); }
t_bind_readonly() { assert_contains "$ROOT/scripts/vm/guest/umbrel-adapter.sh" '.RW == false'; assert_contains "$ROOT/scripts/vm/guest/startos-adapter.sh" '.RW == false'; }
t_adapters_fail_closed() { expect_fail env PATH="$ORIGINAL_PATH" bash "$ROOT/scripts/vm/guest/umbrel-adapter.sh" status; expect_fail env PATH="$ORIGINAL_PATH" bash "$ROOT/scripts/vm/guest/startos-adapter.sh" status; }
t_container_proc_inside() { local common="$ROOT/scripts/vm/guest/adapter-common.sh" startos="$ROOT/scripts/vm/guest/startos-adapter.sh"; assert_contains "$common" 'container_knots_pid'; assert_contains "$common" '"/proc/$1/cmdline"'; ! rg -n 'podman exec.*</proc/1/cmdline|/proc/1/cmdline' "$startos" "$ROOT/scripts/vm/guest/umbrel-adapter.sh"; }
t_live_rdts_validation() { local ubuntu="$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" common="$ROOT/scripts/vm/guest/adapter-common.sh"; assert_contains "$ubuntu" 'process_args_json'; assert_contains "$ubuntu" 'live Knots process has missing or duplicated RDTS option'; assert_contains "$ubuntu" 'rdts_profile_sha256='; assert_contains "$common" 'live Knots RDTS value'; }
t_container_runtime_args() { setup_case; trap teardown_case EXIT; cp "$ROOT/tests/support/fake-container-runtime" "$TEST_ROOT/bin/podman"; chmod +x "$TEST_ROOT/bin/podman"; printf '%s\n' /opt/bvml-knots/bin/bitcoind -datadir=/data/.bitcoin -chain=main -blocksxor=0 -peerblockfilters=1 >"$TEST_ROOT/live-process-args"; source "$ROOT/scripts/vm/guest/adapter-common.sh"; verify_container_knots podman managed /opt/bvml-knots/bin/bitcoind digest /data/.bitcoin '["-peerblockfilters=1"]' 1000; assert_eq "$CONTAINER_KNOTS_PID" 42; printf '%s\n' /opt/bvml-knots/bin/bitcoind -datadir=/data/.bitcoin -chain=main -blocksxor=0 -peerblockfilters=0 >"$TEST_ROOT/live-process-args"; expect_fail bash -c "source '$ROOT/scripts/vm/guest/adapter-common.sh'; verify_container_knots podman managed /opt/bvml-knots/bin/bitcoind digest /data/.bitcoin '[\"-peerblockfilters=1\"]' 1000"; }
t_guest_exec_waits() { local file="$ROOT/lib/common.sh"; assert_contains "$file" 'guest-exec-status'; assert_contains "$file" 'out-data'; assert_contains "$file" 'err-data'; assert_contains "$file" 'exitcode'; }
t_guest_exec_request_json() { setup_case; trap teardown_case EXIT; source "$ROOT/lib/common.sh"; request="$(guest_exec_request_json /adapter stop 'arg with space')"; assert_eq "$(jq -r '.execute' <<<"$request")" guest-exec; assert_eq "$(jq -r '.arguments.path' <<<"$request")" /adapter; assert_eq "$(jq -r '.arguments.arg[1]' <<<"$request")" 'arg with space'; assert_eq "$(jq -r '.arguments["capture-output"]' <<<"$request")" true; }
t_guest_exec_failure_output() { setup_case; trap teardown_case EXIT; export BVML_TEST_GUEST_EXEC=1; out64="$(printf 'guest stdout' | base64 -w0)"; err64="$(printf 'guest stderr' | base64 -w0)"; printf '{"return":{"exited":true,"exitcode":7,"out-data":"%s","err-data":"%s"}}\n' "$out64" "$err64" >"$TEST_ROOT/agent-status.json"; expect_fail bash -c "source '$ROOT/lib/common.sh'; guest_exec_sync ubuntu /adapter 2 verify"; assert_contains "$TEST_ROOT/bvml-expected-failure.out" 'guest stdout'; assert_contains "$TEST_ROOT/bvml-expected-failure.out" 'guest stderr'; assert_contains "$TEST_ROOT/bvml-expected-failure.out" 'failed with exit 7'; }
t_old_tip_rejected() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; sed -i "s/^best_block_time=.*/best_block_time=$(( $(date +%s) - MAX_TIP_AGE_SECONDS - 1 ))/" "$BVML_STORAGE/active/ubuntu-verification.env"; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_required_index_missing() { setup_case; trap teardown_case EXIT; printf '{"id":"txindex-v1","indexes":["txindex"]}\n' >"$TEST_ROOT/index-profile.json"; export CHECKPOINT_PROFILE_FILE="$TEST_ROOT/index-profile.json" CHECKPOINT_PROFILE_SHA256="$(sha256sum "$TEST_ROOT/index-profile.json" | awk '{print $1}')"; make_canonical; sed -i "s/^checkpoint_profile_id=.*/checkpoint_profile_id=txindex-v1/;s/^checkpoint_profile_sha256=.*/checkpoint_profile_sha256=$CHECKPOINT_PROFILE_SHA256/" "$BVML_STORAGE/canonical/manifest.env"; make_stopped_overlay; write_verify; sed -i "s/^checkpoint_profile_id=.*/checkpoint_profile_id=txindex-v1/;s/^checkpoint_profile_sha256=.*/checkpoint_profile_sha256=$CHECKPOINT_PROFILE_SHA256/" "$BVML_STORAGE/active/ubuntu-verification.env"; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_status_attachment_exact() { setup_case; trap teardown_case EXIT; make_canonical; bvml start ubuntu >/dev/null; bvml status >"$TEST_ROOT/status"; assert_contains "$TEST_ROOT/status" 'domain=bvml-ubuntu image='; [[ "$(grep -c '^  domain=.*bitcoin-mainnet-overlay' "$TEST_ROOT/status")" == 1 ]]; ! grep -q 'domain=bvml-umbrel image=' "$TEST_ROOT/status"; }
t_canonical_missing_generation() { setup_case; trap teardown_case EXIT; make_canonical; sed -i '/^generation=/d' "$BVML_STORAGE/canonical/manifest.env"; expect_fail bvml start ubuntu; assert_absent "$BVML_STORAGE/active/bitcoin-mainnet-overlay.qcow2"; }
t_canonical_missing_immutable() { setup_case; trap teardown_case EXIT; make_canonical; touch "$TEST_ROOT/immutable-missing"; expect_fail bvml start ubuntu; }
t_canonical_wrong_profile() { setup_case; trap teardown_case EXIT; make_canonical; sed -i 's/^checkpoint_profile_id=.*/checkpoint_profile_id=wrong/' "$BVML_STORAGE/canonical/manifest.env"; expect_fail bvml start ubuntu; }
t_overlay_generation_mismatch() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; sed -i 's/^checkpoint_generation=.*/checkpoint_generation=wrong/' "$BVML_STORAGE/active/manifest.env"; expect_fail bvml validate; bvml reset ubuntu >/dev/null; assert_absent "$BVML_STORAGE/active/bitcoin-mainnet-overlay.qcow2"; }
t_adapter_profile_metadata() { assert_contains "$ROOT/scripts/vm/manage.sh" 'adapter-verification.json'; assert_contains "$ROOT/scripts/vm/manage.sh" 'profile_digest'; assert_contains "$ROOT/scripts/vm/validate.sh" 'verified guest adapter profile metadata'; }
t_no_deleted_source() { ! rg -n '/home/brian/projects/bitcoin-knots-dev/bitcoin|BITCOIN_SOURCE' "$ROOT/config" "$ROOT/bin" "$ROOT/scripts" "$ROOT/README.md" "$ROOT/docs"; }
t_provisioning_active_guard() {
  setup_case; trap teardown_case EXIT
  bvml checkpoint-bootstrap >/dev/null
  expect_fail bvml media-fetch ubuntu
  assert_contains "$TEST_ROOT/bvml-expected-failure.out" 'provisioning is blocked while lifecycle ownership exists'
  assert_file "$BVML_STORAGE/active/bitcoin-mainnet-bootstrap.qcow2"
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
  printf '#!/bin/sh\nprintf "[GNUPG:] VALIDSIG AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 2026-01-01 0 0 0 0 0 0 0 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\\n"\n' >"$TEST_ROOT/bin/gpgv"
  chmod +x "$TEST_ROOT/bin/gpgv"
  bvml profiles-install >/dev/null
  assert_file "$BVML_HOST_CONFIG_DIR/host.env"
  assert_file "$BVML_HOST_CONFIG_DIR/releases/knots-version.env"
  assert_contains "$BVML_HOST_CONFIG_DIR/releases/knots-rdts.env" 'RDTS_REQUIRED_ARGS_JSON='
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
  for file in knots-version.env knots-rdts.env SHA256SUMS SHA256SUMS.asc signing-key.gpg; do
    printf data >"$BVML_HOST_CONFIG_DIR/releases/$file"
  done
  cp "$ROOT/config/checkpoint-profile-none.json" "$BVML_HOST_CONFIG_DIR/checkpoint-profile.json"
  touch "$TEST_ROOT/undefined-ubuntu"
  printf '#!/usr/bin/env bash\nset -Eeuo pipefail\nif [[ "${1:-}" == -E ]]; then shift; [[ "${1:-}" == env ]] && shift; while [[ "${1:-}" == *=* ]]; do shift; done; exec "$@"; fi\n[[ "${1:-}" == chown ]] && exit 0\nexec "$@"\n' >"$TEST_ROOT/bin/sudo"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >"$TEST_ROOT/virt-customize.log"\n' >"$TEST_ROOT/bin/virt-customize"
  printf '#!/bin/sh\nprintf "<domain type=\\"kvm\\"><name>bvml-ubuntu</name></domain>\\n"\n' >"$TEST_ROOT/bin/virt-install"
  chmod +x "$TEST_ROOT/bin/sudo" "$TEST_ROOT/bin/virt-customize" "$TEST_ROOT/bin/virt-install"
  bvml create ubuntu >/dev/null
  assert_file "$BVML_STORAGE/vms/ubuntu/system.qcow2"
  assert_file "$BVML_STORAGE/vms/ubuntu/application.qcow2"
  assert_contains "$TEST_ROOT/virt-customize.log" '--ssh-inject'
  assert_contains "$TEST_ROOT/virsh.log" 'define'
  assert_absent "$TEST_ROOT/undefined-ubuntu"
}

case_name="${2:-}"
if [[ "${1:-}" == --case ]]; then
  set -Eeuo pipefail
  "t_$case_name"
  exit
fi

tests=(parallel nonoff failed_attach failed_owner failed_start detach_preserves reset_active reset_inactive
  reconcile new_overlay_evidence wrong_evidence wrong_filesystem unsynced_index wrong_knots arbitrary_rdts nonubuntu_promote unverified_adapter_start promote_active
  promote_attached conversion_preserves candidate_preserves post_install_restores promote_success bootstrap_no_source bootstrap_format_explicit
  bootstrap_refuse_canonical bootstrap_refuse_incomplete bootstrap_transition bootstrap_config_guard bootstrap_owner_failure
  bootstrap_reconcile bootstrap_stop_preinstall bootstrap_failed_promote_preserves bootstrap_recovery_ack bootstrap_identity_guards
  import_xor import_optional_indexes import_assertion import_refuses_bootstrap rollback_prevalidate
  rollback_reverse mount_fail_closed ubuntu_stop_uninstalled start_invalidates protection_order bind_readonly adapters_fail_closed
  container_proc_inside live_rdts_validation container_runtime_args guest_exec_waits guest_exec_request_json guest_exec_failure_output old_tip_rejected required_index_missing
  status_attachment_exact canonical_missing_generation canonical_missing_immutable canonical_wrong_profile
  overlay_generation_mismatch adapter_profile_metadata no_deleted_source provisioning_active_guard
  media_existing cloud_create_contract profile_install_contract profile_install_success
  cloud_create_success)
passed=0 failed=0
for test_name in "${tests[@]}"; do
  "$BASH" "$0" --case "$test_name"
  status=$?
  if ((status == 0)); then echo "ok - $test_name"; ((passed+=1))
  else echo "not ok - $test_name (exit $status)" >&2; ((failed+=1)); fi
done
# Prove the runner sees a strict-mode setup failure as a failure.
"$BASH" "$0" --case harness_setup_failure >/dev/null 2>&1
status=$?
if ((status != 0)); then echo "ok - harness detects setup failure"; ((passed+=1))
else echo "not ok - harness ignored setup failure" >&2; ((failed+=1)); fi
echo "$passed passed, $failed failed"
((failed == 0))
