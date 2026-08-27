#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib.sh
source "${SCRIPT_DIR}/lib.sh"

main() {
  (($# == 1)) || { printf 'Usage: %s <app-id>\n' "${0##*/}" >&2; return 2; }
  load_config "$1"
  if [[ -f "$STATE_DIR/status.json" ]]; then
    cat "$STATE_DIR/status.json"
  else
    printf '{"app_id":"%s","status":"unknown","step":"not_deployed"}\n' "$APP_ID"
  fi
}

main "$@"
