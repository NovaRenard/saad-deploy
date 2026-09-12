#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  printf 'Usage: %s <app-id> [<sha>|--query-ci] [--lock-held] [--source automated|manual|rollback]\n' "${0##*/}" >&2
}

main() {
  (($# >= 2 && $# <= 5)) || { usage; return 2; }

  local app_id="$1"
  local target_argument="$2"
  local query_ci=0
  local lock_held=0
  DEPLOY_SOURCE=automated
  shift 2
  while (($#)); do
    case "$1" in
      --lock-held)
        ((lock_held == 0)) || { usage; return 2; }
        lock_held=1
        shift
        ;;
      --source)
        (($# >= 2)) || { usage; return 2; }
        case "$2" in automated|manual|rollback) DEPLOY_SOURCE="$2" ;; *) usage; return 2 ;; esac
        shift 2
        ;;
      *) usage; return 2 ;;
    esac
  done
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
  CANDIDATE_SLOT=""
  CANDIDATE_SHA=""
  ACTIVE_SLOT_SHA=""
  DEPLOYMENT_COMMITTED=0
  CANDIDATE_TRAFFIC_STARTED=0
  CANDIDATE_WORKERS_STARTED=0
  OLD_WORKERS_STOPPED=0
  PREVIOUS_TRAFFIC_STOPPED=0
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

  if [[ -n "$CURRENT_SHA" && "$CURRENT_SHA" == "$TARGET_SHA" &&
    ( "$DEPLOY_STRATEGY" == recreate || -n "$ACTIVE_SLOT" ) ]]; then
    set_step already_deployed
    write_status healthy already_deployed "$(now_utc)" ""
    return 0
  fi

  if [[ "$DEPLOY_STRATEGY" == blue_green && "$DEPLOY_SOURCE" == rollback &&
    "$TARGET_SHA" == "$PREVIOUS_SHA" && -n "$ACTIVE_SLOT" ]]; then
    prepare_compose_args
    validate_blue_green_config
    prepare_blue_green_compose_args
    validate_compose
    validate_blue_green_compose
    verify_external_networks
    determine_blue_green_slots
    if blue_green_fast_rollback_available; then
      run_blue_green_fast_rollback
      prune_dangling_images
      return 0
    fi
  fi

  authenticated_fetch_and_verify
  checkout_target_sha
  export IMAGE_TAG="$TARGET_SHA"
  prepare_compose_args
  validate_compose
  if [[ "$DEPLOY_STRATEGY" == blue_green ]]; then
    validate_blue_green_config
    prepare_blue_green_compose_args
    validate_blue_green_compose
    verify_external_networks
    build_blue_green_services
    run_blue_green_deployment
  else
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
  fi
  prune_dangling_images
}

main "$@"
