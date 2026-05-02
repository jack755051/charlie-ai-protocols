#!/bin/bash

set -euo pipefail

CAP_HOME="${CAP_HOME:-${HOME}/.cap}"

# project_id resolver: strict mode (P1 #1) and identity ledger (P1 #2).
# Resolution chain: CAP_PROJECT_ID_OVERRIDE → .cap.project.yaml → git basename.
# Non-git folders without override or config halt with exit 52 unless
# CAP_ALLOW_BASENAME_FALLBACK=1 is set (legacy escape hatch — ledger still
# written so the fallback path stays auditable).
PROJECT_ID_LEDGER_SCHEMA_VERSION=1
RESOLVED_PROJECT_ID=""
RESOLVED_PROJECT_MODE=""

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

is_inside_git_repo() {
  git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1
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

# Populate RESOLVED_PROJECT_ID and RESOLVED_PROJECT_MODE from project_root.
# Halts with exit 52 if no stable identity source is available and
# CAP_ALLOW_BASENAME_FALLBACK is not set.
resolve_project_identity() {
  local project_root="$1"
  local id="" mode=""

  if [ -n "${CAP_PROJECT_ID_OVERRIDE:-}" ]; then
    id="$(sanitize_project_id "${CAP_PROJECT_ID_OVERRIDE}")"
    mode="override"
  fi

  if [ -z "${id}" ]; then
    local configured_id
    configured_id="$(read_project_id_from_config "${project_root}" || true)"
    if [ -n "${configured_id}" ]; then
      id="$(sanitize_project_id "${configured_id}")"
      mode="config"
    fi
  fi

  if [ -z "${id}" ] && is_inside_git_repo "${project_root}"; then
    id="$(sanitize_project_id "$(basename "${project_root}")")"
    mode="git_basename"
  fi

  if [ -z "${id}" ]; then
    if [ "${CAP_ALLOW_BASENAME_FALLBACK:-0}" = "1" ]; then
      id="$(sanitize_project_id "$(basename "${project_root}")")"
      mode="basename_legacy"
      printf 'cap-paths: warning — using legacy basename fallback (CAP_ALLOW_BASENAME_FALLBACK=1)\n' >&2
      printf 'cap-paths: warning — project_id=%s resolved from basename(%s); set .cap.project.yaml or CAP_PROJECT_ID_OVERRIDE for stable identity\n' "${id}" "${project_root}" >&2
    else
      printf 'cap-paths: error — cannot resolve a stable project_id\n' >&2
      printf '  not in a git repository, no .cap.project.yaml, no CAP_PROJECT_ID_OVERRIDE set\n' >&2
      printf '  fix one of:\n' >&2
      printf '    1. create .cap.project.yaml at %s with `project_id: <stable-id>`\n' "${project_root}" >&2
      printf '    2. export CAP_PROJECT_ID_OVERRIDE=<stable-id>\n' >&2
      printf '    3. export CAP_ALLOW_BASENAME_FALLBACK=1 (legacy escape hatch, not recommended)\n' >&2
      exit 52
    fi
  fi

  RESOLVED_PROJECT_ID="${id}"
  RESOLVED_PROJECT_MODE="${mode}"
}

# Halt with exit 53 if the on-disk identity ledger conflicts with the current
# project_root. Missing ledger is silently ignored here — write_ledger_if_missing
# creates it in the `ensure` subcommand so read-only calls have no side effects.
verify_ledger_or_halt() {
  if [ ! -f "${LEDGER_FILE}" ]; then
    return 0
  fi

  local ledger_origin
  ledger_origin="$(python3 - "${LEDGER_FILE}" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
    print(data.get("origin_path", ""))
except Exception:
    pass
PY
)"

  if [ -z "${ledger_origin}" ] || [ "${ledger_origin}" = "${PROJECT_ROOT}" ]; then
    return 0
  fi

  printf 'cap-paths: error — project_id collision detected\n' >&2
  printf '  project_id=%s\n' "${PROJECT_ID}" >&2
  printf '  ledger_origin=%s (recorded at %s)\n' "${ledger_origin}" "${LEDGER_FILE}" >&2
  printf '  current_origin=%s\n' "${PROJECT_ROOT}" >&2
  printf '  resolve by:\n' >&2
  printf '    1. add a unique suffix in .cap.project.yaml (e.g. project_id: %s-<suffix>)\n' "${PROJECT_ID}" >&2
  printf '    2. export CAP_PROJECT_ID_OVERRIDE=<unique-id>\n' >&2
  printf '    3. remove the colliding storage (rm -rf %s) if you intend to reset\n' "${PROJECT_STORE}" >&2
  exit 53
}

write_ledger_if_missing() {
  if [ -f "${LEDGER_FILE}" ]; then
    return 0
  fi

  mkdir -p "${PROJECT_STORE}"
  python3 - \
    "${LEDGER_FILE}" \
    "${PROJECT_ID}" \
    "${PROJECT_ROOT}" \
    "${RESOLVED_PROJECT_MODE}" \
    "${PROJECT_ID_LEDGER_SCHEMA_VERSION}" <<'PY'
import datetime
import json
import sys

ledger_file, project_id, origin_path, mode, schema_version = sys.argv[1:6]
data = {
    "schema_version": int(schema_version),
    "project_id": project_id,
    "resolved_mode": mode,
    "origin_path": origin_path,
    "created_at": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(ledger_file, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
}

PROJECT_ROOT="$(find_project_root)"
resolve_project_identity "${PROJECT_ROOT}"
PROJECT_ID="${RESOLVED_PROJECT_ID}"
PROJECT_STORE="${CAP_HOME}/projects/${PROJECT_ID}"
LEDGER_FILE="${PROJECT_STORE}/.identity.json"
TRACE_DIR="${PROJECT_STORE}/traces"
LOG_DIR="${PROJECT_STORE}/logs"
DRAFT_DIR="${PROJECT_STORE}/drafts"
HANDOFF_DIR="${PROJECT_STORE}/handoffs"
REPORT_DIR="${PROJECT_STORE}/reports"
WORKFLOW_REPORT_DIR="${REPORT_DIR}/workflows"
CONSTITUTION_DIR="${PROJECT_STORE}/constitutions"
COMPILED_WORKFLOW_DIR="${PROJECT_STORE}/compiled-workflows"
BINDING_DIR="${PROJECT_STORE}/bindings"
WORKSPACE_DIR="${PROJECT_STORE}/workspace"
CACHE_DIR="${PROJECT_STORE}/cache"
SESSION_DIR="${PROJECT_STORE}/sessions"

# Read-only subcommands still validate the ledger — collision must surface
# before any caller consumes a path under the wrong project storage.
verify_ledger_or_halt

ensure_dirs() {
  mkdir -p \
    "${CAP_HOME}" \
    "${CAP_HOME}/projects" \
    "${PROJECT_STORE}" \
    "${TRACE_DIR}" \
    "${LOG_DIR}" \
    "${DRAFT_DIR}" \
    "${HANDOFF_DIR}" \
    "${REPORT_DIR}" \
    "${WORKFLOW_REPORT_DIR}" \
    "${CONSTITUTION_DIR}" \
    "${COMPILED_WORKFLOW_DIR}" \
    "${BINDING_DIR}" \
    "${WORKSPACE_DIR}" \
    "${CACHE_DIR}" \
    "${SESSION_DIR}"
  write_ledger_if_missing
}

get_key() {
  case "${1:-}" in
    cap_home) printf '%s\n' "${CAP_HOME}" ;;
    project_root) printf '%s\n' "${PROJECT_ROOT}" ;;
    project_id) printf '%s\n' "${PROJECT_ID}" ;;
    project_id_mode) printf '%s\n' "${RESOLVED_PROJECT_MODE}" ;;
    project_store) printf '%s\n' "${PROJECT_STORE}" ;;
    ledger_file) printf '%s\n' "${LEDGER_FILE}" ;;
    trace_dir) printf '%s\n' "${TRACE_DIR}" ;;
    log_dir) printf '%s\n' "${LOG_DIR}" ;;
    draft_dir) printf '%s\n' "${DRAFT_DIR}" ;;
    handoff_dir) printf '%s\n' "${HANDOFF_DIR}" ;;
    report_dir) printf '%s\n' "${REPORT_DIR}" ;;
    workflow_report_dir) printf '%s\n' "${WORKFLOW_REPORT_DIR}" ;;
    constitution_dir) printf '%s\n' "${CONSTITUTION_DIR}" ;;
    compiled_workflow_dir) printf '%s\n' "${COMPILED_WORKFLOW_DIR}" ;;
    binding_dir) printf '%s\n' "${BINDING_DIR}" ;;
    workspace_dir) printf '%s\n' "${WORKSPACE_DIR}" ;;
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
project_id_mode=${RESOLVED_PROJECT_MODE}
project_store=${PROJECT_STORE}
ledger_file=${LEDGER_FILE}
trace_dir=${TRACE_DIR}
log_dir=${LOG_DIR}
draft_dir=${DRAFT_DIR}
handoff_dir=${HANDOFF_DIR}
report_dir=${REPORT_DIR}
workflow_report_dir=${WORKFLOW_REPORT_DIR}
constitution_dir=${CONSTITUTION_DIR}
compiled_workflow_dir=${COMPILED_WORKFLOW_DIR}
binding_dir=${BINDING_DIR}
workspace_dir=${WORKSPACE_DIR}
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
