#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACE_LOG="${SCRIPT_DIR}/trace-log.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  bash scripts/cap-session.sh <codex|claude> [args...]    # interactive provider session
  bash scripts/cap-session.sh inspect <session_id> [--json] [--sessions-path <path>]
  bash scripts/cap-session.sh inspect --run-id <run_id>      [--json] [--sessions-path <path>]
  bash scripts/cap-session.sh inspect --workflow-id <wf_id>  [--json] [--sessions-path <path>]
  bash scripts/cap-session.sh inspect --step-id <step_id>    [--json] [--sessions-path <path>]
  bash scripts/cap-session.sh analyze [--top N] [--json] [--run-id <id>] [--workflow-id <id>] [--sessions-path <path>]
EOF
  exit 1
}

resolve_real_bin() {
  local cli_name="$1"
  local override_var
  local override_path

  case "${cli_name}" in
    codex)
      override_var="CAP_REAL_CODEX_BIN"
      ;;
    claude)
      override_var="CAP_REAL_CLAUDE_BIN"
      ;;
    *)
      echo "Unsupported CLI: ${cli_name}" >&2
      exit 1
      ;;
  esac

  override_path="${!override_var:-}"
  if [ -n "${override_path}" ]; then
    printf '%s\n' "${override_path}"
    return
  fi

  if type -P "${cli_name}" >/dev/null 2>&1; then
    type -P "${cli_name}"
    return
  fi

  echo "" >&2
  echo "找不到 ${cli_name} CLI。" >&2
  case "${cli_name}" in
    claude) echo "  安裝：npm install -g @anthropic-ai/claude-code" >&2 ;;
    codex)  echo "  安裝：npm install -g @openai/codex" >&2 ;;
  esac
  echo "  若已安裝在非標準路徑，請設定 ${override_var}。" >&2
  echo "" >&2
  exit 1
}

has_cap_project_context() {
  local project_root

  if [ -n "${CAP_PROJECT_ID_OVERRIDE:-}" ]; then
    return 0
  fi

  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    project_root="$(git rev-parse --show-toplevel)"
  else
    project_root="${PWD}"
  fi

  if [ -f "${project_root}/.cap.project.yaml" ]; then
    return 0
  fi

  if git -C "${project_root}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi

  if [ "${CAP_ALLOW_BASENAME_FALLBACK:-0}" = "1" ]; then
    return 0
  fi

  return 1
}

launch_native_without_cap_context() {
  local cli_name="$1"
  shift

  local real_bin
  real_bin="$(resolve_real_bin "${cli_name}")"

  printf 'cap %s: no CAP project detected; launching native %s.\n' "${cli_name}" "${cli_name}" >&2
  printf 'cap %s: run inside a git repo, add .cap.project.yaml, or set CAP_PROJECT_ID_OVERRIDE to enable CAP-managed trace.\n' "${cli_name}" >&2
  exec "${real_bin}" "$@"
}

[ "$#" -ge 1 ] || usage

CLI_NAME="$1"
shift

case "${CLI_NAME}" in
  codex|claude)
    ;;
  inspect)
    PYTHON_BIN="${PYTHON_BIN:-python3}"
    REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
    exec "${PYTHON_BIN}" "${REPO_ROOT}/engine/session_inspector.py" "$@"
    ;;
  analyze)
    PYTHON_BIN="${PYTHON_BIN:-python3}"
    REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
    exec "${PYTHON_BIN}" "${REPO_ROOT}/engine/session_cost_analyzer.py" "$@"
    ;;
  *)
    usage
    ;;
esac

if ! has_cap_project_context; then
  launch_native_without_cap_context "${CLI_NAME}" "$@"
fi

REAL_BIN="$(resolve_real_bin "${CLI_NAME}")"
SESSION_ID="${CLI_NAME}-$(date '+%Y%m%d-%H%M%S')-$$"
START_EPOCH="$(date '+%s')"

bash "${TRACE_LOG}" append "CLI-${CLI_NAME}" "session:${SESSION_ID} 啟動互動 session" "成功" >/dev/null

set +e
"${REAL_BIN}" "$@"
EXIT_CODE=$?
set -e

DURATION="$(( $(date '+%s') - START_EPOCH ))"

if [ "${EXIT_CODE}" -eq 0 ]; then
  bash "${TRACE_LOG}" append "CLI-${CLI_NAME}" "session:${SESSION_ID} 結束互動 session (duration=${DURATION}s)" "成功" >/dev/null
else
  bash "${TRACE_LOG}" append "CLI-${CLI_NAME}" "session:${SESSION_ID} 結束互動 session (exit=${EXIT_CODE}, duration=${DURATION}s)" "失敗" >/dev/null
fi

exit "${EXIT_CODE}"
