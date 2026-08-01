#!/usr/bin/env bash
# Exact-version Umbrel package integration. The versioned implementation
# preserves the package entrypoint and integration behavior.
set -Eeuo pipefail
COMMON=/usr/local/libexec/bvml/adapter-common.sh
[[ -r "$COMMON" ]] || { echo "error: missing adapter common library" >&2; exit 1; }
# shellcheck source=adapter-common.sh
source "$COMMON"
PROFILE=/etc/bvml/umbrel-profile.env
PROFILE_DIGEST_FILE=/etc/bvml/umbrel-profile.sha256

load() {
  adapter_safe_file "$PROFILE" "$PROFILE_DIGEST_FILE"
  # shellcheck source=/dev/null
  source "$PROFILE"
  for v in PROFILE_ID ADAPTER_IMPLEMENTATION_VERSION SUPPORTED_OS_VERSION SUPPORTED_APP_VERSION \
    APP_ID COMPOSE_PROJECT COMPOSE_FILE BITCOIN_SERVICE EXPECTED_IMAGE \
    EXPECTED_ENTRYPOINT_JSON EXPECTED_COMMAND_JSON EXPECTED_ENV_JSON EXPECTED_RUNTIME_UID \
    EXPECTED_ENDPOINTS_JSON CONTAINER_DATADIR CONTAINER_KNOTS_EXE KNOTS_RELEASE_DIR \
    KNOTS_BITCOIND_SHA256 RDTS_REQUIRED_ARGS_JSON BITCOIN_DEVICE BITCOIN_MOUNT \
    TRANSFORM_SCRIPT TRANSFORM_SCRIPT_SHA256; do adapter_scalar "$v"; done
  for v in COMPOSE_FILE CONTAINER_DATADIR CONTAINER_KNOTS_EXE KNOTS_RELEASE_DIR \
    BITCOIN_DEVICE BITCOIN_MOUNT TRANSFORM_SCRIPT; do adapter_absolute_path "$v"; done
  for v in APP_ID COMPOSE_PROJECT BITCOIN_SERVICE; do adapter_identifier "$v"; done
  [[ "$(source /etc/os-release; printf '%s' "$VERSION_ID")" == "$SUPPORTED_OS_VERSION" ]] ||
    adapter_fail "unsupported UmbrelOS version"
  adapter_safe_file "$TRANSFORM_SCRIPT"
  [[ "$(sha256sum "$TRANSFORM_SCRIPT" | awk '{print $1}')" == "$TRANSFORM_SCRIPT_SHA256" ]] ||
    adapter_fail "Umbrel implementation digest mismatch"
  [[ -x "$TRANSFORM_SCRIPT" ]] || adapter_fail "Umbrel implementation is not executable"
  PROFILE_DIGEST="$(tr -d '[:space:]' <"$PROFILE_DIGEST_FILE")"
}

container_id() {
  docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" ps -q "$BITCOIN_SERVICE"
}

verify_original_contract() {
  local cid="$1" image entrypoint command env
  image="$(docker inspect "$cid" --format '{{.Config.Image}}')"
  entrypoint="$(docker inspect "$cid" --format '{{json .Config.Entrypoint}}')"
  command="$(docker inspect "$cid" --format '{{json .Config.Cmd}}')"
  env="$(docker inspect "$cid" --format '{{json .Config.Env}}')"
  [[ "$image" == "$EXPECTED_IMAGE" ]] || adapter_fail "Umbrel image no longer matches exact package profile"
  jq -e --argjson expected "$EXPECTED_ENTRYPOINT_JSON" '. == $expected' <<<"$entrypoint" >/dev/null ||
    adapter_fail "Umbrel entrypoint differs from profiled package behavior"
  jq -e --argjson expected "$EXPECTED_COMMAND_JSON" '. == $expected' <<<"$command" >/dev/null ||
    adapter_fail "Umbrel command differs from profiled package behavior"
  jq -ne --argjson expected "$EXPECTED_ENV_JSON" --argjson actual "$env" '
    $expected | all(.[]; . as $item | $actual | index($item) != null)' >/dev/null ||
    adapter_fail "Umbrel environment no longer satisfies the exact package profile"
}

setup() {
  load; adapter_mount_disk
  [[ -f "$COMPOSE_FILE" ]] || adapter_fail "actual Umbrel compose file is missing"
  [[ -x "$KNOTS_RELEASE_DIR/bin/bitcoind" ]] || adapter_fail "pinned Knots release is missing"
  [[ "$(sha256sum "$KNOTS_RELEASE_DIR/bin/bitcoind" | awk '{print $1}')" == "$KNOTS_BITCOIND_SHA256" ]] ||
    adapter_fail "pinned Knots digest mismatch"
  local cid state; cid="$(container_id)"
  [[ -n "$cid" ]] || adapter_fail "profiled stock Umbrel container must exist before transformation"
  state="$("$TRANSFORM_SCRIPT" state "$PROFILE" "$cid")"
  case "$state" in
    stock) verify_original_contract "$cid" ;;
    transformed) "$TRANSFORM_SCRIPT" verify-transformation "$PROFILE" "$cid" ;;
    *) adapter_fail "Umbrel package is neither the profiled stock nor recognized transformed state" ;;
  esac
  "$TRANSFORM_SCRIPT" apply "$PROFILE"
  "$TRANSFORM_SCRIPT" recreate "$PROFILE"
  verify
}

verify() {
  load; adapter_mount_disk
  local cid mounts health endpoints extra
  cid="$(container_id)"; [[ -n "$cid" ]] || adapter_fail "Umbrel Bitcoin container is absent"
  mounts="$(docker inspect "$cid" --format '{{json .Mounts}}')"
  jq -e --arg s "$BITCOIN_MOUNT" --arg d "$CONTAINER_DATADIR" \
    'any(.[]; .Source == $s and .Destination == $d and .RW == true)' <<<"$mounts" >/dev/null ||
    adapter_fail "actual container does not use the overlay as its complete datadir"
  jq -e --arg s "$KNOTS_RELEASE_DIR" \
    'any(.[]; .Source == $s and .RW == false)' <<<"$mounts" >/dev/null ||
    adapter_fail "Knots release is not mounted read-only"
  verify_container_knots docker "$cid" "$CONTAINER_KNOTS_EXE" "$KNOTS_BITCOIND_SHA256" \
    "$CONTAINER_DATADIR" "$RDTS_REQUIRED_ARGS_JSON" "$EXPECTED_RUNTIME_UID"
  "$TRANSFORM_SCRIPT" verify-package "$PROFILE" "$cid"
  health="$(docker inspect "$cid" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')"
  [[ "$health" == healthy ]] || adapter_fail "Umbrel package health is '$health', expected healthy"
  endpoints="$EXPECTED_ENDPOINTS_JSON"
  jq -e 'type == "array" and all(.[]; type == "string" and length > 0)' <<<"$endpoints" >/dev/null ||
    adapter_fail "Umbrel expected endpoints profile is invalid"
  "$TRANSFORM_SCRIPT" verify-endpoints "$PROFILE" "$cid"
  extra="$(jq -n --arg cid "$cid" --arg health "$health" --argjson args "$CONTAINER_KNOTS_ARGS_JSON" \
    '{container_id:$cid,health:$health,observed_args:$args}')"
  write_adapter_metadata umbrel "$SUPPORTED_OS_VERSION" "$SUPPORTED_APP_VERSION" "$PROFILE_DIGEST" \
    "$CONTAINER_KNOTS_DIGEST" "$ADAPTER_IMPLEMENTATION_VERSION" "$extra"
}

stop() {
  if [[ ! -r "$PROFILE" || ! -r "$PROFILE_DIGEST_FILE" ]]; then
    pgrep -x bitcoind >/dev/null &&
      adapter_fail "Umbrel profile is absent but a Bitcoin process exists; cannot prove a clean application stop"
    echo "application already stopped: Umbrel adapter is not installed"
    return 0
  fi
  load
  local cid pid n=0
  cid="$(container_id)"
  [[ -n "$cid" ]] || { echo "application already stopped: Umbrel container is absent"; return 0; }
  pid="$(container_knots_pid docker "$cid" "$CONTAINER_KNOTS_EXE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || { echo "application already stopped: Knots process is absent"; return 0; }
  docker exec "$cid" "$(dirname "$CONTAINER_KNOTS_EXE")/bitcoin-cli" "-datadir=$CONTAINER_DATADIR" stop ||
    adapter_fail "Umbrel Knots exists but failed to accept clean shutdown"
  while container_knots_pid docker "$cid" "$CONTAINER_KNOTS_EXE" >/dev/null 2>&1; do
    ((n++ < 120)) || adapter_fail "Umbrel Knots did not stop"; sleep 1
  done
  sync; echo "application stopped successfully"
}

case "${1:-status}" in
  setup) setup ;;
  verify|status) verify ;;
  stop) stop ;;
  *) adapter_fail "usage: $0 {setup|verify|stop|status}" ;;
esac
