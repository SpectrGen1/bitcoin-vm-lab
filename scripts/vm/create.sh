#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "$0")/../.." && pwd)/lib/common.sh"
vm="${1:?VM required}"; valid_vm "$vm"

create_vm() {
init_layout
need qemu-img; need virt-install; need virsh; need sha256sum
assert_provisioning_safe
is_defined "$vm" && die "$(domain "$vm") already exists"

if [[ "$vm" == umbrel ]]; then
  [[ -f "$UMBREL_PROFILE" &&
     "$(sha256sum "$UMBREL_PROFILE" | awk '{print $1}')" == "${UMBREL_PROFILE_SHA256,,}" ]] ||
    die "pinned Umbrel profile is missing or invalid"
  [[ -f "$UMBREL_ISO" && -f "$UMBREL_ISO.manifest.json" ]] ||
    die "run 'bvml media-fetch umbrel' first"
  [[ "$(sha256sum "$UMBREL_ISO" | awk '{print $1}')" == "${UMBREL_ISO_SHA256,,}" ]] ||
    die "staged Umbrel installer digest mismatch"
  jq -e --arg profile "${UMBREL_PROFILE_SHA256,,}" --arg sha "${UMBREL_ISO_SHA256,,}" \
    --arg path "$UMBREL_ISO" '
      .platform=="umbrel" and .profile_digest==$profile and
      .sha256==$sha and .path==$path
    ' "$UMBREL_ISO.manifest.json" >/dev/null ||
    die "Umbrel installer generation manifest differs from active pinned inputs"
  file "$UMBREL_ISO" | grep -qi 'ISO 9660' ||
    die "staged Umbrel installer is not ISO9660"
  xorriso -indev "$UMBREL_ISO" -pvd_info 2>&1 |
    grep -Fq "Volume id    : '$(jq -r .os.iso_label "$UMBREL_PROFILE")'" ||
    die "staged Umbrel installer volume identity mismatch"
  vmdir="$(vm_dir umbrel)"
  if [[ -d "$vmdir" ]] && find "$vmdir" -mindepth 1 -print -quit | grep -q .; then
    die "partial Umbrel disk state exists; use create-cleanup after review"
	  fi
	  install -d -m 0750 "$vmdir"
	  if command -v setfacl >/dev/null; then
	    setfacl -m "u:$QEMU_USER:--x" "$vmdir" ||
	      die "could not grant system QEMU traversal access to $vmdir"
	  fi
	  qemu-img create -f qcow2 "$vmdir/system.qcow2" "${UMBREL_SYSTEM_DISK_GIB}G"
	  qemu-img create -f qcow2 "$vmdir/application.qcow2" "${APP_DISK_GIB}G"
	  chmod 0660 "$vmdir"/*.qcow2
	  if command -v setfacl >/dev/null; then
	    setfacl -m "u:$QEMU_USER:rw-" "$vmdir"/*.qcow2 ||
	      die "could not grant system QEMU access to Umbrel disks"
	  fi
	  sudo -u "$QEMU_USER" test -x "$vmdir" &&
	    sudo -u "$QEMU_USER" test -r "$vmdir/system.qcow2" &&
	    sudo -u "$QEMU_USER" test -w "$vmdir/system.qcow2" &&
	    sudo -u "$QEMU_USER" test -r "$vmdir/application.qcow2" &&
	    sudo -u "$QEMU_USER" test -w "$vmdir/application.qcow2" ||
	    die "system QEMU cannot traverse and read/write the Umbrel VM storage"
  boot=(); [[ "$BVML_BOOT_UEFI" == 1 ]] && boot=(--boot uefi)
	  virt-install --connect "$LIBVIRT_URI" --name "$(domain umbrel)" \
    --memory "$VM_MEMORY_MIB" --vcpus "$VM_CPUS" --cpu host-passthrough \
    --virt-type kvm --os-variant generic "${boot[@]}" \
	    --disk "path=$vmdir/system.qcow2,format=qcow2,bus=virtio,serial=$UMBREL_INSTALL_SERIAL,boot_order=2" \
	    --disk "path=$vmdir/application.qcow2,format=qcow2,bus=virtio,serial=BVML-UMBREL-APP,boot_order=3" \
	    --disk "path=$UMBREL_ISO,device=disk,bus=usb,readonly=on,serial=BVML-UMBREL-INST,boot_order=1" \
    --network "network=$BVML_NETWORK,model=virtio" \
    --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
    --graphics spice --video virtio --serial pty --noautoconsole --wait 0
  "$BVML_ROOT/scripts/vm/umbrel-install.sh"
	  installer_target="$(virshq domblklist "$(domain umbrel)" --details |
	    awk -v source="$UMBREL_ISO" '$4==source {print $3; exit}')"
	  [[ -n "$installer_target" ]] || die "installed VM has no identifiable installer attachment"
	  virshq detach-disk "$(domain umbrel)" "$installer_target" --config
	  [[ -z "$(virshq domblklist "$(domain umbrel)" --details |
	    awk -v source="$UMBREL_ISO" '$4==source {print $3}')" ]] ||
	    die "installer remains attached"
  virshq start "$(domain umbrel)"
  "$BVML_ROOT/scripts/vm/umbrel-onboard.sh"
  virshq shutdown "$(domain umbrel)"
  waited=0
  while ! is_shut_off umbrel; do
    (( waited < SHUTDOWN_TIMEOUT )) || die "Umbrel did not shut off after onboarding"
    sleep 2; waited=$((waited+2))
  done
  note "created, installed, onboarded, and management-provisioned Umbrel VM"
  return
fi

iso_var="${vm^^}_ISO"; sum_var="${vm^^}_ISO_SHA256"
iso="${!iso_var:-}"; expected="${!sum_var:-}"

vmdir="$(vm_dir "$vm")"
if [[ -d "$vmdir" ]] && find "$vmdir" -mindepth 1 -print -quit | grep -q .; then
  die "partial VM disk state exists at $vmdir; inspect it or run 'bvml create-cleanup $vm --confirm-remove-partial'"
fi
install -d -m 0750 "$vmdir"
command -v setfacl >/dev/null && setfacl -m "u:$QEMU_USER:--x" "$vmdir" || true
if [[ "$vm" == ubuntu && "$UBUNTU_IMAGE_MODE" == cloud ]]; then
  [[ "$UBUNTU_CLOUD_IMAGE" = /* && -f "$UBUNTU_CLOUD_IMAGE" ]] ||
    die "run 'bvml media-fetch ubuntu' first"
  [[ "$UBUNTU_CLOUD_IMAGE_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] ||
    die "configure UBUNTU_CLOUD_IMAGE_SHA256"
  validate_cloud_image "$UBUNTU_CLOUD_IMAGE" "$UBUNTU_CLOUD_IMAGE_SHA256"
  [[ "$UBUNTU_CLOUD_SSH_KEY" = /* && -f "$UBUNTU_CLOUD_SSH_KEY" ]] ||
    die "configure an absolute UBUNTU_CLOUD_SSH_KEY public-key path"
  [[ "$UBUNTU_CLOUD_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ &&
     ! "$UBUNTU_CLOUD_SSH_KEY" =~ [[:cntrl:]] ]] ||
    die "Ubuntu cloud user or SSH key path is unsafe"
  profile_release_dir="$(dirname "$KNOTS_RELEASE_PROFILE")"
  for file in "$KNOTS_RELEASE_PROFILE" "$KNOTS_RDTS_PROFILE" \
    "$profile_release_dir/SHA256SUMS" "$profile_release_dir/SHA256SUMS.asc" \
    "$profile_release_dir/trusted-signers.gpg" "$CHECKPOINT_PROFILE_FILE"; do
    [[ -f "$file" ]] || die "run 'bvml profiles-install' first; missing $file"
  done
  qemu-img convert -p -f qcow2 -O qcow2 "$UBUNTU_CLOUD_IMAGE" "$vmdir/system.qcow2"
  qemu-img resize "$vmdir/system.qcow2" "${VM_DISK_GIB}G"
  qemu-img check "$vmdir/system.qcow2" >/dev/null
  info="$(qemu-img info --output=json "$vmdir/system.qcow2")"
  [[ "$(jq -r '.format' <<<"$info")" == qcow2 &&
     -z "$(jq -r '.["backing-filename"] // empty' <<<"$info")" &&
     "$(jq -r '.["virtual-size"]' <<<"$info")" == "$((VM_DISK_GIB * 1073741824))" ]] ||
    die "converted Ubuntu system disk failed standalone format/size validation"
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
  trap 'rm -f -- "$guest_conf" "${domain_xml:-}"' RETURN
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
    --copy-in "$KNOTS_RELEASE_PROFILE:/etc/bvml/releases" \
    --copy-in "$KNOTS_RDTS_PROFILE:/etc/bvml/releases" \
    --copy-in "$profile_release_dir/SHA256SUMS:/etc/bvml/releases" \
    --copy-in "$profile_release_dir/SHA256SUMS.asc:/etc/bvml/releases" \
    --copy-in "$profile_release_dir/trusted-signers.gpg:/etc/bvml/releases" \
    --copy-in "$CHECKPOINT_PROFILE_FILE:/etc/bvml" \
    --run-command "mv /etc/bvml/$(basename "$CHECKPOINT_PROFILE_FILE") /etc/bvml/checkpoint-profile.json" \
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
      --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
      --graphics spice --video virtio --import --noautoconsole --print-xml >"$domain_xml"; then
    die "unattended Ubuntu XML generation failed; persistent disks were retained at $vmdir"
  fi
  xmllint --noout "$domain_xml" || die "generated unattended Ubuntu domain XML is invalid"
  xmllint --xpath 'boolean(/domain/devices/channel[@type="unix"]/target[@type="virtio" and @name="org.qemu.guest_agent.0"])' \
    "$domain_xml" | grep -qx true || die "generated domain XML lacks the QGA Virtio channel"
  for required in /etc/bvml/knots.env /etc/bvml/checkpoint-profile.json \
    /usr/local/libexec/bvml/ubuntu-knots-rdts.sh; do
    virt-cat -a "$vmdir/system.qcow2" "$required" >/dev/null ||
      die "offline customization did not install required guest file: $required"
  done
  qemu-img check "$vmdir/system.qcow2" >/dev/null ||
    die "customized Ubuntu system disk failed qemu-img check"
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
