#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib.sh
source "${SCRIPT_DIR}/lib.sh"

main() {
  (($# == 1)) || { printf 'Usage: %s <app-id>\n' "${0##*/}" >&2; return 2; }
  load_config "$1"
  ensure_state_dir
  acquire_lock
  read_state
  [[ -n "$PREVIOUS_SHA" ]] || die "no previous SHA is available for rollback"
  validate_sha "$PREVIOUS_SHA"
  exec "${SCRIPT_DIR}/deploy-sha.sh" "$APP_ID" "$PREVIOUS_SHA" --lock-held --source rollback
}

main "$@"
