#!/usr/bin/env bash
# Resume only the pinned StartOS setup phase after a host-side automation failure.
set -Eeuo pipefail
source "$(cd "$(dirname "$0")/../.." && pwd)/lib/common.sh"
[[ "${1:-}" == startos && $# == 1 ]] || die "usage: bvml create-resume startos"
is_defined startos || die "StartOS domain is undefined; use create"
[[ "$(domain_state startos)" == running ]] || die "StartOS installer domain must be running"
for image in "$(vm_dir startos)/system.qcow2" "$(vm_dir startos)/application.qcow2"; do
  [[ -f "$image" ]] || die "partial StartOS VM lacks $image"
  virshq dumpxml "$(domain startos)" |
    xmllint --xpath "boolean(//disk[@type='file' and @device='disk']/source[@file='$image']/../driver[@type='qcow2'])" - |
    grep -Fxq true || die "running StartOS domain does not use $image as qcow2"
done
installer_target="$(virshq domblklist "$(domain startos)" --details |
  awk -v source="$STARTOS_ISO" '$4==source {print $3; exit}')"
if [[ -n "$installer_target" ]]; then
  [[ "$(sha256sum "$STARTOS_ISO" | awk '{print $1}')" == "${STARTOS_ISO_SHA256,,}" ]] ||
    die "attached StartOS installer no longer matches its pinned digest"
  "$BVML_ROOT/scripts/vm/startos-install.sh"
else
  [[ -f "${STARTOS_CREDENTIALS_FILE}.root-ca.pem" ]] ||
    die "installer is detached and no protected completed-setup CA exists"
  "$BVML_ROOT/scripts/vm/startos-onboard.sh"
fi
[[ -z "$(virshq domblklist "$(domain startos)" --details |
  awk -v source="$STARTOS_ISO" '$4==source {print $3}')" ]] ||
  die "StartOS installer remains attached after resumed setup"
note "resumed and completed the pinned StartOS VM creation workflow"
