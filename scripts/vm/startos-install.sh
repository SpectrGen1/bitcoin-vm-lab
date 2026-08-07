#!/usr/bin/env bash
# Fully unattended pinned StartOS install/setup through the setup API.
set -Eeuo pipefail
source "$(cd "$(dirname "$0")/../.." && pwd)/lib/common.sh"

[[ "$(domain_state startos)" == running ]] || die "StartOS installer VM is not running"
[[ -x "$STARTOS_CLI" &&
   "$(sha256sum "$STARTOS_CLI" | awk '{print $1}')" == "$(jq -r .os.start_cli_sha256 "$STARTOS_PROFILE")" ]] ||
  die "pinned start-cli is absent or invalid; run media-fetch startos"
[[ "$STARTOS_CREDENTIALS_FILE" == /* && -f "$STARTOS_CREDENTIALS_FILE" &&
   -z "$(find "$STARTOS_CREDENTIALS_FILE" -maxdepth 0 -perm /077 -print -quit)" ]] ||
  die "STARTOS_CREDENTIALS_FILE must be an absolute mode-0600 file"
[[ "$STARTOS_SSH_PUBLIC_KEY" == /* && -f "$STARTOS_SSH_PUBLIC_KEY" ]] ||
  die "configure STARTOS_SSH_PUBLIC_KEY"

password="$(jq -er '.password|select(type=="string" and length>=12)' "$STARTOS_CREDENTIALS_FILE")"
server_name="$(jq -er '.server_name|select(type=="string" and test("^[A-Za-z0-9 ._-]{1,64}$"))' "$STARTOS_CREDENTIALS_FILE")"
hostname="$(jq -er '.hostname|select(type=="string" and test("^[a-z0-9][a-z0-9-]{0,62}$"))' "$STARTOS_CREDENTIALS_FILE")"
trap 'unset password' EXIT

waited=0 address=
while [[ -z "$address" ]]; do
  address="$(domain_ipv4 startos)"
  (( waited < STARTOS_INSTALL_TIMEOUT )) || die "StartOS setup API address was not discovered"
  [[ -n "$address" ]] || { sleep 2; waited=$((waited+2)); }
done
cli=("$STARTOS_CLI" -H "http://$address")

disks=
while :; do
  if disks="$("${cli[@]}" setup disk list --format json 2>/dev/null)" &&
     jq -e 'type=="array"' <<<"$disks" >/dev/null 2>&1; then break; fi
  (( waited < STARTOS_INSTALL_TIMEOUT )) || die "StartOS setup disk API did not become ready"
  sleep 3; waited=$((waited+3))
done

expected_bytes=$((STARTOS_SYSTEM_DISK_GIB * 1073741824))
data_bytes=$((APP_DISK_GIB * 1073741824))
guest_exec_sync startos /bin/lsblk 30 -J -b -o PATH,SERIAL,MODEL,SIZE,TYPE
lsblk_json="$GUEST_EXEC_STDOUT"
disk="$(jq -er --arg serial "$STARTOS_INSTALL_SERIAL" --argjson size "$expected_bytes" \
  --argjson model "$(jq -c .os.disk_identity.model "$STARTOS_PROFILE")" '
    [.blockdevices[] | select(.serial==$serial and .size==$size and
      .type=="disk" and .model==$model)] |
    if length==1 then .[0].path else empty end' <<<"$lsblk_json")" ||
  die "guest disk identity mismatch for StartOS system disk"
data_disk="$(jq -er --arg serial "$STARTOS_DATA_SERIAL" --argjson size "$data_bytes" \
  --argjson model "$(jq -c .os.disk_identity.model "$STARTOS_PROFILE")" '
    [.blockdevices[] | select(.serial==$serial and .size==$size and
      .type=="disk" and .model==$model)] |
    if length==1 then .[0].path else empty end' <<<"$lsblk_json")" ||
  die "guest disk identity mismatch for StartOS application disk"
vendor="$(jq -r .os.disk_identity.vendor "$STARTOS_PROFILE")"
jq -e --arg disk "$disk" --arg data "$data_disk" --arg vendor "$vendor" \
  --argjson model "$(jq -c .os.disk_identity.model "$STARTOS_PROFILE")" \
  --argjson os_size "$expected_bytes" --argjson data_size "$data_bytes" '
    ([.[] | select(.logicalname==$disk and .capacity==$os_size and
      .vendor==$vendor and .model==$model)] | length==1) and
    ([.[] | select(.logicalname==$data and .capacity==$data_size and
      .vendor==$vendor and .model==$model)] | length==1)
  ' <<<"$disks" >/dev/null ||
  die "StartOS setup API disk identities disagree with guest serial/model/capacity evidence"
[[ "$data_disk" != "$disk" ]] || die "StartOS OS and application disks resolved to the same device"
[[ "$disk" =~ ^/dev/[A-Za-z0-9._/-]+$ ]] || die "installer returned an unsafe disk path"
virshq dumpxml "$(domain startos)" |
  xmllint --xpath "string(//disk[source/@file='$(vm_dir startos)/system.qcow2']/serial)" - |
  grep -Fxq "$STARTOS_INSTALL_SERIAL" ||
  die "host domain XML does not bind the pinned StartOS target serial"
virshq dumpxml "$(domain startos)" |
  xmllint --xpath "string(//disk[source/@file='$(vm_dir startos)/application.qcow2']/serial)" - |
  grep -Fxq "$STARTOS_DATA_SERIAL" ||
  die "host domain XML does not bind the pinned StartOS data serial"

setup_status="$("${cli[@]}" setup status --format json)"
status="$(jq -er '.status' <<<"$setup_status")"
run_setup_execute=0
case "$status" in
  incomplete)
    guid="$(jq -er '.guid|select(type=="string" and length>0)' <<<"$setup_status")"
    [[ "$(jq -er '.osDrive' <<<"$setup_status")" == "$disk" ]] ||
      die "incomplete StartOS setup belongs to a different OS disk"
    note "resuming the existing incomplete StartOS installation"
    run_setup_execute=1
    ;;
  complete)
    note "resuming StartOS after setup execution completed"
    ;;
  uninitialized | not-installed | ready)
    install_result="$("${cli[@]}" setup install-os "$disk" --data-drive "$data_disk" --wipe)"
    guid="$(jq -er '.guid // .diskGuid // .result.guid // select(type=="string")' <<<"$install_result" 2>/dev/null ||
      sed -n 's/.*\\([0-9A-Za-z_-]\\{16,\\}\\).*/\\1/p' <<<"$install_result" | head -1)"
    run_setup_execute=1
    ;;
  *)
    die "StartOS setup state '$status' is not safe for installation or resume"
    ;;
esac
if (( run_setup_execute )); then
  [[ "$guid" =~ ^[0-9A-Za-z_-]{16,}$ ]] ||
    die "StartOS install completed without a machine-readable disk GUID"
  PASSWORD="$password" "${cli[@]}" setup execute --guid "$guid" --name "$server_name" --hostname "$hostname"
  waited=0
  while :; do
    status="$("${cli[@]}" setup status --format json | jq -er '.status')"
    [[ "$status" == complete ]] && break
    [[ "$status" == incomplete ]] ||
      die "StartOS setup entered unexpected state '$status'"
    (( waited < STARTOS_INSTALL_TIMEOUT )) ||
      die "StartOS setup execution did not complete"
    sleep 3
    waited=$((waited+3))
  done
fi
"${cli[@]}" setup complete --format json >/dev/null

# Preserve the newly generated server CA, then boot the installed OS without the
# installer.  The setup API and authenticated StartOS API are different services.
setup_status="$("${cli[@]}" setup status --format json)"
root_ca="$(jq -er '.rootCa|select(type=="string" and startswith("-----BEGIN CERTIFICATE-----"))' \
  <<<"$setup_status")"
root_ca_file="${STARTOS_CREDENTIALS_FILE}.root-ca.pem"
root_ca_tmp="${root_ca_file}.tmp.$$"
trap 'unset password; rm -f "${root_ca_tmp:-}"' EXIT
umask 077
printf '%s\n' "$root_ca" >"$root_ca_tmp"
mv -f "$root_ca_tmp" "$root_ca_file"

virshq shutdown "$(domain startos)"
waited=0
while ! is_shut_off startos; do
  (( waited < SHUTDOWN_TIMEOUT )) ||
    die "StartOS installer environment did not shut down after setup"
  sleep 2
  waited=$((waited+2))
done
installer_target="$(virshq domblklist "$(domain startos)" --details |
  awk -v source="$STARTOS_ISO" '$4==source {print $3; exit}')"
[[ -n "$installer_target" ]] || die "StartOS installer attachment disappeared unexpectedly"
virshq detach-disk "$(domain startos)" "$installer_target" --config
[[ -z "$(virshq domblklist "$(domain startos)" --details |
  awk -v source="$STARTOS_ISO" '$4==source {print $3}')" ]] ||
  die "StartOS installer remains attached after setup"
virshq start "$(domain startos)"
"$BVML_ROOT/scripts/vm/startos-onboard.sh"
note "installed, initialized, management-provisioned, and verified pinned StartOS"
