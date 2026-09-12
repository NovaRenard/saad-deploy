#!/usr/bin/env bash
# Shared helpers for SAAD Deploy. This file is sourced by the executable entrypoints.

readonly SAAD_DEPLOY_DEFAULT_CONFIG_DIR="/etc/saad-deploy"
readonly SAAD_DEPLOY_LOCK_EXIT_CODE=75
readonly SAAD_DEPLOY_DEFAULT_NGINX_ALLOWED_DIR="/etc/nginx/saad-deploy"

# This is a process-level packaging/test override, not an application config
# value. Production systemd units should leave it unset.
readonly SAAD_DEPLOY_NGINX_ALLOWED_DIR="${SAAD_DEPLOY_NGINX_ALLOWED_DIR:-${SAAD_DEPLOY_DEFAULT_NGINX_ALLOWED_DIR}}"

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

epoch_seconds() {
  date -u +%s
}

die() {
  LAST_ERROR_MESSAGE="$*"
  printf 'saad-deploy: %s\n' "$*" >&2
  return 1
}

validate_app_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid application id"
}

require_declared() {
  local variable_name
  for variable_name in "$@"; do
    [[ ${!variable_name+x} ]] || die "missing required config variable: ${variable_name}"
  done
}

require_nonempty() {
  local variable_name
  for variable_name in "$@"; do
    [[ -n ${!variable_name:-} ]] || die "config variable must not be empty: ${variable_name}"
  done
}

resolve_path() {
  local value="$1"
  if [[ "$value" = /* ]]; then
    printf '%s\n' "$value"
  else
    printf '%s/%s\n' "$APP_DIR" "$value"
  fi
}

load_env_config() {
  local config_file="$1"
  local line variable_name value
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] ||
      die "invalid config line in ${config_file}"
    variable_name="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"

    if [[ "$value" == \"* ]]; then
      [[ "$value" == *\" ]] || die "unterminated double-quoted config value: ${variable_name}"
      value="${value:1:${#value}-2}"
    elif [[ "$value" == \'* ]]; then
      [[ "$value" == *\' ]] || die "unterminated single-quoted config value: ${variable_name}"
      value="${value:1:${#value}-2}"
    elif [[ "$value" == *[[:space:]]* ]]; then
      die "unquoted config values may not contain whitespace: ${variable_name}"
    fi
    printf -v "$variable_name" '%s' "$value"
  done <"$config_file"
}

load_config() {
  APP_ID="$1"
  validate_app_id "$APP_ID"

  local config_dir="${SAAD_DEPLOY_CONFIG_DIR:-$SAAD_DEPLOY_DEFAULT_CONFIG_DIR}"
  CONFIG_FILE="${config_dir}/${APP_ID}.env"
  [[ -r "$CONFIG_FILE" ]] || die "cannot read application config: ${CONFIG_FILE}"

  # The configuration contract is a root-owned KEY=VALUE environment file.
  # Parse it without source/eval so config values cannot execute shell code.
  local config_variables=(
    DEPLOY_STRATEGY GITHUB_REPOSITORY GITHUB_WORKFLOW GITHUB_TOKEN DEPLOY_BRANCH
    APP_DIR APP_ENV COMPOSE_FILE COMPOSE_PROJECT_NAME STATE_DIR BACKUP_DIR
    BACKUP_RETENTION_DAYS POSTGRES_SERVICE INFRA_SERVICES BUILD_SERVICES
    MIGRATE_SERVICE APP_SERVICES EXTRA_APP_SERVICES HEALTH_SERVICES
    REQUIRED_EXTERNAL_NETWORKS HEALTH_URLS COMPOSE_PROFILES
    HEALTH_TIMEOUT_SECONDS HEALTH_POLL_SECONDS
    TRAFFIC_SERVICES TRAFFIC_HEALTH_SERVICES WORKER_SERVICES WORKER_HEALTH_SERVICES
    BLUE_ENV_FILE GREEN_ENV_FILE BLUE_HEALTH_URLS GREEN_HEALTH_URLS
    NGINX_UPSTREAM_FILE NGINX_BLUE_UPSTREAM NGINX_GREEN_UPSTREAM DRAIN_SECONDS
  )
  unset "${config_variables[@]}" 2>/dev/null || true
  load_env_config "$CONFIG_FILE"

  DEPLOY_STRATEGY="${DEPLOY_STRATEGY:-recreate}"
  case "$DEPLOY_STRATEGY" in
    recreate|blue_green) ;;
    *) die "DEPLOY_STRATEGY must be recreate or blue_green" ;;
  esac
  if [[ "$DEPLOY_STRATEGY" == blue_green ]]; then
    WORKER_SERVICES="${WORKER_SERVICES:-}"
    WORKER_HEALTH_SERVICES="${WORKER_HEALTH_SERVICES:-}"
    DRAIN_SECONDS="${DRAIN_SECONDS:-30}"
  fi
  HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-180}"
  HEALTH_POLL_SECONDS="${HEALTH_POLL_SECONDS:-3}"

  require_declared \
    GITHUB_REPOSITORY GITHUB_WORKFLOW GITHUB_TOKEN DEPLOY_BRANCH APP_DIR APP_ENV \
    COMPOSE_FILE COMPOSE_PROJECT_NAME STATE_DIR BACKUP_DIR BACKUP_RETENTION_DAYS \
    POSTGRES_SERVICE INFRA_SERVICES BUILD_SERVICES MIGRATE_SERVICE APP_SERVICES \
    EXTRA_APP_SERVICES HEALTH_SERVICES REQUIRED_EXTERNAL_NETWORKS HEALTH_URLS \
    COMPOSE_PROFILES
  require_nonempty \
    GITHUB_REPOSITORY GITHUB_WORKFLOW GITHUB_TOKEN DEPLOY_BRANCH APP_DIR APP_ENV \
    COMPOSE_FILE COMPOSE_PROJECT_NAME STATE_DIR BACKUP_DIR BACKUP_RETENTION_DAYS \
    POSTGRES_SERVICE MIGRATE_SERVICE

  [[ "$GITHUB_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "invalid GITHUB_REPOSITORY"
  [[ "$DEPLOY_BRANCH" != *$'\n'* && "$DEPLOY_BRANCH" != *$'\r'* ]] || die "invalid DEPLOY_BRANCH"
  [[ "$COMPOSE_PROJECT_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "invalid COMPOSE_PROJECT_NAME"
  [[ "$BACKUP_RETENTION_DAYS" =~ ^[0-9]+$ ]] || die "BACKUP_RETENTION_DAYS must be a non-negative integer"
  [[ "$HEALTH_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] ||
    die "HEALTH_TIMEOUT_SECONDS must be a non-negative integer"
  [[ "$HEALTH_POLL_SECONDS" =~ ^[0-9]+$ ]] ||
    die "HEALTH_POLL_SECONDS must be a non-negative integer"
  [[ -d "$APP_DIR" ]] || die "APP_DIR does not exist: ${APP_DIR}"
  [[ -d "$APP_DIR/.git" || -f "$APP_DIR/.git" ]] || die "APP_DIR is not a Git worktree: ${APP_DIR}"

  APP_ENV="$(resolve_path "$APP_ENV")"
  COMPOSE_FILE="$(resolve_path "$COMPOSE_FILE")"
  STATE_DIR="$(resolve_path "$STATE_DIR")"
  BACKUP_DIR="$(resolve_path "$BACKUP_DIR")"
  [[ -f "$APP_ENV" ]] || die "APP_ENV does not exist: ${APP_ENV}"
  [[ -f "$COMPOSE_FILE" ]] || die "COMPOSE_FILE does not exist: ${COMPOSE_FILE}"
}

split_list() {
  local variable_name="$1"
  local -n output_array="$2"
  local value="${!variable_name:-}"
  output_array=()
  if [[ -n "$value" ]]; then
    # shellcheck disable=SC2034 # Written through a nameref for the caller.
    read -r -a output_array <<<"$value"
  fi
}

prepare_compose_args() {
  COMPOSE_ARGS=(
    compose
    --project-name "$COMPOSE_PROJECT_NAME"
    --env-file "$APP_ENV"
    -f "$COMPOSE_FILE"
  )

  local profiles=()
  split_list COMPOSE_PROFILES profiles
  local profile
  for profile in "${profiles[@]}"; do
    COMPOSE_ARGS+=(--profile "$profile")
  done
}

compose() {
  IMAGE_TAG="$TARGET_SHA" docker "${COMPOSE_ARGS[@]}" "$@"
}

prepare_blue_green_compose_args() {
  INFRA_COMPOSE_ARGS=("${COMPOSE_ARGS[@]}")
  BLUE_COMPOSE_ARGS=(
    compose
    --project-name "${COMPOSE_PROJECT_NAME}-blue"
    --env-file "$APP_ENV"
    --env-file "$BLUE_ENV_FILE"
    -f "$COMPOSE_FILE"
  )
  GREEN_COMPOSE_ARGS=(
    compose
    --project-name "${COMPOSE_PROJECT_NAME}-green"
    --env-file "$APP_ENV"
    --env-file "$GREEN_ENV_FILE"
    -f "$COMPOSE_FILE"
  )

  local profiles=()
  split_list COMPOSE_PROFILES profiles
  local profile
  for profile in "${profiles[@]}"; do
    INFRA_COMPOSE_ARGS+=(--profile "$profile")
    BLUE_COMPOSE_ARGS+=(--profile "$profile")
    GREEN_COMPOSE_ARGS+=(--profile "$profile")
  done
}

compose_infra() {
  IMAGE_TAG="$TARGET_SHA" docker "${INFRA_COMPOSE_ARGS[@]}" "$@"
}

compose_slot_with_sha() {
  local slot="$1"
  local image_tag="$2"
  shift 2
  local compose_args=()
  case "$slot" in
    blue) compose_args=("${BLUE_COMPOSE_ARGS[@]}") ;;
    green) compose_args=("${GREEN_COMPOSE_ARGS[@]}") ;;
    *) die "invalid application slot: ${slot}" ;;
  esac
  IMAGE_TAG="$image_tag" docker "${compose_args[@]}" "$@"
}

compose_slot() {
  local slot="$1"
  shift
  compose_slot_with_sha "$slot" "$TARGET_SHA" "$@"
}

list_contains() {
  local needle="$1"
  shift
  local value
  for value in "$@"; do
    [[ "$value" == "$needle" ]] && return 0
  done
  return 1
}

validate_service_group_contract() {
  local infra_services=() traffic_services=() traffic_health_services=()
  local worker_services=() worker_health_services=() service
  split_list INFRA_SERVICES infra_services
  split_list TRAFFIC_SERVICES traffic_services
  split_list TRAFFIC_HEALTH_SERVICES traffic_health_services
  split_list WORKER_SERVICES worker_services
  split_list WORKER_HEALTH_SERVICES worker_health_services

  ((${#traffic_services[@]} > 0)) || die "TRAFFIC_SERVICES must not be empty"
  ((${#traffic_health_services[@]} > 0)) || die "TRAFFIC_HEALTH_SERVICES must not be empty"
  for service in "${traffic_health_services[@]}"; do
    list_contains "$service" "${traffic_services[@]}" ||
      die "TRAFFIC_HEALTH_SERVICES contains a service outside TRAFFIC_SERVICES: ${service}"
  done
  for service in "${traffic_services[@]}"; do
    list_contains "$service" "${worker_services[@]}" &&
      die "traffic and worker service groups must not overlap: ${service}"
  done
  if ((${#worker_services[@]} > 0)); then
    ((${#worker_health_services[@]} > 0)) ||
      die "WORKER_HEALTH_SERVICES must not be empty when WORKER_SERVICES is configured"
    for service in "${worker_health_services[@]}"; do
      list_contains "$service" "${worker_services[@]}" ||
        die "WORKER_HEALTH_SERVICES contains a service outside WORKER_SERVICES: ${service}"
    done
  elif ((${#worker_health_services[@]} > 0)); then
    die "WORKER_HEALTH_SERVICES requires WORKER_SERVICES"
  fi

  for service in "${traffic_services[@]}" "${worker_services[@]}"; do
    list_contains "$service" "${infra_services[@]}" &&
      die "infra service must not be a slot service: ${service}"
    [[ "$service" != "$POSTGRES_SERVICE" ]] ||
      die "POSTGRES_SERVICE must not be a slot service: ${service}"
    [[ "$service" != "$MIGRATE_SERVICE" ]] ||
      die "MIGRATE_SERVICE must not be a slot service: ${service}"
  done
}

validate_http_url_list() {
  local variable_name="$1"
  local urls=() url
  split_list "$variable_name" urls
  ((${#urls[@]} > 0)) || die "${variable_name} must not be empty"
  for url in "${urls[@]}"; do
    [[ "$url" =~ ^https?://[^[:space:]\r\n]+$ ]] ||
      die "${variable_name} contains an invalid URL: ${url}"
  done
}

validate_upstream_target() {
  local variable_name="$1"
  local target="${!variable_name}"
  local port
  [[ "$target" =~ ^[A-Za-z0-9._-]+:[0-9]{1,5}$ ]] ||
    die "${variable_name} must be a safe host:port target"
  port="${target##*:}"
  ((10#$port >= 1 && 10#$port <= 65535)) ||
    die "${variable_name} port must be between 1 and 65535"
}

validate_blue_green_config() {
  require_declared \
    TRAFFIC_SERVICES TRAFFIC_HEALTH_SERVICES \
    BLUE_ENV_FILE GREEN_ENV_FILE \
    BLUE_HEALTH_URLS GREEN_HEALTH_URLS \
    NGINX_UPSTREAM_FILE NGINX_BLUE_UPSTREAM NGINX_GREEN_UPSTREAM
  require_nonempty \
    BLUE_ENV_FILE GREEN_ENV_FILE NGINX_UPSTREAM_FILE \
    NGINX_BLUE_UPSTREAM NGINX_GREEN_UPSTREAM

  [[ "$BLUE_ENV_FILE" = /* && "$BLUE_ENV_FILE" != *$'\n'* && "$BLUE_ENV_FILE" != *$'\r'* ]] ||
    die "BLUE_ENV_FILE must be an absolute path without newlines"
  [[ "$GREEN_ENV_FILE" = /* && "$GREEN_ENV_FILE" != *$'\n'* && "$GREEN_ENV_FILE" != *$'\r'* ]] ||
    die "GREEN_ENV_FILE must be an absolute path without newlines"
  [[ -r "$BLUE_ENV_FILE" ]] || die "BLUE_ENV_FILE does not exist or is not readable: ${BLUE_ENV_FILE}"
  [[ -r "$GREEN_ENV_FILE" ]] || die "GREEN_ENV_FILE does not exist or is not readable: ${GREEN_ENV_FILE}"
  [[ "$BLUE_ENV_FILE" != "$GREEN_ENV_FILE" ]] ||
    die "BLUE_ENV_FILE and GREEN_ENV_FILE must differ"

  [[ "$NGINX_UPSTREAM_FILE" = /* && "$NGINX_UPSTREAM_FILE" != *$'\n'* && "$NGINX_UPSTREAM_FILE" != *$'\r'* ]] ||
    die "NGINX_UPSTREAM_FILE must be an absolute path without newlines"
  [[ -d "$SAAD_DEPLOY_NGINX_ALLOWED_DIR" ]] ||
    die "allowed Nginx directory does not exist: ${SAAD_DEPLOY_NGINX_ALLOWED_DIR}"
  local allowed_dir upstream_file
  allowed_dir="$(realpath -m -- "$SAAD_DEPLOY_NGINX_ALLOWED_DIR")"
  upstream_file="$(realpath -m -- "$NGINX_UPSTREAM_FILE")"
  case "$upstream_file" in
    "$allowed_dir"/*) ;;
    *) die "NGINX_UPSTREAM_FILE must be inside ${allowed_dir}" ;;
  esac
  NGINX_UPSTREAM_FILE="$upstream_file"

  validate_upstream_target NGINX_BLUE_UPSTREAM
  validate_upstream_target NGINX_GREEN_UPSTREAM
  [[ "$NGINX_BLUE_UPSTREAM" != "$NGINX_GREEN_UPSTREAM" ]] ||
    die "NGINX_BLUE_UPSTREAM and NGINX_GREEN_UPSTREAM must differ"
  validate_http_url_list BLUE_HEALTH_URLS
  validate_http_url_list GREEN_HEALTH_URLS
  [[ "$DRAIN_SECONDS" =~ ^[0-9]+$ ]] ||
    die "DRAIN_SECONDS must be a non-negative integer"
  validate_service_group_contract

  [[ "${COMPOSE_PROJECT_NAME}-blue" =~ ^[a-z0-9][a-z0-9_-]*$ ]] ||
    die "invalid blue slot project name"
  [[ "${COMPOSE_PROJECT_NAME}-green" =~ ^[a-z0-9][a-z0-9_-]*$ ]] ||
    die "invalid green slot project name"
}

require_services_in_compose_config() {
  local slot="$1"
  local services_output="$2"
  local variable_name="$3"
  local services=() service
  split_list "$variable_name" services
  for service in "${services[@]}"; do
    grep -Fxq -- "$service" <<<"$services_output" ||
      die "${variable_name} service is not present in ${slot} Compose config: ${service}"
  done
}

require_scalar_service_in_compose_config() {
  local slot="$1"
  local services_output="$2"
  local variable_name="$3"
  local service="${!variable_name}"
  grep -Fxq -- "$service" <<<"$services_output" ||
    die "${variable_name} service is not present in ${slot} Compose config: ${service}"
}

validate_blue_green_compose() {
  set_step validating_blue_green_compose
  compose_infra config -q

  local infra_services blue_services green_services blue_json green_json
  if ! infra_services="$(compose_infra config --services)"; then
    die "could not list services in stable infrastructure Compose config"
  fi
  require_services_in_compose_config infra "$infra_services" INFRA_SERVICES
  require_services_in_compose_config infra "$infra_services" BUILD_SERVICES
  require_scalar_service_in_compose_config infra "$infra_services" POSTGRES_SERVICE
  require_scalar_service_in_compose_config infra "$infra_services" MIGRATE_SERVICE
  if ! blue_services="$(compose_slot blue config --services)"; then
    die "could not list services in blue Compose config"
  fi
  if ! green_services="$(compose_slot green config --services)"; then
    die "could not list services in green Compose config"
  fi
  require_services_in_compose_config blue "$blue_services" TRAFFIC_SERVICES
  require_services_in_compose_config blue "$blue_services" TRAFFIC_HEALTH_SERVICES
  require_services_in_compose_config blue "$blue_services" WORKER_SERVICES
  require_services_in_compose_config blue "$blue_services" WORKER_HEALTH_SERVICES
  require_services_in_compose_config green "$green_services" TRAFFIC_SERVICES
  require_services_in_compose_config green "$green_services" TRAFFIC_HEALTH_SERVICES
  require_services_in_compose_config green "$green_services" WORKER_SERVICES
  require_services_in_compose_config green "$green_services" WORKER_HEALTH_SERVICES

  if ! blue_json="$(compose_slot blue config --format json)"; then
    die "could not inspect blue Compose config"
  fi
  if ! green_json="$(compose_slot green config --format json)"; then
    die "could not inspect green Compose config"
  fi
  local blue_fixed green_fixed service container_name
  blue_fixed="$(printf '%s\n' "$blue_json" | jq -r \
    '.services | to_entries[]? | select(.value.container_name? != null) | [.key, .value.container_name] | @tsv')" ||
    die "blue Compose config is not valid JSON"
  green_fixed="$(printf '%s\n' "$green_json" | jq -r \
    '.services | to_entries[]? | select(.value.container_name? != null) | [.key, .value.container_name] | @tsv')" ||
    die "green Compose config is not valid JSON"
  while IFS=$'\t' read -r service container_name; do
    [[ -z "$container_name" ]] && continue
    local green_service green_container
    while IFS=$'\t' read -r green_service green_container; do
      [[ -n "$green_service" ]] || continue
      [[ "$green_container" == "$container_name" ]] &&
        die "fixed container_name conflicts between blue and green slots: ${container_name}"
    done <<<"$green_fixed"
  done <<<"$blue_fixed"

  local blue_ports green_ports port
  blue_ports="$(printf '%s\n' "$blue_json" | jq -r \
    '.services[]?.ports[]? | .published // empty')" ||
    die "blue Compose port data is not valid JSON"
  green_ports="$(printf '%s\n' "$green_json" | jq -r \
    '.services[]?.ports[]? | .published // empty')" ||
    die "green Compose port data is not valid JSON"
  while IFS= read -r port; do
    [[ -z "$port" ]] && continue
    if grep -Fxq -- "$port" <<<"$green_ports"; then
      die "host port is shared by blue and green slots: ${port}"
    fi
  done <<<"$blue_ports"
}

ensure_state_dir() {
  umask 077
  mkdir -p "$STATE_DIR"
}

read_state() {
  CURRENT_SHA=""
  PREVIOUS_SHA=""
  ACTIVE_SLOT=""
  BLUE_SHA=""
  GREEN_SHA=""
  [[ -f "$STATE_DIR/current-sha" ]] && CURRENT_SHA="$(<"$STATE_DIR/current-sha")"
  [[ -f "$STATE_DIR/previous-sha" ]] && PREVIOUS_SHA="$(<"$STATE_DIR/previous-sha")"
  [[ -f "$STATE_DIR/active-slot" ]] && ACTIVE_SLOT="$(<"$STATE_DIR/active-slot")"
  [[ -f "$STATE_DIR/blue-sha" ]] && BLUE_SHA="$(<"$STATE_DIR/blue-sha")"
  [[ -f "$STATE_DIR/green-sha" ]] && GREEN_SHA="$(<"$STATE_DIR/green-sha")"

  if [[ "$DEPLOY_STRATEGY" == blue_green ]]; then
    if [[ -n "$ACTIVE_SLOT" && ! "$ACTIVE_SLOT" =~ ^(blue|green)$ ]]; then
      die "state active-slot must contain only blue or green"
    fi
    [[ -z "$CURRENT_SHA" ]] || validate_sha "$CURRENT_SHA"
    [[ -z "$PREVIOUS_SHA" ]] || validate_sha "$PREVIOUS_SHA"
    [[ -z "$BLUE_SHA" ]] || validate_sha "$BLUE_SHA"
    [[ -z "$GREEN_SHA" ]] || validate_sha "$GREEN_SHA"
  fi
  return 0
}

atomic_write() {
  local destination="$1"
  local value="$2"
  local temporary
  temporary="$(mktemp "${destination}.tmp.XXXXXX")"
  printf '%s\n' "$value" >"$temporary"
  # The rename stays in the destination directory and is therefore atomic.
  mv -f "$temporary" "$destination"
}

json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

json_string_or_null() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf 'null'
  else
    printf '"%s"' "$(json_escape "$value")"
  fi
}

write_status() {
  local status="$1"
  local step="$2"
  local finished_at="$3"
  local last_error="$4"
  local duration=0
  local temporary
  local status_active_slot="" status_candidate_slot="" status_blue_sha="" status_green_sha=""
  if [[ "${DEPLOY_STRATEGY:-recreate}" == blue_green ]]; then
    status_active_slot="${ACTIVE_SLOT:-}"
    status_candidate_slot="${CANDIDATE_SLOT:-}"
    status_blue_sha="${BLUE_SHA:-}"
    status_green_sha="${GREEN_SHA:-}"
  fi

  if [[ -n ${START_EPOCH:-} ]]; then
    duration=$(( $(epoch_seconds) - START_EPOCH ))
  fi

  temporary="$(mktemp "${STATE_DIR}/.status.json.tmp.XXXXXX")"
  {
    printf '{\n'
    printf '  "app_id": "%s",\n' "$(json_escape "$APP_ID")"
    printf '  "status": "%s",\n' "$(json_escape "$status")"
    printf '  "step": "%s",\n' "$(json_escape "$step")"
    printf '  "deployment_strategy": %s,\n' "$(json_string_or_null "${DEPLOY_STRATEGY:-}")"
    printf '  "current_sha": %s,\n' "$(json_string_or_null "$CURRENT_SHA")"
    printf '  "previous_sha": %s,\n' "$(json_string_or_null "$PREVIOUS_SHA")"
    printf '  "active_slot": %s,\n' "$(json_string_or_null "$status_active_slot")"
    printf '  "candidate_slot": %s,\n' "$(json_string_or_null "$status_candidate_slot")"
    printf '  "blue_sha": %s,\n' "$(json_string_or_null "$status_blue_sha")"
    printf '  "green_sha": %s,\n' "$(json_string_or_null "$status_green_sha")"
    printf '  "target_sha": %s,\n' "$(json_string_or_null "${TARGET_SHA:-}")"
    printf '  "source": %s,\n' "$(json_string_or_null "${DEPLOY_SOURCE:-automated}")"
    printf '  "started_at": %s,\n' "$(json_string_or_null "${STARTED_AT:-}")"
    printf '  "finished_at": %s,\n' "$(json_string_or_null "$finished_at")"
    printf '  "duration_seconds": %s,\n' "$duration"
    printf '  "last_error": %s\n' "$(json_string_or_null "$last_error")"
    printf '}\n'
  } >"$temporary"
  mv -f "$temporary" "$STATE_DIR/status.json"
}

write_last_error() {
  atomic_write "$STATE_DIR/last-error.log" "$1"
}

set_step() {
  CURRENT_STEP="$1"
  write_status deploying "$CURRENT_STEP" "" ""
}

report_deployment_error() {
  local exit_code="$1"
  [[ ${ERROR_REPORTED:-0} -eq 0 ]] || return 0
  ERROR_REPORTED=1
  trap - ERR
  set +e

  local message="deployment failed during ${CURRENT_STEP:-initialization} (exit ${exit_code})"
  [[ -z "${LAST_ERROR_MESSAGE:-}" ]] ||
    message="${message}: ${LAST_ERROR_MESSAGE}"
  if [[ ${DEPLOY_STRATEGY:-recreate} == blue_green ]]; then
    rollback_blue_green_after_failure || true
  fi
  [[ -n ${BACKUP_TEMPORARY_FILE:-} && -f ${BACKUP_TEMPORARY_FILE:-} ]] && rm -f "$BACKUP_TEMPORARY_FILE"
  [[ -n ${STATE_DIR:-} && -d ${STATE_DIR:-} ]] || exit "$exit_code"
  write_last_error "$message" || true
  write_status deploy_failed "${CURRENT_STEP:-initialization}" "$(now_utc)" "$message" || true
  printf 'saad-deploy: %s\n' "$message" >&2
  exit "$exit_code"
}

install_deployment_trap() {
  trap 'report_deployment_error "$?"' ERR
}

acquire_lock() {
  ensure_state_dir
  local lock_file="$STATE_DIR/deploy.lock"
  exec {DEPLOY_LOCK_FD}>"$lock_file"
  if ! flock -n "$DEPLOY_LOCK_FD"; then
    printf 'saad-deploy: deployment already in progress for %s\n' "$APP_ID" >&2
    exit "$SAAD_DEPLOY_LOCK_EXIT_CODE"
  fi
}

validate_sha() {
  [[ "$1" =~ ^[0-9a-fA-F]{7,64}$ ]] || die "invalid Git SHA"
}

latest_successful_push_sha() {
  local encoded_workflow response sha
  encoded_workflow="$(printf '%s' "$GITHUB_WORKFLOW" | jq -sRr @uri)"
  response="$(curl --fail --silent --show-error \
    --header 'Accept: application/vnd.github+json' \
    --header "Authorization: Bearer ${GITHUB_TOKEN}" \
    --get \
    --data-urlencode "branch=${DEPLOY_BRANCH}" \
    --data-urlencode 'event=push' \
    --data-urlencode 'status=success' \
    --data-urlencode 'per_page=100' \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/workflows/${encoded_workflow}/runs")"
  sha="$(printf '%s' "$response" | jq -er --arg branch "$DEPLOY_BRANCH" \
    '[.workflow_runs[] | select(.event == "push" and .conclusion == "success" and .head_branch == $branch)][0].head_sha // empty')"
  if [[ -z "$sha" ]]; then
    printf 'saad-deploy: no successful push workflow run found for %s\n' "$DEPLOY_BRANCH" >&2
    return 1
  fi
  if [[ ! "$sha" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
    printf 'saad-deploy: GitHub Actions returned an invalid Git SHA\n' >&2
    return 1
  fi
  printf '%s\n' "$sha"
}

authenticated_fetch_and_verify() {
  set_step fetching_git
  local repository_url auth_basic
  repository_url="https://github.com/${GITHUB_REPOSITORY}.git"
  auth_basic="$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\r\n')"
  GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0=http.extraheader \
  GIT_CONFIG_VALUE_0="Authorization: Basic ${auth_basic}" \
    git -C "$APP_DIR" fetch --prune "$repository_url" \
      "refs/heads/${DEPLOY_BRANCH}:refs/remotes/origin/${DEPLOY_BRANCH}"

  set_step verifying_branch_reachability
  git -C "$APP_DIR" merge-base --is-ancestor "$TARGET_SHA" "origin/${DEPLOY_BRANCH}"
}

checkout_target_sha() {
  set_step checking_out_sha
  git -C "$APP_DIR" checkout --detach --force "$TARGET_SHA"
}

validate_compose() {
  set_step validating_compose
  compose config -q
}

verify_external_networks() {
  local networks=()
  split_list REQUIRED_EXTERNAL_NETWORKS networks
  local network
  set_step verifying_external_networks
  for network in "${networks[@]}"; do
    docker network inspect "$network" >/dev/null
  done
}

build_services() {
  local services=()
  split_list BUILD_SERVICES services
  set_step building_services
  ((${#services[@]} == 0)) || compose build "${services[@]}"
}

start_services() {
  local step="$1"
  local variable_name="$2"
  local services=()
  split_list "$variable_name" services
  set_step "$step"
  ((${#services[@]} == 0)) || compose up -d "${services[@]}"
}

wait_for_services_healthy_from() {
  local mode="$1"
  local slot="$2"
  local image_tag="$3"
  local step="$4"
  local variable_name="$5"
  local services=()
  split_list "$variable_name" services
  set_step "$step"

  local service deadline container_ids=() container_id health container_output
  deadline=$(( $(epoch_seconds) + ${HEALTH_TIMEOUT_SECONDS:-180} ))

  for service in "${services[@]}"; do
    container_ids=()
    if [[ "$mode" == legacy ]]; then
      if ! container_output="$(compose ps -q "$service")"; then
        die "could not list containers for health-gated service: ${service}"
      fi
    elif ! container_output="$(compose_slot_with_sha "$slot" "$image_tag" ps -q "$service")"; then
      die "could not list containers for health-gated service: ${service}"
    fi
    [[ -n "$container_output" ]] && mapfile -t container_ids <<<"$container_output"
    ((${#container_ids[@]} > 0)) || die "no container found for health-gated service: ${service}"

    while :; do
      local all_healthy=1
      for container_id in "${container_ids[@]}"; do
        health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$container_id")"
        case "$health" in
          healthy) ;;
          starting|created|running) all_healthy=0 ;;
          unhealthy) die "container became unhealthy: ${container_id}" ;;
          missing) die "healthcheck is required for service: ${service}" ;;
          *) die "unexpected container health state (${health}) for ${container_id}" ;;
        esac
      done
      ((all_healthy)) && break
      (( $(epoch_seconds) < deadline )) || die "timed out waiting for healthy service: ${service}"
      sleep "${HEALTH_POLL_SECONDS:-3}"
    done
  done
}

wait_for_services_healthy() {
  wait_for_services_healthy_from legacy "" "$TARGET_SHA" "$1" "$2"
}

wait_for_slot_services_healthy() {
  wait_for_services_healthy_from slot "$1" "$2" "$3" "$4"
}

find_postgres_volume() {
  local volumes=() volume_output
  if ! volume_output="$(docker volume ls -q \
    --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" \
    --filter 'label=com.docker.compose.volume=postgres_data')"; then
    die "could not list Docker volumes by Compose labels"
  fi
  [[ -n "$volume_output" ]] && mapfile -t volumes <<<"$volume_output"
  case "${#volumes[@]}" in
    0) return 0 ;;
    1) printf '%s\n' "${volumes[0]}" ;;
    *) die "multiple postgres_data volumes match Compose labels; refusing to choose one" ;;
  esac
}

backup_postgres_if_present() {
  set_step backing_up_postgres
  local volume timestamp backup_file
  if ! volume="$(find_postgres_volume)"; then
    die "could not resolve a PostgreSQL volume from Compose labels"
  fi
  [[ -n "$volume" ]] || return 0

  mkdir -p "$BACKUP_DIR"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_file="${BACKUP_DIR}/${APP_ID}-postgres-${timestamp}-${TARGET_SHA}.sql.gz"
  BACKUP_TEMPORARY_FILE="${backup_file}.tmp"

  # shellcheck disable=SC2016 # POSTGRES_USER is expanded inside the database container.
  if [[ "$DEPLOY_STRATEGY" == blue_green ]]; then
    compose_infra exec -T "$POSTGRES_SERVICE" sh -ec 'pg_dumpall -U "${POSTGRES_USER:-postgres}"' \
      | gzip -c >"$BACKUP_TEMPORARY_FILE"
  else
    compose exec -T "$POSTGRES_SERVICE" sh -ec 'pg_dumpall -U "${POSTGRES_USER:-postgres}"' \
      | gzip -c >"$BACKUP_TEMPORARY_FILE"
  fi
  mv -f "$BACKUP_TEMPORARY_FILE" "$backup_file"
  BACKUP_TEMPORARY_FILE=""

  find "$BACKUP_DIR" -maxdepth 1 -type f -name "${APP_ID}-postgres-*.sql.gz" \
    -mtime "+${BACKUP_RETENTION_DAYS}" -delete
}

run_migrations() {
  set_step running_migrations
  if [[ "$DEPLOY_STRATEGY" == blue_green ]]; then
    compose_infra run --rm --no-deps "$MIGRATE_SERVICE"
  else
    compose run --rm --no-deps "$MIGRATE_SERVICE"
  fi
}

start_application_services() {
  local application_services=() extra_services=() services=()
  split_list APP_SERVICES application_services
  split_list EXTRA_APP_SERVICES extra_services
  services=("${application_services[@]}" "${extra_services[@]}")
  set_step starting_application
  ((${#services[@]} == 0)) || compose up -d "${services[@]}"
}

check_health_urls() {
  local urls=()
  local step="${1:-checking_health_urls}"
  split_list HEALTH_URLS urls
  local url
  set_step "$step"
  for url in "${urls[@]}"; do
    curl --fail --silent --show-error --location --max-time 15 "$url" >/dev/null
  done
}

slot_sha() {
  case "$1" in
    blue) printf '%s\n' "$BLUE_SHA" ;;
    green) printf '%s\n' "$GREEN_SHA" ;;
    *) die "invalid application slot: $1" ;;
  esac
}

determine_blue_green_slots() {
  set_step determining_slots
  if [[ -n "$ACTIVE_SLOT" ]]; then
    [[ -n "$CURRENT_SHA" ]] || die "active slot exists but current-sha is empty"
    local active_sha
    active_sha="$(slot_sha "$ACTIVE_SLOT")"
    [[ -n "$active_sha" && "$active_sha" == "$CURRENT_SHA" ]] ||
      die "active slot state is inconsistent with current-sha"
    ACTIVE_SLOT_SHA="$active_sha"
    case "$ACTIVE_SLOT" in
      blue) CANDIDATE_SLOT=green ;;
      green) CANDIDATE_SLOT=blue ;;
    esac
  else
    [[ -z "$BLUE_SHA" && -z "$GREEN_SHA" ]] ||
      die "cannot determine active slot from ambiguous state"
    # No slot is guessed here: blue is the first candidate, while production
    # remains on the pre-existing Nginx include until it is switched safely.
    CANDIDATE_SLOT=blue
    ACTIVE_SLOT_SHA=""
  fi
  CANDIDATE_SHA="$(slot_sha "$CANDIDATE_SLOT")"
}

slot_health_variable() {
  case "$1" in
    blue) printf 'BLUE_HEALTH_URLS\n' ;;
    green) printf 'GREEN_HEALTH_URLS\n' ;;
    *) die "invalid application slot: $1" ;;
  esac
}

check_slot_health_urls() {
  local slot="$1"
  local step="$2"
  local variable_name
  variable_name="$(slot_health_variable "$slot")"
  local urls=() url
  split_list "$variable_name" urls
  set_step "$step"
  for url in "${urls[@]}"; do
    curl --fail --silent --show-error --location --max-time 15 "$url" >/dev/null
  done
}

slot_services_are_healthy() {
  local slot="$1"
  local image_tag="$2"
  local variable_name="$3"
  local services=() service container_output container_id health
  split_list "$variable_name" services
  for service in "${services[@]}"; do
    container_output="$(compose_slot_with_sha "$slot" "$image_tag" ps -q "$service")" || return 1
    [[ -n "$container_output" ]] || return 1
    while IFS= read -r container_id; do
      [[ -n "$container_id" ]] || continue
      health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$container_id")" ||
        return 1
      [[ "$health" == healthy ]] || return 1
    done <<<"$container_output"
  done
}

blue_green_fast_rollback_available() {
  [[ "$DEPLOY_SOURCE" == rollback ]]
  [[ -n "$ACTIVE_SLOT" && -n "$CANDIDATE_SLOT" ]]
  [[ "$TARGET_SHA" == "$PREVIOUS_SHA" ]]
  [[ "$CANDIDATE_SHA" == "$TARGET_SHA" ]]
  CANDIDATE_TRAFFIC_STARTED=1
  start_slot_services "$CANDIDATE_SLOT" "$TARGET_SHA" TRAFFIC_SERVICES
  slot_services_are_healthy "$CANDIDATE_SLOT" "$TARGET_SHA" TRAFFIC_HEALTH_SERVICES
  check_slot_health_urls "$CANDIDATE_SLOT" checking_candidate_urls
}

capture_nginx_state() {
  [[ -f "$NGINX_UPSTREAM_FILE" ]] ||
    die "NGINX_UPSTREAM_FILE must exist before a blue/green switch: ${NGINX_UPSTREAM_FILE}"
  NGINX_PREVIOUS_EXISTS=1
  NGINX_PREVIOUS_CONTENT="$(<"$NGINX_UPSTREAM_FILE")"
  NGINX_SWITCHED=0
  NGINX_ROLLBACK_NEEDED=0
}

nginx_target_for_slot() {
  case "$1" in
    blue) printf '%s\n' "$NGINX_BLUE_UPSTREAM" ;;
    green) printf '%s\n' "$NGINX_GREEN_UPSTREAM" ;;
    *) die "invalid application slot: $1" ;;
  esac
}

restore_nginx_upstream_file() {
  if [[ ${NGINX_PREVIOUS_EXISTS:-0} -eq 1 ]]; then
    atomic_write "$NGINX_UPSTREAM_FILE" "$NGINX_PREVIOUS_CONTENT"
  else
    rm -f "$NGINX_UPSTREAM_FILE"
  fi
}

switch_nginx_to_slot() {
  local slot="$1"
  local target
  target="$(nginx_target_for_slot "$slot")"
  set_step switching_traffic
  if ! atomic_write "$NGINX_UPSTREAM_FILE" "server ${target};"; then
    restore_nginx_upstream_file || true
    return 1
  fi
  if ! nginx -t; then
    restore_nginx_upstream_file || true
    return 1
  fi
  if ! systemctl reload nginx; then
    NGINX_ROLLBACK_NEEDED=1
    restore_nginx_upstream_file || true
    if nginx -t && systemctl reload nginx; then
      :
    fi
    return 1
  fi
  NGINX_SWITCHED=1
}

stop_slot_services() {
  local slot="$1"
  local image_tag="$2"
  local variable_name="$3"
  local services=()
  split_list "$variable_name" services
  ((${#services[@]} == 0)) || compose_slot_with_sha "$slot" "$image_tag" stop "${services[@]}"
}

start_slot_services() {
  local slot="$1"
  local image_tag="$2"
  local variable_name="$3"
  local services=()
  split_list "$variable_name" services
  ((${#services[@]} == 0)) || compose_slot_with_sha "$slot" "$image_tag" up -d --no-deps "${services[@]}"
}

rollback_blue_green_after_failure() {
  [[ ${DEPLOYMENT_COMMITTED:-0} -eq 0 ]] || return 0

  local active_sha="${ACTIVE_SLOT_SHA:-}"
  if [[ -n "${CANDIDATE_SLOT:-}" && ${CANDIDATE_WORKERS_STARTED:-0} -eq 1 ]]; then
    stop_slot_services "$CANDIDATE_SLOT" "${TARGET_SHA:-}" WORKER_SERVICES || true
  fi

  if [[ ${NGINX_SWITCHED:-0} -eq 1 || ${NGINX_ROLLBACK_NEEDED:-0} -eq 1 ]]; then
    if [[ -n "${ACTIVE_SLOT:-}" && -n "$active_sha" ]]; then
      if [[ ${PREVIOUS_TRAFFIC_STOPPED:-0} -eq 1 ]]; then
        start_slot_services "$ACTIVE_SLOT" "$active_sha" TRAFFIC_SERVICES || true
      fi
      if [[ ${OLD_WORKERS_STOPPED:-0} -eq 1 ]]; then
        start_slot_services "$ACTIVE_SLOT" "$active_sha" WORKER_SERVICES || true
      fi
    fi
    restore_nginx_upstream_file || true
    nginx -t || true
    systemctl reload nginx || true
  fi

  if [[ -n "${CANDIDATE_SLOT:-}" && ${CANDIDATE_TRAFFIC_STARTED:-0} -eq 1 ]]; then
    stop_slot_services "$CANDIDATE_SLOT" "${TARGET_SHA:-}" TRAFFIC_SERVICES || true
  fi
}

start_stable_infrastructure() {
  local services=()
  split_list INFRA_SERVICES services
  set_step preparing_stable_infrastructure
  ((${#services[@]} == 0)) || compose_infra up -d --no-recreate "${services[@]}"
}

build_blue_green_services() {
  local services=()
  split_list BUILD_SERVICES services
  set_step building_services
  ((${#services[@]} == 0)) || compose_infra build "${services[@]}"
}

start_blue_green_candidate_traffic() {
  set_step preparing_candidate
  CANDIDATE_TRAFFIC_STARTED=1
  start_slot_services "$CANDIDATE_SLOT" "$TARGET_SHA" TRAFFIC_SERVICES
}

switch_blue_green_workers() {
  local services=()
  split_list WORKER_SERVICES services
  set_step switching_workers
  ((${#services[@]} == 0)) && return 0

  if [[ -n "$ACTIVE_SLOT" ]]; then
    OLD_WORKERS_STOPPED=1
    stop_slot_services "$ACTIVE_SLOT" "$ACTIVE_SLOT_SHA" WORKER_SERVICES
  fi
  CANDIDATE_WORKERS_STARTED=1
  start_slot_services "$CANDIDATE_SLOT" "$TARGET_SHA" WORKER_SERVICES
  wait_for_slot_services_healthy "$CANDIDATE_SLOT" "$TARGET_SHA" waiting_for_worker_health WORKER_HEALTH_SERVICES
}

drain_and_stop_previous_slot() {
  set_step draining_previous_slot
  if [[ -n "$ACTIVE_SLOT" && "$DRAIN_SECONDS" -gt 0 ]]; then
    sleep "$DRAIN_SECONDS"
  fi
  [[ -n "$ACTIVE_SLOT" ]] || return 0
  set_step stopping_previous_slot
  PREVIOUS_TRAFFIC_STOPPED=1
  stop_slot_services "$ACTIVE_SLOT" "$ACTIVE_SLOT_SHA" TRAFFIC_SERVICES
}

restore_state_file() {
  local path="$1"
  local existed="$2"
  local value="$3"
  if ((existed)); then
    atomic_write "$path" "$value"
  else
    rm -f "$path"
  fi
}

commit_blue_green_state() {
  set_step committing_state
  local old_current="$CURRENT_SHA"
  local old_previous="$PREVIOUS_SHA"
  local old_active="$ACTIVE_SLOT"
  local old_blue="$BLUE_SHA"
  local old_green="$GREEN_SHA"
  local old_deployed=""
  local old_current_exists=0 old_previous_exists=0 old_active_exists=0
  local old_blue_exists=0 old_green_exists=0 old_deployed_exists=0
  [[ -f "$STATE_DIR/current-sha" ]] && old_current_exists=1
  [[ -f "$STATE_DIR/previous-sha" ]] && old_previous_exists=1
  [[ -f "$STATE_DIR/active-slot" ]] && old_active_exists=1
  [[ -f "$STATE_DIR/blue-sha" ]] && old_blue_exists=1
  [[ -f "$STATE_DIR/green-sha" ]] && old_green_exists=1
  [[ -f "$STATE_DIR/deployed-at" ]] && old_deployed_exists=1 && old_deployed="$(<"$STATE_DIR/deployed-at")"

  local new_previous="$old_current"
  local new_blue="$old_blue"
  local new_green="$old_green"
  if [[ "$CANDIDATE_SLOT" == blue ]]; then
    new_blue="$TARGET_SHA"
  else
    new_green="$TARGET_SHA"
  fi

  if ! atomic_write "$STATE_DIR/previous-sha" "$new_previous" ||
    ! atomic_write "$STATE_DIR/deployed-at" "$(now_utc)" ||
    ! atomic_write "$STATE_DIR/current-sha" "$TARGET_SHA" ||
    ! atomic_write "$STATE_DIR/active-slot" "$CANDIDATE_SLOT" ||
    ! atomic_write "$STATE_DIR/blue-sha" "$new_blue" ||
    ! atomic_write "$STATE_DIR/green-sha" "$new_green"; then
    restore_state_file "$STATE_DIR/current-sha" "$old_current_exists" "$old_current" || true
    restore_state_file "$STATE_DIR/previous-sha" "$old_previous_exists" "$old_previous" || true
    restore_state_file "$STATE_DIR/active-slot" "$old_active_exists" "$old_active" || true
    restore_state_file "$STATE_DIR/blue-sha" "$old_blue_exists" "$old_blue" || true
    restore_state_file "$STATE_DIR/green-sha" "$old_green_exists" "$old_green" || true
    restore_state_file "$STATE_DIR/deployed-at" "$old_deployed_exists" "$old_deployed" || true
    return 1
  fi

  PREVIOUS_SHA="$new_previous"
  CURRENT_SHA="$TARGET_SHA"
  ACTIVE_SLOT="$CANDIDATE_SLOT"
  BLUE_SHA="$new_blue"
  GREEN_SHA="$new_green"
  DEPLOYMENT_COMMITTED=1
  rm -f "$STATE_DIR/last-error.log"
  write_status healthy complete "$(now_utc)" "" || true
}

run_blue_green_deployment() {
  determine_blue_green_slots
  start_stable_infrastructure
  wait_for_services_healthy waiting_for_infrastructure_health INFRA_SERVICES
  backup_postgres_if_present
  run_migrations
  start_blue_green_candidate_traffic
  wait_for_slot_services_healthy "$CANDIDATE_SLOT" "$TARGET_SHA" waiting_candidate_health TRAFFIC_HEALTH_SERVICES
  check_slot_health_urls "$CANDIDATE_SLOT" checking_candidate_urls
  capture_nginx_state
  switch_nginx_to_slot "$CANDIDATE_SLOT"
  check_health_urls checking_public_health
  switch_blue_green_workers
  drain_and_stop_previous_slot
  commit_blue_green_state
}

run_blue_green_fast_rollback() {
  set_step preparing_candidate
  CANDIDATE_TRAFFIC_STARTED=1
  start_slot_services "$CANDIDATE_SLOT" "$TARGET_SHA" TRAFFIC_SERVICES
  wait_for_slot_services_healthy "$CANDIDATE_SLOT" "$TARGET_SHA" waiting_candidate_health TRAFFIC_HEALTH_SERVICES
  check_slot_health_urls "$CANDIDATE_SLOT" checking_candidate_urls
  capture_nginx_state
  switch_nginx_to_slot "$CANDIDATE_SLOT"
  check_health_urls checking_public_health
  switch_blue_green_workers
  drain_and_stop_previous_slot
  commit_blue_green_state
}

commit_successful_state() {
  set_step committing_state
  local old_current="$CURRENT_SHA"
  local old_previous="" old_deployed=""
  local old_previous_exists=0 old_deployed_exists=0
  [[ -f "$STATE_DIR/previous-sha" ]] && old_previous_exists=1 && old_previous="$(<"$STATE_DIR/previous-sha")"
  [[ -f "$STATE_DIR/deployed-at" ]] && old_deployed_exists=1 && old_deployed="$(<"$STATE_DIR/deployed-at")"
  # Keep the in-memory current SHA unchanged until the on-disk promotion is ready.
  # In particular, a write error before current-sha is replaced must be reported
  # against the still-running deployment rather than as a false promotion.
  if ! atomic_write "$STATE_DIR/previous-sha" "$old_current" ||
    ! atomic_write "$STATE_DIR/deployed-at" "$(now_utc)" ||
    ! atomic_write "$STATE_DIR/current-sha" "$TARGET_SHA"; then
    restore_state_file "$STATE_DIR/previous-sha" "$old_previous_exists" "$old_previous" || true
    restore_state_file "$STATE_DIR/deployed-at" "$old_deployed_exists" "$old_deployed" || true
    return 1
  fi
  PREVIOUS_SHA="$old_current"
  CURRENT_SHA="$TARGET_SHA"
  rm -f "$STATE_DIR/last-error.log"
  write_status healthy complete "$(now_utc)" ""
}

prune_dangling_images() {
  # Cleanup is deliberately post-commit and must not turn a completed deployment
  # into a failed one. It is restricted to unreferenced images.
  if ! docker image prune --force --filter dangling=true; then
    printf 'saad-deploy: unable to prune dangling images after successful deployment\n' >&2
  fi
  return 0
}
