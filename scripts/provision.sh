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
  [[ $# == 1 ]] || die "usage: bvml media-fetch {ubuntu|umbrel|startos}"
  if [[ "$1" == umbrel ]]; then
    media_fetch_umbrel
    return
  fi
  if [[ "$1" == startos ]]; then
    media_fetch_startos
    return
  fi
  [[ "$1" == ubuntu ]] || die "usage: bvml media-fetch {ubuntu|umbrel|startos}"
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

validate_startos_profile() {
  [[ "$STARTOS_PROFILE" == /* && -f "$STARTOS_PROFILE" &&
     "$STARTOS_PROFILE_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] ||
    die "configure an absolute digest-pinned STARTOS_PROFILE"
  [[ "$(sha256sum "$STARTOS_PROFILE" | awk '{print $1}')" == "${STARTOS_PROFILE_SHA256,,}" ]] ||
    die "StartOS profile digest mismatch"
  jq -e '
    (.os.iso_url|startswith("https://")) and
    (.os.iso_sha256|test("^[0-9a-f]{64}$")) and
    (.registry.release_url|startswith("https://")) and
    (.registry.release_sha256|test("^[0-9a-f]{64}$")) and
    .registry.package_id=="bitcoind" and
    .registry.package_version=="#knots:29.3.1:16" and
    .package.subcontainer=="bitcoind-sub"
  ' "$STARTOS_PROFILE" >/dev/null || die "StartOS profile is malformed"
  [[ "$(jq -r .os.iso_sha256 "$STARTOS_PROFILE")" == "${STARTOS_ISO_SHA256,,}" &&
     "$(jq -r .registry.release_sha256 "$STARTOS_PROFILE")" == "${STARTOS_PACKAGE_SHA256,,}" ]] ||
    die "configured StartOS media digests differ from the profile"
}

validate_startos_iso() {
  local image="$1"
  [[ "$(sha256sum "$image" | awk '{print $1}')" == "${STARTOS_ISO_SHA256,,}" ]] || return 1
  file "$image" | grep -qi 'ISO 9660' || return 1
  xorriso -indev "$image" -report_el_torito plain 2>&1 | grep -qi boot || return 1
}

media_fetch_startos() {
  assert_provisioning_safe
  validate_startos_profile
  need xorriso; need file; need sha256sum
  install -d -m 0755 "$BVML_MEDIA_DIR" "$BVML_MEDIA_DIR/quarantine"
  local iso_url package_url cli_url cli_digest path quarantine manifest_tmp
  iso_url="$(jq -r .os.iso_url "$STARTOS_PROFILE")"
  package_url="$(jq -r .registry.release_url "$STARTOS_PROFILE")"
  cli_url="$(jq -r .os.start_cli_url "$STARTOS_PROFILE")"
  cli_digest="$(jq -r .os.start_cli_sha256 "$STARTOS_PROFILE")"
  for path in "$STARTOS_ISO" "$STARTOS_PACKAGE" "$STARTOS_CLI"; do
    if [[ -e "$path" ]]; then
      if [[ ! -O "$path" ]]; then
        sudo chown "$USER:$QEMU_GROUP" "$path" ||
          die "could not restore operator ownership of staged media $path"
      fi
      chmod 0644 "$path"
    fi
  done
  [[ -f "$STARTOS_ISO" ]] || fetch_to "$iso_url" "$STARTOS_ISO"
  if ! validate_startos_iso "$STARTOS_ISO"; then
    quarantine="$BVML_MEDIA_DIR/quarantine/$(basename "$STARTOS_ISO").$(date -u +%Y%m%dT%H%M%SZ)"
    mv -- "$STARTOS_ISO" "$quarantine"
    die "StartOS installer failed digest/ISO/boot validation and was quarantined at $quarantine"
  fi
  [[ -f "$STARTOS_PACKAGE" ]] || fetch_to "$package_url" "$STARTOS_PACKAGE"
  if [[ "$(sha256sum "$STARTOS_PACKAGE" | awk '{print $1}')" != "${STARTOS_PACKAGE_SHA256,,}" ]]; then
    quarantine="$BVML_MEDIA_DIR/quarantine/$(basename "$STARTOS_PACKAGE").$(date -u +%Y%m%dT%H%M%SZ)"
    mv -- "$STARTOS_PACKAGE" "$quarantine"
    die "StartOS package failed its pinned digest and was quarantined at $quarantine"
  fi
  [[ -f "$STARTOS_CLI" ]] || fetch_to "$cli_url" "$STARTOS_CLI"
  [[ "$(sha256sum "$STARTOS_CLI" | awk '{print $1}')" == "$cli_digest" ]] ||
    die "staged start-cli has the wrong pinned digest"
  chmod 0444 "$STARTOS_ISO" "$STARTOS_PACKAGE"
  chmod 0555 "$STARTOS_CLI"
  manifest_tmp="$(mktemp "$BVML_MEDIA_DIR/.startos-media-manifest.XXXXXX")"
  jq -n --arg platform startos --arg profile "${STARTOS_PROFILE_SHA256,,}" \
    --arg profile_id "$(jq -r .profile_id "$STARTOS_PROFILE")" \
    --arg iso "${STARTOS_ISO_SHA256,,}" --arg package "${STARTOS_PACKAGE_SHA256,,}" \
    --arg start_cli "$cli_digest" \
    --arg source_commit "$(jq -r .registry.source_commit "$STARTOS_PROFILE")" \
    --arg now "$(date -u +%FT%TZ)" \
    '{platform:$platform,profile_id:$profile_id,profile_digest:$profile,
      iso_sha256:$iso,package_sha256:$package,start_cli_sha256:$start_cli,
      package_source_commit:$source_commit,
      verified_at:$now}' >"$manifest_tmp"
  chmod 0444 "$manifest_tmp"
  mv -f -- "$manifest_tmp" "$STARTOS_ISO.manifest.json"
  note "staged verified StartOS installer and official pinned Knots s9pk"
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
  local path vm
  for path in "$CANONICAL" "$CANONICAL_META" "$BOOTSTRAP" "$BOOTSTRAP_META" \
    "$BOOTSTRAP_VERIFY" "$IMPORT_CANDIDATE" "$IMPORT_META" "$RECOVERY_META"; do
    [[ ! -e "$path" ]] ||
      die "profile replacement is blocked by checkpoint/lifecycle state: $path; use an explicit profile migration"
  done
  for vm in ubuntu umbrel startos; do
    for path in "$(lifecycle_overlay "$vm")" "$(lifecycle_meta "$vm")" \
      "$(lifecycle_verify "$vm")" "$(lifecycle_owner "$vm")" "$(lifecycle_recovery "$vm")"; do
      [[ ! -e "$path" ]] ||
        die "profile replacement is blocked by $vm lifecycle state: $path; use an explicit profile migration"
    done
  done
}

profiles_install_body() {
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

profiles_install() {
  assert_profile_mutation_safe
  profiles_install_body
}

profiles_migrate() {
  [[ "${1:-}" == --confirm-checkpoint-migration && $# == 1 ]] ||
    die "usage: bvml profiles-migrate --confirm-checkpoint-migration"
  for vm in umbrel startos; do is_shut_off "$vm" || die "$vm must be shut off"; done
  [[ ! -e "$STARTOS_LAYER" && ! -e "$STARTOS_LAYER_META" &&
     ! -e "$STARTOS_LAYER_CANDIDATE" && ! -e "$STARTOS_LAYER_RECOVERY" ]] ||
    die "remove the StartOS adapter before migrating the canonical profile"
  local vm
  for vm in umbrel startos; do
    [[ ! -e "$(lifecycle_overlay "$vm")" && ! -e "$(lifecycle_meta "$vm")" ]] ||
      die "$vm lifecycle state blocks checkpoint profile migration"
  done
  set_lifecycle_context ubuntu
  [[ -f "$OVERLAY" && -f "$OVERLAY_META" ]] ||
    die "profile migration requires an Ubuntu update overlay"
  if [[ "$(domain_state ubuntu)" == running ]]; then
    [[ "$(owner_vm)" == ubuntu &&
       "$(attached_vm_for_path "$OVERLAY" | paste -sd, -)" == ubuntu &&
       "$(bitcoin_attachment_count)" == 1 ]] ||
      die "running migration requires the exact owned Ubuntu overlay attachment"
  else
    is_shut_off ubuntu || die "Ubuntu migration state is unsafe"
    [[ ! -e "$OWNER_FILE" && -z "$(attached_vm_for_path "$OVERLAY")" ]] ||
      die "stopped migration requires a detached retained Ubuntu overlay"
  fi
  local migration_digest
  migration_digest="$(sha256sum "$CHECKPOINT_MIGRATION_PROFILE_SOURCE" | awk '{print $1}')"
  [[ "$CHECKPOINT_MIGRATION_PROFILE_SOURCE" = /* &&
     -f "$CHECKPOINT_MIGRATION_PROFILE_SOURCE" &&
     "$migration_digest" == "${CHECKPOINT_MIGRATION_PROFILE_SHA256,,}" ]] ||
    die "checkpoint migration profile source or digest is invalid"
  CHECKPOINT_PROFILE_SOURCE="$CHECKPOINT_MIGRATION_PROFILE_SOURCE"
  CHECKPOINT_PROFILE_FILE="$CHECKPOINT_MIGRATION_PROFILE_SOURCE"
  CHECKPOINT_PROFILE_SHA256="${CHECKPOINT_MIGRATION_PROFILE_SHA256,,}"
  validate_profile_generation
  local work stage generation_id generation_digest release_digest rdts_digest
  local active_new host_env
  work="$(mktemp -d)"
  trap "rm -rf -- '$work'" RETURN
  stage="$work/generation"
  if [[ -e "$BVML_HOST_CONFIG_DIR/active" ]]; then
    # active may be a symlink to generations/<id>; copy the real tree.
    cp -aL "$BVML_HOST_CONFIG_DIR/active/." "$stage/" 2>/dev/null || {
      install -d -m 0755 "$stage"
      cp -a "$(readlink -f "$BVML_HOST_CONFIG_DIR/active")/." "$stage/"
    }
  else
    install -d -m 0755 "$stage/releases"
    cp -a "$BVML_HOST_CONFIG_DIR/releases/." "$stage/releases/"
  fi
  install -d -m 0755 "$stage"
  install -m 0644 "$CHECKPOINT_PROFILE_SOURCE" "$stage/checkpoint-profile.json"
  release_digest="$(sha256sum "$stage/releases/knots-version.env" | awk '{print $1}')"
  rdts_digest="$(sha256sum "$stage/releases/knots-rdts.env" | awk '{print $1}')"
  generation_id="$(new_id)"
  generation_digest="$(printf '%s\n' "release=$release_digest" "rdts=$rdts_digest" \
    "checkpoint=${CHECKPOINT_PROFILE_SHA256,,}" | sha256sum | awk '{print $1}')"
  jq -cn --arg id "$generation_id" --arg digest "$generation_digest" \
    --arg release "$release_digest" --arg rdts "$rdts_digest" \
    --arg checkpoint "${CHECKPOINT_PROFILE_SHA256,,}" \
    '{generation_id:$id,generation_digest:$digest,release_profile_sha256:$release,
      rdts_profile_sha256:$rdts,checkpoint_profile_sha256:$checkpoint}' \
    >"$stage/generation.json"
  sudo install -d -o root -g root -m 0755 "$BVML_HOST_CONFIG_DIR/generations"
  sudo cp -a "$stage" "$BVML_HOST_CONFIG_DIR/generations/$generation_id"
  sudo chown -R root:root "$BVML_HOST_CONFIG_DIR/generations/$generation_id"
  active_new="$BVML_HOST_CONFIG_DIR/.active.new"
  sudo ln -s "generations/$generation_id" "$active_new"
  sudo mv -Tf -- "$active_new" "$BVML_HOST_CONFIG_DIR/active"
  host_env="$work/host.env"
  printf 'KNOTS_RELEASE_PROFILE=%q\nKNOTS_RELEASE_PROFILE_SHA256=%q\nKNOTS_RDTS_PROFILE=%q\nKNOTS_RDTS_PROFILE_SHA256=%q\nKNOTS_VERSION_NORMALIZED=%q\nKNOTS_ARTIFACT_SHA256=%q\nKNOTS_RDTS_PROFILE_NAME=%q\nKNOTS_RDTS_REQUIRED_ARGS_JSON=%q\nCHECKPOINT_PROFILE_FILE=%q\nCHECKPOINT_PROFILE_SHA256=%q\nPROFILE_GENERATION_ID=%q\nPROFILE_GENERATION_DIGEST=%q\n' \
    "$BVML_HOST_CONFIG_DIR/active/releases/knots-version.env" "$release_digest" \
    "$BVML_HOST_CONFIG_DIR/active/releases/knots-rdts.env" "$rdts_digest" \
    "$KNOTS_VERSION_NORMALIZED" "${KNOTS_ARTIFACT_SHA256,,}" \
    "$KNOTS_RDTS_PROFILE_NAME" "$KNOTS_RDTS_REQUIRED_ARGS_JSON" \
    "$BVML_HOST_CONFIG_DIR/active/checkpoint-profile.json" \
    "${CHECKPOINT_PROFILE_SHA256,,}" "$generation_id" "$generation_digest" >"$host_env"
  sudo install -o root -g root -m 0644 "$host_env" "$BVML_HOST_CONFIG_DIR/host.env"
  trap - RETURN
  rm -rf -- "$work"
  note "installed the explicit checkpoint migration profile; canonical commit is still required"
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
  [[ $# == 1 ]] || die "usage: bvml guest-provision {ubuntu|umbrel|startos}"
  if [[ "$1" == umbrel ]]; then
    guest_provision_umbrel
    return
  fi
  if [[ "$1" == startos ]]; then
    guest_provision_startos
    return
  fi
  [[ "$1" == ubuntu ]] || die "usage: bvml guest-provision {ubuntu|umbrel|startos}"
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
  local started_here=0 waited=0
  case "$(domain_state umbrel)" in
    "shut off")
      virshq start "$(domain umbrel)" >/dev/null
      started_here=1
      while ! (umbrel_exec_sync /bin/true 15 >/dev/null 2>&1); do
        (( waited < GUEST_EXEC_TIMEOUT )) ||
          die "Umbrel management transport did not become ready"
        sleep 2
        waited=$((waited+2))
      done
      ;;
    running)
      # guest-provision owns this maintenance session because no Bitcoin
      # lifecycle may coexist with it; leave the domain cleanly shut off.
      started_here=1
      ;;
    *) die "Umbrel must be exactly shut off or running for guest provisioning" ;;
  esac
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
  if (( started_here )); then
    virshq shutdown "$(domain umbrel)" >/dev/null
    waited=0
    while ! is_shut_off umbrel; do
      (( waited < SHUTDOWN_TIMEOUT )) ||
        die "Umbrel did not shut off after guest provisioning"
      sleep 2
      waited=$((waited+2))
    done
  fi
  note "installed and stopped the pinned official bitcoin-knots app through umbreld"
}

guest_provision_startos() {
  validate_startos_profile
  is_defined startos || die "StartOS VM is not defined"
  local started_here=0 waited=0 address
  case "$(domain_state startos)" in
    "shut off")
      virshq start "$(domain startos)"
      started_here=1
      while :; do
        address="$(domain_ipv4 startos)"
        if [[ -n "$address" ]] &&
          timeout 3 ssh -i "$STARTOS_SSH_PRIVATE_KEY" -o BatchMode=yes \
            -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
            "$STARTOS_SSH_USER@$address" \
            'sudo -- mountpoint -q /media/startos/data/main' >/dev/null 2>&1; then
          break
        fi
        (( waited < STARTOS_INSTALL_TIMEOUT )) ||
          die "StartOS management transport did not become ready"
        sleep 2
        waited=$((waited+2))
      done
      ;;
    running) ;;
    *) die "StartOS must be exactly shut off or running for guest provisioning" ;;
  esac
  set_lifecycle_context startos
  [[ ! -e "$OVERLAY" && ! -e "$OVERLAY_META" && ! -e "$OWNER_FILE" ]] ||
    die "guest-provision startos requires no StartOS Bitcoin lifecycle"
  bash -n "$ROOT/scripts/vm/guest/startos-adapter.sh" ||
    die "StartOS guest adapter fails shell syntax validation"
  local profile64 digest64 adapter64 url package_digest guest_root
  guest_root="$(jq -er '.os.management_root|select(startswith("/"))' "$STARTOS_PROFILE")" ||
    die "StartOS profile lacks an absolute persistent management root"
  profile64="$(base64 -w0 "$STARTOS_PROFILE")"
  digest64="$(printf '%s\n' "${STARTOS_PROFILE_SHA256,,}" | base64 -w0)"
  adapter64="$(base64 -w0 "$ROOT/scripts/vm/guest/startos-adapter.sh")"
  url="$(jq -r .registry.release_url "$STARTOS_PROFILE")"
  package_digest="$(jq -r .registry.release_sha256 "$STARTOS_PROFILE")"
  startos_exec_sync /bin/bash 120 -c "
    set -Eeuo pipefail
    mountpoint -q /media/startos/data/main
    install -d -o root -g root -m 0700 '$guest_root'
    install -d -o root -g root -m 0755 '$guest_root/bin'
    p=\$(mktemp '$guest_root/startos-profile.json.XXXXXX')
    d=\$(mktemp '$guest_root/startos-profile.sha256.XXXXXX')
    a=\$(mktemp '$guest_root/startos-adapter.sh.XXXXXX')
    trap 'rm -f -- \"\$p\" \"\$d\" \"\$a\"' EXIT
    printf %s '$profile64' | base64 -d >\"\$p\"
    printf %s '$digest64' | base64 -d >\"\$d\"
    printf %s '$adapter64' | base64 -d >\"\$a\"
    test \"\$(sha256sum \"\$p\" | awk '{print \$1}')\" = '${STARTOS_PROFILE_SHA256,,}'
    bash -n \"\$a\"
    chown root:root \"\$p\" \"\$d\" \"\$a\"
    chmod 0644 \"\$p\" \"\$d\"; chmod 0755 \"\$a\"
    mv -f -- \"\$p\" '$guest_root/startos-profile.json'
    mv -f -- \"\$d\" '$guest_root/startos-profile.sha256'
    mv -f -- \"\$a\" '$guest_root/bin/startos-adapter.sh'
    trap - EXIT
  "
  startos_exec_sync /bin/bash "$STARTOS_OPERATION_TIMEOUT" -c "
    set -Eeuo pipefail
    package=/var/tmp/bitcoind_x86_64.s9pk
    if test ! -f \"\$package\" ||
       test \"\$(sha256sum \"\$package\" | awk '{print \$1}')\" != '$package_digest'; then
      tmp=\$(mktemp /var/tmp/bitcoind_x86_64.s9pk.XXXXXX)
      trap 'rm -f -- \"\$tmp\"' EXIT
      curl -fL --proto '=https' --proto-redir '=https' --retry 4 -o \"\$tmp\" '$url'
      test \"\$(sha256sum \"\$tmp\" | awk '{print \$1}')\" = '$package_digest'
      chmod 0400 \"\$tmp\"
      mv -f -- \"\$tmp\" \"\$package\"
      trap - EXIT
    fi
    '$guest_root/bin/startos-adapter.sh' install-package \"\$package\"
  "
  install -d -m 0750 "$ADAPTER_STATE_DIR"
  jq -n --arg platform startos --arg profile "${STARTOS_PROFILE_SHA256,,}" \
    --arg os "$(jq -r .os.release "$STARTOS_PROFILE")" \
    --arg package "$(jq -r .registry.package_version "$STARTOS_PROFILE")" \
    --arg implementation "$(jq -r .adapter_implementation_version "$STARTOS_PROFILE")" \
    --arg now "$(date -u +%FT%TZ)" \
    '{platform:$platform,os_version:$os,package_version:$package,
      profile_digest:$profile,adapter_implementation_version:$implementation,
      provisioning_result:"ok",provisioned_at:$now,last_validation_result:"pending-overlay"}' \
    >"$ADAPTER_STATE_DIR/startos.json"
  chmod 0600 "$ADAPTER_STATE_DIR/startos.json"
  virshq shutdown "$(domain startos)"
  waited=0
  while ! is_shut_off startos; do
    (( waited < SHUTDOWN_TIMEOUT )) ||
      die "StartOS did not shut down after native package provisioning"
    sleep 2
    waited=$((waited+2))
  done
  note "installed and stopped the exact official StartOS bitcoind Knots package"
}

guest_repair_scripts() {
  [[ "${2:-}" == --scripts-only && $# == 2 ]] ||
    die "usage: bvml guest-repair {ubuntu|umbrel|startos} --scripts-only"
  if [[ "$1" == startos ]]; then
    is_defined startos || die "StartOS VM is not defined"
    [[ "$(domain_state startos)" == running ]] || die "StartOS must be exactly running"
    validate_startos_profile
    bash -n "$ROOT/scripts/vm/guest/startos-adapter.sh" \
      "$ROOT/scripts/vm/guest/startos-electrs.sh" \
      "$ROOT/scripts/vm/guest/startos-fulcrum.sh" ||
      die "StartOS guest adapter assets fail shell syntax validation"
    local guest_root adapter64 electrs64 fulcrum64
    guest_root="$(jq -er '.os.management_root|select(startswith("/"))' "$STARTOS_PROFILE")"
    startos_exec_sync /bin/bash 60 -c "
      test \"\$(sha256sum '$guest_root/startos-profile.json' | awk '{print \$1}')\" = '${STARTOS_PROFILE_SHA256,,}'
      test \"\$(tr -d '[:space:]' <'$guest_root/startos-profile.sha256')\" = '${STARTOS_PROFILE_SHA256,,}'
    " || die "StartOS script repair refused because its installed profile digest changed"
    adapter64="$(base64 -w0 "$ROOT/scripts/vm/guest/startos-adapter.sh")"
    electrs64="$(base64 -w0 "$ROOT/scripts/vm/guest/startos-electrs.sh")"
    fulcrum64="$(base64 -w0 "$ROOT/scripts/vm/guest/startos-fulcrum.sh")"
    startos_exec_sync /bin/bash 60 -c "
      set -Eeuo pipefail
      a=\$(mktemp '$guest_root/bin/startos-adapter.sh.XXXXXX')
      e=\$(mktemp '$guest_root/bin/startos-electrs.sh.XXXXXX')
      f=\$(mktemp '$guest_root/bin/startos-fulcrum.sh.XXXXXX')
      trap 'rm -f -- \"\$a\" \"\$e\" \"\$f\"' EXIT
      printf %s '$adapter64' | base64 -d >\"\$a\"
      printf %s '$electrs64' | base64 -d >\"\$e\"
      printf %s '$fulcrum64' | base64 -d >\"\$f\"
      chown root:root \"\$a\" \"\$e\" \"\$f\"
      chmod 0755 \"\$a\" \"\$e\" \"\$f\"
      bash -n \"\$a\" \"\$e\" \"\$f\"
      mv -f -- \"\$a\" '$guest_root/bin/startos-adapter.sh'
      mv -f -- \"\$e\" '$guest_root/bin/startos-electrs.sh'
      mv -f -- \"\$f\" '$guest_root/bin/startos-fulcrum.sh'
      trap - EXIT
    "
    note "updated persistent StartOS adapter and index scripts after proving profile digests"
    return
  fi
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
  [[ "$1" == ubuntu ]] || die "usage: bvml guest-repair {ubuntu|umbrel|startos} --scripts-only"
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

guest_index_provision() {
  local vm="${1:?VM required}" script64 profile64 profile_digest
  valid_vm "$vm"; validate_index_profile
  [[ "$(domain_state "$vm")" == running ]] || die "$vm must be exactly running"
  # Wait for the platform transport (QGA on Ubuntu; SSH fallback on Umbrel/StartOS).
  # Umbrel often lacks a connected qemu-guest-agent, so requiring QGA alone hangs.
  local waited=0
  while ! ( platform_exec_sync "$vm" /bin/true 15 ) >/dev/null 2>&1; do
    (( waited < GUEST_EXEC_TIMEOUT )) ||
      die "$vm guest management transport did not become ready"
    sleep 2
    waited=$((waited+2))
  done
  profile_digest="$(sha256sum "$INDEX_PROFILE" | awk '{print $1}')"
  [[ "$profile_digest" == "${INDEX_PROFILE_SHA256,,}" ]] ||
    die "index profile digest mismatch"
  if [[ "$vm" == ubuntu ]]; then
    bash -n "$ROOT/scripts/vm/guest/ubuntu-indexers.sh" ||
      die "Ubuntu index adapter fails shell syntax validation"
    script64="$(base64 -w0 "$ROOT/scripts/vm/guest/ubuntu-indexers.sh")"
    profile64="$(base64 -w0 "$INDEX_PROFILE")"
    guest_exec_sync ubuntu /bin/bash "$GUEST_EXEC_TIMEOUT" -c "
      set -Eeuo pipefail
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y --no-install-recommends docker.io btrfs-progs python3
      install -d -o root -g root -m 0755 /usr/local/libexec/bvml /etc/bvml
      s=\$(mktemp /usr/local/libexec/bvml/ubuntu-indexers.sh.XXXXXX)
      p=\$(mktemp /etc/bvml/indexers.json.XXXXXX)
      trap 'rm -f -- \"\$s\" \"\$p\"' EXIT
      printf %s '$script64' | base64 -d >\"\$s\"
      printf %s '$profile64' | base64 -d >\"\$p\"
      test \"\$(sha256sum \"\$p\" | awk '{print \$1}')\" = '$profile_digest'
      bash -n \"\$s\"
      chown root:root \"\$s\" \"\$p\"; chmod 0755 \"\$s\"; chmod 0644 \"\$p\"
      mv -f -- \"\$s\" /usr/local/libexec/bvml/ubuntu-indexers.sh
      mv -f -- \"\$p\" /etc/bvml/indexers.json
      systemctl enable --now docker
      trap - EXIT
    "
    note "installed Ubuntu index integration and required container/filesystem tools"
    return
  fi
  if [[ "$vm" == umbrel ]]; then
    bash -n "$ROOT/scripts/vm/guest/umbrel-indexers.sh" ||
      die "Umbrel index adapter fails shell syntax validation"
    local guest_bvml
    guest_bvml="$(jq -er '.os.data_directory | select(startswith("/"))' "$UMBREL_PROFILE")/.bvml"
    script64="$(base64 -w0 "$ROOT/scripts/vm/guest/umbrel-indexers.sh")"
    profile64="$(base64 -w0 "$INDEX_PROFILE")"
    umbrel_exec_sync /bin/bash 120 -c "
      set -Eeuo pipefail
      install -d -o root -g root -m 0755 '$guest_bvml/bin' '$guest_bvml/etc'
      s=\$(mktemp '$guest_bvml/bin/umbrel-indexers.sh.XXXXXX')
      p=\$(mktemp '$guest_bvml/etc/indexers.json.XXXXXX')
      d=\$(mktemp '$guest_bvml/etc/indexers.sha256.XXXXXX')
      trap 'rm -f -- \"\$s\" \"\$p\" \"\$d\"' EXIT
      printf %s '$script64' | base64 -d >\"\$s\"
      printf %s '$profile64' | base64 -d >\"\$p\"
      printf '%s\n' '$profile_digest' >\"\$d\"
      test \"\$(sha256sum \"\$p\" | awk '{print \$1}')\" = '$profile_digest'
      bash -n \"\$s\"
      chown root:root \"\$s\" \"\$p\" \"\$d\"
      chmod 0755 \"\$s\"; chmod 0644 \"\$p\" \"\$d\"
      mv -f \"\$s\" '$guest_bvml/bin/umbrel-indexers.sh'
      mv -f \"\$p\" '$guest_bvml/etc/indexers.json'
      mv -f \"\$d\" '$guest_bvml/etc/indexers.sha256'
      trap - EXIT
    "
    umbrel_exec_sync "$guest_bvml/bin/umbrel-indexers.sh" "$UMBREL_OPERATION_TIMEOUT" install-apps
    note "installed and stopped the pinned official Umbrel Electrs and Fulcrum apps"
    return
  fi
  if [[ "$vm" == startos ]]; then
    bash -n "$ROOT/scripts/vm/guest/startos-fulcrum.sh" ||
      die "StartOS Fulcrum adapter fails shell syntax validation"
    bash -n "$ROOT/scripts/vm/guest/startos-electrs.sh" ||
      die "StartOS Electrs adapter fails shell syntax validation"
    local guest_root startos_profile64 fulcrum64 electrs64
    guest_root="$(jq -er '.os.management_root|select(startswith("/"))' "$STARTOS_PROFILE")"
    fulcrum64="$(base64 -w0 "$ROOT/scripts/vm/guest/startos-fulcrum.sh")"
    electrs64="$(base64 -w0 "$ROOT/scripts/vm/guest/startos-electrs.sh")"
    profile64="$(base64 -w0 "$INDEX_PROFILE")"
    startos_profile64="$(base64 -w0 "$STARTOS_PROFILE")"
    startos_exec_sync /bin/bash 120 -c "
      set -Eeuo pipefail
      install -d -o root -g root -m 0700 '$guest_root'
      install -d -o root -g root -m 0755 '$guest_root/bin'
      f=\$(mktemp '$guest_root/bin/startos-fulcrum.sh.XXXXXX')
      e=\$(mktemp '$guest_root/bin/startos-electrs.sh.XXXXXX')
      p=\$(mktemp '$guest_root/indexers.json.XXXXXX')
      d=\$(mktemp '$guest_root/indexers.sha256.XXXXXX')
      o=\$(mktemp '$guest_root/startos-profile.json.XXXXXX')
      trap 'rm -f -- \"\$f\" \"\$e\" \"\$p\" \"\$d\" \"\$o\"' EXIT
      printf %s '$fulcrum64' | base64 -d >\"\$f\"
      printf %s '$electrs64' | base64 -d >\"\$e\"
      printf %s '$profile64' | base64 -d >\"\$p\"
      printf %s '$startos_profile64' | base64 -d >\"\$o\"
      printf '%s\n' '$profile_digest' >\"\$d\"
      test \"\$(sha256sum \"\$p\"|awk '{print \$1}')\" = '$profile_digest'
      test \"\$(sha256sum \"\$o\"|awk '{print \$1}')\" = '${STARTOS_PROFILE_SHA256,,}'
      bash -n \"\$f\"; bash -n \"\$e\"
      chown root:root \"\$f\" \"\$e\" \"\$p\" \"\$d\" \"\$o\"
      chmod 0755 \"\$f\" \"\$e\"; chmod 0600 \"\$p\" \"\$d\" \"\$o\"
      mv -f \"\$f\" '$guest_root/bin/startos-fulcrum.sh'
      mv -f \"\$e\" '$guest_root/bin/startos-electrs.sh'
      mv -f \"\$p\" '$guest_root/indexers.json'
      mv -f \"\$d\" '$guest_root/indexers.sha256'
      mv -f \"\$o\" '$guest_root/startos-profile.json'
      trap - EXIT
    "
    startos_exec_sync "$guest_root/bin/startos-fulcrum.sh" "$STARTOS_OPERATION_TIMEOUT" install-package
    startos_exec_sync "$guest_root/bin/startos-electrs.sh" "$STARTOS_OPERATION_TIMEOUT" install-package
    note "installed and stopped StartOS Fulcrum (official) and Electrs (community) packages"
    return
  fi
  die "unsupported index provisioning target: $vm"
}

case "$command" in
  media-fetch) with_global_lock media_fetch "$@" ;;
  profiles-install) with_global_lock profiles_install "$@" ;;
  profiles-migrate) with_global_lock profiles_migrate "$@" ;;
  storage-prepare) with_global_lock storage_prepare "$@" ;;
  guest-provision) with_vm_lock "${1:?VM required}" guest_provision "$@" ;;
  guest-repair) with_vm_lock "${1:?VM required}" guest_repair_scripts "$@" ;;
  guest-index-provision) with_vm_lock "${1:?VM required}" guest_index_provision "$@" ;;
  *) die "unsupported provisioning command: $command" ;;
esac
