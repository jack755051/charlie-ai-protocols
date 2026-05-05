#!/usr/bin/env bash
#
# test-cap-workflow-inspect.sh — P7 Phase C focused test.
#
# Exercises the upgraded ``cap workflow inspect <run-id>`` resolution
# implemented in ``engine/workflow_cli.cmd_inspect``. Cases:
#
#   1. workflow-result.json present  → text view shows the 6 sections
#                                      (Run Header / Summary / Failures /
#                                      Sessions / Artifacts / Logs Pointer).
#   2. --json flag                   → emits valid JSON matching the
#                                      stored workflow-result.json.
#   3. workflow-result.json missing  → builder fallback aggregates the
#                                      run_dir SSOT in-memory and renders
#                                      the same text sections.
#   4. run_dir absent, status-store  → legacy ``WORKFLOW RUN INSPECT``
#      has matching run_id            view (preserved for pre-P7 runs).
#   5. neither found                 → exit 1, ``找不到 run_id`` on stderr.
#
# All cases pin ``--cap-home`` to a sandbox so the test never touches
# the real ``~/.cap`` tree. The Python entry is invoked directly to
# bypass cap-workflow.sh's get_status_store helper (which is fine — the
# bash dispatcher only forwards args verbatim).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
CLI_PY="${REPO_ROOT}/engine/workflow_cli.py"

[ -f "${CLI_PY}" ] || { echo "FAIL: ${CLI_PY} missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-inspect-test.XXXXXX)"
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

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    needle: ${needle}"
    echo "    head:   $(printf '%s' "${haystack}" | head -3)"
    fail_count=$((fail_count + 1))
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if ! printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc} (unexpected match): ${needle}"
    fail_count=$((fail_count + 1))
  fi
}

# stage_run_dir <case_name> [project_id] — create canonical CAP run_dir
# layout under the sandbox cap_home and echo the run_dir path.
stage_run_dir() {
  local case_name="$1"
  local project_id="${2:-inspect-proj}"
  local cap_home="${SANDBOX}/${case_name}/cap"
  local run_dir="${cap_home}/projects/${project_id}/reports/workflows/inspect-wf/run_${case_name}"
  mkdir -p "${run_dir}"
  cat > "${run_dir}/runtime-state.json" <<'EOF'
{
  "artifacts": {
    "spec_doc": {"artifact": "spec_doc", "source_step": "spec_step", "path": "/tmp/spec.md"}
  },
  "steps": {
    "spec_step": {
      "phase": "1",
      "capability": "specification",
      "execution_state": "validated",
      "blocked_reason": "",
      "output_source": "captured_stdout",
      "output_path": "/tmp/spec.md",
      "handoff_path": ""
    }
  }
}
EOF
  cat > "${run_dir}/agent-sessions.json" <<EOF
{
  "version": 1,
  "run_id": "run_${case_name}",
  "workflow_id": "inspect-wf",
  "workflow_name": "Inspect Focused Test",
  "sessions": [
    {
      "session_id": "run_${case_name}.1.spec_step",
      "step_id": "spec_step",
      "role": "ba",
      "capability": "specification",
      "executor": "ai",
      "provider": "claude",
      "lifecycle": "completed",
      "result": "success",
      "duration_seconds": 12
    }
  ]
}
EOF
  cat > "${run_dir}/run-summary.md" <<EOF
# Workflow Run Summary

- workflow_id: inspect-wf
- workflow_name: Inspect Focused Test
- run_id: run_${case_name}
- started_at: 2026-05-05 12:00:00

## Steps

### spec_step

- status: ok
- duration_seconds: 12

## Finished

- finished_at: 2026-05-05 12:00:12
- total_duration_seconds: 12
- completed: 1
- failed: 0
- skipped: 0
EOF
  printf '[2026-05-05 12:00:00][workflow][started]\n[2026-05-05 12:00:12][workflow][success]\n' \
    > "${run_dir}/workflow.log"
  printf '%s' "${run_dir}"
}

cap_home_for() {
  local case_name="$1"
  printf '%s' "${SANDBOX}/${case_name}/cap"
}

# Build a workflow-result.json into the run_dir using the Phase A library.
emit_result_json() {
  local run_dir="$1" cap_home="$2"
  PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${run_dir}" "${cap_home}" <<'PY'
import json, sys
from pathlib import Path
from engine.result_report_builder import build_workflow_result

run_dir = sys.argv[1]
cap_home = sys.argv[2] or None
result = build_workflow_result(run_dir, cap_home=cap_home)
Path(run_dir, "workflow-result.json").write_text(
    json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
)
PY
}

# Empty status store (no runs[]) — used by Cases 1-3 where resolution
# never reaches the legacy path. We still need *some* file because
# argparse requires the positional even when unused.
EMPTY_STATUS="${SANDBOX}/empty-status.json"
cat > "${EMPTY_STATUS}" <<'EOF'
{"version": 2, "workflows": {}, "runs": []}
EOF

# ── Case 1: workflow-result.json present → 6-section text view ─────────

echo "Case 1: workflow-result.json present → 6 sections"
RUN1="$(stage_run_dir withjson)"
emit_result_json "${RUN1}" "$(cap_home_for withjson)"

OUT1="$("${PYTHON_BIN}" "${CLI_PY}" inspect "${EMPTY_STATUS}" "run_withjson" \
  --cap-home "$(cap_home_for withjson)" 2>&1)"
RC1=$?
assert_eq "withjson: exit 0" "0" "${RC1}"
assert_contains "withjson: Run Header section"   "${OUT1}" "# Run Header"
assert_contains "withjson: workflow_id field"    "${OUT1}" "workflow_id:   inspect-wf"
assert_contains "withjson: run_id field"         "${OUT1}" "run_id:        run_withjson"
assert_contains "withjson: project_id field"     "${OUT1}" "project_id:    inspect-proj"
assert_contains "withjson: final_state field"    "${OUT1}" "final_state:   completed"
assert_contains "withjson: final_result field"   "${OUT1}" "final_result:  success"
assert_contains "withjson: Summary section"      "${OUT1}" "# Summary"
assert_contains "withjson: total_steps line"     "${OUT1}" "total_steps: 1"
assert_contains "withjson: Failures section"     "${OUT1}" "# Failures"
assert_contains "withjson: Failures (none)"      "${OUT1}" "(none)"
assert_contains "withjson: Sessions section"     "${OUT1}" "# Sessions"
assert_contains "withjson: session entry"        "${OUT1}" "step_id:     spec_step"
assert_contains "withjson: Artifacts section"    "${OUT1}" "# Artifacts"
assert_contains "withjson: spec_doc artifact"    "${OUT1}" "spec_doc: /tmp/spec.md"
assert_contains "withjson: Logs Pointer section" "${OUT1}" "# Logs Pointer"
assert_contains "withjson: workflow_log line"    "${OUT1}" "workflow_log:"

# ── Case 2: --json flag emits the workflow-result JSON ────────────────

echo ""
echo "Case 2: --json flag → JSON output"
OUT2="$("${PYTHON_BIN}" "${CLI_PY}" inspect "${EMPTY_STATUS}" "run_withjson" \
  --cap-home "$(cap_home_for withjson)" --json 2>&1)"
RC2=$?
assert_eq "json: exit 0" "0" "${RC2}"

# Validate JSON parses + key fields match.
JSON_CHECK="$(printf '%s' "${OUT2}" | "${PYTHON_BIN}" -c '
import json, sys
data = json.loads(sys.stdin.read())
print(data["run_id"], data["workflow_id"], data["final_state"], data["summary"]["completed"])
')"
assert_eq "json: parsed run_id+workflow_id+state+completed" \
  "run_withjson inspect-wf completed 1" "${JSON_CHECK}"
# Sanity: text-mode marker should NOT appear in JSON output.
assert_not_contains "json: no Run Header heading"  "${OUT2}" "# Run Header"

# ── Case 3: workflow-result.json missing → builder fallback ───────────

echo ""
echo "Case 3: workflow-result.json missing → builder fallback aggregates SSOT"
RUN3="$(stage_run_dir nojson)"
# Deliberately do NOT call emit_result_json — only the SSOT files exist.
[ ! -f "${RUN3}/workflow-result.json" ] || {
  echo "FAIL: setup error — workflow-result.json should be absent"
  exit 1
}

OUT3="$("${PYTHON_BIN}" "${CLI_PY}" inspect "${EMPTY_STATUS}" "run_nojson" \
  --cap-home "$(cap_home_for nojson)" 2>&1)"
RC3=$?
assert_eq "nojson: exit 0" "0" "${RC3}"
assert_contains "nojson: Run Header heading"    "${OUT3}" "# Run Header"
assert_contains "nojson: builder-derived state" "${OUT3}" "final_state:   completed"
assert_contains "nojson: Summary present"       "${OUT3}" "# Summary"
assert_contains "nojson: completed=1"           "${OUT3}" "completed:   1"
assert_contains "nojson: spec_step session"     "${OUT3}" "step_id:     spec_step"

# ── Case 4: no run_dir → legacy status-store fallback ─────────────────

echo ""
echo "Case 4: no run_dir → legacy WORKFLOW RUN INSPECT view"
LEGACY_HOME="${SANDBOX}/legacy-empty-cap"
mkdir -p "${LEGACY_HOME}"  # exists but no projects/ subtree
LEGACY_STATUS="${SANDBOX}/legacy-status.json"
cat > "${LEGACY_STATUS}" <<'EOF'
{
  "version": 2,
  "workflows": {
    "legacy-wf": {"workflow_name": "Legacy Workflow", "state": "completed", "last_result": "success", "last_run_at": "2026-05-04 10:00:00", "run_count": 1}
  },
  "runs": [
    {
      "run_id": "run_legacy_only",
      "workflow_id": "legacy-wf",
      "workflow_name": "Legacy Workflow",
      "state": "completed",
      "result": "success",
      "mode": "fast",
      "cli": "claude",
      "prompt_preview": "do the legacy thing",
      "created_at": "2026-05-04 09:59:50",
      "updated_at": "2026-05-04 10:00:00",
      "started_at": "2026-05-04 09:59:50",
      "finished_at": "2026-05-04 10:00:00"
    }
  ]
}
EOF

OUT4="$("${PYTHON_BIN}" "${CLI_PY}" inspect "${LEGACY_STATUS}" "run_legacy_only" \
  --cap-home "${LEGACY_HOME}" 2>&1)"
RC4=$?
assert_eq "legacy: exit 0" "0" "${RC4}"
assert_contains "legacy: WORKFLOW RUN INSPECT header" "${OUT4}" "WORKFLOW RUN INSPECT"
assert_contains "legacy: RUN ID line"                 "${OUT4}" "RUN ID:      run_legacy_only"
assert_contains "legacy: WORKFLOW ID line"            "${OUT4}" "WORKFLOW ID: legacy-wf"
assert_contains "legacy: STATE line"                  "${OUT4}" "STATE:       completed"
assert_contains "legacy: PROMPT line"                 "${OUT4}" "PROMPT:      do the legacy thing"
# Sanity: modern path heading must NOT appear when we fall back.
assert_not_contains "legacy: no modern Run Header"    "${OUT4}" "# Run Header"

# ── Case 5: neither found → exit 1 ────────────────────────────────────

echo ""
echo "Case 5: neither run_dir nor status-store → exit 1"
EMPTY_HOME="${SANDBOX}/totally-empty-cap"
mkdir -p "${EMPTY_HOME}"
set +e
OUT5="$("${PYTHON_BIN}" "${CLI_PY}" inspect "${EMPTY_STATUS}" "run_nonexistent" \
  --cap-home "${EMPTY_HOME}" 2>&1)"
RC5=$?
set -e
assert_eq "missing: exit 1" "1" "${RC5}"
assert_contains "missing: error message" "${OUT5}" "找不到 run_id"

# ── Case 6: CAP_HOME env var → resolution without --cap-home ──────────
#
# Without the explicit ``--cap-home`` flag, cmd_inspect must honour
# the ``CAP_HOME`` env var (mirrors how cap-paths.sh resolves cap_home
# elsewhere). The Case 1 fixture is reused so the only difference is
# how the run_dir path is communicated.

echo ""
echo "Case 6: CAP_HOME env var (no --cap-home flag) → resolves run_dir"
OUT6="$(CAP_HOME="$(cap_home_for withjson)" "${PYTHON_BIN}" "${CLI_PY}" inspect \
  "${EMPTY_STATUS}" "run_withjson" 2>&1)"
RC6=$?
assert_eq "envhome: exit 0" "0" "${RC6}"
assert_contains "envhome: Run Header heading"  "${OUT6}" "# Run Header"
assert_contains "envhome: workflow_id field"   "${OUT6}" "workflow_id:   inspect-wf"
assert_contains "envhome: run_id field"        "${OUT6}" "run_id:        run_withjson"
assert_contains "envhome: final_state field"   "${OUT6}" "final_state:   completed"

# ── Case 7: inspect text view shows # Inputs when pointers populated ──
#
# Exercises the P7 #2 minimal-pointer rendering in cmd_inspect's text
# view: when the cap-storage subdirs exist on disk, the # Inputs
# section should appear with the three directory pointers; absent
# when all three are null (covered by Cases 1 / 3 implicitly — those
# fixtures don't stage the dirs and the section is correctly omitted).

echo ""
echo "Case 7: inputs pointers populated → inspect text shows # Inputs"
RUN7="$(stage_run_dir withinputs)"
CAP7="$(cap_home_for withinputs)"
mkdir -p "${CAP7}/projects/inspect-proj/constitutions"
mkdir -p "${CAP7}/projects/inspect-proj/compiled-workflows/inspect-wf"
mkdir -p "${CAP7}/projects/inspect-proj/bindings/inspect-wf"
emit_result_json "${RUN7}" "${CAP7}"

OUT7="$("${PYTHON_BIN}" "${CLI_PY}" inspect "${EMPTY_STATUS}" "run_withinputs" \
  --cap-home "${CAP7}" 2>&1)"
RC7=$?
assert_eq "inputs: exit 0" "0" "${RC7}"
assert_contains "inputs: # Inputs section header"        "${OUT7}" "# Inputs"
assert_contains "inputs: constitution_dir line"          "${OUT7}" "constitution_dir:"
assert_contains "inputs: compiled_workflow_dir line"     "${OUT7}" "compiled_workflow_dir:"
assert_contains "inputs: binding_dir line"               "${OUT7}" "binding_dir:"
# Sanity: Case 1 (withjson, no dirs staged) must NOT show # Inputs.
assert_not_contains "withjson(case1) omits # Inputs"     "${OUT1}" "# Inputs"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
