#!/bin/bash

set -euo pipefail

CAP_HOME="${CAP_HOME:-${HOME}/.cap}"

usage() {
  echo "Usage: bash scripts/cap-paths.sh <ensure|get|show> [key]" >&2
  exit 1
}

find_project_root() {
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    git rev-parse --show-toplevel
    return
  fi

  printf '%s\n' "${PWD}"
}

read_project_id_from_config() {
  local project_root="$1"
  local config_file="${project_root}/.cap.project.yaml"

  [ -f "${config_file}" ] || return 1

  sed -n -E 's/^project_id:[[:space:]]*"?([^"#]+)"?[[:space:]]*$/\1/p' "${config_file}" | head -n 1
}

sanitize_project_id() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

resolve_project_id() {
  local project_root="$1"
  local configured_id=""

  configured_id="$(read_project_id_from_config "${project_root}" || true)"
  if [ -n "${configured_id}" ]; then
    sanitize_project_id "${configured_id}"
    return
  fi

  sanitize_project_id "$(basename "${project_root}")"
}

PROJECT_ROOT="$(find_project_root)"
PROJECT_ID="$(resolve_project_id "${PROJECT_ROOT}")"
PROJECT_STORE="${CAP_HOME}/projects/${PROJECT_ID}"
TRACE_DIR="${PROJECT_STORE}/traces"
LOG_DIR="${PROJECT_STORE}/logs"
DRAFT_DIR="${PROJECT_STORE}/drafts"
HANDOFF_DIR="${PROJECT_STORE}/handoffs"
REPORT_DIR="${PROJECT_STORE}/reports"
CACHE_DIR="${PROJECT_STORE}/cache"
SESSION_DIR="${PROJECT_STORE}/sessions"

ensure_dirs() {
  mkdir -p \
    "${CAP_HOME}" \
    "${CAP_HOME}/projects" \
    "${TRACE_DIR}" \
    "${LOG_DIR}" \
    "${DRAFT_DIR}" \
    "${HANDOFF_DIR}" \
    "${REPORT_DIR}" \
    "${CACHE_DIR}" \
    "${SESSION_DIR}"
}

get_key() {
  case "${1:-}" in
    cap_home) printf '%s\n' "${CAP_HOME}" ;;
    project_root) printf '%s\n' "${PROJECT_ROOT}" ;;
    project_id) printf '%s\n' "${PROJECT_ID}" ;;
    project_store) printf '%s\n' "${PROJECT_STORE}" ;;
    trace_dir) printf '%s\n' "${TRACE_DIR}" ;;
    log_dir) printf '%s\n' "${LOG_DIR}" ;;
    draft_dir) printf '%s\n' "${DRAFT_DIR}" ;;
    handoff_dir) printf '%s\n' "${HANDOFF_DIR}" ;;
    report_dir) printf '%s\n' "${REPORT_DIR}" ;;
    cache_dir) printf '%s\n' "${CACHE_DIR}" ;;
    session_dir) printf '%s\n' "${SESSION_DIR}" ;;
    *)
      echo "Unknown key: ${1:-}" >&2
      exit 1
      ;;
  esac
}

show_all() {
  cat <<EOF
cap_home=${CAP_HOME}
project_root=${PROJECT_ROOT}
project_id=${PROJECT_ID}
project_store=${PROJECT_STORE}
trace_dir=${TRACE_DIR}
log_dir=${LOG_DIR}
draft_dir=${DRAFT_DIR}
handoff_dir=${HANDOFF_DIR}
report_dir=${REPORT_DIR}
cache_dir=${CACHE_DIR}
session_dir=${SESSION_DIR}
EOF
}

case "${1:-}" in
  ensure)
    ensure_dirs
    ;;
  get)
    [ "$#" -eq 2 ] || usage
    get_key "$2"
    ;;
  show)
    show_all
    ;;
  *)
    usage
    ;;
esac
