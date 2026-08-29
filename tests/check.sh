#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS=(
  "$ROOT_DIR/bin/lib.sh"
  "$ROOT_DIR/bin/poll-deploy.sh"
  "$ROOT_DIR/bin/deploy-sha.sh"
  "$ROOT_DIR/bin/status.sh"
  "$ROOT_DIR/bin/rollback.sh"
  "$ROOT_DIR/bin/restart.sh"
)

bash -n "${SCRIPTS[@]}"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --shell=bash "${SCRIPTS[@]}"
else
  printf 'ShellCheck is not installed; syntax and scenario tests still ran.\n' >&2
fi

"$ROOT_DIR/tests/deploy_scenarios.sh"
