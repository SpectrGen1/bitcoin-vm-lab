#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "$0")" && pwd)/platform-adapter-common.sh"
case "${1:-status}" in
  install) adapter_install umbrel ;;
  verify) adapter_verify umbrel ;;
  stop) adapter_stop umbrel ;;
  status) [[ -r /etc/bvml/umbrel-profile.env ]] && adapter_verify umbrel || { echo "Umbrel adapter UNCONFIGURED: install an exact /etc/bvml/umbrel-profile.env"; exit 1; } ;;
  *) adapter_fail "usage: $0 {install|verify|stop|status}" ;;
esac
