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
  umbrel|startos)
    platform="$1"; before="$(canonical_fingerprint)"
    "$ROOT/bin/bvml" start "$platform" --adapter-setup
    "$ROOT/bin/bvml" adapter-setup "$platform"
    "$ROOT/bin/bvml" adapter-validate "$platform"
    "$ROOT/bin/bvml" stop "$platform"
    "$ROOT/bin/bvml" discard "$platform"
    assert_canonical_unchanged "$before"
    ;;
  *)
    die "usage: $0 {preflight|cloud|bootstrap-finalize|ubuntu-smoke|umbrel|startos}"
    ;;
esac
