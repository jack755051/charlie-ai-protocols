#!/usr/bin/env bash
#
# test-workflow-dry-run-inspection.sh — P4 #11 gate.
#
# Verifies that engine.workflow_cli.cmd_print_compiled_dry_run, when
# given the new optional --preflight-json + --binding-json flags
# (P4 #11 wiring), renders a human-readable inspection that includes
# preflight executable status, gate summary, warnings, blocking
# reasons, and per-step capability / provider / skill / status
# alongside the existing constitution + unresolved_policy + phases
# sections.
#
# Coverage (subprocess invocation of the renderer; no AI / no shell
# wiring of run-task to keep the test hermetic and avoid the cost of
# spinning up a sandbox CAP_HOME):
#
#   Case 1 default exit 0:        invoking print-compiled-dry-run
#                                 without the new flags still succeeds
#                                 (backward-compat with pre-P4-#11
#                                 callers).
#   Case 2 preflight rendered:    with --preflight-json, the output
#                                 includes workflow_id, binding_status,
#                                 is_executable, gate summary, warnings
#                                 and blocking_reasons sections.
#   Case 3 binding step detail:   with --binding-json, the output
#                                 includes per-step capability /
#                                 provider / selected skill /
#                                 resolution_status lines.
#   Case 4 no execution side-effect: running the renderer in an empty
#                                    sandbox does not create any files
#                                    in the sandbox CWD (proves the
#                                    dry-run path is print-only and
#                                    does not invoke any executor or
#                                    write run-state artifacts).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

[ -f "${REPO_ROOT}/engine/workflow_cli.py" ] || {
  echo "FAIL: engine/workflow_cli.py missing"; exit 1;
}

PYTHON_BIN="python3"
CLI_PY="${REPO_ROOT}/engine/workflow_cli.py"

SANDBOX="$(mktemp -d -t cap-dryrun-test.XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

pass_count=0
fail_count=0

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected to contain: ${needle}"
    echo "    actual head: $(printf '%s' "${haystack}" | head -5)"
    fail_count=$((fail_count + 1))
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected: ${expected}"
    echo "    actual:   ${actual}"
    fail_count=$((fail_count + 1))
  fi
}

# Build minimal JSON inputs that satisfy the renderer's accessors.
CONSTITUTION_JSON='{"task_id":"task_dryrun_001","goal_stage":"informal_planning","risk_profile":"low"}'
POLICY_JSON='{"decisions":[{"step_id":"prd","action":"execute","resolution_status":"resolved"}]}'
PLAN_JSON='{"phases":[{"phase":1,"steps":[{"step_id":"prd","agent_alias":"prd-bot","skill_id":"prd-skill"}]}],"standby_steps":[]}'
SNAPSHOT_JSON='{"constitution_json_path":"/tmp/cj","binding_json_path":"/tmp/bj","bundle_dir":"/tmp/bundle"}'
PREFLIGHT_JSON='{"schema_version":1,"workflow_id":"compiled-task_dryrun_001","binding_status":"degraded","is_executable":true,"gates":{"compiled_workflow_schema":"passed","binding_report_schema":"passed","binding_policy":"passed","source_root_policy":"passed"},"unresolved_summary":{"total_steps":2,"resolved_steps":1,"fallback_steps":1,"unresolved_optional_steps":0},"warnings":["1 step(s) bound to a fallback skill; review before run"],"blocking_reasons":[]}'
BINDING_JSON='{"schema_version":1,"workflow_id":"compiled-task_dryrun_001","workflow_version":2,"binding_status":"degraded","summary":{"total_steps":2,"resolved_steps":1,"fallback_steps":1,"unresolved_required_steps":0,"unresolved_optional_steps":0},"steps":[{"step_id":"prd","capability":"prd_generation","optional":false,"resolution_status":"resolved","selected_provider":"claude","selected_skill_id":"prd-skill"},{"step_id":"tech","capability":"tech_planning","optional":false,"resolution_status":"fallback_available","selected_provider":"codex","selected_skill_id":"generic-tech"}]}'

# ── Case 1 ──────────────────────────────────────────────────────────────
echo "Case 1: print-compiled-dry-run without new flags → exit 0 (backward-compat)"
out1="$( "${PYTHON_BIN}" "${CLI_PY}" print-compiled-dry-run "${CONSTITUTION_JSON}" "${POLICY_JSON}" "${PLAN_JSON}" "${SNAPSHOT_JSON}" 2>&1 )"
exit1=$?
assert_eq "exit 0 backward-compat"  "0"                   "${exit1}"
assert_contains "constitution rendered" "task_id: task_dryrun_001"  "${out1}"
assert_contains "phases section"        "phases:"                    "${out1}"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: with --preflight-json → preflight section rendered"
out2="$( "${PYTHON_BIN}" "${CLI_PY}" print-compiled-dry-run "${CONSTITUTION_JSON}" "${POLICY_JSON}" "${PLAN_JSON}" "${SNAPSHOT_JSON}" --preflight-json "${PREFLIGHT_JSON}" 2>&1 )"
exit2=$?
assert_eq        "exit 0 with preflight"             "0"                                 "${exit2}"
assert_contains  "preflight section header"           "preflight:"                       "${out2}"
assert_contains  "workflow_id surfaced"               "workflow_id: compiled-task_dryrun_001"  "${out2}"
assert_contains  "binding_status surfaced"            "binding_status: degraded"          "${out2}"
assert_contains  "is_executable surfaced"             "is_executable: True"               "${out2}"
assert_contains  "step counts surfaced"               "total=2 resolved=1 fallback=1"     "${out2}"
assert_contains  "gates summary line"                 "gates: binding_policy=passed binding_report_schema=passed compiled_workflow_schema=passed source_root_policy=passed"  "${out2}"
assert_contains  "warning bullet rendered"            "1 step(s) bound to a fallback skill" "${out2}"
assert_contains  "blocking_reasons (none)"            "blocking_reasons: (none)"          "${out2}"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: with --binding-json → binding_steps section rendered"
out3="$( "${PYTHON_BIN}" "${CLI_PY}" print-compiled-dry-run "${CONSTITUTION_JSON}" "${POLICY_JSON}" "${PLAN_JSON}" "${SNAPSHOT_JSON}" --preflight-json "${PREFLIGHT_JSON}" --binding-json "${BINDING_JSON}" 2>&1 )"
exit3=$?
assert_eq        "exit 0 with both flags"             "0"                                       "${exit3}"
assert_contains  "binding_steps header"               "binding_steps:"                          "${out3}"
assert_contains  "prd step capability+provider+skill" "prd: capability=prd_generation provider=claude skill=prd-skill status=resolved" "${out3}"
assert_contains  "tech step shows fallback skill"      "tech: capability=tech_planning provider=codex skill=generic-tech status=fallback_available" "${out3}"

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: print-only — no files created in CWD by renderer"
PRE_LISTING="$(ls -A "${SANDBOX}" 2>/dev/null | wc -l | tr -d ' ')"
( cd "${SANDBOX}" && "${PYTHON_BIN}" "${CLI_PY}" print-compiled-dry-run "${CONSTITUTION_JSON}" "${POLICY_JSON}" "${PLAN_JSON}" "${SNAPSHOT_JSON}" --preflight-json "${PREFLIGHT_JSON}" --binding-json "${BINDING_JSON}" >/dev/null 2>&1 )
POST_LISTING="$(ls -A "${SANDBOX}" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "no files written by renderer" "${PRE_LISTING}" "${POST_LISTING}"

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "workflow-dry-run-inspection: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
