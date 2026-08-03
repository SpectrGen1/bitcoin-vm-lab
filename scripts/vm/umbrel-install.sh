#!/usr/bin/env bash
# Drive the exact pinned graphical installer using bounded screenshot/OCR
# prompt matching. Keystrokes are sent only after all fingerprints match.
set -Eeuo pipefail
source "$(cd "$(dirname "$0")/../.." && pwd)/lib/common.sh"

domain_name="$(domain umbrel)"
need virsh; need tesseract
[[ "$(domain_state umbrel)" == running ]] || die "Umbrel installer VM is not running"
[[ -f "$UMBREL_PROFILE" ]] || die "pinned Umbrel profile is missing"

work="$(mktemp -d)"
cleanup() {
  local rc=$?
  if (( rc != 0 )); then
    local destination="$RUN_DIR/umbrel-installer-diagnostics-$(date -u +%Y%m%dT%H%M%SZ)"
    install -d -m 0700 "$destination"
    cp -a "$work/." "$destination/"
    echo "installer diagnostics preserved at $destination" >&2
  fi
  rm -rf -- "$work"
  return "$rc"
}
trap cleanup EXIT
banner="$(jq -r .os.installer_prompts.banner "$UMBREL_PROFILE")"
warning="$(jq -r .os.installer_prompts.warning "$UMBREL_PROFILE")"
select_prompt="$(jq -r .os.installer_prompts.select "$UMBREL_PROFILE")"
complete="$(jq -r .os.installer_prompts.complete "$UMBREL_PROFILE")"

capture_text() {
	  virshq screenshot "$domain_name" "$work/screen.ppm" >/dev/null
	  # Sparse VGA consoles are not detected by Tesseract's automatic page
	  # segmentation. Normalize the small, known OCR ambiguities observed for
	  # this pinned bitmap font before comparing the pinned prompt strings.
	  tesseract "$work/screen.ppm" stdout --psm 6 2>/dev/null |
	    sed -E \
	      -e 's/unbrel0S/umbrelOS/Ig' \
	      -e 's/umbrel0S/umbrelOS/Ig' \
	      -e 's/(^|[[:space:]])EMU[[:space:]]+HARDDISK/ QEMU HARDDISK/g' \
	      -e 's/([0-9]+)6([[:space:]]|$)/\1G\2/g' \
	      -e 's/(umbrelOS has been installed)[?]/\1!/Ig' |
	    tee "$work/screen.txt"
}
wait_text() {
  local wanted="$1" waited=0 text
  while (( waited < UMBREL_INSTALL_TIMEOUT )); do
    text="$(capture_text)"
    grep -Fq "$wanted" <<<"$text" && { printf '%s\n' "$text"; return 0; }
    sleep 2; waited=$((waited + 2))
	  done
	  die "installer prompt drift/timeout waiting for '$wanted'; OCR retained in $work"
}
wait_text_either() {
  local first="$1" second="$2" waited=0 text
  while (( waited < UMBREL_INSTALL_TIMEOUT )); do
    text="$(capture_text)"
    if grep -Fq "$first" <<<"$text" || grep -Fq "$second" <<<"$text"; then
      printf '%s\n' "$text"
      return 0
    fi
    sleep 2; waited=$((waited + 2))
  done
  die "installer prompt drift/timeout waiting for '$first' or '$second'; OCR retained in $work"
}
send_digit() {
  local digit="$1"
  [[ "$digit" =~ ^[1-9]$ ]] || die "installer target index is not a single safe digit"
  virshq send-key "$domain_name" --codeset linux "KEY_$digit" KEY_ENTER
}

screen="$(wait_text_either "$select_prompt" "$complete")"

# The installer prints model and human-readable capacity, but not serial. The
# serial and byte capacity are first proven against inactive domain XML.
xml="$(virshq dumpxml "$domain_name" --inactive)"
xmllint --xpath "boolean(//disk[@device='disk']/serial[text()='$UMBREL_INSTALL_SERIAL'])" \
  - <<<"$xml" | grep -qx true || die "installer target serial is absent from domain XML"
system_path="$(vm_dir umbrel)/system.qcow2"
system_target="$(xmllint --xpath "string(//disk[@device='disk'][serial='$UMBREL_INSTALL_SERIAL']/target/@dev)" - <<<"$xml")"
[[ "$system_target" =~ ^(sd|vd)[a-z]+$ ]] ||
  die "installer target serial does not resolve to a safe live block target"
live_capacity="$(virshq domblkinfo "$domain_name" "$system_target" |
  awk '$1=="Capacity:" {print $2}')"
[[ "$live_capacity" == "$((UMBREL_SYSTEM_DISK_GIB * 1073741824))" ]] ||
  die "installer target capacity mismatch"

if grep -Fq "$complete" <<<"$screen"; then
  grep -Fq "$(jq -r .os.installer_prompts.shutdown "$UMBREL_PROFILE")" <<<"$screen" ||
    die "installer completion screen lacks the pinned shutdown fingerprint"
  virshq send-key "$domain_name" KEY_ENTER
  waited=0
  while ! is_shut_off umbrel; do
    (( waited < UMBREL_INSTALL_TIMEOUT )) || die "installed Umbrel VM did not shut off"
    sleep 2; waited=$((waited + 2))
  done
  note "resumed the pinned completed installer and shut the VM off"
  exit 0
fi

grep -Fq "$banner" <<<"$screen" && grep -Fq "$warning" <<<"$screen" ||
  die "installer banner/warning fingerprints differ from the pinned release"
mapfile -t device_lines < <(grep -nF "$UMBREL_INSTALL_MODEL" <<<"$screen")
(( ${#device_lines[@]} >= 1 )) || die "pinned installer target model is absent"
# Device order is derived from displayed lsblk rows. The system disk is the
# unique row matching both model and configured GiB size.
target_line="$(grep -F "$UMBREL_INSTALL_MODEL" <<<"$screen" |
  grep -E "(^|[[:space:]])${UMBREL_SYSTEM_DISK_GIB}G([[:space:]]|$)" || true)"
[[ "$(wc -l <<<"$target_line")" == 1 && -n "$target_line" ]] ||
  die "installer target model/capacity is unavailable or ambiguous"
target_name="$(awk '{for (i=1; i<=NF; i++) if ($i ~ /^(sd|vd)[a-z]+$/) {print $i; exit}}' \
  <<<"$target_line")"
[[ "$target_name" =~ ^(sd|vd)[a-z]+$ ]] || die "installer target device name is unsafe"
target_index="$(awk '{gsub(/[^0-9]/, "", $1); print $1}' <<<"$target_line")"
[[ "$target_index" =~ ^[1-9]$ ]] ||
  die "could not derive the validated installer menu index"
send_digit "$target_index"
wait_text "$(jq -r .os.installer_prompts.selected "$UMBREL_PROFILE")" >/dev/null
completed_screen="$(wait_text "$complete")"
grep -Fq "$(jq -r .os.installer_prompts.shutdown "$UMBREL_PROFILE")" <<<"$completed_screen" ||
  die "installer completion screen lacks the pinned shutdown fingerprint"
virshq send-key "$domain_name" KEY_ENTER

waited=0
while ! is_shut_off umbrel; do
  (( waited < UMBREL_INSTALL_TIMEOUT )) || die "installed Umbrel VM did not shut off"
  sleep 2; waited=$((waited + 2))
done
note "pinned Umbrel installer completed on the serial/model/capacity-validated disk"
