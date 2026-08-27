#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  printf 'Usage: %s <app-id> [<sha>|--query-ci] [--lock-held]\n' "${0##*/}" >&2
}

main() {
  (($# == 2 || $# == 3)) || { usage; return 2; }

  local app_id="$1"
  local target_argument="$2"
  local query_ci=0
  local lock_held=0
  if (($# == 3)); then
    [[ "$3" == --lock-held ]] || { usage; return 2; }
    lock_held=1
  fi
  if [[ "$target_argument" == --query-ci ]]; then
    query_ci=1
  else
    validate_sha "$target_argument"
  fi

  load_config "$app_id"
  ensure_state_dir
  TARGET_SHA="${target_argument,,}"
  STARTED_AT="$(now_utc)"
  START_EPOCH="$(epoch_seconds)"
  CURRENT_STEP=acquiring_lock
  install_deployment_trap
  ((lock_held)) || acquire_lock
  read_state

  if ((query_ci)); then
    set_step querying_github_actions
    if ! TARGET_SHA="$(latest_successful_push_sha)"; then
      die "could not determine a deployable SHA from GitHub Actions"
    fi
  fi
  validate_sha "$TARGET_SHA"

  if [[ -n "$CURRENT_SHA" && "$CURRENT_SHA" == "$TARGET_SHA" ]]; then
    set_step already_deployed
    write_status healthy already_deployed "$(now_utc)" ""
    return 0
  fi

  authenticated_fetch_and_verify
  checkout_target_sha
  export IMAGE_TAG="$TARGET_SHA"
  prepare_compose_args
  validate_compose
  verify_external_networks
  build_services
  start_services starting_infrastructure INFRA_SERVICES
  wait_for_services_healthy waiting_for_infrastructure_health INFRA_SERVICES
  backup_postgres_if_present
  run_migrations
  start_application_services
  wait_for_services_healthy waiting_for_application_health HEALTH_SERVICES
  check_health_urls
  commit_successful_state
  prune_dangling_images
}

main "$@"
