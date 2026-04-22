#!/bin/bash
#
# cap-workflow-exec.sh — 前景 step-by-step workflow executor
#
# Usage:
#   bash cap-workflow-exec.sh <plan_json> <user_prompt> [--cli codex|claude]
#
# plan_json: build_execution_phases() 的 JSON 輸出
# 執行每個 phase/step，顯示進度，輸出串流到終端。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TRACE_LOG="${SCRIPT_DIR}/trace-log.sh"
SKILLS_DIR="${CAP_ROOT}/docs/agent-skills"
PROTOCOL_FILE="${SKILLS_DIR}/00-core-protocol.md"

CLI_NAME="${CAP_DEFAULT_AGENT_CLI:-claude}"
PLAN_JSON=""
USER_PROMPT=""

# ── Parse args ──

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cli)
      CLI_NAME="$2"
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

check_cli "${CLI_NAME}" || exit 1

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
  local prompt="$1"
  case "${CLI_NAME}" in
    claude) run_step_claude "${prompt}" ;;
    codex)  run_step_codex "${prompt}" ;;
    *)
      echo "不支援的 CLI：${CLI_NAME}" >&2
      return 1
      ;;
  esac
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

  local agent_path="${SKILLS_DIR}/${prompt_file}"

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

echo ""
printf "${BOLD}WORKFLOW RUN — ${WORKFLOW_NAME}${RESET}\n"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  CLI: ${CLI_NAME}  |  Phases: ${TOTAL_PHASES}  |  ID: ${WORKFLOW_ID}\n"

FAILED=0
COMPLETED=0
SKIPPED=0
START_TOTAL="$(date '+%s')"

# Flatten phases into step lines: phase_num|total|step_ids|agents|step_id|capability|agent_alias|prompt_file|inputs|optional
STEP_LINES="$(python3 - "${PLAN_JSON}" <<'PYEOF'
import json, sys
plan = json.loads(sys.argv[1])
total = len(plan["phases"])
for phase in plan["phases"]:
    pnum = phase["phase"]
    ids_joined = " + ".join(s["step_id"] for s in phase["steps"])
    agents_joined = ", ".join(dict.fromkeys(s["agent_alias"] for s in phase["steps"]))
    for step in phase["steps"]:
        inputs = ",".join(step.get("inputs", []))
        opt = str(step.get("optional", False))
        print("|".join([
            str(pnum), str(total), ids_joined, agents_joined,
            step["step_id"], step["capability"], step["agent_alias"],
            step["prompt_file"], inputs, opt,
        ]))
PYEOF
)"

PREV_PHASE=""

while IFS='|' read -r phase_num total step_ids_in_phase agents_in_phase step_id capability agent_alias prompt_file inputs optional <&3; do

  # Show phase header once per phase
  if [ "${phase_num}" != "${PREV_PHASE}" ]; then
    phase_header "${phase_num}" "${total}" "${step_ids_in_phase}" "${agents_in_phase}"
    PREV_PHASE="${phase_num}"
  fi

  # Skip optional steps without inputs
  if [ "${optional}" = "True" ] && [ -z "${inputs}" ]; then
    step_status "skip" "${step_id}" "0"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Build and execute step
  step_prompt="$(build_step_prompt "${step_id}" "${capability}" "${agent_alias}" "${prompt_file}" "${inputs}" "${USER_PROMPT}")"

  START_STEP="$(date '+%s')"
  STEP_TMP="$(mktemp)"
  trap "rm -f '${STEP_TMP}'" EXIT

  # Run step in background, show spinner with elapsed time
  run_step "${step_prompt}" > "${STEP_TMP}" 2>&1 &
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
    bash "${TRACE_LOG}" append "Workflow-Exec" "step:${step_id} capability:${capability} agent:${agent_alias}" "成功" >/dev/null 2>&1 || true
  else
    step_status "fail" "${step_id}" "${DURATION}"
    FAILED=$((FAILED + 1))
    bash "${TRACE_LOG}" append "Workflow-Exec" "step:${step_id} capability:${capability} agent:${agent_alias}" "失敗" >/dev/null 2>&1 || true

    if [ -n "${output}" ]; then
      printf "  ${RED}%s${RESET}\n" "${output}" | head -5
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
