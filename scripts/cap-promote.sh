#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PATH_HELPER="${SCRIPT_DIR}/cap-paths.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  bash scripts/cap-promote.sh inspect <artifact_id> [--json] [--project-root P] [--cap-home C] [--project-id ID]
  bash scripts/cap-promote.sh list [drafts|reports|all]
  bash scripts/cap-promote.sh <local_rel_path> <repo_rel_path>

Subcommands (typed promote surface, P10):
  inspect    read-only inspect of a promote candidate (P10 #3); never writes.

Generic / legacy escape hatch (kept for backward compat per policy §7.4):
  list       enumerate runtime drafts/reports
  <src> <dst>  raw copy from <project_store>/<src> to <repo>/<dst>; no
               validation or backup. Prefer the typed cap promote
               project-constitution / cap promote workflow subcommands
               once they ship (P10 #4 / #5).

Examples:
  bash scripts/cap-promote.sh inspect task-alpha
  bash scripts/cap-promote.sh inspect wf-id --json
  bash scripts/cap-promote.sh list
  bash scripts/cap-promote.sh reports/audit-log.md docs/reports/audit-log.md
  bash scripts/cap-promote.sh drafts/readme-draft.md docs/readme/README-draft.md
EOF
  exit 1
}

resolve_python() {
  if [ -x "${CAP_ROOT}/.venv/bin/python" ]; then
    printf '%s\n' "${CAP_ROOT}/.venv/bin/python"
  else
    printf '%s\n' "python3"
  fi
}

PYTHON_BIN="$(resolve_python)"
PROMOTE_CLI_PY="${CAP_ROOT}/engine/promote_cli.py"

list_files() {
  local scope="${1:-all}"
  local project_store

  project_store="$(bash "${PATH_HELPER}" get project_store)"
  bash "${PATH_HELPER}" ensure >/dev/null

  case "${scope}" in
    drafts)
      find "${project_store}/drafts" -type f | sort
      ;;
    reports)
      find "${project_store}/reports" -type f | sort
      ;;
    all)
      find "${project_store}/drafts" "${project_store}/reports" -type f 2>/dev/null | sort
      ;;
    *)
      echo "不支援的 scope：${scope}" >&2
      exit 1
      ;;
  esac
}

ensure_relative_path() {
  case "$1" in
    /*)
      echo "請使用相對路徑，不接受絕對路徑：$1" >&2
      exit 1
      ;;
    *".."*)
      echo "不接受包含 .. 的路徑：$1" >&2
      exit 1
      ;;
  esac
}

promote_file() {
  local local_rel="$1"
  local repo_rel="$2"
  local project_store
  local source_path
  local target_path

  ensure_relative_path "${local_rel}"
  ensure_relative_path "${repo_rel}"

  case "${local_rel}" in
    drafts/*|reports/*)
      ;;
    *)
      echo "來源必須位於 drafts/ 或 reports/ 下：${local_rel}" >&2
      exit 1
      ;;
  esac

  project_store="$(bash "${PATH_HELPER}" get project_store)"
  source_path="${project_store}/${local_rel}"
  target_path="${CAP_ROOT}/${repo_rel}"

  [ -f "${source_path}" ] || {
    echo "找不到來源檔案：${source_path}" >&2
    exit 1
  }

  mkdir -p "$(dirname "${target_path}")"
  cp "${source_path}" "${target_path}"
  printf '%s\n' "${target_path}"
}

case "${1:-}" in
  inspect)
    shift
    [ "$#" -ge 1 ] || usage
    # Forward all remaining args (artifact_id + optional flags) to the
    # Python CLI; argparse handles positional + flag mixing.
    "${PYTHON_BIN}" "${PROMOTE_CLI_PY}" inspect "$@"
    ;;
  list)
    [ "$#" -le 2 ] || usage
    list_files "${2:-all}"
    ;;
  "")
    usage
    ;;
  *)
    [ "$#" -eq 2 ] || usage
    promote_file "$1" "$2"
    ;;
esac
