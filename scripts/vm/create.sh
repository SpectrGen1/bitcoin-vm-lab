#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "$0")/../.." && pwd)/lib/common.sh"
vm="${1:?VM required}"; valid_vm "$vm"

create_vm() {
init_layout
need qemu-img; need virt-install; need virsh; need sha256sum
assert_provisioning_safe
is_defined "$vm" && die "$(domain "$vm") already exists"

iso_var="${vm^^}_ISO"; sum_var="${vm^^}_ISO_SHA256"
iso="${!iso_var:-}"; expected="${!sum_var:-}"

vmdir="$(vm_dir "$vm")"; install -d -m 0750 "$vmdir"
command -v setfacl >/dev/null && setfacl -m "u:$QEMU_USER:--x" "$vmdir" || true
if [[ "$vm" == ubuntu && "$UBUNTU_IMAGE_MODE" == cloud ]]; then
  [[ "$UBUNTU_CLOUD_IMAGE" = /* && -f "$UBUNTU_CLOUD_IMAGE" ]] ||
    die "run 'bvml media-fetch ubuntu' first"
  [[ "$UBUNTU_CLOUD_IMAGE_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] ||
    die "configure UBUNTU_CLOUD_IMAGE_SHA256"
  actual="$(sha256sum "$UBUNTU_CLOUD_IMAGE" | awk '{print $1}')"
  [[ "${actual,,}" == "${UBUNTU_CLOUD_IMAGE_SHA256,,}" ]] ||
    die "Ubuntu cloud image checksum mismatch"
  [[ "$UBUNTU_CLOUD_SSH_KEY" = /* && -f "$UBUNTU_CLOUD_SSH_KEY" ]] ||
    die "configure an absolute UBUNTU_CLOUD_SSH_KEY public-key path"
  [[ "$UBUNTU_CLOUD_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ &&
     ! "$UBUNTU_CLOUD_SSH_KEY" =~ [[:cntrl:]] ]] ||
    die "Ubuntu cloud user or SSH key path is unsafe"
  for file in "$BVML_HOST_CONFIG_DIR"/releases/knots-version.env "$BVML_HOST_CONFIG_DIR"/releases/knots-rdts.env \
    "$BVML_HOST_CONFIG_DIR"/releases/SHA256SUMS "$BVML_HOST_CONFIG_DIR"/releases/SHA256SUMS.asc \
    "$BVML_HOST_CONFIG_DIR"/releases/signing-key.gpg "$BVML_HOST_CONFIG_DIR"/checkpoint-profile.json; do
    [[ -f "$file" ]] || die "run 'bvml profiles-install' first; missing $file"
  done
  qemu-img convert -p -f qcow2 -O qcow2 "$UBUNTU_CLOUD_IMAGE" "$vmdir/system.qcow2"
  qemu-img resize "$vmdir/system.qcow2" "${VM_DISK_GIB}G"
else
  [[ -n "$iso" && "$iso" = /* && -f "$iso" ]] || die "set $iso_var to an existing absolute ISO path"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "set $sum_var to the ISO's 64-character SHA-256"
  actual="$(sha256sum "$iso" | awk '{print $1}')"
  [[ "${actual,,}" == "${expected,,}" ]] || die "$iso_var checksum mismatch"
  qemu-img create -f qcow2 "$vmdir/system.qcow2" "${VM_DISK_GIB}G"
fi
qemu-img create -f qcow2 "$vmdir/application.qcow2" "${APP_DISK_GIB}G"
chmod 0660 "$vmdir"/*.qcow2
command -v setfacl >/dev/null && setfacl -m "u:$QEMU_USER:rw-" "$vmdir"/*.qcow2 || true

boot=()
[[ "$BVML_BOOT_UEFI" == 1 ]] && boot=(--boot uefi)
if [[ "$vm" == ubuntu && "$UBUNTU_IMAGE_MODE" == cloud ]]; then
  need virt-customize
  guest_conf="$(mktemp)"
  printf '%s\n' \
    'BITCOIN_MOUNT=/srv/bitcoin' 'BITCOIN_DEVICE=/dev/vdc' \
    "BITCOIN_SERVICE_USER=$UBUNTU_CLOUD_USER" "BITCOIN_SERVICE_GROUP=$UBUNTU_CLOUD_USER" \
    "MAX_TIP_AGE_SECONDS=$MAX_TIP_AGE_SECONDS" \
    'KNOTS_RELEASE_PROFILE=/etc/bvml/releases/knots-version.env' \
    "KNOTS_RELEASE_PROFILE_SHA256=$KNOTS_RELEASE_PROFILE_SHA256" \
    'KNOTS_RDTS_PROFILE=/etc/bvml/releases/knots-rdts.env' \
    "KNOTS_RDTS_PROFILE_SHA256=$KNOTS_RDTS_PROFILE_SHA256" \
    'CHECKPOINT_PROFILE_FILE=/etc/bvml/checkpoint-profile.json' \
    "CHECKPOINT_PROFILE_SHA256=$CHECKPOINT_PROFILE_SHA256" >"$guest_conf"
  sudo -E env LIBGUESTFS_PATH="$LIBGUESTFS_APPLIANCE_PATH" LIBGUESTFS_BACKEND=direct \
    virt-customize -a "$vmdir/system.qcow2" --network \
    --install qemu-guest-agent,jq,curl,gnupg \
    --mkdir /usr/local/libexec/bvml --mkdir /etc/bvml/releases \
    --ssh-inject "$UBUNTU_CLOUD_USER:file:$UBUNTU_CLOUD_SSH_KEY" \
    --copy-in "$BVML_ROOT/scripts/vm/guest/ubuntu-knots-rdts.sh:/usr/local/libexec/bvml" \
    --copy-in "$guest_conf:/etc/bvml" \
    --copy-in "$BVML_HOST_CONFIG_DIR/releases/knots-version.env:/etc/bvml/releases" \
    --copy-in "$BVML_HOST_CONFIG_DIR/releases/knots-rdts.env:/etc/bvml/releases" \
    --copy-in "$BVML_HOST_CONFIG_DIR/releases/SHA256SUMS:/etc/bvml/releases" \
    --copy-in "$BVML_HOST_CONFIG_DIR/releases/SHA256SUMS.asc:/etc/bvml/releases" \
    --copy-in "$BVML_HOST_CONFIG_DIR/releases/signing-key.gpg:/etc/bvml/releases" \
    --copy-in "$BVML_HOST_CONFIG_DIR/checkpoint-profile.json:/etc/bvml" \
    --run-command "mv /etc/bvml/$(basename "$guest_conf") /etc/bvml/knots.env" \
    --run-command 'chmod 0755 /usr/local/libexec/bvml/ubuntu-knots-rdts.sh' \
    --run-command 'chown -R root:root /etc/bvml /usr/local/libexec/bvml' \
    --run-command 'chmod 0644 /etc/bvml/knots.env /etc/bvml/checkpoint-profile.json /etc/bvml/releases/*' \
    --run-command 'systemctl enable qemu-guest-agent.service'
  sudo chown "$USER:$QEMU_GROUP" "$vmdir"/*.qcow2
  domain_xml="$(mktemp)"
  if ! virt-install --connect "$LIBVIRT_URI" --name "$(domain "$vm")" \
      --memory "$VM_MEMORY_MIB" --vcpus "$VM_CPUS" --cpu host-passthrough \
      --virt-type kvm --os-variant ubuntu24.04 "${boot[@]}" \
      --disk "path=$vmdir/system.qcow2,format=qcow2,bus=virtio" \
      --disk "path=$vmdir/application.qcow2,format=qcow2,bus=virtio" \
      --network "network=$BVML_NETWORK,model=virtio" \
      --graphics spice --video virtio --import --noautoconsole --print-xml >"$domain_xml"; then
    die "unattended Ubuntu XML generation failed; persistent disks were retained at $vmdir"
  fi
  if ! virshq define "$domain_xml" >/dev/null; then
    die "unattended Ubuntu definition failed; persistent disks were retained at $vmdir"
  fi
  is_shut_off "$vm" || die "new unattended Ubuntu domain is unexpectedly active"
  note "created provisioned, shut-off $(domain "$vm"); checkpoint-bootstrap may start it"
elif ! virt-install --connect "$LIBVIRT_URI" --name "$(domain "$vm")" \
    --memory "$VM_MEMORY_MIB" --vcpus "$VM_CPUS" --cpu host-passthrough \
    --virt-type kvm --os-variant generic "${boot[@]}" \
    --disk "path=$vmdir/system.qcow2,format=qcow2,bus=virtio" \
    --disk "path=$vmdir/application.qcow2,format=qcow2,bus=virtio" \
    --disk "path=$iso,device=cdrom,readonly=on" \
    --network "network=$BVML_NETWORK,model=virtio" \
    --graphics spice --video virtio --noautoconsole; then
  die "virt-install failed; disks were retained at $vmdir for diagnosis"
fi
if [[ "$vm" != ubuntu || "$UBUNTU_IMAGE_MODE" != cloud ]]; then
  note "created $(domain "$vm"); complete its installer before attaching Bitcoin data"
fi
}

create_vm
