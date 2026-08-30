#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib.sh
source "${SCRIPT_DIR}/lib.sh"

main() {
  (($# == 1)) || { printf 'Usage: %s <app-id>\n' "${0##*/}" >&2; return 2; }

  load_config "$1"
  ensure_state_dir
  read_state
  [[ -n "$CURRENT_SHA" ]] || die "no current SHA is available for recreate"
  validate_sha "$CURRENT_SHA"

  # RECREATE deliberately uses only the registered current revision. It neither
  # asks CI for a newer revision nor accepts a SHA, service name, path, or
  # compose argument from its caller.
  TARGET_SHA="$CURRENT_SHA"
  DEPLOY_SOURCE=manual
  STARTED_AT="$(now_utc)"
  START_EPOCH="$(epoch_seconds)"
  CURRENT_STEP=acquiring_lock
  install_deployment_trap
  acquire_lock

  set_step verifying_current_sha
  git -C "$APP_DIR" rev-parse --verify "${TARGET_SHA}^{commit}" >/dev/null
  checkout_target_sha
  export IMAGE_TAG="$TARGET_SHA"
  prepare_compose_args
  validate_compose
  verify_external_networks

  local application_services=() extra_services=() services=()
  split_list APP_SERVICES application_services
  split_list EXTRA_APP_SERVICES extra_services
  services=("${application_services[@]}" "${extra_services[@]}")
  ((${#services[@]} > 0)) || die "no application services are configured for recreate"

  set_step recreating_application
  compose up -d --force-recreate "${services[@]}"
  wait_for_services_healthy waiting_for_application_health HEALTH_SERVICES
  check_health_urls

  set_step complete
  rm -f "$STATE_DIR/last-error.log"
  write_status healthy complete "$(now_utc)" ""
}

main "$@"
