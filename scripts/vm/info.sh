#!/usr/bin/env bash
# Operator-facing connection info for lab VMs (IPs, consoles, dashboards, creds).
# This lab is a dedicated test environment: credentials are printed in full.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/lib/common.sh"

usage() {
  cat <<'EOF'
usage: bvml info [VM]

Print connection, console, dashboard, and credential details for lab VMs.
With no VM, prints every known platform (ubuntu, umbrel, startos).
EOF
}

section() { printf '\n== %s ==\n' "$1"; }
field() { printf '  %-18s %s\n' "$1" "$2"; }
field_multi() {
  local label="$1"; shift
  local first=1 line
  for line in "$@"; do
    if ((first)); then
      printf '  %-18s %s\n' "$label" "$line"
      first=0
    else
      printf '  %-18s %s\n' '' "$line"
    fi
  done
}

console_uri() {
  local vm="$1" uri
  uri="$(virshq domdisplay "$(domain "$vm")" 2>/dev/null || true)"
  [[ -n "$uri" ]] || uri="$(virshq vncdisplay "$(domain "$vm")" 2>/dev/null || true)"
  printf '%s\n' "$uri"
}

ssh_key_hint() {
  local key="$1"
  if [[ -n "$key" && "$key" == /* && -f "$key" ]]; then
    printf '%s\n' "$key"
  else
    printf '(not configured)\n'
  fi
}

print_ubuntu() {
  local state ip console key user
  state=undefined; is_defined ubuntu && state="$(domain_state ubuntu)"
  ip="$(domain_ipv4 ubuntu 2>/dev/null || true)"
  console="$(console_uri ubuntu)"
  key="$(ssh_key_hint "${UBUNTU_CLOUD_SSH_KEY:-}")"
  user="${UBUNTU_CLOUD_USER:-ubuntu}"

  section "ubuntu ($(domain ubuntu))"
  field "libvirt state" "$state"
  field "IPv4" "${ip:-unavailable (start the VM or wait for DHCP/QGA)}"
  field "console" "${console:-unavailable}"
  if [[ -n "$ip" ]]; then
    field "SSH" "ssh ${user}@${ip}"
    field "SSH key" "$key"
    if [[ "$key" != '(not configured)' ]]; then
      field "SSH (key)" "ssh -i ${key} ${user}@${ip}"
    fi
  else
    field "SSH" "unavailable until an address is assigned"
  fi
  field_multi "Electrum (host)" \
    "Electrs TCP  ${ip:-<ip>}:50001 (when index consumer is running)" \
    "Fulcrum TCP  ${ip:-<ip>}:50002 (when index consumer is running)"
  field "notes" "Ubuntu has no web dashboard; use SSH or the SPICE console."
  field "lifecycle" "bin/bvml start ubuntu | resume ubuntu | stop ubuntu | status"
}

print_umbrel() {
  local state ip console key user name password creds
  state=undefined; is_defined umbrel && state="$(domain_state umbrel)"
  ip="$(domain_ipv4 umbrel 2>/dev/null || true)"
  [[ -z "${UMBREL_MANAGEMENT_ADDRESS:-}" ]] || ip="${UMBREL_MANAGEMENT_ADDRESS}"
  console="$(console_uri umbrel)"
  key="$(ssh_key_hint "${UMBREL_SSH_PRIVATE_KEY:-}")"
  user="${UMBREL_SSH_USER:-umbrel}"
  name=unavailable
  password=unavailable
  creds="${UMBREL_CREDENTIALS_FILE:-}"
  if [[ -n "$creds" && "$creds" == /* && -f "$creds" ]]; then
    name="$(jq -er '.name // "umbrel"' "$creds" 2>/dev/null || printf 'unavailable')"
    password="$(jq -er '.password // empty' "$creds" 2>/dev/null || true)"
    [[ -n "$password" ]] || password='unavailable'
  fi

  section "umbrel ($(domain umbrel))"
  field "libvirt state" "$state"
  field "IPv4" "${ip:-unavailable (start the VM or wait for DHCP/QGA)}"
  field "console" "${console:-unavailable}"
  if [[ -n "$ip" ]]; then
    field "dashboard" "http://${ip}/"
    field "dashboard (alt)" "http://${ip}:80/"
    field "Tor proxy UI" "http://${ip}:2000/ (Umbrel auth proxy; app-specific)"
    field "login name" "$name"
    field "login password" "$password"
    field "SSH" "ssh ${user}@${ip}"
    field "SSH key" "$key"
    if [[ "$key" != '(not configured)' ]]; then
      field "SSH (key)" "ssh -i ${key} ${user}@${ip}"
    fi
    field "SSH sudo" "password for sudo is the dashboard password above"
  else
    field "dashboard" "unavailable until an address is assigned"
    field "login name" "$name"
    field "login password" "$password"
  fi
  field_multi "Electrum (host)" \
    "Electrs TCP  ${ip:-<ip>}:50001 (after index-adapter-setup)" \
    "Fulcrum TCP  ${ip:-<ip>}:50002 (after index-adapter-setup)"
  field "credentials file" "${creds:-not configured (run: bin/bvml credentials-init umbrel)}"
  field "lifecycle" "bin/bvml start umbrel --adapter-setup | adapter-setup umbrel | stop umbrel"
}

print_startos() {
  local state ip console key user password server hostname creds
  state=undefined; is_defined startos && state="$(domain_state startos)"
  ip="$(domain_ipv4 startos 2>/dev/null || true)"
  [[ -z "${STARTOS_MANAGEMENT_ADDRESS:-}" ]] || ip="${STARTOS_MANAGEMENT_ADDRESS}"
  console="$(console_uri startos)"
  key="$(ssh_key_hint "${STARTOS_SSH_PRIVATE_KEY:-}")"
  user="${STARTOS_SSH_USER:-start9}"
  password=unavailable
  server='Bitcoin VM Lab'
  hostname='bvml-startos'
  creds="${STARTOS_CREDENTIALS_FILE:-}"
  if [[ -n "$creds" && "$creds" == /* && -f "$creds" ]]; then
    password="$(jq -er '.password // empty' "$creds" 2>/dev/null || true)"
    [[ -n "$password" ]] || password='unavailable'
    server="$(jq -er '.server_name // "Bitcoin VM Lab"' "$creds" 2>/dev/null || printf 'Bitcoin VM Lab')"
    hostname="$(jq -er '.hostname // "bvml-startos"' "$creds" 2>/dev/null || printf 'bvml-startos')"
  fi

  section "startos ($(domain startos))"
  field "libvirt state" "$state"
  field "IPv4" "${ip:-unavailable (start the VM or wait for DHCP/QGA)}"
  field "hostname" "$hostname"
  field "server name" "$server"
  field "console" "${console:-unavailable}"
  if [[ -n "$ip" ]]; then
    field "dashboard" "https://${ip}/"
    field "dashboard (http)" "http://${ip}/  (often redirects to HTTPS)"
    field "dashboard (mDNS)" "https://${hostname}.local/  (from LAN clients with mDNS)"
    field "login password" "$password"
    field "login notes" "StartOS UI uses the single setup password (no separate username)."
    field "SSH" "ssh ${user}@${ip}"
    field "SSH key" "$key"
    if [[ "$key" != '(not configured)' ]]; then
      field "SSH (key)" "ssh -i ${key} ${user}@${ip}"
    fi
  else
    field "dashboard" "unavailable until an address is assigned"
    field "login password" "$password"
  fi
  field_multi "Electrum (notes)" \
    "StartOS packages bind Electrum on 50001 inside the subcontainer." \
    "Host publish may expose Fulcrum as ${ip:-<ip>}:50002 when running."
  field "credentials file" "${creds:-not configured (run: bin/bvml credentials-init startos)}"
  field "lifecycle" "bin/bvml start startos --adapter-setup | adapter-setup startos | stop startos"
}

print_header() {
  cat <<EOF
bitcoin-vm-lab connection info
  storage: $BVML_STORAGE
  libvirt: $LIBVIRT_URI
  network: ${BVML_NETWORK:-default}
  note:    test environment — credentials are printed in cleartext on purpose
EOF
}

print_vm() {
  case "$1" in
    ubuntu) print_ubuntu ;;
    umbrel) print_umbrel ;;
    startos) print_startos ;;
    *) die "unknown VM '$1' (use ubuntu, umbrel, or startos)" ;;
  esac
}

main() {
  local target="${1:-}"
  if [[ "$target" == -h || "$target" == --help || "$target" == help ]]; then
    usage
    return 0
  fi
  if [[ -n "$target" ]]; then
    valid_vm "$target"
    print_header
    print_vm "$target"
    printf '\n'
    return 0
  fi
  print_header
  for vm in ubuntu umbrel startos; do
    print_vm "$vm"
  done
  printf '\n'
}

main "$@"
