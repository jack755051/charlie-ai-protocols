#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACE_LOG="${SCRIPT_DIR}/trace-log.sh"

usage() {
  echo "Usage: bash scripts/cap-session.sh <codex|claude> [args...]" >&2
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

  echo "找不到 ${cli_name} 可執行檔。若你已安裝，請設定 ${override_var}。" >&2
  exit 1
}

[ "$#" -ge 1 ] || usage

CLI_NAME="$1"
shift

case "${CLI_NAME}" in
  codex|claude)
    ;;
  *)
    usage
    ;;
esac

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
