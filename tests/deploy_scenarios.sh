#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_SHA=0123456789abcdef0123456789abcdef01234567
OLD_SHA=89abcdef0123456789abcdef0123456789abcdef
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equals() {
  [[ "$1" == "$2" ]] || fail "expected '$1', got '$2'"
}

assert_contains() {
  [[ "$1" == *"$2"* ]] || fail "expected output to contain '$2'"
}

assert_not_contains() {
  [[ "$1" != *"$2"* ]] || fail "expected output not to contain '$2'"
}

assert_missing() {
  [[ ! -e "$1" ]] || fail "expected path to be absent: $1"
}

make_mocks() {
  local mock_dir="$1"
  mkdir -p "$mock_dir"

  # shellcheck disable=SC2016 # The test mock must expand these variables when invoked later.
  printf '%s\n' '#!/usr/bin/env bash' 'if [[ ${SCENARIO:-} == concurrent ]]; then exit 1; fi' 'exit 0' >"$mock_dir/flock"
  # shellcheck disable=SC2016 # The test mock must expand these variables when invoked later.
  printf '%s\n' '#!/usr/bin/env bash' 'printf "git %s\n" "$*" >>"$CALL_LOG"' 'exit 0' >"$mock_dir/git"
  # shellcheck disable=SC2016 # The test mock must expand these variables when invoked later.
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [[ " $* " == *" -sRr @uri "* ]]; then printf "workflow.yml\n"; exit 0; fi' \
    'if [[ ${SCENARIO:-} == failed_ci ]]; then exit 0; fi' \
    'if [[ " $* " == *"container_name"* || " $* " == *"ports"* ]]; then exit 0; fi' \
    "printf '%s\n' '$TARGET_SHA'" >"$mock_dir/jq"
  # shellcheck disable=SC2016 # The test mock must expand these variables when invoked later.
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [[ " $* " == *"api.github.com"* ]]; then' \
    '  if [[ ${SCENARIO:-} == failed_ci ]]; then printf "{\"workflow_runs\":[]}\n"; else printf "{\"workflow_runs\":[{\"head_sha\":\"x\"}]}\n"; fi' \
    '  exit 0' \
    'fi' \
    'if [[ ${SCENARIO:-} == candidate_http_fail && " $* " == *"18081"* ]]; then exit 22; fi' \
    'if [[ ${SCENARIO:-} == public_health_fail && " $* " == *"health.invalid"* ]]; then exit 22; fi' \
    'if [[ ${SCENARIO:-} == failed_healthcheck ]]; then exit 22; fi' \
    'exit 0' >"$mock_dir/curl"
  # shellcheck disable=SC2016 # The test mock must expand these variables when invoked later.
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "docker IMAGE_TAG=%s %s\n" "${IMAGE_TAG:-}" "$*" >>"$CALL_LOG"' \
    'args=" $* "' \
    'if [[ "$args" == *" build "* && ${SCENARIO:-} == failed_build ]]; then exit 1; fi' \
    'if [[ "$args" == *" run "* && ${SCENARIO:-} == failed_migration ]]; then exit 1; fi' \
    'if [[ "$args" == *" config --services "* ]]; then printf "database\nmigrate\nweb\nworker\n"; exit 0; fi' \
    'if [[ "$args" == *" config --format json "* ]]; then printf "{\"services\":{\"database\":{},\"migrate\":{},\"web\":{},\"worker\":{}}}\n"; exit 0; fi' \
    'if [[ "$args" == *" ps -q "* ]]; then slot=stable; [[ "$args" == *"deploytest-blue"* ]] && slot=blue; [[ "$args" == *"deploytest-green"* ]] && slot=green; service="${!#}"; printf "container-%s-%s\n" "$slot" "$service"; exit 0; fi' \
    'if [[ "$args" == *" inspect "* ]]; then container_id="${!#}"; if [[ ${SCENARIO:-} == candidate_docker_fail && "$container_id" == *"green-web"* ]]; then printf "unhealthy\n"; elif [[ ${SCENARIO:-} == worker_fail && "$container_id" == *"green-worker"* ]]; then printf "unhealthy\n"; else printf "healthy\n"; fi; exit 0; fi' \
    'if [[ "$args" == *" config -q "* && ${STATUS_OBSERVER:-0} == 1 ]]; then /usr/bin/sleep 0.05; fi' \
    'exit 0' >"$mock_dir/docker"
  printf '%s\n' '#!/usr/bin/env bash' 'cat' >"$mock_dir/gzip"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$mock_dir/sleep"
  # shellcheck disable=SC2016 # The test mock must expand these variables when invoked later.
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "nginx %s\n" "$*" >>"$CALL_LOG"' \
    'if [[ "$*" == "-t" && ${SCENARIO:-} == nginx_test_fail ]]; then exit 1; fi' \
    'exit 0' >"$mock_dir/nginx"
  # shellcheck disable=SC2016 # The test mock must expand these variables when invoked later.
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "systemctl %s\n" "$*" >>"$CALL_LOG"' \
    'if [[ "$*" == "reload nginx" && ${SCENARIO:-} == nginx_reload_fail ]]; then exit 1; fi' \
    'exit 0' >"$mock_dir/systemctl"
  # shellcheck disable=SC2016 # The test mock must expand these variables when invoked later.
  printf '%s\n' '#!/usr/bin/env bash' \
    'destination="${!#}"' \
    'if [[ ${SCENARIO:-} == state_write_fail && "$destination" == *"/current-sha" ]]; then exit 1; fi' \
    '/usr/bin/mv "$@"' >"$mock_dir/mv"
  chmod +x "$mock_dir"/*
}

make_fixture() {
  local name="$1"
  FIXTURE="$TEST_ROOT/$name"
  MOCK_DIR="$FIXTURE/mocks"
  CONFIG_DIR="$FIXTURE/config"
  STATE_DIR="$FIXTURE/state"
  mkdir -p "$FIXTURE/app/.git" "$CONFIG_DIR" "$STATE_DIR"
  : >"$FIXTURE/app/.env.production"
  : >"$FIXTURE/app/compose.yml"
  make_mocks "$MOCK_DIR"
  printf '%s\n' \
    'GITHUB_REPOSITORY=owner/repository' \
    'GITHUB_WORKFLOW=workflow.yml' \
    'GITHUB_TOKEN=test-token' \
    'DEPLOY_BRANCH=main' \
    "APP_DIR=$FIXTURE/app" \
    'APP_ENV=.env.production' \
    'COMPOSE_FILE=compose.yml' \
    'COMPOSE_PROJECT_NAME=deploytest' \
    "STATE_DIR=$STATE_DIR" \
    "BACKUP_DIR=$FIXTURE/backups" \
    'BACKUP_RETENTION_DAYS=7' \
    'POSTGRES_SERVICE=database' \
    'INFRA_SERVICES=database' \
    'BUILD_SERVICES="web worker"' \
    'MIGRATE_SERVICE=migrate' \
    'APP_SERVICES=web' \
    'EXTRA_APP_SERVICES=worker' \
    'HEALTH_SERVICES=web' \
    'REQUIRED_EXTERNAL_NETWORKS=shared' \
    'HEALTH_URLS=https://health.invalid/status' \
    'COMPOSE_PROFILES=' \
    'HEALTH_TIMEOUT_SECONDS=1' \
    'HEALTH_POLL_SECONDS=0' >"$CONFIG_DIR/sample.env"
}

make_blue_green_fixture() {
  local name="$1"
  make_fixture "$name"
  NGINX_ALLOWED_DIR="$FIXTURE/nginx"
  BLUE_ENV_FILE="$FIXTURE/blue.env"
  GREEN_ENV_FILE="$FIXTURE/green.env"
  mkdir -p "$NGINX_ALLOWED_DIR"
  : >"$BLUE_ENV_FILE"
  : >"$GREEN_ENV_FILE"
  printf '%s\n' 'server 127.0.0.1:18080;' >"$NGINX_ALLOWED_DIR/upstream.conf"
  printf '%s\n' \
    'DEPLOY_STRATEGY=blue_green' \
    'TRAFFIC_SERVICES=web' \
    'TRAFFIC_HEALTH_SERVICES=web' \
    'WORKER_SERVICES=worker' \
    'WORKER_HEALTH_SERVICES=worker' \
    "BLUE_ENV_FILE=$BLUE_ENV_FILE" \
    "GREEN_ENV_FILE=$GREEN_ENV_FILE" \
    'BLUE_HEALTH_URLS=http://127.0.0.1:18080/healthz' \
    'GREEN_HEALTH_URLS=http://127.0.0.1:18081/healthz' \
    "NGINX_UPSTREAM_FILE=$NGINX_ALLOWED_DIR/upstream.conf" \
    'NGINX_BLUE_UPSTREAM=127.0.0.1:18080' \
    'NGINX_GREEN_UPSTREAM=127.0.0.1:18081' \
    'DRAIN_SECONDS=0' >>"$CONFIG_DIR/sample.env"
}

run_poll() {
  local scenario="$1"
  SCENARIO="$scenario" CALL_LOG="$FIXTURE/calls.log" \
    PATH="$MOCK_DIR:$PATH" SAAD_DEPLOY_CONFIG_DIR="$CONFIG_DIR" \
    bash "$PROJECT_ROOT/bin/poll-deploy.sh" sample
}

run_bg_deploy() {
  local scenario="$1"
  local sha="$2"
  SCENARIO="$scenario" CALL_LOG="$FIXTURE/calls.log" \
    PATH="$MOCK_DIR:$PATH" SAAD_DEPLOY_CONFIG_DIR="$CONFIG_DIR" \
    SAAD_DEPLOY_NGINX_ALLOWED_DIR="$NGINX_ALLOWED_DIR" \
    bash "$PROJECT_ROOT/bin/deploy-sha.sh" sample "$sha"
}

run_rollback() {
  local scenario="$1"
  SCENARIO="$scenario" CALL_LOG="$FIXTURE/calls.log" \
    PATH="$MOCK_DIR:$PATH" SAAD_DEPLOY_CONFIG_DIR="$CONFIG_DIR" \
    SAAD_DEPLOY_NGINX_ALLOWED_DIR="${NGINX_ALLOWED_DIR:-}" \
    bash "$PROJECT_ROOT/bin/rollback.sh" sample
}

run_restart() {
  local scenario="$1"
  SCENARIO="$scenario" CALL_LOG="$FIXTURE/calls.log" \
    PATH="$MOCK_DIR:$PATH" SAAD_DEPLOY_CONFIG_DIR="$CONFIG_DIR" \
    SAAD_DEPLOY_NGINX_ALLOWED_DIR="${NGINX_ALLOWED_DIR:-}" \
    bash "$PROJECT_ROOT/bin/restart.sh" sample
}

run_recreate() {
  local scenario="$1"
  SCENARIO="$scenario" CALL_LOG="$FIXTURE/calls.log" \
    PATH="$MOCK_DIR:$PATH" SAAD_DEPLOY_CONFIG_DIR="$CONFIG_DIR" \
    SAAD_DEPLOY_NGINX_ALLOWED_DIR="${NGINX_ALLOWED_DIR:-}" \
    bash "$PROJECT_ROOT/bin/recreate.sh" sample
}

run_status() {
  PATH="$MOCK_DIR:$PATH" SAAD_DEPLOY_CONFIG_DIR="$CONFIG_DIR" \
    bash "$PROJECT_ROOT/bin/status.sh" sample
}

read_status() {
  STATUS_CONTENT="$(<"$STATE_DIR/status.json")"
}

test_already_deployed_sha() {
  make_fixture already-deployed
  printf '%s\n' "$TARGET_SHA" >"$STATE_DIR/current-sha"
  run_poll success
  read_status
  assert_contains "$STATUS_CONTENT" '"status": "healthy"'
  assert_contains "$STATUS_CONTENT" '"step": "already_deployed"'
  assert_missing "$FIXTURE/calls.log"
}

test_failed_ci() {
  make_fixture failed-ci
  if run_poll failed_ci; then fail 'failed CI must fail deployment'; fi
  read_status
  assert_contains "$STATUS_CONTENT" '"status": "deploy_failed"'
  assert_contains "$STATUS_CONTENT" '"step": "querying_github_actions"'
  assert_missing "$STATE_DIR/current-sha"
}

test_concurrent_deploy() {
  make_fixture concurrent
  printf '%s\n' "$OLD_SHA" >"$STATE_DIR/current-sha"
  printf '%s\n' '{"status":"healthy","step":"complete"}' >"$STATE_DIR/status.json"
  set +e
  run_poll concurrent
  local exit_code=$?
  set -e
  assert_equals 75 "$exit_code"
  assert_equals "$OLD_SHA" "$(<"$STATE_DIR/current-sha")"
  assert_equals '{"status":"healthy","step":"complete"}' "$(<"$STATE_DIR/status.json")"
}

test_failed_build_preserves_current_sha() {
  make_fixture failed-build
  printf '%s\n' "$OLD_SHA" >"$STATE_DIR/current-sha"
  if run_poll failed_build; then fail 'failed build must fail deployment'; fi
  read_status
  assert_contains "$STATUS_CONTENT" '"status": "deploy_failed"'
  assert_contains "$STATUS_CONTENT" '"step": "building_services"'
  assert_equals "$OLD_SHA" "$(<"$STATE_DIR/current-sha")"
}

test_failed_migration_preserves_current_sha() {
  make_fixture failed-migration
  printf '%s\n' "$OLD_SHA" >"$STATE_DIR/current-sha"
  if run_poll failed_migration; then fail 'failed migration must fail deployment'; fi
  read_status
  assert_contains "$STATUS_CONTENT" '"step": "running_migrations"'
  assert_equals "$OLD_SHA" "$(<"$STATE_DIR/current-sha")"
}

test_failed_healthcheck_preserves_current_sha() {
  make_fixture failed-healthcheck
  printf '%s\n' "$OLD_SHA" >"$STATE_DIR/current-sha"
  if run_poll failed_healthcheck; then fail 'failed healthcheck must fail deployment'; fi
  read_status
  assert_contains "$STATUS_CONTENT" '"step": "checking_health_urls"'
  assert_equals "$OLD_SHA" "$(<"$STATE_DIR/current-sha")"
}

test_successful_deployment() {
  make_fixture successful
  printf '%s\n' "$OLD_SHA" >"$STATE_DIR/current-sha"
  run_poll success
  read_status
  assert_equals "$TARGET_SHA" "$(<"$STATE_DIR/current-sha")"
  assert_equals "$OLD_SHA" "$(<"$STATE_DIR/previous-sha")"
  assert_contains "$STATUS_CONTENT" '"status": "healthy"'
  assert_contains "$STATUS_CONTENT" '"step": "complete"'
  assert_contains "$STATUS_CONTENT" '"deployment_strategy": "recreate"'
  assert_contains "$STATUS_CONTENT" '"source": "automated"'
  assert_contains "$(<"$FIXTURE/calls.log")" 'build web worker'
  assert_contains "$(<"$FIXTURE/calls.log")" 'run --rm --no-deps migrate'
}

test_rollback_records_rollback_source() {
  make_fixture rollback
  printf '%s\n' "$TARGET_SHA" >"$STATE_DIR/current-sha"
  printf '%s\n' "$OLD_SHA" >"$STATE_DIR/previous-sha"
  run_rollback success
  read_status
  assert_equals "$OLD_SHA" "$(<"$STATE_DIR/current-sha")"
  assert_equals "$TARGET_SHA" "$(<"$STATE_DIR/previous-sha")"
  assert_contains "$STATUS_CONTENT" '"source": "rollback"'
}

test_restart_does_not_write_deployment_status() {
  make_fixture restart
  printf '%s\n' "$TARGET_SHA" >"$STATE_DIR/current-sha"
  printf '%s\n' '{"status":"healthy","step":"complete"}' >"$STATE_DIR/status.json"
  run_restart success
  assert_equals '{"status":"healthy","step":"complete"}' "$(<"$STATE_DIR/status.json")"
  assert_contains "$(<"$FIXTURE/calls.log")" 'restart web worker'
}

test_recreate_requires_current_sha() {
  make_fixture recreate-no-current-sha
  if run_recreate success; then fail 'recreate without current SHA must fail'; fi
  assert_missing "$FIXTURE/calls.log"
}

test_recreate_recreates_only_application_services() {
  make_fixture recreate
  printf '%s\n' "$TARGET_SHA" >"$STATE_DIR/current-sha"
  printf '%s\n' '{"status":"healthy","step":"complete"}' >"$STATE_DIR/status.json"
  run_recreate success
  read_status
  local calls
  calls="$(<"$FIXTURE/calls.log")"
  assert_contains "$calls" "IMAGE_TAG=$TARGET_SHA compose --project-name deploytest --env-file $FIXTURE/app/.env.production -f $FIXTURE/app/compose.yml up -d --force-recreate web worker"
  assert_not_contains "$calls" 'build '
  assert_not_contains "$calls" 'run --rm --no-deps migrate'
  assert_not_contains "$calls" 'up -d database'
  assert_equals "$TARGET_SHA" "$(<"$STATE_DIR/current-sha")"
  assert_contains "$STATUS_CONTENT" '"status": "healthy"'
  assert_contains "$STATUS_CONTENT" '"source": "manual"'
}

test_recreate_failure_is_nonzero_and_records_failed_step() {
  make_fixture recreate-failed-health
  printf '%s\n' "$TARGET_SHA" >"$STATE_DIR/current-sha"
  if run_recreate failed_healthcheck; then fail 'failed recreate health check must return nonzero'; fi
  read_status
  assert_contains "$STATUS_CONTENT" '"status": "deploy_failed"'
  assert_contains "$STATUS_CONTENT" '"step": "checking_health_urls"'
}

test_recreate_lock_and_arguments_are_restricted() {
  make_fixture recreate-lock
  printf '%s\n' "$TARGET_SHA" >"$STATE_DIR/current-sha"
  set +e
  run_recreate concurrent
  local exit_code=$?
  set -e
  assert_equals 75 "$exit_code"
  if PATH="$MOCK_DIR:$PATH" SAAD_DEPLOY_CONFIG_DIR="$CONFIG_DIR" bash "$PROJECT_ROOT/bin/recreate.sh" sample unexpected; then fail 'recreate must reject arbitrary arguments'; fi
  if PATH="$MOCK_DIR:$PATH" SAAD_DEPLOY_CONFIG_DIR="$CONFIG_DIR" bash "$PROJECT_ROOT/bin/recreate.sh" '../invalid'; then fail 'recreate must reject invalid app ids'; fi
}

test_config_values_are_not_executed() {
  make_fixture config-not-executed
  local marker="$FIXTURE/command-ran"
  printf '%s\n' "GITHUB_TOKEN=\"\$(touch $marker)\"" >>"$CONFIG_DIR/sample.env"
  run_status >/dev/null
  assert_missing "$marker"
}

seed_blue_green_state() {
  local active="$1"
  local current="$2"
  printf '%s\n' "$current" >"$STATE_DIR/current-sha"
  printf '%s\n' "$active" >"$STATE_DIR/active-slot"
  if [[ "$active" == blue ]]; then
    printf '%s\n' "$current" >"$STATE_DIR/blue-sha"
  else
    printf '%s\n' "$current" >"$STATE_DIR/green-sha"
    printf '%s\n' 'server 127.0.0.1:18081;' >"$NGINX_ALLOWED_DIR/upstream.conf"
  fi
}

test_blue_green_successful_blue_to_green() {
  make_blue_green_fixture blue-to-green
  seed_blue_green_state blue "$OLD_SHA"
  run_bg_deploy success "$TARGET_SHA"
  read_status
  local calls
  calls="$(<"$FIXTURE/calls.log")"
  assert_equals "$TARGET_SHA" "$(<"$STATE_DIR/current-sha")"
  assert_equals "$OLD_SHA" "$(<"$STATE_DIR/previous-sha")"
  assert_equals green "$(<"$STATE_DIR/active-slot")"
  assert_equals "$TARGET_SHA" "$(<"$STATE_DIR/green-sha")"
  assert_equals 'server 127.0.0.1:18081;' "$(<"$NGINX_ALLOWED_DIR/upstream.conf")"
  assert_contains "$STATUS_CONTENT" '"deployment_strategy": "blue_green"'
  assert_contains "$STATUS_CONTENT" '"active_slot": "green"'
  assert_contains "$calls" 'IMAGE_TAG=0123456789abcdef0123456789abcdef01234567 compose --project-name deploytest --env-file'
  assert_contains "$calls" 'IMAGE_TAG=0123456789abcdef0123456789abcdef01234567 compose --project-name deploytest-green'
  assert_contains "$calls" 'compose --project-name deploytest-green --env-file'
  assert_contains "$calls" 'compose --project-name deploytest-blue --env-file'
  assert_contains "$calls" 'stop web'
}

test_blue_green_successful_green_to_blue() {
  make_blue_green_fixture green-to-blue
  seed_blue_green_state green "$OLD_SHA"
  run_bg_deploy success "$TARGET_SHA"
  assert_equals blue "$(<"$STATE_DIR/active-slot")"
  assert_equals "$TARGET_SHA" "$(<"$STATE_DIR/blue-sha")"
  assert_equals 'server 127.0.0.1:18080;' "$(<"$NGINX_ALLOWED_DIR/upstream.conf")"
}

test_blue_green_candidate_docker_health_failure() {
  make_blue_green_fixture candidate-docker-fail
  seed_blue_green_state blue "$OLD_SHA"
  if run_bg_deploy candidate_docker_fail "$TARGET_SHA"; then fail 'candidate Docker health must fail deployment'; fi
  read_status
  assert_equals "$OLD_SHA" "$(<"$STATE_DIR/current-sha")"
  assert_equals blue "$(<"$STATE_DIR/active-slot")"
  assert_equals 'server 127.0.0.1:18080;' "$(<"$NGINX_ALLOWED_DIR/upstream.conf")"
  assert_contains "$STATUS_CONTENT" '"step": "waiting_candidate_health"'
  assert_not_contains "$(<"$FIXTURE/calls.log")" 'systemctl reload nginx'
}

test_blue_green_candidate_http_health_failure() {
  make_blue_green_fixture candidate-http-fail
  seed_blue_green_state blue "$OLD_SHA"
  if run_bg_deploy candidate_http_fail "$TARGET_SHA"; then fail 'candidate HTTP health must fail deployment'; fi
  read_status
  assert_equals "$OLD_SHA" "$(<"$STATE_DIR/current-sha")"
  assert_equals blue "$(<"$STATE_DIR/active-slot")"
  assert_equals 'server 127.0.0.1:18080;' "$(<"$NGINX_ALLOWED_DIR/upstream.conf")"
  assert_contains "$STATUS_CONTENT" '"step": "checking_candidate_urls"'
  assert_not_contains "$(<"$FIXTURE/calls.log")" 'systemctl reload nginx'
}

test_blue_green_nginx_test_failure_restores_include() {
  make_blue_green_fixture nginx-test-fail
  seed_blue_green_state blue "$OLD_SHA"
  if run_bg_deploy nginx_test_fail "$TARGET_SHA"; then fail 'nginx -t failure must fail deployment'; fi
  assert_equals 'server 127.0.0.1:18080;' "$(<"$NGINX_ALLOWED_DIR/upstream.conf")"
  assert_not_contains "$(<"$FIXTURE/calls.log")" 'systemctl reload nginx'
}

test_blue_green_nginx_reload_failure_attempts_recovery() {
  make_blue_green_fixture nginx-reload-fail
  seed_blue_green_state blue "$OLD_SHA"
  if run_bg_deploy nginx_reload_fail "$TARGET_SHA"; then fail 'nginx reload failure must fail deployment'; fi
  assert_equals 'server 127.0.0.1:18080;' "$(<"$NGINX_ALLOWED_DIR/upstream.conf")"
  assert_contains "$(<"$FIXTURE/calls.log")" 'systemctl reload nginx'
}

test_blue_green_public_health_failure_rolls_back_traffic() {
  make_blue_green_fixture public-health-fail
  seed_blue_green_state blue "$OLD_SHA"
  if run_bg_deploy public_health_fail "$TARGET_SHA"; then fail 'public health failure must fail deployment'; fi
  read_status
  assert_equals "$OLD_SHA" "$(<"$STATE_DIR/current-sha")"
  assert_equals blue "$(<"$STATE_DIR/active-slot")"
  assert_equals 'server 127.0.0.1:18080;' "$(<"$NGINX_ALLOWED_DIR/upstream.conf")"
  assert_contains "$(<"$FIXTURE/calls.log")" 'systemctl reload nginx'
  assert_contains "$STATUS_CONTENT" '"step": "checking_public_health"'
}

test_blue_green_worker_failure_rolls_back_and_restores_workers() {
  make_blue_green_fixture worker-fail
  seed_blue_green_state blue "$OLD_SHA"
  if run_bg_deploy worker_fail "$TARGET_SHA"; then fail 'worker health failure must fail deployment'; fi
  read_status
  local calls
  calls="$(<"$FIXTURE/calls.log")"
  assert_equals "$OLD_SHA" "$(<"$STATE_DIR/current-sha")"
  assert_equals blue "$(<"$STATE_DIR/active-slot")"
  assert_equals 'server 127.0.0.1:18080;' "$(<"$NGINX_ALLOWED_DIR/upstream.conf")"
  assert_contains "$calls" 'deploytest-blue --env-file'
  assert_contains "$calls" 'deploytest-green --env-file'
  assert_contains "$STATUS_CONTENT" '"step": "waiting_for_worker_health"'
}

test_blue_green_state_write_failure_does_not_promote() {
  make_blue_green_fixture state-write-fail
  seed_blue_green_state blue "$OLD_SHA"
  if run_bg_deploy state_write_fail "$TARGET_SHA"; then fail 'state write failure must fail deployment'; fi
  read_status
  assert_equals "$OLD_SHA" "$(<"$STATE_DIR/current-sha")"
  assert_equals blue "$(<"$STATE_DIR/active-slot")"
  assert_equals "$OLD_SHA" "$(<"$STATE_DIR/blue-sha")"
  assert_equals 'server 127.0.0.1:18080;' "$(<"$NGINX_ALLOWED_DIR/upstream.conf")"
}

test_blue_green_first_bootstrap_uses_blue_without_guessing_active() {
  make_blue_green_fixture bootstrap
  run_bg_deploy success "$TARGET_SHA"
  assert_equals "$TARGET_SHA" "$(<"$STATE_DIR/current-sha")"
  assert_equals blue "$(<"$STATE_DIR/active-slot")"
  assert_equals "$TARGET_SHA" "$(<"$STATE_DIR/blue-sha")"
  assert_equals 'server 127.0.0.1:18080;' "$(<"$NGINX_ALLOWED_DIR/upstream.conf")"
}

test_blue_green_fast_rollback_uses_existing_slot_without_rebuild() {
  make_blue_green_fixture fast-rollback
  seed_blue_green_state green "$TARGET_SHA"
  printf '%s\n' "$OLD_SHA" >"$STATE_DIR/previous-sha"
  printf '%s\n' "$OLD_SHA" >"$STATE_DIR/blue-sha"
  run_rollback success
  read_status
  local calls
  calls="$(<"$FIXTURE/calls.log")"
  assert_equals "$OLD_SHA" "$(<"$STATE_DIR/current-sha")"
  assert_equals "$TARGET_SHA" "$(<"$STATE_DIR/previous-sha")"
  assert_equals blue "$(<"$STATE_DIR/active-slot")"
  assert_equals 'server 127.0.0.1:18080;' "$(<"$NGINX_ALLOWED_DIR/upstream.conf")"
  assert_not_contains "$calls" ' build '
  assert_not_contains "$calls" ' run --rm --no-deps migrate'
  assert_contains "$STATUS_CONTENT" '"source": "rollback"'
}

test_blue_green_validation_rejects_unsafe_upstream() {
  make_blue_green_fixture unsafe-upstream
  printf '%s\n' 'NGINX_BLUE_UPSTREAM=not-a-host-port' >>"$CONFIG_DIR/sample.env"
  local output
  if output="$(run_bg_deploy success "$TARGET_SHA" 2>&1)"; then fail 'unsafe upstream must fail validation'; fi
  assert_contains "$output" 'NGINX_BLUE_UPSTREAM must be a safe host:port target'
  assert_missing "$STATE_DIR/current-sha"
}

test_blue_green_restart_only_touches_active_slot() {
  make_blue_green_fixture active-restart
  seed_blue_green_state blue "$TARGET_SHA"
  run_restart success
  local calls
  calls="$(<"$FIXTURE/calls.log")"
  assert_contains "$calls" 'IMAGE_TAG=0123456789abcdef0123456789abcdef01234567 compose --project-name deploytest-blue'
  assert_contains "$calls" 'restart web worker'
  assert_not_contains "$calls" 'deploytest-green'
  assert_not_contains "$calls" 'restart database'
}

test_blue_green_recreate_only_touches_active_slot() {
  make_blue_green_fixture active-recreate
  seed_blue_green_state blue "$TARGET_SHA"
  run_recreate success
  local calls
  calls="$(<"$FIXTURE/calls.log")"
  assert_contains "$calls" 'IMAGE_TAG=0123456789abcdef0123456789abcdef01234567 compose --project-name deploytest-blue'
  assert_contains "$calls" 'up -d --force-recreate --no-deps web worker'
  assert_not_contains "$calls" 'deploytest-green'
  assert_not_contains "$calls" 'up -d database'
}

test_state_writes_are_atomic() {
  make_fixture state-atomicity
  printf '%s\n' "$OLD_SHA" >"$STATE_DIR/current-sha"
  STATUS_OBSERVER=1 SCENARIO=success CALL_LOG="$FIXTURE/calls.log" \
    PATH="$MOCK_DIR:$PATH" SAAD_DEPLOY_CONFIG_DIR="$CONFIG_DIR" \
    bash "$PROJECT_ROOT/bin/poll-deploy.sh" sample &
  local deploy_pid=$!
  local invalid_snapshot=0 invalid_sha=0 snapshot observed_sha
  while kill -0 "$deploy_pid" 2>/dev/null; do
    if [[ -f "$STATE_DIR/status.json" ]]; then
      snapshot="$(<"$STATE_DIR/status.json")"
      [[ "$snapshot" == \{*\} && "$snapshot" == *'"status":'* ]] || invalid_snapshot=1
    fi
    if [[ -f "$STATE_DIR/current-sha" ]]; then
      observed_sha="$(<"$STATE_DIR/current-sha")"
      [[ "$observed_sha" == "$OLD_SHA" || "$observed_sha" == "$TARGET_SHA" ]] || invalid_sha=1
    fi
    /usr/bin/sleep 0.005
  done
  wait "$deploy_pid"
  assert_equals 0 "$invalid_snapshot"
  assert_equals 0 "$invalid_sha"
  if compgen -G "$STATE_DIR/.status.json.tmp.*" >/dev/null; then
    fail 'status temporary file remained after deployment'
  fi
}

run_case() {
  local test_name="$1"
  if [[ -z ${TEST_CASE:-} || ${TEST_CASE} == "$test_name" ]]; then
    "$test_name"
  fi
}

run_case test_already_deployed_sha
run_case test_failed_ci
run_case test_concurrent_deploy
run_case test_failed_build_preserves_current_sha
run_case test_failed_migration_preserves_current_sha
run_case test_failed_healthcheck_preserves_current_sha
run_case test_successful_deployment
run_case test_state_writes_are_atomic
run_case test_rollback_records_rollback_source
run_case test_restart_does_not_write_deployment_status
run_case test_recreate_requires_current_sha
run_case test_recreate_recreates_only_application_services
run_case test_recreate_failure_is_nonzero_and_records_failed_step
run_case test_recreate_lock_and_arguments_are_restricted
run_case test_config_values_are_not_executed
run_case test_blue_green_successful_blue_to_green
run_case test_blue_green_successful_green_to_blue
run_case test_blue_green_candidate_docker_health_failure
run_case test_blue_green_candidate_http_health_failure
run_case test_blue_green_nginx_test_failure_restores_include
run_case test_blue_green_nginx_reload_failure_attempts_recovery
run_case test_blue_green_public_health_failure_rolls_back_traffic
run_case test_blue_green_worker_failure_rolls_back_and_restores_workers
run_case test_blue_green_state_write_failure_does_not_promote
run_case test_blue_green_first_bootstrap_uses_blue_without_guessing_active
run_case test_blue_green_fast_rollback_uses_existing_slot_without_rebuild
run_case test_blue_green_validation_rejects_unsafe_upstream
run_case test_blue_green_restart_only_touches_active_slot
run_case test_blue_green_recreate_only_touches_active_slot
printf 'All deployment scenario tests passed.\n'
