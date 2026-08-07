#!/usr/bin/env bash
# Offline filesystem conversion for the immutable StartOS adapter candidate.
set -Eeuo pipefail

fail() { echo "error: $*" >&2; exit 1; }
[[ $# -ge 3 ]] || fail "usage: $0 {convert|finalize|inspect} SERIAL SIZE_BYTES [INDEX_JSON]"
action="$1"; serial="$2"; expected_size="$3"; indexes="${4:-[]}"
[[ "$serial" =~ ^[A-Za-z0-9._-]+$ && "$expected_size" =~ ^[1-9][0-9]*$ ]] ||
  fail "unsafe maintenance-disk identity"
jq -e 'type=="array" and all(.[]; type=="string" and length>0)' <<<"$indexes" >/dev/null ||
  fail "invalid checkpoint index contract"

for command in jq lsblk findmnt blkid mount umount e2fsck btrfs btrfs-convert; do
  command -v "$command" >/dev/null || fail "missing maintenance command: $command"
done
mapfile -t matches < <(
  find /dev/disk/by-id -maxdepth 1 -type l -name "*${serial}*" -print |
    while read -r path; do readlink -f "$path"; done | sort -u
)
((${#matches[@]} == 1)) || fail "maintenance disk serial is missing or ambiguous"
device="${matches[0]}"
[[ "$(lsblk -bdno SIZE "$device")" == "$expected_size" &&
   "$(lsblk -dno TYPE "$device")" == disk &&
   "$(lsblk -nrpo NAME "$device" | wc -l)" == 1 ]] ||
  fail "maintenance disk size/type/partition identity mismatch"
! findmnt -rn -S "$device" | grep -q . || fail "maintenance disk is already mounted"

mountpoint=/mnt/bvml-startos-adapter
install -d -m 0700 "$mountpoint"
cleanup() { mountpoint -q "$mountpoint" && umount "$mountpoint" || true; }
trap cleanup EXIT

validate_tree() {
  [[ -d "$mountpoint/blocks" && -d "$mountpoint/chainstate" ]] ||
    fail "converted datadir lacks blocks or chainstate"
  local index relative_path
  while IFS= read -r index; do
    case "$index" in
      "basic block filter index") relative_path=indexes/blockfilter/basic ;;
      txindex) relative_path=indexes/txindex ;;
      coinstatsindex) relative_path=indexes/coinstats ;;
      *) fail "unsupported checkpoint index layout: $index" ;;
    esac
    [[ -d "$mountpoint/$relative_path" ]] ||
      fail "converted datadir lacks required index $index"
  done < <(jq -r '.[]' <<<"$indexes")
}

readonly_check() {
  btrfs check --readonly "$device"
  mount -o ro,nodev,nosuid "$device" "$mountpoint"
  [[ "$(findmnt -rn -o FSTYPE -T "$mountpoint" | tail -1)" == btrfs ]] ||
    fail "maintenance disk did not mount as Btrfs"
  validate_tree
  uuid="$(findmnt -rn -o UUID -T "$mountpoint" | tail -1)"
  [[ -n "$uuid" ]] || fail "converted Btrfs filesystem lacks a UUID"
  umount "$mountpoint"
}

case "$action" in
  convert)
    [[ "$(blkid -s TYPE -o value "$device")" == ext4 ]] ||
      fail "conversion candidate is not the expected ext4 filesystem"
    set +e
    e2fsck -f -p "$device"
    fsck_status=$?
    set -e
    (( fsck_status == 0 || fsck_status == 1 )) ||
      fail "full ext4 filesystem check failed with status $fsck_status"
    btrfs-convert "$device"
    readonly_check
    mount -o ro,nodev,nosuid "$device" "$mountpoint"
    btrfs subvolume list "$mountpoint" | grep -Eq ' path ext2_saved$' ||
      fail "btrfs-convert rollback subvolume is absent before finalization"
    umount "$mountpoint"
    ;;
  finalize)
    [[ "$(blkid -s TYPE -o value "$device")" == btrfs ]] ||
      fail "finalization candidate is not Btrfs"
    readonly_check
    mount -o rw,nodev,nosuid "$device" "$mountpoint"
    if btrfs subvolume list "$mountpoint" | grep -Eq ' path ext2_saved$'; then
      btrfs subvolume delete "$mountpoint/ext2_saved"
    else
      echo "conversion rollback subvolume was already removed"
    fi
    sync -f "$mountpoint"
    umount "$mountpoint"
    readonly_check
    ;;
  inspect)
    [[ "$(blkid -s TYPE -o value "$device")" == btrfs ]] ||
      fail "adapter filesystem is not Btrfs"
    readonly_check
    mount -o ro,nodev,nosuid "$device" "$mountpoint"
    ! btrfs subvolume list "$mountpoint" | grep -Eq ' path ext2_saved$' ||
      fail "conversion rollback subvolume still exists"
    printf 'filesystem=btrfs\nfilesystem_uuid=%s\n' \
      "$(findmnt -rn -o UUID -T "$mountpoint" | tail -1)"
    umount "$mountpoint"
    ;;
  *) fail "unknown maintenance action: $action" ;;
esac
