#!/usr/bin/env bash
#
# test-persist-task-constitution.sh — Smoke test for
# scripts/workflows/persist-task-constitution.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PERSIST_SCRIPT="${REPO_ROOT}/scripts/workflows/persist-task-constitution.sh"

if [ ! -x "${PERSIST_SCRIPT}" ]; then
  echo "FAIL: ${PERSIST_SCRIPT} not executable" >&2
  exit 1
fi

SANDBOX="$(mktemp -d -t cap-test-persist.XXXXXX)"
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

run_persist() {
  local draft_path="$1"
  CAP_HOME="${SANDBOX}/cap" \
  CAP_WORKFLOW_INPUT_CONTEXT="- name=task_constitution_draft path=${draft_path}" \
  CAP_WORKFLOW_STEP_ID=test_persist \
  bash "${PERSIST_SCRIPT}" 2>&1
}

# Case 1: happy path
echo "Case 1: happy path"
cat > "${SANDBOX}/draft-good.md" <<'EOF'
<<<TASK_CONSTITUTION_JSON_BEGIN>>>
{
  "task_id": "smoke-001",
  "project_id": "smoke-proj",
  "goal": "Smoke-test the persist executor",
  "goal_stage": "formal_specification",
  "success_criteria": ["script exits 0", "file written"],
  "execution_plan": [
    {"step_id": "prd", "capability": "prd_generation"},
    {"step_id": "tech_plan", "capability": "technical_planning"}
  ],
  "governance": {"watcher_mode": "milestone_gate"}
}
<<<TASK_CONSTITUTION_JSON_END>>>
EOF
out="$(run_persist "${SANDBOX}/draft-good.md")"
rc=$?
assert_eq "exit code 0" "0" "${rc}"
assert_contains "report shows condition: ok" "condition: ok" "${out}"
assert_contains "report shows persisted_path" "persisted_path: ${SANDBOX}/cap/projects/smoke-proj/constitutions/smoke-001.json" "${out}"
assert_contains "output artifact line present" "- name=task_constitution path=${SANDBOX}/cap/projects/smoke-proj/constitutions/smoke-001.json" "${out}"
[ -f "${SANDBOX}/cap/projects/smoke-proj/constitutions/smoke-001.json" ]
assert_eq "persisted file exists" "0" "$?"

# Case 2: malformed JSON
echo "Case 2: malformed JSON"
cat > "${SANDBOX}/draft-bad-json.md" <<'EOF'
<<<TASK_CONSTITUTION_JSON_BEGIN>>>
{ this is not valid json
<<<TASK_CONSTITUTION_JSON_END>>>
EOF
out="$(run_persist "${SANDBOX}/draft-bad-json.md")"
rc=$?
assert_eq "exit code 40" "40" "${rc}"
assert_contains "PARSE_ERROR detail" "PARSE_ERROR" "${out}"

# Case 3: missing required field
echo "Case 3: missing required (task_id)"
cat > "${SANDBOX}/draft-missing.md" <<'EOF'
<<<TASK_CONSTITUTION_JSON_BEGIN>>>
{"project_id":"x","goal":"g","goal_stage":"formal_specification","success_criteria":["x"]}
<<<TASK_CONSTITUTION_JSON_END>>>
EOF
out="$(run_persist "${SANDBOX}/draft-missing.md")"
rc=$?
assert_eq "exit code 40" "40" "${rc}"
assert_contains "MISSING_REQUIRED detail" "MISSING_REQUIRED:task_id" "${out}"

# Case 4: invalid goal_stage
echo "Case 4: invalid goal_stage"
cat > "${SANDBOX}/draft-bad-stage.md" <<'EOF'
<<<TASK_CONSTITUTION_JSON_BEGIN>>>
{"task_id":"x","project_id":"p","goal":"g","goal_stage":"bogus","success_criteria":["x"]}
<<<TASK_CONSTITUTION_JSON_END>>>
EOF
out="$(run_persist "${SANDBOX}/draft-bad-stage.md")"
rc=$?
assert_eq "exit code 40" "40" "${rc}"
assert_contains "INVALID_GOAL_STAGE detail" "INVALID_GOAL_STAGE:bogus" "${out}"

# Case 5: invalid execution_plan entry
echo "Case 5: execution_plan entry missing step_id"
cat > "${SANDBOX}/draft-bad-plan.md" <<'EOF'
<<<TASK_CONSTITUTION_JSON_BEGIN>>>
{"task_id":"x","project_id":"p","goal":"g","goal_stage":"formal_specification","success_criteria":["x"],"execution_plan":[{"capability":"prd_generation"}]}
<<<TASK_CONSTITUTION_JSON_END>>>
EOF
out="$(run_persist "${SANDBOX}/draft-bad-plan.md")"
rc=$?
assert_eq "exit code 40" "40" "${rc}"
assert_contains "INVALID_EXECUTION_PLAN_ENTRY detail" "INVALID_EXECUTION_PLAN_ENTRY" "${out}"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ ${fail_count} -eq 0 ]
