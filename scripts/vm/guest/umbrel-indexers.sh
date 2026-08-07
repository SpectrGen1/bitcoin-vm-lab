#!/usr/bin/env bash
# Native Umbrel lifecycle integration for the official Electrs and Fulcrum apps.
set -Eeuo pipefail

BVML=/home/umbrel/umbrel/.bvml
PROFILE=$BVML/etc/indexers.json
PROFILE_SHA_FILE=$BVML/etc/indexers.sha256
ACTIVE=$BVML/etc/active-indexes.json
EVIDENCE=$BVML/etc/indexers-verification.json
UMBREL_ROOT=/home/umbrel/umbrel
TIMEOUT="${UMBREL_OPERATION_TIMEOUT:-1800}"

fail() { echo "error: $*" >&2; exit 1; }
service_ok() { [[ "${1:-}" =~ ^(electrs|fulcrum)$ ]] || fail "invalid index service"; }
pget() { jq -er --arg s "$1" "$2" "$PROFILE"; }
device_for() { case "$1" in electrs) echo /dev/vdd;; fulcrum) echo /dev/vde;; esac; }

load_profile() {
  local check_files=("$PROFILE" "$PROFILE_SHA_FILE")
  [[ -f "$PROFILE" && -f "$PROFILE_SHA_FILE" ]] ||
    fail "Umbrel index profile is absent"
  # ACTIVE is created by host index-adapter-setup; install-apps may run first.
  [[ -f "$ACTIVE" ]] && check_files+=("$ACTIVE")
  [[ "$(stat -c %u "$PROFILE")" == 0 &&
     -z "$(find "${check_files[@]}" -maxdepth 0 -perm /022 -print -quit)" ]] ||
    fail "Umbrel index profile/state ownership is unsafe"
  PROFILE_SHA="$(tr -d '[:space:]' <"$PROFILE_SHA_FILE")"
  [[ "$PROFILE_SHA" =~ ^[0-9a-f]{64}$ &&
     "$(sha256sum "$PROFILE" | awk '{print $1}')" == "$PROFILE_SHA" ]] ||
    fail "Umbrel index profile digest mismatch"
}

app_id() { pget "$1" '.[$s].umbrel.app_id'; }
app_dir() { printf '%s/app-data/%s\n' "$UMBREL_ROOT" "$(app_id "$1")"; }
data_dir() { printf '%s/%s\n' "$UMBREL_ROOT" "$(pget "$1" '.[$s].umbrel.host_data_suffix')"; }
container_data() { pget "$1" '.[$s].umbrel.container_data'; }

app_call() {
  local service="$1" route="$2"; shift 2
  umbreld client "$route" --appId "$(app_id "$service")" "$@"
}
app_state() {
  local service="$1" output
  output="$(app_call "$service" apps.state.query 2>&1)" ||
    fail "$service state query failed: $output"
  jq -er 'if has("state") then .state elif (.data|type)=="object" then .data.state else empty end' <<<"$output"
}
wait_state() {
  local service="$1" wanted="$2" waited=0 state
  while ((waited < TIMEOUT)); do
    state="$(app_state "$service" 2>/dev/null || echo unknown)"
    [[ "$state" == "$wanted" ]] && return
    [[ "$state" != error && "$state" != failed ]] || fail "$service entered state $state"
    sleep 2; waited=$((waited+2))
  done
  fail "$service timed out waiting for Umbrel state $wanted (last=$state)"
}
# bitcoin-knots implements the official "bitcoin" dependency contract. Electrs
# and Fulcrum declare dependencies: [bitcoin]; without an explicit alternative
# umbreld writes settings.yml as bitcoin: bitcoin and compose cannot source
# APP_BITCOIN_* exports from the Knots app.
bitcoin_dependency_alternative() {
  printf '%s\n' 'bitcoin:bitcoin-knots'
}

app_install() {
  local service="$1" state out
  state="$(app_state "$service" 2>/dev/null || echo not-installed)"
  if [[ "$state" == not-installed ]]; then
    # umbreld CLI accepts --alternatives as a JSON object (parsed via JSON.parse).
    out="$(app_call "$service" apps.install.mutate \
      --alternatives '{"bitcoin":"bitcoin-knots"}' 2>&1)" ||
      fail "$service install failed: $out"
    # Treat a literal false / non-true JSON result as failure; umbreld can exit 0
    # after logging install errors while leaving state not-installed.
    if [[ "$out" == "false" || "$out" == *"error"* ]]; then
      fail "$service install failed: $out"
    fi
    wait_state "$service" ready
  elif [[ "$state" == ready || "$state" == stopped ]]; then
    # Ensure partial installs (or prior runs without alternatives) map bitcoin ->
    # bitcoin-knots so exports and compose bind to Knots, not a missing bitcoin app.
    local settings
    settings="$(app_dir "$service")/settings.yml"
    if [[ -f "$settings" ]] &&
       ! grep -Eq '^[[:space:]]*bitcoin:[[:space:]]*bitcoin-knots[[:space:]]*$' "$settings"; then
      out="$(app_call "$service" apps.setSelectedDependencies.mutate \
        --dependencies '{"bitcoin":"bitcoin-knots"}' 2>&1)" ||
        fail "$service dependency selection failed: $out"
    fi
  fi
}
app_stop() {
  local service="$1" state out
  state="$(app_state "$service" 2>/dev/null || echo not-installed)"
  case "$state" in stopped|not-installed) echo "$service already stopped"; return;; esac
  out="$(app_call "$service" apps.stop.mutate 2>&1)" || fail "$service stop failed: $out"
  wait_state "$service" stopped
}
app_start() {
  local service="$1" out
  out="$(app_call "$service" apps.start.mutate 2>&1)" || fail "$service start failed: $out"
  wait_state "$service" ready
}
app_restart() {
  local service="$1" out
  out="$(app_call "$service" apps.restart.mutate 2>&1)" || fail "$service restart failed: $out"
  wait_state "$service" ready
}

package_file_digest() {
  local service="$1" key="$2" fileset="${3:-files}"
  jq -er --arg s "$service" --arg k "$key" --arg fileset "$fileset" '
    .[$s].umbrel[$fileset][$k] // .[$s].umbrel.files[$k]
  ' "$PROFILE"
}

verify_package() {
  local service="$1" dir key expected actual fileset
  dir="$(app_dir "$service")"
  [[ -d "$dir" ]] || fail "$service official app is not installed"
  # Prefer post-install installed_files digests when the profile records a
  # BVML-safe transformation (same pattern as bitcoin-knots).
  if jq -e --arg s "$service" '.[$s].umbrel.installed_files|type=="object"' \
       "$PROFILE" >/dev/null 2>&1; then
    fileset=installed_files
  else
    fileset=files
  fi
  while IFS=$'\t' read -r key expected; do
    actual="$(sha256sum "$dir/$key" | awk '{print $1}')" ||
      fail "$service installed package lacks $key"
    [[ "$actual" == "$expected" ]] || fail "$service official package drift: $key"
  done < <(jq -r --arg s "$service" --arg fileset "$fileset" '
    .[$s].umbrel[$fileset] // .[$s].umbrel.files | to_entries[] | [.key,.value] | @tsv
  ' "$PROFILE")
  grep -Eq "^version:[[:space:]]*[\"']?$(pget "$service" '.[$s].umbrel.app_version')[\"']?[[:space:]]*$" \
    "$dir/umbrel-app.yml" || fail "$service app version differs from profile"
}

# Official Fulcrum pre-start deletes the data directory once when migrating
# from 1.x. That is catastrophic for a mounted reusable base, so replace the
# wipe with a mountpoint/overlay-aware no-op while preserving Tor setup.
protect_fulcrum_pre_start() {
  local dir hook current official protected
  dir="$(app_dir fulcrum)"; hook="$dir/hooks/pre-start"
  [[ -f "$hook" ]] || fail "Fulcrum official pre-start hook is absent"
  official="$(package_file_digest fulcrum hooks/pre-start files)"
  protected="$(jq -er '.fulcrum.umbrel.installed_files["hooks/pre-start"]' "$PROFILE")"
  current="$(sha256sum "$hook" | awk '{print $1}')"
  [[ "$current" == "$protected" ]] && {
    touch "$dir/POST_2_0_VERSION"
    return
  }
  # Accept store digest or the umbreld post-install rewrite (scripts/app ->
  # legacy-compat/app-script path substitution). Both still contain the 1.x
  # data wipe that must be neutralized for reusable index bases.
  if [[ "$current" != "$official" ]] &&
     ! grep -Fq 'Pre-2.0 data detected, clearing' "$hook"; then
    fail "Fulcrum pre-start is neither the official nor the protected transformation"
  fi
  cat >"$hook" <<'EOF'
#!/usr/bin/env bash
# bitcoin-vm-lab protected Fulcrum pre-start: never wipe a mounted index overlay.
set -euo pipefail

POST_UPDATE_HOOK="${APP_DATA_DIR}/hooks/post-update"
if [[ -e "${POST_UPDATE_HOOK}" ]]; then
  rm -f -- "${POST_UPDATE_HOOK}" || true
fi

if [[ ! -d "${APP_DATA_DIR}/data/fulcrum-logs" ]]; then
  mkdir -p "${APP_DATA_DIR}/data/fulcrum-logs"
  chown 1000:1000 "${APP_DATA_DIR}/data/fulcrum-logs"
fi

FULCRUM_DATA_DIR="${APP_DATA_DIR}/data/fulcrum"
POST_2_0_FLAG="${APP_DATA_DIR}/POST_2_0_VERSION"
mkdir -p "${FULCRUM_DATA_DIR}"

if [[ ! -f "${POST_2_0_FLAG}" ]]; then
  if mountpoint -q "${FULCRUM_DATA_DIR}" ||
     [[ -f "${FULCRUM_DATA_DIR}/.bvml-index-overlay.json" ]]; then
    echo "App: ${APP_ID} - preserving mounted BVML Fulcrum index overlay"
  elif [[ -n "$(find "${FULCRUM_DATA_DIR}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    echo "App: ${APP_ID} - Pre-2.0 data detected, clearing '${FULCRUM_DATA_DIR}' once"
    find "${FULCRUM_DATA_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  fi
  touch "${POST_2_0_FLAG}"
fi

HIDDEN_SERVICE_FILE="${TOR_DATA_DIR}/app-${APP_ID}-rpc/hostname"
if [[ -f "${HIDDEN_SERVICE_FILE}" ]]; then
  exit 0
fi

"${UMBREL_ROOT}/scripts/app" compose "${APP_ID}" up --detach fulcrum
"${UMBREL_ROOT}/scripts/app" compose "${APP_ID}" up --detach tor
echo "App: ${APP_ID} - Generating Tor Hidden Service..."
for attempt in $(seq 1 100); do
  if [[ -f "${HIDDEN_SERVICE_FILE}" ]]; then
    echo "App: ${APP_ID} - Hidden service file created successfully!"
    break
  fi
  sleep 0.1
done
if [[ ! -f "${HIDDEN_SERVICE_FILE}" ]]; then
  echo "App: ${APP_ID} - Hidden service file wasn't created"
fi
EOF
  chown root:root "$hook"; chmod 0755 "$hook"
  current="$(sha256sum "$hook" | awk '{print $1}')"
  [[ "$current" == "$protected" ]] ||
    fail "protected Fulcrum pre-start digest mismatch (got $current)"
  # Migration flag always present after protection so later official upgrades
  # cannot re-arm the wipe against an attached overlay.
  touch "$dir/POST_2_0_VERSION"
  chown 1000:1000 "$dir/POST_2_0_VERSION" 2>/dev/null || true
}

identify_device() {
  local service="$1" serial byid expected_size uuid expected_uuid
  DEVICE="$(device_for "$service")"; serial="$(jq -er --arg s "$service" '.services[$s].disk_serial' "$ACTIVE")"
  expected_size="$(jq -er --arg s "$service" '.services[$s].size_bytes' "$ACTIVE")"
  expected_uuid="$(jq -er --arg s "$service" '.services[$s].filesystem_uuid' "$ACTIVE")"
  byid="/dev/disk/by-id/virtio-$serial"
  [[ -b "$DEVICE" && -b "$byid" &&
     "$(readlink -f "$DEVICE")" == "$(readlink -f "$byid")" &&
     "$(lsblk -dn -o SERIAL "$DEVICE" | sed 's/[[:space:]]*$//')" == "$serial" &&
     "$(blockdev --getsize64 "$DEVICE")" == "$expected_size" ]] ||
    fail "$service overlay disk identity is wrong or ambiguous"
  uuid="$(blkid -s UUID -o value "$DEVICE")"
  [[ "$uuid" == "$expected_uuid" && "$(blkid -s TYPE -o value "$DEVICE")" == btrfs ]] ||
    fail "$service overlay filesystem identity is wrong"
}

index_db_on_mount() {
  local service="$1" target="$2" layout rel
  layout="$(jq -r --arg s "$service" '.[$s].database_layout // empty' "$PROFILE")"
  if [[ -z "$layout" || "$layout" == null ]]; then
    rel="$(pget "$service" '.[$s].umbrel.database')"
    layout="${rel#/data/}"
    layout="${layout#/}"
  fi
  printf '%s/%s\n' "$target" "$layout"
}

assert_existing_index_db() {
  local service="$1" target="$2" db
  db="$(index_db_on_mount "$service" "$target")"
  [[ -d "$db" && -n "$(find "$db" -mindepth 1 -print -quit)" ]] ||
    fail "$service mounted overlay lacks reusable database at $db"
  printf '%s\n' "$db"
}

mount_data() {
  local service="$1" target native source db
  identify_device "$service"; target="$(data_dir "$service")"
  if mountpoint -q "$target"; then
    source="$(findmnt -rn -o SOURCE -T "$target")"
    [[ "$(readlink -f "$source")" == "$(readlink -f "$DEVICE")" ]] ||
      fail "$service existing mount uses another disk"
    assert_existing_index_db "$service" "$target" >/dev/null
    return
  fi
  [[ -z "$(findmnt -rn -S "$DEVICE" -o TARGET)" ]] || fail "$service disk is mounted elsewhere"
  if [[ -d "$target" && -n "$(find "$target" -mindepth 1 -print -quit)" ]]; then
    native="$(app_dir "$service")/data/native-index-quarantine-$(date -u +%Y%m%dT%H%M%SZ)"
    du -sb "$target" >"$native.size"
    mv "$target" "$native"
  fi
  install -d -o root -g root -m 0700 "$target"
  mount -o rw,nodev,nosuid "$DEVICE" "$target"
  chown 1000:1000 "$target"
  db="$(assert_existing_index_db "$service" "$target")"
  jq --arg service "$service" --arg profile "$PROFILE_SHA" --arg database "$db" \
    '.services[$service] + {service:$service,umbrel_index_profile_sha256:$profile,
      database_path:$database,reused_existing_database:true}' \
    "$ACTIVE" >"$target/.bvml-index-overlay.json"
  chown 1000:1000 "$target/.bvml-index-overlay.json"
}

service_container() {
  local service="$1" ids
  ids="$(docker ps -q --filter "label=com.docker.compose.project=$(app_id "$service")" \
    --filter "label=com.docker.compose.service=$(pget "$service" '.[$s].umbrel.service')")"
  [[ "$(wc -w <<<"$ids")" == 1 ]] || fail "$service official service container is not unique"
  printf '%s\n' "$ids"
}

actual_process() {
  local service="$1" cid="$2" name
  name="$(if [[ "$service" == electrs ]]; then echo electrs; else echo Fulcrum; fi)"
  docker exec "$cid" sh -ceu '
    found=
    for p in /proc/[0-9]*; do
      exe=$(readlink -f "$p/exe" 2>/dev/null || true)
      [ "${exe##*/}" = "$1" ] || continue
      [ -z "$found" ] || exit 41
      found=${p##*/}
    done
    [ -n "$found" ] || exit 42
    printf "%s\n" "$found"
  ' sh "$name"
}

electrum_height() {
  local port="$1"
  python3 - "$port" <<'PY'
import json,socket,sys
s=socket.create_connection(("127.0.0.1",int(sys.argv[1])),10)
s.sendall(b'{"jsonrpc":"2.0","id":1,"method":"blockchain.headers.subscribe","params":[]}\n')
print(json.loads(s.makefile("rb").readline())["result"]["height"])
PY
}

verify_runtime() {
  local service="$1" cid pid exe digest expected image target cdata inspect height node_height port marker
  # umbreld rewrites hooks/pre-start paths on each start/restart; re-apply the
  # BVML-safe Fulcrum pre-start before package digest verification.
  [[ "$service" != fulcrum ]] || protect_fulcrum_pre_start
  verify_package "$service"; identify_device "$service"; target="$(data_dir "$service")"
  mountpoint -q "$target" || fail "$service data directory is not a mountpoint"
  cid="$(service_container "$service")"; inspect="$(docker inspect "$cid")"
  image="$(pget "$service" '.[$s].umbrel.image')"
  jq -e --arg image "$image" --arg source "$target" --arg dest "$(container_data "$service")" '
    .[0].Config.Image==$image and
    (. [0].Mounts | any(.Source==$source and .Destination==$dest and .RW==true)) and
    .[0].Config.Labels["com.docker.compose.project"] != null
  ' <<<"$inspect" >/dev/null || fail "$service live container image or production mount differs"
  pid="$(actual_process "$service" "$cid")"
  exe="$(docker exec "$cid" readlink -f "/proc/$pid/exe")"
  digest="$(docker exec "$cid" sha256sum "$exe" | awk '{print $1}')"
  expected="$(jq -r --arg s "$service" '.services[$s].binary_sha256 // empty' "$ACTIVE")"
  [[ -z "$expected" || "$digest" == "$expected" ]] ||
    fail "$service live binary digest differs from the protected base"
  local guest_fs host_fs
  guest_fs="$(docker exec "$cid" stat -f -c %i "$(container_data "$service")")"
  host_fs="$(stat -f -c %i "$target")"
  [[ -n "$guest_fs" && "$guest_fs" == "$host_fs" ]] ||
    fail "$service container does not see the overlay filesystem"
  if [[ "$service" == electrs ]]; then port=50001; else port=50002; fi
  height="$(electrum_height "$port" 2>/dev/null || true)"
  [[ "$height" =~ ^[0-9]+$ ]] ||
    fail "$service Electrum RPC is not ready on port $port"
  local knots_cid base_height db knots_rpc_port
  knots_cid="$(docker ps -q --filter label=com.docker.compose.project=bitcoin-knots \
    --filter label=com.docker.compose.service=app)"
  [[ "$(wc -w <<<"$knots_cid")" == 1 ]] ||
    fail "Umbrel bitcoin-knots service container is not unique"
  # Knots listens on 9332 (not Core's 8332). Prefer live exports, then default.
  knots_rpc_port="${APP_BITCOIN_KNOTS_RPC_PORT:-${APP_BITCOIN_RPC_PORT:-9332}}"
  [[ "$knots_rpc_port" =~ ^[0-9]+$ ]] || knots_rpc_port=9332
  node_height="$(docker exec "$knots_cid" bitcoin-cli \
    -datadir=/data/bitcoin -rpcport="$knots_rpc_port" getblockcount 2>/dev/null || true)"
  [[ "$node_height" =~ ^[0-9]+$ ]] ||
    fail "Umbrel Knots RPC did not return a block height (rpcport=$knots_rpc_port)"
  if ! (( node_height - height >= 0 && node_height - height <= 1 )); then
    fail "$service is not synchronized with Umbrel Knots (index=$height knots=$node_height)"
  fi
  db="$(assert_existing_index_db "$service" "$target")"
  base_height="$(jq -r --arg s "$service" \
    '.services[$s].base_tip_height // empty' "$ACTIVE" 2>/dev/null || true)"
  if [[ "$base_height" =~ ^[0-9]+$ ]]; then
    if ! (( height + 2 >= base_height )); then
      fail "$service height $height is below protected base tip $base_height (reindex suspected)"
    fi
  else
    if ! (( height > 100000 )); then
      fail "$service height $height is too low to prove Umbrel base reuse"
    fi
  fi
  marker="$(cat "$target/.bvml-index-overlay.json")"
  jq -e --arg service "$service" --argjson active "$(cat "$ACTIVE")" '
    .service==$service and .id==$active.services[$service].id and
    .bitcoin_canonical_id==$active.services[$service].bitcoin_canonical_id and
    .bitcoin_checkpoint_generation==$active.services[$service].bitcoin_checkpoint_generation
  ' <<<"$marker" >/dev/null || fail "$service overlay marker differs from host lifecycle"
  jq -n --arg service "$service" --arg container "$cid" --arg pid "$pid" \
    --arg executable "$exe" --arg binary_sha256 "$digest" --arg image "$image" \
    --arg filesystem_uuid "$(blkid -s UUID -o value "$DEVICE")" \
    --arg database_path "$db" --argjson height "$height" \
    --argjson node_height "$node_height" --arg verified "$(date -u +%FT%TZ)" \
    '{service:$service,container:$container,pid:$pid,executable:$executable,
      binary_sha256:$binary_sha256,image:$image,filesystem_uuid:$filesystem_uuid,
      database_path:$database_path,height:$height,node_height:$node_height,
      reused_existing_database:true,synchronized:true,verified_at:$verified}'
}

setup_one() {
  local service="$1"
  jq -e --arg s "$service" '.services[$s]|type=="object"' "$ACTIVE" >/dev/null ||
    fail "$service is not present in the active index lifecycle identity"
  app_stop "$service"
  # Protect Fulcrum pre-start before package verification so umbreld's post-start
  # path rewrite cannot fail digest checks against installed_files.
  [[ "$service" != fulcrum ]] || protect_fulcrum_pre_start
  verify_package "$service"
  mount_data "$service"
  # Re-arm the official migration flag after mount so pre-start cannot wipe
  # the attached reusable base even if the package is later replaced.
  [[ "$service" != fulcrum ]] || touch "$(app_dir fulcrum)/POST_2_0_VERSION"
  app_start "$service"
  local waited=0
  # Run verify in a subshell so fail()/exit only aborts the attempt, not the
  # whole setup script — indexers need time after start for Electrum RPC.
  while ! ( verify_runtime "$service" >"/tmp/$service-verification.json" \
              2>/tmp/"$service-verification.err" ); do
    if ! (( waited < TIMEOUT )); then
      cat /tmp/"$service-verification.err" >&2
      fail "$service did not become ready"
    fi
    sleep 10; waited=$((waited+10))
  done
  app_restart "$service"
  waited=0
  while ! ( verify_runtime "$service" >"/tmp/$service-verification.json" \
              2>/tmp/"$service-verification.err" ); do
    if ! (( waited < TIMEOUT )); then
      cat /tmp/"$service-verification.err" >&2
      fail "$service did not stay ready after restart"
    fi
    sleep 10; waited=$((waited+10))
  done
}

stop_one() {
  local service="$1" target
  app_stop "$service"; target="$(data_dir "$service")"
  [[ -z "$(docker ps -q --filter "label=com.docker.compose.project=$(app_id "$service")")" ]] ||
    fail "$service containers remain after native stop"
  if mountpoint -q "$target"; then
    sync -f "$target"
    ! fuser -m "$target" >/dev/null 2>&1 || fail "$service mount remains busy"
    umount "$target" || fail "$service overlay unmount failed"
  fi
  chown root:root "$target"; chmod 0700 "$target"
}

install_apps() {
  load_profile
  local service
  for service in electrs fulcrum; do
    app_install "$service"
    app_stop "$service"
    if [[ "$service" == fulcrum ]]; then
      protect_fulcrum_pre_start
    fi
    verify_package "$service"
  done
}

active_services() {
  jq -r '.services // {} | keys[]' "$ACTIVE"
}

setup_all() {
  load_profile
  [[ -f "$ACTIVE" ]] || fail "active index lifecycle identity is absent"
  local service evidence_files=()
  while read -r service; do
    [[ -n "$service" ]] || continue
    setup_one "$service"
    evidence_files+=("/tmp/$service-verification.json")
  done < <(active_services)
  ((${#evidence_files[@]} > 0)) || fail "no active Umbrel index services were staged"
  jq -s --arg platform umbrel --arg profile "$PROFILE_SHA" \
    '{platform:$platform,profile_digest:$profile,last_validation_result:"ok",
      validated_at:(now|todate),services:(map({key:.service,value:.})|from_entries)}' \
    "${evidence_files[@]}" >"$EVIDENCE"
}
verify_all() {
  load_profile
  [[ -f "$ACTIVE" ]] || fail "active index lifecycle identity is absent"
  local service tmp=()
  while read -r service; do
    [[ -n "$service" ]] || continue
    verify_runtime "$service" >"/tmp/$service-verification.json"
    tmp+=("/tmp/$service-verification.json")
  done < <(active_services)
  ((${#tmp[@]} > 0)) || fail "no active Umbrel index services were staged"
  jq -s --arg platform umbrel --arg profile "$PROFILE_SHA" \
    '{platform:$platform,profile_digest:$profile,last_validation_result:"ok",
      validated_at:(now|todate),services:(map({key:.service,value:.})|from_entries)}' \
    "${tmp[@]}" >"$EVIDENCE"
  cat "$EVIDENCE"
}
stop_all() {
  [[ -f "$PROFILE" ]] || { echo "index applications already stopped: adapter absent"; return; }
  load_profile
  # Stop Fulcrum before Electrs so dependency teardown is deterministic.
  local service
  for service in fulcrum electrs; do
    if [[ -d "$(app_dir "$service")" ]]; then
      stop_one "$service"
    fi
  done
}

case "${1:-}" in
  install-apps) install_apps ;;
  setup) setup_all ;;
  verify) verify_all ;;
  stop) stop_all ;;
  *) fail "usage: $0 {install-apps|setup|verify|stop}" ;;
esac
