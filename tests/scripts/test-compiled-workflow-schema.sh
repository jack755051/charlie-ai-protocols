#!/usr/bin/env bash
#
# test-compiled-workflow-schema.sh — Validate
# schemas/compiled-workflow.schema.yaml against positive and negative
# fixtures using step_runtime.py validate-jsonschema.
#
# Coverage:
#   Positive 1: minimal valid compiled workflow (1 step)
#   Positive 2: realistic full-spec workflow (matches
#               task_scoped_compiler output for goal_stage=formal_specification)
#   Negative 1: missing required top-level field (steps)
#   Negative 2: missing required step field (capability)
#   Negative 3: invalid version (not enum [2])
#   Negative 4: empty steps array (minItems violation)
#   Negative 5: governance.context_mode missing
#   Negative 6: governance.goal_stage not in enum
#   Negative 7: step.on_fail not in enum
#
# Per MISSING-IMPLEMENTATION-CHECKLIST P0 #2 acceptance: schema can
# validate workflow_id / steps / dependencies (steps[].needs) /
# inputs (steps[].inputs) / outputs (steps[].outputs).
# `run_id` belongs to workflow-result.schema (P0 #5) and
# `executor` belongs to binding-report.schema (P0 #3); see schema header
# for the SSOT split rationale.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCHEMA_PATH="${REPO_ROOT}/schemas/compiled-workflow.schema.yaml"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"
VENV_PY="${REPO_ROOT}/.venv/bin/python"
if [ -x "${VENV_PY}" ]; then
  PYTHON_BIN="${VENV_PY}"
else
  PYTHON_BIN="python3"
fi

[ -f "${SCHEMA_PATH}" ] || { echo "FAIL: schema not found at ${SCHEMA_PATH}"; exit 1; }
[ -f "${STEP_PY}" ]    || { echo "FAIL: step_runtime.py not found"; exit 1; }

SANDBOX="$(mktemp -d -t cap-cwf-test.XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

pass_count=0
fail_count=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
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

validate_fixture() {
  local fixture_path="$1"
  "${PYTHON_BIN}" "${STEP_PY}" validate-jsonschema "${fixture_path}" "${SCHEMA_PATH}" >/dev/null 2>&1
  echo $?
}

write_fixture() {
  local name="$1" payload="$2"
  local path="${SANDBOX}/${name}.json"
  printf '%s\n' "${payload}" > "${path}"
  printf '%s' "${path}"
}

# ── Positive 1: minimal valid compiled workflow ──────────────────────
echo "Positive 1: minimal valid compiled workflow (single step)"
fixture="$(write_fixture "pos-min" '{
  "schema_version": 1,
  "workflow_id": "compiled-smoke-min-001",
  "version": 2,
  "name": "Compiled Workflow — smoke",
  "summary": "minimal smoke fixture",
  "owner": "supervisor",
  "triggers": ["manual", "compiled"],
  "governance": {
    "goal_stage": "informal_planning",
    "context_mode": "summary_first",
    "halt_on_missing_handoff": true,
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log",
    "step_count_budget": 3,
    "max_primary_phases": 2,
    "logger_checkpoints": ["prd"]
  },
  "steps": [
    {
      "id": "prd",
      "name": "Task PRD",
      "capability": "prd_generation",
      "needs": [],
      "inputs": ["user_requirement"],
      "outputs": ["prd_document"],
      "done_when": ["PRD 摘要已產出並獲使用者確認"],
      "optional": false,
      "on_fail": "halt",
      "record_level": "trace_only",
      "input_mode": "summary",
      "output_tier": "planning_artifact",
      "continue_reason": "define goal and scope",
      "stall_action": "warn"
    }
  ]
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 0 on minimal valid compiled workflow" "0" "${rc}"

# ── Positive 2: realistic full-spec compiled workflow ────────────────
echo "Positive 2: realistic full-spec compiled workflow"
fixture="$(write_fixture "pos-fullspec" '{
  "schema_version": 1,
  "workflow_id": "compiled-token-monitor-minimal-spec",
  "version": 2,
  "name": "Compiled Workflow — token-monitor-minimal-spec",
  "summary": "Compiled from task constitution: produce minimal spec for token monitor",
  "owner": "supervisor",
  "triggers": ["manual", "compiled"],
  "governance": {
    "goal_stage": "formal_specification",
    "context_mode": "summary_first",
    "halt_on_missing_handoff": true,
    "watcher_mode": "milestone_gate",
    "logger_mode": "milestone_log",
    "watcher_checkpoints": ["spec_audit"],
    "logger_checkpoints": ["prd", "tech_plan", "archive"]
  },
  "steps": [
    {"id": "prd",        "name": "Task PRD",                     "capability": "prd_generation",      "needs": [],            "inputs": ["user_requirement"], "outputs": ["prd_document"],          "done_when": ["PRD 摘要已產出並獲使用者確認"], "optional": false, "on_fail": "halt", "record_level": "trace_only", "input_mode": "summary", "output_tier": "full_artifact", "continue_reason": "define goal and scope"},
    {"id": "tech_plan",  "name": "Task Technical Plan",          "capability": "technical_planning",  "needs": ["prd"],       "inputs": ["prd_document"],     "outputs": ["tech_plan_document"],    "done_when": ["技術選型與下游建議完成"],     "optional": false, "on_fail": "halt", "record_level": "full_log",   "input_mode": "summary", "output_tier": "full_artifact", "continue_reason": "select technical direction and identify risks"},
    {"id": "ba",         "name": "Business Analysis",            "capability": "business_analysis",   "needs": ["tech_plan"], "inputs": ["tech_plan_document"], "outputs": ["ba_spec"],            "done_when": ["業務流程與邊界已釐清"],       "optional": false, "on_fail": "halt", "record_level": "trace_only", "input_mode": "summary", "output_tier": "full_artifact", "continue_reason": "clarify workflow and edge cases"},
    {"id": "spec_audit", "name": "Spec Consistency Audit",       "capability": "tool_spec_audit",     "needs": ["tech_plan", "ba"], "inputs": ["tech_plan_document", "ba_spec"], "outputs": ["spec_audit_report"], "done_when": ["跨規格一致性已驗證"],        "optional": false, "on_fail": "halt", "record_level": "full_log",   "input_mode": "full",    "output_tier": "full_artifact", "continue_reason": "validate cross-spec consistency"},
    {"id": "archive",    "name": "Task Archive",                 "capability": "technical_logging",   "needs": ["spec_audit"], "inputs": ["spec_audit_report"], "outputs": ["archive_summary"], "done_when": ["決策鏈已歸檔"],              "optional": false, "on_fail": "halt", "record_level": "full_log",   "input_mode": "summary", "output_tier": "full_artifact", "continue_reason": "archive planning decision chain"}
  ]
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 0 on realistic full-spec workflow" "0" "${rc}"

# ── Negative 1: missing required top-level field (steps) ─────────────
echo "Negative 1: missing required top-level field (steps)"
fixture="$(write_fixture "neg-no-steps" '{
  "schema_version": 1,
  "workflow_id": "compiled-x",
  "version": 2,
  "name": "x",
  "summary": "x",
  "owner": "supervisor",
  "triggers": ["manual"],
  "governance": {
    "goal_stage": "informal_planning",
    "context_mode": "summary_first",
    "halt_on_missing_handoff": true,
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log"
  }
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when steps missing" "1" "${rc}"

# ── Negative 2: missing required step field (capability) ─────────────
echo "Negative 2: missing required step field (capability)"
fixture="$(write_fixture "neg-step-no-capability" '{
  "schema_version": 1,
  "workflow_id": "compiled-x",
  "version": 2,
  "name": "x",
  "summary": "x",
  "owner": "supervisor",
  "triggers": ["manual"],
  "governance": {
    "goal_stage": "informal_planning",
    "context_mode": "summary_first",
    "halt_on_missing_handoff": true,
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log"
  },
  "steps": [
    {"id": "prd", "name": "Task PRD", "needs": [], "inputs": [], "outputs": [], "done_when": [], "optional": false, "on_fail": "halt", "record_level": "trace_only", "input_mode": "summary", "output_tier": "planning_artifact", "continue_reason": "x"}
  ]
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when step.capability missing" "1" "${rc}"

# ── Negative 3: invalid version ──────────────────────────────────────
echo "Negative 3: invalid version (not enum [2])"
fixture="$(write_fixture "neg-bad-version" '{
  "schema_version": 1,
  "workflow_id": "compiled-x",
  "version": 99,
  "name": "x",
  "summary": "x",
  "owner": "supervisor",
  "triggers": ["manual"],
  "governance": {
    "goal_stage": "informal_planning",
    "context_mode": "summary_first",
    "halt_on_missing_handoff": true,
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log"
  },
  "steps": [
    {"id": "prd", "name": "x", "capability": "prd_generation", "needs": [], "inputs": [], "outputs": [], "done_when": [], "optional": false, "on_fail": "halt", "record_level": "trace_only", "input_mode": "summary", "output_tier": "planning_artifact", "continue_reason": "x"}
  ]
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when version not in enum" "1" "${rc}"

# ── Negative 4: empty steps array ────────────────────────────────────
echo "Negative 4: empty steps array (minItems violation)"
fixture="$(write_fixture "neg-empty-steps" '{
  "schema_version": 1,
  "workflow_id": "compiled-x",
  "version": 2,
  "name": "x",
  "summary": "x",
  "owner": "supervisor",
  "triggers": ["manual"],
  "governance": {
    "goal_stage": "informal_planning",
    "context_mode": "summary_first",
    "halt_on_missing_handoff": true,
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log"
  },
  "steps": []
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when steps is empty array" "1" "${rc}"

# ── Negative 5: governance.context_mode missing ──────────────────────
echo "Negative 5: governance.context_mode missing"
fixture="$(write_fixture "neg-gov-no-context-mode" '{
  "schema_version": 1,
  "workflow_id": "compiled-x",
  "version": 2,
  "name": "x",
  "summary": "x",
  "owner": "supervisor",
  "triggers": ["manual"],
  "governance": {
    "goal_stage": "informal_planning",
    "halt_on_missing_handoff": true,
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log"
  },
  "steps": [
    {"id": "prd", "name": "x", "capability": "prd_generation", "needs": [], "inputs": [], "outputs": [], "done_when": [], "optional": false, "on_fail": "halt", "record_level": "trace_only", "input_mode": "summary", "output_tier": "planning_artifact", "continue_reason": "x"}
  ]
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when governance.context_mode missing" "1" "${rc}"

# ── Negative 6: governance.goal_stage not in enum ────────────────────
echo "Negative 6: governance.goal_stage not in enum"
fixture="$(write_fixture "neg-gov-bad-stage" '{
  "schema_version": 1,
  "workflow_id": "compiled-x",
  "version": 2,
  "name": "x",
  "summary": "x",
  "owner": "supervisor",
  "triggers": ["manual"],
  "governance": {
    "goal_stage": "rapid_prototyping",
    "context_mode": "summary_first",
    "halt_on_missing_handoff": true,
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log"
  },
  "steps": [
    {"id": "prd", "name": "x", "capability": "prd_generation", "needs": [], "inputs": [], "outputs": [], "done_when": [], "optional": false, "on_fail": "halt", "record_level": "trace_only", "input_mode": "summary", "output_tier": "planning_artifact", "continue_reason": "x"}
  ]
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when governance.goal_stage not in enum" "1" "${rc}"

# ── Negative 7: step.on_fail not in enum ─────────────────────────────
echo "Negative 7: step.on_fail not in enum"
fixture="$(write_fixture "neg-step-bad-on-fail" '{
  "schema_version": 1,
  "workflow_id": "compiled-x",
  "version": 2,
  "name": "x",
  "summary": "x",
  "owner": "supervisor",
  "triggers": ["manual"],
  "governance": {
    "goal_stage": "informal_planning",
    "context_mode": "summary_first",
    "halt_on_missing_handoff": true,
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log"
  },
  "steps": [
    {"id": "prd", "name": "x", "capability": "prd_generation", "needs": [], "inputs": [], "outputs": [], "done_when": [], "optional": false, "on_fail": "panic", "record_level": "trace_only", "input_mode": "summary", "output_tier": "planning_artifact", "continue_reason": "x"}
  ]
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when step.on_fail not in enum" "1" "${rc}"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ ${fail_count} -eq 0 ]
