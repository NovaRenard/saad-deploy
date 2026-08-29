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
  [[ -n "$CURRENT_SHA" ]] || die "no current SHA is available for restart"
  validate_sha "$CURRENT_SHA"
  TARGET_SHA="$CURRENT_SHA"
  prepare_compose_args

  # Services come only from the root-owned deployment declaration. The caller
  # supplies no Docker service, path, environment, or compose arguments.
  local application_services=() extra_services=() services=()
  split_list APP_SERVICES application_services
  split_list EXTRA_APP_SERVICES extra_services
  services=("${application_services[@]}" "${extra_services[@]}")
  ((${#services[@]} > 0)) || die "no application services are configured for restart"
  compose restart "${services[@]}"
}

main "$@"
