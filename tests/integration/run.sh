#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

[[ "${BVML_INTEGRATION:-0}" == 1 ]] ||
  { echo "refusing: set BVML_INTEGRATION=1 explicitly" >&2; exit 64; }
[[ "${BVML_INTEGRATION_STORAGE:-}" == /* &&
   "${BVML_INTEGRATION_STORAGE:-}" != / &&
   -f "$BVML_INTEGRATION_STORAGE/.bvml-dedicated-integration-lab" ]] ||
  { echo "refusing: BVML_INTEGRATION_STORAGE must be a dedicated absolute lab path containing .bvml-dedicated-integration-lab" >&2; exit 64; }
export BVML_STORAGE="$BVML_INTEGRATION_STORAGE"
source "$ROOT/lib/common.sh"
[[ "$BVML_STORAGE" == "$BVML_INTEGRATION_STORAGE" ]] ||
  die "loaded configuration changed the dedicated integration storage path"

canonical_fingerprint() {
  [[ -f "$CANONICAL" && -f "$CANONICAL_META" ]] || return 0
  printf '%s:%s:%s:%s\n' "$(canonical_id)" "$(sha256sum "$CANONICAL_META" | awk '{print $1}')" \
    "$(stat -c '%a:%s:%b:%Y' "$CANONICAL")" "$(lsattr "$CANONICAL" | awk '{print $1}')"
}

assert_canonical_unchanged() {
  local before="$1" after; after="$(canonical_fingerprint)"
  [[ "$before" == "$after" ]] || die "canonical fingerprint changed during integration step"
  image_immutable "$CANONICAL" || die "canonical lost immutable protection"
}

wait_guest_transport() {
  local vm="$1" waited=0 timeout="${2:-300}"
  while (( waited < timeout )); do
    if (platform_exec_sync "$vm" /bin/true 15) >/dev/null 2>&1; then return 0; fi
    sleep 5
    ((waited+=5))
  done
  die "$vm management transport did not become ready within ${timeout}s"
}

wait_umbrel_validation() {
  local waited=0 timeout="${1:-1800}"
  while (( waited < timeout )); do
    if "$ROOT/bin/bvml" adapter-validate umbrel; then return 0; fi
    sleep 20
    ((waited+=20))
  done
  die "Umbrel did not reach fully synchronized validated state within ${timeout}s"
}

accept_umbrel_sync_pending() {
  local script operation
  script="$(jq -r .os.data_directory "$UMBREL_PROFILE")/.bvml/bin/umbrel-adapter.sh"
  operation="$(meta_get "$(lifecycle_recovery umbrel)" operation)"
  [[ "$operation" == adapter-setup || "$operation" == adapter-verify ]] ||
    die "Umbrel setup failed outside the expected synchronization gates"
  platform_exec_sync umbrel "$script" 120 prepared
  jq -e '.prepared==true and .blockchain.chain=="signet"' <<<"$GUEST_EXEC_STDOUT" >/dev/null ||
    die "Umbrel setup failure did not leave a profile-verified running Knots process"
}

case "${1:-preflight}" in
  preflight)
    "$ROOT/bin/bvml" host-validate
    "$ROOT/bin/bvml" validate
    ;;
  cloud)
    "$ROOT/bin/bvml" media-fetch ubuntu
    "$ROOT/bin/bvml" create ubuntu
    virshq start "$(domain ubuntu)"
    ready=0
    for _ in $(seq 1 90); do
      if virshq qemu-agent-command "$(domain ubuntu)" '{"execute":"guest-ping"}' >/dev/null 2>&1; then
        ready=1
        break
      fi
      sleep 1
    done
    (( ready == 1 )) || die "QGA did not become responsive"
    virshq shutdown "$(domain ubuntu)"
    for _ in $(seq 1 90); do is_shut_off ubuntu && exit 0; sleep 1; done
    die "Ubuntu did not shut off after cloud/QGA validation"
    ;;
  bootstrap-finalize)
    [[ "${BVML_CONFIRM_DESTRUCTIVE_INTEGRATION:-0}" == 1 ]] ||
      die "set BVML_CONFIRM_DESTRUCTIVE_INTEGRATION=1"
    "$ROOT/bin/bvml" bootstrap-stop
    "$ROOT/bin/bvml" bootstrap-verify
    "$ROOT/bin/bvml" bootstrap-promote --confirm-synced-clean
    canonical_preflight
    ;;
  ubuntu-smoke)
    before="$(canonical_fingerprint)"
    "$ROOT/bin/bvml" start ubuntu
    guest_exec_sync ubuntu /usr/local/libexec/bvml/ubuntu-knots-rdts.sh "$GUEST_EXEC_TIMEOUT" start
    guest_exec_sync ubuntu /usr/local/bin/bitcoin-cli 120 -conf=/etc/bvml/bitcoin.conf getblockchaininfo
    "$ROOT/bin/bvml" stop ubuntu
    "$ROOT/bin/bvml" discard ubuntu
    assert_canonical_unchanged "$before"
    ;;
  umbrel)
    before="$(canonical_fingerprint)"
    if ! is_defined umbrel; then
      "$ROOT/bin/bvml" media-fetch umbrel
      "$ROOT/bin/bvml" create umbrel
    fi
    if ! jq -e '.platform=="umbrel" and .provisioning_result=="ok"' \
      "$ADAPTER_STATE_DIR/umbrel.json" >/dev/null 2>&1; then
      virshq start "$(domain umbrel)"
      "$ROOT/bin/bvml" guest-provision umbrel
      virshq shutdown "$(domain umbrel)"
      for _ in $(seq 1 180); do is_shut_off umbrel && break; sleep 1; done
      is_shut_off umbrel || die "Umbrel did not shut off after guest provisioning"
    fi
    "$ROOT/bin/bvml" start umbrel
    if ! "$ROOT/bin/bvml" adapter-setup umbrel; then
      accept_umbrel_sync_pending
    fi
    wait_umbrel_validation
    "$ROOT/bin/bvml" stop umbrel
    "$ROOT/bin/bvml" discard umbrel
    assert_canonical_unchanged "$before"
    ;;
  concurrency)
    [[ "${BVML_CONFIRM_CONCURRENCY_INTEGRATION:-0}" == 1 ]] ||
      die "set BVML_CONFIRM_CONCURRENCY_INTEGRATION=1 for the Ubuntu/Umbrel concurrency test"
    canonical_preflight
    is_defined ubuntu && is_defined umbrel ||
      die "concurrency test requires provisioned Ubuntu and Umbrel domains"
    jq -e '.platform=="umbrel" and (.last_validation_result=="ok" or .provisioning_result=="ok")' \
      "$ADAPTER_STATE_DIR/umbrel.json" >/dev/null ||
      die "concurrency test requires the pinned Umbrel app provisioning"
    before="$(canonical_fingerprint)"
    "$ROOT/bin/bvml" start ubuntu
    "$ROOT/bin/bvml" start umbrel
    wait_guest_transport ubuntu 300
    wait_guest_transport umbrel 600
    guest_exec_sync ubuntu /usr/local/libexec/bvml/ubuntu-knots-rdts.sh "$GUEST_EXEC_TIMEOUT" start
    if ! "$ROOT/bin/bvml" adapter-setup umbrel; then
      accept_umbrel_sync_pending
    fi
    wait_umbrel_validation
    [[ "$(domain_state ubuntu)" == running && "$(domain_state umbrel)" == running ]] ||
      die "Ubuntu and Umbrel are not concurrently running"
    [[ "$(attached_vm_for_path "$(lifecycle_overlay ubuntu)" | paste -sd, -)" == ubuntu &&
       "$(attached_vm_for_path "$(lifecycle_overlay umbrel)" | paste -sd, -)" == umbrel ]] ||
      die "concurrent domains do not own distinct overlays"
    [[ "$(overlay_id "$(lifecycle_meta ubuntu)")" != "$(overlay_id "$(lifecycle_meta umbrel)")" ]] ||
      die "concurrent overlays have duplicate identities"
    assert_canonical_unchanged "$before"
    "$ROOT/bin/bvml" stop ubuntu
    [[ "$(domain_state umbrel)" == running &&
       -n "$(attached_vm_for_path "$(lifecycle_overlay umbrel)")" ]] ||
      die "stopping Ubuntu disturbed Umbrel"
    "$ROOT/bin/bvml" discard ubuntu
    "$ROOT/bin/bvml" stop umbrel
    "$ROOT/bin/bvml" discard umbrel
    assert_canonical_unchanged "$before"
    ;;
  startos)
    [[ "${BVML_CONFIRM_STARTOS_INTEGRATION:-0}" == 1 ]] ||
      die "set BVML_CONFIRM_STARTOS_INTEGRATION=1 for the StartOS concurrency test"
    canonical_preflight
    is_defined ubuntu || die "StartOS integration requires the provisioned Ubuntu VM"
    if ! is_defined startos; then
      "$ROOT/bin/bvml" credentials-init startos
      "$ROOT/bin/bvml" media-fetch startos
      "$ROOT/bin/bvml" create startos
    fi
    if ! jq -e '.platform=="startos" and .provisioning_result=="ok"' \
      "$ADAPTER_STATE_DIR/startos.json" >/dev/null 2>&1; then
      virshq start "$(domain startos)"
      wait_guest_transport startos 600
      "$ROOT/bin/bvml" guest-provision startos
      virshq shutdown "$(domain startos)"
      for _ in $(seq 1 180); do is_shut_off startos && break; sleep 1; done
      is_shut_off startos || die "StartOS did not shut off after provisioning"
    fi
    before="$(canonical_fingerprint)"
    "$ROOT/bin/bvml" start ubuntu
    "$ROOT/bin/bvml" start startos
    wait_guest_transport startos 600
    "$ROOT/bin/bvml" adapter-setup startos
    "$ROOT/bin/bvml" adapter-validate startos
    [[ "$(domain_state ubuntu)" == running && "$(domain_state startos)" == running ]] ||
      die "Ubuntu and StartOS were not concurrently running"
    "$ROOT/bin/bvml" stop startos
    "$ROOT/bin/bvml" discard startos
    [[ "$(domain_state ubuntu)" == running &&
       -n "$(attached_vm_for_path "$(lifecycle_overlay ubuntu)")" ]] ||
      die "StartOS cleanup disturbed the concurrent Ubuntu lifecycle"
    "$ROOT/bin/bvml" reset ubuntu
    assert_canonical_unchanged "$before"
    ;;
  index-bootstrap-wait)
    # Non-destructive: wait until Ubuntu bootstrap indexers report synchronized
    # heights, then verify-stop and promote both bases. Leaves Ubuntu stopped
    # with retained Bitcoin overlay; does not discard.
    # guest_exec_sync dies on non-zero, so poll via a guest script that always
    # exits 0 and prints synced=0|1.
    canonical_preflight
    [[ "$(domain_state ubuntu)" == running ]] || die "Ubuntu must be running with index bootstraps"
    waited=0
    ready=0
    while (( waited < INDEX_BUILD_TIMEOUT )); do
      guest_exec_sync ubuntu /bin/bash 120 -c '
        set -euo pipefail
        node=$(bitcoin-cli -conf=/etc/bvml/bitcoin.conf getblockcount)
        eh=0; fh=0
        python3 - <<PY >/tmp/h-e 2>/dev/null || true
import json,socket
s=socket.create_connection(("127.0.0.1",50001),2)
s.sendall(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"blockchain.headers.subscribe\",\"params\":[]}\n")
print(json.loads(s.makefile("rb").readline())["result"]["height"])
PY
        python3 - <<PY >/tmp/h-f 2>/dev/null || true
import json,socket
s=socket.create_connection(("127.0.0.1",50002),2)
s.sendall(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"blockchain.headers.subscribe\",\"params\":[]}\n")
print(json.loads(s.makefile("rb").readline())["result"]["height"])
PY
        [[ -s /tmp/h-e ]] && eh=$(cat /tmp/h-e) || true
        [[ -s /tmp/h-f ]] && fh=$(cat /tmp/h-f) || true
        synced=0
        if (( eh > 0 && fh > 0 && node-eh <= 1 && node-fh <= 1 && node-eh >= 0 && node-fh >= 0 )); then
          synced=1
        fi
        printf "node=%s electrs=%s fulcrum=%s synced=%s\n" "$node" "$eh" "$fh" "$synced"
        exit 0
      '
      note "index bootstrap progress: $GUEST_EXEC_STDOUT"
      if [[ "$GUEST_EXEC_STDOUT" == *synced=1* ]]; then
        ready=1
        break
      fi
      sleep 120
      ((waited+=120))
    done
    (( ready == 1 )) || die "index bootstraps did not synchronize within INDEX_BUILD_TIMEOUT"
    for service in electrs fulcrum; do
      "$ROOT/bin/bvml" index-bootstrap-verify "$service"
    done
    "$ROOT/bin/bvml" stop ubuntu
    for service in electrs fulcrum; do
      "$ROOT/bin/bvml" index-bootstrap-promote "$service" --confirm-index-synced
    done
    "$ROOT/bin/bvml" index-status
    ;;
  index-consumers)
    # Prove Ubuntu, Umbrel, and StartOS open promoted bases and advance.
    # Ends with all three VMs stopped and overlays retained (not discarded).
    canonical_preflight
    for service in electrs fulcrum; do
      index_base_preflight "$service"
    done
    before="$(canonical_fingerprint)"

    "$ROOT/bin/bvml" start ubuntu
    wait_guest_transport ubuntu 300
    guest_exec_sync ubuntu /usr/local/libexec/bvml/ubuntu-knots-rdts.sh "$GUEST_EXEC_TIMEOUT" start
    "$ROOT/bin/bvml" index-adapter-setup ubuntu
    "$ROOT/bin/bvml" index-adapter-validate ubuntu
    "$ROOT/bin/bvml" stop ubuntu

    "$ROOT/bin/bvml" start umbrel --adapter-setup
    wait_guest_transport umbrel 600
    "$ROOT/bin/bvml" guest-index-provision umbrel
    if ! "$ROOT/bin/bvml" adapter-setup umbrel; then
      accept_umbrel_sync_pending
    fi
    wait_umbrel_validation
    "$ROOT/bin/bvml" index-adapter-validate umbrel
    "$ROOT/bin/bvml" stop umbrel

    is_defined startos || die "StartOS domain is required for index-consumers"
    "$ROOT/bin/bvml" start startos --adapter-setup
    wait_guest_transport startos 600
    "$ROOT/bin/bvml" guest-index-provision startos
    "$ROOT/bin/bvml" adapter-setup startos
    "$ROOT/bin/bvml" adapter-validate startos
    "$ROOT/bin/bvml" index-adapter-validate startos
    "$ROOT/bin/bvml" stop startos

    assert_canonical_unchanged "$before"
    for vm in ubuntu umbrel startos; do
      is_shut_off "$vm" || die "$vm was not left shut off"
      [[ -f "$(lifecycle_overlay "$vm")" ]] || die "$vm Bitcoin overlay was not retained"
    done
    "$ROOT/bin/bvml" index-status
    "$ROOT/bin/bvml" status
    ;;
  *)
    die "usage: $0 {preflight|cloud|bootstrap-finalize|ubuntu-smoke|umbrel|concurrency|startos|index-bootstrap-wait|index-consumers}"
    ;;
esac
