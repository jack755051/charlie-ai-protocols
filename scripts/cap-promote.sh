#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PATH_HELPER="${SCRIPT_DIR}/cap-paths.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  bash scripts/cap-promote.sh list [drafts|reports|all]
  bash scripts/cap-promote.sh <local_rel_path> <repo_rel_path>

Examples:
  bash scripts/cap-promote.sh list
  bash scripts/cap-promote.sh reports/audit-log.md docs/reports/audit-log.md
  bash scripts/cap-promote.sh drafts/readme-draft.md docs/readme/README-draft.md
EOF
  exit 1
}

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
