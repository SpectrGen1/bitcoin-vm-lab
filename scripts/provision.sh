#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/common.sh"
command="${1:?provisioning command required}"; shift

fetch_to() {
  local source="$1" destination="$2" tmp="$destination.part"
  [[ "$source" == https://* ]] || die "download source must use HTTPS: $source"
  need curl
  rm -f -- "$tmp"
  curl -fL --retry 4 --continue-at - -o "$tmp" "$source" ||
    { rm -f -- "$tmp"; die "download failed: $source"; }
  mv -- "$tmp" "$destination"
}

copy_or_fetch() {
  local source="$1" destination="$2"
  [[ ! "$source" =~ [[:cntrl:]] ]] || die "source contains control characters"
  if [[ "$source" == https://* ]]; then
    fetch_to "$source" "$destination"
  else
    [[ "$source" == /* && -f "$source" ]] ||
      die "source must be an existing absolute path or HTTPS URL: $source"
    install -m 0644 "$source" "$destination"
  fi
}

media_fetch() {
  [[ "${1:-}" == ubuntu && $# == 1 ]] || die "usage: bvml media-fetch ubuntu"
  assert_provisioning_safe
  [[ "$UBUNTU_IMAGE_MODE" == cloud ]] ||
    die "media-fetch ubuntu requires UBUNTU_IMAGE_MODE=cloud"
  [[ "$UBUNTU_CLOUD_IMAGE" == /* && "$UBUNTU_CLOUD_IMAGE_URL" == https://* ]] ||
    die "configure absolute UBUNTU_CLOUD_IMAGE and HTTPS UBUNTU_CLOUD_IMAGE_URL"
  [[ "$UBUNTU_CLOUD_IMAGE_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] ||
    die "configure the pinned Ubuntu cloud image SHA-256"
  need qemu-img; need jq
  install -d -m 0755 "$BVML_MEDIA_DIR"
  if [[ -f "$UBUNTU_CLOUD_IMAGE" ]] &&
     [[ "$(sha256sum "$UBUNTU_CLOUD_IMAGE" | awk '{print $1}')" == "${UBUNTU_CLOUD_IMAGE_SHA256,,}" ]]; then
    chmod 0444 "$UBUNTU_CLOUD_IMAGE"
    note "verified Ubuntu cloud image already staged"
    return
  fi
  fetch_to "$UBUNTU_CLOUD_IMAGE_URL" "$UBUNTU_CLOUD_IMAGE"
  [[ "$(sha256sum "$UBUNTU_CLOUD_IMAGE" | awk '{print $1}')" == "${UBUNTU_CLOUD_IMAGE_SHA256,,}" ]] ||
    { mv -- "$UBUNTU_CLOUD_IMAGE" "$UBUNTU_CLOUD_IMAGE.rejected"; die "Ubuntu cloud image checksum mismatch; retained as .rejected"; }
  qemu-img info --output=json "$UBUNTU_CLOUD_IMAGE" | jq -e '.format == "qcow2"' >/dev/null ||
    die "Ubuntu cloud image is not qcow2"
  qemu-img check "$UBUNTU_CLOUD_IMAGE" >/dev/null || die "Ubuntu cloud image failed qemu-img check"
  chmod 0444 "$UBUNTU_CLOUD_IMAGE"
  note "staged verified Ubuntu cloud image at $UBUNTU_CLOUD_IMAGE"
}

profiles_install() {
  assert_provisioning_safe
  for value in KNOTS_VERSION_NORMALIZED KNOTS_ARTIFACT_SHA256 KNOTS_ARCHIVE_NAME \
    KNOTS_RELEASE_BASE_URL KNOTS_SHA256SUMS_SOURCE KNOTS_SHA256SUMS_ASC_SOURCE \
    KNOTS_SIGNING_KEY_SOURCE KNOTS_SIGNER_FINGERPRINT KNOTS_RDTS_PROFILE_NAME \
    KNOTS_RDTS_REQUIRED_ARGS_JSON; do
    [[ -n "${!value:-}" ]] || die "configure $value"
  done
  [[ "$KNOTS_ARTIFACT_SHA256" =~ ^[0-9a-fA-F]{64}$ &&
     "$KNOTS_SIGNER_FINGERPRINT" =~ ^[0-9A-Fa-f]{40,64}$ ]] ||
    die "artifact digest or signer fingerprint is malformed"
  need jq; need gpgv; need sha256sum
  [[ "$KNOTS_ARCHIVE_NAME" =~ ^[A-Za-z0-9._-]+$ &&
     "$KNOTS_VERSION_NORMALIZED" =~ ^[A-Za-z0-9._-]+$ &&
     "$KNOTS_RDTS_PROFILE_NAME" =~ ^[A-Za-z0-9._-]+$ &&
     "$KNOTS_RELEASE_BASE_URL" == https://* &&
     ! "$KNOTS_RELEASE_BASE_URL" =~ [[:cntrl:]\'] ]] ||
    die "unsafe archive name or non-HTTPS release URL"
  jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and
    test("^-[A-Za-z0-9][A-Za-z0-9-]*=[A-Za-z0-9._:/,+-]+$")) and
    (map(split("=")[0]) | length == (unique | length))' \
    <<<"$KNOTS_RDTS_REQUIRED_ARGS_JSON" >/dev/null ||
    die "RDTS arguments must be a nonempty unique JSON option=value array"

  local work status listed release rdts release_digest rdts_digest
  work="$(mktemp -d)"
  copy_or_fetch "$KNOTS_SHA256SUMS_SOURCE" "$work/SHA256SUMS"
  copy_or_fetch "$KNOTS_SHA256SUMS_ASC_SOURCE" "$work/SHA256SUMS.asc"
  copy_or_fetch "$KNOTS_SIGNING_KEY_SOURCE" "$work/signing-key.gpg"
  status="$(gpgv --status-fd 1 --keyring "$work/signing-key.gpg" \
    "$work/SHA256SUMS.asc" "$work/SHA256SUMS" 2>/dev/null || true)"
  grep -q "VALIDSIG ${KNOTS_SIGNER_FINGERPRINT^^} " <<<"${status^^}" ||
    die "signed release metadata lacks the configured signer VALIDSIG"
  listed="$(awk -v file="$KNOTS_ARCHIVE_NAME" '$2 == file || $2 == "*" file {print tolower($1)}' \
    "$work/SHA256SUMS")"
  [[ "$listed" == "${KNOTS_ARTIFACT_SHA256,,}" ]] ||
    die "authenticated metadata does not bind the archive to the configured digest"

  release="$work/knots-version.env"; rdts="$work/knots-rdts.env"
  printf '%s\n' \
    "KNOTS_VERSION_NORMALIZED=$KNOTS_VERSION_NORMALIZED" \
    "KNOTS_ARCHIVE_NAME=$KNOTS_ARCHIVE_NAME" \
    "KNOTS_RELEASE_BASE_URL=$KNOTS_RELEASE_BASE_URL" \
    "KNOTS_ARTIFACT_SHA256=${KNOTS_ARTIFACT_SHA256,,}" \
    'KNOTS_SHA256SUMS=/etc/bvml/releases/SHA256SUMS' \
    'KNOTS_SHA256SUMS_ASC=/etc/bvml/releases/SHA256SUMS.asc' \
    'KNOTS_SIGNING_KEY=/etc/bvml/releases/signing-key.gpg' \
    "KNOTS_SIGNER_FINGERPRINT=${KNOTS_SIGNER_FINGERPRINT^^}" >"$release"
  printf '%s\n' \
    "RDTS_PROFILE_NAME=$KNOTS_RDTS_PROFILE_NAME" \
    "RDTS_PROFILE_KNOTS_VERSION_NORMALIZED=$KNOTS_VERSION_NORMALIZED" \
    "RDTS_REQUIRED_ARGS_JSON='$KNOTS_RDTS_REQUIRED_ARGS_JSON'" >"$rdts"
  release_digest="$(sha256sum "$release" | awk '{print $1}')"
  rdts_digest="$(sha256sum "$rdts" | awk '{print $1}')"

  if [[ "${BVML_TESTING:-0}" == 1 ]]; then
    install -d -m 0755 "$BVML_HOST_CONFIG_DIR/releases"
    install -m 0644 "$release" "$BVML_HOST_CONFIG_DIR/releases/knots-version.env"
    install -m 0644 "$rdts" "$BVML_HOST_CONFIG_DIR/releases/knots-rdts.env"
    install -m 0644 "$work/SHA256SUMS" "$BVML_HOST_CONFIG_DIR/releases/SHA256SUMS"
    install -m 0644 "$work/SHA256SUMS.asc" "$BVML_HOST_CONFIG_DIR/releases/SHA256SUMS.asc"
    install -m 0644 "$work/signing-key.gpg" "$BVML_HOST_CONFIG_DIR/releases/signing-key.gpg"
    install -m 0644 "$CHECKPOINT_PROFILE_FILE" "$BVML_HOST_CONFIG_DIR/checkpoint-profile.json"
  else
    sudo install -d -o root -g root -m 0755 "$BVML_HOST_CONFIG_DIR/releases"
    sudo install -o root -g root -m 0644 "$release" "$BVML_HOST_CONFIG_DIR/releases/knots-version.env"
    sudo install -o root -g root -m 0644 "$rdts" "$BVML_HOST_CONFIG_DIR/releases/knots-rdts.env"
    sudo install -o root -g root -m 0644 "$work/SHA256SUMS" "$BVML_HOST_CONFIG_DIR/releases/SHA256SUMS"
    sudo install -o root -g root -m 0644 "$work/SHA256SUMS.asc" "$BVML_HOST_CONFIG_DIR/releases/SHA256SUMS.asc"
    sudo install -o root -g root -m 0644 "$work/signing-key.gpg" "$BVML_HOST_CONFIG_DIR/releases/signing-key.gpg"
    sudo install -o root -g root -m 0644 "$CHECKPOINT_PROFILE_FILE" "$BVML_HOST_CONFIG_DIR/checkpoint-profile.json"
  fi
  local host_env="$work/host.env"
  printf '%s\n' \
    'KNOTS_RELEASE_PROFILE=/etc/bvml/releases/knots-version.env' \
    "KNOTS_RELEASE_PROFILE_SHA256=$release_digest" \
    'KNOTS_RDTS_PROFILE=/etc/bvml/releases/knots-rdts.env' \
    "KNOTS_RDTS_PROFILE_SHA256=$rdts_digest" \
    "KNOTS_VERSION_NORMALIZED=$KNOTS_VERSION_NORMALIZED" \
    "KNOTS_ARTIFACT_SHA256=${KNOTS_ARTIFACT_SHA256,,}" \
    "KNOTS_RDTS_PROFILE_NAME=$KNOTS_RDTS_PROFILE_NAME" \
    "KNOTS_RDTS_REQUIRED_ARGS_JSON='$KNOTS_RDTS_REQUIRED_ARGS_JSON'" >"$host_env"
  if [[ "${BVML_TESTING:-0}" == 1 ]]; then
    install -m 0644 "$host_env" "$BVML_HOST_CONFIG_DIR/host.env"
  else
    sudo install -o root -g root -m 0644 "$host_env" "$BVML_HOST_CONFIG_DIR/host.env"
  fi
  note "installed authenticated root-owned Knots/RDTS profiles"
}

storage_prepare() {
  assert_provisioning_safe
  init_layout
  local path="$BVML_STORAGE" parent
  while [[ "$path" != / ]]; do
    parent="$(dirname "$path")"
    sudo -u "$QEMU_USER" test -x "$parent" ||
      setfacl -m "u:$QEMU_USER:--x" "$parent"
    path="$parent"
  done
  sudo -u "$QEMU_USER" test -x "$BVML_STORAGE" ||
    die "system QEMU cannot traverse $BVML_STORAGE"
  local available required
  available="$(df -B1 --output=avail "$BVML_STORAGE" | tail -1 | tr -d ' ')"
  required=$((BOOTSTRAP_SIZE_GIB * 1073741824))
  (( available >= required )) ||
    die "storage has $available bytes free; bootstrap virtual capacity is $required bytes"
  note "storage initialized with verified system-QEMU traversal and bootstrap capacity"
}

guest_provision() {
  [[ "${1:-}" == ubuntu && $# == 1 ]] || die "usage: bvml guest-provision ubuntu"
  assert_no_bitcoin_lifecycle
  is_defined ubuntu || die "Ubuntu VM is not defined"
  [[ "$(domain_state ubuntu)" == running ]] || die "Ubuntu must be exactly running for QGA provisioning"
  [[ "$UBUNTU_CLOUD_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] ||
    die "UBUNTU_CLOUD_USER is not a safe guest account name"
  local vm
  for vm in umbrel startos; do
    is_defined "$vm" || continue
    is_shut_off "$vm" || die "$(domain "$vm") must be exactly shut off"
  done
  for file in "$BVML_HOST_CONFIG_DIR"/releases/knots-version.env "$BVML_HOST_CONFIG_DIR"/releases/knots-rdts.env \
    "$BVML_HOST_CONFIG_DIR"/releases/SHA256SUMS "$BVML_HOST_CONFIG_DIR"/releases/SHA256SUMS.asc \
    "$BVML_HOST_CONFIG_DIR"/releases/signing-key.gpg "$BVML_HOST_CONFIG_DIR"/checkpoint-profile.json; do
    [[ -f "$file" ]] || die "profiles-install has not supplied $file"
  done
  local guest_conf script64 conf64 release64 rdts64 sums64 asc64 key64 checkpoint64
  guest_conf="$(mktemp)"
  printf '%s\n' \
    'BITCOIN_MOUNT=/srv/bitcoin' 'BITCOIN_DEVICE=/dev/vdc' \
    "BITCOIN_SERVICE_USER=$UBUNTU_CLOUD_USER" "BITCOIN_SERVICE_GROUP=$UBUNTU_CLOUD_USER" \
    "MAX_TIP_AGE_SECONDS=$MAX_TIP_AGE_SECONDS" \
    'KNOTS_RELEASE_PROFILE=/etc/bvml/releases/knots-version.env' \
    "KNOTS_RELEASE_PROFILE_SHA256=$KNOTS_RELEASE_PROFILE_SHA256" \
    'KNOTS_RDTS_PROFILE=/etc/bvml/releases/knots-rdts.env' \
    "KNOTS_RDTS_PROFILE_SHA256=$KNOTS_RDTS_PROFILE_SHA256" \
    'CHECKPOINT_PROFILE_FILE=/etc/bvml/checkpoint-profile.json' \
    "CHECKPOINT_PROFILE_SHA256=$CHECKPOINT_PROFILE_SHA256" >"$guest_conf"
  script64="$(base64 -w0 "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh")"
  conf64="$(base64 -w0 "$guest_conf")"
  release64="$(base64 -w0 "$BVML_HOST_CONFIG_DIR/releases/knots-version.env")"
  rdts64="$(base64 -w0 "$BVML_HOST_CONFIG_DIR/releases/knots-rdts.env")"
  sums64="$(base64 -w0 "$BVML_HOST_CONFIG_DIR/releases/SHA256SUMS")"
  asc64="$(base64 -w0 "$BVML_HOST_CONFIG_DIR/releases/SHA256SUMS.asc")"
  key64="$(base64 -w0 "$BVML_HOST_CONFIG_DIR/releases/signing-key.gpg")"
  checkpoint64="$(base64 -w0 "$BVML_HOST_CONFIG_DIR/checkpoint-profile.json")"
  guest_exec_sync ubuntu /bin/bash "$GUEST_EXEC_TIMEOUT" -c "
    install -d -o root -g root -m 0755 /usr/local/libexec/bvml /etc/bvml/releases
    printf %s '$script64' | base64 -d > /usr/local/libexec/bvml/ubuntu-knots-rdts.sh
    printf %s '$conf64' | base64 -d > /etc/bvml/knots.env
    printf %s '$release64' | base64 -d > /etc/bvml/releases/knots-version.env
    printf %s '$rdts64' | base64 -d > /etc/bvml/releases/knots-rdts.env
    printf %s '$sums64' | base64 -d > /etc/bvml/releases/SHA256SUMS
    printf %s '$asc64' | base64 -d > /etc/bvml/releases/SHA256SUMS.asc
    printf %s '$key64' | base64 -d > /etc/bvml/releases/signing-key.gpg
    printf %s '$checkpoint64' | base64 -d > /etc/bvml/checkpoint-profile.json
    chown -R root:root /etc/bvml /usr/local/libexec/bvml
    chmod 0755 /usr/local/libexec/bvml/ubuntu-knots-rdts.sh
    chmod 0644 /etc/bvml/knots.env /etc/bvml/checkpoint-profile.json /etc/bvml/releases/*
  "
  note "provisioned Ubuntu guest assets through synchronous QGA execution"
}

case "$command" in
  media-fetch) with_lock media_fetch "$@" ;;
  profiles-install) with_lock profiles_install "$@" ;;
  storage-prepare) with_lock storage_prepare "$@" ;;
  guest-provision) with_lock guest_provision "$@" ;;
  *) die "unsupported provisioning command: $command" ;;
esac
