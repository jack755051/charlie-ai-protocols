#!/usr/bin/env bash
#
# test-supervisor-orchestration-schema.sh — Validate
# schemas/supervisor-orchestration.schema.yaml against positive and
# negative fixtures using step_runtime.py validate-jsonschema.
#
# IMPORTANT: this is a forward contract for the future
# SupervisorOrchestrator (P3). The fixtures below describe the **expected
# P3 output shape**, NOT a retrofit of engine/task_scoped_compiler.py
# compile_task() (which today returns a different aggregation dict).
# Acceptance is limited to schema parse + envelope validation;
# producer-side runtime hook is owned by P3 and is out of scope here.
#
# Coverage:
#   Positive 1: minimal valid envelope (small task_constitution + 1-node
#               capability_graph + minimum governance + empty compile_hints)
#   Positive 2: realistic P3-style envelope with full governance, nested
#               capability_graph reflecting full-spec stage, and populated
#               compile_hints (registry_preference / fallback_policy /
#               preferred_cli / attach_inputs / notes)
#   Negative 1: missing required envelope field (capability_graph)
#   Negative 2: missing required governance sub-field (logger_mode)
#   Negative 3: invalid supervisor_role enum
#   Negative 4: governance.goal_stage not in enum
#   Negative 5: compile_hints.fallback_policy not in enum
#   Negative 6: schema_version not in enum
#   Negative 7: task_constitution wrong type (string instead of object)
#   Negative 8: governance.context_mode not in enum
#   Positive 3: full failure_routing with default_action + per-step overrides (P3 #2)
#   Negative 9: missing failure_routing entirely (P3 #2 envelope-level required)
#   Negative 10: failure_routing.default_action not in enum (P3 #2)
#   Negative 11: failure_routing.overrides[].on_fail not in enum (P3 #2)
#   Negative 12: failure_routing.overrides[] missing required step_id (P3 #2)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCHEMA_PATH="${REPO_ROOT}/schemas/supervisor-orchestration.schema.yaml"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"
VENV_PY="${REPO_ROOT}/.venv/bin/python"
if [ -x "${VENV_PY}" ]; then
  PYTHON_BIN="${VENV_PY}"
else
  PYTHON_BIN="python3"
fi

[ -f "${SCHEMA_PATH}" ] || { echo "FAIL: schema not found at ${SCHEMA_PATH}"; exit 1; }
[ -f "${STEP_PY}" ]    || { echo "FAIL: step_runtime.py not found"; exit 1; }

SANDBOX="$(mktemp -d -t cap-supervisor-orch-test.XXXXXX)"
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

# ── Positive 1: minimal valid envelope (informal_planning) ──────────
echo "Positive 1: minimal valid envelope (informal_planning)"
fixture="$(write_fixture "pos-min" '{
  "schema_version": 1,
  "task_id": "smoke-min-001",
  "source_request": "smoke test minimal supervisor orchestration",
  "produced_at": "2026-05-02T01:30:00+08:00",
  "supervisor_role": "01-Supervisor",
  "supervisor_session_id": null,
  "task_constitution": {
    "task_id": "smoke-min-001",
    "project_id": "smoke-proj",
    "source_request": "smoke test minimal supervisor orchestration",
    "goal": "produce minimal informal plan",
    "goal_stage": "informal_planning",
    "success_criteria": ["plan exists"],
    "non_goals": [],
    "execution_plan": [
      {"step_id": "prd", "capability": "prd_generation"}
    ]
  },
  "capability_graph": {
    "schema_version": 1,
    "task_id": "smoke-min-001",
    "goal_stage": "informal_planning",
    "nodes": [
      {"step_id": "prd", "capability": "prd_generation", "required": true, "depends_on": [], "reason": "define scope"}
    ]
  },
  "governance": {
    "goal_stage": "informal_planning",
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log",
    "context_mode": "summary_first"
  },
  "compile_hints": {},
  "failure_routing": {
    "default_action": "halt",
    "overrides": []
  }
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 0 on minimal valid envelope" "0" "${rc}"

# ── Positive 2: realistic P3-style envelope ─────────────────────────
echo "Positive 2: realistic P3-style envelope (formal_specification)"
fixture="$(write_fixture "pos-fullspec" '{
  "schema_version": 1,
  "task_id": "token-monitor-minimal-spec",
  "source_request": "針對 token monitor 產出最小規格，不實作",
  "produced_at": "2026-05-02T01:35:00+08:00",
  "supervisor_role": "01-Supervisor",
  "supervisor_session_id": "sess_p3_2026_05_02_a1b2c3d4",
  "task_constitution": {
    "task_id": "token-monitor-minimal-spec",
    "project_id": "token-monitor",
    "source_request": "針對 token monitor 產出最小規格，不實作",
    "goal": "produce minimal formal spec for token monitor",
    "goal_stage": "formal_specification",
    "success_criteria": ["PRD complete", "BA spec complete", "API + UI specs aligned", "spec audit passes"],
    "non_goals": ["implementation", "deployment"],
    "execution_plan": [
      {"step_id": "prd",        "capability": "prd_generation"},
      {"step_id": "tech_plan",  "capability": "technical_planning"},
      {"step_id": "ba",         "capability": "business_analysis"},
      {"step_id": "dba_api",    "capability": "database_api_design"},
      {"step_id": "ui",         "capability": "ui_design"},
      {"step_id": "spec_audit", "capability": "tool_spec_audit"},
      {"step_id": "archive",    "capability": "technical_logging"}
    ]
  },
  "capability_graph": {
    "schema_version": 1,
    "task_id": "token-monitor-minimal-spec",
    "goal_stage": "formal_specification",
    "nodes": [
      {"step_id": "prd",        "capability": "prd_generation",      "required": true, "depends_on": [],            "reason": "define scope"},
      {"step_id": "tech_plan",  "capability": "technical_planning",  "required": true, "depends_on": ["prd"],       "reason": "select tech direction"},
      {"step_id": "ba",         "capability": "business_analysis",   "required": true, "depends_on": ["tech_plan"], "reason": "clarify workflow"},
      {"step_id": "dba_api",    "capability": "database_api_design", "required": true, "depends_on": ["ba"],        "reason": "materialize contracts"},
      {"step_id": "ui",         "capability": "ui_design",           "required": true, "depends_on": ["ba", "dba_api"], "reason": "interaction surface"},
      {"step_id": "spec_audit", "capability": "tool_spec_audit",     "required": true, "depends_on": ["tech_plan", "ba", "dba_api", "ui"], "reason": "cross-spec consistency"},
      {"step_id": "archive",    "capability": "technical_logging",   "required": true, "depends_on": ["spec_audit"], "reason": "decision archive"}
    ]
  },
  "governance": {
    "goal_stage": "formal_specification",
    "watcher_mode": "milestone_gate",
    "logger_mode": "milestone_log",
    "context_mode": "summary_first",
    "halt_on_missing_handoff": true,
    "watcher_checkpoints": ["spec_audit"],
    "logger_checkpoints": ["prd", "tech_plan", "archive"]
  },
  "compile_hints": {
    "registry_preference": "project_first",
    "fallback_policy": "halt",
    "preferred_cli": "claude",
    "skip_optional_unresolved": false,
    "attach_inputs": [],
    "notes": ["supervisor confirmed v0.21.6 baseline; no unresolved P0a items."]
  },
  "failure_routing": {
    "default_action": "halt",
    "overrides": []
  }
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 0 on realistic P3-style envelope" "0" "${rc}"

# ── Negative 1: missing required envelope field ─────────────────────
echo "Negative 1: missing required envelope field (capability_graph)"
fixture="$(write_fixture "neg-no-graph" '{
  "schema_version": 1,
  "task_id": "x",
  "source_request": "x",
  "produced_at": "2026-05-02T01:30:00+08:00",
  "supervisor_role": "01-Supervisor",
  "task_constitution": {},
  "governance": {
    "goal_stage": "informal_planning",
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log",
    "context_mode": "summary_first"
  },
  "compile_hints": {},
  "failure_routing": {"default_action": "halt", "overrides": []}
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when capability_graph missing" "1" "${rc}"

# ── Negative 2: governance missing required sub-field ───────────────
echo "Negative 2: governance missing required sub-field (logger_mode)"
fixture="$(write_fixture "neg-gov-no-logger" '{
  "schema_version": 1,
  "task_id": "x",
  "source_request": "x",
  "produced_at": "2026-05-02T01:30:00+08:00",
  "supervisor_role": "01-Supervisor",
  "task_constitution": {},
  "capability_graph": {},
  "governance": {
    "goal_stage": "informal_planning",
    "watcher_mode": "final_only",
    "context_mode": "summary_first"
  },
  "compile_hints": {},
  "failure_routing": {"default_action": "halt", "overrides": []}
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when governance.logger_mode missing" "1" "${rc}"

# ── Negative 3: invalid supervisor_role enum ────────────────────────
echo "Negative 3: invalid supervisor_role enum"
fixture="$(write_fixture "neg-bad-role" '{
  "schema_version": 1,
  "task_id": "x",
  "source_request": "x",
  "produced_at": "2026-05-02T01:30:00+08:00",
  "supervisor_role": "07-QA",
  "task_constitution": {},
  "capability_graph": {},
  "governance": {
    "goal_stage": "informal_planning",
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log",
    "context_mode": "summary_first"
  },
  "compile_hints": {},
  "failure_routing": {"default_action": "halt", "overrides": []}
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when supervisor_role not in enum" "1" "${rc}"

# ── Negative 4: governance.goal_stage not in enum ───────────────────
echo "Negative 4: governance.goal_stage not in enum"
fixture="$(write_fixture "neg-bad-goal-stage" '{
  "schema_version": 1,
  "task_id": "x",
  "source_request": "x",
  "produced_at": "2026-05-02T01:30:00+08:00",
  "supervisor_role": "01-Supervisor",
  "task_constitution": {},
  "capability_graph": {},
  "governance": {
    "goal_stage": "rapid_prototyping",
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log",
    "context_mode": "summary_first"
  },
  "compile_hints": {},
  "failure_routing": {"default_action": "halt", "overrides": []}
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when governance.goal_stage not in enum" "1" "${rc}"

# ── Negative 5: compile_hints.fallback_policy not in enum ───────────
echo "Negative 5: compile_hints.fallback_policy not in enum"
fixture="$(write_fixture "neg-bad-fallback" '{
  "schema_version": 1,
  "task_id": "x",
  "source_request": "x",
  "produced_at": "2026-05-02T01:30:00+08:00",
  "supervisor_role": "01-Supervisor",
  "task_constitution": {},
  "capability_graph": {},
  "governance": {
    "goal_stage": "informal_planning",
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log",
    "context_mode": "summary_first"
  },
  "compile_hints": {"fallback_policy": "yolo"},
  "failure_routing": {"default_action": "halt", "overrides": []}
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when compile_hints.fallback_policy not in enum" "1" "${rc}"

# ── Negative 6: schema_version not in enum ──────────────────────────
echo "Negative 6: schema_version not in enum"
fixture="$(write_fixture "neg-bad-version" '{
  "schema_version": 99,
  "task_id": "x",
  "source_request": "x",
  "produced_at": "2026-05-02T01:30:00+08:00",
  "supervisor_role": "01-Supervisor",
  "task_constitution": {},
  "capability_graph": {},
  "governance": {
    "goal_stage": "informal_planning",
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log",
    "context_mode": "summary_first"
  },
  "compile_hints": {},
  "failure_routing": {"default_action": "halt", "overrides": []}
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when schema_version unsupported" "1" "${rc}"

# ── Negative 7: task_constitution wrong type ────────────────────────
echo "Negative 7: task_constitution wrong type (string instead of object)"
fixture="$(write_fixture "neg-tc-string" '{
  "schema_version": 1,
  "task_id": "x",
  "source_request": "x",
  "produced_at": "2026-05-02T01:30:00+08:00",
  "supervisor_role": "01-Supervisor",
  "task_constitution": "not an object",
  "capability_graph": {},
  "governance": {
    "goal_stage": "informal_planning",
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log",
    "context_mode": "summary_first"
  },
  "compile_hints": {},
  "failure_routing": {"default_action": "halt", "overrides": []}
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when task_constitution is string" "1" "${rc}"

# ── Negative 8: governance.context_mode not in enum ─────────────────
echo "Negative 8: governance.context_mode not in enum"
fixture="$(write_fixture "neg-bad-ctx-mode" '{
  "schema_version": 1,
  "task_id": "x",
  "source_request": "x",
  "produced_at": "2026-05-02T01:30:00+08:00",
  "supervisor_role": "01-Supervisor",
  "task_constitution": {},
  "capability_graph": {},
  "governance": {
    "goal_stage": "informal_planning",
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log",
    "context_mode": "interactive_chat"
  },
  "compile_hints": {},
  "failure_routing": {"default_action": "halt", "overrides": []}
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when governance.context_mode not in enum" "1" "${rc}"

# ── Positive 3: full failure_routing with default + overrides (P3 #2) ──
echo "Positive 3: full failure_routing with per-step overrides"
fixture="$(write_fixture "pos-failure-routing" '{
  "schema_version": 1,
  "task_id": "p3-routing-001",
  "source_request": "exercise full failure_routing block",
  "produced_at": "2026-05-03T20:30:00Z",
  "supervisor_role": "01-Supervisor",
  "task_constitution": {
    "task_id": "p3-routing-001",
    "project_id": "smoke-proj",
    "source_request": "exercise full failure_routing block",
    "goal": "verify routing fixture lands valid",
    "goal_stage": "implementation_preparation",
    "success_criteria": ["routing surfaces at envelope level"],
    "non_goals": [],
    "execution_plan": [
      {"step_id": "prd",        "capability": "prd_generation"},
      {"step_id": "tech_plan",  "capability": "technical_planning"},
      {"step_id": "spec_audit", "capability": "tool_spec_audit"}
    ]
  },
  "capability_graph": {
    "schema_version": 1,
    "task_id": "p3-routing-001",
    "goal_stage": "implementation_preparation",
    "nodes": [
      {"step_id": "prd",        "capability": "prd_generation",     "required": true, "depends_on": [],            "reason": "scope"},
      {"step_id": "tech_plan",  "capability": "technical_planning", "required": true, "depends_on": ["prd"],       "reason": "stack"},
      {"step_id": "spec_audit", "capability": "tool_spec_audit",    "required": true, "depends_on": ["tech_plan"], "reason": "consistency"}
    ]
  },
  "governance": {
    "goal_stage": "implementation_preparation",
    "watcher_mode": "milestone_gate",
    "logger_mode": "milestone_log",
    "context_mode": "summary_first"
  },
  "compile_hints": {},
  "failure_routing": {
    "default_action": "halt",
    "default_route_back_to_step": null,
    "default_max_retries": null,
    "overrides": [
      {"step_id": "tech_plan",  "on_fail": "route_back_to", "route_back_to_step": "prd",      "max_retries": null},
      {"step_id": "spec_audit", "on_fail": "retry",         "route_back_to_step": null,        "max_retries": 2},
      {"step_id": "prd",        "on_fail": "escalate_user", "route_back_to_step": null,        "max_retries": null}
    ]
  }
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 0 on full failure_routing fixture" "0" "${rc}"

# ── Negative 9: missing failure_routing entirely (P3 #2) ──────────────
echo "Negative 9: missing failure_routing (envelope-level required)"
fixture="$(write_fixture "neg-no-failure-routing" '{
  "schema_version": 1,
  "task_id": "x",
  "source_request": "x",
  "produced_at": "2026-05-03T20:30:00Z",
  "supervisor_role": "01-Supervisor",
  "task_constitution": {},
  "capability_graph": {},
  "governance": {
    "goal_stage": "informal_planning",
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log",
    "context_mode": "summary_first"
  },
  "compile_hints": {}
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when failure_routing missing" "1" "${rc}"

# ── Negative 10: failure_routing.default_action not in enum (P3 #2) ───
echo "Negative 10: failure_routing.default_action not in enum"
fixture="$(write_fixture "neg-bad-default-action" '{
  "schema_version": 1,
  "task_id": "x",
  "source_request": "x",
  "produced_at": "2026-05-03T20:30:00Z",
  "supervisor_role": "01-Supervisor",
  "task_constitution": {},
  "capability_graph": {},
  "governance": {
    "goal_stage": "informal_planning",
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log",
    "context_mode": "summary_first"
  },
  "compile_hints": {},
  "failure_routing": {"default_action": "ignore", "overrides": []}
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when failure_routing.default_action not in enum" "1" "${rc}"

# ── Negative 11: overrides[].on_fail not in enum (P3 #2) ──────────────
echo "Negative 11: failure_routing.overrides[].on_fail not in enum"
fixture="$(write_fixture "neg-override-bad-on-fail" '{
  "schema_version": 1,
  "task_id": "x",
  "source_request": "x",
  "produced_at": "2026-05-03T20:30:00Z",
  "supervisor_role": "01-Supervisor",
  "task_constitution": {},
  "capability_graph": {},
  "governance": {
    "goal_stage": "informal_planning",
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log",
    "context_mode": "summary_first"
  },
  "compile_hints": {},
  "failure_routing": {
    "default_action": "halt",
    "overrides": [
      {"step_id": "prd", "on_fail": "yolo"}
    ]
  }
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when overrides[].on_fail not in enum" "1" "${rc}"

# ── Negative 12: overrides[] missing required step_id (P3 #2) ─────────
echo "Negative 12: failure_routing.overrides[] missing required step_id"
fixture="$(write_fixture "neg-override-missing-step-id" '{
  "schema_version": 1,
  "task_id": "x",
  "source_request": "x",
  "produced_at": "2026-05-03T20:30:00Z",
  "supervisor_role": "01-Supervisor",
  "task_constitution": {},
  "capability_graph": {},
  "governance": {
    "goal_stage": "informal_planning",
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log",
    "context_mode": "summary_first"
  },
  "compile_hints": {},
  "failure_routing": {
    "default_action": "halt",
    "overrides": [
      {"on_fail": "halt"}
    ]
  }
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when overrides[] missing step_id" "1" "${rc}"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ ${fail_count} -eq 0 ]
