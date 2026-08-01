#!/usr/bin/env bash
set -Eeuo pipefail

BVML_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BVML_ROOT/config/defaults.env"
[[ -f "$BVML_ROOT/config/local.env" ]] && source "$BVML_ROOT/config/local.env"

CANONICAL_DIR="$BVML_STORAGE/canonical"
CANONICAL="$CANONICAL_DIR/bitcoin-mainnet.qcow2"
CANONICAL_META="$CANONICAL_DIR/manifest.env"
ROLLBACK="$CANONICAL_DIR/bitcoin-mainnet.rollback.qcow2"
ROLLBACK_META="$CANONICAL_DIR/rollback-manifest.env"
ACTIVE_DIR="$BVML_STORAGE/active"
OVERLAY="$ACTIVE_DIR/bitcoin-mainnet-overlay.qcow2"
OVERLAY_META="$ACTIVE_DIR/manifest.env"
VERIFY_META="$ACTIVE_DIR/ubuntu-verification.env"
RUN_DIR="$BVML_STORAGE/run"
OWNER_FILE="$RUN_DIR/owner.env"
LOCK_FILE="$RUN_DIR/storage.lock"

die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*"; }
need() { command -v "$1" >/dev/null || die "missing command: $1"; }
domain() { printf 'bvml-%s' "$1"; }
valid_vm() { [[ "${1:-}" =~ ^(ubuntu|umbrel|startos)$ ]] || die "VM must be ubuntu, umbrel, or startos"; }
vm_dir() { printf '%s/vms/%s' "$BVML_STORAGE" "$1"; }
virshq() { virsh -c "$LIBVIRT_URI" "$@"; }
is_defined() { virshq dominfo "$(domain "$1")" >/dev/null 2>&1; }
domain_state() { virshq domstate "$(domain "$1")" 2>/dev/null | sed -n '1{s/[[:space:]]*$//;p;}'; }
is_shut_off() { [[ "$(domain_state "$1")" == "shut off" ]]; }
meta_get() {
  local file="$1" key="$2"
  [[ -f "$file" ]] && sed -n "s/^${key}=//p" "$file" | head -1
  return 0
}
overlay_vm() { meta_get "$OVERLAY_META" vm; }
owner_vm() { meta_get "$OWNER_FILE" vm; }
canonical_id() { meta_get "$CANONICAL_META" id; }

init_layout() {
  if [[ "${BVML_TESTING:-0}" == 1 ]]; then
    install -d -m 0750 "$BVML_STORAGE" "$CANONICAL_DIR" "$ACTIVE_DIR" "$RUN_DIR" "$BVML_STORAGE/vms"
  else
    need sudo
    sudo install -d -o "$USER" -g "$QEMU_GROUP" -m 0750 \
      "$BVML_STORAGE" "$CANONICAL_DIR" "$ACTIVE_DIR" "$RUN_DIR" "$BVML_STORAGE/vms"
  fi
  touch "$LOCK_FILE"; chmod 0640 "$LOCK_FILE"
  if [[ "${BVML_TESTING:-0}" != 1 ]] && command -v setfacl >/dev/null; then
    setfacl -m "u:$QEMU_USER:--x" "$BVML_STORAGE" "$CANONICAL_DIR" "$ACTIVE_DIR" "$BVML_STORAGE/vms"
  fi
}

with_lock() {
  init_layout
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "another bitcoin-vm-lab storage operation is running"
  "$@"
}

write_env_file() {
  local path="$1"; shift
  umask 077
  : >"$path"
  local item
  for item in "$@"; do printf '%s\n' "$item" >>"$path"; done
}

all_shut_off() {
  local vm
  for vm in ubuntu umbrel startos; do
    is_defined "$vm" || continue
    is_shut_off "$vm" || die "$(domain "$vm") is $(domain_state "$vm"); exact 'shut off' required"
  done
}

disk_sources() {
  local vm="$1"
  virshq domblklist "$(domain "$vm")" --details 2>/dev/null |
    awk 'NR>2 && $4 != "-" {print $4}'
}

attached_vm_for_path() {
  local wanted="$1" vm src
  for vm in ubuntu umbrel startos; do
    is_defined "$vm" || continue
    while IFS= read -r src; do [[ "$src" == "$wanted" ]] && printf '%s\n' "$vm"; done < <(disk_sources "$vm")
  done
}

bitcoin_attachment_count() {
  local count=0 vm src
  for vm in ubuntu umbrel startos; do
    is_defined "$vm" || continue
    while IFS= read -r src; do
      [[ "$src" == "$OVERLAY" || "$src" == "$CANONICAL" || "$src" == "$ROLLBACK" ]] && ((count+=1))
    done < <(disk_sources "$vm")
  done
  printf '%s\n' "$count"
}

assert_no_bitcoin_attachments() {
  local count; count="$(bitcoin_attachment_count)"
  [[ "$count" == 0 ]] || die "$count VM Bitcoin-disk attachment(s) remain"
}

assert_no_extra_overlays() {
  local extra
  extra="$(find "$ACTIVE_DIR" -maxdepth 1 -type f -name '*.qcow2' ! -path "$OVERLAY" -print -quit 2>/dev/null)"
  [[ -z "$extra" ]] || die "unexpected extra overlay exists: $extra"
}

protect_image() {
  local image="$1"
  chmod 0440 "$image"
  if [[ "${BVML_TESTING:-0}" != 1 ]]; then
    need chattr; need sudo
    sudo chattr +i "$image" || die "could not set immutable protection on $image"
    need setfacl
    setfacl -m "u:$QEMU_USER:r--" "$image" || die "could not grant read-only QEMU access to $image"
  fi
}

unprotect_image() {
  local image="$1"
  [[ -e "$image" ]] || return 0
  if [[ "${BVML_TESTING:-0}" != 1 ]]; then need sudo; sudo chattr -i "$image"; fi
  chmod u+w "$image"
}

require_canonical() {
  [[ -f "$CANONICAL" && -f "$CANONICAL_META" ]] || die "canonical checkpoint is missing; run checkpoint-import"
  [[ ! -w "$CANONICAL" ]] || die "canonical checkpoint is writable; run checkpoint-protect"
  [[ -z "$(qemu-img info --output=json "$CANONICAL" | sed -n 's/.*"backing-filename":[[:space:]]*"[^"]*".*/backed/p')" ]] ||
    die "canonical checkpoint unexpectedly has a backing image"
}
