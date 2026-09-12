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

  if [[ "$DEPLOY_STRATEGY" == blue_green ]]; then
    [[ -n "$ACTIVE_SLOT" ]] || die "blue/green restart requires an active slot"
    validate_blue_green_config
    prepare_blue_green_compose_args
    determine_blue_green_slots
    local traffic_services=() worker_services=() services=()
    split_list TRAFFIC_SERVICES traffic_services
    split_list WORKER_SERVICES worker_services
    services=("${traffic_services[@]}" "${worker_services[@]}")
    ((${#services[@]} > 0)) || die "no application services are configured for restart"
    compose_slot_with_sha "$ACTIVE_SLOT" "$ACTIVE_SLOT_SHA" restart "${services[@]}"
    return 0
  fi

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
