#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib.sh
source "${SCRIPT_DIR}/lib.sh"

readonly CACHE_MAX_AGE="168h"
readonly MAINTENANCE_LOCK_FILE="/run/saad-deploy-maintenance.lock"

log() {
  printf 'saad-deploy-maintenance: %s\n' "$*"
}

usage() {
  printf 'Usage: %s [--all] [--dry-run]\n' "${0##*/}" >&2
}

is_sha() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

append_unique() {
  local value="$1"
  local -n values="$2"
  local existing
  for existing in "${values[@]}"; do
    [[ "$existing" == "$value" ]] && return 0
  done
  values+=("$value")
}

release_image_repositories() {
  local placeholder_sha="0000000000000000000000000000000000000000"
  local build_services=()
  split_list BUILD_SERVICES build_services
  ((${#build_services[@]})) || return 0

  IMAGE_TAG="$placeholder_sha" docker "${COMPOSE_ARGS[@]}" config --images "${build_services[@]}" \
    | sed -E 's/:[^:]+$//' \
    | sort -u
}

running_image_references() {
  docker ps -a --format '{{.Image}}'
}

prune_app_release_images() {
  local app_id="$1"
  local keep_shas=()
  local repositories=()
  local repository image_ref tag

  load_config "$app_id"
  prepare_compose_args
  read_state
  is_sha "$CURRENT_SHA" && append_unique "$CURRENT_SHA" keep_shas
  is_sha "$PREVIOUS_SHA" && append_unique "$PREVIOUS_SHA" keep_shas

  while IFS= read -r repository; do
    [[ -n "$repository" ]] && append_unique "$repository" repositories
  done < <(release_image_repositories)

  for repository in "${repositories[@]}"; do
    while IFS=' ' read -r image_ref tag; do
      [[ "$image_ref" == "$repository" ]] || continue
      is_sha "$tag" || continue
      if [[ " ${keep_shas[*]} " == *" ${tag} "* ]]; then
        continue
      fi

      image_ref="${repository}:${tag}"
      if running_image_references | grep -Fxq "$image_ref"; then
        log "keeping image in use: ${image_ref}"
      elif ((DRY_RUN)); then
        log "would remove stale image: ${image_ref}"
      else
        log "removing stale image: ${image_ref}"
        docker image rm "$image_ref" || log "could not remove image: ${image_ref}"
      fi
    done < <(docker image ls --format '{{.Repository}} {{.Tag}}' "$repository")
  done
}

prune_build_cache() {
  local arguments=(buildx prune --all --force)
  if (( ! PRUNE_ALL )); then
    arguments+=(--filter "until=${CACHE_MAX_AGE}")
  fi

  if ((DRY_RUN)); then
    log "would run: docker ${arguments[*]}"
  else
    # Buildx prints one line for every cache record. Keep the journal useful
    # while preserving its final reclamation summary and propagating failures.
    docker "${arguments[@]}" 2>&1 | tail -n 12
  fi
}

main() {
  PRUNE_ALL=0
  DRY_RUN=0
  while (($#)); do
    case "$1" in
      --all) PRUNE_ALL=1 ;;
      --dry-run) DRY_RUN=1 ;;
      *) usage; return 2 ;;
    esac
    shift
  done

  exec {lock_fd}>"$MAINTENANCE_LOCK_FILE"
  if ! flock -n "$lock_fd"; then
    log "another maintenance run is active; skipping"
    return 0
  fi

  local config_file app_id
  shopt -s nullglob
  for config_file in "${SAAD_DEPLOY_DEFAULT_CONFIG_DIR}"/*.env; do
    app_id="${config_file##*/}"
    app_id="${app_id%.env}"
    prune_app_release_images "$app_id"
  done
  prune_build_cache
}

main "$@"
