#!/usr/bin/env bash
# Run as root. Installs the conventional Gentoo KVM/libvirt stack.
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'run with sudo' >&2; exit 1; }
for cmd in emerge eselect rc-update usermod; do command -v "$cmd" >/dev/null || { echo "missing $cmd" >&2; exit 1; }; done

install -d -m 0755 /etc/portage/package.use
cat >/etc/portage/package.use/bitcoin-vm-lab <<'EOF'
# Required by bitcoin-vm-lab: system QEMU, libvirtd, and libvirt NAT network.
app-emulation/libvirt libvirtd qemu virt-network
app-emulation/qemu spice vnc
EOF
emerge --ask app-emulation/qemu app-emulation/libvirt app-emulation/virt-manager \
  net-misc/bridge-utils sys-fs/e2fsprogs
rc-update add libvirtd default
rc-service libvirtd start

USER_NAME="${SUDO_USER:-${USER:-}}"
if [[ -n "$USER_NAME" && "$USER_NAME" != root ]]; then
  usermod -aG libvirt,kvm "$USER_NAME"
  echo "Added $USER_NAME to libvirt,kvm. Log out and back in before using bvml."
fi
[[ -e /dev/kvm ]] || echo 'WARNING: /dev/kvm is absent; enable KVM in the host kernel before creating VMs.' >&2
echo 'Verify virtualization with: virt-host-validate qemu; virsh -c qemu:///system list --all'
