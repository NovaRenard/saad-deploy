#!/usr/bin/env bash
# Shared helpers for SAAD Deploy. This file is sourced by the executable entrypoints.

readonly SAAD_DEPLOY_DEFAULT_CONFIG_DIR="/etc/saad-deploy"
readonly SAAD_DEPLOY_LOCK_EXIT_CODE=75

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

epoch_seconds() {
  date -u +%s
}

die() {
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

load_config() {
  APP_ID="$1"
  validate_app_id "$APP_ID"

  local config_dir="${SAAD_DEPLOY_CONFIG_DIR:-$SAAD_DEPLOY_DEFAULT_CONFIG_DIR}"
  CONFIG_FILE="${config_dir}/${APP_ID}.env"
  [[ -r "$CONFIG_FILE" ]] || die "cannot read application config: ${CONFIG_FILE}"

  # The configuration contract is a root-owned shell environment file.
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

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
  local value="${!variable_name}"
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

ensure_state_dir() {
  umask 077
  mkdir -p "$STATE_DIR"
}

read_state() {
  CURRENT_SHA=""
  PREVIOUS_SHA=""
  [[ -f "$STATE_DIR/current-sha" ]] && CURRENT_SHA="$(<"$STATE_DIR/current-sha")"
  [[ -f "$STATE_DIR/previous-sha" ]] && PREVIOUS_SHA="$(<"$STATE_DIR/previous-sha")"
  return 0
}

atomic_write() {
  local destination="$1"
  local value="$2"
  local temporary
  temporary="$(mktemp "${destination}.tmp.XXXXXX")"
  printf '%s\n' "$value" >"$temporary"
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

  if [[ -n ${START_EPOCH:-} ]]; then
    duration=$(( $(epoch_seconds) - START_EPOCH ))
  fi

  temporary="$(mktemp "${STATE_DIR}/.status.json.tmp.XXXXXX")"
  {
    printf '{\n'
    printf '  "app_id": "%s",\n' "$(json_escape "$APP_ID")"
    printf '  "status": "%s",\n' "$(json_escape "$status")"
    printf '  "step": "%s",\n' "$(json_escape "$step")"
    printf '  "current_sha": %s,\n' "$(json_string_or_null "$CURRENT_SHA")"
    printf '  "previous_sha": %s,\n' "$(json_string_or_null "$PREVIOUS_SHA")"
    printf '  "target_sha": %s,\n' "$(json_string_or_null "${TARGET_SHA:-}")"
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

wait_for_services_healthy() {
  local step="$1"
  local variable_name="$2"
  local services=()
  split_list "$variable_name" services
  set_step "$step"

  local service deadline container_ids=() container_id health container_output
  deadline=$(( $(epoch_seconds) + ${HEALTH_TIMEOUT_SECONDS:-180} ))

  for service in "${services[@]}"; do
    container_ids=()
    if ! container_output="$(compose ps -q "$service")"; then
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
  compose exec -T "$POSTGRES_SERVICE" sh -ec 'pg_dumpall -U "${POSTGRES_USER:-postgres}"' \
    | gzip -c >"$BACKUP_TEMPORARY_FILE"
  mv -f "$BACKUP_TEMPORARY_FILE" "$backup_file"
  BACKUP_TEMPORARY_FILE=""

  find "$BACKUP_DIR" -maxdepth 1 -type f -name "${APP_ID}-postgres-*.sql.gz" \
    -mtime "+${BACKUP_RETENTION_DAYS}" -delete
}

run_migrations() {
  set_step running_migrations
  compose run --rm --no-deps "$MIGRATE_SERVICE"
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
  split_list HEALTH_URLS urls
  local url
  set_step checking_health_urls
  for url in "${urls[@]}"; do
    curl --fail --silent --show-error --location --max-time 15 "$url" >/dev/null
  done
}

commit_successful_state() {
  set_step committing_state
  local old_current="$CURRENT_SHA"
  # Keep the in-memory current SHA unchanged until the on-disk promotion is ready.
  # In particular, a write error before current-sha is replaced must be reported
  # against the still-running deployment rather than as a false promotion.
  atomic_write "$STATE_DIR/previous-sha" "$old_current"
  atomic_write "$STATE_DIR/deployed-at" "$(now_utc)"
  atomic_write "$STATE_DIR/current-sha" "$TARGET_SHA"
  PREVIOUS_SHA="$old_current"
  CURRENT_SHA="$TARGET_SHA"
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