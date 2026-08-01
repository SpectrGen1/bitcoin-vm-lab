#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "$0")/../.." && pwd)/lib/common.sh"
vm="${1:?VM required}"; valid_vm "$vm"; init_layout
need qemu-img; need virt-install; need virsh; need sha256sum
is_defined "$vm" && die "$(domain "$vm") already exists"

iso_var="${vm^^}_ISO"; sum_var="${vm^^}_ISO_SHA256"
iso="${!iso_var:-}"; expected="${!sum_var:-}"
[[ -n "$iso" && "$iso" = /* && -f "$iso" ]] || die "set $iso_var to an existing absolute ISO path"
[[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "set $sum_var to the ISO's 64-character SHA-256"
actual="$(sha256sum "$iso" | awk '{print $1}')"
[[ "${actual,,}" == "${expected,,}" ]] || die "$iso_var checksum mismatch"

vmdir="$(vm_dir "$vm")"; install -d -m 0750 "$vmdir"
command -v setfacl >/dev/null && setfacl -m "u:$QEMU_USER:--x" "$vmdir" || true
qemu-img create -f qcow2 "$vmdir/system.qcow2" "${VM_DISK_GIB}G"
qemu-img create -f qcow2 "$vmdir/application.qcow2" "${APP_DISK_GIB}G"
chmod 0660 "$vmdir"/*.qcow2
command -v setfacl >/dev/null && setfacl -m "u:$QEMU_USER:rw-" "$vmdir"/*.qcow2 || true

boot=()
[[ "$BVML_BOOT_UEFI" == 1 ]] && boot=(--boot uefi)
if ! virt-install --connect "$LIBVIRT_URI" --name "$(domain "$vm")" \
    --memory "$VM_MEMORY_MIB" --vcpus "$VM_CPUS" --cpu host-passthrough \
    --virt-type kvm --os-variant generic "${boot[@]}" \
    --disk "path=$vmdir/system.qcow2,format=qcow2,bus=virtio" \
    --disk "path=$vmdir/application.qcow2,format=qcow2,bus=virtio" \
    --disk "path=$iso,device=cdrom,readonly=on" \
    --network "network=$BVML_NETWORK,model=virtio" \
    --graphics spice --video virtio --noautoconsole; then
  die "virt-install failed; disks were retained at $vmdir for diagnosis"
fi
note "created $(domain "$vm"); complete its installer before attaching Bitcoin data"
