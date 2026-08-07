#!/usr/bin/env bash
# Native StartOS consumer adapter. start-cli is the only package controller.
set -Eeuo pipefail

STATE=/media/startos/data/main/bvml
PROFILE=$STATE/startos-profile.json
PROFILE_DIGEST_FILE=$STATE/startos-profile.sha256
ACTIVE=$STATE/active-overlay.json
PROVISIONED=$STATE/startos-provisioned.json
VERIFICATION=$STATE/adapter-verification.json
SEED=$STATE/startos-main-seed
PRIVATE_MOUNT=/media/bvml-startos-overlay

fail() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || fail "missing command: $1"; }
jqv() { jq -er "$1" "$PROFILE"; }

load_profile() {
  need jq; need sha256sum; need start-cli; need findmnt; need lsblk; need blkid
  [[ -f "$PROFILE" && -f "$PROFILE_DIGEST_FILE" ]] || fail "pinned StartOS profile is absent"
  [[ "$(stat -c %u "$PROFILE")" == 0 && "$(stat -c %u "$PROFILE_DIGEST_FILE")" == 0 ]] ||
    fail "StartOS profile files must be root-owned"
  [[ -z "$(find "$PROFILE" "$PROFILE_DIGEST_FILE" -maxdepth 0 -perm /022 -print -quit)" ]] ||
    fail "StartOS profile files must not be group/world writable"
  PROFILE_DIGEST="$(tr -d '[:space:]' <"$PROFILE_DIGEST_FILE")"
  [[ "$PROFILE_DIGEST" =~ ^[0-9a-f]{64}$ &&
     "$(sha256sum "$PROFILE" | awk '{print $1}')" == "$PROFILE_DIGEST" ]] ||
    fail "StartOS profile digest mismatch"
  jq -e '
    (.profile_id|type=="string" and length>0)
    and (.os.release|type=="string" and length>0)
    and (.registry.package_id=="bitcoind")
    and .registry.package_version=="#knots:29.3.1:16"
    and (.registry.release_sha256|test("^[0-9a-f]{64}$"))
    and (.package.knots_binary_sha256|test("^[0-9a-f]{64}$"))
    and .package.lxc_volume_mount=="/media/startos/volumes/main"
    and .package.subcontainer=="bitcoind-sub"
    and .package.subcontainer_datadir=="/root/.bitcoin"
    and .checkpoint.network=="signet"
    and .checkpoint.blocksxor==0
    and .checkpoint.prune==0
    and (.checkpoint.required_indexes|type=="array")
  ' "$PROFILE" >/dev/null || fail "StartOS profile is incomplete or unsupported"
  PACKAGE_ID="$(jqv .registry.package_id)"
  PACKAGE_VERSION="$(jqv .registry.package_version)"
  LXC_VOLUME="$(jqv .package.lxc_volume_mount)"
  SUBCONTAINER="$(jqv .package.subcontainer)"
  DATADIR="$(jqv .package.subcontainer_datadir)"
  EXPECTED_EXE="$(jqv .package.knots_executable)"
}

verify_os() {
  local release git_info expected
  expected="$(jqv .os.release)"
  [[ -r /etc/os-release ]] || fail "StartOS OS identity is unavailable"
  release="$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")"
  [[ "$(. /etc/os-release; printf '%s' "${ID:-}")" == start-os ]] ||
    fail "guest OS identity is not StartOS"
  git_info="$(start-cli git-info 2>/dev/null || true)"
  [[ "$release" == "$expected" ]] || fail "StartOS release '$release' does not match '$expected'"
  [[ "$git_info" == "$(jqv .os.installed_git_info)" ]] ||
    fail "installed StartOS build does not match the pinned OS build"
  STARTOS_RELEASE="$expected"
  STARTOS_GIT_INFO="$git_info"
}

installed_version() {
  local out
  out="$(start-cli package installed-version "$PACKAGE_ID" --format json 2>/dev/null || true)"
  if [[ -n "$out" ]]; then
    jq -er 'if type=="string" then . else tostring end' <<<"$out"
    return
  fi
  out="$(start-cli db dump -p --format json 2>/dev/null || true)"
  [[ -n "$out" ]] || return 1
  jq -er --arg id "$PACKAGE_ID" '
    .value.public.packageData[$id].stateInfo.manifest.version |
    select(type=="string" and length>0)
  ' <<<"$out"
}

# StartOS 0.4: package list status is install-state ("installed"), not runtime.
# Runtime desired state is packageData[].statusInfo.desired.main. Subcontainer
# attach must use -n <name>; interactive attach hangs with multi-sub packages.
package_desired_state() {
  local out desired status
  out="$(start-cli db dump -p --format json 2>/dev/null || true)"
  if [[ -n "$out" ]]; then
    desired="$(jq -r --arg id "$PACKAGE_ID" \
      '.value.public.packageData[$id].statusInfo.desired.main // empty' \
      <<<"$out" 2>/dev/null || true)"
    case "$desired" in
      running|starting|restarting) printf 'running\n'; return;;
      stopped|stopping) printf 'stopped\n'; return;;
      "") ;;
      *) printf '%s\n' "$desired"; return;;
    esac
    if jq -e --arg id "$PACKAGE_ID" \
         '.value.public.packageData[$id]|type=="object"' \
         <<<"$out" >/dev/null 2>&1; then
      printf 'stopped\n'; return
    fi
  fi
  # Fallback for older list-based runtime reporting.
  status="$(start-cli package list --format json 2>/dev/null |
    jq -er --arg id "$PACKAGE_ID" '
      [.[] | select(.id==$id)] |
      if length==1 then .[0].status else empty end
    ')" || return
  case "$status" in
    installed | stopped) printf 'stopped\n' ;;
    running | starting | restarting) printf 'running\n' ;;
    *) printf '%s\n' "$status" ;;
  esac
}

package_stopped() {
  ! sub_exec \
    sh -c 'for p in /proc/[0-9]*; do
      [ "$(readlink -f "$p/exe" 2>/dev/null)" = "$1" ] && exit 0
    done
    exit 1' sh "$EXPECTED_EXE" >/dev/null 2>&1
}

installed_developer_key() {
  local out path
  for path in /package-data/"$PACKAGE_ID"/developer-key \
    /packageData/"$PACKAGE_ID"/developerKey; do
    out="$(start-cli db dump -p --format json "$path" 2>/dev/null || true)"
    [[ -n "$out" ]] || continue
    jq -er 'select(type=="string" and length>0)' <<<"$out" && return
  done
  out="$(start-cli db dump -p --format json 2>/dev/null || true)"
  [[ -n "$out" ]] || return 1
  jq -er --arg id "$PACKAGE_ID" '
    .value.public.packageData[$id].developerKey |
    select(type=="string" and length>0)
  ' <<<"$out"
}

wait_package_stopped() {
  local waited=0
  while ! package_stopped; do
    (( waited < 360 )) || fail "native StartOS package did not stop"
    sleep 2; waited=$((waited+2))
  done
}

wait_package_running() {
  local waited=0
  while :; do
    if sub_exec \
      sh -c 'for p in /proc/[0-9]*; do [ "$(readlink -f "$p/exe" 2>/dev/null)" = /opt/bitcoin/bin/bitcoind ] && exit 0; done; exit 1' \
      >/dev/null 2>&1; then return 0; fi
    (( waited < 900 )) || {
      start-cli package logs "$PACKAGE_ID" -l 300 >&2 || true
      fail "official bitcoind-sub did not become ready"
    }
    sleep 3; waited=$((waited+3))
  done
}

knots_start_ticks() {
  sub_exec sh -ceu '
    for p in /proc/[0-9]*; do
      if [ "$(readlink -f "$p/exe" 2>/dev/null)" = /opt/bitcoin/bin/bitcoind ]; then
        awk "{print \$22}" "$p/stat"
        exit
      fi
    done
    exit 1
  '
}

restart_package_observed() {
  local before after output status waited=0
  before="$(knots_start_ticks)"
  set +e
  output="$(start-cli package restart "$PACKAGE_ID" 2>&1)"
  status=$?
  set -e
  while :; do
    after="$(knots_start_ticks 2>/dev/null || true)"
    [[ -n "$after" && "$after" != "$before" ]] && break
    (( waited < 900 )) || fail "native StartOS restart did not replace the Knots process: $output"
    sleep 3
    waited=$((waited+3))
  done
  (( status == 0 )) ||
    echo "native restart returned exit $status but the Knots process generation changed" >&2
  wait_package_running
}

resolve_lxc_volume() {
  need lxc-info
  local stats rootfs target source_spec source_dev fsroot base waited=0
  while :; do
    stats="$(start-cli package stats --format json 2>/dev/null || true)"
    jq -e --arg id "$PACKAGE_ID" '.[$id] | type=="object"' \
      <<<"$stats" >/dev/null 2>&1 && break
    (( waited < 180 )) ||
      fail "machine-readable StartOS package LXC state is unavailable"
    sleep 2
    waited=$((waited+2))
  done
  LXC_NAME="$(jq -er --arg id "$PACKAGE_ID" '
    .[$id] |
    (.container_id // .containerId) |
    select(type=="string" and length>0)
  ' <<<"$stats")" ||
    fail "StartOS did not report a unique LXC identity for bitcoind"
  [[ "$LXC_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || fail "StartOS returned an unsafe LXC identity"
  LXC_CONFIG="/var/lib/lxc/$LXC_NAME/config"
  [[ -f "$LXC_CONFIG" ]] || fail "pinned StartOS LXC configuration is missing"
  rootfs="$(awk -F'[[:space:]]*=[[:space:]]*' '
    $1=="lxc.rootfs.path" {sub(/^dir:/, "", $2); print $2}
  ' "$LXC_CONFIG")"
  [[ "$rootfs" == "/var/lib/lxc/$LXC_NAME/rootfs" && -d "$rootfs" ]] ||
    fail "StartOS LXC rootfs layout differs from the pinned release"
  target="$rootfs$LXC_VOLUME"
  [[ -d "$target" ]] &&
    findmnt -rn -o TARGET -T "$target" | grep -Fxq "$target" ||
    fail "StartOS package LXC main volume is not a distinct mounted filesystem"
  source_spec="$(findmnt -rn -o SOURCE -T "$target" | head -1)"
  fsroot="$(findmnt -rn -o FSROOT -T "$target" | head -1)"
  source_dev="${source_spec%%[*}"
  base="$(findmnt -rn -S "$source_dev" -o TARGET,FSROOT |
    awk '$2=="/" {print $1; exit}')"
  [[ -n "$base" && "$fsroot" == /* ]] ||
    fail "could not map the LXC main-volume mount back to its host filesystem"
  LXC_VOLUME_SOURCE="$(readlink -f -- "$base/${fsroot#/}")"
  [[ "$LXC_VOLUME_SOURCE" == /* && -d "$LXC_VOLUME_SOURCE" ]] ||
    fail "could not resolve the native bitcoind main-volume source"
  if mountpoint -q "$LXC_VOLUME_SOURCE"; then
    [[ -f "$PROVISIONED" ]] &&
      jq -e --arg source "$LXC_VOLUME_SOURCE" --arg profile "$PROFILE_DIGEST" \
        '.native_volume_source==$source and .profile_digest==$profile' \
        "$PROVISIONED" >/dev/null ||
      fail "mounted StartOS volume source is not bound to the provisioned native volume"
  else
    [[ "$(findmnt -rn -o FSTYPE -T "$target" | head -1)" == "$(findmnt -rn -o FSTYPE -T "$LXC_VOLUME_SOURCE" | head -1)" ]] ||
      fail "native StartOS volume source and LXC target filesystem disagree"
  fi
  [[ "$(lxc-info -n "$LXC_NAME" -sH 2>/dev/null || true)" =~ ^(STOPPED|RUNNING)$ ]] ||
    fail "resolved LXC identity is not observable"
}

capture_seed() {
  resolve_lxc_volume
  package_stopped || fail "bitcoind package must be stopped before capturing its seed"
  [[ "$(package_desired_state)" == stopped ]] ||
    fail "bitcoind package desired state is not stopped"
  install -d -o root -g root -m 0700 "$SEED"
  local file
  for file in bitcoin.conf store.json; do
    [[ -f "$LXC_VOLUME_SOURCE/$file" ]] ||
      fail "native StartOS volume lacks required seed $file"
    install -o root -g root -m 0600 "$LXC_VOLUME_SOURCE/$file" "$SEED/$file"
  done
  [[ ! -e "$LXC_VOLUME_SOURCE/blocks" && ! -e "$LXC_VOLUME_SOURCE/chainstate" &&
     ! -e "$LXC_VOLUME_SOURCE/signet/blocks" && ! -e "$LXC_VOLUME_SOURCE/signet/chainstate" ]] ||
    fail "native StartOS seed unexpectedly contains blockchain data"
  local native_bytes
  native_bytes="$(du -sx -B1 "$LXC_VOLUME_SOURCE" | awk '{print $1}')"
  jq -n --arg source "$LXC_VOLUME_SOURCE" --arg lxc "$LXC_NAME" \
    --arg profile "$PROFILE_DIGEST" --arg package "$PACKAGE_VERSION" \
    --arg captured "$(date -u +%FT%TZ)" --argjson native_bytes "$native_bytes" \
    '{native_volume_source:$source,lxc_name:$lxc,profile_digest:$profile,
      package_version:$package,native_volume_bytes:$native_bytes,
      seed_captured_at:$captured}' >"$PROVISIONED"
  chmod 0600 "$PROVISIONED"
}

device_for_active_overlay() {
  [[ -f "$ACTIVE" ]] || fail "active StartOS overlay identity is absent"
  local serial byid size candidates=()
  serial="$(jq -er .disk_serial "$ACTIVE")"
  size="$(jq -er '.size_bytes|select(type=="number")' "$ACTIVE")"
  while IFS= read -r byid; do
    [[ -e "$byid" ]] || continue
    [[ "$(lsblk -bndo SIZE "$(readlink -f "$byid")")" == "$size" ]] || continue
    candidates+=("$(readlink -f "$byid")")
  done < <(find /dev/disk/by-id -maxdepth 1 -type l -name "*${serial}*" -print 2>/dev/null)
  ((${#candidates[@]} == 1)) || fail "StartOS overlay serial '$serial' is missing or ambiguous"
  DEVICE="${candidates[0]}"
  [[ "$(lsblk -ndo TYPE "$DEVICE")" == disk ]] || fail "overlay identity is not a whole disk"
  [[ "$(lsblk -nrpo NAME "$DEVICE" | wc -l)" == 1 ]] || fail "overlay unexpectedly has child partitions"
}

verify_overlay_identity() {
  device_for_active_overlay
  local uuid expected_uuid fstype
  uuid="$(blkid -s UUID -o value "$DEVICE")"
  expected_uuid="$(jq -er .filesystem_uuid "$ACTIVE")"
  fstype="$(blkid -s TYPE -o value "$DEVICE")"
  [[ "$uuid" == "$expected_uuid" ]] || fail "StartOS overlay filesystem UUID mismatch"
  [[ "$fstype" == btrfs ]] || fail "StartOS overlay filesystem type '$fstype' is unsupported"
  jq -e '
    [.overlay_id,.canonical_id,.checkpoint_generation,.disk_serial,
     .filesystem_uuid,.startos_profile_sha256] |
    all(type=="string" and length>0)
  ' "$ACTIVE" >/dev/null || fail "active StartOS lifecycle identity is incomplete"
  [[ "$(jq -r .startos_profile_sha256 "$ACTIVE")" == "$PROFILE_DIGEST" ]] ||
    fail "active lifecycle uses another StartOS adapter generation"
}

mount_overlay() {
  resolve_lxc_volume; verify_overlay_identity
  package_stopped || fail "bitcoind package must be stopped before replacing its volume"
  [[ "$(package_desired_state)" == stopped ]] ||
    fail "bitcoind package desired state is not stopped"
  local expected_uuid lxc_pid
  expected_uuid="$(jq -r .filesystem_uuid "$ACTIVE")"
  lxc_pid="$(lxc-info -n "$LXC_NAME" -pH)"
  [[ "$lxc_pid" =~ ^[1-9][0-9]*$ && -e "/proc/$lxc_pid/ns/user" ]] ||
    fail "official StartOS package LXC user namespace is unavailable"
  if mountpoint -q "$LXC_VOLUME_SOURCE"; then
    [[ "$(findmnt -rn -o UUID -T "$PRIVATE_MOUNT" | tail -1)" == "$expected_uuid" &&
       "$(findmnt -rn -o UUID -T "$LXC_VOLUME_SOURCE" | tail -1)" == "$expected_uuid" &&
       "$(findmnt -rn -o UUID -T "/var/lib/lxc/$LXC_NAME/rootfs$LXC_VOLUME" | tail -1)" == "$expected_uuid" ]] ||
      fail "an existing StartOS volume replacement does not match the active overlay"
    if findmnt -rn -o OPTIONS -T "$LXC_VOLUME_SOURCE" | tail -1 | grep -qw idmapped; then
      return
    fi
    ! lsof +f -- "$LXC_VOLUME_SOURCE" >/dev/null 2>&1 ||
      fail "non-idmapped StartOS overlay bind is busy and cannot be repaired"
    umount "$LXC_VOLUME_SOURCE" ||
      fail "could not remove the non-idmapped StartOS overlay bind"
  fi
  install -d -o root -g root -m 0700 "$PRIVATE_MOUNT"
  mountpoint -q "$PRIVATE_MOUNT" || mount -o rw,nodev,nosuid "$DEVICE" "$PRIVATE_MOUNT"
  [[ "$(findmnt -rn -o UUID -T "$PRIVATE_MOUNT" | tail -1)" == "$expected_uuid" ]] ||
    fail "private StartOS overlay mount has the wrong filesystem"
  mount --bind --map-users "/proc/$lxc_pid/ns/user" \
    "$PRIVATE_MOUNT" "$LXC_VOLUME_SOURCE"
  findmnt -rn -o OPTIONS -T "$LXC_VOLUME_SOURCE" | tail -1 | grep -qw idmapped ||
    fail "StartOS overlay bind did not retain the package LXC user mapping"
  [[ "$(findmnt -rn -o UUID -T "$LXC_VOLUME_SOURCE" | tail -1)" == "$expected_uuid" ]] ||
    fail "managed StartOS volume is not backed by the overlay"
  [[ "$(findmnt -rn -o UUID -T "/var/lib/lxc/$LXC_NAME/rootfs$LXC_VOLUME" | tail -1)" \
     == "$expected_uuid" ]] ||
    fail "overlay mount did not propagate into the pinned StartOS package LXC"
}

merge_config() {
  local conf="$PRIVATE_MOUNT/bitcoin.conf" store="$PRIVATE_MOUNT/store.json"
  install -d -o root -g root -m 0700 "$PRIVATE_MOUNT/.bvml-diagnostics"
  [[ ! -f "$conf" ]] ||
    cp -a -- "$conf" "$PRIVATE_MOUNT/.bvml-diagnostics/ubuntu-bitcoin.conf.$(date -u +%s)"
  install -m 0600 "$SEED/bitcoin.conf" "$conf"
  install -m 0600 "$SEED/store.json" "$store"
  find "$LXC_VOLUME_SOURCE" -maxdepth 1 -type f \
    \( -name '.cookie' -o -name '*.pid' -o -name '.lock' \) -delete
  sed -i -E '/^[[:space:]]*(blocksxor|prune|reindex|reindex-chainstate|txindex|chain|signet|testnet|regtest)[[:space:]]*=/d' "$conf"
  printf '\n# bitcoin-vm-lab consumer contract\nchain=signet\nblocksxor=0\nprune=0\n' >>"$conf"
  if jq -e '.checkpoint.required_indexes | index("txindex") != null' "$PROFILE" >/dev/null; then
    printf 'txindex=1\n' >>"$conf"
  else
    printf 'txindex=0\n' >>"$conf"
  fi
  jq '.reindexBlockchain=false | .reindexChainstate=false' "$store" >"$store.new"
  mv -f -- "$store.new" "$store"
  jq -n --arg lifecycle "$(jq -r .lifecycle_id "$ACTIVE")" \
    --arg overlay "$(jq -r .overlay_id "$ACTIVE")" \
    --arg canonical "$(jq -r .canonical_id "$ACTIVE")" \
    --arg generation "$(jq -r .checkpoint_generation "$ACTIVE")" \
    --arg uuid "$(jq -r .filesystem_uuid "$ACTIVE")" \
    --arg profile "$PROFILE_DIGEST" \
    '{lifecycle_id:$lifecycle,overlay_id:$overlay,canonical_id:$canonical,
      checkpoint_generation:$generation,filesystem_uuid:$uuid,
      startos_profile_generation:$profile}' >"$PRIVATE_MOUNT/.bvml-overlay.json"
  chown --reference="$SEED/bitcoin.conf" "$conf"
  chown --reference="$SEED/store.json" "$store"
}

activate_rdts() {
  local out input event_id
  input="$(start-cli package action get-input "$PACKAGE_ID" \
    "$(jqv .package.rdts_action)" --format json)" ||
    fail "native RDTS action input discovery failed"
  event_id="$(jq -er '
    .eventId as $event |
    .spec.acknowledge.type=="toggle" and
    (.value|type=="object") |
    $event | select(type=="string" and length>0)
  ' <<<"$input")" || fail "native RDTS action schema differs from the pinned package"
  out="$(printf '%s\n' '{"acknowledge":true}' |
    start-cli package action run "$PACKAGE_ID" "$(jqv .package.rdts_action)" \
      --event-id "$event_id" --format json 2>&1)" ||
    fail "native RDTS action failed: $out"
  grep -Eq 'success|complete|acknowledge|finished|^$' <<<"$out" ||
    fail "native RDTS action returned an unrecognized result: $out"
}

verify_native_nocow_contract() {
  local probe="$PRIVATE_MOUNT/.bvml-startos-nocow-probe" output
  rm -rf -- "$probe"
  mkdir -m 0700 "$probe"
  if ! output="$(chattr +C "$probe" 2>&1)"; then
    install -d -m 0700 "$PRIVATE_MOUNT/.bvml-diagnostics"
    printf '%s\n' "$output" >"$PRIVATE_MOUNT/.bvml-diagnostics/nocow-incompatible.txt"
    rm -rf -- "$probe"
    fail "official StartOS package requires chattr +C, which the checkpoint filesystem does not support"
  fi
  lsattr -d "$probe" | awk '{print $1}' | grep -q C ||
    fail "checkpoint filesystem did not retain the required NOCOW attribute"
  chattr -C "$probe"
  rmdir "$probe"
}

sub_exec() {
  start-cli package attach "$PACKAGE_ID" -n "$SUBCONTAINER" -- "$@"
}

runtime_json() {
  local raw pid digest version filesystem_id args_b64 args
  raw="$(sub_exec sh -ceu '
    found=
    for p in /proc/[0-9]*; do
      [ "$(readlink -f "$p/exe" 2>/dev/null)" = "$1" ] || continue
      [ -z "$found" ] || exit 41
      found=${p##*/}
    done
    [ -n "$found" ] || exit 42
    digest=$(sha256sum "$1" | cut -d" " -f1)
    version=$("$1" --version | sed -n "1s/^.* version v//p")
    filesystem_id=$(stat -f -c %i "$2")
    printf "pid=%s\ndigest=%s\nversion=%s\nfilesystem_id=%s\nargs_b64=" "$found" "$digest" "$version" "$filesystem_id"
    base64 <"/proc/$found/cmdline" | tr -d "\n"
    printf "\n"
  ' sh "$EXPECTED_EXE" "$DATADIR")"
  raw="${raw//$'\r'/}"
  pid="$(sed -n 's/^pid=//p' <<<"$raw")"
  digest="$(sed -n 's/^digest=//p' <<<"$raw")"
  version="$(sed -n 's/^version=//p' <<<"$raw")"
  filesystem_id="$(sed -n 's/^filesystem_id=//p' <<<"$raw")"
  args_b64="$(sed -n 's/^args_b64=//p' <<<"$raw")"
  args="$(printf '%s' "$args_b64" | base64 -d | tr '\0' '\n' | jq -Rsc 'split("\n")[:-1]')"
  jq -n --arg pid "$pid" --arg digest "$digest" --arg version "$version" \
    --arg filesystem_id "$filesystem_id" --argjson args "$args" \
    '{pid:$pid,args:$args,digest:$digest,version:$version,filesystem_id:$filesystem_id}'
}

rpc() {
  sub_exec /opt/bitcoin/bin/bitcoin-cli "-datadir=$DATADIR" "$@"
}

wait_node_ready() {
  local waited=0 chain
  while :; do
    chain="$(rpc getblockchaininfo 2>/dev/null || true)"
    chain="${chain//$'\r'/}"
    if jq -e '.chain=="signet" and .initialblockdownload==false and .blocks==.headers' \
      <<<"$chain" >/dev/null 2>&1; then
      printf '%s\n' "$chain"
      return 0
    fi
    (( waited < 900 )) || {
      start-cli package logs "$PACKAGE_ID" -l 300 >&2 || true
      fail "StartOS Knots did not become synchronized and RPC-ready"
    }
    sleep 3
    waited=$((waited+3))
  done
}

wait_indexes_ready() {
  local waited=0 indexes expected
  expected="$(jq -c .checkpoint.required_indexes "$PROFILE")"
  while :; do
    indexes="$(rpc getindexinfo 2>/dev/null || true)"
    indexes="${indexes//$'\r'/}"
    if jq -e --argjson expected "$expected" '
      type=="object" and
      ($expected | all(.[]; . as $name | $indexes[$name].synced == true)) and
      all(.[]; .synced == true)
    ' --argjson indexes "$indexes" <<<"$indexes" >/dev/null 2>&1; then
      printf '%s\n' "$indexes"
      return 0
    fi
    (( waited < 14400 )) || {
      start-cli package logs "$PACKAGE_ID" -l 300 >&2 || true
      fail "StartOS package indexes did not become synchronized"
    }
    sleep 10
    waited=$((waited+10))
  done
}

verify_runtime() {
  load_profile; verify_os; resolve_lxc_volume; verify_overlay_identity
  [[ "$(installed_version)" == *"$PACKAGE_VERSION"* ]] ||
    fail "installed bitcoind flavor differs from '$PACKAGE_VERSION'"
  local uuid filesystem_id lxc_filesystem_id runtime_filesystem_id runtime chain indexes deployment marker expected actual tip_age now signer
  signer="$(installed_developer_key)" || fail "installed package signer is not observable"
  jq -e --arg signer "$signer" '
    ($signer | gsub("[[:space:]]+$"; "")) as $observed |
    [.registry.expected_signers[] | gsub("[[:space:]]+$"; "")] |
    index($observed) != null
  ' "$PROFILE" >/dev/null ||
    fail "installed bitcoind package signer differs from the pinned profile"
  uuid="$(jq -r .filesystem_uuid "$ACTIVE")"
  [[ "$(findmnt -rn -o UUID -T "$PRIVATE_MOUNT" | tail -1)" == "$uuid" &&
     "$(findmnt -rn -o UUID -T "$LXC_VOLUME_SOURCE" | tail -1)" == "$uuid" ]] ||
    fail "host StartOS volume views do not use the overlay"
  filesystem_id="$(stat -f -c %i "$PRIVATE_MOUNT")"
  [[ "$(lxc-info -n "$LXC_NAME" -sH)" == RUNNING ]] || fail "official package LXC is not running"
  lxc_filesystem_id="$(lxc-attach -n "$LXC_NAME" -- stat -f -c %i "$LXC_VOLUME")"
  [[ "$lxc_filesystem_id" == "$filesystem_id" ]] ||
    fail "package LXC main volume does not use the overlay"
  runtime="$(runtime_json)"
  runtime_filesystem_id="$(jq -r .filesystem_id <<<"$runtime")"
  [[ "$runtime_filesystem_id" == "$filesystem_id" ]] ||
    fail "bitcoind-sub datadir filesystem '$runtime_filesystem_id' differs from overlay '$filesystem_id'"
  [[ "$(jq -r .digest <<<"$runtime")" == "$(jqv .package.knots_binary_sha256)" ]] ||
    fail "official Knots executable digest mismatch"
  [[ "$(jq -r .version <<<"$runtime")" == "$(jqv .package.knots_version_normalized)" ]] ||
    fail "actual Knots version differs from the pinned package"
  # Network may be set via conf (chain=signet) rather than CLI; forbid other nets
  # and reindex flags. Runtime getblockchaininfo proves signet below.
  jq -e --arg datadir "$DATADIR" '
    ([.args[] | select(startswith("-datadir="))] | all(. == "-datadir="+$datadir)) and
    ([.args[] | select(test("^-(testnet|regtest)(=|$)"))] | length==0) and
    ([.args[] | select(test("^-(reindex|reindex-chainstate)(=|$)"))] | length==0)
  ' <<<"$runtime" >/dev/null ||
    fail "actual official Knots process uses a conflicting datadir/network/reindex argument"
  grep -Eq '^[[:space:]]*chain[[:space:]]*=[[:space:]]*signet([[:space:]]|$)' \
    "$PRIVATE_MOUNT/bitcoin.conf" || fail "chain=signet is not effective in StartOS configuration"
  chain="$(wait_node_ready)"
  indexes="$(wait_indexes_ready)"
  deployment="$(rpc getdeploymentinfo)"
  jq -e '.chain=="signet" and .initialblockdownload==false and .blocks==.headers' <<<"$chain" >/dev/null ||
    fail "StartOS Knots is not synchronized on signet"
  jq -e --arg name "$(jqv .package.rdts_deployment)" '
    .deployments[$name] as $deployment |
    $deployment.type=="bip9" and
    ($deployment.active==true or
      ($deployment.bip9.status | IN("started","locked_in","active")))
  ' <<<"$deployment" >/dev/null ||
    fail "runtime getdeploymentinfo does not prove RDTS enforcement"
  grep -Eq '^[[:space:]]*blocksxor[[:space:]]*=[[:space:]]*0([[:space:]]|$)' \
    "$PRIVATE_MOUNT/bitcoin.conf" || fail "blocksxor=0 is not effective in StartOS configuration"
  ! grep -Eq '^[[:space:]]*prune[[:space:]]*=[[:space:]]*([1-9]|[1-9][0-9]+)' \
    "$PRIVATE_MOUNT/bitcoin.conf" || fail "StartOS pruning remains enabled"
  jq -e --argjson expected "$(jq -c .checkpoint.required_indexes "$PROFILE")" '
    $expected | all(.[]; . as $name | $indexes[$name].synced == true)
  ' --argjson indexes "$indexes" <<<"null" >/dev/null ||
    fail "required StartOS checkpoint indexes are absent or unsynchronized"
  now="$(date +%s)"; tip_age=$((now - $(jq -r .time <<<"$chain")))
  (( tip_age >= 0 && tip_age <= 86400 )) || fail "StartOS chain tip is stale"
  marker="$(cat "$PRIVATE_MOUNT/.bvml-overlay.json")"
  jq -e --arg overlay "$(jq -r .overlay_id "$ACTIVE")" \
    --arg generation "$(jq -r .checkpoint_generation "$ACTIVE")" \
    '.overlay_id==$overlay and .checkpoint_generation==$generation' <<<"$marker" >/dev/null ||
    fail "StartOS overlay marker differs from lifecycle state"
  jq -n --arg platform startos --arg os "$STARTOS_RELEASE" \
    --arg package "$PACKAGE_VERSION" --arg profile "$PROFILE_DIGEST" \
    --arg binary "$(jq -r .digest <<<"$runtime")" \
    --arg implementation "$(jqv .adapter_implementation_version)" \
    --arg lxc "$LXC_NAME" --arg source "$LXC_VOLUME_SOURCE" \
    --arg uuid "$uuid" --arg signer "$signer" \
    --argjson runtime "$runtime" --argjson chain "$chain" \
    --argjson indexes "$indexes" --argjson deployment "$deployment" \
    --arg now "$(date -u +%FT%TZ)" \
    '{platform:$platform,os_version:$os,package_version:$package,
      profile_digest:$profile,knots_binary_digest:$binary,
      adapter_implementation_version:$implementation,last_validation_result:"ok",
      validated_at:$now,lxc_name:$lxc,native_volume_source:$source,
      filesystem_uuid:$uuid,package_signer:$signer,runtime:$runtime,blockchain:$chain,indexes:$indexes,
      deployment:$deployment}' >"$VERIFICATION"
  chmod 0600 "$VERIFICATION"
}

setup() {
  load_profile; verify_os
  if ! package_stopped; then
    echo "recovering a previously started native package before adapter setup" >&2
    stop_native
  fi
  mount_overlay
  verify_native_nocow_contract
  merge_config
  activate_rdts
  start-cli package start "$PACKAGE_ID" --force 2>/dev/null ||
    start-cli package start "$PACKAGE_ID"
  wait_package_running
  verify_runtime
  restart_package_observed
  verify_runtime
}

restart_native() {
  load_profile
  restart_package_observed
  verify_runtime
}

stop_native() {
  if [[ ! -f "$PROFILE" ]]; then
    pgrep -x bitcoind >/dev/null && fail "profile absent while a Knots process exists"
    echo "application already stopped: StartOS adapter is not installed"; return
  fi
  load_profile
  if package_stopped; then
    echo "application already stopped"
  else
    start-cli package stop "$PACKAGE_ID" || fail "native StartOS package stop failed"
    wait_package_stopped
    echo "application stopped successfully"
  fi
  [[ "$(package_desired_state)" == stopped ]] ||
    fail "native StartOS package desired state is not stopped"
  resolve_lxc_volume
  ! lsof +f -- "$LXC_VOLUME_SOURCE" >/dev/null 2>&1 ||
    fail "StartOS main volume remains busy after native package stop"
  sync -f "$LXC_VOLUME_SOURCE"
  if mountpoint -q "$LXC_VOLUME_SOURCE"; then
    umount "$LXC_VOLUME_SOURCE" || fail "managed StartOS main-volume bind mount is busy"
  fi
  if mountpoint -q "$PRIVATE_MOUNT"; then
    umount "$PRIVATE_MOUNT" || fail "private StartOS overlay mount is busy"
  fi
  [[ ! -e "$LXC_VOLUME_SOURCE/.bvml-overlay.json" ]] ||
    fail "native StartOS volume was not restored after unmount"
  [[ ! -e "$LXC_VOLUME_SOURCE/blocks" && ! -e "$LXC_VOLUME_SOURCE/chainstate" ]] ||
    fail "native StartOS system volume acquired a competing blockchain datadir"
}

observe() {
  load_profile; verify_os; resolve_lxc_volume
  local desired actual lxc_state private_uuid managed_uuid subcontainer
  desired="$(package_desired_state 2>/dev/null || echo unknown)"
  package_stopped && actual=stopped || actual=running
  lxc_state="$(lxc-info -n "$LXC_NAME" -sH 2>/dev/null || echo unknown)"
  private_uuid="$(findmnt -rn -o UUID -T "$PRIVATE_MOUNT" 2>/dev/null | tail -1 || true)"
  managed_uuid="$(findmnt -rn -o UUID -T "$LXC_VOLUME_SOURCE" 2>/dev/null | tail -1 || true)"
  if sub_exec /bin/true >/dev/null 2>&1; then
    subcontainer=running
  else
    subcontainer=stopped
  fi
  jq -n --arg platform startos --arg desired "$desired" --arg actual "$actual" \
    --arg lxc "$LXC_NAME" --arg lxc_state "$lxc_state" \
    --arg native_source "$LXC_VOLUME_SOURCE" --arg private_mount "$PRIVATE_MOUNT" \
    --arg private_uuid "$private_uuid" --arg managed_uuid "$managed_uuid" \
    --arg subcontainer "$subcontainer" \
    '{platform:$platform,desired_state:$desired,actual_state:$actual,
      lxc_name:$lxc,lxc_state:$lxc_state,native_volume_source:$native_source,
      private_mount:$private_mount,private_uuid:$private_uuid,
      managed_uuid:$managed_uuid,subcontainer_state:$subcontainer}'
}

install_package() {
  load_profile; verify_os
  local package_file="${2:-/var/tmp/bitcoind_x86_64.s9pk}" registry version_query
  [[ -f "$package_file" &&
     "$(sha256sum "$package_file" | awk '{print $1}')" == "$(jqv .registry.release_sha256)" ]] ||
    fail "pinned StartOS s9pk is missing or has the wrong digest"
  registry="$(jqv .registry.url)"
  version_query="$(start-cli --registry "$registry" registry package get "$PACKAGE_ID" full \
    --target-version "=$PACKAGE_VERSION" --format json)" ||
    fail "official StartOS registry query failed"
  jq -e --arg version "$PACKAGE_VERSION" \
    --arg commit "$(jqv .registry.source_commit)" \
    --arg root "$(jqv .registry.root_sighash)" \
    --argjson signers "$(jq -c .registry.expected_signers "$PROFILE")" '
      .best[$version].gitHash==$commit and
      ([.best[$version].s9pks[][] |
        select(.commitment.rootSighash==$root) |
        (.signatures|keys) as $actual |
        ($signers|sort)==($actual|sort)] | any)
  ' <<<"$version_query" >/dev/null ||
    fail "official registry version, commitment, source, or signer metadata differs from the pinned profile"
  if [[ "$(installed_version 2>/dev/null || true)" != "$PACKAGE_VERSION" ]]; then
    start-cli --registry "$registry" package install "$PACKAGE_ID" "=$PACKAGE_VERSION"
  fi
  [[ "$(installed_version)" == "$PACKAGE_VERSION" ]] ||
    fail "installed StartOS package has the wrong flavor/version"
  start-cli package stop "$PACKAGE_ID" >/dev/null 2>&1 || true
  wait_package_stopped
  capture_seed
}

case "${1:-status}" in
  install-package) install_package "$@" ;;
  setup)
    exec 8>"$STATE/adapter-operation.lock"
    flock -n 8 || fail "another StartOS adapter operation is running"
    setup
    ;;
  verify)
    exec 8>"$STATE/adapter-operation.lock"
    flock -n 8 || fail "another StartOS adapter operation is running"
    verify_runtime
    ;;
  status|observe) observe ;;
  restart)
    exec 8>"$STATE/adapter-operation.lock"
    flock -n 8 || fail "another StartOS adapter operation is running"
    restart_native
    ;;
  stop)
    exec 8>"$STATE/adapter-operation.lock"
    flock -n 8 || fail "another StartOS adapter operation is running"
    stop_native
    ;;
  *) fail "usage: $0 {install-package|setup|verify|restart|stop|status}" ;;
esac
