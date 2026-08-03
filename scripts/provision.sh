#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/common.sh"
command="${1:?provisioning command required}"; shift

fetch_to() {
  local source="$1" destination="$2" tmp
  tmp="$destination.part"
  [[ "$source" == https://* ]] || die "download source must use HTTPS: $source"
  need curl
  rm -f -- "$tmp"
  curl -fL --proto '=https' --proto-redir '=https' --retry 4 -o "$tmp" "$source" ||
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
  [[ $# == 1 ]] || die "usage: bvml media-fetch {ubuntu|umbrel}"
  if [[ "$1" == umbrel ]]; then
    media_fetch_umbrel
    return
  fi
  [[ "$1" == ubuntu ]] || die "usage: bvml media-fetch {ubuntu|umbrel}"
  assert_provisioning_safe
  [[ "$UBUNTU_IMAGE_MODE" == cloud ]] ||
    die "media-fetch ubuntu requires UBUNTU_IMAGE_MODE=cloud"
  [[ "$UBUNTU_CLOUD_IMAGE" == /* && "$UBUNTU_CLOUD_IMAGE_URL" == https://* ]] ||
    die "configure absolute UBUNTU_CLOUD_IMAGE and HTTPS UBUNTU_CLOUD_IMAGE_URL"
  [[ "$UBUNTU_CLOUD_IMAGE_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] ||
    die "configure the pinned Ubuntu cloud image SHA-256"
  need qemu-img; need jq
  install -d -m 0755 "$BVML_MEDIA_DIR"
  if [[ -f "$UBUNTU_CLOUD_IMAGE" ]]; then
    validate_cloud_image "$UBUNTU_CLOUD_IMAGE" "$UBUNTU_CLOUD_IMAGE_SHA256"
    note "verified Ubuntu cloud image already staged"
    return
  fi
  fetch_to "$UBUNTU_CLOUD_IMAGE_URL" "$UBUNTU_CLOUD_IMAGE"
  validate_cloud_image "$UBUNTU_CLOUD_IMAGE" "$UBUNTU_CLOUD_IMAGE_SHA256"
  note "staged verified Ubuntu cloud image at $UBUNTU_CLOUD_IMAGE"
}

validate_umbrel_profile() {
  [[ "$UMBREL_PROFILE" == /* && -f "$UMBREL_PROFILE" &&
     "$UMBREL_PROFILE_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] ||
    die "configure an absolute digest-pinned UMBREL_PROFILE"
  [[ "$(sha256sum "$UMBREL_PROFILE" | awk '{print $1}')" == "${UMBREL_PROFILE_SHA256,,}" ]] ||
    die "Umbrel profile digest mismatch"
  jq -e '
    .profile_version==1 and (.os.installer_url|startswith("https://"))
  ' "$UMBREL_PROFILE" >/dev/null || die "Umbrel profile is malformed"
  [[ "$(jq -r .os.installer_sha256 "$UMBREL_PROFILE")" == "${UMBREL_ISO_SHA256,,}" ]] ||
    die "configured Umbrel installer digest differs from the profile"
}

validate_umbrel_media() {
  local image="$1" expected="$2" actual label info
  actual="$(sha256sum "$image" | awk '{print $1}')"
  [[ "$actual" == "${expected,,}" ]] || return 1
  [[ "$(stat -c %s "$image")" == "$(jq -r .os.installer_size "$UMBREL_PROFILE")" ]] || return 1
  file "$image" | grep -qi 'ISO 9660' || return 1
  label="$(xorriso -indev "$image" -pvd_info 2>&1 |
    sed -n "s/^Volume id[[:space:]]*:[[:space:]]*'\\(.*\\)'/\\1/p")"
  [[ "$label" == "$(jq -r .os.iso_label "$UMBREL_PROFILE")" ]] || return 1
  info="$(xorriso -indev "$image" -report_el_torito plain 2>&1)"
  grep -qi 'boot' <<<"$info" || return 1
}

media_fetch_umbrel() {
  assert_provisioning_safe
  validate_umbrel_profile
  need xorriso; need file; need sha256sum
  install -d -m 0755 "$BVML_MEDIA_DIR" "$BVML_MEDIA_DIR/quarantine"
  local url staged="$UMBREL_ISO" quarantine
  url="$(jq -r .os.installer_url "$UMBREL_PROFILE")"
  [[ "$url" == https://* ]] || die "Umbrel installer URL must use HTTPS"
  if [[ ! -f "$staged" ]]; then fetch_to "$url" "$staged"; fi
  if ! validate_umbrel_media "$staged" "$UMBREL_ISO_SHA256"; then
    quarantine="$BVML_MEDIA_DIR/quarantine/$(basename "$staged").$(date -u +%Y%m%dT%H%M%SZ)"
    mv -- "$staged" "$quarantine"
    die "Umbrel media failed digest/ISO/boot validation and was quarantined at $quarantine"
  fi
  [[ "$(stat -c %a "$staged")" == 444 ]] || chmod 0444 "$staged"
  local manifest_tmp
  manifest_tmp="$(mktemp "$BVML_MEDIA_DIR/.umbrel-media-manifest.XXXXXX")"
  jq -n --arg profile "${UMBREL_PROFILE_SHA256,,}" \
    --arg profile_id "$(jq -r .profile_id "$UMBREL_PROFILE")" \
    --arg installer_commit "$(jq -r .os.installer_source_commit "$UMBREL_PROFILE")" \
    --arg sha "${UMBREL_ISO_SHA256,,}" \
    --arg path "$staged" --arg now "$(date -u +%FT%TZ)" \
    '{platform:"umbrel",profile_id:$profile_id,profile_digest:$profile,
      installer_source_commit:$installer_commit,sha256:$sha,path:$path,verified_at:$now}' \
    >"$manifest_tmp"
  chmod 0444 "$manifest_tmp"
  mv -f -- "$manifest_tmp" "$staged.manifest.json"
  note "staged structurally validated, profile-bound UmbrelOS installer"
}

assert_profile_mutation_safe() {
  assert_provisioning_safe
  local path
  for path in "$CANONICAL" "$CANONICAL_META" "$BOOTSTRAP" "$BOOTSTRAP_META" \
    "$BOOTSTRAP_VERIFY" "$OVERLAY" "$OVERLAY_META" "$VERIFY_META" \
    "$IMPORT_CANDIDATE" "$IMPORT_META" "$OWNER_FILE" "$RECOVERY_META"; do
    [[ ! -e "$path" ]] ||
      die "profile replacement is blocked by checkpoint/lifecycle state: $path; use an explicit profile migration"
  done
}

profiles_install() {
  assert_profile_mutation_safe
  for value in KNOTS_VERSION_NORMALIZED KNOTS_ARTIFACT_SHA256 KNOTS_ARCHIVE_NAME \
    KNOTS_RELEASE_BASE_URL KNOTS_SHA256SUMS_SOURCE KNOTS_SHA256SUMS_ASC_SOURCE \
    KNOTS_SIGNING_KEY_SOURCE KNOTS_SIGNER_FINGERPRINT KNOTS_RDTS_PROFILE_NAME \
    KNOTS_RDTS_REQUIRED_ARGS_JSON; do
    [[ -n "${!value:-}" ]] || die "configure $value"
  done
  [[ "$KNOTS_ARTIFACT_SHA256" =~ ^[0-9a-fA-F]{64}$ &&
     "$KNOTS_SIGNER_FINGERPRINT" =~ ^[0-9A-Fa-f]{40,64}$ ]] ||
    die "artifact digest or signer fingerprint is malformed"
  need jq; need gpg; need gpgv; need sha256sum
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

  local work status listed release rdts release_digest rdts_digest keyring fingerprint
  work="$(mktemp -d)"
  trap "rm -rf -- '$work'" RETURN
  copy_or_fetch "$KNOTS_SHA256SUMS_SOURCE" "$work/SHA256SUMS"
  copy_or_fetch "$KNOTS_SHA256SUMS_ASC_SOURCE" "$work/SHA256SUMS.asc"
  copy_or_fetch "$KNOTS_SIGNING_KEY_SOURCE" "$work/signing-key.input"
  install -d -m 0700 "$work/gnupg"
  gpg --batch --homedir "$work/gnupg" --import "$work/signing-key.input" >/dev/null 2>&1 ||
    die "trusted signing key import failed"
  fingerprint="$(gpg --batch --homedir "$work/gnupg" --with-colons --fingerprint |
    awk -F: '$1 == "fpr" {print toupper($10)}')"
  grep -qx "${KNOTS_SIGNER_FINGERPRINT^^}" <<<"$fingerprint" ||
    die "imported key material lacks the configured signer fingerprint"
  keyring="$work/trusted-signers.gpg"
  gpg --batch --homedir "$work/gnupg" --export >"$keyring"
  status="$(gpgv --status-fd 1 --keyring "$keyring" \
    "$work/SHA256SUMS.asc" "$work/SHA256SUMS" 2>/dev/null || true)"
  grep -q "VALIDSIG ${KNOTS_SIGNER_FINGERPRINT^^} " <<<"${status^^}" ||
    die "signed release metadata lacks the configured signer VALIDSIG"
  listed="$(awk -v file="$KNOTS_ARCHIVE_NAME" '$2 == file || $2 == "*" file {print tolower($1)}' \
    "$work/SHA256SUMS")"
  [[ "$listed" == "${KNOTS_ARTIFACT_SHA256,,}" ]] ||
    die "authenticated metadata does not bind the archive to the configured digest"

  release="$work/knots-version.env"; rdts="$work/knots-rdts.env"
  printf 'KNOTS_VERSION_NORMALIZED=%q\nKNOTS_ARCHIVE_NAME=%q\nKNOTS_RELEASE_BASE_URL=%q\nKNOTS_ARTIFACT_SHA256=%q\nKNOTS_SHA256SUMS=%q\nKNOTS_SHA256SUMS_ASC=%q\nKNOTS_SIGNING_KEY=%q\nKNOTS_SIGNER_FINGERPRINT=%q\n' \
    "$KNOTS_VERSION_NORMALIZED" "$KNOTS_ARCHIVE_NAME" "$KNOTS_RELEASE_BASE_URL" \
    "${KNOTS_ARTIFACT_SHA256,,}" /etc/bvml/releases/SHA256SUMS \
    /etc/bvml/releases/SHA256SUMS.asc /etc/bvml/releases/trusted-signers.gpg \
    "${KNOTS_SIGNER_FINGERPRINT^^}" >"$release"
  printf 'RDTS_PROFILE_NAME=%q\nRDTS_PROFILE_KNOTS_VERSION_NORMALIZED=%q\nRDTS_REQUIRED_ARGS_JSON=%q\n' \
    "$KNOTS_RDTS_PROFILE_NAME" "$KNOTS_VERSION_NORMALIZED" \
    "$KNOTS_RDTS_REQUIRED_ARGS_JSON" >"$rdts"
  release_digest="$(sha256sum "$release" | awk '{print $1}')"
  rdts_digest="$(sha256sum "$rdts" | awk '{print $1}')"
  [[ -f "$CHECKPOINT_PROFILE_SOURCE" ]] || die "checkpoint profile source is missing"
  [[ "$(sha256sum "$CHECKPOINT_PROFILE_SOURCE" | awk '{print $1}')" == "${CHECKPOINT_PROFILE_SHA256,,}" ]] ||
    die "checkpoint profile source digest mismatch"
  local generation_id generation_digest stage generations active_new
  generation_id="$(new_id)"
  generation_digest="$(printf '%s\n' "release=$release_digest" "rdts=$rdts_digest" \
    "checkpoint=${CHECKPOINT_PROFILE_SHA256,,}" | sha256sum | awk '{print $1}')"
  stage="$work/generation"; install -d -m 0755 "$stage/releases"
  install -m 0644 "$release" "$stage/releases/knots-version.env"
  install -m 0644 "$rdts" "$stage/releases/knots-rdts.env"
  install -m 0644 "$work/SHA256SUMS" "$stage/releases/SHA256SUMS"
  install -m 0644 "$work/SHA256SUMS.asc" "$stage/releases/SHA256SUMS.asc"
  install -m 0644 "$keyring" "$stage/releases/trusted-signers.gpg"
  install -m 0644 "$CHECKPOINT_PROFILE_SOURCE" "$stage/checkpoint-profile.json"
  jq -cn --arg id "$generation_id" --arg digest "$generation_digest" \
    --arg release "$release_digest" --arg rdts "$rdts_digest" \
    --arg checkpoint "${CHECKPOINT_PROFILE_SHA256,,}" \
    '{generation_id:$id,generation_digest:$digest,release_profile_sha256:$release,
      rdts_profile_sha256:$rdts,checkpoint_profile_sha256:$checkpoint}' \
    >"$stage/generation.json"
  generations="$BVML_HOST_CONFIG_DIR/generations"
  if [[ "${BVML_TESTING:-0}" == 1 ]]; then
    install -d -m 0755 "$generations"
    cp -a "$stage" "$generations/$generation_id"
    active_new="$BVML_HOST_CONFIG_DIR/.active.new"
    ln -s "generations/$generation_id" "$active_new"
    mv -Tf -- "$active_new" "$BVML_HOST_CONFIG_DIR/active"
  else
    sudo install -d -o root -g root -m 0755 "$BVML_HOST_CONFIG_DIR" "$generations"
    sudo cp -a "$stage" "$generations/$generation_id"
    sudo chown -R root:root "$generations/$generation_id"
    active_new="$BVML_HOST_CONFIG_DIR/.active.new"
    sudo ln -s "generations/$generation_id" "$active_new"
    sudo mv -Tf -- "$active_new" "$BVML_HOST_CONFIG_DIR/active"
  fi
  local host_env="$work/host.env"
  printf 'KNOTS_RELEASE_PROFILE=%q\nKNOTS_RELEASE_PROFILE_SHA256=%q\nKNOTS_RDTS_PROFILE=%q\nKNOTS_RDTS_PROFILE_SHA256=%q\nKNOTS_VERSION_NORMALIZED=%q\nKNOTS_ARTIFACT_SHA256=%q\nKNOTS_RDTS_PROFILE_NAME=%q\nKNOTS_RDTS_REQUIRED_ARGS_JSON=%q\nCHECKPOINT_PROFILE_FILE=%q\nCHECKPOINT_PROFILE_SHA256=%q\nPROFILE_GENERATION_ID=%q\nPROFILE_GENERATION_DIGEST=%q\n' \
    "$BVML_HOST_CONFIG_DIR/active/releases/knots-version.env" \
    "$release_digest" \
    "$BVML_HOST_CONFIG_DIR/active/releases/knots-rdts.env" "$rdts_digest" \
    "$KNOTS_VERSION_NORMALIZED" "${KNOTS_ARTIFACT_SHA256,,}" \
    "$KNOTS_RDTS_PROFILE_NAME" "$KNOTS_RDTS_REQUIRED_ARGS_JSON" \
    "$BVML_HOST_CONFIG_DIR/active/checkpoint-profile.json" "${CHECKPOINT_PROFILE_SHA256,,}" \
    "$generation_id" "$generation_digest" >"$host_env"
  if [[ "${BVML_TESTING:-0}" == 1 ]]; then
    install -m 0644 "$host_env" "$BVML_HOST_CONFIG_DIR/host.env"
  else
    sudo install -o root -g root -m 0644 "$host_env" "$BVML_HOST_CONFIG_DIR/host.env"
  fi
  trap - RETURN
  rm -rf -- "$work"
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
  [[ $# == 1 ]] || die "usage: bvml guest-provision {ubuntu|umbrel}"
  if [[ "$1" == umbrel ]]; then
    guest_provision_umbrel
    return
  fi
  [[ "$1" == ubuntu ]] || die "usage: bvml guest-provision {ubuntu|umbrel}"
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
  local profile_release_dir; profile_release_dir="$(dirname "$KNOTS_RELEASE_PROFILE")"
  for file in "$KNOTS_RELEASE_PROFILE" "$KNOTS_RDTS_PROFILE" \
    "$profile_release_dir/SHA256SUMS" "$profile_release_dir/SHA256SUMS.asc" \
    "$profile_release_dir/trusted-signers.gpg" "$CHECKPOINT_PROFILE_FILE"; do
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
  release64="$(base64 -w0 "$KNOTS_RELEASE_PROFILE")"
  rdts64="$(base64 -w0 "$KNOTS_RDTS_PROFILE")"
  sums64="$(base64 -w0 "$profile_release_dir/SHA256SUMS")"
  asc64="$(base64 -w0 "$profile_release_dir/SHA256SUMS.asc")"
  key64="$(base64 -w0 "$profile_release_dir/trusted-signers.gpg")"
  checkpoint64="$(base64 -w0 "$CHECKPOINT_PROFILE_FILE")"
  guest_exec_sync ubuntu /bin/bash "$GUEST_EXEC_TIMEOUT" -c "
    install -d -o root -g root -m 0755 /usr/local/libexec/bvml /etc/bvml/releases
    printf %s '$script64' | base64 -d > /usr/local/libexec/bvml/ubuntu-knots-rdts.sh
    printf %s '$conf64' | base64 -d > /etc/bvml/knots.env
    printf %s '$release64' | base64 -d > /etc/bvml/releases/knots-version.env
    printf %s '$rdts64' | base64 -d > /etc/bvml/releases/knots-rdts.env
    printf %s '$sums64' | base64 -d > /etc/bvml/releases/SHA256SUMS
    printf %s '$asc64' | base64 -d > /etc/bvml/releases/SHA256SUMS.asc
    printf %s '$key64' | base64 -d > /etc/bvml/releases/trusted-signers.gpg
    printf %s '$checkpoint64' | base64 -d > /etc/bvml/checkpoint-profile.json
    chown -R root:root /etc/bvml /usr/local/libexec/bvml
    chmod 0755 /usr/local/libexec/bvml/ubuntu-knots-rdts.sh
    chmod 0644 /etc/bvml/knots.env /etc/bvml/checkpoint-profile.json /etc/bvml/releases/*
  "
  note "provisioned Ubuntu guest assets through synchronous QGA execution"
}

guest_provision_umbrel() {
  assert_no_bitcoin_lifecycle
  validate_umbrel_profile
  is_defined umbrel || die "Umbrel VM is not defined"
  [[ "$(domain_state umbrel)" == running ]] || die "Umbrel must be exactly running"
  local other
  for other in ubuntu startos; do
    is_defined "$other" || continue
    is_shut_off "$other" || die "$(domain "$other") must be exactly shut off"
  done
  bash -n "$ROOT/scripts/vm/guest/umbrel-adapter.sh" \
    "$ROOT/scripts/vm/guest/adapter-common.sh" ||
    die "Umbrel guest adapter assets fail shell syntax validation"
  local profile64 digest64 adapter64 common64 active_stub64 guest_root guest_bvml
  guest_root="$(jq -er '.os.data_directory | select(startswith("/"))' "$UMBREL_PROFILE")" ||
    die "Umbrel profile lacks an absolute persistent data directory"
  [[ ! "$guest_root" =~ [[:cntrl:]] ]] || die "unsafe Umbrel persistent data directory"
  guest_bvml="$guest_root/.bvml"
  profile64="$(base64 -w0 "$UMBREL_PROFILE")"
  digest64="$(printf '%s\n' "${UMBREL_PROFILE_SHA256,,}" | base64 -w0)"
  adapter64="$(base64 -w0 "$ROOT/scripts/vm/guest/umbrel-adapter.sh")"
  common64="$(base64 -w0 "$ROOT/scripts/vm/guest/adapter-common.sh")"
  active_stub64="$(printf '{}\n' | base64 -w0)"
  umbrel_exec_sync /bin/bash "$GUEST_EXEC_TIMEOUT" -c "
    install -d -o root -g root -m 0755 '$guest_bvml/etc' '$guest_bvml/bin'
    printf %s '$profile64' | base64 -d > '$guest_bvml/etc/umbrel-profile.json'
    printf %s '$digest64' | base64 -d > '$guest_bvml/etc/umbrel-profile.sha256'
    printf %s '$adapter64' | base64 -d > '$guest_bvml/bin/umbrel-adapter.sh'
    printf %s '$common64' | base64 -d > '$guest_bvml/bin/adapter-common.sh'
    printf %s '$active_stub64' | base64 -d > '$guest_bvml/etc/active-overlay.json'
    chown -R root:root '$guest_bvml'
    chmod 0644 '$guest_bvml/etc/umbrel-profile.json' '$guest_bvml/etc/umbrel-profile.sha256'
    chmod 0600 '$guest_bvml/etc/active-overlay.json'
    chmod 0755 '$guest_bvml/bin/umbrel-adapter.sh' '$guest_bvml/bin/adapter-common.sh'
  "
  umbrel_exec_sync "$guest_bvml/bin/umbrel-adapter.sh" "$UMBREL_OPERATION_TIMEOUT" install-app
  install -d -m 0750 "$ADAPTER_STATE_DIR"
  jq -n --arg platform umbrel --arg profile "${UMBREL_PROFILE_SHA256,,}" \
    --arg os "$(jq -r .os.version "$UMBREL_PROFILE")" \
    --arg package "$(jq -r .app_store.app_version "$UMBREL_PROFILE")" \
    --arg implementation "$(jq -r .adapter_implementation_version "$UMBREL_PROFILE")" \
    --arg now "$(date -u +%FT%TZ)" \
    '{platform:$platform,os_version:$os,package_version:$package,
      profile_digest:$profile,adapter_implementation_version:$implementation,
      provisioning_result:"ok",provisioned_at:$now,last_validation_result:"pending-overlay"}' \
    >"$ADAPTER_STATE_DIR/umbrel.json"
  chmod 0600 "$ADAPTER_STATE_DIR/umbrel.json"
  note "installed and stopped the pinned official bitcoin-knots app through umbreld"
}

guest_repair_scripts() {
  [[ "${2:-}" == --scripts-only && $# == 2 ]] ||
    die "usage: bvml guest-repair {ubuntu|umbrel} --scripts-only"
  if [[ "$1" == umbrel ]]; then
    is_defined umbrel || die "Umbrel VM is not defined"
    [[ "$(domain_state umbrel)" == running ]] || die "Umbrel must be exactly running"
    bash -n "$ROOT/scripts/vm/guest/umbrel-adapter.sh" \
      "$ROOT/scripts/vm/guest/adapter-common.sh" ||
      die "Umbrel guest adapter assets fail shell syntax validation"
    local guest_bvml adapter64 common64
    guest_bvml="$(jq -er '.os.data_directory | select(startswith("/"))' "$UMBREL_PROFILE")/.bvml" ||
      die "Umbrel profile lacks an absolute persistent data directory"
    umbrel_exec_sync /bin/bash 60 -c "
      test \"\$(sha256sum '$guest_bvml/etc/umbrel-profile.json' | awk '{print \$1}')\" = '${UMBREL_PROFILE_SHA256,,}'
      test \"\$(tr -d '[:space:]' <'$guest_bvml/etc/umbrel-profile.sha256')\" = '${UMBREL_PROFILE_SHA256,,}'
    " || die "Umbrel script repair refused because the installed profile digest changed"
    adapter64="$(base64 -w0 "$ROOT/scripts/vm/guest/umbrel-adapter.sh")"
    common64="$(base64 -w0 "$ROOT/scripts/vm/guest/adapter-common.sh")"
    umbrel_exec_sync /bin/bash 60 -c "
      set -Eeuo pipefail
      a=\$(mktemp '$guest_bvml/bin/umbrel-adapter.sh.XXXXXX')
      c=\$(mktemp '$guest_bvml/bin/adapter-common.sh.XXXXXX')
      trap 'rm -f -- \"\$a\" \"\$c\"' EXIT
      printf %s '$adapter64' | base64 -d >\"\$a\"
      printf %s '$common64' | base64 -d >\"\$c\"
      chown root:root \"\$a\" \"\$c\"; chmod 0755 \"\$a\" \"\$c\"
      bash -n \"\$a\" \"\$c\"
      mv -f -- \"\$a\" '$guest_bvml/bin/umbrel-adapter.sh'
      mv -f -- \"\$c\" '$guest_bvml/bin/adapter-common.sh'
      trap - EXIT
    "
    note "updated persistent Umbrel adapter scripts after proving its profile digest is unchanged"
    return
  fi
  [[ "$1" == ubuntu ]] || die "usage: bvml guest-repair {ubuntu|umbrel} --scripts-only"
  is_defined ubuntu || die "Ubuntu VM is not defined"
  [[ "$(domain_state ubuntu)" == running ]] || die "Ubuntu must be exactly running"
  local vm
  for vm in umbrel startos; do
    is_defined "$vm" || continue
    is_shut_off "$vm" || die "$(domain "$vm") must be exactly shut off"
  done
  validate_profile_generation
  guest_exec_sync ubuntu /bin/bash 60 -lc "
    set -Eeuo pipefail
    test \"\$(sha256sum /etc/bvml/releases/knots-version.env | awk '{print \$1}')\" = '${KNOTS_RELEASE_PROFILE_SHA256,,}'
    test \"\$(sha256sum /etc/bvml/releases/knots-rdts.env | awk '{print \$1}')\" = '${KNOTS_RDTS_PROFILE_SHA256,,}'
    test \"\$(sha256sum /etc/bvml/checkpoint-profile.json | awk '{print \$1}')\" = '${CHECKPOINT_PROFILE_SHA256,,}'
  "
  local script64
  script64="$(base64 -w0 "$ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh")"
  guest_exec_sync ubuntu /bin/bash 60 -lc "
    set -Eeuo pipefail
    tmp=\$(mktemp /usr/local/libexec/bvml/ubuntu-knots-rdts.sh.XXXXXX)
    trap 'rm -f -- \"\$tmp\"' EXIT
    printf %s '$script64' | base64 -d >\"\$tmp\"
    chown root:root \"\$tmp\"
    chmod 0755 \"\$tmp\"
    bash -n \"\$tmp\"
    mv -f -- \"\$tmp\" /usr/local/libexec/bvml/ubuntu-knots-rdts.sh
  "
  note "updated Ubuntu lifecycle script after proving guest profile digests are unchanged"
}

case "$command" in
  media-fetch) with_lock media_fetch "$@" ;;
  profiles-install) with_lock profiles_install "$@" ;;
  storage-prepare) with_lock storage_prepare "$@" ;;
  guest-provision) with_lock guest_provision "$@" ;;
  guest-repair) with_lock guest_repair_scripts "$@" ;;
  *) die "unsupported provisioning command: $command" ;;
esac
