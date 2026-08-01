#!/usr/bin/env bash
# Exact-version StartOS package implementation and verification.
set -Eeuo pipefail
COMMON=/usr/local/libexec/bvml/adapter-common.sh
[[ -r "$COMMON" ]] || { echo "error: missing adapter common library" >&2; exit 1; }
# shellcheck source=adapter-common.sh
source "$COMMON"
PROFILE=/etc/bvml/startos-profile.env
PROFILE_DIGEST_FILE=/etc/bvml/startos-profile.sha256

load() {
  adapter_safe_file "$PROFILE" "$PROFILE_DIGEST_FILE"
  # shellcheck source=/dev/null
  source "$PROFILE"
  for v in PROFILE_ID ADAPTER_IMPLEMENTATION_VERSION SUPPORTED_OS_VERSION \
    SUPPORTED_PACKAGE_VERSION PACKAGE_ID PACKAGE_PROJECT_DIR PACKAGE_CONTAINER_NAME \
    CONTAINER_DATADIR CONTAINER_KNOTS_EXE EXPECTED_RUNTIME_UID EXPECTED_HEALTH_JSON \
    EXPECTED_DEPENDENCIES_JSON KNOTS_RELEASE_DIR KNOTS_BITCOIND_SHA256 \
    RDTS_REQUIRED_ARGS_JSON BITCOIN_DEVICE BITCOIN_MOUNT \
    PACKAGE_IMPLEMENTATION_SCRIPT PACKAGE_IMPLEMENTATION_SHA256; do adapter_scalar "$v"; done
  for v in PACKAGE_PROJECT_DIR CONTAINER_DATADIR CONTAINER_KNOTS_EXE KNOTS_RELEASE_DIR \
    BITCOIN_DEVICE BITCOIN_MOUNT PACKAGE_IMPLEMENTATION_SCRIPT; do adapter_absolute_path "$v"; done
  for v in PACKAGE_ID PACKAGE_CONTAINER_NAME; do adapter_identifier "$v"; done
  [[ "$(source /etc/os-release; printf '%s' "$VERSION_ID")" == "$SUPPORTED_OS_VERSION" ]] ||
    adapter_fail "unsupported StartOS version"
  adapter_safe_file "$PACKAGE_IMPLEMENTATION_SCRIPT"
  [[ "$(sha256sum "$PACKAGE_IMPLEMENTATION_SCRIPT" | awk '{print $1}')" == "$PACKAGE_IMPLEMENTATION_SHA256" ]] ||
    adapter_fail "StartOS package implementation digest mismatch"
  [[ -x "$PACKAGE_IMPLEMENTATION_SCRIPT" ]] || adapter_fail "StartOS implementation is not executable"
  PROFILE_DIGEST="$(tr -d '[:space:]' <"$PROFILE_DIGEST_FILE")"
}

setup() {
  load; adapter_mount_disk
  [[ -d "$PACKAGE_PROJECT_DIR" ]] || adapter_fail "versioned StartOS package source is missing"
  [[ -x "$KNOTS_RELEASE_DIR/bin/bitcoind" ]] || adapter_fail "pinned Knots release is missing"
  [[ "$(sha256sum "$KNOTS_RELEASE_DIR/bin/bitcoind" | awk '{print $1}')" == "$KNOTS_BITCOIND_SHA256" ]] ||
    adapter_fail "pinned Knots digest mismatch"
  "$PACKAGE_IMPLEMENTATION_SCRIPT" apply "$PROFILE"
  "$PACKAGE_IMPLEMENTATION_SCRIPT" build "$PROFILE"
  "$PACKAGE_IMPLEMENTATION_SCRIPT" install "$PROFILE"
  verify
}

verify() {
  load; adapter_mount_disk
  local mounts extra
  mounts="$(podman inspect "$PACKAGE_CONTAINER_NAME" --format '{{json .Mounts}}')"
  jq -e --arg s "$BITCOIN_MOUNT" --arg d "$CONTAINER_DATADIR" \
    'any(.[]; .Source == $s and .Destination == $d and .RW == true)' <<<"$mounts" >/dev/null ||
    adapter_fail "actual StartOS package container does not use overlay datadir"
  jq -e --arg s "$KNOTS_RELEASE_DIR" \
    'any(.[]; .Source == $s and .RW == false)' <<<"$mounts" >/dev/null ||
    adapter_fail "Knots release is not mounted read-only in the package"
  verify_container_knots podman "$PACKAGE_CONTAINER_NAME" "$CONTAINER_KNOTS_EXE" \
    "$KNOTS_BITCOIND_SHA256" "$CONTAINER_DATADIR" "$RDTS_REQUIRED_ARGS_JSON" "$EXPECTED_RUNTIME_UID"
  "$PACKAGE_IMPLEMENTATION_SCRIPT" verify-interfaces "$PROFILE" "$PACKAGE_CONTAINER_NAME"
  "$PACKAGE_IMPLEMENTATION_SCRIPT" verify-health "$PROFILE" "$PACKAGE_CONTAINER_NAME"
  "$PACKAGE_IMPLEMENTATION_SCRIPT" verify-no-competing-datadir "$PROFILE" "$PACKAGE_CONTAINER_NAME"
  extra="$(jq -n --arg container "$PACKAGE_CONTAINER_NAME" --argjson args "$CONTAINER_KNOTS_ARGS_JSON" \
    --argjson health "$EXPECTED_HEALTH_JSON" --argjson dependencies "$EXPECTED_DEPENDENCIES_JSON" \
    '{container_id:$container,observed_args:$args,expected_health:$health,expected_dependencies:$dependencies}')"
  write_adapter_metadata startos "$SUPPORTED_OS_VERSION" "$SUPPORTED_PACKAGE_VERSION" "$PROFILE_DIGEST" \
    "$CONTAINER_KNOTS_DIGEST" "$ADAPTER_IMPLEMENTATION_VERSION" "$extra"
}

stop() {
  if [[ ! -r "$PROFILE" || ! -r "$PROFILE_DIGEST_FILE" ]]; then
    pgrep -x bitcoind >/dev/null &&
      adapter_fail "StartOS profile is absent but a Bitcoin process exists; cannot prove a clean application stop"
    echo "application already stopped: StartOS adapter is not installed"
    return 0
  fi
  load
  local pid n=0
  podman inspect "$PACKAGE_CONTAINER_NAME" >/dev/null 2>&1 ||
    { echo "application already stopped: StartOS container is absent"; return 0; }
  pid="$(container_knots_pid podman "$PACKAGE_CONTAINER_NAME" "$CONTAINER_KNOTS_EXE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || { echo "application already stopped: Knots process is absent"; return 0; }
  podman exec "$PACKAGE_CONTAINER_NAME" "$(dirname "$CONTAINER_KNOTS_EXE")/bitcoin-cli" "-datadir=$CONTAINER_DATADIR" stop ||
    adapter_fail "StartOS Knots exists but failed to accept clean shutdown"
  while container_knots_pid podman "$PACKAGE_CONTAINER_NAME" "$CONTAINER_KNOTS_EXE" >/dev/null 2>&1; do
    ((n++ < 120)) || adapter_fail "StartOS Knots did not stop"; sleep 1
  done
  sync; echo "application stopped successfully"
}

case "${1:-status}" in
  setup) setup ;;
  verify|status) verify ;;
  stop) stop ;;
  *) adapter_fail "usage: $0 {setup|verify|stop|status}" ;;
esac
