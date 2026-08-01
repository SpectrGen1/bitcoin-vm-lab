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
  export KNOTS_VERSION="Bitcoin Knots version 29.1.knots" KNOTS_ARTIFACT_SHA256=artifact-digest
  export KNOTS_RELEASE_PROFILE="$TEST_ROOT/release.env" KNOTS_RDTS_PROFILE="$TEST_ROOT/rdts.env"
  export KNOTS_RDTS_PROFILE_SHA256=dummy UMBREL_SUPPORTED_VERSION=test STARTOS_SUPPORTED_VERSION=test
  mkdir -p "$TEST_ROOT/bin" "$BVML_STORAGE"/{canonical,active,run,vms}
  for vm in ubuntu umbrel startos; do printf 'shut off\n' >"$TEST_ROOT/state-$vm"; done
  cp "$ROOT/tests/support/fake-virsh" "$TEST_ROOT/bin/virsh"
  cp "$ROOT/tests/support/fake-qemu-img" "$TEST_ROOT/bin/qemu-img"
  printf '#!/bin/sh\nprintf "blocks\\nchainstate\\nindexes\\n"\n' >"$TEST_ROOT/bin/virt-ls"
  printf '#!/bin/sh\n[[ ! -e "$TEST_ROOT/fail-virt-customize" ]]\n' >"$TEST_ROOT/bin/virt-customize"
  printf '#!/bin/sh\ncase "$*" in *ubuntu-verification.env*) [[ -f "$TEST_ROOT/guest-evidence" ]] && cat "$TEST_ROOT/guest-evidence" || exit 1;; *) exit 0;; esac\n' >"$TEST_ROOT/bin/virt-cat"
  printf '#!/bin/sh\nprintf "Name UUID\\n/dev/sda fs1\\n"\n' >"$TEST_ROOT/bin/virt-filesystems"
  printf '#!/usr/bin/env bash\nset -Eeuo pipefail\nsize=; out="${@: -1}"\nwhile (($#)); do case "$1" in --size) size="$2"; shift 2;; --size=*) size="${1#--size=}"; shift;; *) shift;; esac; done\n[[ "$size" =~ ^[0-9]+$ ]] || exit 9\nprintf "backing=\\nimport_size=%s\\n" "$size" >"$out"\n' >"$TEST_ROOT/bin/virt-make-fs"
  chmod +x "$TEST_ROOT/bin"/*
  : >"$TEST_ROOT/release.env"; : >"$TEST_ROOT/rdts.env"
}
teardown_case() { chmod -R u+w "$TEST_ROOT" 2>/dev/null || true; rm -rf -- "$TEST_ROOT"; }
make_canonical() {
  printf 'backing=\ncanonical\n' >"$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2"
  chmod 0440 "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2"
  printf 'id=base-id\ngeneration=base-generation\nblocksxor=0\nnetwork=main\nlayout=root-datadir\n' \
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
    datadir_layout=root-datadir rdts_validated=1 "knots_actual_version=$KNOTS_VERSION" \
    "artifact_sha256=$KNOTS_ARTIFACT_SHA256" "rdts_profile=$KNOTS_RDTS_PROFILE" \
    'rdts_effective_args=-peerblockfilters=1' block_height=100 header_height=100 \
    best_block_hash=abc tip_time=123 filesystem_uuid=fs1 'indexes_json=[]' \
    'index_sync_json={}' shutdown_id=shutdown-1 "overlay_id=$overlay_id" \
    "checkpoint_generation=$generation" >"$BVML_STORAGE/active/ubuntu-verification.env"
}
write_guest_evidence() {
  printf '%s\n' vm=ubuntu network=main blocksxor=0 synced=1 clean_shutdown=1 \
    datadir_layout=root-datadir rdts_validated=1 "knots_actual_version=$KNOTS_VERSION" \
    "artifact_sha256=$KNOTS_ARTIFACT_SHA256" "rdts_profile=$KNOTS_RDTS_PROFILE" \
    'rdts_effective_args=-peerblockfilters=1' block_height=100 header_height=100 \
    best_block_hash=abc tip_time=123 filesystem_uuid=fs1 'indexes_json=[]' \
    'index_sync_json={}' shutdown_id=shutdown-bootstrap >"$TEST_ROOT/guest-evidence"
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
t_reconcile() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; printf 'vm=ubuntu\noverlay=%s\noverlay_id=%s\n' "$BVML_STORAGE/active/bitcoin-mainnet-overlay.qcow2" "$(sed -n 's/^overlay_id=//p' "$BVML_STORAGE/active/manifest.env")" >"$BVML_STORAGE/run/owner.env"; bvml reconcile >/dev/null; assert_absent "$BVML_STORAGE/run/owner.env"; assert_file "$BVML_STORAGE/active/bitcoin-mainnet-overlay.qcow2"; }
t_new_overlay_evidence() { setup_case; trap teardown_case EXIT; make_canonical; touch "$BVML_STORAGE/active/ubuntu-verification.env"; bvml start ubuntu >/dev/null; assert_absent "$BVML_STORAGE/active/ubuntu-verification.env"; }
t_wrong_evidence() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; sed -i 's/^overlay_id=.*/overlay_id=old/' "$BVML_STORAGE/active/ubuntu-verification.env"; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_wrong_filesystem() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_guest_evidence; sed -i 's/^filesystem_uuid=.*/filesystem_uuid=another-fs/' "$TEST_ROOT/guest-evidence"; expect_fail bvml checkpoint-verify; }
t_unsynced_index() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; sed -i 's/^index_sync_json=.*/index_sync_json={\"txindex\":false}/' "$BVML_STORAGE/active/ubuntu-verification.env"; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_wrong_knots() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; sed -i 's/^knots_actual_version=.*/knots_actual_version=Bitcoin Core/' "$BVML_STORAGE/active/ubuntu-verification.env"; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_arbitrary_rdts() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; sed -i 's#^rdts_profile=.*#rdts_profile=/tmp/arbitrary#' "$BVML_STORAGE/active/ubuntu-verification.env"; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_nonubuntu_promote() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay umbrel; write_verify; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_promote_active() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; printf 'pmsuspended\n' >"$TEST_ROOT/state-startos"; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_promote_attached() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; printf 'vdc %s\n' "$BVML_STORAGE/active/bitcoin-mainnet-overlay.qcow2" >"$TEST_ROOT/attach-umbrel"; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_conversion_preserves() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; old="$(sha256sum "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2")"; touch "$TEST_ROOT/fail-convert"; expect_fail bvml checkpoint-promote --confirm-synced-clean; assert_eq "$(sha256sum "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2")" "$old"; }
t_candidate_preserves() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; old="$(sha256sum "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2")"; touch "$TEST_ROOT/fail-virt-customize"; expect_fail bvml checkpoint-promote --confirm-synced-clean; assert_eq "$(sha256sum "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2")" "$old"; }
t_post_install_restores() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; old="$(sha256sum "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2")"; touch "$TEST_ROOT/fail-post-install"; expect_fail bvml checkpoint-promote --confirm-synced-clean; assert_eq "$(sha256sum "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2")" "$old"; assert_file "$BVML_STORAGE/run/recovery.env"; }
t_promote_success() { setup_case; trap teardown_case EXIT; make_canonical; make_stopped_overlay; write_verify; bvml checkpoint-promote --confirm-synced-clean >/dev/null; assert_file "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2"; assert_file "$BVML_STORAGE/canonical/bitcoin-mainnet.rollback.qcow2"; assert_absent "$BVML_STORAGE/active/bitcoin-mainnet-overlay.qcow2"; [[ ! -w "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2" ]]; }
t_bootstrap_no_source() { setup_case; trap teardown_case EXIT; bvml checkpoint-bootstrap >/dev/null; assert_file "$BVML_STORAGE/active/bitcoin-mainnet-bootstrap.qcow2"; assert_contains "$BVML_STORAGE/active/bootstrap-manifest.env" 'filesystem_initialized=0'; assert_file "$TEST_ROOT/attach-ubuntu"; }
t_bootstrap_format_explicit() { setup_case; trap teardown_case EXIT; bvml checkpoint-bootstrap >/dev/null; expect_fail bvml bootstrap-init; bvml bootstrap-init --confirm-device-vdc >/dev/null; assert_contains "$BVML_STORAGE/active/bootstrap-manifest.env" 'filesystem_initialized=1'; }
t_bootstrap_refuse_canonical() { setup_case; trap teardown_case EXIT; make_canonical; expect_fail bvml checkpoint-bootstrap; }
t_bootstrap_refuse_incomplete() { setup_case; trap teardown_case EXIT; bvml checkpoint-bootstrap >/dev/null; expect_fail bvml bootstrap-promote --confirm-synced-clean; assert_file "$BVML_STORAGE/active/bitcoin-mainnet-bootstrap.qcow2"; }
t_bootstrap_transition() { setup_case; trap teardown_case EXIT; bvml checkpoint-bootstrap >/dev/null; bvml bootstrap-init --confirm-device-vdc >/dev/null; write_guest_evidence; bvml bootstrap-stop >/dev/null; bvml bootstrap-verify >/dev/null; bvml bootstrap-promote --confirm-synced-clean >/dev/null; assert_file "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2"; assert_absent "$BVML_STORAGE/active/bitcoin-mainnet-bootstrap.qcow2"; [[ ! -w "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2" ]]; }
t_bootstrap_config_guard() { assert_contains "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" 'blocksxor=0'; assert_contains "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" 'KNOTS_RDTS_PROFILE_SHA256'; assert_contains "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" 'RDTS_REQUIRED_ARGS'; }
t_import_xor() { setup_case; trap teardown_case EXIT; mkdir -p "$TEST_ROOT/source"/{blocks,chainstate}; printf '\\001\\002' >"$TEST_ROOT/source/blocks/xor.dat"; expect_fail bvml checkpoint-import "$TEST_ROOT/source" --consistent-snapshot --assert-mainnet; assert_absent "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2"; }
t_import_optional_indexes() { setup_case; trap teardown_case EXIT; mkdir -p "$TEST_ROOT/source"/{blocks,chainstate}; printf data >"$TEST_ROOT/source/blocks/blk.dat"; printf state >"$TEST_ROOT/source/chainstate/data"; bvml checkpoint-import "$TEST_ROOT/source" --consistent-snapshot --assert-mainnet >/dev/null; assert_file "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2"; assert_contains "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2" 'import_size='; }
t_import_assertion() { setup_case; trap teardown_case EXIT; mkdir -p "$TEST_ROOT/source"/{blocks,chainstate}; expect_fail bvml checkpoint-import "$TEST_ROOT/source"; }
t_rollback_prevalidate() { setup_case; trap teardown_case EXIT; make_canonical; printf 'backing=/bad\n' >"$BVML_STORAGE/canonical/bitcoin-mainnet.rollback.qcow2"; printf 'id=bad\n' >"$BVML_STORAGE/canonical/rollback-manifest.env"; old="$(sha256sum "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2")"; expect_fail bvml checkpoint-rollback; assert_eq "$(sha256sum "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2")" "$old"; }
t_rollback_reverse() { setup_case; trap teardown_case EXIT; make_canonical; printf 'backing=\nrollback-image\n' >"$BVML_STORAGE/canonical/bitcoin-mainnet.rollback.qcow2"; chmod 0440 "$BVML_STORAGE/canonical/bitcoin-mainnet.rollback.qcow2"; printf 'id=rollback\ngeneration=old\nblocksxor=0\n' >"$BVML_STORAGE/canonical/rollback-manifest.env"; old="$(sha256sum "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2")"; touch "$TEST_ROOT/fail-rollback-install"; expect_fail bvml checkpoint-rollback; assert_eq "$(sha256sum "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2")" "$old"; assert_file "$BVML_STORAGE/run/recovery.env"; }
t_mount_fail_closed() { assert_contains "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" 'ConditionPathIsMountPoint='; assert_contains "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" 'RequiresMountsFor='; assert_contains "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" 'bitcoin-filesystem.uuid'; }
t_start_invalidates() { assert_contains "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" 'start_knots()'; assert_contains "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh" 'invalidate_evidence'; }
t_protection_order() { local file="$ROOT/lib/common.sh" chown mode acl readable immutable; chown="$(rg -n 'sudo chown.*image' "$file" | cut -d: -f1)"; mode="$(rg -n 'chmod 0440.*image' "$file" | cut -d: -f1)"; acl="$(rg -n 'setfacl.*QEMU_USER:r--' "$file" | cut -d: -f1)"; readable="$(rg -n 'QEMU_USER.*test -r' "$file" | cut -d: -f1)"; immutable="$(rg -n -F 'sudo chattr +i' "$file" | cut -d: -f1)"; ((chown < mode && mode < acl && acl < readable && readable < immutable)); }
t_bind_readonly() { assert_contains "$ROOT/scripts/vm/guest/umbrel-adapter.sh" '/opt/bvml-knots:ro'; assert_contains "$ROOT/scripts/vm/guest/startos-adapter.sh" '.RW == false'; }
t_adapters_fail_closed() { expect_fail env PATH="$ORIGINAL_PATH" bash "$ROOT/scripts/vm/guest/umbrel-adapter.sh" status; expect_fail env PATH="$ORIGINAL_PATH" bash "$ROOT/scripts/vm/guest/startos-adapter.sh" status; }
t_no_deleted_source() { ! rg -n '/home/brian/projects/bitcoin-knots-dev/bitcoin|BITCOIN_SOURCE' "$ROOT/config" "$ROOT/bin" "$ROOT/scripts" "$ROOT/README.md" "$ROOT/docs"; }

case_name="${2:-}"
if [[ "${1:-}" == --case ]]; then
  set -Eeuo pipefail
  "t_$case_name"
  exit
fi

tests=(parallel nonoff failed_attach failed_owner failed_start detach_preserves reset_active reset_inactive
  reconcile new_overlay_evidence wrong_evidence wrong_filesystem unsynced_index wrong_knots arbitrary_rdts nonubuntu_promote promote_active
  promote_attached conversion_preserves candidate_preserves post_install_restores promote_success bootstrap_no_source bootstrap_format_explicit
  bootstrap_refuse_canonical bootstrap_refuse_incomplete bootstrap_transition bootstrap_config_guard import_xor import_optional_indexes import_assertion rollback_prevalidate
  rollback_reverse mount_fail_closed start_invalidates protection_order bind_readonly adapters_fail_closed no_deleted_source)
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
