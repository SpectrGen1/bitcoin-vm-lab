#!/usr/bin/env bash
set -Eeuo pipefail

BVML_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BVML_ROOT/config/defaults.env"
[[ -f "$BVML_ROOT/config/local.env" ]] && source "$BVML_ROOT/config/local.env"

CANONICAL="$BVML_STORAGE/canonical/bitcoin-mainnet.qcow2"
RUN_DIR="$BVML_STORAGE/run"
OWNER_FILE="$RUN_DIR/bitcoin-data.owner"
LOCK_FILE="$RUN_DIR/bitcoin-data.lock"

die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*"; }
need() { command -v "$1" >/dev/null || die "missing command: $1"; }
domain() { printf 'bvml-%s' "$1"; }
valid_vm() { [[ "$1" =~ ^(ubuntu|umbrel|startos)$ ]] || die "VM must be ubuntu, umbrel, or startos"; }
vm_dir() { printf '%s/vms/%s' "$BVML_STORAGE" "$1"; }
overlay() { printf '%s/overlays/%s/bitcoin-mainnet.qcow2' "$BVML_STORAGE" "$1"; }

init_layout() {
  # qemu must traverse disk directories; images themselves retain restrictive modes.
  install -d -m 0755 "$BVML_STORAGE"/{canonical,overlays,vms}
  install -d -m 0750 "$RUN_DIR"; touch "$LOCK_FILE"; chmod 0600 "$LOCK_FILE"
}
with_lock() { init_layout; exec 9>"$LOCK_FILE"; flock -n 9 || die "Bitcoin data is busy; run '$BVML_ROOT/bin/bvml status'"; "$@"; }
owner_vm() { [[ -f "$OWNER_FILE" ]] && awk -F= '$1=="vm" {print $2}' "$OWNER_FILE"; }
assert_no_owner() { [[ ! -e "$OWNER_FILE" ]] || die "Bitcoin data is owned by $(owner_vm)"; }
assert_owner() { [[ "$(owner_vm)" == "$1" ]] || die "Bitcoin data is not owned by $1"; }
write_owner() { umask 077; printf 'vm=%s\npid=%s\nstarted=%s\n' "$1" "$$" "$(date -Is)" >"$OWNER_FILE"; }
clear_owner() { rm -f -- "$OWNER_FILE"; }
require_canonical() { [[ -f "$CANONICAL" ]] || die "canonical image missing: $CANONICAL"; [[ ! -w "$CANONICAL" ]] || die "canonical is writable; run checkpoint-protect"; }
virshq() { virsh -c "$LIBVIRT_URI" "$@"; }
is_running() { virshq domstate "$(domain "$1")" 2>/dev/null | grep -qx running; }
is_defined() { virshq dominfo "$(domain "$1")" >/dev/null 2>&1; }
