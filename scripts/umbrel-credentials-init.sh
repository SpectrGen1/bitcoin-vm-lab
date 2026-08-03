#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/common.sh"
[[ $# == 0 ]] || die "usage: bvml credentials-init umbrel"
need openssl; need ssh-keygen; need jq

credentials_dir="${XDG_CONFIG_HOME:-$HOME/.config}/bitcoin-vm-lab"
credentials="$credentials_dir/umbrel-credentials.json"
private_key="$credentials_dir/umbrel_ed25519"
public_key="$private_key.pub"
install -d -m 0700 "$credentials_dir"
if [[ ! -e "$credentials" ]]; then
  password="$(openssl rand -base64 36 | tr -d '\n')"
  umask 077
  jq -n --arg name bvml --arg password "$password" \
    '{name:$name,password:$password}' >"$credentials"
  unset password
  chmod 0600 "$credentials"
fi
if [[ ! -e "$private_key" || ! -e "$public_key" ]]; then
  [[ ! -e "$private_key" && ! -e "$public_key" ]] ||
    die "partial Umbrel SSH key state exists in $credentials_dir"
  ssh-keygen -q -t ed25519 -N '' -C 'bitcoin-vm-lab Umbrel management' -f "$private_key"
  chmod 0600 "$private_key"; chmod 0644 "$public_key"
fi

local_config="$ROOT/config/local.env"
touch "$local_config"; chmod 0600 "$local_config"
for assignment in \
  "UMBREL_CREDENTIALS_FILE=$credentials" \
  "UMBREL_SSH_PRIVATE_KEY=$private_key" \
  "UMBREL_SSH_PUBLIC_KEY=$public_key"; do
  key="${assignment%%=*}"
  if grep -q "^${key}=" "$local_config"; then
    current="$(sed -n "s/^${key}=//p" "$local_config" | tail -1)"
    [[ "$current" == "${assignment#*=}" ]] ||
      die "$key already points elsewhere; refusing to overwrite operator configuration"
  else
    printf '%s\n' "$assignment" >>"$local_config"
  fi
done
note "protected Umbrel credentials and dedicated SSH keys are configured under $credentials_dir"
