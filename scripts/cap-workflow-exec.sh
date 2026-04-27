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
VENV_PYTHON="${CAP_ROOT}/.venv/bin/python"

CLI_NAME="${CAP_DEFAULT_AGENT_CLI:-}"
REQUESTED_MODE="${CAP_WORKFLOW_REQUESTED_MODE:-}"
SELECTED_MODE="${CAP_WORKFLOW_SELECTED_MODE:-}"
REQUESTED_STRATEGY="${CAP_WORKFLOW_REQUESTED_STRATEGY:-${REQUESTED_MODE}}"
SELECTED_STRATEGY="${CAP_WORKFLOW_SELECTED_STRATEGY:-${SELECTED_MODE}}"
PLAN_JSON=""
USER_PROMPT=""
RUN_ID=""
DEFAULT_STEP_TIMEOUT_SECONDS="${CAP_WORKFLOW_STEP_TIMEOUT_SECONDS:-600}"
DEFAULT_STEP_STALL_SECONDS="${CAP_WORKFLOW_STEP_STALL_SECONDS:-120}"
DEFAULT_STEP_STALL_ACTION="${CAP_WORKFLOW_STALL_ACTION:-warn}"

resolve_python() {
  if [ -x "${VENV_PYTHON}" ]; then
    printf '%s\n' "${VENV_PYTHON}"
  else
    printf '%s\n' "python3"
  fi
}

PYTHON_BIN="$(resolve_python)"
STEP_PY="${CAP_ROOT}/engine/step_runtime.py"

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
  "${PYTHON_BIN}" "${STEP_PY}" update-status "${status_file}" "${workflow_id}" "${workflow_name}" "${state}" "${result}"
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

# Codex stdout 包含 banner + prompt echo + response，需要清洗。
# 策略：找到 Codex 的 response 起始標記（`assistant` 或第一個非 banner 行），
# 剝離之前的所有內容。
strip_codex_preamble() {
  awk '
    BEGIN { found = 0 }
    # Codex banner 結尾是 "--------" 後接 "user" 行，response 從 "assistant" 開始
    /^assistant$/ { found = 1; next }
    found == 1 { print }
    # 如果沒有 assistant 標記（舊版 codex），fallback：跳過前面的 banner
    END { if (found == 0) exit 1 }
  '
}

run_step_codex() {
  local prompt="$1"
  local raw
  raw="$(codex exec "${prompt}" 2>&1)"
  # 嘗試剝離 Codex preamble；若失敗（無 assistant 標記），保留原始輸出
  printf '%s\n' "${raw}" | strip_codex_preamble 2>/dev/null || printf '%s\n' "${raw}"
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

resolve_shell_script_path() {
  local script_ref="$1"

  case "${script_ref}" in
    scripts/workflows/*.sh) ;;
    *)
      echo "shell step script 必須位於 scripts/workflows/*.sh：${script_ref}" >&2
      return 1
      ;;
  esac

  local script_path="${CAP_ROOT}/${script_ref}"
  if [ ! -f "${script_path}" ]; then
    echo "找不到 shell step script：${script_ref}" >&2
    return 1
  fi
  if [ ! -x "${script_path}" ]; then
    echo "shell step script 不可執行：${script_ref}" >&2
    return 1
  fi

  printf '%s\n' "${script_path}"
}

run_shell_step() {
  local script_ref="$1"
  local step_id="$2"
  local output_path="$3"
  local artifact_index="$4"
  local input_context="$5"
  local contract_context="$6"
  local user_prompt="$7"
  local script_path

  script_path="$(resolve_shell_script_path "${script_ref}")" || return 30
  CAP_WORKFLOW_STEP_ID="${step_id}" \
  CAP_WORKFLOW_OUTPUT_PATH="${output_path}" \
  CAP_WORKFLOW_ARTIFACT_INDEX="${artifact_index}" \
  CAP_WORKFLOW_INPUT_CONTEXT="${input_context}" \
  CAP_WORKFLOW_CONTRACT_CONTEXT="${contract_context}" \
  CAP_WORKFLOW_USER_PROMPT="${user_prompt}" \
  CAP_WORKFLOW_REQUESTED_MODE="${REQUESTED_MODE}" \
  CAP_WORKFLOW_SELECTED_MODE="${SELECTED_MODE}" \
  CAP_WORKFLOW_REQUESTED_STRATEGY="${REQUESTED_STRATEGY}" \
  CAP_WORKFLOW_SELECTED_STRATEGY="${SELECTED_STRATEGY}" \
  bash "${script_path}" 2>&1
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

shell_exit_condition() {
  local code="$1"
  case "${code}" in
    10) printf '%s\n' "no_changes" ;;
    20) printf '%s\n' "ambiguous_change_type" ;;
    21) printf '%s\n' "mixed_change_type" ;;
    30) printf '%s\n' "policy_blocked" ;;
    40) printf '%s\n' "git_operation_failed" ;;
    50) printf '%s\n' "sensitive_file_risk" ;;
    *)  printf '%s\n' "shell_exit_nonzero" ;;
  esac
}

fallback_condition_allowed() {
  local condition="$1"
  local fallback_when="$2"

  [ -n "${fallback_when}" ] || return 1
  case ",${fallback_when}," in
    *",${condition},"*) return 0 ;;
    *",shell_exit_nonzero,"*) [ "${condition}" != "sensitive_file_risk" ] && return 0 ;;
  esac
  return 1
}

# ── Progress display ──

BOLD=$'\033[1m'
DIM=$'\033[2m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
RESET=$'\033[0m'

phase_header() {
  local phase_num="$1"
  local total="$2"
  local step_ids="$3"
  local agents="$4"
  local bar
  bar="$(phase_bar "${phase_num}" "${total}")"
  echo ""
  printf "${GREEN}%s${RESET}\n" "${bar}"
  printf "${BOLD}  Phase %s/%s${RESET}  ${DIM}%s${RESET}  →  ${BOLD}%s${RESET}\n" "${phase_num}" "${total}" "${step_ids}" "${agents}"
  printf "${DIM}  ─────────────────────────────────────────────${RESET}\n"
}

phase_bar() {
  local phase_num="$1"
  local total="$2"
  local width=14
  local filled=$(( (phase_num * width + total - 1) / total ))
  local empty=$(( width - filled ))
  local bar=""

  for ((i = 0; i < filled; i++)); do bar="${bar}■"; done
  for ((i = 0; i < empty; i++)); do bar="${bar}□"; done
  printf "%s" "${bar}"
}

section_total_for_capability() {
  local capability="$1"
  case "${capability}" in
    prd_generation) printf "6" ;;
    *)              printf "4" ;;
  esac
}

structured_sections_for_capability() {
  local capability="$1"
  case "${capability}" in
    prd_generation)
      cat <<'EOF'
請使用以下固定章節標題依序輸出，讓 workflow 可以從串流標題推斷段內進度：
## 專案目標
## 核心價值與受眾
## 技術堆疊與架構定案
## 預期功能清單
## 下一步調度建議
## 設計交付模式
EOF
      ;;
    *)
      cat <<'EOF'
請使用以下固定章節標題依序輸出，讓 workflow 可以從串流標題推斷段內進度：
## 任務理解
## 執行重點
## 產出內容
## 交接摘要
EOF
      ;;
  esac
}

detected_section_count() {
  local output_file="$1"
  local total="$2"
  local count
  count="$(grep -cE '^##[[:space:]]+' "${output_file}" 2>/dev/null || true)"
  if [ "${count}" -gt "${total}" ]; then
    count="${total}"
  fi
  printf "%s" "${count}"
}

latest_section_heading() {
  local output_file="$1"
  grep -E '^##[[:space:]]+' "${output_file}" 2>/dev/null | tail -n 1 | tr '\r\t' '  '
}

format_activity_status() {
  local step_id="$1"
  local elapsed="$2"
  local silent="$3"
  local timeout="$4"
  local bytes="$5"
  local spin="$6"
  local section_done="$7"
  local section_total="$8"
  local stall_note="$9"

  local signal="${YELLOW}◌ waiting${RESET}"
  if [ "${bytes}" -gt 0 ]; then
    local kb=$(( bytes / 1024 ))
    if [ "${kb}" -gt 0 ]; then
      signal="${GREEN}● ${kb}KB${RESET}"
    else
      signal="${GREEN}● ${bytes}B${RESET}"
    fi
  fi

  local time_color="${DIM}"
  if [ "${elapsed}" -ge "${timeout}" ] 2>/dev/null; then
    time_color="${RED}"
  elif [ "${elapsed}" -ge $(( timeout * 3 / 4 )) ] 2>/dev/null; then
    time_color="${YELLOW}"
  fi

  printf "\r\033[K  ${YELLOW}%s${RESET} %s  %s[%ss]${RESET}  ${DIM}[%s/%s]${RESET}%s" \
    "${spin}" "${signal}" "${time_color}" "${elapsed}" "${section_done}" "${section_total}" "${stall_note}"
}

step_status() {
  local status="$1"
  local step_id="$2"
  local duration="$3"
  case "${status}" in
    ok)   printf "  ${GREEN}✓${RESET} %s ${DIM}(%ss)${RESET}\n" "${step_id}" "${duration}" ;;
    fail) printf "  ${RED}✗${RESET} %s ${DIM}(%ss)${RESET}\n" "${step_id}" "${duration}" ;;
    skip) printf "  ${YELLOW}⊘${RESET} %s ${DIM}(skipped)${RESET}\n" "${step_id}" ;;
    stop) printf "  ${RED}■${RESET} %s ${DIM}(%ss)${RESET}\n" "${step_id}" "${duration}" ;;
    block) printf "  ${RED}■${RESET} %s ${DIM}(blocked)${RESET}\n" "${step_id}" ;;
  esac
}

terminate_step() {
  local pid="$1"
  kill "${pid}" 2>/dev/null || true
  sleep 1
  if kill -0 "${pid}" 2>/dev/null; then
    kill -9 "${pid}" 2>/dev/null || true
  fi
}

positive_int_or_default() {
  local value="$1"
  local fallback="$2"
  case "${value}" in
    ''|*[!0-9]*) printf '%s\n' "${fallback}" ;;
    *)           printf '%s\n' "${value}" ;;
  esac
}

stall_action_or_default() {
  local value="$1"
  local fallback="$2"
  case "${value}" in
    warn|kill) printf '%s\n' "${value}" ;;
    *)         printf '%s\n' "${fallback}" ;;
  esac
}

ensure_dir_or_fail() {
  local dir="$1"
  local label="$2"

  if mkdir -p "${dir}" 2>/dev/null; then
    return 0
  fi

  printf "${RED}✗ 無法建立 %s：%s${RESET}\n" "${label}" "${dir}" >&2
  return 1
}

write_file_or_fail() {
  local path="$1"
  local content="$2"
  local dir
  dir="$(dirname "${path}")"

  ensure_dir_or_fail "${dir}" "output directory" || return 1
  if printf '%s\n' "${content}" > "${path}" 2>/dev/null; then
    return 0
  fi

  printf "${RED}✗ 無法寫入檔案：%s${RESET}\n" "${path}" >&2
  return 1
}

output_has_executor_fallback_marker() {
  local path="$1"
  [ -f "${path}" ] && grep -q 'Executor fallback: agent did not write the required output file' "${path}" 2>/dev/null
}

output_has_failure_result_marker() {
  local path="$1"
  [ -f "${path}" ] && grep -qiE '(^|[[:space:]-])result:[[:space:]]*`?(blocked|blocked_by_|failed|failure|error)|(^|[[:space:]-])(commit_result|tag_result|push_result):[[:space:]]*`?(failed|not_created|not_attempted)' "${path}" 2>/dev/null
}

append_workflow_log() {
  local log_path="$1"
  local agent_skill="$2"
  local detail="$3"
  local result="$4"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s][%s][%s][%s]\n' "${ts}" "${agent_skill}" "${detail}" "${result}" >> "${log_path}" 2>/dev/null || true
}

materialize_step_output() {
  local step_id="$1"
  local output_path="$2"
  local captured_output="$3"
  local source="agent_file"

  if [ -s "${output_path}" ] && ! output_has_executor_fallback_marker "${output_path}"; then
    printf '%s\n' "${source}"
    return 0
  fi

  source="captured_stdout"
  if [ -n "${captured_output}" ]; then
    write_file_or_fail "${output_path}" "${captured_output}" || return 1
    printf '%s\n' "${source}"
    return 0
  fi

  source="empty_capture"
  write_file_or_fail "${output_path}" "# ${step_id}

> Executor note: the agent completed without writing the required output file and without producing captured stdout/stderr.
" || return 1
  printf '%s\n' "${source}"
}

build_handoff_summary_content() {
  local artifact_path="$1"
  "${PYTHON_BIN}" "${STEP_PY}" handoff-summary "${artifact_path}"
}

materialize_handoff_summary() {
  local artifact_path="$1"
  local handoff_path="$2"
  local summary
  summary="$(build_handoff_summary_content "${artifact_path}")"
  if [ -z "${summary}" ]; then
    summary="## 交接摘要

> 無可用摘要，請回看完整 artifact。"
  fi
  write_file_or_fail "${handoff_path}" "${summary}"
}

resolve_step_input_context() {
  local plan_json="$1"
  local current_step_id="$2"
  local input_mode="$3"
  local registry_path="$4"

  "${PYTHON_BIN}" "${STEP_PY}" resolve-inputs "${plan_json}" "${current_step_id}" "${input_mode}" "${registry_path}"
}

resolve_step_contract_context() {
  local plan_json="$1"
  local current_step_id="$2"

  "${PYTHON_BIN}" "${STEP_PY}" resolve-contract "${plan_json}" "${current_step_id}"
}

validate_step_inputs() {
  local plan_json="$1"
  local current_step_id="$2"
  local registry_path="$3"

  "${PYTHON_BIN}" "${STEP_PY}" validate-inputs "${plan_json}" "${current_step_id}" "${registry_path}"
}

current_git_branch() {
  git branch --show-current 2>/dev/null || true
}

step_requires_attached_branch() {
  local capability="$1"
  local inputs="$2"

  if [ "${capability}" = "version_control_commit" ]; then
    return 0
  fi

  if [ "${capability}" = "version_control_tag" ] && [[ ",${inputs}," == *",commit_result,"* ]]; then
    return 0
  fi

  return 1
}

register_step_runtime_state() {
  local plan_json="$1"
  local registry_path="$2"
  local step_id="$3"
  local execution_state="$4"
  local blocked_reason="$5"
  local output_source="$6"
  local output_path="$7"
  local handoff_path="$8"

  "${PYTHON_BIN}" "${STEP_PY}" register-state "${plan_json}" "${registry_path}" "${step_id}" "${execution_state}" "${blocked_reason}" "${output_source}" "${output_path}" "${handoff_path}"
}

register_agent_session() {
  local session_id="$1"
  local step_id="$2"
  local capability="$3"
  local agent_alias="$4"
  local prompt_file="$5"
  local provider_cli="$6"
  local executor="$7"
  local lifecycle="$8"
  local result="$9"
  local input_mode="${10}"
  local output_path="${11}"
  local handoff_path="${12}"
  local failure_reason="${13}"
  local duration_seconds="${14}"

  "${PYTHON_BIN}" "${STEP_PY}" upsert-session \
    "${AGENT_SESSIONS_JSON}" \
    "${RUN_LABEL}" \
    "${WORKFLOW_ID}" \
    "${WORKFLOW_NAME}" \
    "${session_id}" \
    "${step_id}" \
    "${capability}" \
    "${agent_alias}" \
    "${prompt_file}" \
    "${provider_cli}" \
    "${executor}" \
    "${lifecycle}" \
    "${result}" \
    "${input_mode}" \
    "${output_path}" \
    "${handoff_path}" \
    "${failure_reason}" \
    "${duration_seconds}" >/dev/null 2>&1 || true
}

session_lifecycle_for_state() {
  local final_state="$1"
  case "${final_state}" in
    validated) printf '%s\n' "completed" ;;
    blocked)   printf '%s\n' "blocked" ;;
    *)         printf '%s\n' "failed" ;;
  esac
}

session_result_for_state() {
  local final_state="$1"
  case "${final_state}" in
    validated) printf '%s\n' "success" ;;
    blocked)   printf '%s\n' "blocked" ;;
    skipped)   printf '%s\n' "skipped" ;;
    *)         printf '%s\n' "failed" ;;
  esac
}

# ── Build step prompt ──

build_step_prompt() {
  local step_id="$1"
  local capability="$2"
  local agent_alias="$3"
  local prompt_file="$4"
  local inputs="$5"
  local step_contract="$6"
  local user_req="$7"
  local output_path="$8"
  local artifact_index="$9"
  local project_docs_dir="${10}"
  local input_mode="${11}"
  local continue_reason="${12}"
  local structured_sections
  structured_sections="$(structured_sections_for_capability "${capability}")"

  cat <<EOF
你現在是 ${agent_alias} agent，正在執行 workflow step: ${step_id} (capability: ${capability})。

使用者的原始需求：
${user_req}

本步驟的輸入上下文：${inputs}

本步驟的輸入模式：
${input_mode}

本次 version-control strategy：
requested_strategy=${REQUESTED_STRATEGY:-<unset>}
selected_strategy=${SELECTED_STRATEGY:-<unset>}

本步驟的契約與完成條件：
${step_contract}

可用的上游產物索引：
${artifact_index}

本步驟的強制輸出檔：
${output_path}

專案文件目錄：
${project_docs_dir}

請嚴格依照 ${SKILLS_DIR}/${prompt_file} 中定義的角色規範執行。
你必須完成以下事項：
1. 讀取可用的上游產物索引，若索引內有上游輸出檔，必須把它們視為本步驟輸入，而不是重新猜測。
2. 若本步驟的輸入模式為 summary，你必須只以交接摘要與必要 metadata 為主要依據，不得要求完整上游全文。
3. 將本步驟的完整交付內容直接輸出到 stdout；workflow executor 會負責把 stdout 可靠寫入「本步驟的強制輸出檔」。
4. 不要因為無法直接寫入「本步驟的強制輸出檔」而請求權限、暫停、或把結果標記為待確認；stdout 就是本步驟的主要交付通道。
5. 若本步驟產出可長期追蹤的正式/半正式規格，且你確定環境允許寫入，才可額外同步寫入專案文件目錄下合適的 Markdown 檔；若不能寫入，請在 stdout 的交接摘要中列出建議路徑即可。

本步驟繼續執行的理由：
${continue_reason}

${structured_sections}

完成後，請輸出交接摘要（agent_id, task_summary, output_paths, result）。
EOF
}

# ── Main execution loop ──

# 一次取得 workflow_id / workflow_name / total_phases（取代散落的 inline json.loads）
IFS='|' read -r WORKFLOW_ID WORKFLOW_NAME TOTAL_PHASES <<EOF
$("${PYTHON_BIN}" "${STEP_PY}" plan-meta "${PLAN_JSON}")
EOF

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
if [ -n "${SELECTED_STRATEGY}" ]; then
  printf "  Strategy: %s  |  Requested: %s\n" "${SELECTED_STRATEGY}" "${REQUESTED_STRATEGY:-auto}"
fi

FAILED=0
COMPLETED=0
SKIPPED=0
START_TOTAL="$(date '+%s')"
RUN_LABEL="${RUN_ID:-manual-$(date '+%Y%m%d-%H%M%S')-$$}"

bash "${PATH_HELPER}" ensure >/dev/null 2>&1 || true
PROJECT_ROOT="$(bash "${PATH_HELPER}" get project_root)"
REPORT_DIR="$(bash "${PATH_HELPER}" get report_dir)"
WORKFLOW_REPORT_DIR="$(bash "${PATH_HELPER}" get workflow_report_dir)"
WORKFLOW_OUTPUT_DIR="${WORKFLOW_REPORT_DIR}/${WORKFLOW_ID}/${RUN_LABEL}"
PROJECT_DOCS_DIR="${PROJECT_ROOT}/docs"
ARTIFACT_INDEX="${WORKFLOW_OUTPUT_DIR}/artifact-index.md"
RUN_SUMMARY="${WORKFLOW_OUTPUT_DIR}/run-summary.md"
RESULT_REPORT="${WORKFLOW_OUTPUT_DIR}/result.md"
WORKFLOW_LOG="${WORKFLOW_OUTPUT_DIR}/workflow.log"
RUNTIME_STATE_JSON="${WORKFLOW_OUTPUT_DIR}/runtime-state.json"
AGENT_SESSIONS_JSON="${WORKFLOW_OUTPUT_DIR}/agent-sessions.json"
ensure_dir_or_fail "${WORKFLOW_OUTPUT_DIR}" "workflow output directory" || exit 1
ensure_dir_or_fail "${PROJECT_DOCS_DIR}" "project docs directory" || true

write_file_or_fail "${ARTIFACT_INDEX}" "$(cat <<EOF
# Workflow Artifact Index

- workflow_id: ${WORKFLOW_ID}
- workflow_name: ${WORKFLOW_NAME}
- run_id: ${RUN_LABEL}
- project_root: ${PROJECT_ROOT}
- output_dir: ${WORKFLOW_OUTPUT_DIR}
- workflow_log: ${WORKFLOW_LOG}

## Step Outputs
EOF
)" || exit 1

write_file_or_fail "${RUN_SUMMARY}" "$(cat <<EOF
# Workflow Run Summary

- workflow_id: ${WORKFLOW_ID}
- workflow_name: ${WORKFLOW_NAME}
- run_id: ${RUN_LABEL}
- started_at: $(date '+%Y-%m-%d %H:%M:%S')
- project_root: ${PROJECT_ROOT}
- output_dir: ${WORKFLOW_OUTPUT_DIR}
- workflow_log: ${WORKFLOW_LOG}

## User Prompt

${USER_PROMPT}

## Steps
EOF
)" || exit 1

write_file_or_fail "${WORKFLOW_LOG}" "$(cat <<EOF
[$(date '+%Y-%m-%d %H:%M:%S')][workflow][workflow:${WORKFLOW_ID} run:${RUN_LABEL} output_dir:${WORKFLOW_OUTPUT_DIR}][started]
EOF
)" || exit 1

write_file_or_fail "${RUNTIME_STATE_JSON}" '{"artifacts": {}, "steps": {}}' || exit 1
write_file_or_fail "${AGENT_SESSIONS_JSON}" "$(cat <<EOF
{
  "version": 1,
  "run_id": "${RUN_LABEL}",
  "workflow_id": "${WORKFLOW_ID}",
  "workflow_name": "${WORKFLOW_NAME}",
  "sessions": []
}
EOF
)" || exit 1

echo "  Output dir: ${WORKFLOW_OUTPUT_DIR}"

# Flatten phases into step lines:
# phase_num|total|step_ids|agents|step_id|capability|agent_alias|prompt_file|step_cli|inputs|optional|resolution_status|timeout_seconds|stall_seconds|stall_action|input_mode|output_tier|continue_reason|executor|script|fallback_executor|fallback_when
STEP_LINES="$("${PYTHON_BIN}" "${STEP_PY}" flatten-steps "${PLAN_JSON}")"

PREV_PHASE=""

while IFS='|' read -r phase_num total step_ids_in_phase agents_in_phase step_id capability agent_alias prompt_file step_cli inputs optional resolution_status timeout_seconds stall_seconds stall_action input_mode output_tier continue_reason executor script_ref fallback_executor fallback_when <&3; do

  # Show phase header once per phase
  if [ "${phase_num}" != "${PREV_PHASE}" ]; then
    phase_header "${phase_num}" "${total}" "${step_ids_in_phase}" "${agents_in_phase}"
    PREV_PHASE="${phase_num}"
  fi

  # Skip optional steps that were intentionally left unresolved in degraded mode.
  if [ "${resolution_status}" = "optional_unresolved" ]; then
    step_status "skip" "${step_id}" "0"
    SKIPPED=$((SKIPPED + 1))
    register_step_runtime_state "${PLAN_JSON}" "${RUNTIME_STATE_JSON}" "${step_id}" "skipped" "unresolved_binding" "" "" ""
    continue
  fi

  # Guard against malformed preflight state leaking into execution.
  if [ "${resolution_status}" = "required_unresolved" ] || [ "${resolution_status}" = "incompatible" ]; then
    echo "  ${RED}│ step ${step_id} 無法執行：binding 狀態為 ${resolution_status}${RESET}"
    FAILED=$((FAILED + 1))
    register_step_runtime_state "${PLAN_JSON}" "${RUNTIME_STATE_JSON}" "${step_id}" "blocked" "unresolved_binding" "" "" ""
    break
  fi

  # Skip optional steps without inputs
  if [ "${optional}" = "True" ] && [ -z "${inputs}" ]; then
    step_status "skip" "${step_id}" "0"
    SKIPPED=$((SKIPPED + 1))
    register_step_runtime_state "${PLAN_JSON}" "${RUNTIME_STATE_JSON}" "${step_id}" "skipped" "" "" "" ""
    continue
  fi

  effective_executor="${executor:-ai}"
  if [ "${effective_executor}" != "ai" ] && [ "${effective_executor}" != "shell" ]; then
    echo "  ${RED}│ step ${step_id} executor 不支援：${effective_executor}${RESET}"
    FAILED=$((FAILED + 1))
    register_step_runtime_state "${PLAN_JSON}" "${RUNTIME_STATE_JSON}" "${step_id}" "blocked" "unsupported_executor" "" "" ""
    break
  fi

  if { [ "${effective_executor}" = "ai" ] || [ "${fallback_executor}" = "ai" ]; } && { [ -z "${agent_alias}" ] || [ -z "${prompt_file}" ]; }; then
    echo "  ${RED}│ step ${step_id} 缺少 agent_alias 或 prompt_file，無法執行${RESET}"
    FAILED=$((FAILED + 1))
    register_step_runtime_state "${PLAN_JSON}" "${RUNTIME_STATE_JSON}" "${step_id}" "blocked" "unresolved_binding" "" "" ""
    break
  fi

  effective_cli="$(resolve_step_cli "${step_cli}")"
  if [ "${effective_executor}" = "ai" ] || [ "${fallback_executor}" = "ai" ]; then
    check_cli "${effective_cli}" || {
      FAILED=$((FAILED + 1))
      break
    }
  fi

  if [ "${effective_executor}" = "shell" ] && ! resolve_shell_script_path "${script_ref}" >/dev/null; then
    FAILED=$((FAILED + 1))
    register_step_runtime_state "${PLAN_JSON}" "${RUNTIME_STATE_JSON}" "${step_id}" "blocked" "invalid_shell_script" "" "" ""
    break
  fi

  STEP_OUTPUT_PATH="${WORKFLOW_OUTPUT_DIR}/${phase_num}-${step_id}.md"
  STEP_HANDOFF_PATH="${WORKFLOW_OUTPUT_DIR}/${phase_num}-${step_id}.handoff.md"
  SESSION_ID="${RUN_LABEL}.${phase_num}.${step_id}"
  STEP_STATUS="running"
  AGENT_SKILL="${agent_alias}:${prompt_file}"
  INPUT_CHECK_JSON="$(validate_step_inputs "${PLAN_JSON}" "${step_id}" "${RUNTIME_STATE_JSON}")"
  # 將 validate-inputs JSON 解析成兩行（ok / missing-csv）給 shell 直接讀
  { read -r INPUT_OK; read -r MISSING_INPUTS; } < <(printf '%s' "${INPUT_CHECK_JSON}" | "${PYTHON_BIN}" "${STEP_PY}" parse-input-check)
  if [ "${INPUT_OK}" != "True" ]; then
    if [ "${optional}" = "True" ]; then
      step_status "skip" "${step_id}" "0"
      printf "  ${YELLOW}│ optional step skipped: missing inputs -> %s${RESET}\n" "${MISSING_INPUTS}"
      SKIPPED=$((SKIPPED + 1))
      register_step_runtime_state "${PLAN_JSON}" "${RUNTIME_STATE_JSON}" "${step_id}" "skipped" "missing_input_artifact" "" "" ""
      continue
    fi
    step_status "block" "${step_id}" "0"
    printf "  ${RED}│ blocked_missing_input: %s${RESET}\n" "${MISSING_INPUTS}"
    FAILED=$((FAILED + 1))
    register_step_runtime_state "${PLAN_JSON}" "${RUNTIME_STATE_JSON}" "${step_id}" "blocked" "missing_input_artifact" "" "" ""
    break
  fi

  if step_requires_attached_branch "${capability}" "${inputs}"; then
    CURRENT_BRANCH="$(current_git_branch)"
    if [ -z "${CURRENT_BRANCH}" ]; then
      step_status "block" "${step_id}" "0"
      printf "  ${RED}│ blocked_detached_head: version control step requires an attached branch${RESET}\n"
      FAILED=$((FAILED + 1))
      register_step_runtime_state "${PLAN_JSON}" "${RUNTIME_STATE_JSON}" "${step_id}" "blocked" "detached_head" "" "" ""
      break
    fi
  fi

  append_workflow_log "${WORKFLOW_LOG}" "${AGENT_SKILL}" "phase:${phase_num} step:${step_id} capability:${capability} cli:${effective_cli} action:start" "running"
  RESOLVED_INPUT_CONTEXT="$(resolve_step_input_context "${PLAN_JSON}" "${step_id}" "${input_mode:-summary}" "${RUNTIME_STATE_JSON}")"
  STEP_CONTRACT_CONTEXT="$(resolve_step_contract_context "${PLAN_JSON}" "${step_id}")"

  # Build and execute step
  step_prompt="$(
    build_step_prompt \
      "${step_id}" \
      "${capability}" \
      "${agent_alias}" \
      "${prompt_file}" \
      "${RESOLVED_INPUT_CONTEXT}" \
      "${STEP_CONTRACT_CONTEXT}" \
      "${USER_PROMPT}" \
      "${STEP_OUTPUT_PATH}" \
      "${ARTIFACT_INDEX}" \
      "${PROJECT_DOCS_DIR}" \
      "${input_mode:-summary}" \
      "${continue_reason:-required by workflow}"
  )"

  START_STEP="$(date '+%s')"
  STEP_TMP="$(mktemp)"
  effective_timeout="$(positive_int_or_default "${timeout_seconds}" "${DEFAULT_STEP_TIMEOUT_SECONDS}")"
  effective_stall="$(positive_int_or_default "${stall_seconds}" "${DEFAULT_STEP_STALL_SECONDS}")"
  effective_stall_action="$(stall_action_or_default "${stall_action}" "${DEFAULT_STEP_STALL_ACTION}")"
  LAST_SIZE=0
  LAST_CHANGE="${START_STEP}"
  STOP_REASON=""
  STALL_WARNED=0
  SECTION_TOTAL="$(section_total_for_capability "${capability}")"
  LAST_SECTION_DONE=0

  if [ "${effective_executor}" = "shell" ]; then
    printf "  ${BOLD}%s${RESET}  ${DIM}%s · %s · %s${RESET}\n" "${step_id}" "shell" "${capability}" "${script_ref}"
  else
    printf "  ${BOLD}%s${RESET}  ${DIM}%s · %s · %s${RESET}\n" "${step_id}" "${agent_alias}" "${capability}" "${effective_cli}"
  fi

  register_agent_session \
    "${SESSION_ID}" \
    "${step_id}" \
    "${capability}" \
    "${agent_alias}" \
    "${prompt_file}" \
    "${effective_cli}" \
    "${effective_executor}" \
    "running" \
    "pending" \
    "${input_mode:-summary}" \
    "${STEP_OUTPUT_PATH}" \
    "${STEP_HANDOFF_PATH}" \
    "" \
    ""

  # Run step in background, show live output chunks plus watchdog state.
  if [ "${effective_executor}" = "shell" ]; then
    run_shell_step "${script_ref}" "${step_id}" "${STEP_OUTPUT_PATH}" "${ARTIFACT_INDEX}" "${RESOLVED_INPUT_CONTEXT}" "${STEP_CONTRACT_CONTEXT}" "${USER_PROMPT}" > "${STEP_TMP}" 2>&1 &
  else
    run_step "${effective_cli}" "${step_prompt}" > "${STEP_TMP}" 2>&1 &
  fi
  STEP_PID=$!

  SPIN='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  SPIN_IDX=0
  while kill -0 "${STEP_PID}" 2>/dev/null; do
    NOW="$(date '+%s')"
    ELAPSED="$(( NOW - START_STEP ))"
    CURRENT_SIZE="$(wc -c < "${STEP_TMP}" 2>/dev/null | tr -d ' ')"
    if [ -z "${CURRENT_SIZE}" ]; then
      CURRENT_SIZE=0
    fi
    if [ "${CURRENT_SIZE}" -gt "${LAST_SIZE}" ]; then
      LAST_SIZE="${CURRENT_SIZE}"
      LAST_CHANGE="${NOW}"
    fi
    SILENT_DURATION="$(( NOW - LAST_CHANGE ))"
    STATUS_NOTE=""
    if [ "${effective_stall}" -gt 0 ] && [ "${SILENT_DURATION}" -ge "${effective_stall}" ]; then
      STATUS_NOTE=" │ stall:${effective_stall_action}"
    fi
    SECTION_DONE="$(detected_section_count "${STEP_TMP}" "${SECTION_TOTAL}")"
    if [ "${SECTION_DONE}" -gt "${LAST_SECTION_DONE}" ]; then
      printf "\r\033[K  ${DIM}│ %s${RESET}\n" "$(latest_section_heading "${STEP_TMP}")"
      LAST_SECTION_DONE="${SECTION_DONE}"
    fi
    format_activity_status \
      "${step_id}" \
      "${ELAPSED}" \
      "${SILENT_DURATION}" \
      "${effective_timeout}" \
      "${CURRENT_SIZE}" \
      "${SPIN:SPIN_IDX:1}" \
      "${SECTION_DONE}" \
      "${SECTION_TOTAL}" \
      "${STATUS_NOTE}"

    if [ "${effective_timeout}" -gt 0 ] && [ "${ELAPSED}" -ge "${effective_timeout}" ]; then
      STOP_REASON="TIMEOUT"
      terminate_step "${STEP_PID}"
      break
    fi
    if [ "${effective_stall}" -gt 0 ] && [ "${SILENT_DURATION}" -ge "${effective_stall}" ]; then
      if [ "${effective_stall_action}" = "kill" ]; then
        STOP_REASON="STALL"
        terminate_step "${STEP_PID}"
        break
      elif [ "${STALL_WARNED}" -eq 0 ]; then
        bash "${TRACE_LOG}" append "Workflow-Exec" "step:${step_id} warning:stall silent:${SILENT_DURATION}s capability:${capability} cli:${effective_cli}" "警告" >/dev/null 2>&1 || true
        STALL_WARNED=1
      fi
    fi

    SPIN_IDX=$(( (SPIN_IDX + 1) % ${#SPIN} ))
    sleep 0.15
  done
  printf "\r\033[K"

  set +e
  wait "${STEP_PID}"
  exit_code=$?
  set -e

  if [ -f "${STEP_TMP}" ]; then
    CURRENT_SIZE="$(wc -c < "${STEP_TMP}" 2>/dev/null | tr -d ' ')"
    output="$(cat "${STEP_TMP}" 2>/dev/null || true)"
  else
    output=""
    append_workflow_log "${WORKFLOW_LOG}" "${AGENT_SKILL}" "step:${step_id} temp_output_missing:${STEP_TMP}" "失敗"
  fi
  rm -f "${STEP_TMP}"

  if [ "${effective_executor}" = "shell" ] && [ "${exit_code}" -ne 0 ] && [ -z "${STOP_REASON}" ]; then
    SHELL_CONDITION="$(shell_exit_condition "${exit_code}")"
    if fallback_condition_allowed "${SHELL_CONDITION}" "${fallback_when}"; then
      FALLBACK_TMP="$(mktemp)"
      FALLBACK_PROMPT="${step_prompt}

Shell executor fallback context:
- shell_script: ${script_ref}
- shell_exit_code: ${exit_code}
- shell_condition: ${SHELL_CONDITION}
- shell_output:
${output}

Git evidence:
$(git status --short 2>/dev/null || true)
$(git diff --stat 2>/dev/null || true)

請接手處理此 shell step 未能安全自動完成的情境。若涉及 sensitive_file_risk，必須停止並回報，不得自行加入或推送敏感檔案。"

      if [ "${SHELL_CONDITION}" = "ambiguous_change_type" ]; then
        FALLBACK_PROMPT="${FALLBACK_PROMPT}

Release / governed-mode requirements:
1. 你必須根據 git diff 與 changed paths 產生具體 Conventional Commit message，不得使用 update docs workflow assets、update project documentation、release vX.Y.Z 這類泛用文字。
2. 若建立 annotated tag，tag message 的第一行必須是具體 release 摘要，例如「v0.14.1 — enforce governed release fallback and semantic tag summaries」，不得使用「Release vX.Y.Z」。
3. CHANGELOG / README 的 release note 必須描述實際變更，不得只寫版本號或泛用 release 句。"
      fi

      printf "  ${YELLOW}│ shell exit %s (%s)，切換 AI fallback${RESET}\n" "${exit_code}" "${SHELL_CONDITION}"
      START_FALLBACK="$(date '+%s')"
      set +e
      run_step "${effective_cli}" "${FALLBACK_PROMPT}" > "${FALLBACK_TMP}" 2>&1
      fallback_exit_code=$?
      set -e
      fallback_output="$(cat "${FALLBACK_TMP}" 2>/dev/null || true)"
      rm -f "${FALLBACK_TMP}"
      output="${fallback_output}"
      exit_code="${fallback_exit_code}"
      effective_executor="ai"
      script_ref="${script_ref} -> ai_fallback:${SHELL_CONDITION}"
      DURATION="$(( $(date '+%s') - START_STEP ))"
    fi
  fi

  DURATION="$(( $(date '+%s') - START_STEP ))"
  SHOULD_HALT=0
  OUTPUT_SOURCE=""
  FINAL_STEP_STATE="running"

  if ! OUTPUT_SOURCE="$(materialize_step_output "${step_id}" "${STEP_OUTPUT_PATH}" "${output}")"; then
    STEP_STATUS="write_failed"
    FINAL_STEP_STATE="hard_fail"
    step_status "fail" "${step_id}" "${DURATION}"
    FAILED=$((FAILED + 1))
    ERROR_TYPE="write_permission"
    ERROR_HINT="  executor 無法寫入強制輸出檔：${STEP_OUTPUT_PATH}。請檢查目錄是否存在、owner/group、以及目前使用者是否有寫入權限。"
    append_workflow_log "${WORKFLOW_LOG}" "${AGENT_SKILL}" "step:${step_id} output:${STEP_OUTPUT_PATH} error:${ERROR_TYPE}" "失敗"
    bash "${TRACE_LOG}" append "Workflow-Exec" "step:${step_id} error_type:${ERROR_TYPE} output:${STEP_OUTPUT_PATH}" "失敗" >/dev/null 2>&1 || true
    printf "%s\n" "${ERROR_HINT}"
    SHOULD_HALT=1
  fi

  if [ "${SHOULD_HALT}" -eq 0 ]; then
    materialize_handoff_summary "${STEP_OUTPUT_PATH}" "${STEP_HANDOFF_PATH}" || {
      append_workflow_log "${WORKFLOW_LOG}" "${AGENT_SKILL}" "step:${step_id} handoff:${STEP_HANDOFF_PATH} error:write_failed" "失敗"
    }
  fi

  if [ "${SHOULD_HALT}" -eq 1 ]; then
    :
  elif output_has_failure_result_marker "${STEP_OUTPUT_PATH}"; then
    STEP_STATUS="reported_failure"
    FINAL_STEP_STATE="hard_fail"
    step_status "fail" "${step_id}" "${DURATION}"
    FAILED=$((FAILED + 1))
    ERROR_TYPE="artifact_reported_failure"
    ERROR_HINT="  step stdout/artifact 回報 blocked 或 failed 結果，executor 已判定為 hard_fail，避免只產文件卻被標記成功。"
    bash "${TRACE_LOG}" append "Workflow-Exec" "step:${step_id} error_type:${ERROR_TYPE} capability:${capability} cli:${effective_cli}" "失敗" >/dev/null 2>&1 || true
    append_workflow_log "${WORKFLOW_LOG}" "${AGENT_SKILL}" "step:${step_id} duration:${DURATION}s error:${ERROR_TYPE}" "失敗"
    printf "%s\n" "${ERROR_HINT}"
    SHOULD_HALT=1
  elif [ -n "${STOP_REASON}" ]; then
    STEP_STATUS="${STOP_REASON}"
    FINAL_STEP_STATE="$(printf '%s' "${STOP_REASON}" | tr '[:upper:]' '[:lower:]')"
    step_status "stop" "${step_id}" "${DURATION}"
    FAILED=$((FAILED + 1))
    case "${STOP_REASON}" in
      TIMEOUT)
        ERROR_TYPE="timeout"
        ERROR_HINT="  step 超過硬性執行上限 ${effective_timeout}s，executor 已自動中止。可在 workflow step 設定 timeout_seconds，或用 CAP_WORKFLOW_STEP_TIMEOUT_SECONDS 覆寫預設值。"
        ;;
      STALL)
        ERROR_TYPE="stall"
        ERROR_HINT="  step 連續 ${effective_stall}s 沒有新增輸出，且 stall_action=kill，executor 已自動中止。可在 workflow step 設定 stall_seconds/stall_action，或用 CAP_WORKFLOW_STEP_STALL_SECONDS、CAP_WORKFLOW_STALL_ACTION 覆寫預設值。"
        ;;
    esac
    bash "${TRACE_LOG}" append "Workflow-Exec" "step:${step_id} error_type:${ERROR_TYPE} capability:${capability} cli:${effective_cli}" "失敗" >/dev/null 2>&1 || true
    append_workflow_log "${WORKFLOW_LOG}" "${AGENT_SKILL}" "step:${step_id} duration:${DURATION}s stop_reason:${STOP_REASON}" "失敗"
    if [ -n "${output}" ]; then
      echo "${output}" | tail -3 | while IFS= read -r line; do
        printf "  ${RED}│ %s${RESET}\n" "${line}"
      done
    fi
    printf "%s\n" "${ERROR_HINT}"
    SHOULD_HALT=1
  elif [ "${executor:-ai}" = "shell" ] && [ "${exit_code}" -eq 10 ]; then
    STEP_STATUS="no_changes"
    FINAL_STEP_STATE="validated"
    step_status "ok" "${step_id}" "${DURATION}"
    COMPLETED=$((COMPLETED + 1))
    bash "${TRACE_LOG}" append "Workflow-Exec" "step:${step_id} capability:${capability} executor:shell result:no_changes" "成功" >/dev/null 2>&1 || true
    append_workflow_log "${WORKFLOW_LOG}" "${AGENT_SKILL}" "step:${step_id} duration:${DURATION}s output:${STEP_OUTPUT_PATH} source:${OUTPUT_SOURCE} result:no_changes" "成功"
  elif [ "${exit_code}" -eq 0 ]; then
    if [ "${OUTPUT_SOURCE}" = "empty_capture" ]; then
      STEP_STATUS="missing_output"
      FINAL_STEP_STATE="hard_fail"
      step_status "fail" "${step_id}" "${DURATION}"
      FAILED=$((FAILED + 1))
      ERROR_TYPE="output_validation_failed"
      ERROR_HINT="  step exit 0，但沒有產出可用內容；executor 已判定為 hard_fail，避免下游繼續消耗 token。"
      bash "${TRACE_LOG}" append "Workflow-Exec" "step:${step_id} error_type:${ERROR_TYPE} capability:${capability} cli:${effective_cli}" "失敗" >/dev/null 2>&1 || true
      append_workflow_log "${WORKFLOW_LOG}" "${AGENT_SKILL}" "step:${step_id} duration:${DURATION}s error:${ERROR_TYPE}" "失敗"
      printf "%s\n" "${ERROR_HINT}"
      SHOULD_HALT=1
    else
      STEP_STATUS="ok"
      FINAL_STEP_STATE="validated"
      step_status "ok" "${step_id}" "${DURATION}"
      COMPLETED=$((COMPLETED + 1))
      bash "${TRACE_LOG}" append "Workflow-Exec" "step:${step_id} capability:${capability} agent:${agent_alias} cli:${effective_cli}" "成功" >/dev/null 2>&1 || true
      append_workflow_log "${WORKFLOW_LOG}" "${AGENT_SKILL}" "step:${step_id} duration:${DURATION}s output:${STEP_OUTPUT_PATH} source:${OUTPUT_SOURCE}" "成功"
    fi
  else
    STEP_STATUS="failed"
    FINAL_STEP_STATE="hard_fail"
    step_status "fail" "${step_id}" "${DURATION}"
    FAILED=$((FAILED + 1))

    # ── Error classification ──
    ERROR_TYPE="unknown"
    ERROR_HINT=""
    output_lower="$(echo "${output}" | tr '[:upper:]' '[:lower:]')"

    if [ "${executor:-ai}" = "shell" ]; then
      ERROR_TYPE="$(shell_exit_condition "${exit_code}")"
      case "${exit_code}" in
        20|21|40)
          ERROR_HINT="  shell step 回報 ${ERROR_TYPE}，但 workflow 未允許此條件走 AI fallback，或 fallback 執行後仍失敗。"
          ;;
        30)
          ERROR_HINT="  shell step 因 policy_blocked 停止。只有 workflow 明確允許 policy_blocked fallback 時才會交給 AI。"
          ;;
        50)
          ERROR_HINT="  shell step 偵測到 sensitive_file_risk，executor 已強制 halt，不會交給 AI fallback。"
          ;;
      esac
    # Auth / login errors
    elif echo "${output_lower}" | grep -qE 'not logged in|not authenticated|unauthorized|authentication required|login required|sign in|no api key|invalid.*api.?key|ANTHROPIC_API_KEY|OPENAI_API_KEY'; then
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
    append_workflow_log "${WORKFLOW_LOG}" "${AGENT_SKILL}" "step:${step_id} duration:${DURATION}s error:${ERROR_TYPE}" "失敗"

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
      SHOULD_HALT=1
    fi
  fi

  register_step_runtime_state \
    "${PLAN_JSON}" \
    "${RUNTIME_STATE_JSON}" \
    "${step_id}" \
    "${FINAL_STEP_STATE}" \
    "$([ "${FINAL_STEP_STATE}" = "blocked" ] && printf '%s' 'missing_input_artifact')" \
    "${OUTPUT_SOURCE:-}" \
    "${STEP_OUTPUT_PATH}" \
    "${STEP_HANDOFF_PATH}"

  SESSION_LIFECYCLE="$(session_lifecycle_for_state "${FINAL_STEP_STATE}")"
  SESSION_RESULT="$(session_result_for_state "${FINAL_STEP_STATE}")"
  SESSION_FAILURE_REASON=""
  if [ "${SESSION_RESULT}" != "success" ]; then
    SESSION_FAILURE_REASON="${STEP_STATUS}"
  fi
  register_agent_session \
    "${SESSION_ID}" \
    "${step_id}" \
    "${capability}" \
    "${agent_alias}" \
    "${prompt_file}" \
    "${effective_cli}" \
    "${effective_executor}" \
    "${SESSION_LIFECYCLE}" \
    "${SESSION_RESULT}" \
    "${input_mode:-summary}" \
    "${STEP_OUTPUT_PATH}" \
    "${STEP_HANDOFF_PATH}" \
    "${SESSION_FAILURE_REASON}" \
    "${DURATION}"

  {
    printf '\n### %s\n\n' "${step_id}"
    printf -- '- phase: %s\n' "${phase_num}"
    printf -- '- capability: %s\n' "${capability}"
    printf -- '- agent: %s\n' "${agent_alias}"
    printf -- '- cli: %s\n' "${effective_cli}"
    printf -- '- status: %s\n' "${STEP_STATUS}"
    printf -- '- duration_seconds: %s\n' "${DURATION}"
    printf -- '- output: %s\n' "${STEP_OUTPUT_PATH}"
    printf -- '- handoff: %s\n' "${STEP_HANDOFF_PATH}"
    printf -- '- output_source: %s\n' "${OUTPUT_SOURCE:-unknown}"
    printf -- '- input_mode: %s\n' "${input_mode:-summary}"
    printf -- '- output_tier: %s\n' "${output_tier:-planning_artifact}"
  } >> "${ARTIFACT_INDEX}"

  {
    printf '\n### %s\n\n' "${step_id}"
    printf -- '- status: %s\n' "${STEP_STATUS}"
    printf -- '- duration_seconds: %s\n' "${DURATION}"
    printf -- '- output: %s\n' "${STEP_OUTPUT_PATH}"
    printf -- '- handoff: %s\n' "${STEP_HANDOFF_PATH}"
    printf -- '- output_source: %s\n' "${OUTPUT_SOURCE:-unknown}"
    printf -- '- input_mode: %s\n' "${input_mode:-summary}"
    printf -- '- output_tier: %s\n' "${output_tier:-planning_artifact}"
  } >> "${RUN_SUMMARY}"

  if [ "${SHOULD_HALT}" -eq 1 ]; then
    break
  fi

done 3<<< "${STEP_LINES}"

TOTAL_DURATION="$(( $(date '+%s') - START_TOTAL ))"

FINAL_STATE="completed"
FINAL_RESULT="success"
EXIT_CODE=0

if [ "${FAILED}" -gt 0 ]; then
  FINAL_STATE="failed"
  FINAL_RESULT="step_failed"
  EXIT_CODE=1
fi

write_file_or_fail "${RESULT_REPORT}" "$(cat <<EOF
# Workflow Result

- workflow_id: ${WORKFLOW_ID}
- workflow_name: ${WORKFLOW_NAME}
- run_id: ${RUN_LABEL}
- final_state: ${FINAL_STATE}
- final_result: ${FINAL_RESULT}
- total_duration_seconds: ${TOTAL_DURATION}
- completed: ${COMPLETED}
- failed: ${FAILED}
- skipped: ${SKIPPED}

## Artifacts

- artifact_index: ${ARTIFACT_INDEX}
- run_summary: ${RUN_SUMMARY}
- runtime_state: ${RUNTIME_STATE_JSON}
- agent_sessions: ${AGENT_SESSIONS_JSON}
- workflow_log: ${WORKFLOW_LOG}

## Notes

This result report is generated by CAP workflow executor as the human-readable run archive.
EOF
)" || true

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  ${BOLD}Done${RESET} in %ss  |  ✓ %s  ✗ %s  ⊘ %s\n" "${TOTAL_DURATION}" "${COMPLETED}" "${FAILED}" "${SKIPPED}"
echo ""
CAP_SHORT="~/.cap"
RUN_SHORT="${WORKFLOW_OUTPUT_DIR/#${HOME}\/.cap/${CAP_SHORT}}"
printf "  ${DIM}base${RESET} %s/\n" "${RUN_SHORT}"
# Collect unique filenames, skip duplicates
_LISTED=""
for f in "${ARTIFACT_INDEX}" "${WORKFLOW_LOG}" "${RUN_SUMMARY}" "${RESULT_REPORT}" "${AGENT_SESSIONS_JSON}" "${WORKFLOW_OUTPUT_DIR}/"*-*.md "${WORKFLOW_OUTPUT_DIR}/"*-*.raw.log "${RUNTIME_STATE_JSON}"; do
  [ -f "${f}" ] || continue
  _FNAME="$(basename "${f}")"
  case "${_LISTED}" in *"|${_FNAME}|"*) continue ;; esac
  _LISTED="${_LISTED}|${_FNAME}|"
  printf "    %s\n" "${_FNAME}"
done
echo ""

append_workflow_log "${WORKFLOW_LOG}" "workflow" "workflow:${WORKFLOW_ID} duration:${TOTAL_DURATION}s completed:${COMPLETED} failed:${FAILED} skipped:${SKIPPED}" "${FINAL_RESULT}"

{
  printf '\n## Finished\n\n'
  printf -- '- finished_at: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf -- '- total_duration_seconds: %s\n' "${TOTAL_DURATION}"
  printf -- '- completed: %s\n' "${COMPLETED}"
  printf -- '- failed: %s\n' "${FAILED}"
  printf -- '- skipped: %s\n' "${SKIPPED}"
} >> "${RUN_SUMMARY}"

if [ -n "${RUN_ID}" ]; then
  bash "${SCRIPT_DIR}/cap-workflow.sh" update-run-status "${RUN_ID}" "${FINAL_STATE}" "${FINAL_RESULT}" >/dev/null 2>&1 || true
fi

exit "${EXIT_CODE}"
