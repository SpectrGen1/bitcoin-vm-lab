#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'run with sudo' >&2; exit 1; }
for cmd in emerge rc-update rc-service; do command -v "$cmd" >/dev/null || { echo "missing $cmd" >&2; exit 1; }; done

echo "The following project-specific USE file will be installed:"
echo "  /etc/portage/package.use/bitcoin-vm-lab"
install -d -m 0755 /etc/portage/package.use
tmp="$(mktemp)"
trap 'rm -f -- "$tmp"' EXIT
printf '%s\n' \
  '# bitcoin-vm-lab: system QEMU, daemon, NAT network, and libguestfs' \
  'app-emulation/libvirt libvirtd qemu virt-network' \
  'app-emulation/qemu spice vnc' \
  'media-libs/netpbm png' \
  'net-dns/dnsmasq script' \
  'net-libs/gnutls pkcs11 tools' >"$tmp"
if [[ ! -f /etc/portage/package.use/bitcoin-vm-lab ]] ||
   ! cmp -s "$tmp" /etc/portage/package.use/bitcoin-vm-lab; then
  install -m 0644 "$tmp" /etc/portage/package.use/bitcoin-vm-lab
fi

emerge --ask app-emulation/qemu app-emulation/libvirt app-emulation/virt-manager \
  app-emulation/libguestfs sys-firmware/edk2-bin sys-apps/acl app-misc/jq \
  net-misc/bridge-utils sys-fs/e2fsprogs dev-libs/libxml2 sys-process/lsof
rc-update add libvirtd default
rc-service libvirtd status >/dev/null 2>&1 || rc-service libvirtd start

operator="${SUDO_USER:-}"
if [[ -n "$operator" && "$operator" != root ]]; then
  usermod -aG libvirt,kvm "$operator"
  echo "Added $operator to libvirt,kvm; log out and back in."
fi
echo "Host packages/services prepared. Run: ./bin/bvml host-validate"
