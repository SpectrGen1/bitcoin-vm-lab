#!/usr/bin/env bash
# Ubuntu producer/consumer integration for pinned Electrs and Fulcrum images.
set -Eeuo pipefail

PROFILE=/etc/bvml/indexers.json
ACTIVE=/etc/bvml/active-indexes.json
BITCOIN=/srv/bitcoin
STATE=/var/lib/bvml-indexers

fail() { echo "error: $*" >&2; exit 1; }
service_ok() { [[ "${1:-}" =~ ^(electrs|fulcrum)$ ]] || fail "service must be electrs or fulcrum"; }
device_for() { case "$1" in electrs) echo /dev/vdd;; fulcrum) echo /dev/vde;; esac; }
mount_for() { printf '/srv/%s\n' "$1"; }
unit_for() { printf 'bvml-%s.service\n' "$1"; }
container_for() { printf 'bvml-%s\n' "$1"; }
profile_get() { jq -er --arg s "$1" "$2" "$PROFILE"; }

safe_profile() {
  [[ -f "$PROFILE" && "$(stat -c %u "$PROFILE")" == 0 &&
     -z "$(find "$PROFILE" -maxdepth 0 -perm /022 -print -quit)" ]] ||
    fail "index profile is missing or unsafe"
  jq -e '.profile_version == 1 and .filesystems.base == "btrfs"' "$PROFILE" >/dev/null ||
    fail "unsupported index profile"
}

active_get() {
  local service="$1" expression="$2"
  jq -er --arg service "$service" ".services[\$service]$expression" "$ACTIVE"
}

identify_device() {
  local service="$1" device serial byid expected_size actual_size
  service_ok "$service"; [[ -f "$ACTIVE" ]] || fail "host index identity is absent"
  device="$(device_for "$service")"
  serial="$(active_get "$service" .disk_serial)"
  expected_size="$(active_get "$service" .size_bytes)"
  [[ "$serial" =~ ^BVML[EF]-[A-Za-z0-9-]{8,16}$ ]] || fail "$service serial is malformed"
  byid="/dev/disk/by-id/virtio-$serial"
  [[ -b "$device" && -b "$byid" &&
     "$(readlink -f "$device")" == "$(readlink -f "$byid")" ]] ||
    fail "$service disk does not have its expected unambiguous by-id identity"
  [[ "$(lsblk -dn -o SERIAL "$device" | sed 's/[[:space:]]*$//')" == "$serial" ]] ||
    fail "$service disk serial mismatch"
  actual_size="$(blockdev --getsize64 "$device")"
  [[ "$actual_size" == "$expected_size" ]] || fail "$service disk size mismatch"
  DEVICE="$device"
}

stage() {
  safe_profile
  [[ $# == 2 ]] || fail "stage requires service and host identity JSON"
  local service="$1"; service_ok "$service"
  jq -e --arg service "$service" '
    .services[$service] |
    (.id|type=="string" and length>15) and
    (.disk_serial|type=="string" and length>12) and
    ((.kind=="bootstrap" and (.nonce|type=="string" and length>15)) or
      (.kind=="overlay" and (.filesystem_uuid|type=="string" and length>15))) and
    (.size_bytes|type=="number" and .>0) and
    (.bitcoin_canonical_id|type=="string" and length>0) and
    (.bitcoin_checkpoint_generation|type=="string" and length>0)
  ' <<<"$2" >/dev/null || fail "host index identity is incomplete"
  install -d -o root -g root -m 0700 /etc/bvml
  local tmp; tmp="$(mktemp /etc/bvml/active-indexes.json.XXXXXX)"
  if [[ -f "$ACTIVE" ]] && jq -e '.services|type=="object"' "$ACTIVE" >/dev/null 2>&1; then
    jq -s '.[0] * .[1]' "$ACTIVE" <(printf '%s\n' "$2") >"$tmp"
  else
    printf '%s\n' "$2" >"$tmp"
  fi
  mv "$tmp" "$ACTIVE"
  chown root:root "$ACTIVE"; chmod 0600 "$ACTIVE"
  identify_device "$service"
}

init_filesystem() {
  safe_profile
  [[ "${1:-}" =~ ^(electrs|fulcrum)$ &&
     "${2:-}" == --confirm-index-format && $# == 2 ]] ||
    fail "usage: init SERVICE --confirm-index-format"
  local service="$1" signatures children mounts uuid target marker
  identify_device "$service"
  [[ "$(active_get "$service" .kind)" == bootstrap ]] ||
    fail "only an explicit bootstrap image may be formatted"
  [[ -n "$(active_get "$service" .nonce)" ]] || fail "bootstrap nonce is absent"
  children="$(lsblk -nrpo NAME "$DEVICE" | tail -n +2)"
  [[ -z "$children" ]] || fail "$service disk has child partitions or mappings"
  mounts="$(lsblk -nrpo MOUNTPOINTS "$DEVICE" | sed '/^[[:space:]]*$/d')"
  [[ -z "$mounts" ]] || fail "$service disk is mounted"
  signatures="$(wipefs -n "$DEVICE" 2>&1)" || fail "wipefs could not inspect $service disk"
  [[ -z "$signatures" ]] || fail "$service disk has a recognized signature"
  set +e
  signatures="$(blkid -p "$DEVICE" 2>&1)"; local probe=$?
  set -e
  [[ "$probe" == 2 && -z "$signatures" ]] ||
    fail "blkid did not prove the $service disk empty"
  mkfs.btrfs -L "BVML_${service^^}" "$DEVICE"
  uuid="$(blkid -s UUID -o value "$DEVICE")"; [[ -n "$uuid" ]] || fail "filesystem UUID unavailable"
  target="$(mount_for "$service")"; install -d -o root -g root -m 0750 "$target"
  mount "$DEVICE" "$target"
  install -d -o 1000 -g 1000 -m 0750 "$target/.bvml"
  marker="$target/.bvml/base-identity.json"
  jq --arg service "$service" --arg uuid "$uuid" \
    '.services[$service] + {service:$service,filesystem_uuid:$uuid}' "$ACTIVE" >"$marker"
  chown -R 1000:1000 "$target"; sync -f "$target"; umount "$target"
  echo "initialized $service bootstrap filesystem UUID=$uuid"
}

expected_mount() {
  local service="$1" target expected actual source
  identify_device "$service"; target="$(mount_for "$service")"
  expected="$(active_get "$service" .filesystem_uuid)"
  actual="$(blkid -s UUID -o value "$DEVICE")"
  [[ -n "$expected" && "$actual" == "$expected" ]] || fail "$service filesystem UUID mismatch"
  [[ "$(blkid -s TYPE -o value "$DEVICE")" == btrfs ]] || fail "$service filesystem is not Btrfs"
  if ! mountpoint -q "$target"; then
    install -d -o root -g root -m 0750 "$target"
    mount "$DEVICE" "$target"
  fi
  chown 1000:1000 "$target"; chmod 0750 "$target"
  source="$(findmnt -rn -o SOURCE -T "$target")"
  [[ "$(readlink -f "$source")" == "$(readlink -f "$DEVICE")" ]] ||
    fail "$service mount is backed by another disk"
}

verify_image() {
  local service="$1" image expected digest
  install -d -o root -g root -m 0750 "$STATE"
  image="$(profile_get "$service" '.[$s].ubuntu.image')"
  expected="${image##*@}"
  docker pull "$image" >/dev/null
  docker image inspect "$image" |
    jq -e --arg digest "$expected" '.[0].RepoDigests | any(endswith("@"+$digest))' >/dev/null ||
    fail "$service image digest does not match the pinned profile"
  digest="$(docker run --rm --entrypoint sha256sum "$image" \
    "$(profile_get "$service" '.[$s].ubuntu.binary')" | awk '{print $1}')"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || fail "$service binary digest could not be measured"
  printf '%s\n' "$digest" >"$STATE/$service-binary.sha256"
}

install_unit() {
  local service="$1" image target unit container
  service_ok "$service"; safe_profile; need_docker
  expected_mount "$service"; verify_image "$service"
  target="$(mount_for "$service")"; unit="$(unit_for "$service")"
  container="$(container_for "$service")"; image="$(profile_get "$service" '.[$s].ubuntu.image')"
  install -d -o root -g root -m 0750 "$STATE"
  if [[ "$service" == electrs ]]; then
    cat >"/etc/systemd/system/$unit" <<EOF
[Unit]
Description=BVML pinned Electrs
Requires=bvml-knots.service
After=bvml-knots.service docker.service
RequiresMountsFor=$BITCOIN $target
ConditionPathIsMountPoint=$BITCOIN
ConditionPathIsMountPoint=$target
[Service]
ExecStartPre=-/usr/bin/docker rm -f $container
ExecStart=/usr/bin/docker run --rm --name $container --network host \
  -e ELECTRS_LOG_FILTERS=INFO -e ELECTRS_NETWORK=bitcoin \
  -e ELECTRS_DAEMON_RPC_ADDR=127.0.0.1:8332 \
  -e ELECTRS_DAEMON_P2P_ADDR=127.0.0.1:8333 \
  -e ELECTRS_ELECTRUM_RPC_ADDR=127.0.0.1:50001 \
  -e ELECTRS_COOKIE_FILE=/data/.bitcoin/.cookie \
  -e ELECTRS_DB_DIR=/data/db \
  -v $BITCOIN:/data/.bitcoin:ro -v $target:/data:rw $image
ExecStop=/usr/bin/docker stop --time 300 $container
TimeoutStopSec=330
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
  else
    cat >"$target/fulcrum.conf" <<EOF
datadir = /data
bitcoind = 127.0.0.1:8332
rpccookie = /bitcoin/.cookie
tcp = 127.0.0.1:50002
admin = 127.0.0.1:8000
peering = false
announce = false
# Lab-tuned for mainnet indexing on a 32GiB / multi-vCPU Ubuntu VM.
db_mem = 8192
worker_threads = 8
bitcoind_clients = 8
bitcoind_timeout = 600
EOF
    chown 1000:1000 "$target/fulcrum.conf"
    cat >"/etc/systemd/system/$unit" <<EOF
[Unit]
Description=BVML pinned Fulcrum
Requires=bvml-knots.service
After=bvml-knots.service docker.service
RequiresMountsFor=$BITCOIN $target
ConditionPathIsMountPoint=$BITCOIN
ConditionPathIsMountPoint=$target
[Service]
ExecStartPre=-/usr/bin/docker rm -f $container
ExecStart=/usr/bin/docker run --rm --name $container --network host --user 1000:1000 \
  -v $BITCOIN:/bitcoin:ro -v $target:/data:rw $image \
  Fulcrum --ts-format none /data/fulcrum.conf
ExecStop=/usr/bin/docker stop --time 300 $container
TimeoutStopSec=330
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
  fi
  systemctl daemon-reload
  systemctl enable "$unit"
}

need_docker() {
  command -v docker >/dev/null || fail "Docker is not installed; run guest-provision ubuntu"
  systemctl is-active --quiet docker || systemctl start docker
}

electrum_height() {
  local port="$1"
  # Electrs may bind RPC early but stall replies during post-sync RocksDB
  # compaction; retry with a longer per-attempt timeout.
  python3 - "$port" <<'PY'
import json, socket, sys, time
port = int(sys.argv[1])
last = None
for attempt in range(36):  # up to ~6 minutes
    try:
        s = socket.create_connection(("127.0.0.1", port), 20)
        s.settimeout(20)
        s.sendall(b'{"jsonrpc":"2.0","id":1,"method":"blockchain.headers.subscribe","params":[]}\n')
        line = s.makefile("rb").readline()
        obj = json.loads(line)
        print(obj["result"]["height"])
        raise SystemExit(0)
    except Exception as exc:
        last = exc
        time.sleep(10)
raise SystemExit(f"electrum height unavailable on port {port}: {last}")
PY
}

index_database_path() {
  local service="$1" root="$2" layout
  layout="$(jq -r --arg s "$service" '.[$s].database_layout // empty' "$PROFILE")"
  if [[ -z "$layout" || "$layout" == null ]]; then
    case "$service" in
      electrs) layout=db/bitcoin ;;
      fulcrum) layout=fulc2_db ;;
    esac
  fi
  printf '%s/%s\n' "$root" "$layout"
}

assert_database_present() {
  local service="$1" target="$2" db
  db="$(index_database_path "$service" "$target")"
  [[ -d "$db" && -n "$(find "$db" -mindepth 1 -print -quit)" ]] ||
    fail "$service database is absent at $db"
  printf '%s\n' "$db"
}

# Consumer overlays must already contain a non-empty database before start so
# the indexer extends the protected base instead of rebuilding from genesis.
require_existing_database_for_overlay() {
  local service="$1" target db kind
  kind="$(active_get "$service" .kind)"
  [[ "$kind" == overlay ]] || return 0
  target="$(mount_for "$service")"
  db="$(assert_database_present "$service" "$target")"
  echo "$service consumer overlay already contains database at $db"
}

start_service() {
  local service="$1"; install_unit "$service"
  require_existing_database_for_overlay "$service"
  systemctl restart "$(unit_for "$service")"
  local waited=0 container; container="$(container_for "$service")"
  while [[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" != true ]]; do
    ((waited++ < 60)) || fail "$service container did not start"
    sleep 1
  done
  echo "$service started from its pinned image on the attached writable disk"
}

verify_service() {
  local service="$1" port image container target height node_height digest expected_digest db
  local kind base_height reused=false startup_height=-1
  service_ok "$service"; safe_profile; expected_mount "$service"
  container="$(container_for "$service")"; target="$(mount_for "$service")"
  [[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" == true ]] ||
    fail "$service container is not running"
  image="$(profile_get "$service" '.[$s].ubuntu.image')"
  [[ "$(docker inspect -f '{{.Config.Image}}' "$container")" == "$image" ]] ||
    fail "$service running image differs from the profile"
  digest="$(docker exec "$container" sha256sum \
    "$(profile_get "$service" '.[$s].ubuntu.binary')" | awk '{print $1}')"
  expected_digest="$(<"$STATE/$service-binary.sha256")"
  [[ "$digest" == "$expected_digest" ]] || fail "$service live binary digest changed"
  if [[ "$service" == electrs ]]; then port=50001
  else port=50002
  fi
  # Allow a small tip lag and brief catch-up: Knots may advance while the
  # indexer opens an existing database or finishes a short gap fill.
  local attempt
  height=0; node_height=0
  for attempt in $(seq 1 30); do
    height="$(electrum_height "$port")"
    node_height="$(bitcoin-cli -conf=/etc/bvml/bitcoin.conf getblockcount)"
    if (( node_height - height >= 0 && node_height - height <= 6 )); then
      break
    fi
    sleep 10
  done
  (( node_height - height >= 0 && node_height - height <= 6 )) ||
    fail "$service height $height is not synchronized with Bitcoin $node_height"
  db="$(assert_database_present "$service" "$target")"
  kind="$(active_get "$service" .kind)"
  base_height="$(jq -r --arg s "$service" \
    '.services[$s].base_tip_height // empty' "$ACTIVE" 2>/dev/null || true)"
  if [[ "$kind" == overlay ]]; then
    reused=true
    # Consumer must be extending the promoted base tip, not reindexing genesis.
    if [[ "$base_height" =~ ^[0-9]+$ ]]; then
      (( height + 2 >= base_height )) ||
        fail "$service consumer height $height is below protected base tip $base_height"
    else
      (( height > 100000 )) ||
        fail "$service consumer height $height is too low to prove base reuse"
    fi
  fi
  jq -n --arg service "$service" --arg image "$image" \
    --arg binary_sha256 "$digest" --argjson height "$height" \
    --arg filesystem_uuid "$(blkid -s UUID -o value "$DEVICE")" \
    --arg id "$(active_get "$service" .id)" \
    --arg canonical "$(active_get "$service" .bitcoin_canonical_id)" \
    --arg generation "$(active_get "$service" .bitcoin_checkpoint_generation)" \
    --arg database_path "$db" --arg kind "$kind" \
    --argjson reused "$reused" --argjson node_height "$node_height" \
    --arg verified "$(date -u +%FT%TZ)" \
    '{service:$service,image:$image,binary_sha256:$binary_sha256,height:$height,
      node_height:$node_height,filesystem_uuid:$filesystem_uuid,index_id:$id,
      bitcoin_canonical_id:$canonical,bitcoin_checkpoint_generation:$generation,
      database_path:$database_path,kind:$kind,reused_existing_database:$reused,
      synchronized:true,verified_at:$verified}' \
    >"$STATE/$service-verification.json"
  cat "$STATE/$service-verification.json"
}

stop_service() {
  local service="$1" unit target
  service_ok "$service"; unit="$(unit_for "$service")"; target="$(mount_for "$service")"
  if systemctl list-unit-files --no-legend "$unit" 2>/dev/null | grep -q "^$unit"; then
    systemctl stop "$unit" || fail "$service exists but failed to stop"
  fi
  docker inspect "$(container_for "$service")" >/dev/null 2>&1 &&
    fail "$service container remains after stop"
  if mountpoint -q "$target"; then
    sync -f "$target"
    ! fuser -m "$target" >/dev/null 2>&1 || fail "$service data mount is busy"
    umount "$target" || fail "$service data mount could not be unmounted"
  fi
  echo "$service stopped cleanly and unmounted"
}

verify_stop() {
  local service="$1"; verify_service "$service"; stop_service "$service"
  jq '. + {clean_shutdown:true,shutdown_at:now|todate}' \
    "$STATE/$service-verification.json" >"$STATE/$service-verification.json.new"
  mv "$STATE/$service-verification.json.new" "$STATE/$service-verification.json"
  cat "$STATE/$service-verification.json"
}

status() {
  local service="$1"; service_ok "$service"
  jq -n --arg service "$service" \
    --arg unit "$(systemctl is-active "$(unit_for "$service")" 2>/dev/null || true)" \
    --arg mounted "$(mountpoint -q "$(mount_for "$service")" && echo yes || echo no)" \
    --arg container "$(docker inspect -f '{{.State.Status}}' "$(container_for "$service")" 2>/dev/null || echo absent)" \
    '{service:$service,unit:$unit,mounted:$mounted,container:$container}'
}

case "${1:-}" in
  stage) shift; stage "$@" ;;
  init) shift; init_filesystem "$@" ;;
  install) shift; install_unit "$@" ;;
  start) shift; start_service "$@" ;;
  verify) shift; verify_service "$@" ;;
  verify-stop) shift; verify_stop "$@" ;;
  stop) shift; stop_service "$@" ;;
  status) shift; status "$@" ;;
  *) fail "usage: $0 {stage|init|install|start|verify|verify-stop|stop|status} SERVICE" ;;
esac
