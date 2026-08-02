#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/lib/common.sh"
failed=0
check() { if "$@"; then printf 'ok   %s\n' "$*"; else printf 'FAIL %s\n' "$*" >&2; failed=1; fi; }
for cmd in virsh qemu-img virt-install virt-make-fs virt-ls virt-cat virt-customize \
  virt-filesystems flock sha256sum setfacl jq xmllint lsof curl gpgv base64; do
  command -v "$cmd" >/dev/null && printf 'ok   command %s\n' "$cmd" || { echo "FAIL missing command $cmd" >&2; failed=1; }
done
if [[ "$UBUNTU_IMAGE_MODE" == cloud ]]; then
  check test -r "$LIBGUESTFS_APPLIANCE_PATH/kernel"
  check test -r "$LIBGUESTFS_APPLIANCE_PATH/initrd"
  check test -r "$LIBGUESTFS_APPLIANCE_PATH/root"
fi
check test -c /dev/kvm
check virshq version
command -v virt-host-validate >/dev/null && check virt-host-validate qemu || { echo "FAIL virt-host-validate missing" >&2; failed=1; }
if [[ "$BVML_BOOT_UEFI" == 1 ]]; then
  firmware="$(find /usr/share/edk2* /usr/share/qemu -type f \( -iname 'OVMF_CODE*.fd' -o -iname 'OVMF_CODE*.secboot.fd' \) 2>/dev/null | head -1)"
  [[ -n "$firmware" ]] && echo "ok   UEFI firmware $firmware" || { echo "FAIL UEFI firmware not found" >&2; failed=1; }
fi
if [[ -d "$BVML_STORAGE" ]]; then
  check sudo -u "$QEMU_USER" test -x "$BVML_STORAGE"
  [[ ! -f "$CANONICAL" ]] || check sudo -u "$QEMU_USER" test -r "$CANONICAL"
  probe="$(mktemp "$ACTIVE_DIR/.qemu-access.XXXXXX")"
  chmod 0600 "$probe"
  setfacl -m "u:$QEMU_USER:rw-" "$probe"
  check sudo -u "$QEMU_USER" test -r "$probe"
  check sudo -u "$QEMU_USER" test -w "$probe"
  rm -f -- "$probe"
else
  echo "FAIL storage not initialized: $BVML_STORAGE" >&2; failed=1
fi
exit "$failed"
