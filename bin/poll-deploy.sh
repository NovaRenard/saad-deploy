#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if (($# != 1)); then
  printf 'Usage: %s <app-id>\n' "${0##*/}" >&2
  exit 2
fi
exec "${SCRIPT_DIR}/deploy-sha.sh" "${1:?Usage: poll-deploy.sh <app-id>}" --query-ci
