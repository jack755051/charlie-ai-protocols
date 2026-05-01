#!/usr/bin/env bash
#
# test-workflow-result-schema.sh — Validate
# schemas/workflow-result.schema.yaml against positive and negative
# fixtures using step_runtime.py validate-jsonschema.
#
# IMPORTANT: this is a normalized future contract. fixtures describe the
# **expected P7 result-report-builder output**, NOT a retrofit of the
# current cap-workflow-exec.sh runtime-state.json (which is intentionally
# lower-level). result.md is the human-readable projection of this
# contract and is owned by P7; it is out of scope here.
#
# Coverage:
#   Positive 1: minimal completed run (1 step, no failures, no
#               promote_candidates, sessions populated)
#   Positive 2: realistic multi-step run with sessions, artifacts,
#               one failed step + matching failures[] entry, one
#               promote_candidate, logs pointer populated
#   Negative 1: missing required top-level field (run_id)
#   Negative 2: invalid final_state enum
#   Negative 3: step missing step_id
#   Negative 4: step.status not in enum
#   Negative 5: failure entry missing reason
#   Negative 6: artifact path wrong type (integer instead of string)
#   Negative 7: session lifecycle not in enum
#   Negative 8: schema_version not in supported enum

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCHEMA_PATH="${REPO_ROOT}/schemas/workflow-result.schema.yaml"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"
VENV_PY="${REPO_ROOT}/.venv/bin/python"
if [ -x "${VENV_PY}" ]; then
  PYTHON_BIN="${VENV_PY}"
else
  PYTHON_BIN="python3"
fi

[ -f "${SCHEMA_PATH}" ] || { echo "FAIL: schema not found at ${SCHEMA_PATH}"; exit 1; }
[ -f "${STEP_PY}" ]    || { echo "FAIL: step_runtime.py not found"; exit 1; }

SANDBOX="$(mktemp -d -t cap-wfresult-test.XXXXXX)"
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

# ── Positive 1: minimal completed run ───────────────────────────────
echo "Positive 1: minimal completed run (1 step, success)"
fixture="$(write_fixture "pos-min" '{
  "schema_version": 1,
  "run_id": "run_20260502013000_aaaaaaaa",
  "workflow_id": "minimal-flow",
  "project_id": "smoke-proj",
  "started_at": "2026-05-02T01:30:00+08:00",
  "finished_at": "2026-05-02T01:31:30+08:00",
  "total_duration_seconds": 90,
  "final_state": "completed",
  "final_result": "success",
  "summary": {
    "total_steps": 1,
    "completed": 1,
    "failed": 0,
    "skipped": 0,
    "blocked": 0
  },
  "steps": [
    {
      "step_id": "prd",
      "phase": 1,
      "capability": "prd_generation",
      "status": "ok",
      "duration_seconds": 90,
      "output_path": "/tmp/run/1-prd.md",
      "handoff_path": "/tmp/run/1-prd.handoff.md"
    }
  ],
  "sessions": [
    {
      "session_id": "run_20260502013000_aaaaaaaa.1.prd",
      "step_id": "prd",
      "role": "supervisor",
      "capability": "prd_generation",
      "provider": "claude",
      "executor": "ai",
      "lifecycle": "completed",
      "result": "success",
      "duration_seconds": 90
    }
  ],
  "artifacts": [
    {"name": "prd_document", "path": "/tmp/run/1-prd.md", "producer_step_id": "prd", "promoted": false}
  ]
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 0 on minimal completed run" "0" "${rc}"

# ── Positive 2: realistic multi-step run with failure + promote ─────
echo "Positive 2: realistic multi-step run (one failed step, one promote_candidate, logs)"
fixture="$(write_fixture "pos-realistic" '{
  "schema_version": 1,
  "run_id": "run_20260502014500_bbbbbbbb",
  "workflow_id": "project-spec-pipeline",
  "workflow_name": "Project Specification Pipeline",
  "project_id": "charlie-ai-protocols",
  "task_id": "token-monitor-minimal-spec",
  "started_at": "2026-05-02T01:45:00+08:00",
  "finished_at": "2026-05-02T02:08:30+08:00",
  "total_duration_seconds": 1410,
  "final_state": "failed",
  "final_result": "failed",
  "summary": {
    "total_steps": 5,
    "completed": 3,
    "failed": 1,
    "skipped": 0,
    "blocked": 1
  },
  "steps": [
    {"step_id": "prd",        "phase": 1, "capability": "prd_generation",      "status": "ok",      "execution_state": "validated", "duration_seconds": 120, "output_path": "/run/1-prd.md",        "handoff_path": "/run/1-prd.handoff.md",        "output_source": "captured_stdout", "input_mode": "summary", "output_tier": "full_artifact"},
    {"step_id": "tech_plan",  "phase": 2, "capability": "technical_planning",  "status": "ok",      "execution_state": "validated", "duration_seconds": 180, "output_path": "/run/2-tech_plan.md",  "handoff_path": "/run/2-tech_plan.handoff.md",  "output_source": "captured_stdout", "input_mode": "summary", "output_tier": "full_artifact"},
    {"step_id": "ba",         "phase": 3, "capability": "business_analysis",   "status": "ok",      "execution_state": "validated", "duration_seconds": 240, "output_path": "/run/3-ba.md",         "handoff_path": "/run/3-ba.handoff.md",         "output_source": "captured_stdout", "input_mode": "summary", "output_tier": "full_artifact"},
    {"step_id": "spec_audit", "phase": 4, "capability": "tool_spec_audit",     "status": "failed",  "execution_state": "failed",    "duration_seconds": 95,  "output_path": "/run/4-spec_audit.md",  "handoff_path": null,                            "output_source": "captured_stdout", "input_mode": "full",    "output_tier": "governance_report", "failure": {"reason": "spec_audit_inconsistency", "detail": "BA spec references undefined API endpoint /tokens", "route_back_to": "ba"}},
    {"step_id": "archive",    "phase": 5, "capability": "technical_logging",   "status": "blocked", "execution_state": "blocked",   "blocked_reason": "upstream_failed: spec_audit"}
  ],
  "sessions": [
    {"session_id": "run_20260502014500_bbbbbbbb.1.prd",        "step_id": "prd",        "role": "supervisor", "capability": "prd_generation",      "provider": "claude", "provider_cli": "claude", "executor": "ai", "lifecycle": "completed", "result": "success", "duration_seconds": 120},
    {"session_id": "run_20260502014500_bbbbbbbb.2.tech_plan",  "step_id": "tech_plan",  "role": "techlead",   "capability": "technical_planning",  "provider": "claude", "provider_cli": "claude", "executor": "ai", "lifecycle": "completed", "result": "success", "duration_seconds": 180},
    {"session_id": "run_20260502014500_bbbbbbbb.3.ba",         "step_id": "ba",         "role": "ba",         "capability": "business_analysis",   "provider": "claude", "provider_cli": "claude", "executor": "ai", "lifecycle": "completed", "result": "success", "duration_seconds": 240},
    {"session_id": "run_20260502014500_bbbbbbbb.4.spec_audit", "step_id": "spec_audit", "role": "watcher",    "capability": "tool_spec_audit",     "provider": "claude", "provider_cli": "claude", "executor": "ai", "lifecycle": "failed",    "result": "failure", "duration_seconds": 95, "failure_reason": "spec_audit_inconsistency"}
  ],
  "artifacts": [
    {"name": "prd_document",        "path": "/run/1-prd.md",        "producer_step_id": "prd",        "promoted": false},
    {"name": "tech_plan_document",  "path": "/run/2-tech_plan.md",  "producer_step_id": "tech_plan",  "promoted": false},
    {"name": "ba_spec",             "path": "/run/3-ba.md",         "producer_step_id": "ba",         "promoted": false},
    {"name": "spec_audit_report",   "path": "/run/4-spec_audit.md", "producer_step_id": "spec_audit", "promoted": false}
  ],
  "failures": [
    {"step_id": "spec_audit", "reason": "spec_audit_inconsistency", "detail": "BA spec references undefined API endpoint /tokens", "route_back_to": "ba"}
  ],
  "promote_candidates": [
    {"artifact_name": "prd_document", "path": "/run/1-prd.md", "target_repo_path": "docs/specs/token-monitor-prd.md", "reason": "PRD finalized; safe to promote even though run failed downstream"}
  ],
  "logs": {
    "workflow_log": "/run/workflow.log",
    "workflow_log_lines": 86
  }
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 0 on realistic multi-step run with failure" "0" "${rc}"

# ── Negative 1: missing required top-level (run_id) ─────────────────
echo "Negative 1: missing required top-level (run_id)"
fixture="$(write_fixture "neg-no-run-id" '{
  "schema_version": 1,
  "workflow_id": "x",
  "project_id": "x",
  "started_at": "2026-05-02T01:30:00+08:00",
  "final_state": "completed",
  "summary": {"total_steps": 0, "completed": 0, "failed": 0, "skipped": 0, "blocked": 0},
  "steps": [], "sessions": [], "artifacts": []
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when run_id missing" "1" "${rc}"

# ── Negative 2: invalid final_state enum ────────────────────────────
echo "Negative 2: invalid final_state enum"
fixture="$(write_fixture "neg-bad-final-state" '{
  "schema_version": 1,
  "run_id": "x", "workflow_id": "x", "project_id": "x",
  "started_at": "2026-05-02T01:30:00+08:00",
  "final_state": "yolo",
  "summary": {"total_steps": 0, "completed": 0, "failed": 0, "skipped": 0, "blocked": 0},
  "steps": [], "sessions": [], "artifacts": []
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when final_state not in enum" "1" "${rc}"

# ── Negative 3: step missing step_id ────────────────────────────────
echo "Negative 3: step missing step_id"
fixture="$(write_fixture "neg-step-no-id" '{
  "schema_version": 1,
  "run_id": "x", "workflow_id": "x", "project_id": "x",
  "started_at": "2026-05-02T01:30:00+08:00",
  "final_state": "completed",
  "summary": {"total_steps": 1, "completed": 1, "failed": 0, "skipped": 0, "blocked": 0},
  "steps": [{"phase": 1, "capability": "prd_generation", "status": "ok"}],
  "sessions": [], "artifacts": []
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when step.step_id missing" "1" "${rc}"

# ── Negative 4: step.status not in enum ─────────────────────────────
echo "Negative 4: step.status not in enum"
fixture="$(write_fixture "neg-bad-step-status" '{
  "schema_version": 1,
  "run_id": "x", "workflow_id": "x", "project_id": "x",
  "started_at": "2026-05-02T01:30:00+08:00",
  "final_state": "completed",
  "summary": {"total_steps": 1, "completed": 1, "failed": 0, "skipped": 0, "blocked": 0},
  "steps": [{"step_id": "prd", "phase": 1, "capability": "prd_generation", "status": "magnificent"}],
  "sessions": [], "artifacts": []
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when step.status not in enum" "1" "${rc}"

# ── Negative 5: failure entry missing reason ────────────────────────
echo "Negative 5: failure entry missing reason"
fixture="$(write_fixture "neg-failure-no-reason" '{
  "schema_version": 1,
  "run_id": "x", "workflow_id": "x", "project_id": "x",
  "started_at": "2026-05-02T01:30:00+08:00",
  "final_state": "failed",
  "summary": {"total_steps": 1, "completed": 0, "failed": 1, "skipped": 0, "blocked": 0},
  "steps": [{"step_id": "prd", "phase": 1, "capability": "prd_generation", "status": "failed"}],
  "sessions": [], "artifacts": [],
  "failures": [{"step_id": "prd"}]
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when failure entry missing reason" "1" "${rc}"

# ── Negative 6: artifact path wrong type ────────────────────────────
echo "Negative 6: artifact path wrong type (integer)"
fixture="$(write_fixture "neg-artifact-path-int" '{
  "schema_version": 1,
  "run_id": "x", "workflow_id": "x", "project_id": "x",
  "started_at": "2026-05-02T01:30:00+08:00",
  "final_state": "completed",
  "summary": {"total_steps": 0, "completed": 0, "failed": 0, "skipped": 0, "blocked": 0},
  "steps": [], "sessions": [],
  "artifacts": [{"name": "x", "path": 42}]
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when artifact.path is integer" "1" "${rc}"

# ── Negative 7: session lifecycle not in enum ───────────────────────
echo "Negative 7: session lifecycle not in enum"
fixture="$(write_fixture "neg-session-bad-lifecycle" '{
  "schema_version": 1,
  "run_id": "x", "workflow_id": "x", "project_id": "x",
  "started_at": "2026-05-02T01:30:00+08:00",
  "final_state": "completed",
  "summary": {"total_steps": 0, "completed": 0, "failed": 0, "skipped": 0, "blocked": 0},
  "steps": [],
  "sessions": [{"session_id": "x.1.prd", "step_id": "prd", "role": "supervisor", "capability": "prd_generation", "executor": "ai", "lifecycle": "ascended"}],
  "artifacts": []
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when session.lifecycle not in enum" "1" "${rc}"

# ── Negative 8: schema_version not in enum ──────────────────────────
echo "Negative 8: schema_version not in enum"
fixture="$(write_fixture "neg-bad-version" '{
  "schema_version": 99,
  "run_id": "x", "workflow_id": "x", "project_id": "x",
  "started_at": "2026-05-02T01:30:00+08:00",
  "final_state": "completed",
  "summary": {"total_steps": 0, "completed": 0, "failed": 0, "skipped": 0, "blocked": 0},
  "steps": [], "sessions": [], "artifacts": []
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when schema_version unsupported" "1" "${rc}"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ ${fail_count} -eq 0 ]
