#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "$0")/../.." && pwd)/lib/common.sh"
vm="${1:?VM required}"; valid_vm "$vm"; init_layout
need qemu-img; need virt-install; need virsh
is_defined "$vm" && die "$(domain "$vm") already exists"
vmdir="$(vm_dir "$vm")"; install -d -m 0750 "$vmdir"
qemu-img create -f qcow2 "$vmdir/system.qcow2" "${VM_DISK_GIB}G"
qemu-img create -f qcow2 "$vmdir/application.qcow2" "${APP_DISK_GIB}G"

iso_var="${vm^^}_ISO"; iso="${!iso_var:-}"
[[ -n "$iso" && -f "$iso" ]] || die "set $iso_var to an existing absolute ISO path in config/local.env"
note "Creating $(domain "$vm"); complete the OS installer in the console."
virt-install --connect "$LIBVIRT_URI" --name "$(domain "$vm")" --memory "$VM_MEMORY_MIB" --vcpus "$VM_CPUS" \
  --cpu host-passthrough --virt-type kvm --os-variant generic --boot uefi \
  --disk "path=$vmdir/system.qcow2,format=qcow2,bus=virtio" \
  --disk "path=$vmdir/application.qcow2,format=qcow2,bus=virtio" \
  --disk "path=$iso,device=cdrom,readonly=on" --network "network=$BVML_BRIDGE,model=virtio" \
  --graphics spice --video virtio --noautoconsole
note "Attach Bitcoin data only through: bin/bvml start $vm"
