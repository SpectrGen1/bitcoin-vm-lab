#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "$0")/../.." && pwd)/lib/common.sh"
need curl; need jq; need sshpass
[[ "$UMBREL_CREDENTIALS_FILE" == /* && -f "$UMBREL_CREDENTIALS_FILE" ]] ||
  die "configure protected UMBREL_CREDENTIALS_FILE"
[[ -z "$(find "$UMBREL_CREDENTIALS_FILE" -maxdepth 0 -perm /077 -print -quit)" ]] ||
  die "Umbrel credential file must be mode 0600 or stricter"
jq -e '.name|type=="string" and length>0 and test("^[A-Za-z0-9 _.-]+$")' \
  "$UMBREL_CREDENTIALS_FILE" >/dev/null || die "invalid Umbrel account name"
jq -e '.password|type=="string" and length>=12 and
  (contains("\\n")|not) and (contains("\\r")|not)' "$UMBREL_CREDENTIALS_FILE" >/dev/null ||
  die "Umbrel password must be at least 12 characters without newlines"
[[ "$UMBREL_SSH_PUBLIC_KEY" == /* && -f "$UMBREL_SSH_PUBLIC_KEY" ]] ||
  die "configure UMBREL_SSH_PUBLIC_KEY"

address="${UMBREL_MANAGEMENT_ADDRESS:-}"
waited=0
while [[ -z "$address" && $waited -lt "$GUEST_EXEC_TIMEOUT" ]]; do
  address="$(domain_ipv4 umbrel)"; [[ -n "$address" ]] || { sleep 2; waited=$((waited+2)); }
done
[[ "$address" =~ ^[A-Za-z0-9:.%-]+$ ]] || die "could not resolve Umbrel management address"

work="$(mktemp -d)"
cleanup() {
  local rc=$?
  if (( rc != 0 )); then
    local destination="$RUN_DIR/umbrel-onboarding-diagnostics-$(date -u +%Y%m%dT%H%M%SZ)"
    install -d -m 0700 "$destination"
    [[ ! -f "$work/register-response.json" ]] ||
      install -m 0600 "$work/register-response.json" "$destination/register-response.json"
    printf 'profile=%s\naddress=%s\nfailed_at=%s\n' \
      "$UMBREL_PROFILE_SHA256" "${address:-unresolved}" "$(date -u +%FT%TZ)" \
      >"$destination/summary.env"
    echo "onboarding diagnostics preserved at $destination (credentials excluded)" >&2
  fi
  rm -rf -- "$work"
  return "$rc"
}
trap cleanup EXIT
jq '{name:.name,password:.password,language:"en"}' "$UMBREL_CREDENTIALS_FILE" >"$work/register.json"
chmod 0600 "$work/register.json"
response=
for ((waited=0; waited<GUEST_EXEC_TIMEOUT; waited+=2)); do
  response="$(curl -fsS --proto '=http,https' --max-time 10 \
    "http://$address/trpc/user.exists" 2>/dev/null || true)"
  [[ -n "$response" ]] && break
  sleep 2
done
[[ -n "$response" ]] || die "Umbrel onboarding RPC did not become available"
exists="$(jq -r '
  .result.data as $data |
  if ($data | type) == "object" then ($data.json // false)
  else ($data // false)
  end
' <<<"$response")"
if [[ "$exists" != true ]]; then
  curl -fsS --proto '=http,https' --max-time 60 -H 'content-type: application/json' \
    --data-binary "@$work/register.json" "http://$address/trpc/user.register" \
    >"$work/register-response.json" ||
    die "pinned Umbrel user.register onboarding RPC failed"
  jq -e '
    .result.data as $data |
    if ($data | type) == "object" then $data.json == true
    else $data == true
    end
  ' "$work/register-response.json" >/dev/null ||
    die "Umbrel onboarding returned an unexpected response"
fi

password="$(jq -r .password "$UMBREL_CREDENTIALS_FILE")"
pubkey="$(cat "$UMBREL_SSH_PUBLIC_KEY")"
export SSHPASS="$password"
printf '%s\n' "$pubkey" | sshpass -e ssh \
  -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password \
  "$UMBREL_SSH_USER@$address" \
	  'umask 077; mkdir -p "$HOME/.ssh"; tmp="$HOME/.ssh/authorized_keys.bvml"; cat >"$tmp"; cat "$tmp" >>"$HOME/.ssh/authorized_keys"; sort -u "$HOME/.ssh/authorized_keys" -o "$HOME/.ssh/authorized_keys"; rm "$tmp"' \
	  >/dev/null || die "Umbrel onboarding succeeded but dedicated SSH key installation failed"
version_response="$(curl -fsS --proto '=http,https' --max-time 10 \
  "http://$address/trpc/system.version")" ||
  die "installed UmbrelOS system.version RPC is unavailable"
[[ "$(jq -r '.result.data.version // empty' <<<"$version_response")" == "$(jq -r .os.version "$UMBREL_PROFILE")" ]] ||
  die "installed UmbrelOS system.version differs from the pinned profile"
ssh -i "$UMBREL_SSH_PRIVATE_KEY" -o BatchMode=yes -o IdentitiesOnly=yes \
  "$UMBREL_SSH_USER@$address" \
  "test \"\$(jq -r .version /opt/umbreld/package.json)\" = '$(jq -r .os.version "$UMBREL_PROFILE")'" ||
  die "installed UmbrelOS identity differs from pinned 1.7.4"
printf '%s\n' "$password" | ssh -i "$UMBREL_SSH_PRIVATE_KEY" \
  -o BatchMode=yes -o IdentitiesOnly=yes "$UMBREL_SSH_USER@$address" \
  "sudo -S -p '' -- /bin/bash -c true" >/dev/null ||
  die "Umbrel management credential cannot authorize synchronous root commands"
unset SSHPASS password
note "Umbrel onboarding and dedicated key-only management transport completed"
