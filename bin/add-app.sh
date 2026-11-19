#!/usr/bin/env bash
# Register a project with SAAD Deploy in one step.
#
#   sudo add-app.sh <app-id> --repo owner/name --dir /srv/<app-id> [options]
#
# It inspects the project's Compose file, writes the root-owned contract
# /etc/saad-deploy/<app-id>.env, validates it with the same loader the engine
# uses, and enables the saad-deploy@<app-id>.timer poller. After that the
# project deploys itself on every green GitHub Actions push and appears in the
# dashboard on the next agent heartbeat.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: add-app.sh <app-id> --repo OWNER/NAME --dir APP_DIR [options]

Required:
  --repo OWNER/NAME        GitHub repository
  --dir PATH               Git checkout on this server (cloned if missing)

Options:
  --name TEXT              Name shown in the dashboard (default: app-id)
  --category CATEGORY      crm | site | bot | service | internal | other (default: other)
  --public-url URL         Public address shown in the dashboard
  --health-url URL         Health URL checked after start (repeatable)
  --branch NAME            Deployed branch (default: main)
  --workflow FILE          GitHub Actions workflow file (default: deploy.yml)
  --compose FILE           Compose file relative to --dir (default: compose.yml)
  --env-file FILE          Compose env file relative to --dir (default: .env.production)
  --token-file PATH        File holding a fine-grained read-only GitHub token
                           (default: $GITHUB_TOKEN from the environment)
  --strategy NAME          recreate (default) | blue_green (edit the file afterwards)
  --print                  Print the generated contract and change nothing
  --no-enable              Write the contract but do not enable the timer
  --force                  Overwrite an existing contract
EOF
}

APP_ID_ARG=""
REPO=""
DIR=""
NAME=""
CATEGORY="other"
PUBLIC=""
HEALTH=()
BRANCH="main"
WORKFLOW="deploy.yml"
COMPOSE_REL="compose.yml"
ENV_REL=".env.production"
TOKEN_FILE=""
STRATEGY="recreate"
PRINT_ONLY=0
ENABLE=1
FORCE=0

parse_args() {
  (($# > 0)) || { usage; exit 2; }
  APP_ID_ARG="$1"
  shift
  while (($# > 0)); do
    case "$1" in
      --repo) REPO="${2:?}"; shift 2 ;;
      --dir) DIR="${2:?}"; shift 2 ;;
      --name) NAME="${2:?}"; shift 2 ;;
      --category) CATEGORY="${2:?}"; shift 2 ;;
      --public-url) PUBLIC="${2:?}"; shift 2 ;;
      --health-url) HEALTH+=("${2:?}"); shift 2 ;;
      --branch) BRANCH="${2:?}"; shift 2 ;;
      --workflow) WORKFLOW="${2:?}"; shift 2 ;;
      --compose) COMPOSE_REL="${2:?}"; shift 2 ;;
      --env-file) ENV_REL="${2:?}"; shift 2 ;;
      --token-file) TOKEN_FILE="${2:?}"; shift 2 ;;
      --strategy) STRATEGY="${2:?}"; shift 2 ;;
      --print) PRINT_ONLY=1; shift ;;
      --no-enable) ENABLE=0; shift ;;
      --force) FORCE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) printf 'add-app: unknown option: %s\n' "$1" >&2; usage; exit 2 ;;
    esac
  done
  validate_app_id "$APP_ID_ARG"
  [[ -n "$REPO" && -n "$DIR" ]] || { usage; exit 2; }
  [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "invalid --repo"
  [[ "$CATEGORY" =~ ^(crm|site|bot|service|internal|other)$ ]] || die "invalid --category"
  [[ "$STRATEGY" =~ ^(recreate|blue_green)$ ]] || die "invalid --strategy"
  [[ "$DIR" = /* ]] || die "--dir must be an absolute path"
  NAME="${NAME:-$APP_ID_ARG}"
  [[ "$NAME" != *'"'* && "$NAME" != *$'\n'* ]] || die "--name must not contain quotes or newlines"
  local url
  for url in "$PUBLIC" "${HEALTH[@]}"; do
    [[ -z "$url" || "$url" =~ ^https?://[^[:space:]\"]+$ ]] || die "invalid URL: ${url}"
  done
}

read_token() {
  local token="${GITHUB_TOKEN:-}"
  if [[ -n "$TOKEN_FILE" ]]; then
    [[ -r "$TOKEN_FILE" ]] || die "cannot read --token-file"
    token="$(tr -d '[:space:]' <"$TOKEN_FILE")"
  fi
  printf '%s' "$token"
}

ensure_checkout() {
  if [[ -d "$DIR/.git" || -f "$DIR/.git" ]]; then
    return 0
  fi
  ((PRINT_ONLY == 0)) || die "APP_DIR is not a Git checkout yet: ${DIR}"
  local token="$1"
  [[ -n "$token" ]] || die "APP_DIR is not a Git checkout and no GitHub token was given to clone it"
  printf 'add-app: cloning %s into %s\n' "$REPO" "$DIR" >&2
  mkdir -p "$(dirname -- "$DIR")"
  # The token goes through an askpass helper, never into argv or .git/config.
  local askpass
  askpass="$(mktemp)"
  # shellcheck disable=SC2016 # Expanded later by the askpass helper, not here.
  printf '#!/bin/sh\nprintf "%%s" "$SAAD_ADD_APP_TOKEN"\n' >"$askpass"
  chmod 0700 "$askpass"
  SAAD_ADD_APP_TOKEN="$token" GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 \
    git clone --branch "$BRANCH" "https://x-access-token@github.com/${REPO}.git" "$DIR" ||
    { rm -f "$askpass"; die "git clone failed"; }
  rm -f "$askpass"
  git -C "$DIR" remote set-url origin "https://github.com/${REPO}.git"
}

# Classify Compose services. Heuristics only fill a first draft; the operator
# can edit the generated contract before the first deployment.
detect_services() {
  local compose_path="$DIR/$COMPOSE_REL" env_path="$DIR/$ENV_REL" json
  [[ -f "$compose_path" ]] || die "Compose file not found: ${compose_path}"
  local env_args=()
  [[ -f "$env_path" ]] && env_args=(--env-file "$env_path")
  json="$(IMAGE_TAG=detect docker compose --project-directory "$DIR" "${env_args[@]}" -f "$compose_path" config --format json)" ||
    die "docker compose config failed for ${compose_path}"

  POSTGRES_SVC="$(jq -r '[.services | to_entries[] | select((.value.image // "") | test("(^|/)postgres(:|$)|postgis")) | .key][0] // ""' <<<"$json")"
  MIGRATE_SVC="$(jq -r '[.services | keys[] | select(test("^(migrate|migrations?|db-migrate)$"))][0] // ""' <<<"$json")"
  INFRA_SVCS="$(jq -r '[.services | to_entries[] | select((.value.build == null) and ((.value.image // "") | test("postgres|postgis|redis|valkey|mongo|mysql|mariadb|rabbitmq|memcached|minio|clickhouse"))) | .key] | join(" ")' <<<"$json")"
  BUILD_SVCS="$(jq -r '[.services | to_entries[] | select(.value.build != null) | .key] | join(" ")' <<<"$json")"
  APP_SVCS="$(jq -r --arg infra " $INFRA_SVCS " --arg migrate "$MIGRATE_SVC" \
    '[.services | keys[] | . as $name | select($name != $migrate and (($infra | contains(" " + $name + " ")) | not))] | join(" ")' <<<"$json")"
  HEALTH_SVCS="$(jq -r --arg apps " $APP_SVCS " \
    '[.services | to_entries[] | .key as $name | select(.value.healthcheck != null and ((.value.healthcheck.disable // false) | not) and ($apps | contains(" " + $name + " "))) | $name] | join(" ")' <<<"$json")"
  NETWORKS="$(jq -r '[.networks // {} | to_entries[] | select(.value.external == true) | (.value.name // .key)] | join(" ")' <<<"$json")"

  [[ -n "$APP_SVCS" ]] || die "no application services found in ${compose_path}"
  if [[ -z "$HEALTH_SVCS" ]]; then
    printf 'add-app: warning: no application service declares a healthcheck; add one (see docs/PROJECT_STANDARD.md)\n' >&2
  fi
}

render_contract() {
  local token="$1"
  local COMPOSE_NAME="${APP_ID_ARG,,}"
  COMPOSE_NAME="${COMPOSE_NAME//./-}"
  cat <<EOF
# SAAD Deploy contract for ${APP_ID_ARG}. Generated by add-app.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Review the detected service lists, then: systemctl start saad-deploy@${APP_ID_ARG}.service

# Dashboard
APP_NAME="${NAME}"
APP_CATEGORY=${CATEGORY}
PUBLIC_URL="${PUBLIC}"

# Source
GITHUB_REPOSITORY=${REPO}
GITHUB_WORKFLOW=${WORKFLOW}
GITHUB_TOKEN=${token:-replace-with-a-fine-grained-read-token}
DEPLOY_BRANCH=${BRANCH}

# Runtime
DEPLOY_STRATEGY=${STRATEGY}
APP_DIR=${DIR}
APP_ENV=${ENV_REL}
COMPOSE_FILE=${COMPOSE_REL}
COMPOSE_PROJECT_NAME=${COMPOSE_NAME}
COMPOSE_PROFILES=""
STATE_DIR=/var/lib/saad-deploy/${APP_ID_ARG}
BACKUP_DIR=/var/backups/saad-deploy/${APP_ID_ARG}
BACKUP_RETENTION_DAYS=14

# Services (detected from ${COMPOSE_REL})
INFRA_SERVICES="${INFRA_SVCS}"
POSTGRES_SERVICE=${POSTGRES_SVC}
MIGRATE_SERVICE=${MIGRATE_SVC}
BUILD_SERVICES="${BUILD_SVCS}"
APP_SERVICES="${APP_SVCS}"
EXTRA_APP_SERVICES=""
HEALTH_SERVICES="${HEALTH_SVCS}"
REQUIRED_EXTERNAL_NETWORKS="${NETWORKS}"
HEALTH_URLS="${HEALTH[*]}"
EOF
}

main() {
  parse_args "$@"
  local config_dir="${SAAD_DEPLOY_CONFIG_DIR:-$SAAD_DEPLOY_DEFAULT_CONFIG_DIR}"
  local config_file="${config_dir}/${APP_ID_ARG}.env"
  if [[ -e "$config_file" && $FORCE -eq 0 && $PRINT_ONLY -eq 0 ]]; then
    die "contract already exists: ${config_file} (use --force to overwrite)"
  fi

  local token
  token="$(read_token)"
  ensure_checkout "$token"
  [[ -f "$DIR/$ENV_REL" ]] ||
    printf 'add-app: warning: %s does not exist yet; create it before the first deployment\n' "$DIR/$ENV_REL" >&2
  detect_services

  if ((PRINT_ONLY)); then
    render_contract ""
    return 0
  fi

  install -d -m 0755 "$config_dir"
  local temporary
  temporary="$(mktemp "${config_dir}/.${APP_ID_ARG}.env.XXXXXX")"
  chmod 0600 "$temporary"
  render_contract "$token" >"$temporary"
  mv -f "$temporary" "$config_file"
  printf 'add-app: wrote %s\n' "$config_file" >&2

  if [[ -f "$DIR/$ENV_REL" ]]; then
    # Validate with the engine's own loader and Compose validation.
    # compose config is called directly: set_step would leave a "deploying" status.
    # shellcheck disable=SC2034 # TARGET_SHA is read by compose() in lib.sh.
    ( load_config "$APP_ID_ARG"; TARGET_SHA=validate; prepare_compose_args; compose config -q ) ||
      die "the generated contract does not validate; edit ${config_file}"
  fi

  if [[ -z "$token" ]]; then
    printf 'add-app: set GITHUB_TOKEN in %s, then enable the timer:\n  systemctl enable --now saad-deploy@%s.timer\n' \
      "$config_file" "$APP_ID_ARG" >&2
    return 0
  fi
  if ((ENABLE)) && [[ -f "$DIR/$ENV_REL" ]]; then
    systemctl enable --now "saad-deploy@${APP_ID_ARG}.timer"
    printf 'add-app: %s is registered; it deploys on the next green push to %s\n' "$APP_ID_ARG" "$BRANCH" >&2
  else
    printf 'add-app: enable automatic deployment with: systemctl enable --now saad-deploy@%s.timer\n' "$APP_ID_ARG" >&2
  fi
}

main "$@"
