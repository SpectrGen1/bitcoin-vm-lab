#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "$0")" && pwd)/platform-adapter-common.sh"
case "${1:-status}" in
  install) adapter_install startos ;;
  verify) adapter_verify startos ;;
  stop) adapter_stop startos ;;
  status) [[ -r /etc/bvml/startos-profile.env ]] && adapter_verify startos || { echo "StartOS adapter UNCONFIGURED: install an exact /etc/bvml/startos-profile.env"; exit 1; } ;;
  *) adapter_fail "usage: $0 {install|verify|stop|status}" ;;
esac
