#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKFLOWS_DIR="${CAP_ROOT}/schemas/workflows"
VENV_PYTHON="${CAP_ROOT}/.venv/bin/python"
PATH_HELPER="${SCRIPT_DIR}/cap-paths.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  cap workflow list
  cap workflow ps [--all]
  cap workflow show <id>
  cap workflow inspect <run-id>
  cap workflow plan <id>
  cap workflow bind <id> [registry]
  cap workflow constitution <request...>
  cap workflow compile <request...> [--registry path]
  cap workflow run-task [--dry-run] [--cli codex|claude] [--registry path] <request...>
  cap workflow run [--dry-run] [--cli codex|claude] [--mode quick|governed|auto] <id> [prompt...]
  cap workflow <id> "<prompt>"            (run 的簡寫)

Default CLI: claude (可用 --cli codex 覆寫，或設定 CAP_DEFAULT_AGENT_CLI 環境變數)
EOF
  exit 1
}

resolve_python() {
  if [ -x "${VENV_PYTHON}" ]; then
    printf '%s\n' "${VENV_PYTHON}"
  else
    printf '%s\n' "python3"
  fi
}

PYTHON_BIN="$(resolve_python)"
CLI_PY="${CAP_ROOT}/engine/workflow_cli.py"

# ---------------------------------------------------------------------------
# Thin wrapper functions — delegate to workflow_cli.py subcommands
# ---------------------------------------------------------------------------

resolve_workflow_ref() {
  local raw_ref="${1:-}"
  [ -n "${raw_ref}" ] || return 1

  if [ -f "${raw_ref}" ]; then
    printf '%s\n' "${raw_ref}"
    return 0
  fi

  if [[ "${raw_ref}" != *.yaml && "${raw_ref}" != *.yml && "${raw_ref}" != *.json ]]; then
    if [ -f "${WORKFLOWS_DIR}/${raw_ref}.yaml" ]; then
      printf '%s\n' "${WORKFLOWS_DIR}/${raw_ref}.yaml"
      return 0
    fi
  fi

  if [ -f "${WORKFLOWS_DIR}/${raw_ref}" ]; then
    printf '%s\n' "${WORKFLOWS_DIR}/${raw_ref}"
    return 0
  fi

  "${PYTHON_BIN}" "${CLI_PY}" resolve-ref "${WORKFLOWS_DIR}" "${raw_ref}"
  return $?
}

collect_repo_change_files() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi

  {
    git diff --name-only --cached 2>/dev/null || true
    git diff --name-only 2>/dev/null || true
    git ls-files --others --exclude-standard 2>/dev/null || true
  } | sed '/^[[:space:]]*$/d' | sort -u
}

resolve_run_execution_mode() {
  local workflow_ref="$1"
  local requested_mode="$2"
  local user_prompt="$3"
  local changed_files

  changed_files="$(collect_repo_change_files || true)"

  "${PYTHON_BIN}" "${CLI_PY}" resolve-mode "${CAP_ROOT}" "${workflow_ref}" "${requested_mode}" "${user_prompt}" "${changed_files}"
}

ensure_status_store() {
  bash "${PATH_HELPER}" ensure >/dev/null
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

create_workflow_run() {
  local workflow_id="$1"
  local workflow_name="$2"
  local state="$3"
  local result="$4"
  local mode="$5"
  local cli_name="$6"
  local prompt="$7"
  local status_file
  status_file="$(get_status_store)"

  "${PYTHON_BIN}" "${CLI_PY}" create-run "${status_file}" "${workflow_id}" "${workflow_name}" "${state}" "${result}" "${mode}" "${cli_name}" "${prompt}"
}

persist_constitution_artifact() {
  local constitution_json="$1"
  local request="$2"
  local origin="$3"
  local constitution_dir

  bash "${PATH_HELPER}" ensure >/dev/null
  constitution_dir="$(bash "${PATH_HELPER}" get constitution_dir)"

  "${PYTHON_BIN}" "${CLI_PY}" persist-constitution "${constitution_dir}" "${request}" "${origin}" "${constitution_json}"
}

persist_binding_snapshot() {
  local binding_json="$1"
  local workflow_id="$2"
  local workflow_name="$3"
  local workflow_ref="$4"
  local origin="$5"
  local binding_dir
  local augmented_json

  bash "${PATH_HELPER}" ensure >/dev/null
  binding_dir="$(bash "${PATH_HELPER}" get binding_dir)"

  # Inject workflow_name, workflow_ref, origin into the binding JSON
  # so the CLI can extract them (it reads these from the JSON payload).
  augmented_json="$(printf '%s' "${binding_json}" | "${PYTHON_BIN}" -c "
import json, sys
d = json.load(sys.stdin)
d['workflow_name'] = sys.argv[1]
d['workflow_ref'] = sys.argv[2]
d['origin'] = sys.argv[3]
print(json.dumps(d, ensure_ascii=False))
" "${workflow_name}" "${workflow_ref}" "${origin}")"

  "${PYTHON_BIN}" "${CLI_PY}" persist-binding "${binding_dir}" "${workflow_id}" "${augmented_json}"
}

persist_task_compile_bundle() {
  local compiled_json="$1"
  local request="$2"
  local registry_ref="$3"
  local origin="$4"
  local constitution_dir
  local compiled_workflow_dir
  local binding_dir

  bash "${PATH_HELPER}" ensure >/dev/null
  constitution_dir="$(bash "${PATH_HELPER}" get constitution_dir)"
  compiled_workflow_dir="$(bash "${PATH_HELPER}" get compiled_workflow_dir)"
  binding_dir="$(bash "${PATH_HELPER}" get binding_dir)"

  "${PYTHON_BIN}" "${CLI_PY}" persist-compile-bundle "${constitution_dir}" "${compiled_workflow_dir}" "${binding_dir}" "${request}" "${registry_ref}" "${origin}" "${compiled_json}"
}

update_workflow_run() {
  local run_id="$1"
  local state="$2"
  local result="$3"
  local status_file
  status_file="$(get_status_store)"

  "${PYTHON_BIN}" "${CLI_PY}" update-run "${status_file}" "${run_id}" "${state}" "${result}"
}

workflow_summary_field() {
  local workflow_id="$1"
  local field="$2"
  local status_file
  status_file="$(get_status_store)"

  "${PYTHON_BIN}" "${CLI_PY}" summary-field "${status_file}" "${workflow_id}" "${field}"
}

ensure_status_store

COMMAND="${1:-}"
if [ -n "${COMMAND}" ] && [[ "${COMMAND}" != "list" && "${COMMAND}" != "ps" && "${COMMAND}" != "show" && "${COMMAND}" != "inspect" && "${COMMAND}" != "plan" && "${COMMAND}" != "bind" && "${COMMAND}" != "constitution" && "${COMMAND}" != "compile" && "${COMMAND}" != "run-task" && "${COMMAND}" != "run" && "${COMMAND}" != "update-run-status" ]]; then
  # cap workflow <id> "prompt" → run <id> "prompt"
  # cap workflow <id>          → show <id>
  if [ "$#" -ge 2 ]; then
    set -- run "$@"
  else
    set -- show "$@"
  fi
fi

case "${1:-}" in
  list)
    [ "$#" -eq 1 ] || usage
    "${PYTHON_BIN}" "${CLI_PY}" list "${WORKFLOWS_DIR}" "$(get_status_store)"
    ;;
  ps)
    shift || true
    PS_FILTER="active"
    if [ "${1:-}" = "--all" ] || [ "${1:-}" = "-a" ]; then
      PS_FILTER="all"
      shift || true
    fi
    "${PYTHON_BIN}" "${CLI_PY}" ps "$(get_status_store)" "${PS_FILTER}"
    ;;
  show)
    [ "$#" -eq 2 ] || usage
    WORKFLOW_REF="$(resolve_workflow_ref "$2")" || {
      echo "找不到 workflow：$2" >&2
      exit 1
    }
    "${PYTHON_BIN}" "${CLI_PY}" show "${CAP_ROOT}" "${WORKFLOW_REF}" "$(get_status_store)"
    ;;
  inspect)
    [ "$#" -eq 2 ] || usage
    "${PYTHON_BIN}" "${CLI_PY}" inspect "$(get_status_store)" "$2"
    ;;
  plan)
    [ "$#" -eq 2 ] || usage
    WORKFLOW_REF="$(resolve_workflow_ref "$2")" || {
      echo "找不到 workflow：$2" >&2
      exit 1
    }
    "${PYTHON_BIN}" "${CLI_PY}" plan "${CAP_ROOT}" "${WORKFLOW_REF}"
    ;;
  bind)
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
    WORKFLOW_REF="$(resolve_workflow_ref "$2")" || {
      echo "找不到 workflow：$2" >&2
      exit 1
    }
    REGISTRY_REF="${3:-}"
    BINDING_JSON="$("${PYTHON_BIN}" "${CLI_PY}" bind "${CAP_ROOT}" "${WORKFLOW_REF}" "${REGISTRY_REF}")"
    BINDING_WORKFLOW_ID="$(printf '%s' "${BINDING_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["workflow_id"])')"
    BINDING_WORKFLOW_NAME="$(basename "${WORKFLOW_REF}")"
    BINDING_SNAPSHOT_JSON="$(persist_binding_snapshot "${BINDING_JSON}" "${BINDING_WORKFLOW_ID}" "${BINDING_WORKFLOW_NAME}" "${WORKFLOW_REF}" "bind")"
    "${PYTHON_BIN}" "${CLI_PY}" print-bind-report "${BINDING_JSON}" "${BINDING_SNAPSHOT_JSON}"
    ;;
  constitution)
    shift || true
    [ "$#" -ge 1 ] || {
      echo "Usage: cap workflow constitution <request...>" >&2
      exit 1
    }
    REQUEST="$*"
    CONSTITUTION_JSON="$("${PYTHON_BIN}" "${CLI_PY}" constitution-json "${CAP_ROOT}" "${REQUEST}")"
    CONSTITUTION_SNAPSHOT_JSON="$(persist_constitution_artifact "${CONSTITUTION_JSON}" "${REQUEST}" "constitution")"
    "${PYTHON_BIN}" "${CLI_PY}" print-constitution-report "${CONSTITUTION_JSON}" "${CONSTITUTION_SNAPSHOT_JSON}"
    ;;
  compile)
    shift || true
    REGISTRY_REF=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --registry) REGISTRY_REF="$2"; shift 2 ;;
        *) break ;;
      esac
    done
    [ "$#" -ge 1 ] || {
      echo "Usage: cap workflow compile <request...> [--registry path]" >&2
      exit 1
    }
    REQUEST="$*"
    COMPILED_JSON="$("${PYTHON_BIN}" "${CLI_PY}" compile-json "${CAP_ROOT}" "${REQUEST}" "${REGISTRY_REF}")"
    COMPILE_SNAPSHOT_JSON="$(persist_task_compile_bundle "${COMPILED_JSON}" "${REQUEST}" "${REGISTRY_REF}" "compile")"
    "${PYTHON_BIN}" "${CLI_PY}" print-compile-report "${COMPILED_JSON}" "${COMPILE_SNAPSHOT_JSON}"
    ;;
  run-task)
    shift || true

    DETACH=0
    DRY_RUN=0
    RUN_CLI="${CAP_DEFAULT_AGENT_CLI:-auto}"
    CLI_OVERRIDE=0
    REGISTRY_REF=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -d) DETACH=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --cli) RUN_CLI="$2"; CLI_OVERRIDE=1; shift 2 ;;
        --registry) REGISTRY_REF="$2"; shift 2 ;;
        *) break ;;
      esac
    done

    [ "$#" -ge 1 ] || {
      echo "Usage: cap workflow run-task [--dry-run] [-d] [--cli codex|claude] [--registry path] <request...>" >&2
      exit 1
    }

    USER_PROMPT="$*"
    COMPILED_JSON="$("${PYTHON_BIN}" "${CLI_PY}" compile-json "${CAP_ROOT}" "${USER_PROMPT}" "${REGISTRY_REF}")"

    PLAN_JSON="$(printf '%s' "${COMPILED_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["plan"], ensure_ascii=False))')"
    CONSTITUTION_JSON="$(printf '%s' "${COMPILED_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["task_constitution"], ensure_ascii=False))')"
    POLICY_JSON="$(printf '%s' "${COMPILED_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["unresolved_policy"], ensure_ascii=False))')"
    WORKFLOW_ID="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["workflow_id"])')"
    WORKFLOW_NAME="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
    BINDING_JSON="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["binding"], ensure_ascii=False))')"
    BINDING_STATUS="$(printf '%s' "${BINDING_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["binding_status"])')"
    COMPILE_SNAPSHOT_JSON="$(persist_task_compile_bundle "${COMPILED_JSON}" "${USER_PROMPT}" "${REGISTRY_REF}" "run-task")"

    if [ "${DRY_RUN}" -eq 1 ]; then
      echo ""
      echo "COMPILED WORKFLOW DRY RUN — ${WORKFLOW_NAME}"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      "${PYTHON_BIN}" "${CLI_PY}" print-compiled-dry-run "${CONSTITUTION_JSON}" "${POLICY_JSON}" "${PLAN_JSON}" "${COMPILE_SNAPSHOT_JSON}"
      echo ""
      exit 0
    fi

    if [ "${BINDING_STATUS}" = "blocked" ]; then
      echo ""
      echo "COMPILED WORKFLOW PREFLIGHT BLOCKED — ${WORKFLOW_NAME}"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      "${PYTHON_BIN}" "${CLI_PY}" print-compiled-blocked "${CONSTITUTION_JSON}" "${POLICY_JSON}" "${BINDING_JSON}" "${COMPILE_SNAPSHOT_JSON}"
      echo ""
      exit 2
    fi

    if [ "${BINDING_STATUS}" = "degraded" ]; then
      echo ""
      echo "COMPILED WORKFLOW PREFLIGHT DEGRADED — ${WORKFLOW_NAME}"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      "${PYTHON_BIN}" "${CLI_PY}" print-compiled-degraded "${POLICY_JSON}" "${COMPILE_SNAPSHOT_JSON}"
      echo ""
    fi

    if [ "${DETACH}" -eq 1 ]; then
      RUN_ID="$(create_workflow_run "${WORKFLOW_ID}" "${WORKFLOW_NAME}" "detached" "background_start" "detached" "${RUN_CLI}" "${USER_PROMPT}")"
      echo "Background mode is not yet implemented."
      echo "RUN ID: ${RUN_ID}"
      exit 0
    fi

    RUN_ID="$(create_workflow_run "${WORKFLOW_ID}" "${WORKFLOW_NAME}" "executing" "foreground_start" "foreground" "${RUN_CLI}" "${USER_PROMPT}")"
    bash "${SCRIPT_DIR}/trace-log.sh" append "Workflow" "compiled_workflow:${WORKFLOW_ID} run:${RUN_ID} 啟動 (${WORKFLOW_NAME})" "成功" >/dev/null 2>&1 || true
    "${PYTHON_BIN}" "${CLI_PY}" print-compile-start "${COMPILE_SNAPSHOT_JSON}" "${RUN_ID}"
    if [ "${CLI_OVERRIDE}" -eq 1 ]; then
      CAP_WORKFLOW_REQUESTED_MODE="${EXECUTION_MODE}" CAP_WORKFLOW_SELECTED_MODE="${SELECTED_MODE}" exec bash "${SCRIPT_DIR}/cap-workflow-exec.sh" "${PLAN_JSON}" "${USER_PROMPT}" --cli "${RUN_CLI}" --run-id "${RUN_ID}"
    fi
    CAP_WORKFLOW_REQUESTED_MODE="${EXECUTION_MODE}" CAP_WORKFLOW_SELECTED_MODE="${SELECTED_MODE}" exec bash "${SCRIPT_DIR}/cap-workflow-exec.sh" "${PLAN_JSON}" "${USER_PROMPT}" --run-id "${RUN_ID}"
    ;;
  run)
    shift || true

    DETACH=0
    DRY_RUN=0
    RUN_CLI="${CAP_DEFAULT_AGENT_CLI:-auto}"
    CLI_OVERRIDE=0
    EXECUTION_MODE="auto"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -d)       DETACH=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --cli)    RUN_CLI="$2"; CLI_OVERRIDE=1; shift 2 ;;
        --mode)   EXECUTION_MODE="$2"; shift 2 ;;
        *)        break ;;
      esac
    done

    [ "$#" -ge 1 ] || {
      echo "Usage: cap workflow run [--dry-run] [-d] [--cli codex|claude] [--mode quick|governed|auto] <workflow> [prompt...]" >&2
      exit 1
    }
    case "${EXECUTION_MODE}" in
      quick|governed|auto) ;;
      *)
        echo "不支援的 --mode：${EXECUTION_MODE}。可用值：quick | governed | auto" >&2
        exit 1
        ;;
    esac

    WORKFLOW_REF="$(resolve_workflow_ref "$1")" || {
      echo "找不到 workflow：$1" >&2
      exit 1
    }
    shift
    USER_PROMPT="$*"

    PLAN_JSON="$("${PYTHON_BIN}" "${CLI_PY}" build-bound-plan "${CAP_ROOT}" "${WORKFLOW_REF}")"

    WORKFLOW_ID="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["workflow_id"])')"
    WORKFLOW_NAME="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
    BINDING_JSON="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["binding"], ensure_ascii=False))')"
    BINDING_STATUS="$(printf '%s' "${BINDING_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["binding_status"])')"
    BINDING_SNAPSHOT_JSON="$(persist_binding_snapshot "${BINDING_JSON}" "${WORKFLOW_ID}" "${WORKFLOW_NAME}" "${WORKFLOW_REF}" "run")"

    if [ -z "${USER_PROMPT}" ]; then
      if [ -t 0 ]; then
        printf '請輸入 workflow 任務說明（直接 Enter 僅顯示 plan）: ' >&2
        read -r USER_PROMPT || true
      fi
    fi

    MODE_RESOLUTION_JSON="$(resolve_run_execution_mode "${WORKFLOW_REF}" "${EXECUTION_MODE}" "${USER_PROMPT}")"
    SELECTOR_APPLIED="$(printf '%s' "${MODE_RESOLUTION_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["selector_applied"])')"
    SELECTED_MODE="$(printf '%s' "${MODE_RESOLUTION_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["selected_mode"])')"
    MODE_REASON="$(printf '%s' "${MODE_RESOLUTION_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["reason"])')"
    MODE_CONFIDENCE="$(printf '%s' "${MODE_RESOLUTION_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["confidence"])')"
    SELECTED_WORKFLOW_REF="$(printf '%s' "${MODE_RESOLUTION_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["selected_workflow_ref"])')"
    if [ "${SELECTOR_APPLIED}" = "True" ]; then
      WORKFLOW_REF="${SELECTED_WORKFLOW_REF}"
      PLAN_JSON="$("${PYTHON_BIN}" "${CLI_PY}" build-bound-plan "${CAP_ROOT}" "${WORKFLOW_REF}")"
      WORKFLOW_ID="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["workflow_id"])')"
      WORKFLOW_NAME="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
      BINDING_JSON="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["binding"], ensure_ascii=False))')"
      BINDING_STATUS="$(printf '%s' "${BINDING_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["binding_status"])')"
      BINDING_SNAPSHOT_JSON="$(persist_binding_snapshot "${BINDING_JSON}" "${WORKFLOW_ID}" "${WORKFLOW_NAME}" "${WORKFLOW_REF}" "run")"
    fi

    if [ -z "${USER_PROMPT}" ] || [ "${DRY_RUN}" -eq 1 ]; then
      echo ""
      if [ "${DRY_RUN}" -eq 1 ]; then
        echo "WORKFLOW DRY RUN — ${WORKFLOW_NAME}"
      else
        echo "WORKFLOW PLAN — ${WORKFLOW_NAME}"
      fi
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo ""
      if [ "${SELECTOR_APPLIED}" = "True" ]; then
        echo "  Mode: ${SELECTED_MODE} (${EXECUTION_MODE})"
        echo "  Reason: ${MODE_REASON}"
        echo "  Confidence: ${MODE_CONFIDENCE}"
        echo ""
      fi
      "${PYTHON_BIN}" "${CLI_PY}" print-workflow-plan "${PLAN_JSON}"
      echo ""
      "${PYTHON_BIN}" "${CLI_PY}" print-binding-summary "${BINDING_JSON}" "${BINDING_SNAPSHOT_JSON}"
      echo ""
      if [ "${DRY_RUN}" -eq 1 ]; then
        echo "  Dry run only — no step was executed."
      else
        echo "  To execute: cap workflow run ${WORKFLOW_ID} \"<prompt>\""
      fi
      echo ""
      exit 0
    fi

    if [ "${BINDING_STATUS}" = "blocked" ]; then
      echo ""
      echo "WORKFLOW PREFLIGHT BLOCKED — ${WORKFLOW_NAME}"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      if [ "${SELECTOR_APPLIED}" = "True" ]; then
        echo "mode: ${SELECTED_MODE} (${EXECUTION_MODE})"
        echo "reason: ${MODE_REASON}"
        echo ""
      fi
      "${PYTHON_BIN}" "${CLI_PY}" print-binding-blocked "${BINDING_JSON}" "${BINDING_SNAPSHOT_JSON}"
      echo ""
      echo "Workflow 已停止，請先補齊 skill registry 或調整 binding policy。"
      exit 2
    fi

    if [ "${BINDING_STATUS}" = "degraded" ]; then
      echo ""
      echo "WORKFLOW PREFLIGHT DEGRADED — ${WORKFLOW_NAME}"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      if [ "${SELECTOR_APPLIED}" = "True" ]; then
        echo "mode: ${SELECTED_MODE} (${EXECUTION_MODE})"
        echo "reason: ${MODE_REASON}"
        echo ""
      fi
      "${PYTHON_BIN}" "${CLI_PY}" print-binding-degraded "${BINDING_JSON}" "${BINDING_SNAPSHOT_JSON}"
      echo ""
      echo "將以 degraded 模式繼續執行。"
    fi

    if [ "${DETACH}" -eq 1 ]; then
      RUN_ID="$(create_workflow_run "${WORKFLOW_ID}" "${WORKFLOW_NAME}" "detached" "background_start" "detached" "${RUN_CLI}" "${USER_PROMPT}")"
      bash "${SCRIPT_DIR}/trace-log.sh" append "Workflow" "workflow:${WORKFLOW_ID} run:${RUN_ID} 啟動背景執行 (${WORKFLOW_NAME})" "成功" >/dev/null 2>&1 || true
      echo "Background mode is not yet implemented."
      echo "RUN ID: ${RUN_ID}"
      echo "Use foreground: cap workflow run ${WORKFLOW_ID} \"<prompt>\""
      exit 0
    fi

    RUN_ID="$(create_workflow_run "${WORKFLOW_ID}" "${WORKFLOW_NAME}" "executing" "foreground_start" "foreground" "${RUN_CLI}" "${USER_PROMPT}")"
    bash "${SCRIPT_DIR}/trace-log.sh" append "Workflow" "workflow:${WORKFLOW_ID} run:${RUN_ID} 啟動 (${WORKFLOW_NAME})" "成功" >/dev/null 2>&1 || true
    if [ "${SELECTOR_APPLIED}" = "True" ]; then
      echo "  Mode: ${SELECTED_MODE} (${EXECUTION_MODE})"
      echo "  Reason: ${MODE_REASON}"
      echo "  Confidence: ${MODE_CONFIDENCE}"
    fi
    "${PYTHON_BIN}" "${CLI_PY}" print-binding-start "${BINDING_SNAPSHOT_JSON}" "${RUN_ID}"
    if [ "${CLI_OVERRIDE}" -eq 1 ]; then
      exec bash "${SCRIPT_DIR}/cap-workflow-exec.sh" "${PLAN_JSON}" "${USER_PROMPT}" --cli "${RUN_CLI}" --run-id "${RUN_ID}"
    fi
    exec bash "${SCRIPT_DIR}/cap-workflow-exec.sh" "${PLAN_JSON}" "${USER_PROMPT}" --run-id "${RUN_ID}"
    ;;
  update-run-status)
    [ "$#" -eq 4 ] || usage
    update_workflow_run "$2" "$3" "$4"
    ;;
  *)
    usage
    ;;
esac
