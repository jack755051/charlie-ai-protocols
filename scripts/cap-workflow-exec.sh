#!/bin/bash
#
# cap-workflow-exec.sh — 前景 step-by-step workflow executor
#
# Usage:
#   bash cap-workflow-exec.sh <plan_json> <user_prompt> [--cli codex|claude]
#
# plan_json: RuntimeBinder.build_bound_execution_phases() 的 JSON 輸出
# 執行每個 phase/step，顯示進度，輸出串流到終端。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TRACE_LOG="${SCRIPT_DIR}/trace-log.sh"
PATH_HELPER="${SCRIPT_DIR}/cap-paths.sh"
SKILLS_DIR="${CAP_ROOT}/docs/agent-skills"
PROTOCOL_FILE="${SKILLS_DIR}/00-core-protocol.md"

CLI_NAME="${CAP_DEFAULT_AGENT_CLI:-}"
PLAN_JSON=""
USER_PROMPT=""
RUN_ID=""

# ── Parse args ──

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cli)
      CLI_NAME="$2"
      shift 2
      ;;
    --run-id)
      RUN_ID="$2"
      shift 2
      ;;
    *)
      if [ -z "${PLAN_JSON}" ]; then
        PLAN_JSON="$1"
      elif [ -z "${USER_PROMPT}" ]; then
        USER_PROMPT="$1"
      else
        USER_PROMPT="${USER_PROMPT} $1"
      fi
      shift
      ;;
  esac
done

[ -n "${PLAN_JSON}" ] || {
  echo "Usage: bash cap-workflow-exec.sh <plan_json> <user_prompt> [--cli codex|claude]" >&2
  exit 1
}

get_status_store() {
  local cache_dir
  local preferred
  local fallback
  cache_dir="$(bash "${PATH_HELPER}" get cache_dir)"
  preferred="${cache_dir}/workflow-runs.json"
  fallback="${CAP_ROOT}/workspace/history/workflow-runs.json"

  mkdir -p "$(dirname "${fallback}")" >/dev/null 2>&1 || true

  if [ -f "${fallback}" ]; then
    printf '%s\n' "${fallback}"
    return
  fi

  if { [ -f "${preferred}" ] && [ -w "${preferred}" ]; } || { [ ! -f "${preferred}" ] && [ -d "${cache_dir}" ] && [ -w "${cache_dir}" ]; }; then
    printf '%s\n' "${preferred}"
    return
  fi

  printf '%s\n' "${fallback}"
}

update_workflow_status() {
  local workflow_id="$1"
  local workflow_name="$2"
  local state="$3"
  local result="$4"
  local status_file
  status_file="$(get_status_store)"
  python3 - <<'PY' "${status_file}" "${workflow_id}" "${workflow_name}" "${state}" "${result}"
from pathlib import Path
import json
import sys
from datetime import datetime

status_file = Path(sys.argv[1])
workflow_id = sys.argv[2]
workflow_name = sys.argv[3]
state = sys.argv[4]
result = sys.argv[5]

def normalize(payload):
    if isinstance(payload, dict) and ("workflows" in payload or "runs" in payload):
        workflows = payload.get("workflows", {})
        runs = payload.get("runs", [])
    elif isinstance(payload, dict):
        workflows = {k: v for k, v in payload.items() if isinstance(v, dict)}
        runs = []
    else:
        workflows = {}
        runs = []
    return {
        "version": 2,
        "workflows": workflows if isinstance(workflows, dict) else {},
        "runs": runs if isinstance(runs, list) else [],
    }

payload = normalize(json.loads(status_file.read_text(encoding="utf-8"))) if status_file.exists() else normalize({})
entry = payload["workflows"].get(workflow_id, {})
entry["workflow_name"] = workflow_name
entry["state"] = state
entry["last_result"] = result
entry["last_run_at"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
entry["run_count"] = int(entry.get("run_count", 0))
payload["workflows"][workflow_id] = entry

status_file.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
PY
}

# ── CLI availability check ──

check_cli() {
  local cli="$1"
  if command -v "${cli}" >/dev/null 2>&1; then
    return 0
  fi
  echo "" >&2
  echo "找不到 ${cli} CLI。workflow 前景執行需要至少一套 AI CLI 工具。" >&2
  echo "" >&2
  case "${cli}" in
    claude)
      echo "  安裝 Claude Code:" >&2
      echo "    npm install -g @anthropic-ai/claude-code" >&2
      echo "" >&2
      echo "  或改用 Codex:" >&2
      echo "    cap workflow run --cli codex <workflow> \"<prompt>\"" >&2
      ;;
    codex)
      echo "  安裝 Codex:" >&2
      echo "    npm install -g @openai/codex" >&2
      echo "" >&2
      echo "  或改用 Claude:" >&2
      echo "    cap workflow run --cli claude <workflow> \"<prompt>\"" >&2
      ;;
  esac
  echo "" >&2
  return 1
}

# ── CLI command builder ──

run_step_claude() {
  local prompt="$1"
  claude -p "${prompt}" 2>&1
}

run_step_codex() {
  local prompt="$1"
  codex exec "${prompt}" 2>&1
}

run_step() {
  local cli="$1"
  local prompt="$2"
  case "${cli}" in
    claude) run_step_claude "${prompt}" ;;
    codex)  run_step_codex "${prompt}" ;;
    *)
      echo "不支援的 CLI：${cli}" >&2
      return 1
      ;;
  esac
}

resolve_step_cli() {
  local step_cli="$1"
  if [ -n "${CLI_NAME}" ]; then
    printf '%s\n' "${CLI_NAME}"
    return
  fi
  if [ -n "${step_cli}" ]; then
    printf '%s\n' "${step_cli}"
    return
  fi
  printf '%s\n' "claude"
}

# ── Progress display ──

BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

phase_header() {
  local phase_num="$1"
  local total="$2"
  local step_ids="$3"
  local agents="$4"
  printf "\n${BOLD}▶ Phase %s/%s${RESET}  %s → %s\n" "${phase_num}" "${total}" "${step_ids}" "${agents}"
  printf "${DIM}──────────────────────────────────────────────────${RESET}\n"
}

step_status() {
  local status="$1"
  local step_id="$2"
  local duration="$3"
  case "${status}" in
    ok)   printf "  ${GREEN}✓${RESET} %s ${DIM}(%ss)${RESET}\n" "${step_id}" "${duration}" ;;
    fail) printf "  ${RED}✗${RESET} %s ${DIM}(%ss)${RESET}\n" "${step_id}" "${duration}" ;;
    skip) printf "  ${YELLOW}⊘${RESET} %s ${DIM}(skipped)${RESET}\n" "${step_id}" ;;
  esac
}

# ── Build step prompt ──

build_step_prompt() {
  local step_id="$1"
  local capability="$2"
  local agent_alias="$3"
  local prompt_file="$4"
  local inputs="$5"
  local user_req="$6"

  cat <<EOF
你現在是 ${agent_alias} agent，正在執行 workflow step: ${step_id} (capability: ${capability})。

使用者的原始需求：
${user_req}

本步驟的輸入上下文：${inputs}

請嚴格依照 docs/agent-skills/${prompt_file} 中定義的角色規範執行。
完成後，請輸出你的交接摘要（agent_id, task_summary, output_paths, result）。
EOF
}

# ── Main execution loop ──

WORKFLOW_NAME="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["name"])' "${PLAN_JSON}")"
WORKFLOW_ID="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["workflow_id"])' "${PLAN_JSON}")"
TOTAL_PHASES="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])["phases"]))' "${PLAN_JSON}")"

on_exit() {
  if [ -n "${RUN_ID}" ]; then
    return
  fi
  if [ "${FAILED}" -gt 0 ]; then
    update_workflow_status "${WORKFLOW_ID}" "${WORKFLOW_NAME}" "failed" "foreground_failed"
  else
    update_workflow_status "${WORKFLOW_ID}" "${WORKFLOW_NAME}" "completed" "foreground_completed"
  fi
}

trap on_exit EXIT

echo ""
printf "${BOLD}WORKFLOW RUN — ${WORKFLOW_NAME}${RESET}\n"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  CLI: %s  |  Phases: %s  |  ID: %s\n" "${CLI_NAME:-auto}" "${TOTAL_PHASES}" "${WORKFLOW_ID}"

FAILED=0
COMPLETED=0
SKIPPED=0
START_TOTAL="$(date '+%s')"

# Flatten phases into step lines:
# phase_num|total|step_ids|agents|step_id|capability|agent_alias|prompt_file|step_cli|inputs|optional|resolution_status
STEP_LINES="$(python3 - "${PLAN_JSON}" <<'PYEOF'
import json, sys
plan = json.loads(sys.argv[1])
total = len(plan["phases"])
for phase in plan["phases"]:
    pnum = phase["phase"]
    ids_joined = " + ".join(s["step_id"] for s in phase["steps"])
    agents_joined = ", ".join(
        dict.fromkeys((s.get("agent_alias") or s.get("skill_id") or "-") for s in phase["steps"])
    )
    for step in phase["steps"]:
        inputs = ",".join(step.get("inputs", []))
        opt = str(step.get("optional", False))
        resolution_status = step.get("resolution_status", "resolved")
        print("|".join([
            str(pnum), str(total), ids_joined, agents_joined,
            step["step_id"], step["capability"], step.get("agent_alias") or "",
            step.get("prompt_file") or "", step.get("cli") or "", inputs, opt, resolution_status,
        ]))
PYEOF
)"

PREV_PHASE=""

while IFS='|' read -r phase_num total step_ids_in_phase agents_in_phase step_id capability agent_alias prompt_file step_cli inputs optional resolution_status <&3; do

  # Show phase header once per phase
  if [ "${phase_num}" != "${PREV_PHASE}" ]; then
    phase_header "${phase_num}" "${total}" "${step_ids_in_phase}" "${agents_in_phase}"
    PREV_PHASE="${phase_num}"
  fi

  # Skip optional steps that were intentionally left unresolved in degraded mode.
  if [ "${resolution_status}" = "optional_unresolved" ]; then
    step_status "skip" "${step_id}" "0"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Guard against malformed preflight state leaking into execution.
  if [ "${resolution_status}" = "required_unresolved" ] || [ "${resolution_status}" = "incompatible" ]; then
    echo "  ${RED}│ step ${step_id} 無法執行：binding 狀態為 ${resolution_status}${RESET}"
    FAILED=$((FAILED + 1))
    break
  fi

  # Skip optional steps without inputs
  if [ "${optional}" = "True" ] && [ -z "${inputs}" ]; then
    step_status "skip" "${step_id}" "0"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if [ -z "${agent_alias}" ] || [ -z "${prompt_file}" ]; then
    echo "  ${RED}│ step ${step_id} 缺少 agent_alias 或 prompt_file，無法執行${RESET}"
    FAILED=$((FAILED + 1))
    break
  fi

  effective_cli="$(resolve_step_cli "${step_cli}")"
  check_cli "${effective_cli}" || {
    FAILED=$((FAILED + 1))
    break
  }

  # Build and execute step
  step_prompt="$(build_step_prompt "${step_id}" "${capability}" "${agent_alias}" "${prompt_file}" "${inputs}" "${USER_PROMPT}")"

  START_STEP="$(date '+%s')"
  STEP_TMP="$(mktemp)"
  trap "rm -f '${STEP_TMP}'" EXIT

  # Run step in background, show spinner with elapsed time
  run_step "${effective_cli}" "${step_prompt}" > "${STEP_TMP}" 2>&1 &
  STEP_PID=$!

  SPIN='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  SPIN_IDX=0
  while kill -0 "${STEP_PID}" 2>/dev/null; do
    ELAPSED="$(( $(date '+%s') - START_STEP ))"
    printf "\r  ${YELLOW}%s${RESET} ${DIM}Running ${step_id}... (%ss)${RESET}  " "${SPIN:SPIN_IDX:1}" "${ELAPSED}"
    SPIN_IDX=$(( (SPIN_IDX + 1) % ${#SPIN} ))
    sleep 0.15
  done
  printf "\r\033[K"

  set +e
  wait "${STEP_PID}"
  exit_code=$?
  set -e

  output="$(cat "${STEP_TMP}")"
  rm -f "${STEP_TMP}"
  DURATION="$(( $(date '+%s') - START_STEP ))"

  if [ "${exit_code}" -eq 0 ]; then
    step_status "ok" "${step_id}" "${DURATION}"
    COMPLETED=$((COMPLETED + 1))
    bash "${TRACE_LOG}" append "Workflow-Exec" "step:${step_id} capability:${capability} agent:${agent_alias} cli:${effective_cli}" "成功" >/dev/null 2>&1 || true
  else
    step_status "fail" "${step_id}" "${DURATION}"
    FAILED=$((FAILED + 1))

    # ── Error classification ──
    ERROR_TYPE="unknown"
    ERROR_HINT=""
    output_lower="$(echo "${output}" | tr '[:upper:]' '[:lower:]')"

    # Auth / login errors
    if echo "${output_lower}" | grep -qE 'not logged in|not authenticated|unauthorized|authentication required|login required|sign in|no api key|invalid.*api.?key|ANTHROPIC_API_KEY|OPENAI_API_KEY'; then
      ERROR_TYPE="auth"
      case "${effective_cli}" in
        claude) ERROR_HINT="  請先登入：執行 'claude' 啟動互動 session 完成認證。" ;;
        codex)  ERROR_HINT="  請先設定 API Key：export OPENAI_API_KEY=<your-key>" ;;
      esac
    # Rate limit / quota
    elif echo "${output_lower}" | grep -qE 'rate.?limit|too many requests|429|quota.*exceeded|billing|usage.?limit|credit|overloaded|capacity'; then
      ERROR_TYPE="rate_limit"
      ERROR_HINT="  API 額度不足或請求過於頻繁。建議：
    - 稍等幾分鐘後重試
    - 檢查帳戶用量與額度限制
    - 若持續發生，考慮升級方案或切換 CLI：cap workflow run --cli codex ..."
    # Network errors
    elif echo "${output_lower}" | grep -qE 'network|connection.*refused|timeout|dns|econnreset|enotfound|fetch failed'; then
      ERROR_TYPE="network"
      ERROR_HINT="  網路連線異常。請確認：
    - 網路是否正常
    - 是否需要 proxy 設定
    - API 服務是否正常（查看 status page）"
    # Trusted directory (codex)
    elif echo "${output_lower}" | grep -qE 'trusted directory|skip-git-repo-check'; then
      ERROR_TYPE="trust"
      ERROR_HINT="  Codex 不信任目前目錄。請先在專案目錄內執行 'codex' 並允許信任。"
    fi

    bash "${TRACE_LOG}" append "Workflow-Exec" "step:${step_id} error_type:${ERROR_TYPE} capability:${capability} cli:${effective_cli}" "失敗" >/dev/null 2>&1 || true

    # Show classified error
    if [ -n "${output}" ]; then
      echo "${output}" | head -3 | while IFS= read -r line; do
        printf "  ${RED}│ %s${RESET}\n" "${line}"
      done
    fi
    if [ -n "${ERROR_HINT}" ]; then
      printf "\n${YELLOW}  [%s]${RESET}\n" "${ERROR_TYPE}"
      echo "${ERROR_HINT}"
    fi

    if [ "${optional}" != "True" ]; then
      printf "\n${RED}✗ Workflow halted at step: ${step_id}${RESET}\n"
      break
    fi
  fi

  # Show condensed output
  if [ -n "${output}" ] && [ "${exit_code}" -eq 0 ]; then
    echo "${output}" | head -3 | while IFS= read -r line; do
      printf "  ${DIM}│ %s${RESET}\n" "${line}"
    done
    total_lines="$(echo "${output}" | wc -l | tr -d ' ')"
    if [ "${total_lines}" -gt 3 ]; then
      printf "  ${DIM}│ ... (%s lines total)${RESET}\n" "${total_lines}"
    fi
  fi

done 3<<< "${STEP_LINES}"

TOTAL_DURATION="$(( $(date '+%s') - START_TOTAL ))"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  Done in %ss  |  ✓ %s  ✗ %s  ⊘ %s\n" "${TOTAL_DURATION}" "${COMPLETED}" "${FAILED}" "${SKIPPED}"
echo ""

FINAL_STATE="completed"
FINAL_RESULT="success"
EXIT_CODE=0

if [ "${FAILED}" -gt 0 ]; then
  FINAL_STATE="failed"
  FINAL_RESULT="step_failed"
  EXIT_CODE=1
fi

if [ -n "${RUN_ID}" ]; then
  bash "${SCRIPT_DIR}/cap-workflow.sh" update-run-status "${RUN_ID}" "${FINAL_STATE}" "${FINAL_RESULT}" >/dev/null 2>&1 || true
fi

exit "${EXIT_CODE}"
