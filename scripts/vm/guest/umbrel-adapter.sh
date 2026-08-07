#!/usr/bin/env bash
# Version-gated integration for Umbrel's unchanged official bitcoin-knots app.
# umbreld is the only lifecycle controller; Docker is used read-only for proof.
set -Eeuo pipefail

BVML_STATE=/home/umbrel/umbrel/.bvml
PROFILE=$BVML_STATE/etc/umbrel-profile.json
PROFILE_DIGEST=$BVML_STATE/etc/umbrel-profile.sha256
ACTIVE=$BVML_STATE/etc/active-overlay.json
EVIDENCE=$BVML_STATE/etc/adapter-verification.json
APP_ID=bitcoin-knots
DEVICE=/dev/vdc
TIMEOUT="${UMBREL_OPERATION_TIMEOUT:-1200}"

fail() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || fail "missing guest command: $1"; }
jqv() { jq -er "$1" "$PROFILE"; }

load_profile() {
  need jq; need sha256sum; need umbreld; need docker
  [[ -f "$PROFILE" && -f "$PROFILE_DIGEST" ]] || fail "pinned Umbrel profile is not installed"
  [[ "$(stat -c %u "$PROFILE")" == 0 && "$(stat -c %u "$PROFILE_DIGEST")" == 0 ]] ||
    fail "Umbrel profile must be root-owned"
  find "$PROFILE" "$PROFILE_DIGEST" -maxdepth 0 -perm /022 -print -quit | grep -q . &&
    fail "Umbrel profile is group/world writable"
  PROFILE_SHA="$(tr -d '[:space:]' <"$PROFILE_DIGEST")"
  [[ "$PROFILE_SHA" =~ ^[0-9a-f]{64}$ &&
     "$(sha256sum "$PROFILE" | awk '{print $1}')" == "$PROFILE_SHA" ]] ||
    fail "Umbrel profile digest mismatch"
  jq -e '
    .profile_version == 1 and .app_store.app_id == "bitcoin-knots" and
    .app_store.host_datadir_suffix == "app-data/bitcoin-knots/data/bitcoin" and
    .app_store.container_datadir == "/data/bitcoin" and
    .knots.required_settings.chain == "main" and
    .knots.required_settings.consensusrules == true and
    .knots.required_settings.prune == 0
  ' "$PROFILE" >/dev/null || fail "unsupported or unsafe Umbrel profile"
  OS_VERSION="$(jqv .os.version)"
  APP_VERSION="$(jqv .app_store.app_version)"
  KNOTS_VERSION="$(jqv .knots.version)"
  KNOTS_EXE="$(jqv .knots.executable)"
  KNOTS_SHA="$(jqv .knots.binary_sha256)"
  IMAGE="$(jqv .app_store.image)"
  DATADIR_SUFFIX="$(jqv .app_store.host_datadir_suffix)"
  CONTAINER_DATADIR="$(jqv .app_store.container_datadir)"
}

verify_os() {
  local reported package
  reported="$(umbreld client system.version.query 2>/dev/null)" ||
    fail "umbreld system.version query failed"
  package="$(jq -er .version /opt/umbreld/package.json)" ||
    fail "installed umbreld package has no machine-readable version"
  [[ "$(jq -r '.version // empty' <<<"$reported")" == "$OS_VERSION" &&
     "$package" == "$OS_VERSION" ]] ||
    fail "umbrelOS/umbreld version differs from pinned '$OS_VERSION'"
}

umbrel_root() {
  local proc arg root roots=
  for proc in /proc/[0-9]*; do
    [[ -r "$proc/cmdline" ]] || continue
    mapfile -d '' -t argv <"$proc/cmdline" || true
    [[ " ${argv[*]} " == *" /opt/umbreld/"*"source/cli.ts "* ]] || continue
    for arg in "${argv[@]}"; do
      case "$arg" in
        --data-directory=/*) roots+="${arg#--data-directory=}"$'\n' ;;
      esac
    done
  done
  root="$(sed '/^$/d' <<<"$roots" | sort -u)"
  [[ -n "$root" && "$(wc -l <<<"$root")" == 1 &&
     ! "$root" =~ [[:cntrl:]] ]] ||
    fail "could not resolve one safe Umbrel data directory from the live umbreld process"
  root="$(readlink -m "$root")"
  [[ -f "$root/app-data/$APP_ID/exports.sh" ]] ||
    fail "installed official bitcoin-knots exports.sh was not found beneath $root"
  printf '%s\n' "$root"
}

resolve_app() {
  UMBREL_ROOT="$(umbrel_root)"
  APP_DIR="$UMBREL_ROOT/app-data/$APP_ID"
  EXPORTS="$APP_DIR/exports.sh"
  [[ -f "$EXPORTS" ]] || fail "installed exports.sh is missing"
  local key expected actual repo migrate_source_record=0
  repo="$(find "$UMBREL_ROOT/app-stores" -type f -path '*/.git/config' \
    -exec grep -lF 'github.com/getumbrel/umbrel-apps' {} \; 2>/dev/null |
    sed 's#/.git/config$##' | head -1)"
  if [[ -f "$BVML_STATE/etc/umbrel-provisioned.json" ]]; then
    jq -e --arg profile "$PROFILE_SHA" '.profile_digest==$profile' \
      "$BVML_STATE/etc/umbrel-provisioned.json" >/dev/null ||
      fail "installed app provisioning record belongs to another profile"
    if jq -e --arg commit "$(jqv .app_store.commit)" '.source_commit==$commit' \
      "$BVML_STATE/etc/umbrel-provisioned.json" >/dev/null; then
      :
    elif jq -e 'has("source_commit")|not' \
      "$BVML_STATE/etc/umbrel-provisioned.json" >/dev/null; then
      migrate_source_record=1
    else
      fail "installed app provisioning record is not bound to the pinned app-store commit"
    fi
  else
    [[ -n "$repo" && "$(git -C "$repo" rev-parse HEAD)" == "$(jqv .app_store.commit)" ]] ||
      fail "app installation source is not the pinned official app-store commit"
    while IFS=$'\t' read -r key expected; do
      actual="$(sha256sum "$repo/$APP_ID/$key" | awk '{print $1}')" ||
        fail "missing pinned upstream package file $key"
      [[ "$actual" == "$expected" ]] ||
        fail "pinned upstream package file drift: $key"
    done < <(jq -r '.app_store.files | to_entries[] | [.key,.value] | @tsv' "$PROFILE")
  fi
  while IFS=$'\t' read -r key expected; do
    actual="$(sha256sum "$APP_DIR/$key" | awk '{print $1}')" ||
      fail "missing transformed installed package file $key"
    [[ "$actual" == "$expected" ]] ||
      fail "Umbrel legacy-compat package transformation drift: $key"
  done < <(jq -r '.app_store.installed_files | to_entries[] | [.key,.value] | @tsv' "$PROFILE")
  if (( migrate_source_record )); then
    local provisioned_tmp="$BVML_STATE/etc/umbrel-provisioned.json.new"
    jq --arg commit "$(jqv .app_store.commit)" '.source_commit=$commit' \
      "$BVML_STATE/etc/umbrel-provisioned.json" >"$provisioned_tmp"
    chown root:root "$provisioned_tmp"; chmod 0600 "$provisioned_tmp"
    mv -f -- "$provisioned_tmp" "$BVML_STATE/etc/umbrel-provisioned.json"
  fi
  # exports.sh is trusted only after its pinned digest has been checked.
  EXPORTS_APP_DIR="$APP_DIR"; EXPORTS_APP_ID="$APP_ID"; EXPORTS_TOR_DATA_DIR="$UMBREL_ROOT/tor/data"
  export EXPORTS_APP_DIR EXPORTS_APP_ID EXPORTS_TOR_DATA_DIR UMBREL_ROOT
  # shellcheck source=/dev/null
  source "$EXPORTS"
  [[ "${APP_BITCOIN_KNOTS_RPC_PORT:-}" =~ ^[0-9]{1,5}$ &&
     "$APP_BITCOIN_KNOTS_RPC_PORT" -ge 1 && "$APP_BITCOIN_KNOTS_RPC_PORT" -le 65535 ]] ||
    fail "exports.sh did not provide a safe official Knots RPC port"
  DATADIR="$(readlink -m "$APP_BITCOIN_KNOTS_DATA_DIR")"
  [[ "$DATADIR" == "$APP_DIR/data/bitcoin" ]] ||
    fail "exports.sh resolved unexpected datadir '$DATADIR'"
}

umbrel_call() {
  local route="$1"; shift
  umbreld client "$route" --appId "$APP_ID" "$@"
}

app_state_json() {
  local output
  output="$(umbrel_call apps.state.query 2>&1)" ||
    fail "umbreld apps.state query failed: $output"
  jq -ec 'if type=="object" and has("state") then . elif type=="object" and
    (.data|type)=="object" then .data else empty end' <<<"$output" ||
    fail "umbreld returned an unrecognized app-state response"
}

wait_state() {
  local wanted="$1" waited=0 state json
  while (( waited < TIMEOUT )); do
    json="$(app_state_json)"
    state="$(jq -r '.state' <<<"$json")"
    [[ "$state" == "$wanted" ]] && return 0
    case "$state" in error|failed) fail "Umbrel app operation failed: $json" ;; esac
    sleep 2; waited=$((waited + 2))
  done
  fail "timed out waiting for Umbrel app state '$wanted'; last response: $json"
}

umbrel_app_install() {
  local state output
  state="$(jq -r .state <<<"$(app_state_json 2>/dev/null || printf '{"state":"not-installed"}')")"
  [[ "$state" == not-installed ]] || return 0
  output="$(umbrel_call apps.install.mutate 2>&1)" ||
    fail "Umbrel app installation failed: $output"
  wait_state ready
}
umbrel_app_start() { local out; out="$(umbrel_call apps.start.mutate 2>&1)" || fail "app start failed: $out"; wait_state ready; }
umbrel_app_stop() {
  local state out
  state="$(jq -r .state <<<"$(app_state_json 2>/dev/null || printf '{"state":"not-installed"}')")"
  [[ "$state" != stopped && "$state" != not-installed ]] || { echo "application already stopped"; return 0; }
  out="$(umbrel_call apps.stop.mutate 2>&1)" || fail "app stop failed: $out"
  wait_state stopped
}
umbrel_app_restart() { local out; out="$(umbrel_call apps.restart.mutate 2>&1)" || fail "app restart failed: $out"; wait_state ready; }

pin_official_app_store() {
  local commit repo
  commit="$(jqv .app_store.commit)"
  repo="$(find /data -xdev -type f -path '*/app-stores/*/.git/config' \
    -exec grep -lF 'github.com/getumbrel/umbrel-apps' {} \; 2>/dev/null |
    sed 's#/.git/config$##' | head -1)"
  [[ -n "$repo" ]] || fail "official Umbrel app-store checkout was not found"
  git -C "$repo" fetch --quiet --depth=1 origin "$commit" ||
    fail "could not fetch the pinned official app-store commit"
  git -C "$repo" checkout --quiet --detach "$commit" ||
    fail "could not select the pinned official app-store commit"
  [[ "$(git -C "$repo" rev-parse HEAD)" == "$commit" ]] ||
    fail "official app-store checkout is not at the pinned commit"
  chown -R 1000:1000 "$repo"
}

container_id() {
  local ids
  ids="$(docker ps -q --filter "label=com.docker.compose.project=$APP_ID" \
    --filter 'label=com.docker.compose.service=app')"
  [[ "$(wc -w <<<"$ids")" == 1 ]] || fail "expected exactly one official Knots app container"
  printf '%s\n' "$ids"
}

actual_knots_pid() {
  local cid="$1"
  docker exec "$cid" sh -ceu '
    found=
    for proc in /proc/[0-9]*; do
      exe=$(readlink -f "$proc/exe" 2>/dev/null || true)
      case "$exe" in */bitcoind)
        [ -z "$found" ] || exit 41
        found=${proc##*/};;
      esac
    done
    [ -n "$found" ] || exit 42
    printf "%s\n" "$found"
  '
}

wait_knots_ready() {
  local waited=0 cid pid
  while (( waited < TIMEOUT )); do
    cid="$(container_id 2>/dev/null || true)"
    if [[ -n "$cid" ]]; then
      pid="$(actual_knots_pid "$cid" 2>/dev/null || true)"
      if [[ -n "$pid" ]] &&
         docker exec "$cid" bitcoin-cli "-datadir=$CONTAINER_DATADIR" \
           "-rpcport=$APP_BITCOIN_KNOTS_RPC_PORT" \
           getblockchaininfo >/dev/null 2>&1; then
        return 0
      fi
    fi
    sleep 2; waited=$((waited + 2))
  done
  [[ -z "${cid:-}" ]] || docker logs --tail 200 "$cid" >&2 || true
  fail "timed out waiting for the official Knots process and RPC to become ready"
}

wait_checkpoint_ready() {
  local waited=0 cid chain indexes
  while (( waited < TIMEOUT )); do
    cid="$(container_id 2>/dev/null || true)"
    if [[ -n "$cid" ]]; then
      chain="$(docker exec "$cid" bitcoin-cli "-datadir=$CONTAINER_DATADIR" \
        "-rpcport=$APP_BITCOIN_KNOTS_RPC_PORT" getblockchaininfo 2>/dev/null || true)"
      indexes="$(docker exec "$cid" bitcoin-cli "-datadir=$CONTAINER_DATADIR" \
        "-rpcport=$APP_BITCOIN_KNOTS_RPC_PORT" getindexinfo 2>/dev/null || true)"
      if jq -e --argjson minimum "$(jq -r .expected_minimum_height "$ACTIVE")" '
          .chain=="main" and .initialblockdownload==false and
          .blocks==.headers and .blocks >= $minimum
        ' <<<"$chain" >/dev/null 2>&1 &&
        jq -e --argjson expected "$(jq '.knots.required_indexes' "$PROFILE")" \
          --argjson height "$(jq -r .blocks <<<"$chain")" '
          . as $actual |
          all($expected[]; . as $name |
            ($actual | has($name)) and $actual[$name].synced==true and
            ($actual[$name].best_block_height // -1) >= $height)
        ' <<<"$indexes" >/dev/null 2>&1; then
        return 0
      fi
    fi
    sleep 10
    waited=$((waited + 10))
  done
  [[ -z "${cid:-}" ]] || docker logs --tail 300 "$cid" >&2 || true
  fail "timed out waiting for Umbrel Knots chain and checkpoint indexes"
}

prepared() {
  local cid pid exe digest args chain
  load_profile; verify_os; resolve_app
  mountpoint -q "$DATADIR" || fail "Knots datadir is not mounted"
  cid="$(container_id)"
  pid="$(actual_knots_pid "$cid")" || fail "actual Knots process not found"
  exe="$(docker exec "$cid" readlink -f "/proc/$pid/exe")"
  [[ "$exe" == "$KNOTS_EXE" ]] || fail "live Knots executable differs from profile"
  digest="$(docker exec "$cid" sha256sum "$KNOTS_EXE" | awk '{print $1}')"
  [[ "$digest" == "$KNOTS_SHA" ]] || fail "live Knots binary digest mismatch"
  args="$(docker exec "$cid" sh -ceu 'tr "\0" "\n" <"/proc/$1/cmdline"' sh "$pid" |
    jq -Rsc 'split("\n")[:-1]')"
  jq -e --arg d "$CONTAINER_DATADIR" 'any(.[];.=="-datadir="+$d)' <<<"$args" >/dev/null ||
    fail "live Knots process does not use the mounted datadir"
  jq -e --argjson active "$(cat "$ACTIVE")" '
    .overlay_id==$active.overlay_id and .canonical_id==$active.canonical_id and
    .checkpoint_generation==$active.checkpoint_generation and
    .filesystem_uuid==$active.filesystem_uuid
  ' "$DATADIR/.bvml-overlay.json" >/dev/null || fail "overlay marker does not match host identity"
  chain="$(docker exec "$cid" bitcoin-cli "-datadir=$CONTAINER_DATADIR" \
    "-rpcport=$APP_BITCOIN_KNOTS_RPC_PORT" getblockchaininfo)"
  jq -n --arg container "$cid" --arg pid "$pid" --arg digest "$digest" \
    --argjson args "$args" --argjson chain "$chain" \
    '{prepared:true,container_id:$container,knots_pid:$pid,
      knots_binary_digest:$digest,observed_args:$args,blockchain:$chain}'
}

validate_device() {
  [[ -f "$ACTIVE" ]] || fail "host-bound active-overlay identity is absent"
  jq -e '.overlay_id|type=="string" and length>0' "$ACTIVE" >/dev/null ||
    fail "active-overlay identity is invalid"
  [[ "$(jq -r .checkpoint_profile_id "$ACTIVE")" == "$(jqv .knots.checkpoint_profile_id)" ]] ||
    fail "overlay checkpoint index profile differs from the pinned Umbrel contract"
  [[ "$(jq -r .checkpoint_profile_sha256 "$ACTIVE")" == "$(jqv .knots.checkpoint_profile_sha256)" ]] ||
    fail "overlay checkpoint profile digest differs from the pinned Umbrel contract"
  local serial expected_serial expected_uuid actual_uuid fstype byid
  expected_serial="$(jq -r .disk_serial "$ACTIVE")"
  expected_uuid="$(jq -r .filesystem_uuid "$ACTIVE")"
  serial="$(udevadm info --query=property --name="$DEVICE" | sed -n 's/^ID_SERIAL=//p' | head -1)"
  [[ "$serial" == "$expected_serial" ]] || fail "wrong /dev/vdc serial '$serial'"
  byid="/dev/disk/by-id/virtio-$expected_serial"
  [[ -L "$byid" && "$(readlink -f "$byid")" == "$(readlink -f "$DEVICE")" ]] ||
    fail "overlay does not resolve through its expected by-id identity"
  [[ "$(blockdev --getsize64 "$DEVICE")" == "$(jq -r .size_bytes "$ACTIVE")" ]] ||
    fail "overlay device size differs from the host manifest"
  actual_uuid="$(blkid -s UUID -o value "$DEVICE")"
  [[ "$actual_uuid" == "$expected_uuid" ]] || fail "wrong /dev/vdc filesystem UUID"
  fstype="$(blkid -s TYPE -o value "$DEVICE")"
  [[ "$fstype" == ext4 ]] || fail "unsupported overlay filesystem '$fstype'"
}

prepare_settings() {
  install -d -o 1000 -g 1000 -m 0750 "$APP_DIR/data/app"
  jq '.knots.required_settings' "$PROFILE" >"$APP_DIR/data/app/settings.json.new"
  chown 1000:1000 "$APP_DIR/data/app/settings.json.new"
  chmod 0600 "$APP_DIR/data/app/settings.json.new"
  mv -f "$APP_DIR/data/app/settings.json.new" "$APP_DIR/data/app/settings.json"
  # This is the only adapter-owned configuration in the disposable overlay.
  printf '# Managed by bitcoin-vm-lab; Umbrel owns umbrel-bitcoin.conf\nblocksxor=0\n' >"$DATADIR/bitcoin.conf"
  chown 1000:1000 "$DATADIR/bitcoin.conf"
  chmod 0640 "$DATADIR/bitcoin.conf"
  find "$DATADIR" -maxdepth 1 -type f \( -name '.cookie' -o -name '*.pid' -o -name '.lock' \) -delete
}

mount_overlay() {
  validate_device
  local source
  if mountpoint -q "$DATADIR"; then
    source="$(findmnt -n -o SOURCE "$DATADIR")"
    [[ "$(readlink -f "$source")" == "$(readlink -f "$DEVICE")" ]] ||
      fail "Knots datadir is mounted from the wrong device"
    return
  fi
  [[ -z "$(findmnt -rn -S "$DEVICE" -o TARGET)" ]] || fail "$DEVICE is mounted elsewhere"
  if [[ -d "$DATADIR" && -n "$(find "$DATADIR" -mindepth 1 -print -quit)" ]]; then
    local quarantine="$APP_DIR/data/native-datadir-quarantine-$(date -u +%Y%m%dT%H%M%SZ)"
    du -sb "$DATADIR" >"$quarantine.size"
    mv "$DATADIR" "$quarantine"
  fi
  install -d -o root -g root -m 0700 "$DATADIR"
  mount -o rw,nodev,nosuid "$DEVICE" "$DATADIR"
  chown 1000:1000 "$DATADIR"
  [[ -d "$DATADIR/blocks" && -d "$DATADIR/chainstate" ]] ||
    fail "mounted checkpoint lacks blocks or chainstate"
  jq -n --argjson active "$(cat "$ACTIVE")" --arg profile "$PROFILE_SHA" \
    '$active + {umbrel_profile_sha256:$profile}' >"$DATADIR/.bvml-overlay.json"
  chown 1000:1000 "$DATADIR/.bvml-overlay.json"
  prepare_settings
}

verify_package() {
  local cid="$1" inspect sidecar_id
  inspect="$(docker inspect "$cid")"
  jq -e --arg image "$IMAGE" --argjson entry "$(jq '.app_store.entrypoint' "$PROFILE")" \
    --argjson command "$(jq '.app_store.command' "$PROFILE")" \
    --arg user "1000:1000" --arg restart "$(jqv .app_store.restart_policy)" \
    --argjson grace "$(jqv .app_store.stop_grace_period_ns)" '
      .[0] | .Config.Image==$image and .Config.Entrypoint==$entry and
      .Config.Cmd==$command and .Config.User==$user and
	      .HostConfig.RestartPolicy.Name==$restart and
	      (.HostConfig.StopTimeout == null or .HostConfig.StopTimeout*1000000000==$grace)
	  ' <<<"$inspect" >/dev/null || fail "live official app contract differs from profile"
  if [[ "$(jq -r '.[0].HostConfig.StopTimeout // "unset"' <<<"$inspect")" == unset ]]; then
    grep -Eq '^[[:space:]]*stop_grace_period:[[:space:]]*15m30s[[:space:]]*$' \
      "$APP_DIR/docker-compose.yml" ||
      fail "Docker omitted StopTimeout and the pinned Compose grace period is absent"
  fi
  jq -e --arg source "$APP_DIR/data" '
    .[0].Mounts | any(.Source==$source and .Destination=="/data" and .RW==true)
  ' <<<"$inspect" >/dev/null || fail "official parent /data bind does not expose the mounted datadir"
  jq -e --arg network "$(jqv .app_store.network_mode)" \
    --argjson ports "$(jq '.app_store.published_ports' "$PROFILE")" '
    .[0] as $container |
    $container.Config.Labels["com.docker.compose.project"]=="bitcoin-knots" and
    $container.Config.Labels["com.docker.compose.service"]=="app" and
    $container.HostConfig.NetworkMode==$network and
    all($ports[]; . as $port |
      ($container.HostConfig.PortBindings[($port|tostring)+"/tcp"]|length)>0)
  ' <<<"$inspect" >/dev/null || fail "official Compose project, network, or published ports differ"
  local sidecar image
  while IFS=$'\t' read -r sidecar image; do
    sidecar_id="$(docker ps -q --filter "label=com.docker.compose.project=$APP_ID" \
      --filter "label=com.docker.compose.service=$sidecar")"
    [[ -n "$sidecar_id" && "$(docker inspect "$sidecar_id" --format '{{.State.Running}}')" == true &&
       "$(docker inspect "$sidecar_id" --format '{{.Config.Image}}')" == "$image" ]] ||
      fail "required pinned $sidecar sidecar is absent or unhealthy"
  done < <(jq -r '[["tor",.app_store.tor_image],["i2pd_daemon",.app_store.i2p_image]][]|@tsv' "$PROFILE")
}

verify_runtime() {
  local cid pid exe args digest uid mount_id_host mount_id_guest version config chain indexes now tip_age logs ppid parent zmq
  cid="$(container_id)"; verify_package "$cid"
  pid="$(actual_knots_pid "$cid")" || fail "actual Knots process not found"
  ppid="$(docker exec "$cid" awk '/^PPid:/ {print $2}' "/proc/$pid/status")"
  parent="$(docker exec "$cid" sh -ceu 'tr "\0" " " <"/proc/$1/cmdline"' sh "$ppid")"
  [[ "$parent" == *node*dist/server.js* ]] ||
    fail "Knots parent is not the pinned official Umbrel backend"
  exe="$(docker exec "$cid" readlink -f "/proc/$pid/exe")"
  [[ "$exe" == "$KNOTS_EXE" ]] || fail "live Knots executable '$exe' differs from profile"
  args="$(docker exec "$cid" sh -ceu 'tr "\0" "\n" <"/proc/$1/cmdline"' sh "$pid" | jq -Rsc 'split("\n")[:-1]')"
  jq -e --arg d "$CONTAINER_DATADIR" '
    any(.[];.=="-datadir="+$d) and
    (any(.[];.=="-chain=main") or (all(.[];. != "-chain=test" and . != "-testnet" and . != "-regtest" and . != "-signet")))
  ' <<<"$args" >/dev/null || fail "live Knots process does not use mainnet and /data/bitcoin"
  jq -e 'all(.[]; (startswith("-reindex") or startswith("-reindex-chainstate"))|not)' \
    <<<"$args" >/dev/null || fail "live Knots unexpectedly requests a reindex"
  digest="$(docker exec "$cid" sha256sum "$KNOTS_EXE" | awk '{print $1}')"
  [[ "$digest" == "$KNOTS_SHA" ]] || fail "live Knots binary digest mismatch"
  local live_schema_sha live_metadata_sha
  live_schema_sha="$(docker exec "$cid" sha256sum /app/libs/settings/dist/settings.schema.js | awk '{print $1}')"
  live_metadata_sha="$(docker exec "$cid" sha256sum /app/libs/settings/dist/settings.meta.js | awk '{print $1}')"
  [[ "$live_schema_sha" == "$(jqv .knots.settings_schema_sha256)" &&
     "$live_metadata_sha" == "$(jqv .knots.settings_metadata_sha256)" ]] ||
    fail "live official settings schema/metadata digest mismatch"
  uid="$(docker exec "$cid" stat -c %u "/proc/$pid")"; [[ "$uid" == 1000 ]] ||
    fail "live Knots UID is '$uid', expected 1000"
  version="$(docker exec "$cid" "$KNOTS_EXE" --version | head -1)"
  [[ "$version" == *"${KNOTS_VERSION#v}"* ]] || fail "live Knots version mismatch"
  config="$(docker exec "$cid" cat "$CONTAINER_DATADIR/umbrel-bitcoin.conf")"
  grep -Eq '^consensusrules=rdts$' <<<"$config" || fail "RDTS is absent from generated configuration"
  docker exec "$cid" grep -Eq '^blocksxor=0$' "$CONTAINER_DATADIR/bitcoin.conf" ||
    fail "blocksxor=0 is absent from base configuration"
  if docker exec "$cid" test -s "$CONTAINER_DATADIR/blocks/xor.dat"; then
    docker exec "$cid" sh -ceu '
      ! od -An -v -tu1 "$1/blocks/xor.dat" | tr -s " " "\n" | sed "/^$/d" | grep -qv "^0$"
    ' sh "$CONTAINER_DATADIR" || fail "block storage is XOR encoded"
  fi
  chain="$(docker exec "$cid" bitcoin-cli "-datadir=$CONTAINER_DATADIR" \
    "-rpcport=$APP_BITCOIN_KNOTS_RPC_PORT" getblockchaininfo)"
  logs="$(docker logs "$cid" 2>&1 | tail -4000)"
  grep -Eqi 'consensusrules.*rdts|Setting.*consensusrules.*rdts' <<<"$logs" ||
    fail "startup logs do not prove the effective RDTS configuration"
  ! grep -Eqi 'Reindexing|Rebuilding chainstate' <<<"$logs" ||
    fail "Knots entered reindex or chainstate rebuild"
  jq -e '.chain=="main" and .initialblockdownload==false and .blocks==.headers' <<<"$chain" >/dev/null ||
    fail "Knots is not fully synchronized on mainnet"
  [[ "$(jq -r .blocks <<<"$chain")" -ge "$(jq -r .expected_minimum_height "$ACTIVE")" ]] ||
    fail "Knots did not open the checkpoint's existing chain height"
  now="$(date +%s)"; tip_age=$((now - $(jq -r .time <<<"$chain")))
  (( tip_age >= 0 && tip_age <= $(jqv .runtime.max_tip_age_seconds) )) ||
    fail "chain tip is too old: ${tip_age}s"
  indexes="$(docker exec "$cid" bitcoin-cli "-datadir=$CONTAINER_DATADIR" \
    "-rpcport=$APP_BITCOIN_KNOTS_RPC_PORT" getindexinfo)"
  jq -e --argjson expected "$(jq '.knots.required_indexes' "$PROFILE")" '
    . as $actual |
    all($expected[]; . as $name |
      ($actual | has($name)) and $actual[$name].synced==true)
  ' <<<"$indexes" >/dev/null || fail "required checkpoint indexes are missing or unsynchronized"
  zmq="$(docker exec "$cid" bitcoin-cli "-datadir=$CONTAINER_DATADIR" \
    "-rpcport=$APP_BITCOIN_KNOTS_RPC_PORT" getzmqnotifications)"
  [[ "$(jq 'map(.type)|unique|length' <<<"$zmq")" -ge 5 ]] ||
    fail "required Umbrel ZMQ publishers are not active"
  docker exec "$cid" node -e \
    'fetch("http://127.0.0.1:3000/api/widget/sync").then(r=>{if(!r.ok)process.exit(2);return r.text()}).then(()=>process.exit(0)).catch(()=>process.exit(3))' ||
    fail "official Umbrel UI backend does not report node state"
  jq -e --argjson active "$(cat "$ACTIVE")" '
    .overlay_id==$active.overlay_id and .canonical_id==$active.canonical_id and
    .checkpoint_generation==$active.checkpoint_generation and
    .filesystem_uuid==$active.filesystem_uuid
  ' "$DATADIR/.bvml-overlay.json" >/dev/null || fail "overlay marker does not match host lifecycle identity"
  mount_id_host="$(stat -f -c %i "$DATADIR")"
  mount_id_guest="$(docker exec "$cid" stat -f -c %i "$CONTAINER_DATADIR")"
  [[ -n "$mount_id_host" && "$mount_id_host" == "$mount_id_guest" ]] ||
    fail "container /data/bitcoin is not the same mounted filesystem"
  [[ -z "$(find "$APP_DIR" -xdev -type d \( -name blocks -o -name chainstate \) \
    ! -path "$DATADIR/*" ! -path '*/native-datadir-quarantine-*/*' -print -quit)" ]] ||
    fail "a competing Bitcoin datadir exists on the Umbrel system disk"
  jq -n --arg platform umbrel --arg os "$OS_VERSION" --arg package "$APP_VERSION" \
    --arg profile "$PROFILE_SHA" --arg binary "$digest" \
	    --arg implementation "$(jqv .adapter_implementation_version)" \
	    --arg now "$(date -u +%FT%TZ)" --arg cid "$cid" --arg pid "$pid" \
	    --arg parent "$parent" \
    --argjson args "$args" --argjson chain "$chain" --argjson indexes "$indexes" \
    --argjson overlay "$(cat "$ACTIVE")" \
    '{platform:$platform,os_version:$os,package_version:$package,
	      profile_digest:$profile,knots_binary_digest:$binary,
	      adapter_implementation_version:$implementation,provisioning_result:"ok",
	      last_validation_result:"ok",
      validated_at:$now,container_id:$cid,knots_pid:$pid,knots_parent:$parent,observed_args:$args,
      blockchain:$chain,indexes:$indexes,overlay:$overlay,rdts_validated:true}' >"$EVIDENCE"
  chmod 0600 "$EVIDENCE"
}

setup() {
  load_profile; verify_os; resolve_app
  umbrel_app_stop
  mount_overlay
  umbrel_app_start
  wait_knots_ready
  wait_checkpoint_ready
  verify_runtime
}

verify() {
  load_profile; verify_os; resolve_app
  mountpoint -q "$DATADIR" || fail "Knots datadir is not mounted"
  wait_checkpoint_ready
  verify_runtime
  umbrel_app_restart
  wait_knots_ready
  wait_checkpoint_ready
  verify_runtime
}

stop() {
  load_profile; verify_os; resolve_app
  if ! mountpoint -q "$DATADIR"; then
    umbrel_app_stop
    chmod 0700 "$DATADIR" 2>/dev/null || true
    echo "application already stopped; overlay already unmounted"
    return 0
  fi
  umbrel_app_stop
  [[ -z "$(docker ps -q --filter "label=com.docker.compose.project=$APP_ID" \
    --filter 'label=com.docker.compose.service=app')" ]] || fail "Knots app container remains running"
  ! pgrep -af bitcoind | grep -F "$DATADIR" >/dev/null || fail "Knots process remains"
  if command -v fuser >/dev/null; then
    [[ -z "$(fuser -m "$DATADIR" 2>/dev/null || true)" ]] ||
      fail "Knots datadir filesystem is still held by a process"
  else
    fail "fuser is required to prove that the datadir filesystem is idle"
  fi
  sync -f "$DATADIR"
  umount "$DATADIR" || fail "clean unmount failed; overlay remains mounted for recovery"
  chown root:root "$DATADIR"; chmod 0700 "$DATADIR"
  echo "application stopped successfully; overlay unmounted"
}

install_app() {
  load_profile; verify_os
  need git
  pin_official_app_store
  umbrel_app_install
  resolve_app
  umbrel_app_stop
  local repo_digests
  repo_digests="$(docker image inspect "$IMAGE" --format '{{json .RepoDigests}}')" ||
    fail "pinned official Knots image is not installed"
  jq -e --arg digest "$(jqv .app_store.image_index_digest)" '
    any(.[]; endswith("@"+$digest))' <<<"$repo_digests" >/dev/null ||
    fail "installed Knots image digest differs from the profile"
  if [[ -d "$DATADIR" && -n "$(find "$DATADIR" -mindepth 1 -print -quit)" ]]; then
    local quarantine="$APP_DIR/data/native-datadir-quarantine-$(date -u +%Y%m%dT%H%M%SZ)"
    du -sb "$DATADIR" >"$quarantine.size"
    mv "$DATADIR" "$quarantine"
  fi
  install -d -o root -g root -m 0700 "$DATADIR"
  jq -n --arg profile "$PROFILE_SHA" --arg commit "$(jqv .app_store.commit)" \
    --arg root "$UMBREL_ROOT" --arg app "$APP_DIR" \
    --arg datadir "$DATADIR" --arg now "$(date -u +%FT%TZ)" \
    '{profile_digest:$profile,source_commit:$commit,umbrel_root:$root,
      app_dir:$app,datadir:$datadir,provisioned_at:$now}' \
    >"$BVML_STATE/etc/umbrel-provisioned.json"
}

case "${1:-status}" in
  install-app) install_app ;;
  setup) setup ;;
  prepared) prepared ;;
  verify|status) verify ;;
  restart) load_profile; verify_os; resolve_app; umbrel_app_restart; wait_knots_ready; wait_checkpoint_ready; verify_runtime ;;
  stop) stop ;;
  *) fail "usage: $0 {install-app|setup|verify|restart|stop|status}" ;;
esac
