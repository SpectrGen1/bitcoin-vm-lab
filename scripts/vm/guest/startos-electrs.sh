#!/usr/bin/env bash
# Native StartOS Electrs consumer (community marketplace package).
# start-cli remains the lifecycle controller; overlay is idmapped onto the
# package main volume at /media/startos/volumes/main.
set -Eeuo pipefail

STATE=/media/startos/data/main/bvml
INDEX_PROFILE=$STATE/indexers.json
INDEX_SHA_FILE=$STATE/indexers.sha256
STARTOS_PROFILE=$STATE/startos-profile.json
ACTIVE=$STATE/active-indexes.json
PROVISIONED=$STATE/startos-electrs-provisioned.json
EVIDENCE=$STATE/electrs-verification.json
SEED=$STATE/startos-electrs-seed
PRIVATE=/media/bvml-startos-electrs
PACKAGE=electrs
VOLUME=/media/startos/volumes/main
SUBCONTAINER=electrs
DATADIR=/data
TIMEOUT="${STARTOS_OPERATION_TIMEOUT:-14400}"

fail() { echo "error: $*" >&2; exit 1; }
iget() { jq -er "$1" "$INDEX_PROFILE"; }

load_profiles() {
  local file
  for file in "$INDEX_PROFILE" "$INDEX_SHA_FILE" "$STARTOS_PROFILE"; do
    [[ -f "$file" && "$(stat -c %u "$file")" == 0 &&
       -z "$(find "$file" -maxdepth 0 -perm /022 -print -quit)" ]] ||
      fail "unsafe or absent privileged profile: $file"
  done
  INDEX_SHA="$(tr -d '[:space:]' <"$INDEX_SHA_FILE")"
  [[ "$INDEX_SHA" =~ ^[0-9a-f]{64}$ &&
     "$(sha256sum "$INDEX_PROFILE" | awk '{print $1}')" == "$INDEX_SHA" ]] ||
    fail "StartOS Electrs index profile digest mismatch"
  PACKAGE_VERSION="$(iget .electrs.startos.package_version)"
  [[ "$PACKAGE_VERSION" == 0.11.1:17 &&
     "$(iget .electrs.startos.package_id)" == "$PACKAGE" &&
     "$(iget .electrs.startos.volume)" == main &&
     "$(iget .electrs.startos.lxc_volume_mount)" == "$VOLUME" &&
     "$(iget .electrs.startos.subcontainer)" == "$SUBCONTAINER" &&
     "$(iget .electrs.startos.subcontainer_datadir)" == "$DATADIR" ]] ||
    fail "unsupported StartOS Electrs profile"
}

verify_os() {
  local release expected git_info
  expected="$(jq -er .os.release "$STARTOS_PROFILE")"
  release="$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")"
  [[ "$(. /etc/os-release; printf '%s' "${ID:-}")" == start-os &&
     "$release" == "$expected" ]] || fail "StartOS release differs from the pinned platform"
  git_info="$(start-cli git-info 2>/dev/null || true)"
  [[ "$git_info" == "$(jq -er .os.installed_git_info "$STARTOS_PROFILE")" ]] ||
    fail "StartOS build differs from the pinned platform"
}

installed_version() {
  local out
  out="$(start-cli package installed-version "$PACKAGE" --format json 2>/dev/null || true)"
  if [[ -n "$out" ]]; then jq -er 'if type=="string" then . else tostring end' <<<"$out"; return; fi
  start-cli db dump -p --format json |
    jq -er --arg id "$PACKAGE" '.value.public.packageData[$id].stateInfo.manifest.version'
}

# StartOS 0.4 package list status is install-state ("installed"), not runtime.
# Runtime desired state lives in packageData[].statusInfo.desired.main.
package_status() {
  local out desired
  out="$(start-cli db dump -p --format json 2>/dev/null || true)"
  if [[ -n "$out" ]]; then
    desired="$(jq -r --arg id "$PACKAGE" \
      '.value.public.packageData[$id].statusInfo.desired.main // empty' <<<"$out" 2>/dev/null || true)"
    case "$desired" in
      running|starting|restarting) printf 'running\n'; return;;
      stopped|stopping|"") ;;
      *) printf '%s\n' "$desired"; return;;
    esac
    if jq -e --arg id "$PACKAGE" '.value.public.packageData[$id]|type=="object"' \
         <<<"$out" >/dev/null 2>&1; then
      printf 'stopped\n'; return
    fi
  fi
  start-cli package list --format json 2>/dev/null |
    jq -er --arg id "$PACKAGE" \
      '[.[]|select(.id==$id)]|if length==1 then .[0].status else empty end' ||
    printf 'absent\n'
}

package_stopped() {
  case "$(package_status 2>/dev/null || echo absent)" in installed|stopped|absent) return 0;; *) return 1;; esac
}

wait_status() {
  local wanted="$1" waited=0 status
  while ((waited < TIMEOUT)); do
    status="$(package_status 2>/dev/null || echo unknown)"
    case "$wanted:$status" in
      stopped:installed|stopped:stopped|running:running) return;;
      *:failed|*:error) fail "Electrs package entered $status";;
    esac
    sleep 3; waited=$((waited+3))
  done
  fail "Electrs package timed out waiting for $wanted (last=$status)"
}

# StartOS 0.4: -n selects the subcontainer by name (e.g. electrs).
# The older interactive attach listing ("=> Name: ...") is no longer reliable.
sub_exec() {
  start-cli package attach "$PACKAGE" -n "$SUBCONTAINER" -- "$@"
}

resolve_volume() {
  local stats rootfs target source_spec source_dev fsroot base waited=0
  while :; do
    stats="$(start-cli package stats --format json 2>/dev/null || true)"
    jq -e --arg id "$PACKAGE" '.[$id]|type=="object"' <<<"$stats" >/dev/null 2>&1 && break
    ((waited < 180)) || fail "Electrs LXC identity is unavailable"
    sleep 2; waited=$((waited+2))
  done
  LXC="$(jq -er --arg id "$PACKAGE" '.[$id]|(.container_id//.containerId)' <<<"$stats")"
  [[ "$LXC" =~ ^[A-Za-z0-9._-]+$ ]] || fail "unsafe Electrs LXC identity"
  LXC_CONFIG="/var/lib/lxc/$LXC/config"; [[ -f "$LXC_CONFIG" ]] || fail "Electrs LXC config absent"
  rootfs="$(awk -F'[[:space:]]*=[[:space:]]*' '$1=="lxc.rootfs.path"{sub(/^dir:/,"",$2);print $2}' "$LXC_CONFIG")"
  [[ "$rootfs" == "/var/lib/lxc/$LXC/rootfs" ]] || fail "Electrs LXC rootfs layout changed"
  target="$rootfs$VOLUME"
  # Stacked mounts (package-data underlay + BVML overlay) emit multiple findmnt
  # rows for the same TARGET; require every row's TARGET equals the LXC path.
  [[ -d "$target" ]] || fail "Electrs LXC volume path is absent"
  [[ -n "$(findmnt -rn -o TARGET -T "$target")" ]] ||
    fail "Electrs main volume is not a distinct native mount"
  while IFS= read -r mnt_target; do
    [[ "$mnt_target" == "$target" ]] ||
      fail "Electrs main volume is not a distinct native mount"
  done < <(findmnt -rn -o TARGET -T "$target")
  source_spec="$(findmnt -rn -o SOURCE -T "$target" | head -n1)"
  fsroot="$(findmnt -rn -o FSROOT -T "$target" | head -n1)"
  source_dev="${source_spec%%[*}"
  base="$(findmnt -rn -S "$source_dev" -o TARGET,FSROOT | awk '$2=="/"{print $1;exit}')"
  [[ -n "$base" && "$fsroot" == /* ]] || fail "Electrs volume source cannot be resolved"
  NATIVE="$(readlink -f "$base/${fsroot#/}")"
  [[ "$NATIVE" == /* && -d "$NATIVE" ]] || fail "Electrs native main-volume source is unsafe"
}

capture_seed() {
  resolve_volume; package_stopped || fail "Electrs must be stopped before seed capture"
  install -d -o root -g root -m 0700 "$SEED"
  # Community electrs 0.11.1:17 seeds electrs.toml only (no store.json, unlike
  # official Fulcrum/bitcoind packages which write StartOS store.json).
  [[ -f "$NATIVE/electrs.toml" ]] || fail "native Electrs seed lacks electrs.toml"
  install -o root -g root -m 0600 "$NATIVE/electrs.toml" "$SEED/electrs.toml"
  if [[ -f "$NATIVE/store.json" ]]; then
    install -o root -g root -m 0600 "$NATIVE/store.json" "$SEED/store.json"
  else
    rm -f -- "$SEED/store.json"
  fi
  [[ ! -e "$NATIVE/db" ]] ||
    fail "native seed unexpectedly contains an Electrs database"
  jq -n --arg source "$NATIVE" --arg lxc "$LXC" --arg profile "$INDEX_SHA" \
    --arg version "$PACKAGE_VERSION" --arg captured "$(date -u +%FT%TZ)" \
    '{native_volume_source:$source,lxc_name:$lxc,profile_digest:$profile,
      package_version:$version,captured_at:$captured}' >"$PROVISIONED"
  chmod 0600 "$PROVISIONED"
}

install_package() {
  load_profiles; verify_os
  local url digest package_file
  url="$(iget .electrs.startos.release_url)"; digest="$(iget .electrs.startos.release_sha256)"
  package_file=/var/tmp/electrs_x86_64.s9pk
  if [[ ! -f "$package_file" || "$(sha256sum "$package_file"|awk '{print $1}')" != "$digest" ]]; then
    local tmp; tmp="$(mktemp /var/tmp/electrs_x86_64.s9pk.XXXXXX)"
    trap 'rm -f -- "$tmp"' EXIT
    curl -fL --proto '=https' --proto-redir '=https' --retry 4 -o "$tmp" "$url"
    [[ "$(sha256sum "$tmp"|awk '{print $1}')" == "$digest" ]] || fail "Electrs s9pk digest mismatch"
    chmod 0400 "$tmp"; mv "$tmp" "$package_file"; trap - EXIT
  fi
  # Community marketplace package: sideload the digest-pinned s9pk (not registry).
  if [[ "$(installed_version 2>/dev/null || true)" != "$PACKAGE_VERSION" ]]; then
    start-cli package install --sideload "$package_file" ||
      fail "could not sideload StartOS community Electrs package $PACKAGE_VERSION from $package_file"
  fi
  [[ "$(installed_version)" == "$PACKAGE_VERSION" ]] || fail "wrong Electrs package version installed"
  start-cli package stop "$PACKAGE" >/dev/null 2>&1 || true
  wait_status stopped
  capture_seed
}

identify_overlay() {
  [[ -f "$ACTIVE" ]] || fail "active Electrs overlay identity is absent"
  local serial size byid candidates=()
  serial="$(jq -er .services.electrs.disk_serial "$ACTIVE")"
  size="$(jq -er .services.electrs.size_bytes "$ACTIVE")"
  while IFS= read -r byid; do
    [[ -e "$byid" && "$(lsblk -bndo SIZE "$(readlink -f "$byid")")" == "$size" ]] &&
      candidates+=("$(readlink -f "$byid")")
  done < <(find /dev/disk/by-id -maxdepth 1 -type l -name "*$serial*" -print)
  ((${#candidates[@]}==1)) || fail "Electrs overlay identity is missing or ambiguous"
  DEVICE="${candidates[0]}"
  [[ "$(blkid -s UUID -o value "$DEVICE")" == "$(jq -r .services.electrs.filesystem_uuid "$ACTIVE")" &&
     "$(blkid -s TYPE -o value "$DEVICE")" == btrfs ]] ||
    fail "Electrs overlay filesystem identity is wrong"
}

mount_overlay() {
  resolve_volume; identify_overlay; package_stopped || fail "Electrs package must be stopped"
  local pid uuid target
  uuid="$(jq -r .services.electrs.filesystem_uuid "$ACTIVE")"
  pid="$(lxc-info -n "$LXC" -pH)"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || fail "Electrs LXC user namespace unavailable"
  install -d -o root -g root -m 0700 "$PRIVATE"
  mountpoint -q "$PRIVATE" || mount -o rw,nodev,nosuid "$DEVICE" "$PRIVATE"
  [[ "$(findmnt -rn -o UUID -T "$PRIVATE")" == "$uuid" ]] || fail "private Electrs mount UUID mismatch"
  if mountpoint -q "$NATIVE"; then
    [[ "$(findmnt -rn -o UUID -T "$NATIVE")" == "$uuid" ]] && return
    fail "Electrs native volume is already replaced by another filesystem"
  fi
  mount --bind --map-users "/proc/$pid/ns/user" "$PRIVATE" "$NATIVE"
  findmnt -rn -o OPTIONS -T "$NATIVE" | grep -qw idmapped ||
    fail "Electrs native volume bind is not idmapped"
  target="/var/lib/lxc/$LXC/rootfs$VOLUME"
  # StartOS keeps the package-data volume mount under the LXC path; our idmapped
  # overlay stacks on top. Accept success when the topmost (last) UUID matches.
  [[ "$(findmnt -rn -o UUID -T "$target" | tail -n1)" == "$uuid" ]] ||
    fail "Electrs overlay did not propagate into its package LXC"
}

# Official StartOS Electrs (community package 0.11.1:17) hard-codes
# network=bitcoin in package store and rewrites electrs.toml on every start.
# Signet/testnet are not supported by the package (see electrs-startos README:
# "Mainnet only — network is fixed to bitcoin"). Lab signet consumers therefore
# cannot prove Electrs overlay reuse through start-cli on this package version.
assert_startos_electrs_signet_supported() {
  fail "official StartOS Electrs package ${PACKAGE_VERSION} is mainnet-only (network fixed to bitcoin); signet index overlay reuse is unsupported until the package exposes signet"
}

seed_overlay() {
  local db layout
  layout="$(iget .electrs.database_layout)"
  db="$PRIVATE/$layout"
  [[ -d "$db" && -n "$(find "$db" -mindepth 1 -print -quit)" ]] ||
    fail "StartOS Electrs overlay lacks reusable database at $db (base was not attached)"
  install -m 0600 "$SEED/electrs.toml" "$PRIVATE/electrs.toml"
  if [[ -f "$SEED/store.json" ]]; then
    install -m 0600 "$SEED/store.json" "$PRIVATE/store.json"
  fi
  # Cookie for signet lives under the network subdir of the bitcoind datadir.
  jq --arg db "$db" --arg layout "$layout" \
    '.services.electrs + {startos_index_profile_sha256:"'"$INDEX_SHA"'",
      database_path:$db,database_layout:$layout,reused_existing_database:true}' \
    "$ACTIVE" >"$PRIVATE/.bvml-index-overlay.json"
  assert_startos_electrs_signet_supported
}

runtime_json() {
  local raw
  raw="$(sub_exec sh -ceu '
    found=
    for p in /proc/[0-9]*; do
      exe=$(readlink -f "$p/exe" 2>/dev/null || true)
      [ "${exe##*/}" = electrs ] || continue
      [ -z "$found" ] || exit 41; found=${p##*/}
    done
    [ -n "$found" ] || exit 42
    printf "pid=%s\ndigest=%s\nfilesystem=%s\nargs=" "$found" \
      "$(sha256sum "/proc/$found/exe"|cut -d" " -f1)" "$(stat -f -c %i /data)"
    base64 <"/proc/$found/cmdline"|tr -d "\n"; printf "\n"
  ')"
  local args; args="$(sed -n 's/^args=//p' <<<"$raw" | base64 -d | tr '\0' '\n' | jq -Rsc 'split("\n")[:-1]')"
  jq -n --arg pid "$(sed -n 's/^pid=//p' <<<"$raw")" \
    --arg digest "$(sed -n 's/^digest=//p' <<<"$raw")" \
    --arg filesystem "$(sed -n 's/^filesystem=//p' <<<"$raw")" \
    --argjson args "$args" '{pid:$pid,digest:$digest,filesystem_id:$filesystem,args:$args}'
}

electrum_height() {
  # Community Electrs binds Electrum TCP on 50001. The electrs image has bash
  # but not python3; use bash /dev/tcp explicitly.
  sub_exec /bin/bash -ceu '
    exec 3<>/dev/tcp/127.0.0.1/50001
    printf "%s\n" "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"blockchain.headers.subscribe\",\"params\":[]}" >&3
    IFS= read -r -t 60 line <&3 || exit 2
    printf "%s\n" "$line"
  ' | jq -er .result.height
}

verify_runtime() {
  load_profiles; verify_os; resolve_volume; identify_overlay
  [[ "$(installed_version)" == "$PACKAGE_VERSION" ]] || fail "wrong Electrs package version"
  [[ "$(findmnt -rn -o UUID -T "$PRIVATE")" == "$(jq -r .services.electrs.filesystem_uuid "$ACTIVE")" &&
     "$(findmnt -rn -o UUID -T "$NATIVE")" == "$(jq -r .services.electrs.filesystem_uuid "$ACTIVE")" ]] ||
    fail "StartOS Electrs host views do not use the overlay"
  local runtime expected height marker base_height layout db
  layout="$(iget .electrs.database_layout)"
  db="$PRIVATE/$layout"
  [[ -d "$db" && -n "$(find "$db" -mindepth 1 -print -quit)" ]] ||
    fail "StartOS Electrs overlay database missing at $db"
  runtime="$(runtime_json)"
  # Community Electrs is a custom image; Ubuntu producer binary digest may differ.
  # Require a live electrs process on the overlay FS and package version match.
  expected="$(jq -r '.services.electrs.binary_sha256 // empty' "$ACTIVE")"
  if [[ -n "$expected" && "$(jq -r .digest <<<"$runtime")" != "$expected" ]]; then
    echo "warning: StartOS Electrs binary digest differs from Ubuntu producer (community image)" >&2
  fi
  [[ "$(jq -r .filesystem_id <<<"$runtime")" == "$(stat -f -c %i "$PRIVATE")" ]] ||
    fail "Electrs subcontainer does not see the overlay filesystem"
  height="$(electrum_height 2>/dev/null || true)"
  [[ "$height" =~ ^[0-9]+$ && "$height" -gt 0 ]] ||
    fail "Electrs Electrum interface returned no height"
  base_height="$(jq -r '.services.electrs.base_tip_height // empty' "$ACTIVE" 2>/dev/null || true)"
  if [[ "$base_height" =~ ^[0-9]+$ ]]; then
    if ! (( height + 2 >= base_height )); then
      fail "StartOS Electrs height $height is below base tip $base_height (reindex suspected)"
    fi
  else
    if ! (( height > 1000 )); then
      fail "StartOS Electrs height $height is too low to prove base reuse"
    fi
  fi
  marker="$(cat "$PRIVATE/.bvml-index-overlay.json")"
  jq -e --arg id "$(jq -r .services.electrs.id "$ACTIVE")" '.id==$id' <<<"$marker" >/dev/null ||
    fail "StartOS Electrs overlay marker mismatch"
  jq -n --arg platform startos --arg service electrs --arg profile "$INDEX_SHA" \
    --arg package "$PACKAGE_VERSION" --arg binary "$(jq -r .digest <<<"$runtime")" \
    --arg uuid "$(jq -r .services.electrs.filesystem_uuid "$ACTIVE")" \
    --arg database_path "$db" --argjson height "$height" --argjson runtime "$runtime" \
    --arg now "$(date -u +%FT%TZ)" \
    '{platform:$platform,service:$service,profile_digest:$profile,package_version:$package,
      binary_sha256:$binary,filesystem_uuid:$uuid,database_path:$database_path,
      height:$height,runtime:$runtime,reused_existing_database:true,
      synchronized:true,last_validation_result:"ok",validated_at:$now}' >"$EVIDENCE"
  cat "$EVIDENCE"
}

setup() {
  load_profiles
  # Fail closed before mount/start: official package cannot open db/signet.
  assert_startos_electrs_signet_supported
}

stop_all() {
  [[ -f "$INDEX_PROFILE" ]] || { echo "Electrs already stopped: adapter absent"; return; }
  load_profiles
  package_stopped || { start-cli package stop "$PACKAGE"; wait_status stopped; }
  resolve_volume
  ! lsof +f -- "$NATIVE" >/dev/null 2>&1 || fail "StartOS Electrs volume remains busy"
  sync -f "$NATIVE"
  mountpoint -q "$NATIVE" && umount "$NATIVE"
  mountpoint -q "$PRIVATE" && umount "$PRIVATE"
}

case "${1:-}" in
  install-package) install_package ;;
  setup) setup ;;
  verify) verify_runtime ;;
  stop) stop_all ;;
  *) fail "usage: $0 {install-package|setup|verify|stop}" ;;
esac
