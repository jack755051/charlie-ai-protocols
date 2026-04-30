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
assert_eq "exit code 41" "41" "${rc}"
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
assert_eq "exit code 41" "41" "${rc}"
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
assert_eq "exit code 41" "41" "${rc}"
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
assert_eq "exit code 41" "41" "${rc}"
assert_contains "INVALID_EXECUTION_PLAN_ENTRY detail" "INVALID_EXECUTION_PLAN_ENTRY" "${out}"

# Case 6: normalize fills `goal` from `task_summary` alias.
# Reproduces the supervisor-draft shape that real cap workflow run hit on
# 2026-04-30: top-level `task_summary` instead of `goal`,
# `user_intent_excerpt` instead of `source_request`, and `target_capability`
# instead of `capability` inside execution_plan entries. Use goal_stage
# informal_planning so the canonical project-spec-pipeline plan replacement
# (which expects six fixed steps) does not kick in for this fixture.
echo "Case 6: normalize lifts task_summary into canonical goal field"
cat > "${SANDBOX}/draft-task-summary.md" <<'EOF'
<<<TASK_CONSTITUTION_JSON_BEGIN>>>
{
  "task_id": "alias-test",
  "project_id": "alias-proj",
  "task_summary": "Verify normalizer maps task_summary → goal so legacy supervisor drafts persist cleanly.",
  "goal_stage": "informal_planning",
  "user_intent_excerpt": "make sure goal alias works",
  "success_criteria": ["normalize maps aliases without halt"],
  "execution_plan": [
    {"step_id": "prd", "target_capability": "prd_generation"}
  ]
}
<<<TASK_CONSTITUTION_JSON_END>>>
EOF
out="$(run_persist "${SANDBOX}/draft-task-summary.md")"
rc=$?
assert_eq "exit code 0 with task_summary alias" "0" "${rc}"
persisted="${SANDBOX}/cap/projects/alias-proj/constitutions/alias-test.json"
[ -f "${persisted}" ]
assert_eq "persisted file exists for alias case" "0" "$?"
goal_value="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('goal',''))" "${persisted}")"
assert_eq "goal field populated from task_summary" "Verify normalizer maps task_summary → goal so legacy supervisor drafts persist cleanly." "${goal_value}"
source_request_value="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('source_request',''))" "${persisted}")"
assert_eq "source_request populated from user_intent_excerpt" "make sure goal alias works" "${source_request_value}"
capability_value="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['execution_plan'][0].get('capability',''))" "${persisted}")"
assert_eq "execution_plan capability normalized from target_capability" "prd_generation" "${capability_value}"

# Case 7: normalize coerces risk_profile object form into the schema enum string.
# Reproduces the supervisor draft shape that real cap workflow run hit on
# 2026-05-01: top-level `risk_profile` was {"level":"medium","key_risks":[...]}
# but schema requires type=string with enum [low,medium,high,unknown]. The
# normalizer must keep level and drop sub-fields so persist does not halt.
echo "Case 7: normalize coerces risk_profile object form to enum string"
cat > "${SANDBOX}/draft-risk-object.md" <<'EOF'
<<<TASK_CONSTITUTION_JSON_BEGIN>>>
{
  "task_id": "risk-obj",
  "project_id": "risk-proj",
  "goal": "Verify risk_profile object is collapsed to level string.",
  "goal_stage": "informal_planning",
  "success_criteria": ["risk_profile becomes a schema-valid string"],
  "risk_profile": {"level": "medium", "key_risks": ["ignored sub-field"]},
  "execution_plan": [
    {"step_id": "prd", "capability": "prd_generation"}
  ]
}
<<<TASK_CONSTITUTION_JSON_END>>>
EOF
out="$(run_persist "${SANDBOX}/draft-risk-object.md")"
rc=$?
assert_eq "exit code 0 with risk_profile object" "0" "${rc}"
persisted="${SANDBOX}/cap/projects/risk-proj/constitutions/risk-obj.json"
risk_value="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('risk_profile',''))" "${persisted}")"
assert_eq "risk_profile collapsed to level string" "medium" "${risk_value}"

# Case 8: normalize ensures non_goals is always an array even when omitted.
# parity-check (PROVIDER-PARITY-E2E §4.2) treats missing non_goals as a real
# FAIL. The normalizer should default it to [] so downstream gates see a
# schema-valid array rather than null/absent.
echo "Case 8: normalize defaults missing non_goals to []"
cat > "${SANDBOX}/draft-no-non-goals.md" <<'EOF'
<<<TASK_CONSTITUTION_JSON_BEGIN>>>
{
  "task_id": "no-ng",
  "project_id": "no-ng-proj",
  "goal": "Verify normalize defaults non_goals to empty array.",
  "goal_stage": "informal_planning",
  "success_criteria": ["non_goals is array even when supervisor omits it"],
  "execution_plan": [
    {"step_id": "prd", "capability": "prd_generation"}
  ]
}
<<<TASK_CONSTITUTION_JSON_END>>>
EOF
out="$(run_persist "${SANDBOX}/draft-no-non-goals.md")"
rc=$?
assert_eq "exit code 0 without non_goals" "0" "${rc}"
persisted="${SANDBOX}/cap/projects/no-ng-proj/constitutions/no-ng.json"
non_goals_type="$(python3 -c "import json,sys; print(type(json.load(open(sys.argv[1])).get('non_goals')).__name__)" "${persisted}")"
assert_eq "non_goals normalized to list type" "list" "${non_goals_type}"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ ${fail_count} -eq 0 ]
