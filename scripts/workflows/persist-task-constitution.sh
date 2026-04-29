#!/usr/bin/env bash
#
# persist-task-constitution.sh — Pipeline step: validate the AI-drafted Task
# Constitution JSON against schemas/task-constitution.schema.yaml and persist
# it to the canonical runtime location.
#
# Reads:
#   - task_constitution_draft artifact path (from CAP_WORKFLOW_INPUT_CONTEXT)
#   - upstream draft must contain JSON either in a <<<TASK_CONSTITUTION_JSON_BEGIN>>>
#     fence or in a ```json fenced block.
#
# Behavior:
#   - Locate the draft path from upstream context.
#   - Extract the JSON payload.
#   - Validate against schemas/task-constitution.schema.yaml (best-effort;
#     warns on missing required fields, hard-fails on JSON parse errors).
#   - Persist to ~/.cap/projects/<project_id>/constitutions/task_<task_id>.json.
#   - Emit a markdown report listing the persisted path so downstream
#     handoff_ticket_emit step can resolve it.
#
# Exit codes:
#   - 0  : success (persistence performed)
#   - 40 : critical failure — missing input artifact, JSON parse error,
#          required field missing, or write failure.
#
# This step does NOT allow AI fallback; the upstream draft is preserved in
# the workflow output dir for retry.

set -u

step_id="${CAP_WORKFLOW_STEP_ID:-persist_task_constitution}"
input_context="${CAP_WORKFLOW_INPUT_CONTEXT:-}"

CAP_ROOT="${CAP_ROOT:-}"
if [ -z "${CAP_ROOT}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CAP_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
fi

VENV_PY="${CAP_ROOT}/.venv/bin/python"
if [ -x "${VENV_PY}" ]; then
  PYTHON_BIN="${VENV_PY}"
else
  PYTHON_BIN="python3"
fi

PATH_HELPER="${CAP_ROOT}/scripts/cap-paths.sh"

print_header() {
  printf '# %s\n\n' "${step_id}"
  printf '## Task Constitution Persistence Report\n\n'
}

fail_with() {
  local reason="$1"
  shift
  printf 'condition: workflow_step_failed\n'
  printf 'reason: %s\n' "${reason}"
  for line in "$@"; do
    printf 'detail: %s\n' "${line}"
  done
  exit 40
}

extract_artifact_path() {
  local context="$1"
  local artifact_name="$2"
  printf '%s' "${context}" | "${PYTHON_BIN}" -c '
import re
import sys

want = sys.argv[1]
for line in sys.stdin.read().splitlines():
    if want in line and "path=" in line:
        m = re.search(r"path=([^\s]+)", line)
        if m:
            print(m.group(1))
            raise SystemExit(0)
print("")
' "${artifact_name}"
}

extract_task_constitution_json() {
  local path="$1"
  awk '
    BEGIN { inside = 0 }
    /^<<<TASK_CONSTITUTION_JSON_BEGIN>>>[[:space:]]*$/ { inside = 1; next }
    /^<<<TASK_CONSTITUTION_JSON_END>>>[[:space:]]*$/   { inside = 0; next }
    inside == 1 { print }
  ' "${path}" | head -c 1 >/dev/null 2>&1
  awk '
    BEGIN { inside = 0; emitted = 0 }
    /^<<<TASK_CONSTITUTION_JSON_BEGIN>>>[[:space:]]*$/ { inside = 1; next }
    /^<<<TASK_CONSTITUTION_JSON_END>>>[[:space:]]*$/   { inside = 0; next }
    inside == 1 { print; emitted = 1 }
    END { if (emitted == 0) exit 1 }
  ' "${path}" 2>/dev/null && return 0

  awk '
    BEGIN { inside = 0; emitted = 0 }
    /^```json[[:space:]]*$/ { inside = 1; next }
    inside == 1 && /^```[[:space:]]*$/ { exit }
    inside == 1 { print; emitted = 1 }
    END { if (emitted == 0) exit 1 }
  ' "${path}"
}

validate_and_extract_ids() {
  # Validate the task constitution JSON and emit "<project_id>|<task_id>" on
  # stdout when valid. Errors go to stderr and are surfaced via exit code:
  #   0  ok
  #   2  JSON parse error
  #   3  missing required field
  #   4  invalid goal_stage
  printf '%s' "$1" | "${PYTHON_BIN}" -c '
import json
import sys

raw = sys.stdin.read()
try:
    data = json.loads(raw)
except json.JSONDecodeError as e:
    sys.stderr.write(f"PARSE_ERROR:{e}\n")
    raise SystemExit(2)

required = ["task_id", "project_id", "goal", "goal_stage", "success_criteria"]
missing = [k for k in required if k not in data or data[k] in (None, "", [])]
if missing:
    missing_list = ",".join(missing)
    sys.stderr.write(f"MISSING_REQUIRED:{missing_list}\n")
    raise SystemExit(3)

allowed_stages = {"informal_planning", "formal_specification",
                  "implementation_preparation", "implementation_and_verification"}
goal_stage = data["goal_stage"]
if goal_stage not in allowed_stages:
    sys.stderr.write(f"INVALID_GOAL_STAGE:{goal_stage}\n")
    raise SystemExit(4)

project_id = data["project_id"]
task_id = data["task_id"]
sys.stdout.write(f"{project_id}|{task_id}\n")
'
}

print_header

if [ -z "${input_context}" ]; then
  fail_with "missing_input_context" "CAP_WORKFLOW_INPUT_CONTEXT is empty"
fi

draft_path="$(extract_artifact_path "${input_context}" "task_constitution_draft")"
if [ -z "${draft_path}" ]; then
  draft_path="$(extract_artifact_path "${input_context}" "task_constitution")"
fi
if [ -z "${draft_path}" ]; then
  fail_with "missing_draft_artifact" "neither task_constitution_draft nor task_constitution found in input context"
fi
if [ ! -f "${draft_path}" ]; then
  fail_with "draft_path_not_found" "${draft_path}"
fi

json_payload="$(extract_task_constitution_json "${draft_path}")"
if [ -z "${json_payload}" ]; then
  fail_with "no_json_in_draft" "neither <<<TASK_CONSTITUTION_JSON>>> fence nor json fence found in ${draft_path}"
fi

# Capture stdout+stderr into separate streams via a temp file for stderr.
tmp_err="$(mktemp -t persist-task-constitution.err.XXXXXX)"
trap 'rm -f "${tmp_err}"' EXIT
ids="$(validate_and_extract_ids "${json_payload}" 2>"${tmp_err}")"
validation_rc=$?
if [ ${validation_rc} -ne 0 ]; then
  err_msg="$(cat "${tmp_err}")"
  fail_with "validation_failed" "${err_msg}" "rc=${validation_rc}"
fi

project_id="${ids%%|*}"
task_id="${ids##*|}"
task_id="${task_id%$'\n'}"  # strip trailing newline if any

if [ -z "${project_id}" ] || [ -z "${task_id}" ]; then
  fail_with "missing_ids" "project_id=${project_id} task_id=${task_id}"
fi

CAP_HOME="${CAP_HOME:-${HOME}/.cap}"
target_dir="${CAP_HOME}/projects/${project_id}/constitutions"
mkdir -p "${target_dir}" || fail_with "mkdir_failed" "${target_dir}"

target_path="${target_dir}/${task_id}.json"
printf '%s' "${json_payload}" > "${target_path}" || fail_with "write_failed" "${target_path}"

# Pretty-print via python for stable formatting
"${PYTHON_BIN}" - "${target_path}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
path.write_text(
    json.dumps(data, ensure_ascii=False, indent=2, sort_keys=False) + "\n",
    encoding="utf-8",
)
PY

printf -- 'condition: ok\n'
printf -- 'task_id: %s\n' "${task_id}"
printf -- 'project_id: %s\n' "${project_id}"
printf -- 'persisted_path: %s\n' "${target_path}"
printf -- '\n'
printf -- '## Output Artifacts\n\n'
printf -- '- name=task_constitution path=%s\n' "${target_path}"

exit 0
