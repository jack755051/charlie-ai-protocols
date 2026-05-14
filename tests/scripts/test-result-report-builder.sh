#!/usr/bin/env bash
#
# test-result-report-builder.sh — P7 Phase A: read-only workflow result
# aggregator. Library-only contract — no CLI, no cap-workflow-exec.sh
# wiring. Cases cover:
#
#   1. happy run (all ok)                  → final_state=completed,  final_result=success
#   2. partial run (some skipped)          → final_state=completed,  final_result=partial
#   3. failed run (some failed)            → final_state=failed,     final_result=null
#   4. running run (no Finished section)   → final_state=running,    final_result=null
#   5. blocked run (some blocked, finished)→ final_state=blocked,    final_result=null
#   6. handoff ticket cross-reference      → failures[].route_back_to populated from ticket
#   7. missing optional sources            → builder degrades to null/[] without raising
#   8. promote_candidates                  → always [] in v1
#   9. schema validation                   → every fixture passes
#                                           schemas/workflow-result.schema.yaml
#  10. real smoke run dir (when present)   → schema passes against the
#                                            actual ~/.cap smoke artifact

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
SCHEMA_PATH="${REPO_ROOT}/schemas/workflow-result.schema.yaml"
STEP_RUNTIME="${REPO_ROOT}/engine/step_runtime.py"
BUILDER_MODULE="${REPO_ROOT}/engine/result_report_builder.py"

[ -f "${BUILDER_MODULE}" ] || { echo "FAIL: ${BUILDER_MODULE} missing"; exit 1; }
[ -f "${SCHEMA_PATH}" ]    || { echo "FAIL: ${SCHEMA_PATH} missing"; exit 1; }
[ -f "${STEP_RUNTIME}" ]   || { echo "FAIL: ${STEP_RUNTIME} missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-result-builder-test.XXXXXX)"
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

# ── helpers ─────────────────────────────────────────────────────────────

# stage_run_dir <case_name> [project_id]
# Creates the canonical CAP run-dir layout and echoes the run_dir path.
stage_run_dir() {
  local case_name="$1"
  local project_id="${2:-test-proj}"
  local cap_home="${SANDBOX}/${case_name}/cap"
  local run_dir="${cap_home}/projects/${project_id}/reports/workflows/test-wf/run_${case_name}"
  mkdir -p "${run_dir}"
  printf '%s' "${run_dir}"
}

cap_home_for() {
  local case_name="$1"
  printf '%s' "${SANDBOX}/${case_name}/cap"
}

# Build the result via Python helper script and emit JSON to a path.
# Usage: build_to_json <run_dir> <out_json> [cap_home] [status_file]
build_to_json() {
  local run_dir="$1"
  local out_json="$2"
  local cap_home="${3:-}"
  local status_file="${4:-}"
  PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${run_dir}" "${out_json}" "${cap_home}" "${status_file}" <<'PY'
import json, sys
from pathlib import Path
from engine.result_report_builder import build_workflow_result

run_dir = sys.argv[1]
out_json = sys.argv[2]
cap_home = sys.argv[3] or None
status_file = sys.argv[4] or None
result = build_workflow_result(
    run_dir,
    cap_home=cap_home,
    status_file=status_file,
)
Path(out_json).write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
PY
}

# json_field <json_path> <python_expr_on_data> — print the evaluated expression.
json_field() {
  local json_path="$1"
  local expr="$2"
  "${PYTHON_BIN}" - "${json_path}" "${expr}" <<'PY'
import json, sys
data = json.loads(open(sys.argv[1]).read())
expr = sys.argv[2]
print(eval(expr, {"data": data}))
PY
}

assert_schema_ok() {
  local desc="$1" json_path="$2"
  local out
  out="$("${PYTHON_BIN}" "${STEP_RUNTIME}" validate-jsonschema "${json_path}" "${SCHEMA_PATH}" 2>&1)"
  local rc=$?
  if [ "${rc}" -eq 0 ] && grep -q '"ok": true' <<<"${out}"; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    rc:  ${rc}"
    echo "    out: ${out}"
    fail_count=$((fail_count + 1))
  fi
}

# ── Case 1: happy run ──────────────────────────────────────────────────

echo "Case 1: happy run → completed/success"
RUN1="$(stage_run_dir happy)"
cat > "${RUN1}/runtime-state.json" <<'EOF'
{
  "artifacts": {
    "spec_doc": {
      "artifact": "spec_doc",
      "source_step": "spec_step",
      "path": "/tmp/spec.md",
      "handoff_path": "/tmp/spec.handoff.md"
    }
  },
  "steps": {
    "spec_step": {
      "phase": "1",
      "capability": "specification",
      "execution_state": "validated",
      "blocked_reason": "",
      "output_source": "captured_stdout",
      "output_path": "/tmp/spec.md",
      "handoff_path": "/tmp/spec.handoff.md"
    },
    "review_step": {
      "phase": "2",
      "capability": "review",
      "execution_state": "validated",
      "blocked_reason": "",
      "output_source": "captured_stdout",
      "output_path": "/tmp/review.md",
      "handoff_path": "/tmp/review.handoff.md"
    }
  }
}
EOF
cat > "${RUN1}/agent-sessions.json" <<'EOF'
{
  "version": 1,
  "run_id": "run_happy",
  "workflow_id": "test-wf",
  "workflow_name": "Test Happy Workflow",
  "sessions": [
    {
      "session_id": "run_happy.1.spec_step",
      "step_id": "spec_step",
      "role": "ba",
      "capability": "specification",
      "executor": "ai",
      "provider": "claude",
      "provider_cli": "claude",
      "lifecycle": "completed",
      "result": "success",
      "duration_seconds": 30,
      "usage": {
        "available": true,
        "source": "provider_cli",
        "provider": "claude",
        "provider_cli": "claude",
        "model": "test-model",
        "input_tokens": 100,
        "output_tokens": 50,
        "cache_read_tokens": 10,
        "cache_write_tokens": 0,
        "total_tokens": 160,
        "prompt_size_bytes": 1000,
        "output_size_bytes": 500,
        "quota_pressure": null,
        "reason": null
      }
    },
    {
      "session_id": "run_happy.2.review_step",
      "step_id": "review_step",
      "role": "watcher",
      "capability": "review",
      "executor": "ai",
      "provider": "codex",
      "provider_cli": "codex",
      "lifecycle": "completed",
      "result": "success",
      "duration_seconds": 25,
      "usage": {
        "available": false,
        "source": "runtime_byte_counts",
        "provider": "codex",
        "provider_cli": "codex",
        "model": null,
        "input_tokens": null,
        "output_tokens": null,
        "cache_read_tokens": null,
        "cache_write_tokens": null,
        "total_tokens": null,
        "prompt_size_bytes": 800,
        "output_size_bytes": 300,
        "quota_pressure": null,
        "reason": "provider did not expose token usage; byte counts recorded"
      }
    }
  ]
}
EOF
cat > "${RUN1}/run-summary.md" <<'EOF'
# Workflow Run Summary

- workflow_id: test-wf
- workflow_name: Test Happy Workflow
- run_id: run_happy
- started_at: 2026-05-05 10:00:00

## Steps

### spec_step

- status: ok
- duration_seconds: 30
- output: /tmp/spec.md
- handoff: /tmp/spec.handoff.md
- output_source: captured_stdout
- input_mode: summary
- output_tier: full_artifact

### review_step

- status: ok
- duration_seconds: 25
- output: /tmp/review.md
- handoff: /tmp/review.handoff.md
- output_source: captured_stdout
- input_mode: summary
- output_tier: full_artifact

## Finished

- finished_at: 2026-05-05 10:01:05
- total_duration_seconds: 65
- completed: 2
- failed: 0
- skipped: 0
EOF
printf '[2026-05-05 10:00:00][workflow][started]\n[2026-05-05 10:01:05][workflow][success]\n' > "${RUN1}/workflow.log"

OUT1="${SANDBOX}/happy.json"
build_to_json "${RUN1}" "${OUT1}" "$(cap_home_for happy)"
assert_eq "happy schema_version=1" "1" "$(json_field "${OUT1}" 'data["schema_version"]')"
assert_eq "happy run_id"         "run_happy"  "$(json_field "${OUT1}" 'data["run_id"]')"
assert_eq "happy workflow_id"    "test-wf"    "$(json_field "${OUT1}" 'data["workflow_id"]')"
assert_eq "happy project_id"     "test-proj"  "$(json_field "${OUT1}" 'data["project_id"]')"
assert_eq "happy final_state=completed" "completed" "$(json_field "${OUT1}" 'data["final_state"]')"
assert_eq "happy final_result=success"  "success"   "$(json_field "${OUT1}" 'data["final_result"]')"
assert_eq "happy summary.completed=2" "2" "$(json_field "${OUT1}" 'data["summary"]["completed"]')"
assert_eq "happy summary.failed=0"    "0" "$(json_field "${OUT1}" 'data["summary"]["failed"]')"
assert_eq "happy steps_count=2"       "2" "$(json_field "${OUT1}" 'len(data["steps"])')"
assert_eq "happy sessions_count=2"    "2" "$(json_field "${OUT1}" 'len(data["sessions"])')"
assert_eq "happy usage available count" "1" "$(json_field "${OUT1}" 'data["usage_summary"]["available_sessions"]')"
assert_eq "happy usage unavailable count" "1" "$(json_field "${OUT1}" 'data["usage_summary"]["unavailable_sessions"]')"
assert_eq "happy total_tokens projected" "160" "$(json_field "${OUT1}" 'data["usage_summary"]["total_tokens"]')"
assert_eq "happy prompt bytes aggregated" "1800" "$(json_field "${OUT1}" 'data["usage_summary"]["prompt_size_bytes"]')"
assert_eq "happy artifacts_count=1"   "1" "$(json_field "${OUT1}" 'len(data["artifacts"])')"
assert_eq "happy failures=[]"         "0" "$(json_field "${OUT1}" 'len(data["failures"])')"
assert_eq "happy promote_candidates=[]" "0" "$(json_field "${OUT1}" 'len(data["promote_candidates"])')"
assert_eq "happy task_id=None"        "None" "$(json_field "${OUT1}" 'data["task_id"]')"
assert_eq "happy logs.workflow_log_lines=2" "2" "$(json_field "${OUT1}" 'data["logs"]["workflow_log_lines"]')"
assert_schema_ok "happy passes workflow-result schema" "${OUT1}"

# ── Case 2: partial run (one skipped) ──────────────────────────────────

echo ""
echo "Case 2: partial run (one skipped) → completed/partial"
RUN2="$(stage_run_dir partial)"
cat > "${RUN2}/runtime-state.json" <<'EOF'
{
  "artifacts": {},
  "steps": {
    "core_step": {
      "phase": "1",
      "capability": "core",
      "execution_state": "validated",
      "blocked_reason": "",
      "output_source": "captured_stdout",
      "output_path": "/tmp/core.md",
      "handoff_path": ""
    },
    "optional_step": {
      "phase": "2",
      "capability": "optional",
      "execution_state": "skipped",
      "blocked_reason": "",
      "output_source": "",
      "output_path": "",
      "handoff_path": ""
    }
  }
}
EOF
cat > "${RUN2}/agent-sessions.json" <<'EOF'
{"version": 1, "run_id": "run_partial", "workflow_id": "test-wf", "sessions": []}
EOF
cat > "${RUN2}/run-summary.md" <<'EOF'
# Workflow Run Summary

- workflow_id: test-wf
- run_id: run_partial
- started_at: 2026-05-05 11:00:00

## Steps

### core_step

- status: ok
- duration_seconds: 10

### optional_step

- status: skipped

## Finished

- finished_at: 2026-05-05 11:00:15
- total_duration_seconds: 15
- completed: 1
- failed: 0
- skipped: 1
EOF

OUT2="${SANDBOX}/partial.json"
build_to_json "${RUN2}" "${OUT2}" "$(cap_home_for partial)"
assert_eq "partial final_state=completed" "completed" "$(json_field "${OUT2}" 'data["final_state"]')"
assert_eq "partial final_result=partial"  "partial"   "$(json_field "${OUT2}" 'data["final_result"]')"
assert_eq "partial summary.skipped=1"     "1" "$(json_field "${OUT2}" 'data["summary"]["skipped"]')"
assert_schema_ok "partial passes schema" "${OUT2}"

# ── Case 3: failed run ─────────────────────────────────────────────────

echo ""
echo "Case 3: failed run → failed/null + failures populated"
RUN3="$(stage_run_dir failed)"
cat > "${RUN3}/runtime-state.json" <<'EOF'
{
  "artifacts": {},
  "steps": {
    "good_step": {
      "phase": "1",
      "capability": "good",
      "execution_state": "validated",
      "blocked_reason": "",
      "output_source": "captured_stdout",
      "output_path": "/tmp/good.md",
      "handoff_path": ""
    },
    "bad_step": {
      "phase": "2",
      "capability": "bad",
      "execution_state": "failed",
      "blocked_reason": "",
      "output_source": "",
      "output_path": "",
      "handoff_path": ""
    }
  }
}
EOF
cat > "${RUN3}/agent-sessions.json" <<'EOF'
{
  "version": 1,
  "run_id": "run_failed",
  "workflow_id": "test-wf",
  "sessions": [
    {
      "session_id": "run_failed.2.bad_step",
      "step_id": "bad_step",
      "role": "shell",
      "capability": "bad",
      "executor": "shell",
      "lifecycle": "failed",
      "result": "failure",
      "duration_seconds": 5,
      "failure_reason": "reason=schema_validation_failed;detail=missing required field summary"
    }
  ]
}
EOF
cat > "${RUN3}/run-summary.md" <<'EOF'
# Workflow Run Summary

- workflow_id: test-wf
- run_id: run_failed
- started_at: 2026-05-05 12:00:00

## Steps

### good_step

- status: ok
- duration_seconds: 8

### bad_step

- status: failed
- duration_seconds: 5

## Finished

- finished_at: 2026-05-05 12:00:30
- total_duration_seconds: 30
- completed: 1
- failed: 1
- skipped: 0
EOF

OUT3="${SANDBOX}/failed.json"
build_to_json "${RUN3}" "${OUT3}" "$(cap_home_for failed)"
assert_eq "failed final_state=failed" "failed" "$(json_field "${OUT3}" 'data["final_state"]')"
assert_eq "failed final_result=null"  "None"   "$(json_field "${OUT3}" 'data["final_result"]')"
assert_eq "failed failures count=1"   "1"      "$(json_field "${OUT3}" 'len(data["failures"])')"
assert_eq "failed failures[0].step_id=bad_step" "bad_step" "$(json_field "${OUT3}" 'data["failures"][0]["step_id"]')"
assert_eq "failed reason split" "schema_validation_failed" "$(json_field "${OUT3}" 'data["failures"][0]["reason"]')"
assert_eq "failed detail split" "missing required field summary" "$(json_field "${OUT3}" 'data["failures"][0]["detail"]')"
assert_eq "failed route_back_to=None (no ticket)" "None" "$(json_field "${OUT3}" 'data["failures"][0]["route_back_to"]')"
assert_eq "failed step.failure inline reason" "schema_validation_failed" "$(json_field "${OUT3}" '[s["failure"]["reason"] for s in data["steps"] if s["step_id"]=="bad_step"][0]')"
assert_schema_ok "failed passes schema" "${OUT3}"

# ── Case 4: running run (no Finished section) ──────────────────────────

echo ""
echo "Case 4: running run → running/null"
RUN4="$(stage_run_dir running)"
cat > "${RUN4}/runtime-state.json" <<'EOF'
{
  "artifacts": {},
  "steps": {
    "in_progress": {
      "phase": "1",
      "capability": "wip",
      "execution_state": "running",
      "blocked_reason": "",
      "output_source": "",
      "output_path": "",
      "handoff_path": ""
    }
  }
}
EOF
cat > "${RUN4}/agent-sessions.json" <<'EOF'
{
  "version": 1,
  "run_id": "run_running",
  "workflow_id": "test-wf",
  "sessions": [
    {
      "session_id": "run_running.1.in_progress",
      "step_id": "in_progress",
      "role": "ba",
      "capability": "wip",
      "executor": "ai",
      "provider": "claude",
      "lifecycle": "running"
    }
  ]
}
EOF
cat > "${RUN4}/run-summary.md" <<'EOF'
# Workflow Run Summary

- workflow_id: test-wf
- run_id: run_running
- started_at: 2026-05-05 13:00:00

## Steps

### in_progress

- status: running
EOF

OUT4="${SANDBOX}/running.json"
build_to_json "${RUN4}" "${OUT4}" "$(cap_home_for running)"
assert_eq "running final_state=running" "running" "$(json_field "${OUT4}" 'data["final_state"]')"
assert_eq "running final_result=null"   "None"    "$(json_field "${OUT4}" 'data["final_result"]')"
assert_eq "running finished_at=null"    "None"    "$(json_field "${OUT4}" 'data["finished_at"]')"
assert_eq "running total_duration_seconds=null" "None" "$(json_field "${OUT4}" 'data["total_duration_seconds"]')"
assert_schema_ok "running passes schema" "${OUT4}"

# ── Case 5: blocked run ────────────────────────────────────────────────

echo ""
echo "Case 5: blocked run → blocked/null"
RUN5="$(stage_run_dir blocked)"
cat > "${RUN5}/runtime-state.json" <<'EOF'
{
  "artifacts": {},
  "steps": {
    "blocked_step": {
      "phase": "1",
      "capability": "needs_input",
      "execution_state": "blocked",
      "blocked_reason": "missing input artifact",
      "output_source": "",
      "output_path": "",
      "handoff_path": ""
    }
  }
}
EOF
cat > "${RUN5}/agent-sessions.json" <<'EOF'
{"version": 1, "run_id": "run_blocked", "workflow_id": "test-wf", "sessions": []}
EOF
cat > "${RUN5}/run-summary.md" <<'EOF'
# Workflow Run Summary

- workflow_id: test-wf
- run_id: run_blocked
- started_at: 2026-05-05 14:00:00

## Steps

### blocked_step

- status: blocked

## Finished

- finished_at: 2026-05-05 14:00:05
- total_duration_seconds: 5
- completed: 0
- failed: 0
- skipped: 0
EOF

OUT5="${SANDBOX}/blocked.json"
build_to_json "${RUN5}" "${OUT5}" "$(cap_home_for blocked)"
assert_eq "blocked final_state=blocked" "blocked" "$(json_field "${OUT5}" 'data["final_state"]')"
assert_eq "blocked final_result=null"   "None"    "$(json_field "${OUT5}" 'data["final_result"]')"
assert_eq "blocked summary.blocked=1"   "1"       "$(json_field "${OUT5}" 'data["summary"]["blocked"]')"
assert_eq "blocked failures count=1"    "1"       "$(json_field "${OUT5}" 'len(data["failures"])')"
assert_eq "blocked reason fallback" "missing input artifact" "$(json_field "${OUT5}" 'data["failures"][0]["reason"]')"
assert_schema_ok "blocked passes schema" "${OUT5}"

# ── Case 6: handoff ticket cross-reference ─────────────────────────────

echo ""
echo "Case 6: failed step + handoff ticket → route_back_to populated"
RUN6="$(stage_run_dir ticketed)"
HANDOFFS6="${SANDBOX}/ticketed/cap/projects/test-proj/handoffs"
mkdir -p "${HANDOFFS6}"
cat > "${RUN6}/runtime-state.json" <<'EOF'
{
  "artifacts": {},
  "steps": {
    "first_step": {
      "phase": "1", "capability": "first",
      "execution_state": "validated", "blocked_reason": "",
      "output_source": "captured_stdout", "output_path": "/tmp/first.md", "handoff_path": ""
    },
    "second_step": {
      "phase": "2", "capability": "second",
      "execution_state": "failed", "blocked_reason": "",
      "output_source": "", "output_path": "", "handoff_path": ""
    }
  }
}
EOF
cat > "${RUN6}/agent-sessions.json" <<'EOF'
{
  "version": 1, "run_id": "run_ticketed", "workflow_id": "test-wf",
  "sessions": [
    {
      "session_id": "run_ticketed.2.second_step",
      "step_id": "second_step",
      "role": "shell", "capability": "second", "executor": "shell",
      "lifecycle": "failed", "result": "failure",
      "failure_reason": "reason=schema_validation_failed;detail=missing field"
    }
  ]
}
EOF
cat > "${RUN6}/run-summary.md" <<'EOF'
# Workflow Run Summary

- workflow_id: test-wf
- run_id: run_ticketed
- started_at: 2026-05-05 15:00:00

## Steps

### first_step
- status: ok
- duration_seconds: 5

### second_step
- status: failed

## Finished
- finished_at: 2026-05-05 15:00:10
- total_duration_seconds: 10
- completed: 1
- failed: 1
- skipped: 0
EOF
cat > "${HANDOFFS6}/second_step.ticket.json" <<'EOF'
{
  "ticket_id": "task_ticketed-second_step-1",
  "task_id": "task_ticketed",
  "step_id": "second_step",
  "created_at": "2026-05-05T15:00:01Z",
  "created_by": "01-Supervisor",
  "target_capability": "second",
  "task_objective": "execute second_step",
  "rules_to_load": {"agent_skill": "", "core_protocol": "agent-skills/00-core-protocol.md"},
  "context_payload": {
    "project_constitution_path": "/dev/null",
    "task_constitution_path": "/dev/null"
  },
  "acceptance_criteria": ["dummy"],
  "output_expectations": {
    "primary_artifacts": [],
    "handoff_summary_path": "/dev/null"
  },
  "failure_routing": {
    "on_fail": "route_back_to",
    "route_back_to_step": "first_step"
  }
}
EOF

OUT6="${SANDBOX}/ticketed.json"
build_to_json "${RUN6}" "${OUT6}" "$(cap_home_for ticketed)"
assert_eq "ticketed final_state=failed" "failed" "$(json_field "${OUT6}" 'data["final_state"]')"
assert_eq "ticketed failures route_back_to=first_step" "first_step" "$(json_field "${OUT6}" 'data["failures"][0]["route_back_to"]')"
assert_eq "ticketed step.failure inline route_back" "first_step" "$(json_field "${OUT6}" '[s["failure"]["route_back_to"] for s in data["steps"] if s["step_id"]=="second_step"][0]')"
assert_schema_ok "ticketed passes schema" "${OUT6}"

# ── Case 7: missing optional sources ───────────────────────────────────

echo ""
echo "Case 7: missing optional sources → builder degrades gracefully"
RUN7="$(stage_run_dir minimal)"
# No workflow.log, no handoffs/, no status_file. Only the 3 required SSOTs.
cat > "${RUN7}/runtime-state.json" <<'EOF'
{
  "artifacts": {},
  "steps": {
    "single": {
      "phase": "1", "capability": "single",
      "execution_state": "validated", "blocked_reason": "",
      "output_source": "captured_stdout",
      "output_path": "/tmp/single.md", "handoff_path": ""
    }
  }
}
EOF
cat > "${RUN7}/agent-sessions.json" <<'EOF'
{"version": 1, "run_id": "run_minimal", "workflow_id": "test-wf", "sessions": []}
EOF
cat > "${RUN7}/run-summary.md" <<'EOF'
# Workflow Run Summary

- workflow_id: test-wf
- run_id: run_minimal
- started_at: 2026-05-05 16:00:00

## Steps

### single
- status: ok
- duration_seconds: 1

## Finished
- finished_at: 2026-05-05 16:00:01
- total_duration_seconds: 1
- completed: 1
- failed: 0
- skipped: 0
EOF

OUT7="${SANDBOX}/minimal.json"
# Note: no cap_home passed → handoff lookup skipped entirely
build_to_json "${RUN7}" "${OUT7}" "" ""
assert_eq "minimal final_state=completed" "completed" "$(json_field "${OUT7}" 'data["final_state"]')"
assert_eq "minimal logs=null (no workflow.log)" "None" "$(json_field "${OUT7}" 'data["logs"]')"
assert_eq "minimal task_id=None (no status_file)" "None" "$(json_field "${OUT7}" 'data["task_id"]')"
assert_eq "minimal failures=[]" "0" "$(json_field "${OUT7}" 'len(data["failures"])')"
assert_eq "minimal promote_candidates=[]" "0" "$(json_field "${OUT7}" 'len(data["promote_candidates"])')"
assert_schema_ok "minimal passes schema" "${OUT7}"

# ── Case 8: future-compatible linkage (status_file → task_id) ─────────
#
# The current ``step_runtime.update_status`` producer writes only the
# ``workflows{}`` map and leaves ``runs[]`` empty — i.e. there is no
# per-run ``task_id`` on disk today. The builder's ``status_file`` hook
# is therefore best-effort future-compatible: 8a covers the future
# producer shape (runs[*].task_id present); 8b covers the current
# producer shape (no runs[] task_id) and asserts the builder degrades
# to ``task_id=None`` while the schema still passes.

echo ""
echo "Case 8: future-compatible linkage (status_file → task_id)"
echo "  8a: future producer shape (runs[*].task_id present) → task_id populated"
RUN8="$(stage_run_dir linked)"
STATUS8="${SANDBOX}/linked/workflow-runs.json"
cat > "${RUN8}/runtime-state.json" <<'EOF'
{"artifacts": {}, "steps": {}}
EOF
cat > "${RUN8}/agent-sessions.json" <<'EOF'
{"version": 1, "run_id": "run_linked", "workflow_id": "test-wf", "sessions": []}
EOF
cat > "${RUN8}/run-summary.md" <<'EOF'
# Workflow Run Summary

- workflow_id: test-wf
- run_id: run_linked
- started_at: 2026-05-05 17:00:00

## Finished
- finished_at: 2026-05-05 17:00:01
- total_duration_seconds: 1
- completed: 0
- failed: 0
- skipped: 0
EOF
cat > "${STATUS8}" <<'EOF'
{
  "version": 2,
  "workflows": {},
  "runs": [
    {"run_id": "run_linked", "workflow_id": "test-wf", "task_id": "task-abc-123"}
  ]
}
EOF

OUT8="${SANDBOX}/linked.json"
build_to_json "${RUN8}" "${OUT8}" "$(cap_home_for linked)" "${STATUS8}"
assert_eq "linked task_id=task-abc-123" "task-abc-123" "$(json_field "${OUT8}" 'data["task_id"]')"
assert_schema_ok "linked passes schema" "${OUT8}"

echo ""
echo "  8b: current producer shape (no runs[] task_id) → task_id=None + schema pass"
# Mirror the on-disk shape that ``step_runtime.update_status`` produces today:
# only the workflow-level ``workflows{}`` map is populated; ``runs[]`` is
# left empty, so there is no per-run ``task_id`` to resolve. The builder
# must degrade to ``task_id=None`` without breaking schema validation.
RUN8B="$(stage_run_dir current_producer)"
STATUS8B="${SANDBOX}/current_producer/workflow-runs.json"
cat > "${RUN8B}/runtime-state.json" <<'EOF'
{"artifacts": {}, "steps": {}}
EOF
cat > "${RUN8B}/agent-sessions.json" <<'EOF'
{"version": 1, "run_id": "run_current_producer", "workflow_id": "test-wf", "sessions": []}
EOF
cat > "${RUN8B}/run-summary.md" <<'EOF'
# Workflow Run Summary

- workflow_id: test-wf
- run_id: run_current_producer
- started_at: 2026-05-05 17:30:00

## Finished
- finished_at: 2026-05-05 17:30:01
- total_duration_seconds: 1
- completed: 0
- failed: 0
- skipped: 0
EOF
cat > "${STATUS8B}" <<'EOF'
{
  "version": 2,
  "workflows": {
    "test-wf": {
      "workflow_name": "Test Workflow",
      "state": "completed",
      "last_result": "success",
      "last_run_at": "2026-05-05 17:30:01",
      "run_count": 1
    }
  },
  "runs": []
}
EOF

OUT8B="${SANDBOX}/current_producer.json"
build_to_json "${RUN8B}" "${OUT8B}" "$(cap_home_for current_producer)" "${STATUS8B}"
assert_eq "current_producer task_id=None" "None" "$(json_field "${OUT8B}" 'data["task_id"]')"
assert_schema_ok "current_producer passes schema" "${OUT8B}"

# ── Case 9: malformed runtime-state → default {}, builder still runs ──

echo ""
echo "Case 9: malformed runtime-state.json → degrades to empty, schema still passes"
RUN9="$(stage_run_dir malformed)"
echo '{not valid json' > "${RUN9}/runtime-state.json"
echo '{"version":1,"run_id":"run_malformed","workflow_id":"test-wf","sessions":[]}' > "${RUN9}/agent-sessions.json"
cat > "${RUN9}/run-summary.md" <<'EOF'
# Workflow Run Summary

- workflow_id: test-wf
- run_id: run_malformed
- started_at: 2026-05-05 18:00:00

## Finished
- finished_at: 2026-05-05 18:00:01
- total_duration_seconds: 1
- completed: 0
- failed: 0
- skipped: 0
EOF

OUT9="${SANDBOX}/malformed.json"
build_to_json "${RUN9}" "${OUT9}" "$(cap_home_for malformed)"
assert_eq "malformed steps=[]" "0" "$(json_field "${OUT9}" 'len(data["steps"])')"
assert_eq "malformed artifacts=[]" "0" "$(json_field "${OUT9}" 'len(data["artifacts"])')"
assert_schema_ok "malformed passes schema (degrades)" "${OUT9}"

# ── Case 10: real smoke run dir (when present) ────────────────────────

echo ""
echo "Case 10: real smoke run dir → schema passes against actual ~/.cap artifact"
SMOKE_DIR="$(ls -td "${HOME}/.cap/projects/charlie-ai-protocols/reports/workflows/workflow-smoke-test/run_"* 2>/dev/null | head -1 || true)"
if [ -n "${SMOKE_DIR}" ] && [ -d "${SMOKE_DIR}" ]; then
  OUT10="${SANDBOX}/smoke.json"
  build_to_json "${SMOKE_DIR}" "${OUT10}" "${HOME}/.cap"
  assert_eq "smoke final_state=completed" "completed" "$(json_field "${OUT10}" 'data["final_state"]')"
  assert_eq "smoke project_id=charlie-ai-protocols" "charlie-ai-protocols" "$(json_field "${OUT10}" 'data["project_id"]')"
  assert_schema_ok "smoke passes schema (real run dir)" "${OUT10}"
else
  echo "  SKIP: no real smoke run dir under ~/.cap (regression-only)"
fi

# ── Case 11: missing run_dir → FileNotFoundError ───────────────────────

echo ""
echo "Case 11: missing run_dir → builder raises FileNotFoundError"
out11="$(PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${SANDBOX}/no-such-dir" <<'PY' 2>&1 || true
import sys
from engine.result_report_builder import build_workflow_result
try:
    build_workflow_result(sys.argv[1])
    print("UNEXPECTED:no_error")
except FileNotFoundError as exc:
    print(f"OK:{exc.__class__.__name__}")
except Exception as exc:
    print(f"WRONG_EXCEPTION:{exc.__class__.__name__}:{exc}")
PY
)"
assert_eq "missing run_dir raises FileNotFoundError" "OK:FileNotFoundError" "${out11}"

# ── Case 12: render_result_md → human-readable Markdown projection ─────

echo ""
echo "Case 12: render_result_md → headings + key fields rendered"
RENDERED_MD="${SANDBOX}/happy.result.md"
PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${OUT1}" "${RENDERED_MD}" <<'PY'
import json, sys
from pathlib import Path
from engine.result_report_builder import render_result_md

result = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
Path(sys.argv[2]).write_text(render_result_md(result), encoding="utf-8")
PY

assert_md_contains() {
  local desc="$1" md_path="$2" needle="$3"
  if grep -qF -- "${needle}" "${md_path}"; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    needle: ${needle}"
    echo "    file:   ${md_path}"
    fail_count=$((fail_count + 1))
  fi
}

assert_md_contains "render: top heading" "${RENDERED_MD}" "# Workflow Result"
assert_md_contains "render: workflow_id field" "${RENDERED_MD}" "- workflow_id: test-wf"
assert_md_contains "render: run_id field" "${RENDERED_MD}" "- run_id: run_happy"
assert_md_contains "render: project_id field" "${RENDERED_MD}" "- project_id: test-proj"
assert_md_contains "render: final_state field" "${RENDERED_MD}" "- final_state: completed"
assert_md_contains "render: final_result field" "${RENDERED_MD}" "- final_result: success"
assert_md_contains "render: Summary section" "${RENDERED_MD}" "## Summary"
assert_md_contains "render: Usage section" "${RENDERED_MD}" "## Usage"
assert_md_contains "render: usage availability" "${RENDERED_MD}" "- provider_token_telemetry_available: 1/2"
assert_md_contains "render: total tokens" "${RENDERED_MD}" "- total_tokens: 160"
assert_md_contains "render: Steps section" "${RENDERED_MD}" "## Steps"
assert_md_contains "render: spec_step bullet" "${RENDERED_MD}" "- spec_step [ok]"
assert_md_contains "render: review_step bullet" "${RENDERED_MD}" "- review_step [ok]"
assert_md_contains "render: Artifacts section" "${RENDERED_MD}" "## Artifacts"
assert_md_contains "render: spec_doc artifact" "${RENDERED_MD}" "- spec_doc: /tmp/spec.md"
assert_md_contains "render: Logs section" "${RENDERED_MD}" "## Logs"
assert_md_contains "render: Notes section" "${RENDERED_MD}" "## Notes"

# Failed fixture exercises the optional ## Failures branch.
RENDERED_FAILED_MD="${SANDBOX}/failed.result.md"
PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${OUT3}" "${RENDERED_FAILED_MD}" <<'PY'
import json, sys
from pathlib import Path
from engine.result_report_builder import render_result_md

result = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
Path(sys.argv[2]).write_text(render_result_md(result), encoding="utf-8")
PY
assert_md_contains "render(failed): Failures section" "${RENDERED_FAILED_MD}" "## Failures"
assert_md_contains "render(failed): bad_step entry" "${RENDERED_FAILED_MD}" "- step_id: bad_step"
assert_md_contains "render(failed): reason rendered" "${RENDERED_FAILED_MD}" "reason: schema_validation_failed"

# ── Case 13: input pointers — dirs present (P7 #2) ────────────────────
#
# When the well-known cap-storage subdirs exist on disk, the builder
# records directory pointers under ``inputs``. Pointer-only by design;
# the test only checks dir-level resolution, not snapshot picking.

echo ""
echo "Case 13: inputs pointers populated when cap-storage dirs exist"
RUN13="$(stage_run_dir withinputs)"
CAP13="$(cap_home_for withinputs)"
# Create the three well-known subdirs that _resolve_input_pointers looks at.
mkdir -p "${CAP13}/projects/test-proj/constitutions"
mkdir -p "${CAP13}/projects/test-proj/compiled-workflows/test-wf"
mkdir -p "${CAP13}/projects/test-proj/bindings/test-wf"

OUT13="${SANDBOX}/withinputs.json"
build_to_json "${RUN13}" "${OUT13}" "${CAP13}"
assert_eq "withinputs constitution_dir resolved" \
  "${CAP13}/projects/test-proj/constitutions" \
  "$(json_field "${OUT13}" 'data["inputs"]["constitution_dir"]')"
assert_eq "withinputs compiled_workflow_dir resolved" \
  "${CAP13}/projects/test-proj/compiled-workflows/test-wf" \
  "$(json_field "${OUT13}" 'data["inputs"]["compiled_workflow_dir"]')"
assert_eq "withinputs binding_dir resolved" \
  "${CAP13}/projects/test-proj/bindings/test-wf" \
  "$(json_field "${OUT13}" 'data["inputs"]["binding_dir"]')"
assert_schema_ok "withinputs passes schema" "${OUT13}"

# Render check: result.md should now include the ## Inputs section.
RENDERED_INPUTS_MD="${SANDBOX}/withinputs.result.md"
PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${OUT13}" "${RENDERED_INPUTS_MD}" <<'PY'
import json, sys
from pathlib import Path
from engine.result_report_builder import render_result_md

result = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
Path(sys.argv[2]).write_text(render_result_md(result), encoding="utf-8")
PY
assert_md_contains "render(inputs): ## Inputs section"     "${RENDERED_INPUTS_MD}" "## Inputs"
assert_md_contains "render(inputs): constitution_dir line" "${RENDERED_INPUTS_MD}" "- constitution_dir:"
assert_md_contains "render(inputs): compiled_workflow_dir" "${RENDERED_INPUTS_MD}" "- compiled_workflow_dir:"
assert_md_contains "render(inputs): binding_dir line"      "${RENDERED_INPUTS_MD}" "- binding_dir:"

# ── Case 14: input pointers — dirs missing → all null + section omitted

echo ""
echo "Case 14: inputs pointers null when cap-storage dirs absent"
RUN14="$(stage_run_dir noinputs)"
CAP14="$(cap_home_for noinputs)"
# Deliberately do NOT mkdir constitutions / compiled-workflows / bindings.

OUT14="${SANDBOX}/noinputs.json"
build_to_json "${RUN14}" "${OUT14}" "${CAP14}"
assert_eq "noinputs constitution_dir=None" "None" \
  "$(json_field "${OUT14}" 'data["inputs"]["constitution_dir"]')"
assert_eq "noinputs compiled_workflow_dir=None" "None" \
  "$(json_field "${OUT14}" 'data["inputs"]["compiled_workflow_dir"]')"
assert_eq "noinputs binding_dir=None" "None" \
  "$(json_field "${OUT14}" 'data["inputs"]["binding_dir"]')"
assert_schema_ok "noinputs passes schema (all null pointers)" "${OUT14}"

# Render: ## Inputs section must be omitted when all pointers are null.
RENDERED_NOINPUTS_MD="${SANDBOX}/noinputs.result.md"
PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${OUT14}" "${RENDERED_NOINPUTS_MD}" <<'PY'
import json, sys
from pathlib import Path
from engine.result_report_builder import render_result_md

result = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
Path(sys.argv[2]).write_text(render_result_md(result), encoding="utf-8")
PY
if grep -qF -- "## Inputs" "${RENDERED_NOINPUTS_MD}"; then
  echo "  FAIL: render(noinputs) should omit ## Inputs when all pointers null"
  fail_count=$((fail_count + 1))
else
  echo "  PASS: render(noinputs): ## Inputs section omitted"
  pass_count=$((pass_count + 1))
fi

# ── Case 15: session result enum normalization ─────────────────────────
#
# Reproduces the 2026-05-13 component-feedback-widget dogfood failure
# (run run_20260513110312_2052b7a8) where the workflow-result fallback
# emitted ``sessions/1/result: 'failed' is not one of ['success',
# 'failure', 'partial', None]``. The agent-sessions ledger writes
# ``"failed"`` / ``"passed"`` (mirroring agent-session schema +
# gate-result projection) but the workflow-result schema enum is
# [success, failure, partial, null]. ``_project_sessions`` must
# normalize the ledger value to the workflow-result enum or set
# ``None`` for unknown inputs.
echo "Case 15: session result enum normalized for workflow-result schema"
RUN15="$(stage_run_dir resultenum)"
cat > "${RUN15}/runtime-state.json" <<'EOF'
{
  "artifacts": {},
  "steps": {
    "s_failed": {
      "phase": "1",
      "capability": "x",
      "execution_state": "failed",
      "blocked_reason": "",
      "output_source": "captured_stdout",
      "output_path": "/tmp/x.md",
      "handoff_path": "/tmp/x.handoff.md"
    },
    "s_passed": {
      "phase": "2",
      "capability": "x",
      "execution_state": "validated",
      "blocked_reason": "",
      "output_source": "captured_stdout",
      "output_path": "/tmp/y.md",
      "handoff_path": "/tmp/y.handoff.md"
    },
    "s_unknown": {
      "phase": "3",
      "capability": "x",
      "execution_state": "validated",
      "blocked_reason": "",
      "output_source": "captured_stdout",
      "output_path": "/tmp/z.md",
      "handoff_path": "/tmp/z.handoff.md"
    }
  }
}
EOF
cat > "${RUN15}/agent-sessions.json" <<'EOF'
{
  "version": 1,
  "run_id": "run_resultenum",
  "workflow_id": "test-wf",
  "sessions": [
    {
      "session_id": "run_resultenum.1.s_failed",
      "step_id": "s_failed",
      "role": "ba",
      "capability": "x",
      "executor": "ai",
      "provider": "claude",
      "lifecycle": "failed",
      "result": "failed",
      "duration_seconds": 30
    },
    {
      "session_id": "run_resultenum.2.s_passed",
      "step_id": "s_passed",
      "role": "watcher",
      "capability": "x",
      "executor": "ai",
      "provider": "codex",
      "lifecycle": "completed",
      "result": "passed",
      "duration_seconds": 25
    },
    {
      "session_id": "run_resultenum.3.s_unknown",
      "step_id": "s_unknown",
      "role": "qa",
      "capability": "x",
      "executor": "ai",
      "provider": "claude",
      "lifecycle": "completed",
      "result": "archive_completed_stdout_closed_with_blockers",
      "duration_seconds": 15
    }
  ]
}
EOF
cat > "${RUN15}/run-summary.md" <<'EOF'
# Workflow Run Summary

- workflow_id: test-wf
- run_id: run_resultenum
- started_at: 2026-05-13 11:03:00

## Steps

### s_failed

- status: failed
- duration_seconds: 30
- output: /tmp/x.md

### s_passed

- status: ok
- duration_seconds: 25
- output: /tmp/y.md

### s_unknown

- status: ok
- duration_seconds: 15
- output: /tmp/z.md

## Finished

- finished_at: 2026-05-13 11:04:10
- total_duration_seconds: 70
- completed: 2
- failed: 1
- skipped: 0
EOF

OUT15="${SANDBOX}/resultenum.json"
build_to_json "${RUN15}" "${OUT15}" "$(cap_home_for resultenum)"
assert_eq "resultenum sessions_count=3" "3" "$(json_field "${OUT15}" 'len(data["sessions"])')"
assert_eq "resultenum sessions[0].result=failure (was 'failed')" "failure" \
  "$(json_field "${OUT15}" 'data["sessions"][0]["result"]')"
assert_eq "resultenum sessions[1].result=success (was 'passed')" "success" \
  "$(json_field "${OUT15}" 'data["sessions"][1]["result"]')"
assert_eq "resultenum sessions[2].result=None (unknown alias collapses)" "None" \
  "$(json_field "${OUT15}" 'data["sessions"][2]["result"]')"
assert_schema_ok "resultenum passes workflow-result schema (no 'failed' leak)" "${OUT15}"

# ── Case 16: cost hotspot aggregation ────────────────────────────────
#
# Backs the P0b "workflow cost/hotspot report from existing usage
# telemetry" deliverable (docs/cap/COST-OPTIMIZATION-MEMO.md).
# Stages three sessions: two backend_implementation sessions with
# different prompt sizes (one with full usage incl. tokens, one with
# byte-only fallback), plus one frontend_implementation session that
# shares prompt_hash with the first backend session to exercise the
# within-run duplicate detector.
#
# Asserts:
#   - by_capability aggregates per capability with summed metrics
#   - by_step ranks sessions by prompt_size_bytes desc
#   - duplicate_prompts surfaces the shared prompt_hash
#   - largest_prompts caps at top 5 and excludes null-size sessions
#   - result.md renders ## Cost Hotspot with the three sub-sections
#   - workflow-result schema accepts the new usage_hotspot object
echo "Case 16: cost hotspot aggregates by_step/by_capability/duplicates"
RUN16="$(stage_run_dir hotspot)"
cat > "${RUN16}/runtime-state.json" <<'EOF'
{
  "artifacts": {},
  "steps": {
    "backend_a": {
      "phase": "1",
      "capability": "backend_implementation",
      "execution_state": "validated",
      "blocked_reason": "",
      "output_source": "captured_stdout",
      "output_path": "/tmp/a.md",
      "handoff_path": "/tmp/a.handoff.md"
    },
    "backend_b": {
      "phase": "2",
      "capability": "backend_implementation",
      "execution_state": "validated",
      "blocked_reason": "",
      "output_source": "captured_stdout",
      "output_path": "/tmp/b.md",
      "handoff_path": "/tmp/b.handoff.md"
    },
    "frontend_a": {
      "phase": "3",
      "capability": "frontend_implementation",
      "execution_state": "validated",
      "blocked_reason": "",
      "output_source": "captured_stdout",
      "output_path": "/tmp/c.md",
      "handoff_path": "/tmp/c.handoff.md"
    }
  }
}
EOF
cat > "${RUN16}/agent-sessions.json" <<'EOF'
{
  "version": 1,
  "run_id": "run_hotspot",
  "workflow_id": "test-wf",
  "sessions": [
    {
      "session_id": "run_hotspot.1.backend_a",
      "step_id": "backend_a",
      "role": "backend",
      "capability": "backend_implementation",
      "executor": "ai",
      "provider": "claude",
      "lifecycle": "completed",
      "result": "success",
      "duration_seconds": 600,
      "prompt_hash": "shared_hash_aaa",
      "prompt_size_bytes": 8000,
      "usage": {
        "available": true,
        "source": "provider_cli",
        "provider": "claude",
        "model": "test-model",
        "input_tokens": 5000,
        "output_tokens": 2000,
        "cache_read_tokens": 500,
        "cache_write_tokens": 100,
        "total_tokens": 7600,
        "prompt_size_bytes": 8000,
        "output_size_bytes": 3000,
        "quota_pressure": null,
        "reason": null
      }
    },
    {
      "session_id": "run_hotspot.2.backend_b",
      "step_id": "backend_b",
      "role": "backend",
      "capability": "backend_implementation",
      "executor": "ai",
      "provider": "codex",
      "lifecycle": "completed",
      "result": "success",
      "duration_seconds": 400,
      "prompt_hash": "unique_hash_bbb",
      "prompt_size_bytes": 6000,
      "usage": {
        "available": false,
        "source": "runtime_byte_counts",
        "provider": "codex",
        "model": null,
        "input_tokens": null,
        "output_tokens": null,
        "cache_read_tokens": null,
        "cache_write_tokens": null,
        "total_tokens": null,
        "prompt_size_bytes": 6000,
        "output_size_bytes": 1500,
        "quota_pressure": null,
        "reason": "provider did not expose token usage; byte counts recorded"
      }
    },
    {
      "session_id": "run_hotspot.3.frontend_a",
      "step_id": "frontend_a",
      "role": "frontend",
      "capability": "frontend_implementation",
      "executor": "ai",
      "provider": "claude",
      "lifecycle": "completed",
      "result": "success",
      "duration_seconds": 500,
      "prompt_hash": "shared_hash_aaa",
      "prompt_size_bytes": 8000,
      "usage": {
        "available": true,
        "source": "provider_cli",
        "provider": "claude",
        "model": "test-model",
        "input_tokens": 4000,
        "output_tokens": 1500,
        "cache_read_tokens": 200,
        "cache_write_tokens": 0,
        "total_tokens": 5700,
        "prompt_size_bytes": 8000,
        "output_size_bytes": 2500,
        "quota_pressure": null,
        "reason": null
      }
    }
  ]
}
EOF
cat > "${RUN16}/run-summary.md" <<'EOF'
# Workflow Run Summary

- workflow_id: test-wf
- run_id: run_hotspot
- started_at: 2026-05-14 09:00:00

## Steps

### backend_a

- status: ok
- duration_seconds: 600

### backend_b

- status: ok
- duration_seconds: 400

### frontend_a

- status: ok
- duration_seconds: 500

## Finished

- finished_at: 2026-05-14 09:25:00
- total_duration_seconds: 1500
- completed: 3
- failed: 0
- skipped: 0
EOF

OUT16="${SANDBOX}/hotspot.json"
build_to_json "${RUN16}" "${OUT16}" "$(cap_home_for hotspot)"

# by_capability assertions: backend_implementation should aggregate two
# sessions (8000 + 6000 = 14000 prompt bytes), frontend_implementation
# should have one session (8000 prompt bytes). backend_implementation
# total_tokens should be 7600 (only backend_a contributed real tokens;
# backend_b's usage.available=false leaves token sum at 7600).
assert_eq "hotspot by_capability[0].capability=backend_implementation" "backend_implementation" \
  "$(json_field "${OUT16}" 'data["usage_hotspot"]["by_capability"][0]["capability"]')"
assert_eq "hotspot by_capability[0].sessions=2" "2" \
  "$(json_field "${OUT16}" 'data["usage_hotspot"]["by_capability"][0]["sessions"]')"
assert_eq "hotspot by_capability[0].prompt_size_bytes=14000" "14000" \
  "$(json_field "${OUT16}" 'data["usage_hotspot"]["by_capability"][0]["prompt_size_bytes"]')"
assert_eq "hotspot by_capability[0].total_tokens=7600 (backend_b skipped)" "7600" \
  "$(json_field "${OUT16}" 'data["usage_hotspot"]["by_capability"][0]["total_tokens"]')"
assert_eq "hotspot by_capability[1].capability=frontend_implementation" "frontend_implementation" \
  "$(json_field "${OUT16}" 'data["usage_hotspot"]["by_capability"][1]["capability"]')"

# by_step: backend_a (8000) and frontend_a (8000) tied at top, then
# backend_b (6000). Order between the tied 8000B entries is sort-stable
# so backend_a (came first in input) wins. The point of the test is the
# ranking shape, not the precise tie-breaking, so only assert the
# lowest-ranked entry.
assert_eq "hotspot by_step length=3" "3" \
  "$(json_field "${OUT16}" 'len(data["usage_hotspot"]["by_step"])')"
assert_eq "hotspot by_step[2].step_id=backend_b (lowest prompt bytes)" "backend_b" \
  "$(json_field "${OUT16}" 'data["usage_hotspot"]["by_step"][2]["step_id"]')"
assert_eq "hotspot by_step[2].prompt_size_bytes=6000" "6000" \
  "$(json_field "${OUT16}" 'data["usage_hotspot"]["by_step"][2]["prompt_size_bytes"]')"

# duplicate_prompts: shared_hash_aaa appears 2× across backend_a + frontend_a.
assert_eq "hotspot duplicate_prompts length=1" "1" \
  "$(json_field "${OUT16}" 'len(data["usage_hotspot"]["duplicate_prompts"])')"
assert_eq "hotspot duplicate_prompts[0].occurrences=2" "2" \
  "$(json_field "${OUT16}" 'data["usage_hotspot"]["duplicate_prompts"][0]["occurrences"]')"
assert_eq "hotspot duplicate_prompts[0].prompt_hash=shared_hash_aaa" "shared_hash_aaa" \
  "$(json_field "${OUT16}" 'data["usage_hotspot"]["duplicate_prompts"][0]["prompt_hash"]')"

# largest_prompts: top 5 by size, includes only sessions with non-null prompt_size_bytes.
assert_eq "hotspot largest_prompts length=3 (all have sizes)" "3" \
  "$(json_field "${OUT16}" 'len(data["usage_hotspot"]["largest_prompts"])')"

# Schema must accept the new usage_hotspot field.
assert_schema_ok "hotspot passes workflow-result schema (usage_hotspot optional field)" "${OUT16}"

# result.md should render the ## Cost Hotspot section + 3 sub-sections.
RENDERED_HOTSPOT_MD="${SANDBOX}/hotspot.result.md"
PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${OUT16}" "${RENDERED_HOTSPOT_MD}" <<'PY'
import json, sys
from pathlib import Path
from engine.result_report_builder import render_result_md
result = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
Path(sys.argv[2]).write_text(render_result_md(result), encoding="utf-8")
PY
for needle in \
  "## Cost Hotspot" \
  "### by_capability" \
  "### by_step" \
  "### duplicate_prompts" \
  "shared_hash_" \
  "backend_implementation:"
do
  if grep -qF -- "${needle}" "${RENDERED_HOTSPOT_MD}"; then
    echo "  PASS: render(hotspot) contains '${needle}'"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: render(hotspot) missing '${needle}'"
    fail_count=$((fail_count + 1))
  fi
done

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
