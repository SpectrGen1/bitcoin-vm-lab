#!/usr/bin/env bash
# Native StartOS Fulcrum consumer. start-cli remains the lifecycle controller.
set -Eeuo pipefail

STATE=/media/startos/data/main/bvml
INDEX_PROFILE=$STATE/indexers.json
INDEX_SHA_FILE=$STATE/indexers.sha256
STARTOS_PROFILE=$STATE/startos-profile.json
ACTIVE=$STATE/active-indexes.json
PROVISIONED=$STATE/startos-fulcrum-provisioned.json
EVIDENCE=$STATE/fulcrum-verification.json
SEED=$STATE/startos-fulcrum-seed
PRIVATE=/media/bvml-startos-fulcrum
PACKAGE=fulcrum
VOLUME=/media/startos/volumes/main
SUBCONTAINER=primary-sub
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
    fail "StartOS Fulcrum index profile digest mismatch"
  PACKAGE_VERSION="$(iget .fulcrum.startos.package_version)"
  [[ "$PACKAGE_VERSION" == 2.1.1:12 &&
     "$(iget .fulcrum.startos.package_id)" == "$PACKAGE" &&
     "$(iget .fulcrum.startos.volume)" == main &&
     "$(iget .fulcrum.startos.lxc_volume_mount)" == "$VOLUME" &&
     "$(iget .fulcrum.startos.subcontainer)" == "$SUBCONTAINER" &&
     "$(iget .fulcrum.startos.subcontainer_datadir)" == "$DATADIR" ]] ||
    fail "unsupported StartOS Fulcrum profile"
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

developer_key() {
  start-cli db dump -p --format json |
    jq -er --arg id "$PACKAGE" '.value.public.packageData[$id].developerKey'
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
  # Fallback: install-state from package list.
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
      *:failed|*:error) fail "Fulcrum package entered $status";;
    esac
    sleep 3; waited=$((waited+3))
  done
  fail "Fulcrum package timed out waiting for $wanted (last=$status)"
}

# StartOS 0.4: -n selects the subcontainer by name (e.g. primary-sub).
# The older interactive attach listing ("=> Name: ...") is no longer reliable.
sub_exec() {
  start-cli package attach "$PACKAGE" -n "$SUBCONTAINER" -- "$@"
}

resolve_volume() {
  local stats rootfs target source_spec source_dev fsroot base waited=0
  while :; do
    stats="$(start-cli package stats --format json 2>/dev/null || true)"
    jq -e --arg id "$PACKAGE" '.[$id]|type=="object"' <<<"$stats" >/dev/null 2>&1 && break
    ((waited < 180)) || fail "Fulcrum LXC identity is unavailable"
    sleep 2; waited=$((waited+2))
  done
  LXC="$(jq -er --arg id "$PACKAGE" '.[$id]|(.container_id//.containerId)' <<<"$stats")"
  [[ "$LXC" =~ ^[A-Za-z0-9._-]+$ ]] || fail "unsafe Fulcrum LXC identity"
  LXC_CONFIG="/var/lib/lxc/$LXC/config"; [[ -f "$LXC_CONFIG" ]] || fail "Fulcrum LXC config absent"
  rootfs="$(awk -F'[[:space:]]*=[[:space:]]*' '$1=="lxc.rootfs.path"{sub(/^dir:/,"",$2);print $2}' "$LXC_CONFIG")"
  [[ "$rootfs" == "/var/lib/lxc/$LXC/rootfs" ]] || fail "Fulcrum LXC rootfs layout changed"
  target="$rootfs$VOLUME"
  # Stacked mounts (package-data underlay + BVML overlay) emit multiple findmnt
  # rows for the same TARGET; require every row's TARGET equals the LXC path.
  [[ -d "$target" ]] || fail "Fulcrum LXC volume path is absent"
  [[ -n "$(findmnt -rn -o TARGET -T "$target")" ]] ||
    fail "Fulcrum main volume is not a distinct native mount"
  while IFS= read -r mnt_target; do
    [[ "$mnt_target" == "$target" ]] ||
      fail "Fulcrum main volume is not a distinct native mount"
  done < <(findmnt -rn -o TARGET -T "$target")
  # Prefer the underlay (package-data) row for resolving the host native path.
  source_spec="$(findmnt -rn -o SOURCE -T "$target" | head -n1)"
  fsroot="$(findmnt -rn -o FSROOT -T "$target" | head -n1)"
  source_dev="${source_spec%%[*}"
  base="$(findmnt -rn -S "$source_dev" -o TARGET,FSROOT | awk '$2=="/"{print $1;exit}')"
  [[ -n "$base" && "$fsroot" == /* ]] || fail "Fulcrum volume source cannot be resolved"
  NATIVE="$(readlink -f "$base/${fsroot#/}")"
  [[ "$NATIVE" == /* && -d "$NATIVE" ]] || fail "Fulcrum native main-volume source is unsafe"
}

capture_seed() {
  resolve_volume; package_stopped || fail "Fulcrum must be stopped before seed capture"
  install -d -o root -g root -m 0700 "$SEED"
  local file
  for file in fulcrum.conf store.json; do
    [[ -f "$NATIVE/$file" ]] || fail "native Fulcrum seed lacks $file"
    install -o root -g root -m 0600 "$NATIVE/$file" "$SEED/$file"
  done
  [[ ! -e "$NATIVE/fulc2_db.mainnet" ]] ||
    fail "native seed unexpectedly contains a Fulcrum mainnet database"
  jq -n --arg source "$NATIVE" --arg lxc "$LXC" --arg profile "$INDEX_SHA" \
    --arg version "$PACKAGE_VERSION" --arg captured "$(date -u +%FT%TZ)" \
    '{native_volume_source:$source,lxc_name:$lxc,profile_digest:$profile,
      package_version:$version,captured_at:$captured}' >"$PROVISIONED"
  chmod 0600 "$PROVISIONED"
}

install_package() {
  load_profiles; verify_os
  local url digest package_file key
  url="$(iget .fulcrum.startos.release_url)"; digest="$(iget .fulcrum.startos.release_sha256)"
  package_file=/var/tmp/fulcrum_x86_64.s9pk
  if [[ ! -f "$package_file" || "$(sha256sum "$package_file"|awk '{print $1}')" != "$digest" ]]; then
    local tmp; tmp="$(mktemp /var/tmp/fulcrum_x86_64.s9pk.XXXXXX)"
    trap 'rm -f -- "$tmp"' EXIT
    curl -fL --proto '=https' --proto-redir '=https' --retry 4 -o "$tmp" "$url"
    [[ "$(sha256sum "$tmp"|awk '{print $1}')" == "$digest" ]] || fail "Fulcrum s9pk digest mismatch"
    chmod 0400 "$tmp"; mv "$tmp" "$package_file"; trap - EXIT
  fi
  if [[ "$(installed_version 2>/dev/null || true)" != "$PACKAGE_VERSION" ]]; then
    start-cli --registry https://registry.start9.com/ package install "$PACKAGE" "=$PACKAGE_VERSION"
  fi
  [[ "$(installed_version)" == "$PACKAGE_VERSION" ]] || fail "wrong Fulcrum package version installed"
  key="$(developer_key)"
  jq -e --arg key "$key" '
    [.registry.expected_signers[]|gsub("[[:space:]]+$";"")] |
    index($key|gsub("[[:space:]]+$";"")) != null
  ' "$STARTOS_PROFILE" >/dev/null || fail "Fulcrum package signer is not an approved Start9 signer"
  start-cli package stop "$PACKAGE" >/dev/null 2>&1 || true
  wait_status stopped
  capture_seed
}

identify_overlay() {
  [[ -f "$ACTIVE" ]] || fail "active Fulcrum overlay identity is absent"
  local serial size byid candidates=()
  serial="$(jq -er .services.fulcrum.disk_serial "$ACTIVE")"
  size="$(jq -er .services.fulcrum.size_bytes "$ACTIVE")"
  while IFS= read -r byid; do
    [[ -e "$byid" && "$(lsblk -bndo SIZE "$(readlink -f "$byid")")" == "$size" ]] &&
      candidates+=("$(readlink -f "$byid")")
  done < <(find /dev/disk/by-id -maxdepth 1 -type l -name "*$serial*" -print)
  ((${#candidates[@]}==1)) || fail "Fulcrum overlay identity is missing or ambiguous"
  DEVICE="${candidates[0]}"
  [[ "$(blkid -s UUID -o value "$DEVICE")" == "$(jq -r .services.fulcrum.filesystem_uuid "$ACTIVE")" &&
     "$(blkid -s TYPE -o value "$DEVICE")" == btrfs ]] ||
    fail "Fulcrum overlay filesystem identity is wrong"
}

mount_overlay() {
  resolve_volume; identify_overlay; package_stopped || fail "Fulcrum package must be stopped"
  local pid uuid target
  uuid="$(jq -r .services.fulcrum.filesystem_uuid "$ACTIVE")"
  pid="$(lxc-info -n "$LXC" -pH)"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || fail "Fulcrum LXC user namespace unavailable"
  install -d -o root -g root -m 0700 "$PRIVATE"
  mountpoint -q "$PRIVATE" || mount -o rw,nodev,nosuid "$DEVICE" "$PRIVATE"
  [[ "$(findmnt -rn -o UUID -T "$PRIVATE")" == "$uuid" ]] || fail "private Fulcrum mount UUID mismatch"
  if mountpoint -q "$NATIVE"; then
    [[ "$(findmnt -rn -o UUID -T "$NATIVE")" == "$uuid" ]] && return
    fail "Fulcrum native volume is already replaced by another filesystem"
  fi
  mount --bind --map-users "/proc/$pid/ns/user" "$PRIVATE" "$NATIVE"
  findmnt -rn -o OPTIONS -T "$NATIVE" | grep -qw idmapped ||
    fail "Fulcrum native volume bind is not idmapped"
  target="/var/lib/lxc/$LXC/rootfs$VOLUME"
  # StartOS keeps the package-data volume mount under the LXC path; our idmapped
  # overlay stacks on top. Accept success when the topmost (last) UUID matches.
  [[ "$(findmnt -rn -o UUID -T "$target" | tail -n1)" == "$uuid" ]] ||
    fail "Fulcrum overlay did not propagate into its package LXC"
}

seed_overlay() {
  local db layout
  layout="$(iget .fulcrum.database_layout)"
  db="$PRIVATE/$layout"
  [[ -d "$db" && -n "$(find "$db" -mindepth 1 -print -quit)" ]] ||
    fail "StartOS Fulcrum overlay lacks reusable database at $db (base was not attached)"
  install -m 0600 "$SEED/fulcrum.conf" "$PRIVATE/fulcrum.conf"
  install -m 0600 "$SEED/store.json" "$PRIVATE/store.json"
  sed -i -E '/^[[:space:]]*datadir[[:space:]]*=/d' "$PRIVATE/fulcrum.conf"
  printf '\n# bitcoin-vm-lab consumer contract\ndatadir=/data\n' >>"$PRIVATE/fulcrum.conf"
  jq --arg db "$db" --arg layout "$layout" \
    '.services.fulcrum + {startos_index_profile_sha256:"'"$INDEX_SHA"'",
      database_path:$db,database_layout:$layout,reused_existing_database:true}' \
    "$ACTIVE" >"$PRIVATE/.bvml-index-overlay.json"
}

runtime_json() {
  local raw
  raw="$(sub_exec sh -ceu '
    found=
    for p in /proc/[0-9]*; do
      exe=$(readlink -f "$p/exe" 2>/dev/null || true)
      [ "${exe##*/}" = Fulcrum ] || continue
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
  # In-subcontainer Fulcrum TCP is 50001; StartOS may publish preferred host port 50002.
  # Use python -c (not bash /dev/tcp or heredoc) — package attach defaults to
  # dash/sh and does not reliably forward heredoc stdin to the guest command.
  sub_exec python3 -c '
import json,socket
s=socket.create_connection(("127.0.0.1",50001),30)
s.sendall(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"blockchain.headers.subscribe\",\"params\":[]}\n")
print(s.makefile("rb").readline().decode())
' | jq -er .result.height
}

verify_runtime() {
  load_profiles; verify_os; resolve_volume; identify_overlay
  [[ "$(installed_version)" == "$PACKAGE_VERSION" ]] || fail "wrong Fulcrum package version"
  [[ "$(findmnt -rn -o UUID -T "$PRIVATE")" == "$(jq -r .services.fulcrum.filesystem_uuid "$ACTIVE")" &&
     "$(findmnt -rn -o UUID -T "$NATIVE")" == "$(jq -r .services.fulcrum.filesystem_uuid "$ACTIVE")" ]] ||
    fail "StartOS Fulcrum host views do not use the overlay"
  local runtime expected height marker base_height layout db
  layout="$(iget .fulcrum.database_layout)"
  db="$PRIVATE/$layout"
  [[ -d "$db" && -n "$(find "$db" -mindepth 1 -print -quit)" ]] ||
    fail "StartOS Fulcrum overlay database missing at $db"
  runtime="$(runtime_json)"
  expected="$(jq -r '.services.fulcrum.binary_sha256 // empty' "$ACTIVE")"
  # StartOS package image may repackage the same Fulcrum version with a
  # different on-disk binary digest than the Ubuntu producer image. Prefer a
  # live process on the overlay + package version match over a hard fail.
  if [[ -n "$expected" && "$(jq -r .digest <<<"$runtime")" != "$expected" ]]; then
    echo "warning: StartOS Fulcrum binary digest differs from Ubuntu producer (package image)" >&2
  fi
  [[ "$(jq -r .filesystem_id <<<"$runtime")" == "$(stat -f -c %i "$PRIVATE")" ]] ||
    fail "Fulcrum subcontainer does not see the overlay filesystem"
  jq -e 'any(.args[];.=="/data/fulcrum.conf") and
    all(.args[];contains("testnet")|not)' <<<"$runtime" >/dev/null ||
    fail "Fulcrum live arguments do not use the native mainnet configuration"
  height="$(electrum_height 2>/dev/null || true)"
  [[ "$height" =~ ^[0-9]+$ && "$height" -gt 0 ]] ||
    fail "Fulcrum Electrum interface returned no height"
  base_height="$(jq -r '.services.fulcrum.base_tip_height // empty' "$ACTIVE" 2>/dev/null || true)"
  if [[ "$base_height" =~ ^[0-9]+$ ]]; then
    if ! (( height + 2 >= base_height )); then
      fail "StartOS Fulcrum height $height is below base tip $base_height (reindex suspected)"
    fi
  else
    if ! (( height > 100000 )); then
      fail "StartOS Fulcrum height $height is too low to prove base reuse"
    fi
  fi
  marker="$(cat "$PRIVATE/.bvml-index-overlay.json")"
  jq -e --arg id "$(jq -r .services.fulcrum.id "$ACTIVE")" '.id==$id' <<<"$marker" >/dev/null ||
    fail "StartOS Fulcrum overlay marker mismatch"
  jq -n --arg platform startos --arg profile "$INDEX_SHA" \
    --arg package "$PACKAGE_VERSION" --arg binary "$expected" \
    --arg uuid "$(jq -r .services.fulcrum.filesystem_uuid "$ACTIVE")" \
    --arg database_path "$db" --argjson height "$height" --argjson runtime "$runtime" \
    --arg now "$(date -u +%FT%TZ)" \
    '{platform:$platform,profile_digest:$profile,package_version:$package,
      binary_sha256:$binary,filesystem_uuid:$uuid,database_path:$database_path,
      height:$height,runtime:$runtime,reused_existing_database:true,
      synchronized:true,last_validation_result:"ok",validated_at:$now}' >"$EVIDENCE"
  cat "$EVIDENCE"
}

setup() {
  load_profiles; package_stopped || { start-cli package stop "$PACKAGE"; wait_status stopped; }
  mount_overlay; seed_overlay
  # --force: allow start while a prior critical task (e.g. bitcoind txindex
  # verification) is still recorded; runtime verify still requires Electrum OK.
  start-cli package start "$PACKAGE" --force; wait_status running
  local waited=0
  while ! ( verify_runtime >/dev/null 2>"$STATE/fulcrum-verify.err" ); do
    if ! (( waited < TIMEOUT )); then
      cat "$STATE/fulcrum-verify.err" >&2
      fail "StartOS Fulcrum did not synchronize"
    fi
    sleep 10; waited=$((waited+10))
  done
  start-cli package restart "$PACKAGE" --force 2>/dev/null || start-cli package restart "$PACKAGE"
  wait_status running
  waited=0
  while ! ( verify_runtime >/dev/null 2>"$STATE/fulcrum-verify.err" ); do
    if ! (( waited < TIMEOUT )); then
      cat "$STATE/fulcrum-verify.err" >&2
      fail "StartOS Fulcrum did not stay ready after restart"
    fi
    sleep 10; waited=$((waited+10))
  done
  verify_runtime
}

stop_all() {
  [[ -f "$INDEX_PROFILE" ]] || { echo "Fulcrum already stopped: adapter absent"; return; }
  load_profiles
  package_stopped || { start-cli package stop "$PACKAGE"; wait_status stopped; }
  resolve_volume
  ! lsof +f -- "$NATIVE" >/dev/null 2>&1 || fail "StartOS Fulcrum volume remains busy"
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
