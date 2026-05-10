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
SKILLS_DIR="${CAP_ROOT}/agent-skills"
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

# P7 Phase B — workflow-result.json producer + result.md renderer.
# Sourced helper exposes ``cap_result_emit``; see scripts/cap-result-emit.sh.
# The legacy hardcoded ``result.md`` template below is kept as a fallback
# when the builder errors or schema validation fails.
# shellcheck source=cap-result-emit.sh
. "${SCRIPT_DIR}/cap-result-emit.sh"

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

  mkdir -p "${cache_dir}" "$(dirname "${fallback}")" >/dev/null 2>&1 || true

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
  echo "${cli} CLI not found. Foreground workflow execution requires at least one AI CLI." >&2
  echo "" >&2
  case "${cli}" in
    claude)
      echo "  Install Claude Code:" >&2
      echo "    npm install -g @anthropic-ai/claude-code" >&2
      echo "" >&2
      echo "  Or use Codex instead:" >&2
      echo "    cap workflow run --cli codex <workflow> \"<prompt>\"" >&2
      ;;
    codex)
      echo "  Install Codex:" >&2
      echo "    npm install -g @openai/codex" >&2
      echo "" >&2
      echo "  Or use Claude instead:" >&2
      echo "    cap workflow run --cli claude <workflow> \"<prompt>\"" >&2
      ;;
  esac
  echo "" >&2
  return 1
}

# ── CLI command builder ──

# Layer 3 guard: fail loud if the requested provider CLI is missing on PATH.
# CAP does not install or login providers (see cap-provider.sh / docs/cap
# Provider Isolation). When a workflow step asks for an AI executor we either
# can dispatch to the CLI as-is, or we stop with a message that points the
# user at the upstream installer — no silent fallback to another provider.
ensure_provider_cli() {
  local cli="$1"
  if command -v "${cli}" >/dev/null 2>&1; then
    return 0
  fi
  echo "" >&2
  echo "✗ provider CLI not on PATH: ${cli}" >&2
  echo "  CAP does not install or authenticate providers; please install the matching CLI and retry." >&2
  case "${cli}" in
    claude)
      echo "    Claude Code: https://docs.claude.com/claude-code" >&2
      ;;
    codex)
      echo "    Codex CLI:   https://developers.openai.com/codex" >&2
      ;;
  esac
  echo "  You can also run 'cap provider doctor' to inspect current provider status." >&2
  return 1
}

run_step_claude() {
  local prompt="$1"
  local write_dir="${2:-}"
  ensure_provider_cli claude || return 1
  local args=(-p)
  # v0.26.1 Round 2 — AI write contract. When the per-step landing dir
  # is set, give claude the tool whitelist + permission mode it needs
  # to actually write code there. Read remains unchanged (claude can
  # read absolute paths under the default permission mode); the new
  # flags only widen Edit / Write to the landing dir.
  #
  # ``--add-dir`` extends the directories tools can touch beyond cwd.
  # ``--permission-mode acceptEdits`` auto-accepts file edits so the
  # headless run does not stall on permission dialogs. The
  # ``--allowed-tools`` list is intentionally narrow: Read / Edit /
  # Write / Bash / Glob / Grep is the minimum needed for an
  # implementation step to scaffold a project, run a build, and emit
  # markdown to stdout. No WebFetch / WebSearch / Task spawning so
  # the AI cannot escape the sandbox via a sub-agent.
  if [ -n "${write_dir}" ]; then
    args+=(
      --add-dir "${write_dir}"
      --permission-mode acceptEdits
      --allowed-tools "Read,Edit,Write,Bash,Glob,Grep"
    )
  fi
  claude "${args[@]}" "${prompt}" 2>&1
}

# Codex stdout 包含 banner + prompt echo + response，需要清洗。
# 策略：找到 Codex 的 response 起始標記（`assistant` 或第一個非 banner 行），
# 剝離之前的所有內容。
strip_codex_preamble() {
  awk '
    BEGIN { found = 0; buf = "" }
    # Codex CLI 版本差異：有些輸出以 assistant 為回覆標記，
    # 有些輸出以 codex 為回覆標記，且會夾帶 user/exec transcript。
    # 取最後一段 assistant/codex 回覆，避免 tool transcript 混入 artifact。
    /^(assistant|codex)$/ { found = 1; buf = ""; next }
    found == 1 { buf = buf $0 ORS }
    END {
      if (found == 0) exit 1
      printf "%s", buf
    }
  '
}

run_step_codex() {
  local prompt="$1"
  local write_dir="${2:-}"
  local raw
  local exit_code
  local last_message_file
  local args=(exec)
  ensure_provider_cli codex || return 1
  if [ "${CAP_CODEX_SKIP_GIT_REPO_CHECK:-1}" != "0" ]; then
    args+=(--skip-git-repo-check)
  fi
  # v0.26.1 Round 2 — AI write contract for codex. ``workspace-write``
  # sandbox lets the agent write files under its working directory;
  # ``--cd <write_dir>`` pins that working dir at the per-step landing
  # path so writes land where promote / impl_audit can later inspect
  # them. Reads from absolute paths outside the sandbox still work
  # (workspace-write only restricts WRITES), so the agent can pull
  # context from project_root + the run dir without further flags.
  if [ -n "${write_dir}" ]; then
    args+=(--sandbox workspace-write --cd "${write_dir}")
  fi
  # 用 --output-last-message 取單一 assistant 回覆，繞過 Codex CLI 在 stdout
  # 內出現多輪 turn / `tokens used` banner / 重複輸出（cf. v0.23 dogfood
  # 2026-05-08：strip_codex_preamble 的 awk pattern `^(assistant|codex)$`
  # 在同一個 assistant 標題下無法切分後續重複的 fence pair，導致
  # validate_constitution 偵測到 multiple_explicit_fences 而 halt）。
  last_message_file="$(mktemp -t cap-codex-last.XXXXXX)"
  args+=(-o "${last_message_file}")
  set +e
  raw="$(codex "${args[@]}" "${prompt}" 2>&1)"
  exit_code=$?
  set -e
  if [ -s "${last_message_file}" ]; then
    cat "${last_message_file}"
    rm -f "${last_message_file}"
  else
    rm -f "${last_message_file}"
    # Fallback：若 Codex CLI 不支援或未寫入 last-message file，
    # 沿用原本的 stdout 剝離策略
    printf '%s\n' "${raw}" | strip_codex_preamble 2>/dev/null || printf '%s\n' "${raw}"
  fi
  return "${exit_code}"
}

run_step() {
  local cli="$1"
  local prompt="$2"
  # v0.26.1 Round 2 — optional third arg ``write_dir`` carries the
  # per-step landing directory. Empty means no write contract for
  # this step (legacy behaviour: provider runs without --add-dir /
  # --cd, no write tools enabled). Code-emitting steps must pass a
  # non-empty path — the caller (main loop) prepares
  # ``<run_dir>/code/<step_id>/`` before invoking run_step.
  local write_dir="${3:-}"
  case "${cli}" in
    claude) run_step_claude "${prompt}" "${write_dir}" ;;
    codex)  run_step_codex "${prompt}" "${write_dir}" ;;
    *)
      echo "Unsupported CLI: ${cli}" >&2
      return 1
      ;;
  esac
}

resolve_shell_script_path() {
  local script_ref="$1"

  case "${script_ref}" in
    scripts/workflows/*.sh) ;;
    *)
      echo "shell step script must live under scripts/workflows/*.sh: ${script_ref}" >&2
      return 1
      ;;
  esac

  local script_path="${CAP_ROOT}/${script_ref}"
  if [ ! -f "${script_path}" ]; then
    echo "shell step script not found: ${script_ref}" >&2
    return 1
  fi
  if [ ! -x "${script_path}" ]; then
    echo "shell step script is not executable: ${script_ref}" >&2
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
  local constitution_overwrite="0"

  case "${step_id}" in
    persist_reconciled_constitution) constitution_overwrite="1" ;;
  esac

  script_path="$(resolve_shell_script_path "${script_ref}")" || return 30
  CAP_WORKFLOW_STEP_ID="${step_id}" \
  CAP_WORKFLOW_OUTPUT_PATH="${output_path}" \
  CAP_WORKFLOW_ARTIFACT_INDEX="${artifact_index}" \
  CAP_WORKFLOW_INPUT_CONTEXT="${input_context}" \
  CAP_WORKFLOW_CONTRACT_CONTEXT="${contract_context}" \
  CAP_WORKFLOW_USER_PROMPT="${user_prompt}" \
  CAP_PROJECT_CONSTITUTION_ADDENDUM_PATH="${CAP_PROJECT_CONSTITUTION_ADDENDUM_PATH:-}" \
  CAP_CONSTITUTION_OVERWRITE="${constitution_overwrite}" \
  CAP_WORKFLOW_REQUESTED_MODE="${REQUESTED_MODE}" \
  CAP_WORKFLOW_SELECTED_MODE="${SELECTED_MODE}" \
  CAP_WORKFLOW_REQUESTED_STRATEGY="${REQUESTED_STRATEGY}" \
  CAP_WORKFLOW_SELECTED_STRATEGY="${SELECTED_STRATEGY}" \
  CAP_PROJECT_ROOT="${PROJECT_ROOT}" \
  CAP_PROJECT_ID="${CAP_PROJECT_ID:-$(bash "${PATH_HELPER}" get project_id 2>/dev/null || true)}" \
  CAP_HOME="${CAP_HOME:-$(bash "${PATH_HELPER}" get cap_home 2>/dev/null || true)}" \
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
    41) printf '%s\n' "schema_validation_failed" ;;
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
    project_constitution)
      cat <<'EOF'
請使用以下固定章節標題依序輸出，讓 workflow 可以從串流標題推斷段內進度：
## 任務理解
## 執行重點
## 產出內容
## 交接摘要

Fence 一次到位鐵律（最終指令，覆蓋 prompt 中段的所有其他章節要求；違反會被 validate_constitution exit 41 halt，無 AI fallback）：
- 整份 stdout 只能出現一對 <<<CONSTITUTION_JSON_BEGIN>>>/<<<CONSTITUTION_JSON_END>>> fence。
- 動筆前先決定 JSON 寫在 `## 產出內容` 章節內；從 `## 任務理解` 一氣呵成寫到 `## 交接摘要`，中途不要回頭重寫。
- 嚴禁先以自由敘事 + fence pair 完成回答，再為了補 4 個固定標題格式整份重寫，產生 fence pair #2。
- 若已寫完 fence pair，後續章節若需提及 JSON 內容，請改用自由文字描述（例如：「JSON 已包含 schema_version、constraints、stop_conditions、binding_policy」），嚴禁再次以 fence 包覆 JSON 重貼一遍。
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

  printf "${RED}✗ Failed to create %s: %s${RESET}\n" "${label}" "${dir}" >&2
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

  printf "${RED}✗ Failed to write file: %s${RESET}\n" "${path}" >&2
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

# Record a step that was blocked before execution started (input gating,
# unresolved binding, unsupported executor, missing agent, invalid shell
# script, detached HEAD). Without this, blocked steps leave no trace in
# workflow.log or the run-summary `## Steps` section, and governance layers
# (provider-parity-check, watcher, post-mortem) read a partial picture.
# Inherits agent_alias / prompt_file / script_ref from the surrounding
# while-loop scope; falls back to safe placeholders when those are unset.
record_blocked_step() {
  local log_path="$1"
  local run_summary="$2"
  local phase_num="$3"
  local step_id="$4"
  local capability="$5"
  local blocked_reason="$6"
  local extra_detail="${7:-}"
  local agent_skill="${agent_alias:-shell}:${prompt_file:-${script_ref:-builtin}}"
  local detail="phase:${phase_num} step:${step_id} capability:${capability} blocked_reason:${blocked_reason}"
  if [ -n "${extra_detail}" ]; then
    detail="${detail} ${extra_detail}"
  fi
  append_workflow_log "${log_path}" "${agent_skill}" "${detail}" "blocked"
  {
    printf '\n### %s\n\n' "${step_id}"
    printf -- '- phase: %s\n' "${phase_num}"
    printf -- '- status: blocked\n'
    printf -- '- blocked_reason: %s\n' "${blocked_reason}"
    if [ -n "${extra_detail}" ]; then
      printf -- '- detail: %s\n' "${extra_detail}"
    fi
  } >> "${run_summary}"
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

# resolve_latest_ticket — Locate the highest-seq Type C handoff ticket
# for ${step_id} under ${handoffs_dir}. Mirrors the seq scheme written
# by scripts/workflows/emit-handoff-ticket.sh (base file
# `<step>.ticket.json`; reruns append `-<seq>.ticket.json` per
# supervisor protocol §3.6 rule 2). Stdout is the absolute path of
# the latest ticket, or empty when no ticket exists for the step
# (used by the P6 #3 opt-in pre-dispatch gate to no-op cleanly).
resolve_latest_ticket() {
  local handoffs_dir="$1"
  local step_id="$2"
  [ -z "${handoffs_dir}" ] && return 0
  [ ! -d "${handoffs_dir}" ] && return 0
  local base="${handoffs_dir}/${step_id}.ticket.json"
  local latest=""
  [ -f "${base}" ] && latest="${base}"
  local candidate seq highest=1
  shopt -s nullglob
  for candidate in "${handoffs_dir}/${step_id}"-*.ticket.json; do
    [ -f "${candidate}" ] || continue
    seq="${candidate##*-}"
    seq="${seq%.ticket.json}"
    case "${seq}" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "${seq}" -gt "${highest}" ]; then
      highest="${seq}"
      latest="${candidate}"
    fi
  done
  shopt -u nullglob
  [ -n "${latest}" ] && printf '%s\n' "${latest}"
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
  # P5 #6 wiring: optional prompt snapshot metadata. When unset / empty
  # the corresponding --flag is omitted so the call stays byte-equivalent
  # to the legacy 14-positional invocation; older callers do not need to
  # change. Populated by the prompt build path below so production runs
  # contribute prompt_hash / size to the agent-sessions ledger and
  # `cap session analyze` can surface real largest_prompts /
  # duplicate_prompts hot lists.
  local prompt_hash="${15:-}"
  local prompt_snapshot_path="${16:-}"
  local prompt_size_bytes="${17:-}"

  local extra=()
  [ -n "${prompt_hash}" ] && extra+=(--prompt-hash "${prompt_hash}")
  [ -n "${prompt_snapshot_path}" ] && extra+=(--prompt-snapshot-path "${prompt_snapshot_path}")
  [ -n "${prompt_size_bytes}" ] && extra+=(--prompt-size-bytes "${prompt_size_bytes}")

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
    "${duration_seconds}" \
    "${extra[@]+"${extra[@]}"}" >/dev/null 2>&1 || true
}

# P5 #6 production wiring: compute SHA-256, write content-addressed
# snapshot, echo "hash|path|size" so the caller can fan into ledger
# fields. Mirrors engine.agent_session_runner._write_prompt_snapshot
# layout — `<base_dir>/prompts/<hash[:2]>/<hash>.txt` — so Python and
# shell paths share the same on-disk dedupe set per workflow run.
# Idempotent: existing target file is left untouched. Returns 1 (and
# emits nothing) when no sha256 tool is available, so the caller can
# skip the metadata fields rather than crash.
write_prompt_snapshot() {
  local prompt="$1"
  local base_dir="$2"
  local hash size prompts_dir target

  if command -v shasum >/dev/null 2>&1; then
    hash="$(printf '%s' "${prompt}" | shasum -a 256 | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    hash="$(printf '%s' "${prompt}" | sha256sum | awk '{print $1}')"
  else
    return 1
  fi

  size="$(printf '%s' "${prompt}" | wc -c | tr -d ' ')"
  prompts_dir="${base_dir}/prompts/${hash:0:2}"
  target="${prompts_dir}/${hash}.txt"

  mkdir -p "${prompts_dir}" 2>/dev/null || return 1
  if [ ! -f "${target}" ]; then
    printf '%s' "${prompt}" > "${target}" 2>/dev/null || return 1
  fi

  printf '%s|%s|%s\n' "${hash}" "${target}" "${size}"
}

# Parse `reason:` / `detail:` lines emitted by shell executors via
# fail_with() (e.g. persist-task-constitution.sh, validate-constitution.sh)
# from the step's artifact and return a compact one-line summary suitable
# for embedding in workflow.log entries and the agent-sessions ledger
# failure_reason field.
#
# Output shape (empty when neither is present):
#   reason=<reason>;detail=<detail1>|<detail2>
#
# Goal: make `cap session inspect <id>` and `cap session analyze` show
# the actual failure category (e.g. MISSING_REQUIRED:goal,success_criteria
# or PARSE_ERROR:Extra data ...) instead of a bare "schema_validation_failed"
# / generic "failed" string. No execution behaviour change — pure
# observability lift parsed from the artifact the step itself wrote.
extract_step_failure_detail() {
  local artifact="$1"
  local reason details
  [ -f "${artifact}" ] || { printf ''; return; }
  reason="$(awk '/^reason:/ {sub(/^reason: */, ""); print; exit}' "${artifact}" 2>/dev/null)"
  details="$(awk '/^detail:/ {sub(/^detail: */, ""); print}' "${artifact}" 2>/dev/null | tr '\n' '|' | sed 's/|$//')"
  if [ -n "${reason}" ] && [ -n "${details}" ]; then
    printf '%s' "reason=${reason};detail=${details}"
  elif [ -n "${reason}" ]; then
    printf '%s' "reason=${reason}"
  elif [ -n "${details}" ]; then
    printf '%s' "detail=${details}"
  fi
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
  local structured_sections attached_section write_section
  structured_sections="$(structured_sections_for_capability "${capability}")"
  attached_section="$(build_attached_skills_section "${step_id}")"
  write_section="$(build_write_contract_section "${capability}")"

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

${write_section}${attached_section}${structured_sections}

完成後，請輸出交接摘要（agent_id, task_summary, output_paths, result）。
EOF
}

# v0.26.1 Round 2 — render the AI Write Contract section into AI step
# prompts. For code-emitting capabilities (backend / frontend / qa /
# devops), instructs the agent to land code under
# ${CAP_WORKFLOW_WRITE_DIR} and reminds that the workflow runtime now
# enforces non-empty landing dir for these capabilities. For
# markdown-only capabilities the section is empty (no need to clutter
# the prompt with write contract details that don't apply).
build_write_contract_section() {
  local capability="$1"
  local emits_code
  emits_code="$("${PYTHON_BIN}" "${STEP_PY}" capability-emits-code "${capability}" 2>/dev/null)"
  if [ "${emits_code}" != "true" ]; then
    return 0
  fi
  if [ -z "${CAP_WORKFLOW_WRITE_DIR:-}" ]; then
    return 0
  fi
  cat <<EOF
AI Write Contract (v0.26.1):
本步驟的 capability「${capability}」屬於 code-emitting 類型，**必須**在 stdout 之外把實際程式碼 / Dockerfile / 測試檔等檔案寫入下列指定 landing dir：

  ${CAP_WORKFLOW_WRITE_DIR}

該 dir 已由 workflow executor 預先建立並設為可寫；provider CLI 已加上對應旗標（claude --add-dir / codex workspace-write --cd），不需要你自己處理權限。

重要規則：
1. 不要寫到 project_root（你目前的 cwd 不是 project_root；project_root 路徑只用於 read 上游規格）。
2. 寫到 landing dir 之後，請在交接摘要的 output_paths 列出所有產出檔案（相對於 landing dir 或絕對路徑皆可）。
3. workflow runtime 在你回 \`result: success\` 時會驗證 landing dir 至少含一個檔案；若 success 但 dir 為空，會被 demote 為 \`ai_success_no_artifacts\` hard fail（這是 v0.26.1 R2 強制契約，避免 v0.25.x 時代「step PASS 但沒有產出」的假性成功）。
4. 若你判斷無法落地檔案（read-only / 上游缺漏），照舊回 \`result: blocked\` 或 \`result: needs_data\`，runtime 會正確 halt（v0.26.0 R1 已生效）。

EOF
}

# Phase 5 — render Attached Advisory Skills section for an AI step.
# Pulls (prompt_file, skill_id, attach_reason) tuples from
# step_runtime.py attached-prompts and emits a Markdown-style block
# the role prompt can read alongside its own role file. Empty stdout
# (and trailing blank line) when the step has no attachments — the
# build_step_prompt template still renders cleanly because the empty
# string concatenates inertly into the "${attached_section}${structured_sections}"
# slot.
#
# Why pre-rendered prompt path references (vs. inlining file
# contents): the role prompt already follows the
# "請嚴格依照 ${SKILLS_DIR}/${prompt_file}" pattern. Advisory skills
# inherit the same convention so the AI provider can read both
# files via its filesystem tools; the section names them, the
# provider mounts them. This keeps the assembled prompt small and
# avoids duplicating skill content into every step's invocation
# (which would also break ``cap session analyze``'s prompt-hash
# duplicate detection).
build_attached_skills_section() {
  local step_id="$1"
  local records
  records="$("${PYTHON_BIN}" "${STEP_PY}" attached-prompts "${PLAN_JSON}" "${step_id}" 2>/dev/null)"
  if [ -z "${records}" ]; then
    return 0
  fi

  printf '附加規範指引 (Attached Advisory Skills):\n'
  printf '本步驟在原本角色規範之外，必須額外遵守以下 advisory skill 中定義的守則。\n'
  printf '若 advisory skill 與角色規範產生衝突，以角色規範與專案 constitution 為準。\n\n'
  while IFS=$'\t' read -r prompt_file_attach skill_id_attach attach_reason; do
    [ -z "${prompt_file_attach}" ] && continue
    printf -- '- skill_id: %s\n' "${skill_id_attach}"
    printf -- '  prompt_file: %s/%s\n' "${SKILLS_DIR}" "${prompt_file_attach}"
    printf -- '  attach_reason: %s\n' "${attach_reason}"
  done <<< "${records}"
  printf '\n'
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
HANDOFFS_DIR="$(bash "${PATH_HELPER}" get handoff_dir 2>/dev/null || true)"
HANDOFF_SCHEMA_PATH="${CAP_ROOT}/schemas/handoff-ticket.schema.yaml"
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

# A0 #4: stamp the new agent-sessions ledger with the builtin
# agent-skills baseline (cap_version + git_commit + dir_hash + per-file
# hashes) so replay / diff can later identify which baseline this run
# observed. Idempotent — re-runs that hit an already-stamped envelope
# are a no-op. Best-effort: a failure (e.g., git unavailable, sandbox
# without manifest) is logged to workflow.log but does not halt the
# run, matching the rest of the snapshot-attach contract that runs
# without baseline are still executable. SSOT:
# policies/agent-skills-baseline.md §7.
SNAPSHOT_PY="${CAP_ROOT}/engine/agent_skills_snapshot.py"
if [ -f "${SNAPSHOT_PY}" ]; then
  if ! "${PYTHON_BIN}" "${SNAPSHOT_PY}" attach "${AGENT_SESSIONS_JSON}" \
      >> "${WORKFLOW_LOG}" 2>&1; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')][workflow][warn] failed to attach agent_skills_baseline to ${AGENT_SESSIONS_JSON}; continuing without baseline" >> "${WORKFLOW_LOG}"
  fi
fi

# H2 #4: parallel attach for project layer skill snapshot. Captures
# <project_root>/.cap/skills.yaml + .cap/skills/* hashes so the H2
# verifier can later compute dual-axis drift (builtin + project).
# Same best-effort contract as A0 #4 — failure warns but never halts.
# CAP_PROJECT_ROOT env var lets the snapshot module resolve the same
# project root cap-paths.sh resolved above. SSOT:
# docs/cap/H2-PROJECT-SKILL-DRIFT-DESIGN.md §7.1.
PROJECT_SKILLS_PY="${CAP_ROOT}/engine/project_skills_snapshot.py"
if [ -f "${PROJECT_SKILLS_PY}" ]; then
  if ! CAP_PROJECT_ROOT="${PROJECT_ROOT}" "${PYTHON_BIN}" "${PROJECT_SKILLS_PY}" attach "${AGENT_SESSIONS_JSON}" \
      >> "${WORKFLOW_LOG}" 2>&1; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')][workflow][warn] failed to attach project_skill_baseline to ${AGENT_SESSIONS_JSON}; continuing without project baseline" >> "${WORKFLOW_LOG}"
  fi
fi

# H2 #4: derive a compact binding_summary from the bound plan and
# attach it to the envelope so the verifier can identify which
# skill_ids the run actually used (and which layer they came from).
# binding_summary contains step_id / selected_skill_id / skill_source
# per step — extracted from PLAN_JSON without re-running bind. Same
# best-effort contract.
BINDING_SUMMARY_PY="${CAP_ROOT}/engine/binding_summary.py"
if [ -f "${BINDING_SUMMARY_PY}" ]; then
  PLAN_TMP="$(mktemp -t cap-plan.XXXXXX 2>/dev/null || mktemp 2>/dev/null)"
  if [ -n "${PLAN_TMP}" ]; then
    printf '%s' "${PLAN_JSON}" > "${PLAN_TMP}"
    if ! "${PYTHON_BIN}" "${BINDING_SUMMARY_PY}" attach "${AGENT_SESSIONS_JSON}" \
        --plan-path "${PLAN_TMP}" \
        >> "${WORKFLOW_LOG}" 2>&1; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')][workflow][warn] failed to attach binding_summary to ${AGENT_SESSIONS_JSON}; continuing without binding summary" >> "${WORKFLOW_LOG}"
    fi
    rm -f "${PLAN_TMP}"
  fi
fi

# H3 #4: attach three whole-file-hash baselines for the new replay
# verifier axes (workflow YAML / constitution / capability schema).
# Each follows the same best-effort contract as the H1+H2 attaches:
# failure logs a warn line and never halts the run. Per design memo
# §5 the attaches are intentionally minimal — single SHA-256 each —
# so combined runtime overhead stays well under 100ms.
WF_YAML_SNAPSHOT_PY="${CAP_ROOT}/engine/workflow_yaml_snapshot.py"
if [ -f "${WF_YAML_SNAPSHOT_PY}" ]; then
  # H4 #2: extract both workflow source path AND source_layer from
  # PLAN_JSON (binding.workflow_source.source_layer is populated by
  # P9 #4 layered resolver and threaded through bind_semantic_plan).
  # Without this fix the attached workflow_yaml_baseline records
  # source_layer=None even when the layered resolver knows the
  # answer — see H3 dogfood report and H4 design memo §5.
  WF_PLAN_META="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c "
import json, sys
try:
    plan = json.loads(sys.stdin.read())
    src_path = plan.get('source_path', '') or ''
    binding = plan.get('binding', {}) or {}
    ws = binding.get('workflow_source') or {}
    src_layer = ws.get('source_layer', '') or ''
    print(f'{src_path}|{src_layer}')
except Exception:
    print('|')
")"
  WF_SOURCE_PATH="${WF_PLAN_META%|*}"
  WF_SOURCE_LAYER="${WF_PLAN_META#*|}"
  if [ -n "${WF_SOURCE_PATH}" ] && [ -f "${WF_SOURCE_PATH}" ]; then
    WF_ATTACH_ARGS=(attach "${AGENT_SESSIONS_JSON}"
      --workflow-path "${WF_SOURCE_PATH}"
      --workflow-id "${WORKFLOW_ID}")
    if [ -n "${WF_SOURCE_LAYER}" ]; then
      WF_ATTACH_ARGS+=(--source-layer "${WF_SOURCE_LAYER}")
    fi
    if ! "${PYTHON_BIN}" "${WF_YAML_SNAPSHOT_PY}" "${WF_ATTACH_ARGS[@]}" \
        >> "${WORKFLOW_LOG}" 2>&1; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')][workflow][warn] failed to attach workflow_yaml_baseline to ${AGENT_SESSIONS_JSON}; continuing without workflow yaml baseline" >> "${WORKFLOW_LOG}"
    fi
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')][workflow][warn] workflow source_path empty or missing; skipping workflow_yaml_baseline attach" >> "${WORKFLOW_LOG}"
  fi
fi

CONSTITUTION_SNAPSHOT_PY="${CAP_ROOT}/engine/constitution_snapshot.py"
if [ -f "${CONSTITUTION_SNAPSHOT_PY}" ]; then
  if ! CAP_PROJECT_ROOT="${PROJECT_ROOT}" "${PYTHON_BIN}" "${CONSTITUTION_SNAPSHOT_PY}" attach "${AGENT_SESSIONS_JSON}" \
      >> "${WORKFLOW_LOG}" 2>&1; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')][workflow][warn] failed to attach constitution_baseline to ${AGENT_SESSIONS_JSON}; continuing without constitution baseline" >> "${WORKFLOW_LOG}"
  fi
fi

CAP_SCHEMA_SNAPSHOT_PY="${CAP_ROOT}/engine/capability_schema_snapshot.py"
if [ -f "${CAP_SCHEMA_SNAPSHOT_PY}" ]; then
  if ! "${PYTHON_BIN}" "${CAP_SCHEMA_SNAPSHOT_PY}" attach "${AGENT_SESSIONS_JSON}" \
      >> "${WORKFLOW_LOG}" 2>&1; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')][workflow][warn] failed to attach capability_schema_baseline to ${AGENT_SESSIONS_JSON}; continuing without capability schema baseline" >> "${WORKFLOW_LOG}"
  fi
fi

echo "  Output dir: ${WORKFLOW_OUTPUT_DIR}"

# Flatten phases into step lines:
# phase_num|total|step_ids|agents|step_id|capability|agent_alias|prompt_file|step_cli|inputs|optional|resolution_status|timeout_seconds|stall_seconds|stall_action|input_mode|output_tier|continue_reason|executor|script|fallback_executor|fallback_when|attached_count
# Phase 5 added the trailing attached_count field; consumers that
# only iterate the leading 22 fields keep working because the IFS
# read line below now binds the 23rd variable explicitly.
STEP_LINES="$("${PYTHON_BIN}" "${STEP_PY}" flatten-steps "${PLAN_JSON}")"

# ── P6 #8 step iteration: array + index pointer ──
# Replaces the prior `while ... <&3 ... done <<< STEP_LINES` stream
# loop so the runtime can rewind to a route_back_to_step target. The
# loop uses an "advance-first, then read" pattern: step_idx is
# incremented *before* the body executes, so existing `break` /
# `continue` calls keep their original semantics. route_back_to fires
# from a single hook at the central halt point (search for
# CAP_ENFORCE_ROUTE_BACK below) and overwrites step_idx + continue.
mapfile -t STEP_ARRAY <<< "${STEP_LINES}"

# ROUTE_BACK_PLAN_STEPS — comma-separated step ids fed to
# resolve-handoff-routing as `--plan-steps`, used by the resolver to
# reject route_back_to_step values that point outside the active
# plan (invalid_target).
ROUTE_BACK_PLAN_STEPS=""
for __step_line in "${STEP_ARRAY[@]}"; do
  __step_field="$(printf '%s' "${__step_line}" | cut -d'|' -f5)"
  [ -z "${__step_field}" ] && continue
  if [ -z "${ROUTE_BACK_PLAN_STEPS}" ]; then
    ROUTE_BACK_PLAN_STEPS="${__step_field}"
  else
    ROUTE_BACK_PLAN_STEPS="${ROUTE_BACK_PLAN_STEPS},${__step_field}"
  fi
done
unset __step_line __step_field

# VISIT_COUNTS — per-run visit counter consumed by the resolver as
# the `--visits` arg. Each step's count is incremented *on entry*;
# the resolver compares against the ticket's max_retries (default 1)
# so route_back_to_step: <self> cycles halt after one rerun.
declare -A VISIT_COUNTS

# ROUTE_HISTORY_FILE — append-only JSONL audit trail of route_back
# decisions (one line per resolver verdict). cap session inspect
# / cap analyze can later surface this; for now it is observability
# scaffolding for human review.
ROUTE_HISTORY_FILE="${WORKFLOW_OUTPUT_DIR}/route-history.jsonl"

# find_step_idx_in_array <step_id> — locate the index of the first
# STEP_ARRAY entry whose 5th pipe-delimited field matches step_id.
# Stdout: index (integer) on hit, empty on miss; rc 0 always.
find_step_idx_in_array() {
  local target="$1"
  local i sid
  for i in "${!STEP_ARRAY[@]}"; do
    sid="$(printf '%s' "${STEP_ARRAY[${i}]}" | cut -d'|' -f5)"
    if [ "${sid}" = "${target}" ]; then
      printf '%s' "${i}"
      return 0
    fi
  done
  return 0
}

# format_visit_counts — render the VISIT_COUNTS associative array
# as the comma-separated `step=count` form the resolver consumes.
format_visit_counts() {
  local out=""
  local key
  for key in "${!VISIT_COUNTS[@]}"; do
    if [ -z "${out}" ]; then
      out="${key}=${VISIT_COUNTS[${key}]}"
    else
      out="${out},${key}=${VISIT_COUNTS[${key}]}"
    fi
  done
  printf '%s' "${out}"
}

# record_route_history <from_step> <to_step> <reason> <action> —
# append one JSONL row. Reason carries the resolver verdict tag
# (ok / max_retries_exhausted / invalid_target / unsupported_action /
# missing_target). action is "route_back_to" on a successful jump or
# "halt" when the resolver refuses.
record_route_history() {
  local from="$1"
  local to="$2"
  local reason="$3"
  local action="$4"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"ts":"%s","from_step":"%s","to_step":"%s","reason":"%s","action":"%s","visit_count":%d}\n' \
    "${ts}" "${from}" "${to}" "${reason}" "${action}" "${VISIT_COUNTS[${to}]:-0}" \
    >> "${ROUTE_HISTORY_FILE}"
}

PREV_PHASE=""
step_idx=0

while [ "${step_idx}" -lt "${#STEP_ARRAY[@]}" ]; do
  # Advance pointer FIRST so existing `break` / `continue` calls in
  # the body keep working. route_back_to overwrites step_idx + continue
  # at the halt hook (line search: CAP_ENFORCE_ROUTE_BACK).
  CURRENT_STEP_IDX="${step_idx}"
  step_idx=$((step_idx + 1))
  IFS='|' read -r phase_num total step_ids_in_phase agents_in_phase step_id capability agent_alias prompt_file step_cli inputs optional resolution_status timeout_seconds stall_seconds stall_action input_mode output_tier continue_reason executor script_ref fallback_executor fallback_when attached_count <<< "${STEP_ARRAY[${CURRENT_STEP_IDX}]}"

  # Visit counter — incremented on every entry (forward execution and
  # route_back reruns alike) so the resolver can detect cycles.
  VISIT_COUNTS["${step_id}"]=$(( ${VISIT_COUNTS["${step_id}"]:-0} + 1 ))

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
    echo "  ${RED}│ step ${step_id} cannot run: binding status is ${resolution_status}${RESET}"
    FAILED=$((FAILED + 1))
    register_step_runtime_state "${PLAN_JSON}" "${RUNTIME_STATE_JSON}" "${step_id}" "blocked" "unresolved_binding" "" "" ""
    record_blocked_step "${WORKFLOW_LOG}" "${RUN_SUMMARY}" "${phase_num}" "${step_id}" "${capability}" "unresolved_binding" "resolution_status:${resolution_status}"
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
    echo "  ${RED}│ step ${step_id} unsupported executor: ${effective_executor}${RESET}"
    FAILED=$((FAILED + 1))
    register_step_runtime_state "${PLAN_JSON}" "${RUNTIME_STATE_JSON}" "${step_id}" "blocked" "unsupported_executor" "" "" ""
    record_blocked_step "${WORKFLOW_LOG}" "${RUN_SUMMARY}" "${phase_num}" "${step_id}" "${capability}" "unsupported_executor" "executor:${effective_executor}"
    break
  fi

  if { [ "${effective_executor}" = "ai" ] || [ "${fallback_executor}" = "ai" ]; } && { [ -z "${agent_alias}" ] || [ -z "${prompt_file}" ]; }; then
    echo "  ${RED}│ step ${step_id} missing agent_alias or prompt_file; cannot run${RESET}"
    FAILED=$((FAILED + 1))
    register_step_runtime_state "${PLAN_JSON}" "${RUNTIME_STATE_JSON}" "${step_id}" "blocked" "unresolved_binding" "" "" ""
    record_blocked_step "${WORKFLOW_LOG}" "${RUN_SUMMARY}" "${phase_num}" "${step_id}" "${capability}" "unresolved_binding" "missing:agent_alias_or_prompt_file"
    break
  fi

  effective_cli="$(resolve_step_cli "${step_cli}")"
  if [ "${effective_executor}" = "ai" ] || [ "${fallback_executor}" = "ai" ]; then
    check_cli "${effective_cli}" || {
      FAILED=$((FAILED + 1))
      record_blocked_step "${WORKFLOW_LOG}" "${RUN_SUMMARY}" "${phase_num}" "${step_id}" "${capability}" "cli_unavailable" "cli:${effective_cli}"
      break
    }
  fi

  if [ "${effective_executor}" = "shell" ] && ! resolve_shell_script_path "${script_ref}" >/dev/null; then
    FAILED=$((FAILED + 1))
    register_step_runtime_state "${PLAN_JSON}" "${RUNTIME_STATE_JSON}" "${step_id}" "blocked" "invalid_shell_script" "" "" ""
    record_blocked_step "${WORKFLOW_LOG}" "${RUN_SUMMARY}" "${phase_num}" "${step_id}" "${capability}" "invalid_shell_script" "script_ref:${script_ref}"
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
    record_blocked_step "${WORKFLOW_LOG}" "${RUN_SUMMARY}" "${phase_num}" "${step_id}" "${capability}" "missing_input_artifact" "missing:${MISSING_INPUTS}"
    break
  fi

  if step_requires_attached_branch "${capability}" "${inputs}"; then
    CURRENT_BRANCH="$(current_git_branch)"
    if [ -z "${CURRENT_BRANCH}" ]; then
      step_status "block" "${step_id}" "0"
      printf "  ${RED}│ blocked_detached_head: version control step requires an attached branch${RESET}\n"
      FAILED=$((FAILED + 1))
      register_step_runtime_state "${PLAN_JSON}" "${RUNTIME_STATE_JSON}" "${step_id}" "blocked" "detached_head" "" "" ""
      record_blocked_step "${WORKFLOW_LOG}" "${RUN_SUMMARY}" "${phase_num}" "${step_id}" "${capability}" "detached_head" "version_control_requires_branch"
      break
    fi
  fi

  # ── P6 #3 opt-in handoff schema gate (pre-dispatch) ──
  # Default behavior is unchanged (flag off → branch is skipped, the
  # ai-dispatch path runs as before). When CAP_ENFORCE_HANDOFF_SCHEMA=1
  # we re-validate the latest-seq Type C ticket for this step against
  # schemas/handoff-ticket.schema.yaml *before* spawning the sub-agent.
  # The emission-time gate inside emit-handoff-ticket.sh already
  # enforces the same schema; this is the last line of defense against
  # manual edits, schema bumps invalidating older tickets, fixture
  # drift, or any on-disk mutation between emission and dispatch.
  # Validator rc=41 (schema_validation_failed) maps to
  # STEP_STATUS=handoff_ticket_invalid + ERROR_TYPE=handoff_validation_failed
  # + STEP_HANDOFF_GATE_DETAIL captured for SESSION_FAILURE_REASON below.
  # No ticket on disk → no-op (not every step has a ticket; avoids false
  # positives on pure shell steps and pre-emit phases).
  STEP_HANDOFF_GATE_DETAIL=""
  HANDOFF_GATE_HARD_FAIL=0
  if [ "${CAP_ENFORCE_HANDOFF_SCHEMA:-0}" = "1" ] && [ "${effective_executor}" = "ai" ]; then
    HANDOFF_TICKET_PATH="$(resolve_latest_ticket "${HANDOFFS_DIR}" "${step_id}")"
    if [ -n "${HANDOFF_TICKET_PATH}" ]; then
      GATE_OUT="$("${PYTHON_BIN}" "${STEP_PY}" validate-handoff-ticket "${HANDOFF_TICKET_PATH}" --schema "${HANDOFF_SCHEMA_PATH}" 2>&1)"
      GATE_RC=$?
      if [ "${GATE_RC}" -eq 41 ]; then
        HANDOFF_GATE_HARD_FAIL=1
        STEP_HANDOFF_GATE_DETAIL="${GATE_OUT}"
        STEP_STATUS="handoff_ticket_invalid"
        FINAL_STEP_STATE="hard_fail"
        ERROR_TYPE="handoff_validation_failed"
        step_status "block" "${step_id}" "0"
        printf "  ${RED}│ blocked_handoff_invalid: %s${RESET}\n" "${HANDOFF_TICKET_PATH}"
        printf "  ${RED}│ %s${RESET}\n" "${GATE_OUT}"
        FAILED=$((FAILED + 1))
        bash "${TRACE_LOG}" append "Workflow-Exec" "step:${step_id} error_type:${ERROR_TYPE} ticket:${HANDOFF_TICKET_PATH} handoff_gate:hard_fail" "失敗" >/dev/null 2>&1 || true
        append_workflow_log "${WORKFLOW_LOG}" "${AGENT_SKILL}" "step:${step_id} error:${ERROR_TYPE} ticket:${HANDOFF_TICKET_PATH} gate:${GATE_OUT}" "失敗"
        register_step_runtime_state "${PLAN_JSON}" "${RUNTIME_STATE_JSON}" "${step_id}" "blocked" "handoff_ticket_invalid" "" "" ""
        record_blocked_step "${WORKFLOW_LOG}" "${RUN_SUMMARY}" "${phase_num}" "${step_id}" "${capability}" "handoff_ticket_invalid" "ticket:${HANDOFF_TICKET_PATH} detail:${GATE_OUT}"
        break
      fi
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

  # P5 #6 production wiring: capture prompt snapshot + hash + size so
  # the agent-sessions ledger gets the same metadata Python
  # AgentSessionRunner already writes. write_prompt_snapshot is
  # idempotent (multiple sessions sharing identical prompt content
  # share the file), so this is safe to call per step. On systems
  # without shasum / sha256sum the helper returns 1 and the three
  # vars stay empty, in which case register_agent_session simply
  # omits the optional --flag args (legacy behaviour preserved).
  STEP_PROMPT_HASH=""
  STEP_PROMPT_SNAPSHOT_PATH=""
  STEP_PROMPT_SIZE_BYTES=""
  PROMPT_META="$(write_prompt_snapshot "${step_prompt}" "${WORKFLOW_OUTPUT_DIR}" 2>/dev/null || true)"
  if [ -n "${PROMPT_META}" ]; then
    STEP_PROMPT_HASH="$(printf '%s' "${PROMPT_META}" | cut -d'|' -f1)"
    STEP_PROMPT_SNAPSHOT_PATH="$(printf '%s' "${PROMPT_META}" | cut -d'|' -f2)"
    STEP_PROMPT_SIZE_BYTES="$(printf '%s' "${PROMPT_META}" | cut -d'|' -f3)"
  fi

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
    "" \
    "${STEP_PROMPT_HASH}" \
    "${STEP_PROMPT_SNAPSHOT_PATH}" \
    "${STEP_PROMPT_SIZE_BYTES}"

  # v0.26.1 Round 2 — AI write contract landing dir setup. Each AI
  # step gets its own ``<run_dir>/code/<step_id>/`` directory; the
  # provider flags (claude --add-dir / codex --cd) plus the prompt
  # body all reference this path so the AI knows where to land code
  # artifacts. Markdown-only AI steps that have no need to write
  # files simply ignore the dir; the post-AI emit gate (R2.3) only
  # enforces non-emptiness for capabilities in the
  # ``capability-emits-code`` whitelist.
  STEP_WRITE_DIR=""
  if [ "${effective_executor}" != "shell" ]; then
    STEP_WRITE_DIR="${WORKFLOW_OUTPUT_DIR}/code/${step_id}"
    mkdir -p "${STEP_WRITE_DIR}" 2>/dev/null || true
    export CAP_WORKFLOW_WRITE_DIR="${STEP_WRITE_DIR}"
  fi

  # Run step in background, show live output chunks plus watchdog state.
  if [ "${effective_executor}" = "shell" ]; then
    run_shell_step "${script_ref}" "${step_id}" "${STEP_OUTPUT_PATH}" "${ARTIFACT_INDEX}" "${RESOLVED_INPUT_CONTEXT}" "${STEP_CONTRACT_CONTEXT}" "${USER_PROMPT}" > "${STEP_TMP}" 2>&1 &
  else
    run_step "${effective_cli}" "${step_prompt}" "${STEP_WRITE_DIR}" > "${STEP_TMP}" 2>&1 &
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

      printf "  ${YELLOW}│ shell exit %s (%s); falling back to AI${RESET}\n" "${exit_code}" "${SHELL_CONDITION}"
      START_FALLBACK="$(date '+%s')"
      # AI fallback to a shell step also needs the write contract
      # landing dir so the fallback agent can produce code. The dir
      # was prepared above for this step; create it lazily here in
      # case the shell branch ran first and the AI dir hasn't been
      # set up yet.
      FALLBACK_WRITE_DIR="${WORKFLOW_OUTPUT_DIR}/code/${step_id}"
      mkdir -p "${FALLBACK_WRITE_DIR}" 2>/dev/null || true
      export CAP_WORKFLOW_WRITE_DIR="${FALLBACK_WRITE_DIR}"
      set +e
      run_step "${effective_cli}" "${FALLBACK_PROMPT}" "${FALLBACK_WRITE_DIR}" > "${FALLBACK_TMP}" 2>&1
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
  STEP_VALIDATOR_DETAIL=""

  if ! OUTPUT_SOURCE="$(materialize_step_output "${step_id}" "${STEP_OUTPUT_PATH}" "${output}")"; then
    STEP_STATUS="write_failed"
    FINAL_STEP_STATE="hard_fail"
    step_status "fail" "${step_id}" "${DURATION}"
    FAILED=$((FAILED + 1))
    ERROR_TYPE="write_permission"
    ERROR_HINT="  executor failed to write the required output file: ${STEP_OUTPUT_PATH}. Check that the directory exists and the current user has write permission (owner/group)."
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
    ERROR_HINT="  step stdout/artifact reported a blocked or failed result; executor classified this as hard_fail to avoid marking a doc-only run as success."
    bash "${TRACE_LOG}" append "Workflow-Exec" "step:${step_id} error_type:${ERROR_TYPE} capability:${capability} cli:${effective_cli}" "失敗" >/dev/null 2>&1 || true
    STEP_FAILURE_DETAIL="$(extract_step_failure_detail "${STEP_OUTPUT_PATH}")"
    LOG_DETAIL_SUFFIX=""
    [ -n "${STEP_FAILURE_DETAIL}" ] && LOG_DETAIL_SUFFIX=" ${STEP_FAILURE_DETAIL}"
    append_workflow_log "${WORKFLOW_LOG}" "${AGENT_SKILL}" "step:${step_id} duration:${DURATION}s error:${ERROR_TYPE}${LOG_DETAIL_SUFFIX}" "失敗"
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
        ERROR_HINT="  step exceeded the hard execution limit of ${effective_timeout}s; executor aborted it automatically. Adjust timeout_seconds in the workflow step, or override the default with CAP_WORKFLOW_STEP_TIMEOUT_SECONDS."
        ;;
      STALL)
        ERROR_TYPE="stall"
        ERROR_HINT="  step produced no new output for ${effective_stall}s and stall_action=kill; executor aborted it automatically. Adjust stall_seconds/stall_action in the workflow step, or override the defaults with CAP_WORKFLOW_STEP_STALL_SECONDS / CAP_WORKFLOW_STALL_ACTION."
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
      ERROR_HINT="  step exit 0 but produced no usable output; executor classified this as hard_fail to stop downstream steps from burning tokens."
      bash "${TRACE_LOG}" append "Workflow-Exec" "step:${step_id} error_type:${ERROR_TYPE} capability:${capability} cli:${effective_cli}" "失敗" >/dev/null 2>&1 || true
      append_workflow_log "${WORKFLOW_LOG}" "${AGENT_SKILL}" "step:${step_id} duration:${DURATION}s error:${ERROR_TYPE}" "失敗"
      printf "%s\n" "${ERROR_HINT}"
      SHOULD_HALT=1
    else
      # ── P6 #4 opt-in required-output enforcement ──
      # Default behavior is unchanged (flag off → branch is skipped, exit 0
      # path runs as before). When CAP_ENFORCE_REQUIRED_OUTPUTS=1 we run the
      # registered capability_validator gate against the artifact: registered
      # capabilities (3 today: task_constitution_persistence /
      # task_constitution_planning / supervisor_envelope_validation) are
      # structurally checked; unregistered capabilities short-circuit to
      # rc=0 with reason=skipped (no false positives). Validator rc=41
      # (schema_validation_failed) maps to STEP_STATUS=required_output_invalid
      # + ERROR_TYPE=output_validation_failed (existing high-level grouping)
      # + STEP_VALIDATOR_DETAIL captured for SESSION_FAILURE_REASON below.
      VALIDATOR_HARD_FAIL=0
      if [ "${CAP_ENFORCE_REQUIRED_OUTPUTS:-0}" = "1" ]; then
        VALIDATOR_OUT="$("${PYTHON_BIN}" "${STEP_PY}" validate-capability-output "${capability}" "${STEP_OUTPUT_PATH}" 2>&1)"
        VALIDATOR_RC=$?
        if [ "${VALIDATOR_RC}" -eq 41 ]; then
          VALIDATOR_HARD_FAIL=1
          STEP_VALIDATOR_DETAIL="${VALIDATOR_OUT}"
          STEP_STATUS="required_output_invalid"
          FINAL_STEP_STATE="hard_fail"
          step_status "fail" "${step_id}" "${DURATION}"
          FAILED=$((FAILED + 1))
          ERROR_TYPE="output_validation_failed"
          ERROR_HINT="  step exit 0 but the capability validator detected a malformed required output (CAP_ENFORCE_REQUIRED_OUTPUTS=1); executor classified this as hard_fail."
          bash "${TRACE_LOG}" append "Workflow-Exec" "step:${step_id} error_type:${ERROR_TYPE} capability:${capability} cli:${effective_cli} validator:hard_fail" "失敗" >/dev/null 2>&1 || true
          append_workflow_log "${WORKFLOW_LOG}" "${AGENT_SKILL}" "step:${step_id} duration:${DURATION}s error:${ERROR_TYPE} validator:${VALIDATOR_OUT}" "失敗"
          printf "%s\n" "${ERROR_HINT}"
          if [ "${optional}" != "True" ]; then
            SHOULD_HALT=1
          fi
        fi
      fi
      # ── v0.26.0 #1 AI step result contract enforcement ──
      # Bug #12 fix: pre-v0.26.0, an AI step that exited 0 with
      # non-empty stdout was treated as success even when the AI
      # itself reported ``result: blocked_*`` / ``FAIL_BLOCKED_*`` /
      # ``needs_data`` inside its markdown body. The runtime now
      # parses the trailing handoff summary's ``result:`` line
      # against the docs/cap/AI-STEP-RESULT-CONTRACT.md enum and
      # converts non-success states into hard failures so
      # ``final_state`` reflects what the agent actually delivered.
      # Shell steps are not in scope (their exit code already
      # carries the failure signal); the gate fires only when the
      # effective executor was AI and the validator branch above
      # didn't already hard-fail the step.
      AI_RESULT_HARD_FAIL=0
      if [ "${VALIDATOR_HARD_FAIL}" -eq 0 ] \
         && [ "${effective_executor:-${executor:-ai}}" = "ai" ]; then
        AI_RESULT_OUT="$("${PYTHON_BIN}" "${STEP_PY}" parse-step-result "${STEP_OUTPUT_PATH}" 2>/dev/null)"
        AI_RESULT_STATE="$(echo "${AI_RESULT_OUT}" | grep -oE '^state=[a-z_]+' | head -1 | cut -d= -f2)"
        AI_RESULT_RAW="$(echo "${AI_RESULT_OUT}" | grep -oE '^raw_value=[^ ]+' | head -1 | cut -d= -f2)"
        if [ -z "${AI_RESULT_STATE}" ] || [ "${AI_RESULT_STATE}" = "unknown" ] \
           || [ "${AI_RESULT_STATE}" = "failed" ] || [ "${AI_RESULT_STATE}" = "blocked" ] \
           || [ "${AI_RESULT_STATE}" = "needs_data" ]; then
          AI_RESULT_HARD_FAIL=1
          STEP_STATUS="ai_self_reported_${AI_RESULT_STATE:-unknown}"
          FINAL_STEP_STATE="ai_${AI_RESULT_STATE:-unknown}"
          step_status "fail" "${step_id}" "${DURATION}"
          FAILED=$((FAILED + 1))
          ERROR_TYPE="ai_step_result_${AI_RESULT_STATE:-unknown}"
          ERROR_HINT="  AI step self-reported result=${AI_RESULT_STATE:-unknown} (raw='${AI_RESULT_RAW}'); executor classified as hard_fail per docs/cap/AI-STEP-RESULT-CONTRACT.md."
          bash "${TRACE_LOG}" append "Workflow-Exec" "step:${step_id} error_type:${ERROR_TYPE} capability:${capability} cli:${effective_cli} ai_result:${AI_RESULT_STATE:-unknown}" "失敗" >/dev/null 2>&1 || true
          append_workflow_log "${WORKFLOW_LOG}" "${AGENT_SKILL}" "step:${step_id} duration:${DURATION}s error:${ERROR_TYPE} ai_result_raw:${AI_RESULT_RAW}" "失敗"
          register_step_runtime_state "${PLAN_JSON}" "${RUNTIME_STATE_JSON}" "${step_id}" "blocked" "${ERROR_TYPE}" "${OUTPUT_SOURCE}" "${STEP_OUTPUT_PATH}" "" 2>/dev/null || true
          record_blocked_step "${WORKFLOW_LOG}" "${RUN_SUMMARY}" "${phase_num}" "${step_id}" "${capability}" "${ERROR_TYPE}" "ai_result:${AI_RESULT_STATE:-unknown} raw:${AI_RESULT_RAW}" 2>/dev/null || true
          printf "%s\n" "${ERROR_HINT}"
          if [ "${optional}" != "True" ]; then
            SHOULD_HALT=1
          fi
        fi
      fi

      # ── v0.26.1 #2 AI write contract emit-required gate ──
      # Round 2 of the bug #12 fix series. For capabilities in the
      # code-emitting whitelist (step_runtime ``capability-emits-code``
      # / ``_CODE_EMITTING_CAPABILITIES``: backend / frontend /
      # qa_testing / devops_delivery), a successful AI step must
      # actually deposit at least one file under the per-step landing
      # dir. ``result: success`` with an empty landing dir is the
      # exact pathology bug #12 surfaced: the AI thinks it succeeded
      # (or hallucinated success) but produced no real artifact. The
      # workflow now demotes this to ``ai_success_no_artifacts`` —
      # a hard fail that surfaces the discrepancy at the right
      # boundary.
      AI_EMIT_HARD_FAIL=0
      if [ "${VALIDATOR_HARD_FAIL}" -eq 0 ] \
         && [ "${AI_RESULT_HARD_FAIL}" -eq 0 ] \
         && [ "${effective_executor:-${executor:-ai}}" = "ai" ] \
         && [ -n "${STEP_WRITE_DIR}" ]; then
        EMITS_CODE="$("${PYTHON_BIN}" "${STEP_PY}" capability-emits-code "${capability}" 2>/dev/null)"
        if [ "${EMITS_CODE}" = "true" ]; then
          # Count any regular file under the landing dir, recursively.
          # Empty / dot-only dirs are treated as missing; the Round 2
          # contract requires a real artifact, not a placeholder.
          EMITTED_COUNT="$(find "${STEP_WRITE_DIR}" -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')"
          if [ -z "${EMITTED_COUNT}" ] || [ "${EMITTED_COUNT}" = "0" ]; then
            AI_EMIT_HARD_FAIL=1
            STEP_STATUS="ai_success_no_artifacts"
            FINAL_STEP_STATE="ai_success_no_artifacts"
            step_status "fail" "${step_id}" "${DURATION}"
            FAILED=$((FAILED + 1))
            ERROR_TYPE="ai_success_no_artifacts"
            ERROR_HINT="  AI step claimed result=success but landing dir ${STEP_WRITE_DIR} is empty. Capability '${capability}' is in the code-emitting whitelist (docs/cap/AI-STEP-RESULT-CONTRACT.md §Round 2) and must deposit at least one file there; workflow halts to surface the discrepancy."
            bash "${TRACE_LOG}" append "Workflow-Exec" "step:${step_id} error_type:${ERROR_TYPE} capability:${capability} cli:${effective_cli} write_dir:${STEP_WRITE_DIR}" "失敗" >/dev/null 2>&1 || true
            append_workflow_log "${WORKFLOW_LOG}" "${AGENT_SKILL}" "step:${step_id} duration:${DURATION}s error:${ERROR_TYPE} write_dir:${STEP_WRITE_DIR}" "失敗"
            register_step_runtime_state "${PLAN_JSON}" "${RUNTIME_STATE_JSON}" "${step_id}" "blocked" "${ERROR_TYPE}" "${OUTPUT_SOURCE}" "${STEP_OUTPUT_PATH}" "" 2>/dev/null || true
            record_blocked_step "${WORKFLOW_LOG}" "${RUN_SUMMARY}" "${phase_num}" "${step_id}" "${capability}" "${ERROR_TYPE}" "landing_dir:${STEP_WRITE_DIR} emitted_count:0" 2>/dev/null || true
            printf "%s\n" "${ERROR_HINT}"
            if [ "${optional}" != "True" ]; then
              SHOULD_HALT=1
            fi
          fi
        fi
      fi

      if [ "${VALIDATOR_HARD_FAIL}" -eq 0 ] && [ "${AI_RESULT_HARD_FAIL}" -eq 0 ] && [ "${AI_EMIT_HARD_FAIL}" -eq 0 ]; then
        STEP_STATUS="ok"
        FINAL_STEP_STATE="validated"
        step_status "ok" "${step_id}" "${DURATION}"
        COMPLETED=$((COMPLETED + 1))
        bash "${TRACE_LOG}" append "Workflow-Exec" "step:${step_id} capability:${capability} agent:${agent_alias} cli:${effective_cli}" "成功" >/dev/null 2>&1 || true
        append_workflow_log "${WORKFLOW_LOG}" "${AGENT_SKILL}" "step:${step_id} duration:${DURATION}s output:${STEP_OUTPUT_PATH} source:${OUTPUT_SOURCE}" "成功"
      fi
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
          ERROR_HINT="  shell step reported ${ERROR_TYPE}, but the workflow does not allow AI fallback for this condition, or the fallback also failed."
          ;;
        30)
          ERROR_HINT="  shell step stopped with policy_blocked. AI fallback only kicks in when the workflow explicitly allows it."
          ;;
        50)
          ERROR_HINT="  shell step detected sensitive_file_risk; executor forced a halt and will not fall back to AI."
          ;;
      esac
    # Auth / login errors
    elif echo "${output_lower}" | grep -qE 'not logged in|not authenticated|unauthorized|authentication required|login required|sign in|no api key|invalid.*api.?key|ANTHROPIC_API_KEY|OPENAI_API_KEY'; then
      ERROR_TYPE="auth"
      case "${effective_cli}" in
        claude) ERROR_HINT="  Please log in first: run 'claude' to start an interactive session and complete authentication." ;;
        codex)  ERROR_HINT="  Please configure an API key first: export OPENAI_API_KEY=<your-key>" ;;
      esac
    # Rate limit / quota
    elif echo "${output_lower}" | grep -qE 'rate.?limit|too many requests|429|quota.*exceeded|billing|usage.?limit|credit|overloaded|capacity'; then
      ERROR_TYPE="rate_limit"
      ERROR_HINT="  API quota exhausted or request throttled. Suggestions:
    - Wait a few minutes and retry
    - Check account usage and quota limits
    - If it persists, upgrade your plan or switch CLI: cap workflow run --cli codex ..."
    # Network errors
    elif echo "${output_lower}" | grep -qE 'network|connection.*refused|timeout|dns|econnreset|enotfound|fetch failed'; then
      ERROR_TYPE="network"
      ERROR_HINT="  Network connectivity issue. Please verify:
    - Network is working
    - Proxy settings (if required)
    - API service status (check the provider status page)"
    # Trusted directory (codex)
    elif echo "${output_lower}" | grep -qE 'trusted directory|skip-git-repo-check'; then
      ERROR_TYPE="trust"
      ERROR_HINT="  Codex does not trust the current directory. Please run 'codex' inside the project directory and grant trust first."
    fi

    bash "${TRACE_LOG}" append "Workflow-Exec" "step:${step_id} error_type:${ERROR_TYPE} capability:${capability} cli:${effective_cli}" "失敗" >/dev/null 2>&1 || true
    STEP_FAILURE_DETAIL="$(extract_step_failure_detail "${STEP_OUTPUT_PATH}")"
    LOG_DETAIL_SUFFIX=""
    [ -n "${STEP_FAILURE_DETAIL}" ] && LOG_DETAIL_SUFFIX=" ${STEP_FAILURE_DETAIL}"
    append_workflow_log "${WORKFLOW_LOG}" "${AGENT_SKILL}" "step:${step_id} duration:${DURATION}s error:${ERROR_TYPE}${LOG_DETAIL_SUFFIX}" "失敗"

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
    # P6 #4: opt-in capability_validator detail wins over artifact-side
    # reason:/detail: lines, because the gate ran AFTER the agent finished
    # writing — its verdict is the closest-to-truth diagnosis of why this
    # step is being downgraded from exit-0 to hard_fail.
    if [ -n "${STEP_VALIDATOR_DETAIL:-}" ]; then
      SESSION_FAILURE_REASON="${STEP_STATUS}: ${STEP_VALIDATOR_DETAIL}"
    else
      # Pull reason / detail lines emitted by shell executors (fail_with)
      # so the ledger surfaces e.g. "failed: reason=validation_failed;detail=PARSE_ERROR:..."
      # rather than just "failed". Empty extraction → fall back to STEP_STATUS only.
      SESSION_DETAIL="$(extract_step_failure_detail "${STEP_OUTPUT_PATH}")"
      if [ -n "${SESSION_DETAIL}" ]; then
        SESSION_FAILURE_REASON="${STEP_STATUS}: ${SESSION_DETAIL}"
      else
        SESSION_FAILURE_REASON="${STEP_STATUS}"
      fi
    fi
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
    "${DURATION}" \
    "${STEP_PROMPT_HASH}" \
    "${STEP_PROMPT_SNAPSHOT_PATH}" \
    "${STEP_PROMPT_SIZE_BYTES}"

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
    # ── P6 #8 opt-in route_back_to handling ──
    # Default behavior is unchanged (flag off → break out as before).
    # When CAP_ENFORCE_ROUTE_BACK=1 we consult the failed ticket's
    # failure_routing block via resolve-handoff-routing. Verdicts:
    #   * action=route_back_to + valid target → step_idx jumps back,
    #     SHOULD_HALT clears, control flow re-enters target step.
    #     Forward steps after target re-execute on next iteration
    #     because they sit ahead in STEP_ARRAY.
    #   * action=halt (incl. max_retries_exhausted, invalid_target,
    #     unsupported_action, missing_target) → break as usual but
    #     log the verdict to route-history.jsonl + workflow.log so
    #     audit trails surface why route_back was refused.
    # Scope: only ai-executor steps with a ticket on disk. Pure-shell
    # steps and steps without an emitted ticket short-circuit to
    # halt (no route_back semantics defined for them in P6 #8).
    if [ "${CAP_ENFORCE_ROUTE_BACK:-0}" = "1" ] && [ "${effective_executor}" = "ai" ]; then
      ROUTE_BACK_TICKET_PATH="$(resolve_latest_ticket "${HANDOFFS_DIR}" "${step_id}")"
      if [ -n "${ROUTE_BACK_TICKET_PATH}" ]; then
        ROUTE_VISITS_ARG="$(format_visit_counts)"
        ROUTE_OUT="$("${PYTHON_BIN}" "${STEP_PY}" resolve-handoff-routing "${ROUTE_BACK_TICKET_PATH}" --plan-steps "${ROUTE_BACK_PLAN_STEPS}" --visits "${ROUTE_VISITS_ARG}" 2>&1)"
        ROUTE_RC=$?
        if [ "${ROUTE_RC}" -eq 0 ]; then
          ROUTE_ACTION="$(printf '%s' "${ROUTE_OUT}" | sed -E 's/^action=([^;]*).*$/\1/')"
          ROUTE_TARGET="$(printf '%s' "${ROUTE_OUT}" | sed -E 's/^.*target=([^;]*);reason=.*$/\1/')"
          ROUTE_REASON="$(printf '%s' "${ROUTE_OUT}" | sed -E 's/^.*reason=([^;]*);remaining=.*$/\1/')"
          if [ "${ROUTE_ACTION}" = "route_back_to" ] && [ -n "${ROUTE_TARGET}" ]; then
            ROUTE_TARGET_IDX="$(find_step_idx_in_array "${ROUTE_TARGET}")"
            if [ -n "${ROUTE_TARGET_IDX}" ]; then
              record_route_history "${step_id}" "${ROUTE_TARGET}" "${ROUTE_REASON}" "route_back_to"
              printf "  ${YELLOW}│ route_back_to: %s → %s (reason=%s, visits=%s)${RESET}\n" "${step_id}" "${ROUTE_TARGET}" "${ROUTE_REASON}" "${VISIT_COUNTS[${ROUTE_TARGET}]:-0}"
              append_workflow_log "${WORKFLOW_LOG}" "${AGENT_SKILL}" "step:${step_id} route_back_to:${ROUTE_TARGET} reason:${ROUTE_REASON} visits:${VISIT_COUNTS[${ROUTE_TARGET}]:-0}" "重路由"
              bash "${TRACE_LOG}" append "Workflow-Exec" "step:${step_id} route_back_to:${ROUTE_TARGET} reason:${ROUTE_REASON}" "重路由" >/dev/null 2>&1 || true
              # Reset SHOULD_HALT and rewind step_idx to target.
              # Visit counter for ${ROUTE_TARGET} will increment
              # again on the next iteration's entry.
              step_idx="${ROUTE_TARGET_IDX}"
              SHOULD_HALT=0
              FAILED=$(( FAILED > 0 ? FAILED - 1 : 0 ))
              continue
            fi
          fi
          # Halt verdict: log non-trivial reasons (skip "no_routing"
          # which is the default halt and not noteworthy).
          if [ "${ROUTE_ACTION}" = "halt" ] && [ "${ROUTE_REASON}" != "no_routing" ]; then
            record_route_history "${step_id}" "${ROUTE_TARGET}" "${ROUTE_REASON}" "halt"
            printf "  ${YELLOW}│ route_back halted: reason=%s${RESET}\n" "${ROUTE_REASON}"
            append_workflow_log "${WORKFLOW_LOG}" "${AGENT_SKILL}" "step:${step_id} route_back_halt reason:${ROUTE_REASON} target:${ROUTE_TARGET}" "失敗"
          fi
        fi
      fi
    fi
    break
  fi

done

TOTAL_DURATION="$(( $(date '+%s') - START_TOTAL ))"

FINAL_STATE="completed"
FINAL_RESULT="success"
EXIT_CODE=0

if [ "${FAILED}" -gt 0 ]; then
  FINAL_STATE="failed"
  FINAL_RESULT="step_failed"
  EXIT_CODE=1
fi

# Append the run-summary ``## Finished`` block BEFORE rendering result.md so
# result_report_builder can derive ``final_state`` from the Finished header.
{
  printf '\n## Finished\n\n'
  printf -- '- finished_at: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf -- '- total_duration_seconds: %s\n' "${TOTAL_DURATION}"
  printf -- '- completed: %s\n' "${COMPLETED}"
  printf -- '- failed: %s\n' "${FAILED}"
  printf -- '- skipped: %s\n' "${SKIPPED}"
} >> "${RUN_SUMMARY}"

# P7 Phase B — try the result_report_builder producer first. On schema
# pass we get both ``workflow-result.json`` (machine artifact) and a
# rendered ``result.md`` (human projection). Any failure falls back to
# the legacy hardcoded template below; failures only log to workflow.log
# and never halt the run.
WORKFLOW_RESULT_JSON="${WORKFLOW_OUTPUT_DIR}/workflow-result.json"
CAP_HOME_FOR_BUILDER="$(bash "${PATH_HELPER}" get cap_home 2>/dev/null || true)"
STATUS_FILE_FOR_BUILDER="$(get_status_store 2>/dev/null || true)"
if cap_result_emit \
    "${WORKFLOW_OUTPUT_DIR}" \
    "${CAP_HOME_FOR_BUILDER}" \
    "${STATUS_FILE_FOR_BUILDER}" \
    "${WORKFLOW_RESULT_JSON}" \
    "${RESULT_REPORT}" \
    "${WORKFLOW_LOG}"; then
  :
else
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

This result report is generated by CAP workflow executor as the human-readable run archive (legacy fallback path; workflow-result.json was not emitted).
EOF
)" || true
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  ${BOLD}Done${RESET} in %ss  |  ✓ %s  ✗ %s  ⊘ %s\n" "${TOTAL_DURATION}" "${COMPLETED}" "${FAILED}" "${SKIPPED}"
echo ""
CAP_SHORT="~/.cap"
RUN_SHORT="${WORKFLOW_OUTPUT_DIR/#${HOME}\/.cap/${CAP_SHORT}}"
printf "  ${DIM}base${RESET} %s/\n" "${RUN_SHORT}"
# Collect unique filenames, skip duplicates
_LISTED=""
for f in "${ARTIFACT_INDEX}" "${WORKFLOW_LOG}" "${RUN_SUMMARY}" "${RESULT_REPORT}" "${WORKFLOW_RESULT_JSON}" "${AGENT_SESSIONS_JSON}" "${WORKFLOW_OUTPUT_DIR}/"*-*.md "${WORKFLOW_OUTPUT_DIR}/"*-*.raw.log "${RUNTIME_STATE_JSON}"; do
  [ -f "${f}" ] || continue
  _FNAME="$(basename "${f}")"
  case "${_LISTED}" in *"|${_FNAME}|"*) continue ;; esac
  _LISTED="${_LISTED}|${_FNAME}|"
  printf "    %s\n" "${_FNAME}"
done
echo ""

append_workflow_log "${WORKFLOW_LOG}" "workflow" "workflow:${WORKFLOW_ID} duration:${TOTAL_DURATION}s completed:${COMPLETED} failed:${FAILED} skipped:${SKIPPED}" "${FINAL_RESULT}"

if [ -n "${RUN_ID}" ]; then
  bash "${SCRIPT_DIR}/cap-workflow.sh" update-run-status "${RUN_ID}" "${FINAL_STATE}" "${FINAL_RESULT}" >/dev/null 2>&1 || true
fi

exit "${EXIT_CODE}"
