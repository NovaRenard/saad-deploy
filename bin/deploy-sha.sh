#!/usr/bin/env bash
set -Eeuo pipefail

# Privileged helpers may launch this script with UMask=0077. Checked-out
# application source must stay readable by non-root containers; state files
# still use their own scoped umask in lib.sh.
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  printf 'Usage: %s <app-id> [<sha>|--query-ci] [--lock-held] [--source automated|manual|rollback]\n' "${0##*/}" >&2
}

normalize_application_source_permissions() {
  # Privileged helpers may run with UMask=0077. Application source must stay
  # readable by the non-root containers that build images and run migrations.
  local source_dir="$APP_DIR/app"
  [[ -d "$source_dir" ]] || return 0
  find "$source_dir" -type f -exec chmod a+r {} +
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
  if (( ! lock_held )); then
    if [[ "$DEPLOY_SOURCE" == manual ]]; then
      # A manual request racing the two-minute poller waits safely for
      # the existing transaction rather than failing immediately with code 75.
      acquire_lock "$MANUAL_LOCK_WAIT_SECONDS"
    else
      acquire_lock 0
    fi
  fi
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
    printf 'saad-deploy: %s already runs %s; nothing to deploy
' "$APP_ID" "${TARGET_SHA:0:12}" >&2
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
      printf 'saad-deploy: rolled %s back to %s
' "$APP_ID" "${TARGET_SHA:0:12}" >&2
      return 0
    fi
  fi

  authenticated_fetch_and_verify
  checkout_target_sha
  normalize_application_source_permissions
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
  printf 'saad-deploy: deployed %s to %s
' "${TARGET_SHA:0:12}" "$APP_ID" >&2
}

main "$@"
