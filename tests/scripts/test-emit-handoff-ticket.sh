#!/usr/bin/env bash
#
# test-emit-handoff-ticket.sh — Smoke test for
# scripts/workflows/emit-handoff-ticket.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
EMIT_SCRIPT="${REPO_ROOT}/scripts/workflows/emit-handoff-ticket.sh"

if [ ! -x "${EMIT_SCRIPT}" ]; then
  echo "FAIL: ${EMIT_SCRIPT} not executable" >&2
  exit 1
fi

SANDBOX="$(mktemp -d -t cap-test-emit.XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

pass_count=0
fail_count=0

assert_eq() {
  local desc="$1"
  local expected="$2"
  local actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected: ${expected}"
    echo "    actual:   ${actual}"
    fail_count=$((fail_count + 1))
  fi
}

assert_contains() {
  local desc="$1"
  local needle="$2"
  local haystack="$3"
  if printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected to contain: ${needle}"
    echo "    actual: ${haystack}"
    fail_count=$((fail_count + 1))
  fi
}

# Pre-stage: create a real task constitution file using the persist script
PERSIST_SCRIPT="${REPO_ROOT}/scripts/workflows/persist-task-constitution.sh"
cat > "${SANDBOX}/draft.md" <<'EOF'
<<<TASK_CONSTITUTION_JSON_BEGIN>>>
{
  "task_id": "emit-smoke-001",
  "project_id": "emit-smoke-proj",
  "goal": "Smoke-test the emit executor",
  "goal_stage": "formal_specification",
  "success_criteria": ["ticket emitted", "schema valid"],
  "execution_plan": [
    {"step_id": "prd", "capability": "prd_generation", "bound_to": "01-supervisor"},
    {"step_id": "tech_plan", "capability": "technical_planning", "bound_to": "02-techlead"}
  ],
  "governance": {"watcher_mode": "milestone_gate", "watcher_checkpoints": ["spec_audit"], "budget_sub_agent_sessions": 6}
}
<<<TASK_CONSTITUTION_JSON_END>>>
EOF

CAP_HOME="${SANDBOX}/cap" \
CAP_PROJECT_ID_OVERRIDE="emit-smoke-proj" \
CAP_WORKFLOW_INPUT_CONTEXT="- name=task_constitution_draft path=${SANDBOX}/draft.md" \
bash "${PERSIST_SCRIPT}" > /dev/null 2>&1
TC_PATH="${SANDBOX}/cap/projects/emit-smoke-proj/constitutions/emit-smoke-001.json"

if [ ! -f "${TC_PATH}" ]; then
  echo "FAIL: pre-stage persist did not produce ${TC_PATH}" >&2
  exit 1
fi

run_emit() {
  local target_step="$1"
  local tc_path="${2:-${TC_PATH}}"
  CAP_HOME="${SANDBOX}/cap" \
  CAP_PROJECT_ID_OVERRIDE="emit-smoke-proj" \
  CAP_TASK_CONSTITUTION_PATH="${tc_path}" \
  CAP_TARGET_STEP_ID="${target_step}" \
  CAP_WORKFLOW_STEP_ID=test_emit \
  bash "${EMIT_SCRIPT}" 2>&1
}

# Case 1: happy path
echo "Case 1: happy path"
out="$(run_emit "prd")"
rc=$?
assert_eq "exit code 0" "0" "${rc}"
assert_contains "condition ok" "condition: ok" "${out}"
ticket_path="${SANDBOX}/cap/projects/emit-smoke-proj/handoffs/prd.ticket.json"
[ -f "${ticket_path}" ]
assert_eq "ticket file exists" "0" "$?"
assert_contains "output artifact line" "- name=handoff_ticket path=${ticket_path}" "${out}"
# Validate ticket structure roughly via python
ticket_check="$(python3 - "${ticket_path}" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
required = ["ticket_id","task_id","step_id","created_at","created_by",
            "target_capability","task_objective","rules_to_load",
            "context_payload","acceptance_criteria","output_expectations",
            "failure_routing"]
missing = [k for k in required if k not in data]
print("MISSING:" + ",".join(missing) if missing else "OK")
PY
)"
assert_eq "ticket has all top-level required fields" "OK" "${ticket_check}"
ticket_id="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['ticket_id'])" "${ticket_path}")"
assert_eq "ticket_id seq=1" "emit-smoke-001-prd-1" "${ticket_id}"

# Case 2: seq increment
echo "Case 2: seq increment"
out="$(run_emit "prd")"
rc=$?
assert_eq "exit code 0" "0" "${rc}"
ticket_path_2="${SANDBOX}/cap/projects/emit-smoke-proj/handoffs/prd-2.ticket.json"
[ -f "${ticket_path_2}" ]
assert_eq "second ticket file exists" "0" "$?"
ticket_id_2="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['ticket_id'])" "${ticket_path_2}")"
assert_eq "ticket_id seq=2" "emit-smoke-001-prd-2" "${ticket_id_2}"
out="$(run_emit "prd")"
ticket_path_3="${SANDBOX}/cap/projects/emit-smoke-proj/handoffs/prd-3.ticket.json"
[ -f "${ticket_path_3}" ]
assert_eq "third ticket file exists" "0" "$?"
[ -f "${ticket_path}" ]
assert_eq "first ticket still preserved (audit trail)" "0" "$?"

# Case 3: missing target_step_id
echo "Case 3: missing target_step_id env"
out="$(CAP_HOME="${SANDBOX}/cap" CAP_TASK_CONSTITUTION_PATH="${TC_PATH}" bash "${EMIT_SCRIPT}" 2>&1)"
rc=$?
assert_eq "exit code 40" "40" "${rc}"
assert_contains "missing_target_step_id detail" "missing_target_step_id" "${out}"

# Case 4: target step not in execution_plan
echo "Case 4: target step not in execution_plan"
out="$(run_emit "ghost_step")"
rc=$?
assert_eq "exit code 40" "40" "${rc}"
assert_contains "step_not_in_execution_plan detail" "step_not_in_execution_plan" "${out}"

# Case 5: runtime project identity wins over a drifted task_constitution project_id.
echo "Case 5: project_id drift warning and runtime handoff path"
DRIFT_TC="${SANDBOX}/drift-task-constitution.json"
python3 - "${TC_PATH}" "${DRIFT_TC}" <<'PY'
import json
import sys
from pathlib import Path

src, dst = map(Path, sys.argv[1:])
data = json.loads(src.read_text(encoding="utf-8"))
data["project_id"] = "supervisor-guessed-id"
dst.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
out="$(run_emit "tech_plan" "${DRIFT_TC}")"
rc=$?
assert_eq "exit code 0 with project_id drift" "0" "${rc}"
assert_contains "project drift warning emitted" "governance_warning: project_id_drift" "${out}"
drift_ticket="${SANDBOX}/cap/projects/emit-smoke-proj/handoffs/tech_plan.ticket.json"
[ -f "${drift_ticket}" ]
assert_eq "ticket written under runtime project id" "0" "$?"
assert_contains "output artifact uses runtime project path" "- name=handoff_ticket path=${drift_ticket}" "${out}"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ ${fail_count} -eq 0 ]
