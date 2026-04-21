#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACE_LOG="${SCRIPT_DIR}/trace-log.sh"
SESSION_WRAPPER="${SCRIPT_DIR}/cap-session.sh"
DEFAULT_CLI="${CAP_DEFAULT_AGENT_CLI:-codex}"
REGISTRY_HELPER="${SCRIPT_DIR}/cap-registry.sh"

usage() {
  echo "Usage: bash scripts/cap-agent.sh [--cli codex|claude] <agent> [prompt...]" >&2
  exit 1
}

normalize_agent() {
  local raw_agent="$1"
  raw_agent="${raw_agent#\$}"
  printf '%s\n' "${raw_agent}" | tr '[:upper:]' '[:lower:]'
}

resolve_agent_meta() {
  local alias_name="$1"
  if meta_json="$(bash "${REGISTRY_HELPER}" get "${alias_name}" 2>/dev/null)"; then
    printf '%s\n' "${meta_json}"
    return
  fi
  return 1
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

AGENT_META="$(resolve_agent_meta "${AGENT_ALIAS}")" || {
  echo "不支援的 agent：${AGENT_ALIAS}" >&2
  exit 1
}

AGENT_FILE="$(printf '%s' "${AGENT_META}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["prompt_file"])')"
AGENT_PROVIDER="$(printf '%s' "${AGENT_META}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["provider"])')"
AGENT_DEFAULT_CLI="$(printf '%s' "${AGENT_META}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["cli"])')"

if [ -z "${CLI_NAME}" ] || [ "${CLI_NAME}" = "${DEFAULT_CLI}" ]; then
  CLI_NAME="${AGENT_DEFAULT_CLI}"
fi

if [ "${AGENT_PROVIDER}" != "builtin" ]; then
  echo "目前僅支援 builtin provider，尚未支援：${AGENT_PROVIDER}" >&2
  exit 1
fi

PROMPT="$(build_prompt "${AGENT_ALIAS}" "${AGENT_FILE}" "${USER_PROMPT}")"
bash "${TRACE_LOG}" append "CLI-Agent" "agent:${AGENT_ALIAS} 透過 ${CLI_NAME} 啟動" "成功" >/dev/null
exec bash "${SESSION_WRAPPER}" "${CLI_NAME}" "${PROMPT}"
