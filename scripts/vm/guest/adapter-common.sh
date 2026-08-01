#!/usr/bin/env bash
# Shared fail-closed helpers for exact-version package adapters.
set -Eeuo pipefail

adapter_fail() { echo "error: $*" >&2; exit 1; }

adapter_safe_file() {
  local file="$1" digest_file="${2:-}" owner mode expected
  [[ "$file" == /* && -f "$file" ]] || adapter_fail "missing absolute profile/implementation file: $file"
  owner="$(stat -c %u "$file")"; mode="$(stat -c %a "$file")"
  [[ "$owner" == 0 ]] || adapter_fail "$file must be root-owned"
  (( (8#$mode & 022) == 0 )) || adapter_fail "$file must not be group/world writable"
  if [[ -n "$digest_file" ]]; then
    [[ -f "$digest_file" ]] || adapter_fail "missing digest file: $digest_file"
    [[ "$(stat -c %u "$digest_file")" == 0 ]] || adapter_fail "$digest_file must be root-owned"
    mode="$(stat -c %a "$digest_file")"
    (( (8#$mode & 022) == 0 )) || adapter_fail "$digest_file must not be group/world writable"
    expected="$(tr -d '[:space:]' <"$digest_file")"
    [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || adapter_fail "invalid digest in $digest_file"
    [[ "$(sha256sum "$file" | awk '{print $1}')" == "${expected,,}" ]] ||
      adapter_fail "digest mismatch for $file"
  fi
}

adapter_scalar() {
  local name="$1" value="${!1:-}"
  [[ -n "$value" && ! "$value" =~ [[:cntrl:]] ]] ||
    adapter_fail "$name is empty or contains control characters"
}

adapter_absolute_path() {
  local name="$1" value="${!1:-}"
  [[ "$value" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
    adapter_fail "$name must be an absolute path with safe path characters"
}

adapter_identifier() {
  local name="$1" value="${!1:-}"
  [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] ||
    adapter_fail "$name contains unsafe identifier characters"
}

adapter_mount_disk() {
  [[ -b "$BITCOIN_DEVICE" ]] || adapter_fail "overlay disk absent"
  local uuid source
  uuid="$(blkid -s UUID -o value "$BITCOIN_DEVICE")"; [[ -n "$uuid" ]] || adapter_fail "overlay has no filesystem"
  sudo install -d -m 0750 "$BITCOIN_MOUNT"
  grep -q "^UUID=$uuid " /etc/fstab ||
    echo "UUID=$uuid $BITCOIN_MOUNT ext4 defaults,x-systemd.device-timeout=30 0 2" | sudo tee -a /etc/fstab >/dev/null
  mountpoint -q "$BITCOIN_MOUNT" || sudo mount "$BITCOIN_MOUNT"
  source="$(findmnt -n -o SOURCE "$BITCOIN_MOUNT")"
  [[ "$(blkid -s UUID -o value "$source" 2>/dev/null)" == "$uuid" ]] ||
    adapter_fail "Bitcoin mount is not backed by the attached overlay"
}

container_knots_pid() {
  local runtime="$1" container="$2" expected_exe="$3"
  "$runtime" exec "$container" sh -ceu '
    found=
    for proc in /proc/[0-9]*; do
      pid=${proc##*/}
      exe=$(readlink -f "$proc/exe" 2>/dev/null || true)
      if [ "$exe" = "$1" ]; then
        [ -z "$found" ] || exit 41
        found=$pid
      fi
    done
    [ -n "$found" ] || exit 42
    printf "%s\n" "$found"
  ' sh "$expected_exe"
}

container_process_args_json() {
  local runtime="$1" container="$2" pid="$3"
  # Redirection deliberately occurs in the container shell, not in this host shell.
  "$runtime" exec "$container" sh -ceu \
    'test -r "/proc/$1/cmdline"; tr "\0" "\n" <"/proc/$1/cmdline"' sh "$pid" |
    jq -Rsc 'split("\n")[:-1]'
}

verify_container_knots() {
  local runtime="$1" container="$2" expected_exe="$3" expected_digest="$4"
  local datadir="$5" required_rdts_json="$6" expected_user="$7"
  local pid args digest uid option expected count actual
  pid="$(container_knots_pid "$runtime" "$container" "$expected_exe")" ||
    adapter_fail "could not locate exactly one actual Knots process in $container"
  args="$(container_process_args_json "$runtime" "$container" "$pid")"
  digest="$("$runtime" exec "$container" sha256sum "$expected_exe" | awk '{print $1}')"
  [[ "$digest" == "$expected_digest" ]] || adapter_fail "in-container executable digest mismatch"
  uid="$("$runtime" exec "$container" stat -c %u "/proc/$pid")"
  [[ "$uid" == "$expected_user" ]] || adapter_fail "Knots runtime user $uid does not match expected $expected_user"
  for expected in "-datadir=$datadir" "-chain=main" "-blocksxor=0"; do
    option="${expected%%=*}"
    count="$(jq --arg o "$option" '[.[] | select(. == $o or startswith($o + "="))] | length' <<<"$args")"
    [[ "$count" == 1 ]] || adapter_fail "live Knots process has missing/duplicated $option"
    actual="$(jq -r --arg o "$option" '.[] | select(. == $o or startswith($o + "="))' <<<"$args")"
    [[ "$actual" == "$expected" ]] || adapter_fail "live Knots uses '$actual', expected '$expected'"
  done
  jq -e 'type == "array" and length > 0 and all(.[]; type == "string")' \
    <<<"$required_rdts_json" >/dev/null || adapter_fail "invalid RDTS argument profile"
  while IFS= read -r expected; do
    option="${expected%%=*}"
    count="$(jq --arg o "$option" '[.[] | select(. == $o or startswith($o + "="))] | length' <<<"$args")"
    [[ "$count" == 1 ]] || adapter_fail "live Knots process has missing/duplicated RDTS option $option"
    actual="$(jq -r --arg o "$option" '.[] | select(. == $o or startswith($o + "="))' <<<"$args")"
    [[ "$actual" == "$expected" ]] || adapter_fail "live Knots RDTS value '$actual' differs from '$expected'"
  done < <(jq -r '.[]' <<<"$required_rdts_json")
  CONTAINER_KNOTS_PID="$pid"
  CONTAINER_KNOTS_ARGS_JSON="$args"
  CONTAINER_KNOTS_DIGEST="$digest"
  CONTAINER_KNOTS_UID="$uid"
}

write_adapter_metadata() {
  local platform="$1" os_version="$2" package_version="$3" profile_digest="$4"
  local binary_digest="$5" implementation_version="$6" extra_json="${7:-{}}"
  jq -n --arg platform "$platform" --arg os "$os_version" --arg package "$package_version" \
    --arg profile "$profile_digest" --arg binary "$binary_digest" --arg implementation "$implementation_version" \
    --arg now "$(date -u +%FT%TZ)" --argjson extra "$extra_json" \
    '{platform:$platform,os_version:$os,package_version:$package,profile_digest:$profile,
      knots_binary_digest:$binary,adapter_implementation_version:$implementation,
      last_validation_result:"ok",validated_at:$now} + $extra' |
    sudo tee /etc/bvml/adapter-verification.json >/dev/null
  sudo chmod 0600 /etc/bvml/adapter-verification.json
}
