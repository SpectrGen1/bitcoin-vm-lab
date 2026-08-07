#!/usr/bin/env bash
# Resume-safe authenticated onboarding of an already installed StartOS domain.
set -Eeuo pipefail
source "$(cd "$(dirname "$0")/../.." && pwd)/lib/common.sh"

[[ "$(domain_state startos)" == running ]] || die "installed StartOS VM is not running"
[[ -x "$STARTOS_CLI" &&
   "$(sha256sum "$STARTOS_CLI" | awk '{print $1}')" == "$(jq -r .os.start_cli_sha256 "$STARTOS_PROFILE")" ]] ||
  die "pinned start-cli is absent or invalid"
[[ "$STARTOS_CREDENTIALS_FILE" == /* && -f "$STARTOS_CREDENTIALS_FILE" &&
   -z "$(find "$STARTOS_CREDENTIALS_FILE" -maxdepth 0 -perm /077 -print -quit)" ]] ||
  die "STARTOS_CREDENTIALS_FILE must be an absolute mode-0600 file"
[[ "$STARTOS_SSH_PUBLIC_KEY" == /* && -f "$STARTOS_SSH_PUBLIC_KEY" ]] ||
  die "configure STARTOS_SSH_PUBLIC_KEY"
root_ca_file="${STARTOS_CREDENTIALS_FILE}.root-ca.pem"
[[ -f "$root_ca_file" && -z "$(find "$root_ca_file" -maxdepth 0 -perm /077 -print -quit)" ]] ||
  die "the protected StartOS root CA from setup is absent"
identity_file="${STARTOS_CREDENTIALS_FILE}.identity"
if [[ ! -f "$identity_file" ]]; then
  "$STARTOS_CLI" --id-key-path "$identity_file" init-key
fi
chmod 0600 "$identity_file"
[[ -s "$identity_file" ]] || die "StartOS management identity key is absent"

password="$(jq -er '.password|select(type=="string" and length>=12)' "$STARTOS_CREDENTIALS_FILE")"
trap 'unset password' EXIT
waited=0
while :; do
  address="$(domain_ipv4 startos)"
  if [[ -n "$address" ]]; then
    cli=("$STARTOS_CLI" -H "https://$address" --root-ca "$root_ca_file" \
      --id-key-path "$identity_file")
    "${cli[@]}" git-info >/dev/null 2>&1 && break
  fi
  (( waited < STARTOS_INSTALL_TIMEOUT )) ||
    die "installed StartOS authenticated API did not become ready"
  sleep 2
  waited=$((waited+2))
done

waited=0
while ! PASSWORD="$password" "${cli[@]}" auth login >/dev/null 2>&1; do
  (( waited < 30 )) || die "StartOS authentication failed"
  sleep 5
  waited=$((waited+5))
done
ssh_fingerprint="$(ssh-keygen -lf "$STARTOS_SSH_PUBLIC_KEY" -E md5 |
  awk '{sub(/^MD5:/, "", $2); print $2}')"
if ! "${cli[@]}" ssh list 2>/dev/null | grep -Fq "$ssh_fingerprint"; then
  "${cli[@]}" ssh add "$(<"$STARTOS_SSH_PUBLIC_KEY")"
fi
[[ "$("${cli[@]}" git-info)" == "$(jq -r .os.start_cli_git_info "$STARTOS_PROFILE")" ]] ||
  die "installed management CLI build differs from the pinned profile"
installed_release="$("${cli[@]}" db dump --format json |
  jq -er '.value.serverInfo.version')"
[[ "$installed_release" == "$(jq -r .os.release "$STARTOS_PROFILE")" ]] ||
  die "installed StartOS release '$installed_release' differs from the pinned profile"

"${cli[@]}" server shutdown
waited=0
while ! is_shut_off startos; do
  (( waited < SHUTDOWN_TIMEOUT )) || die "installed StartOS did not shut down"
  sleep 2
  waited=$((waited+2))
done
note "initialized, management-provisioned, and verified pinned StartOS"
