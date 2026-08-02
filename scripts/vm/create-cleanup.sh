#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "$0")/../.." && pwd)/lib/common.sh"
vm="${1:?VM required}"; shift
valid_vm "$vm"
[[ "${1:-}" == --confirm-remove-partial && $# == 1 ]] ||
  die "usage: bvml create-cleanup VM --confirm-remove-partial"

cleanup_partial_vm() {
  assert_provisioning_safe
  is_defined "$vm" && die "$(domain "$vm") is defined; undefine it deliberately before partial-disk cleanup"
  local dir; dir="$(vm_dir "$vm")"
  [[ -d "$dir" ]] || { note "no partial VM directory exists for $vm"; return; }
  find "$dir" -mindepth 1 -maxdepth 1 -type f \
    ! -name system.qcow2 ! -name application.qcow2 -print -quit | grep -q . &&
    die "unexpected files exist in $dir; refusing automatic cleanup"
  rm -f -- "$dir/system.qcow2" "$dir/application.qcow2"
  rmdir "$dir" 2>/dev/null || die "VM directory is not empty after known partial disks were removed"
  note "removed known partial persistent disks for undefined $vm VM"
}

with_lock cleanup_partial_vm
