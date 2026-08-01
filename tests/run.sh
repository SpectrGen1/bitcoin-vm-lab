#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
passed=0; failed=0
run_test() {
  local name="$1"; shift
  if (set -Eeuo pipefail; "$@"); then echo "ok - $name"; ((passed+=1)); else echo "not ok - $name" >&2; ((failed+=1)); fi
}

setup_case() {
  TEST_ROOT="$(mktemp -d)"
  export TEST_ROOT BVML_STORAGE="$TEST_ROOT/storage" BVML_TESTING=1
  export KNOTS_VERSION=27.1.knots KNOTS_RDTS_ARGS=-peerblockfilters=1
  export PATH="$TEST_ROOT/bin:$ORIGINAL_PATH"
  mkdir -p "$TEST_ROOT/bin" "$BVML_STORAGE"/{canonical,active,run,vms}
  for vm in ubuntu umbrel startos; do echo 'shut off' >"$TEST_ROOT/state-$vm"; done
  cp "$ROOT/tests/support/fake-virsh" "$TEST_ROOT/bin/virsh"
  cp "$ROOT/tests/support/fake-qemu-img" "$TEST_ROOT/bin/qemu-img"
  printf '#!/bin/sh\nprintf "blocks\\nchainstate\\n"\n' >"$TEST_ROOT/bin/virt-ls"
  printf '#!/bin/sh\nexit 1\n' >"$TEST_ROOT/bin/virt-cat"
  chmod +x "$TEST_ROOT/bin"/*
  printf 'standalone\n' >"$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2"
  chmod 0440 "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2"
  printf 'id=base-id\nblocksxor=0\nnetwork=main\nlayout=root-datadir\n' >"$BVML_STORAGE/canonical/manifest.env"
}
teardown_case() { chmod -R u+w "$TEST_ROOT" 2>/dev/null || true; rm -rf -- "$TEST_ROOT"; }
bvml() { "$ROOT/bin/bvml" "$@"; }
expect_fail() { if "$@" >/dev/null 2>&1; then return 1; fi; }
make_stopped_overlay() {
  bvml start "${1:-ubuntu}" >/dev/null
  bvml stop "${1:-ubuntu}" >/dev/null
}
write_verify() {
  printf '%s\n' vm=ubuntu network=main blocksxor=0 synced=1 clean_shutdown=1 \
    datadir_layout=root-datadir rdts_validated=1 knots_version=27.1.knots 'indexes_json=[]' \
    >"$BVML_STORAGE/active/ubuntu-verification.env"
}

t_parallel() { setup_case; trap teardown_case EXIT; bvml start ubuntu >/dev/null; expect_fail bvml start umbrel; }
t_nonoff_active() { setup_case; trap teardown_case EXIT; echo paused >"$TEST_ROOT/state-ubuntu"; expect_fail bvml start ubuntu; echo 'in shutdown' >"$TEST_ROOT/state-ubuntu"; expect_fail bvml start ubuntu; }
t_failed_start() { setup_case; trap teardown_case EXIT; touch "$TEST_ROOT/fail-start"; expect_fail bvml start ubuntu; [[ ! -e "$BVML_STORAGE/active/bitcoin-mainnet-overlay.qcow2" && ! -e "$BVML_STORAGE/run/owner.env" && ! -e "$TEST_ROOT/attach-ubuntu" ]]; }
t_promote_active() { setup_case; trap teardown_case EXIT; make_stopped_overlay; write_verify; echo paused >"$TEST_ROOT/state-startos"; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_promote_attached() { setup_case; trap teardown_case EXIT; make_stopped_overlay; write_verify; printf 'vdc %s\n' "$BVML_STORAGE/active/bitcoin-mainnet-overlay.qcow2" >"$TEST_ROOT/attach-umbrel"; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_nonubuntu_promote() { setup_case; trap teardown_case EXIT; make_stopped_overlay umbrel; write_verify; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_stale_and_extra() { setup_case; trap teardown_case EXIT; make_stopped_overlay; touch "$BVML_STORAGE/run/owner.env" "$BVML_STORAGE/active/extra.qcow2"; write_verify; expect_fail bvml checkpoint-promote --confirm-synced-clean; }
t_conversion_preserves() { setup_case; trap teardown_case EXIT; make_stopped_overlay; write_verify; old="$(sha256sum "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2")"; touch "$TEST_ROOT/fail-convert"; expect_fail bvml checkpoint-promote --confirm-synced-clean; [[ "$(sha256sum "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2")" == "$old" ]]; }
t_validation_preserves() { setup_case; trap teardown_case EXIT; make_stopped_overlay; write_verify; old="$(sha256sum "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2")"; touch "$TEST_ROOT/fail-candidate-check"; expect_fail bvml checkpoint-promote --confirm-synced-clean; [[ "$(sha256sum "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2")" == "$old" ]]; }
t_reset_active() { setup_case; trap teardown_case EXIT; bvml start ubuntu >/dev/null; bvml reset ubuntu >/dev/null; [[ ! -e "$BVML_STORAGE/active/bitcoin-mainnet-overlay.qcow2" && "$(cat "$TEST_ROOT/state-ubuntu")" == 'shut off' ]]; }
t_reset_inactive() { setup_case; trap teardown_case EXIT; make_stopped_overlay; bvml reset ubuntu >/dev/null; [[ ! -e "$BVML_STORAGE/active/bitcoin-mainnet-overlay.qcow2" ]]; }
t_storage_access() { setup_case; trap teardown_case EXIT; chmod 000 "$BVML_STORAGE"; expect_fail env BVML_TESTING=0 QEMU_USER=definitely-no-user "$ROOT/scripts/host/validate-gentoo.sh"; chmod 750 "$BVML_STORAGE"; }
t_xor() {
  setup_case; trap teardown_case EXIT
  rm -f "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2" "$BVML_STORAGE/canonical/manifest.env"
  mkdir -p "$TEST_ROOT/source"/{blocks,chainstate}; printf '\\001\\002\\003\\004\\005\\006\\007\\010' >"$TEST_ROOT/source/blocks/xor.dat"
  for x in virt-make-fs virt-ls; do printf '#!/bin/sh\nexit 0\n' >"$TEST_ROOT/bin/$x"; chmod +x "$TEST_ROOT/bin/$x"; done
  expect_fail bvml checkpoint-import --source "$TEST_ROOT/source" --snapshot
}
t_missing_knots() { setup_case; trap teardown_case EXIT; expect_fail env KNOTS_VERSION= KNOTS_RDTS_ARGS= "$ROOT/bin/bvml" validate; }
t_rotate_rollback() {
  setup_case; trap teardown_case EXIT; make_stopped_overlay; write_verify
  [[ "$(sed -n 's/^vm=//p' "$BVML_STORAGE/active/manifest.env")" == ubuntu ]]
  bvml checkpoint-promote --confirm-synced-clean >/dev/null
  [[ -f "$BVML_STORAGE/canonical/bitcoin-mainnet.rollback.qcow2" && ! -e "$BVML_STORAGE/active/bitcoin-mainnet-overlay.qcow2" ]]
  new="$(sha256sum "$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2" | awk '{print $1}')"
  bvml checkpoint-rollback >/dev/null
  [[ "$(sha256sum "$BVML_STORAGE/canonical/bitcoin-mainnet.rollback.qcow2" | awk '{print $1}')" == "$new" ]]
}

ORIGINAL_PATH="$PATH"; export ORIGINAL_PATH
run_test "refuse parallel VM use" t_parallel
run_test "paused and shutdown-in-progress are active" t_nonoff_active
run_test "failed start rolls back" t_failed_start
run_test "promotion refuses active VM" t_promote_active
run_test "promotion refuses attached VM" t_promote_attached
run_test "promotion refuses non-Ubuntu overlay" t_nonubuntu_promote
run_test "promotion refuses stale ownership and extra overlays" t_stale_and_extra
run_test "conversion failure preserves checkpoint" t_conversion_preserves
run_test "candidate validation failure preserves checkpoint" t_validation_preserves
run_test "reset stops active VM and discards" t_reset_active
run_test "reset discards inactive overlay" t_reset_inactive
run_test "inaccessible storage detected" t_storage_access
run_test "XOR-enabled source rejected" t_xor
run_test "missing Knots/RDTS configuration detected" t_missing_knots
run_test "successful rotation and rollback" t_rotate_rollback
echo "$passed passed, $failed failed"
((failed == 0))
