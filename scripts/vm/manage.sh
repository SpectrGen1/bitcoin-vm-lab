#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/lib/common.sh"
command="${1:?command}"; vm="${2:-}"

protect_canonical() {
  [[ -f "$CANONICAL" ]] || die "canonical image missing"
  chmod a-w "$CANONICAL"
  # The immutable bit is additional protection when supported; lack of support is OK.
  command -v chattr >/dev/null && chattr +i "$CANONICAL" 2>/dev/null || true
}
unprotect_canonical() {
  [[ -f "$CANONICAL" ]] || return 0
  command -v chattr >/dev/null && chattr -i "$CANONICAL" 2>/dev/null || true
  chmod u+w "$CANONICAL"
}
attach_overlay() {
  local name="$(domain "$vm")" path="$(overlay "$vm")"
  virshq attach-disk "$name" "$path" vdc --targetbus virtio --persistent --config --driver qemu --subdriver qcow2
}
detach_overlay() {
  local name="$(domain "$vm")"
  virshq detach-disk "$name" vdc --persistent --config 2>/dev/null || true
}
start_vm() {
  valid_vm "$vm"; is_defined "$vm" || die "VM has not been created: $vm"
  assert_no_owner; require_canonical; ! is_running "$vm" || die "$vm is already running"
  local path; path="$(overlay "$vm")"; install -d -m 0750 "$(dirname "$path")"
  [[ ! -e "$path" ]] || die "overlay exists; run discard or reset first"
  qemu-img create -f qcow2 -F qcow2 -b "$CANONICAL" "$path"
  # Let qemu read the overlay and its read-only backing disk under libvirt DAC rules.
  chmod 0644 "$path"; detach_overlay; attach_overlay
  write_owner "$vm"
  if ! virshq start "$(domain "$vm")"; then detach_overlay; rm -f -- "$path"; clear_owner; exit 1; fi
  note "$vm started with a fresh Bitcoin overlay. Guest instructions: docs/OPERATIONS.md"
}
stop_vm() {
  valid_vm "$vm"; is_defined "$vm" || die "VM not defined: $vm"; assert_owner "$vm"
  if is_running "$vm"; then
    note "Requesting clean guest shutdown..."; virshq shutdown "$(domain "$vm")"
    for _ in $(seq 1 60); do is_running "$vm" || break; sleep 2; done
    is_running "$vm" && die "guest still running; do not release data ownership"
  fi
  detach_overlay; clear_owner; note "$vm stopped; overlay retained for inspection or checkpoint promotion"
}
discard_vm() {
  valid_vm "$vm"; ! is_running "$vm" || die "stop $vm before discarding"
  [[ "$(owner_vm)" != "$vm" ]] || die "stop $vm before discarding"
  detach_overlay; rm -f -- "$(overlay "$vm")"; rmdir "$(dirname "$(overlay "$vm")")" 2>/dev/null || true
  note "Discarded $vm Bitcoin overlay; persistent OS/application disks were untouched"
}
checkpoint_create() {
  [[ ! -e "$CANONICAL" ]] || die "canonical already exists"
  qemu-img create -f qcow2 "$CANONICAL" "${BTC_DISK_GIB}G"; protect_canonical
  note "Empty protected canonical created. Start Ubuntu, format/mount the overlay, and sync Bitcoin Core."
}
checkpoint_update() {
  [[ -f "$(overlay ubuntu)" ]] || die "Ubuntu overlay missing"
  [[ "$(owner_vm)" != ubuntu ]] || die "stop Ubuntu cleanly before promotion"
  ! is_running ubuntu || die "Ubuntu is still running"
  # qemu-img rebase -b '' flattens the verified Ubuntu overlay into a standalone image.
  local candidate="$BVML_STORAGE/canonical/bitcoin-mainnet.new.qcow2"
  rm -f -- "$candidate"; qemu-img convert -p -O qcow2 "$(overlay ubuntu)" "$candidate"
  qemu-img check "$candidate"
  unprotect_canonical; mv -f -- "$candidate" "$CANONICAL"; protect_canonical
  note "Canonical promoted. Now run validate, then discard ubuntu to return it to the new checkpoint."
}
validate() {
  local failed=0; for x in virsh qemu-img flock; do command -v "$x" >/dev/null || { echo "missing: $x"; failed=1; }; done
  [[ -f "$CANONICAL" ]] && { qemu-img check "$CANONICAL" || failed=1; [[ ! -w "$CANONICAL" ]] || { echo 'canonical is writable'; failed=1; }; } || echo 'canonical not created yet'
  [[ -f "$OWNER_FILE" ]] && { local o; o="$(owner_vm)"; is_running "$o" || { echo "stale owner record for $o"; failed=1; }; }
  for x in ubuntu umbrel startos; do is_defined "$x" && virshq domblklist "$(domain "$x")" --details; done
  return "$failed"
}
status() {
  init_layout; echo "Storage: $BVML_STORAGE"; echo "Canonical: ${CANONICAL} $([[ -f "$CANONICAL" ]] && echo present || echo absent)"; echo "Owner: $(owner_vm || echo none)"; virshq list --all || true
}
case "$command" in
  init) init_layout; note "storage initialized at $BVML_STORAGE" ;;
  create) exec "$ROOT/scripts/vm/create.sh" "$vm" ;;
  start) with_lock start_vm ;;
  stop) with_lock stop_vm ;;
  discard) with_lock discard_vm ;;
  reset) with_lock discard_vm ;;
  checkpoint-create) with_lock checkpoint_create ;;
  checkpoint-update) with_lock checkpoint_update ;;
  checkpoint-protect) with_lock protect_canonical ;;
  validate) with_lock validate ;;
  status) status ;;
  *) die "unknown command: $command" ;;
esac
