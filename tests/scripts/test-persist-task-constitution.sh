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
  if grep -qF -- "${needle}" <<<"${haystack}"; then
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
  local project_id_override="${2:-}"
  CAP_HOME="${SANDBOX}/cap" \
  CAP_PROJECT_ID_OVERRIDE="${project_id_override}" \
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
out="$(run_persist "${SANDBOX}/draft-good.md" "smoke-proj")"
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
out="$(run_persist "${SANDBOX}/draft-bad-json.md" "x")"
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
out="$(run_persist "${SANDBOX}/draft-missing.md" "x")"
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
out="$(run_persist "${SANDBOX}/draft-bad-stage.md" "p")"
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
out="$(run_persist "${SANDBOX}/draft-bad-plan.md" "p")"
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
out="$(run_persist "${SANDBOX}/draft-task-summary.md" "alias-proj")"
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
out="$(run_persist "${SANDBOX}/draft-risk-object.md" "risk-proj")"
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
out="$(run_persist "${SANDBOX}/draft-no-non-goals.md" "no-ng-proj")"
rc=$?
assert_eq "exit code 0 without non_goals" "0" "${rc}"
persisted="${SANDBOX}/cap/projects/no-ng-proj/constitutions/no-ng.json"
non_goals_type="$(python3 -c "import json,sys; print(type(json.load(open(sys.argv[1])).get('non_goals')).__name__)" "${persisted}")"
assert_eq "non_goals normalized to list type" "list" "${non_goals_type}"

# Case 9: runtime project identity wins over supervisor-drafted project_id.
# Reproduces R3: supervisor can draft a different project_id than the current
# CAP runtime project, but storage must not split into two CAP homes.
echo "Case 9: normalize aligns project_id to cap-paths runtime identity"
cat > "${SANDBOX}/draft-project-drift.md" <<'EOF'
<<<TASK_CONSTITUTION_JSON_BEGIN>>>
{
  "task_id": "project-drift",
  "project_id": "supervisor-guessed-id",
  "goal": "Verify runtime project identity is authoritative.",
  "goal_stage": "informal_planning",
  "success_criteria": ["project_id is rewritten to runtime identity"],
  "execution_plan": [
    {"step_id": "prd", "capability": "prd_generation"}
  ]
}
<<<TASK_CONSTITUTION_JSON_END>>>
EOF
out="$(run_persist "${SANDBOX}/draft-project-drift.md" "runtime-project")"
rc=$?
assert_eq "exit code 0 with project_id drift" "0" "${rc}"
assert_contains "project drift warning emitted" "governance_warning: project_id_drift" "${out}"
assert_contains "runtime project_id reported" "runtime_project_id: runtime-project" "${out}"
persisted="${SANDBOX}/cap/projects/runtime-project/constitutions/project-drift.json"
[ -f "${persisted}" ]
assert_eq "persisted under runtime project id" "0" "$?"
normalized_project_id="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('project_id',''))" "${persisted}")"
assert_eq "project_id rewritten in persisted JSON" "runtime-project" "${normalized_project_id}"

# Case 10: explicit task constitution fence may contain a nested markdown
# ```json block. Claude parity run 2026-05-01 produced this shape; persist
# must strip the markdown fence before JSON parsing.
echo "Case 10: strip nested json fence inside explicit task constitution fence"
cat > "${SANDBOX}/draft-nested-json-fence.md" <<'EOF'
<<<TASK_CONSTITUTION_JSON_BEGIN>>>
```json
{
  "task_id": "nested-fence",
  "project_id": "nested-proj",
  "goal": "Verify nested markdown json fence is accepted.",
  "goal_stage": "informal_planning",
  "success_criteria": ["nested fence is stripped before parse"],
  "execution_plan": [
    {"step_id": "prd", "capability": "prd_generation"}
  ]
}
```
<<<TASK_CONSTITUTION_JSON_END>>>
EOF
out="$(run_persist "${SANDBOX}/draft-nested-json-fence.md" "nested-proj")"
rc=$?
assert_eq "exit code 0 with nested json fence" "0" "${rc}"
persisted="${SANDBOX}/cap/projects/nested-proj/constitutions/nested-fence.json"
[ -f "${persisted}" ]
assert_eq "persisted file exists for nested fence case" "0" "$?"
goal_value="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('goal',''))" "${persisted}")"
assert_eq "nested fence JSON parsed" "Verify nested markdown json fence is accepted." "${goal_value}"

# Case 11: normalize splits compound on_fail "route_back_to:<step_id>".
#
# Reproduces the 2026-05-13 component-feedback-widget dogfood failure
# (run run_20260513110312_2052b7a8) where the supervisor emitted
# ``on_fail: "route_back_to:step_03_backend_impl"`` instead of the
# canonical split form. Without the normalize split, persist halts with
# schema_validation_failed because schemas/task-constitution.schema.yaml
# restricts on_fail to enum [halt, route_back_to, retry, escalate_user].
#
# Expected: normalize splits the compound into on_fail="route_back_to" +
# route_back_to="step_03_backend_impl", persist exits 0, and the
# persisted JSON carries the canonical shape.
echo "Case 11: normalize splits compound on_fail route_back_to:<step_id>"
cat > "${SANDBOX}/draft-compound-on-fail.md" <<'EOF'
<<<TASK_CONSTITUTION_JSON_BEGIN>>>
{
  "task_id": "compound-on-fail",
  "project_id": "compound-proj",
  "source_request": "ship a feature with backend then frontend",
  "goal": "Ship the feature with the canonical backend-then-frontend slice.",
  "goal_stage": "implementation_and_verification",
  "success_criteria": ["both impl steps pass watcher"],
  "non_goals": [],
  "execution_plan": [
    {
      "step_id": "step_03_backend_impl",
      "capability": "backend_implementation"
    },
    {
      "step_id": "step_04_frontend_impl",
      "capability": "frontend_implementation",
      "on_fail": "route_back_to:step_03_backend_impl"
    }
  ]
}
<<<TASK_CONSTITUTION_JSON_END>>>
EOF
out="$(run_persist "${SANDBOX}/draft-compound-on-fail.md" "compound-proj")"
rc=$?
assert_eq "exit code 0 with compound on_fail split" "0" "${rc}"
persisted="${SANDBOX}/cap/projects/compound-proj/constitutions/compound-on-fail.json"
[ -f "${persisted}" ]
assert_eq "persisted file exists for compound on_fail case" "0" "$?"
on_fail_value="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print([e for e in d['execution_plan'] if e.get('step_id')=='frontend'][0].get('on_fail',''))" "${persisted}")"
assert_eq "on_fail split to enum value" "route_back_to" "${on_fail_value}"
route_back_value="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print([e for e in d['execution_plan'] if e.get('step_id')=='frontend'][0].get('route_back_to',''))" "${persisted}")"
assert_eq "route_back_to lifted and canonicalized to sibling field" "backend" "${route_back_value}"

# Case 12: implementation pipeline dynamic step ids canonicalize to fixed
# workflow step ids. Dogfood run run_20260513114937_febc776f passed
# persist, then emit_backend_ticket halted with
# step_not_in_execution_plan:backend because the drafted plan used
# step_02_backend_module / step_03_frontend_core instead of backend /
# frontend.
echo "Case 12: implementation execution_plan canonicalizes to fixed workflow ids"
cat > "${SANDBOX}/draft-implementation-canonical.md" <<'EOF'
<<<TASK_CONSTITUTION_JSON_BEGIN>>>
{
  "task_id": "impl-canonical",
  "project_id": "impl-canonical-proj",
  "source_request": "implement a component repo",
  "goal": "Implement a component repo.",
  "goal_stage": "implementation_and_verification",
  "success_criteria": ["implementation pipeline can emit tickets"],
  "execution_plan": [
    {
      "step_id": "step_02_backend_module",
      "capability": "backend_implementation",
      "objective": "Implement backend/Feedback with IFeedbackStore.",
      "acceptance_criteria": ["backend/Feedback exists"],
      "output_paths": ["backend/Feedback/"]
    },
    {
      "step_id": "step_03_frontend_core",
      "capability": "frontend_implementation",
      "objective": "Implement frontend/lib/feedback core.",
      "acceptance_criteria": ["frontend/lib/feedback exists"],
      "output_paths": ["frontend/lib/feedback/"]
    },
    {
      "step_id": "step_04_frontend_components",
      "capability": "frontend_implementation",
      "objective": "Implement frontend/components/feedback adapter.",
      "acceptance_criteria": ["frontend/components/feedback exists"],
      "output_paths": ["frontend/components/feedback/"]
    },
    {
      "step_id": "step_05_runtime_infra",
      "capability": "devops_setup",
      "objective": "Produce docker-compose and runtime smoke.",
      "output_paths": ["docker-compose.yml", "scripts/runtime-smoke.sh"]
    },
    {
      "step_id": "step_06_impl_audit",
      "capability": "impl_audit",
      "objective": "Audit implementation structure."
    },
    {
      "step_id": "step_07_security_audit",
      "capability": "security_audit",
      "objective": "Audit implementation security."
    },
    {
      "step_id": "step_08_qa_smoke",
      "capability": "qa_audit",
      "objective": "Run runtime smoke QA."
    }
  ]
}
<<<TASK_CONSTITUTION_JSON_END>>>
EOF
out="$(run_persist "${SANDBOX}/draft-implementation-canonical.md" "impl-canonical-proj")"
rc=$?
assert_eq "exit code 0 with implementation canonicalization" "0" "${rc}"
persisted="${SANDBOX}/cap/projects/impl-canonical-proj/constitutions/impl-canonical.json"
ids_csv="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(','.join(e.get('step_id','') for e in d['execution_plan']))" "${persisted}")"
assert_eq "canonical implementation step ids" "frontend,backend,qa_testing,security_audit,devops_packaging,impl_audit,archive" "${ids_csv}"
frontend_outputs="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(','.join(i.get('path','') for e in d['execution_plan'] if e.get('step_id')=='frontend' for i in e.get('output_paths',[])))" "${persisted}")"
assert_contains "frontend canonical entry merges core output" "frontend/lib/feedback/" "${frontend_outputs}"
assert_contains "frontend canonical entry merges component output" "frontend/components/feedback/" "${frontend_outputs}"
devops_capability="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print([e for e in d['execution_plan'] if e.get('step_id')=='devops_packaging'][0].get('capability',''))" "${persisted}")"
assert_eq "devops_setup alias canonicalized to devops_delivery" "devops_delivery" "${devops_capability}"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ ${fail_count} -eq 0 ]
