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
    "printf '%s\n' '$TARGET_SHA'" >"$mock_dir/jq"
  # shellcheck disable=SC2016 # The test mock must expand these variables when invoked later.
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [[ " $* " == *"api.github.com"* ]]; then' \
    '  if [[ ${SCENARIO:-} == failed_ci ]]; then printf "{\"workflow_runs\":[]}\n"; else printf "{\"workflow_runs\":[{\"head_sha\":\"x\"}]}\n"; fi' \
    '  exit 0' \
    'fi' \
    'if [[ ${SCENARIO:-} == failed_healthcheck ]]; then exit 22; fi' \
    'exit 0' >"$mock_dir/curl"
  # shellcheck disable=SC2016 # The test mock must expand these variables when invoked later.
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "docker IMAGE_TAG=%s %s\n" "${IMAGE_TAG:-}" "$*" >>"$CALL_LOG"' \
    'args=" $* "' \
    'if [[ "$args" == *" build "* && ${SCENARIO:-} == failed_build ]]; then exit 1; fi' \
    'if [[ "$args" == *" run "* && ${SCENARIO:-} == failed_migration ]]; then exit 1; fi' \
    'if [[ "$args" == *" ps -q "* ]]; then printf "container-1\n"; exit 0; fi' \
    'if [[ "$args" == *" inspect "* ]]; then printf "healthy\n"; exit 0; fi' \
    'if [[ "$args" == *" config -q "* && ${STATUS_OBSERVER:-0} == 1 ]]; then /usr/bin/sleep 0.05; fi' \
    'exit 0' >"$mock_dir/docker"
  printf '%s\n' '#!/usr/bin/env bash' 'cat' >"$mock_dir/gzip"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$mock_dir/sleep"
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

run_poll() {
  local scenario="$1"
  SCENARIO="$scenario" CALL_LOG="$FIXTURE/calls.log" \
    PATH="$MOCK_DIR:$PATH" SAAD_DEPLOY_CONFIG_DIR="$CONFIG_DIR" \
    bash "$PROJECT_ROOT/bin/poll-deploy.sh" sample
}

run_rollback() {
  local scenario="$1"
  SCENARIO="$scenario" CALL_LOG="$FIXTURE/calls.log" \
    PATH="$MOCK_DIR:$PATH" SAAD_DEPLOY_CONFIG_DIR="$CONFIG_DIR" \
    bash "$PROJECT_ROOT/bin/rollback.sh" sample
}

run_restart() {
  local scenario="$1"
  SCENARIO="$scenario" CALL_LOG="$FIXTURE/calls.log" \
    PATH="$MOCK_DIR:$PATH" SAAD_DEPLOY_CONFIG_DIR="$CONFIG_DIR" \
    bash "$PROJECT_ROOT/bin/restart.sh" sample
}

run_recreate() {
  local scenario="$1"
  SCENARIO="$scenario" CALL_LOG="$FIXTURE/calls.log" \
    PATH="$MOCK_DIR:$PATH" SAAD_DEPLOY_CONFIG_DIR="$CONFIG_DIR" \
    bash "$PROJECT_ROOT/bin/recreate.sh" sample
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
printf 'All deployment scenario tests passed.\n'
