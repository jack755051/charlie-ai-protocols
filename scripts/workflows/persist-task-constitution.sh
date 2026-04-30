#!/usr/bin/env bash
#
# persist-task-constitution.sh — Pipeline step: validate the AI-drafted Task
# Constitution JSON and persist it to the canonical runtime location.
#
# Reads:
#   - task_constitution_draft artifact path (from CAP_WORKFLOW_INPUT_CONTEXT)
#   - upstream draft must contain JSON either in a <<<TASK_CONSTITUTION_JSON_BEGIN>>>
#     fence or in a ```json fenced block.
#
# Validation:
#   1. Inline minimal structural validation (fast-fail before write):
#      - JSON parses cleanly
#      - Required fields present and non-empty: task_id, project_id, goal,
#        goal_stage, success_criteria
#      - goal_stage is one of the four enum values
#      - execution_plan, if present, is a non-empty array; each entry has
#        step_id and capability
#      - governance, if present, is an object
#   2. Full JSON Schema validation (post-write):
#      - Delegates to engine/step_runtime.py validate-jsonschema against
#        schemas/task-constitution.schema.yaml
#      - Catches type errors, enum violations, and nested object shape issues
#        that the minimal pass cannot see.
#
# Behavior:
#   - Locate the draft path from upstream context.
#   - Extract the JSON payload.
#   - Run minimal structural validation (above).
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
    /^<<<TASK_CONSTITUTION_JSON_END>>>[[:space:]]*$/   { exit }
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

# Optional structural checks for nested objects that downstream steps depend on.
exec_plan = data.get("execution_plan")
if exec_plan is not None:
    if not isinstance(exec_plan, list) or not exec_plan:
        sys.stderr.write("INVALID_EXECUTION_PLAN:must be non-empty array if present\n")
        raise SystemExit(5)
    for idx, entry in enumerate(exec_plan):
        if not isinstance(entry, dict):
            sys.stderr.write(f"INVALID_EXECUTION_PLAN_ENTRY:index={idx} not an object\n")
            raise SystemExit(5)
        for required_field in ("step_id", "capability"):
            if not entry.get(required_field):
                sys.stderr.write(
                    f"INVALID_EXECUTION_PLAN_ENTRY:index={idx} missing {required_field}\n"
                )
                raise SystemExit(5)

governance = data.get("governance")
if governance is not None and not isinstance(governance, dict):
    sys.stderr.write("INVALID_GOVERNANCE:must be object if present\n")
    raise SystemExit(6)

project_id = data["project_id"]
task_id = data["task_id"]
sys.stdout.write(f"{project_id}|{task_id}\n")
'
}

normalize_task_constitution_json() {
  printf '%s' "$1" | "${PYTHON_BIN}" -c '
import json
import re
import sys

raw = sys.stdin.read()
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    sys.stdout.write(raw)
    raise SystemExit(0)

def first_string(*values):
    for value in values:
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""

def string_list(value):
    if isinstance(value, list):
        return [str(item) for item in value if str(item).strip()]
    if isinstance(value, str) and value.strip():
        return [value.strip()]
    return []

def slug(value):
    value = re.sub(r"[^A-Za-z0-9_.-]+", "-", value).strip("-")
    return value or "task"

user_intent = data.get("user_intent") if isinstance(data.get("user_intent"), dict) else {}
scope = data.get("scope") if isinstance(data.get("scope"), dict) else {}

data["task_id"] = first_string(
    data.get("task_id"),
    data.get("task_constitution_id"),
    data.get("id"),
)
if data["task_id"]:
    data["task_id"] = slug(data["task_id"])

data["source_request"] = first_string(
    data.get("source_request"),
    data.get("user_intent_excerpt"),
    user_intent.get("raw"),
    user_intent.get("normalized"),
)

data["goal"] = first_string(
    data.get("goal"),
    data.get("task_goal"),
    data.get("task_summary"),
    data.get("objective"),
    data.get("summary"),
    user_intent.get("normalized"),
    user_intent.get("raw"),
)

if isinstance(scope, dict):
    data["scope"] = string_list(scope.get("in_scope"))
    data["non_goals"] = string_list(scope.get("out_of_scope"))
elif "scope" not in data:
    data["scope"] = string_list(data.get("scope_in"))
if "non_goals" not in data:
    data["non_goals"] = string_list(data.get("scope_out"))

data["success_criteria"] = string_list(
    data.get("success_criteria")
    or data.get("completion_criteria")
    or data.get("completion_criteria_global")
    or data.get("acceptance_criteria")
    or data.get("acceptance_criteria_global")
)

if "constraints" not in data:
    data["constraints"] = string_list(data.get("inherited_constraints"))
if "stop_conditions" not in data:
    data["stop_conditions"] = string_list(data.get("inherited_stop_conditions"))

plan = data.get("execution_plan")
if isinstance(plan, list):
    for entry in plan:
        if not isinstance(entry, dict):
            continue
        entry["capability"] = first_string(entry.get("capability"), entry.get("target_capability"))
        routing = entry.get("failure_routing") if isinstance(entry.get("failure_routing"), dict) else {}
        if "on_fail" not in entry and routing.get("on_fail"):
            entry["on_fail"] = routing.get("on_fail")
        if "route_back_to" not in entry and routing.get("route_back_to_step"):
            entry["route_back_to"] = routing.get("route_back_to_step")
        if "done_when" not in entry and entry.get("acceptance_criteria"):
            entry["done_when"] = entry.get("acceptance_criteria")
        if "output_paths" not in entry and entry.get("outputs"):
            entry["output_paths"] = entry.get("outputs")

if not data["success_criteria"] and isinstance(plan, list):
    derived_success = []
    for entry in plan:
        if not isinstance(entry, dict):
            continue
        step_id = first_string(entry.get("step_id"), entry.get("capability"), entry.get("target_capability"))
        criteria = string_list(entry.get("acceptance_criteria") or entry.get("done_when"))
        if criteria:
            derived_success.append(f"{step_id}: " + "; ".join(criteria[:3]))
    data["success_criteria"] = derived_success

is_project_spec_pipeline = (
    data.get("workflow_id") == "project-spec-pipeline"
    or (
        data.get("goal_stage") == "formal_specification"
        and isinstance(data.get("execution_plan"), list)
        and all(
            isinstance(entry, dict) and entry.get("step_id")
            for entry in data.get("execution_plan", [])
        )
    )
)

if is_project_spec_pipeline:
    expected = [
        ("prd", "prd_generation", "01-Supervisor"),
        ("tech_plan", "technical_planning", "02-TechLead"),
        ("ba", "business_analysis", "02a-BA"),
        ("dba_api", "database_api_design", "02b-DBA"),
        ("ui", "ui_design", "03-UI"),
        ("spec_audit", "code_structure_audit", "90-Watcher"),
    ]
    by_cap = {
        entry.get("capability"): entry
        for entry in data.get("execution_plan", [])
        if isinstance(entry, dict) and entry.get("capability")
    }
    by_id = {
        entry.get("step_id"): entry
        for entry in data.get("execution_plan", [])
        if isinstance(entry, dict) and entry.get("step_id")
    }
    if any(step_id not in by_id for step_id, _, _ in expected):
        canonical = []
        for step_id, capability, bound_to in expected:
            source = by_id.get(step_id) or by_cap.get(capability) or {}
            canonical.append({
                "step_id": step_id,
                "capability": capability,
                "bound_to": source.get("bound_to") or bound_to,
                "needs": source.get("needs") if isinstance(source.get("needs"), list) else [],
                "on_fail": source.get("on_fail") or "halt",
                "route_back_to": source.get("route_back_to") or "",
                "objective": source.get("objective") or f"Produce {step_id} artifact for project-spec-pipeline.",
                "acceptance_criteria": string_list(source.get("acceptance_criteria") or source.get("done_when")),
                "done_when": string_list(source.get("done_when") or source.get("acceptance_criteria")),
            })
        data["execution_plan"] = canonical

print(json.dumps(data, ensure_ascii=False))
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
json_payload="$(normalize_task_constitution_json "${json_payload}")" || {
  fail_with "normalization_failed" "could not normalize task constitution draft"
}

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

# Full JSON Schema validation against schemas/task-constitution.schema.yaml
# via engine/step_runtime.py validate-jsonschema. Catches type / enum / nested
# shape issues that the minimal pre-write pass cannot see.
SCHEMA_PATH="${CAP_ROOT}/schemas/task-constitution.schema.yaml"
STEP_PY="${CAP_ROOT}/engine/step_runtime.py"
if [ -f "${SCHEMA_PATH}" ] && [ -f "${STEP_PY}" ]; then
  schema_result="$("${PYTHON_BIN}" "${STEP_PY}" validate-jsonschema "${target_path}" "${SCHEMA_PATH}" 2>&1)"
  schema_rc=$?
  if [ ${schema_rc} -ne 0 ]; then
    fail_with "schema_validation_failed" "${schema_result}"
  fi
fi

printf -- 'condition: ok\n'
printf -- 'task_id: %s\n' "${task_id}"
printf -- 'project_id: %s\n' "${project_id}"
printf -- 'persisted_path: %s\n' "${target_path}"
printf -- '\n'
printf -- '## Output Artifacts\n\n'
printf -- '- name=task_constitution path=%s\n' "${target_path}"

exit 0
