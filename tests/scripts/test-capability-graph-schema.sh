#!/usr/bin/env bash
#
# test-capability-graph-schema.sh — Validate schemas/capability-graph.schema.yaml
# against a positive fixture and several negative fixtures, asserting that
# step_runtime.py validate-jsonschema correctly accepts / rejects each.
#
# Coverage:
#   Positive 1: minimal valid graph (1 root node)
#   Positive 2: realistic full-spec graph (matches task_scoped_compiler output)
#   Negative 1: missing required top-level field (nodes)
#   Negative 2: missing required node field (reason)
#   Negative 3: invalid goal_stage enum
#   Negative 4: nodes empty array (violates minItems: 1)
#   Negative 5: depends_on item is non-string
#   Negative 6: schema_version not in enum
#
# Per MISSING-IMPLEMENTATION-CHECKLIST P0 acceptance: schema can validate
# nodes / edges / required / depends_on / reason.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCHEMA_PATH="${REPO_ROOT}/schemas/capability-graph.schema.yaml"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"
VENV_PY="${REPO_ROOT}/.venv/bin/python"
if [ -x "${VENV_PY}" ]; then
  PYTHON_BIN="${VENV_PY}"
else
  PYTHON_BIN="python3"
fi

[ -f "${SCHEMA_PATH}" ] || { echo "FAIL: schema not found at ${SCHEMA_PATH}"; exit 1; }
[ -f "${STEP_PY}" ]    || { echo "FAIL: step_runtime.py not found"; exit 1; }

SANDBOX="$(mktemp -d -t cap-capgraph-test.XXXXXX)"
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

# Run validate-jsonschema; returns the exit code.
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

# ── Positive 1: minimal valid graph ─────────────────────────────────
echo "Positive 1: minimal valid graph (single root node)"
fixture="$(write_fixture "pos-min" '{
  "schema_version": 1,
  "task_id": "smoke-min-001",
  "goal_stage": "informal_planning",
  "nodes": [
    {
      "step_id": "prd",
      "capability": "prd_generation",
      "required": true,
      "depends_on": [],
      "reason": "define goal and scope"
    }
  ]
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 0 on minimal valid graph" "0" "${rc}"

# ── Positive 2: realistic full-spec graph ───────────────────────────
echo "Positive 2: realistic full-spec graph (matches task_scoped_compiler output)"
fixture="$(write_fixture "pos-fullspec" '{
  "schema_version": 1,
  "task_id": "token-monitor-minimal-spec",
  "goal_stage": "formal_specification",
  "nodes": [
    {"step_id": "prd",        "capability": "prd_generation",      "required": true, "depends_on": [],            "reason": "define goal and scope"},
    {"step_id": "tech_plan",  "capability": "technical_planning",  "required": true, "depends_on": ["prd"],       "reason": "select technical direction and identify risks"},
    {"step_id": "ba",         "capability": "business_analysis",   "required": true, "depends_on": ["tech_plan"], "reason": "clarify workflow and edge cases"},
    {"step_id": "dba_api",    "capability": "database_api_design", "required": true, "depends_on": ["ba"],        "reason": "materialize data and interface contracts"},
    {"step_id": "ui",         "capability": "ui_design",           "required": true, "depends_on": ["ba", "dba_api"], "reason": "define interaction surface"},
    {"step_id": "spec_audit", "capability": "tool_spec_audit",     "required": true, "depends_on": ["tech_plan", "ba", "dba_api", "ui"], "reason": "validate cross-spec consistency"},
    {"step_id": "archive",    "capability": "technical_logging",   "required": true, "depends_on": ["spec_audit"], "reason": "archive planning decision chain"}
  ]
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 0 on realistic full-spec graph" "0" "${rc}"

# ── Negative 1: missing required top-level field (nodes) ────────────
echo "Negative 1: missing required top-level field (nodes)"
fixture="$(write_fixture "neg-no-nodes" '{
  "schema_version": 1,
  "task_id": "smoke-001",
  "goal_stage": "formal_specification"
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when nodes missing" "1" "${rc}"

# ── Negative 2: missing required node field (reason) ────────────────
echo "Negative 2: missing required node field (reason)"
fixture="$(write_fixture "neg-no-reason" '{
  "schema_version": 1,
  "task_id": "smoke-001",
  "goal_stage": "formal_specification",
  "nodes": [
    {"step_id": "prd", "capability": "prd_generation", "required": true, "depends_on": []}
  ]
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when node.reason missing" "1" "${rc}"

# ── Negative 3: invalid goal_stage enum ─────────────────────────────
echo "Negative 3: invalid goal_stage enum"
fixture="$(write_fixture "neg-bad-stage" '{
  "schema_version": 1,
  "task_id": "smoke-001",
  "goal_stage": "rapid_prototyping",
  "nodes": [
    {"step_id": "prd", "capability": "prd_generation", "required": true, "depends_on": [], "reason": "x"}
  ]
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when goal_stage not in enum" "1" "${rc}"

# ── Negative 4: nodes empty array (violates minItems: 1) ────────────
echo "Negative 4: nodes empty array"
fixture="$(write_fixture "neg-empty-nodes" '{
  "schema_version": 1,
  "task_id": "smoke-001",
  "goal_stage": "formal_specification",
  "nodes": []
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when nodes is empty array (minItems violation)" "1" "${rc}"

# ── Negative 5: depends_on item is non-string ───────────────────────
echo "Negative 5: depends_on item is non-string"
fixture="$(write_fixture "neg-bad-edge" '{
  "schema_version": 1,
  "task_id": "smoke-001",
  "goal_stage": "formal_specification",
  "nodes": [
    {"step_id": "prd",       "capability": "prd_generation",     "required": true, "depends_on": [],    "reason": "x"},
    {"step_id": "tech_plan", "capability": "technical_planning", "required": true, "depends_on": [42],  "reason": "y"}
  ]
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when depends_on item is not a string" "1" "${rc}"

# ── Negative 6: schema_version not in enum ──────────────────────────
echo "Negative 6: schema_version not in enum"
fixture="$(write_fixture "neg-bad-version" '{
  "schema_version": 99,
  "task_id": "smoke-001",
  "goal_stage": "formal_specification",
  "nodes": [
    {"step_id": "prd", "capability": "prd_generation", "required": true, "depends_on": [], "reason": "x"}
  ]
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when schema_version unsupported" "1" "${rc}"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ ${fail_count} -eq 0 ]
