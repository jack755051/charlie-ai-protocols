#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACE_LOG="${SCRIPT_DIR}/trace-log.sh"
SESSION_WRAPPER="${SCRIPT_DIR}/cap-session.sh"
DEFAULT_CLI="${CAP_DEFAULT_AGENT_CLI:-codex}"

usage() {
  echo "Usage: bash scripts/cap-agent.sh [--cli codex|claude] <agent> [prompt...]" >&2
  exit 1
}

normalize_agent() {
  local raw_agent="$1"
  raw_agent="${raw_agent#\$}"
  printf '%s\n' "${raw_agent}" | tr '[:upper:]' '[:lower:]'
}

resolve_agent_file() {
  case "$1" in
    supervisor) printf '%s\n' '01-supervisor-agent.md' ;;
    techlead) printf '%s\n' '02-techlead-agent.md' ;;
    ba) printf '%s\n' '02a-ba-agent.md' ;;
    dba) printf '%s\n' '02b-dba-api-agent.md' ;;
    ui) printf '%s\n' '03-ui-agent.md' ;;
    frontend) printf '%s\n' '04-frontend-agent.md' ;;
    backend) printf '%s\n' '05-backend-agent.md' ;;
    devops) printf '%s\n' '06-devops-agent.md' ;;
    qa) printf '%s\n' '07-qa-agent.md' ;;
    security) printf '%s\n' '08-security-agent.md' ;;
    analytics) printf '%s\n' '09-analytics-agent.md' ;;
    troubleshoot) printf '%s\n' '10-troubleshoot-agent.md' ;;
    sre) printf '%s\n' '11-sre-agent.md' ;;
    figma) printf '%s\n' '12-figma-agent.md' ;;
    watcher) printf '%s\n' '90-watcher-agent.md' ;;
    logger) printf '%s\n' '99-logger-agent.md' ;;
    *)
      return 1
      ;;
  esac
}

build_prompt() {
  local agent_alias="$1"
  local agent_file="$2"
  local user_prompt="$3"

  if [ -n "${user_prompt}" ]; then
    cat <<EOF
請使用 \$${agent_alias} 載入對應 agent，並嚴格遵守目前專案的 AGENTS.md、核心協議與 [docs/agent-skills/${agent_file}] 中的規範。

本次任務：
${user_prompt}

若本輪形成明確交付，請在結尾附上 logging handoff 摘要。
EOF
  else
    cat <<EOF
請使用 \$${agent_alias} 載入對應 agent，並嚴格遵守目前專案的 AGENTS.md、核心協議與 [docs/agent-skills/${agent_file}] 中的規範。

先進入對應角色並等待我的下一個指令。若本輪形成明確交付，請在結尾附上 logging handoff 摘要。
EOF
  fi
}

CLI_NAME="${DEFAULT_CLI}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cli)
      [ "$#" -ge 2 ] || usage
      CLI_NAME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      break
      ;;
  esac
done

[ "$#" -ge 1 ] || usage

AGENT_ALIAS="$(normalize_agent "$1")"
shift
USER_PROMPT="$*"

case "${CLI_NAME}" in
  codex|claude)
    ;;
  *)
    echo "不支援的 CLI：${CLI_NAME}" >&2
    exit 1
    ;;
esac

AGENT_FILE="$(resolve_agent_file "${AGENT_ALIAS}")" || {
  echo "不支援的 agent：${AGENT_ALIAS}" >&2
  exit 1
}

PROMPT="$(build_prompt "${AGENT_ALIAS}" "${AGENT_FILE}" "${USER_PROMPT}")"
bash "${TRACE_LOG}" append "CLI-Agent" "agent:${AGENT_ALIAS} 透過 ${CLI_NAME} 啟動" "成功" >/dev/null
exec bash "${SESSION_WRAPPER}" "${CLI_NAME}" "${PROMPT}"
