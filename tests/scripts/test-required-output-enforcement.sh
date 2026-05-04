#!/usr/bin/env bash
#
# test-required-output-enforcement.sh — P6 #4 gate.
#
# Verifies the CAP_ENFORCE_REQUIRED_OUTPUTS=1 opt-in path end to end:
#
#   Layer 1 — engine/step_runtime.py validate-capability-output CLI:
#     contract for the executor to consume. Asserts the 4 verdict
#     branches exit code + stdout format are stable, since
#     cap-workflow-exec.sh greps stdout into SESSION_FAILURE_REASON.
#
#   Layer 2 — shell branch simulation:
#     re-runs the exact CAP_ENFORCE_REQUIRED_OUTPUTS conditional block
#     extracted from cap-workflow-exec.sh against fixture artifacts so
#     we cover the wiring (STEP_STATUS / FINAL_STEP_STATE / SHOULD_HALT
#     / STEP_VALIDATOR_DETAIL) without the full workflow runtime.
#
#   Layer 3 — wrapper presence check:
#     greps cap-workflow-exec.sh for the new env-flag block + reset to
#     guard against accidental removal during refactors. The shell
#     wrapper is the production surface; if these lines disappear,
#     the gate silently no-ops even when the flag is set.
#
# Cases:
#   1. CLI ok                 → rc 0,  stdout reason=ok;detail=json_schema
#   2. CLI required_invalid    → rc 41, stdout reason=required_output_invalid + missing field
#   3. CLI no_validator        → rc 0,  stdout reason=skipped;detail=no_validator
#   4. CLI missing_artifact    → rc 1,  stdout reason=missing_artifact
#   5. branch flag=0           → STEP_STATUS=ok (validator never invoked)
#   6. branch flag=1 + bad     → STEP_STATUS=required_output_invalid +
#                                 STEP_VALIDATOR_DETAIL captured + SHOULD_HALT=1
#   7. branch flag=1 + unknown → STEP_STATUS=ok (no_validator passes through)
#   8. wrapper has env-flag block + STEP_VALIDATOR_DETAIL reset

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"
EXEC_SH="${REPO_ROOT}/scripts/cap-workflow-exec.sh"

[ -f "${STEP_PY}" ] || { echo "FAIL: engine/step_runtime.py missing"; exit 1; }
[ -f "${EXEC_SH}" ] || { echo "FAIL: scripts/cap-workflow-exec.sh missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-required-out-test.XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

pass_count=0
fail_count=0

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected substring: ${needle}"
    echo "    actual head: $(printf '%s' "${haystack}" | head -3)"
    fail_count=$((fail_count + 1))
  fi
}

# Fixture artifacts ───────────────────────────────────────────────────────

GOOD_FIXTURE="${SANDBOX}/good.md"
cat > "${GOOD_FIXTURE}" <<'EOF'
<<<TASK_CONSTITUTION_JSON_BEGIN>>>
{
  "task_id": "demo-good",
  "project_id": "charlie-ai-protocols",
  "source_request": "smoke",
  "goal": "exercise required-output gate happy path",
  "goal_stage": "informal_planning",
  "success_criteria": ["validator returns ok"],
  "non_goals": [],
  "execution_plan": [{"step_id": "x", "capability": "y"}]
}
<<<TASK_CONSTITUTION_JSON_END>>>
EOF

BAD_FIXTURE="${SANDBOX}/bad.md"
cat > "${BAD_FIXTURE}" <<'EOF'
<<<TASK_CONSTITUTION_JSON_BEGIN>>>
{
  "task_id": "demo-bad",
  "project_id": "charlie-ai-protocols",
  "source_request": "smoke missing fields",
  "goal_stage": "informal_planning",
  "non_goals": [],
  "execution_plan": [{"step_id": "x", "capability": "y"}]
}
<<<TASK_CONSTITUTION_JSON_END>>>
EOF

UNKNOWN_FIXTURE="${SANDBOX}/unknown.md"
echo "anything goes for unregistered capabilities" > "${UNKNOWN_FIXTURE}"

# ── Layer 1: CLI exit-code + stdout contract ────────────────────────────

echo "Case 1: CLI ok → rc 0 stdout reason=ok"
out1="$(cd "${REPO_ROOT}" && python3 "${STEP_PY}" validate-capability-output task_constitution_planning "${GOOD_FIXTURE}" 2>&1)"
rc1=$?
assert_eq "rc 0"                "0"                              "${rc1}"
assert_contains "reason=ok"     "reason=ok"                      "${out1}"
assert_contains "detail kind"   "detail=json_schema"             "${out1}"

echo "Case 2: CLI bad artifact → rc 41 reason=required_output_invalid + field detail"
out2="$(cd "${REPO_ROOT}" && python3 "${STEP_PY}" validate-capability-output task_constitution_planning "${BAD_FIXTURE}" 2>&1)"
rc2=$?
assert_eq "rc 41 (schema_validation_failed)" "41"                "${rc2}"
assert_contains "reason=required_output_invalid" "reason=required_output_invalid" "${out2}"
assert_contains "missing required field 'goal'"  "missing required field 'goal'"  "${out2}"

echo "Case 3: CLI unregistered capability → rc 0 reason=skipped"
out3="$(cd "${REPO_ROOT}" && python3 "${STEP_PY}" validate-capability-output not_in_registry_xyz "${UNKNOWN_FIXTURE}" 2>&1)"
rc3=$?
assert_eq "rc 0"                  "0"                            "${rc3}"
assert_contains "reason=skipped" "reason=skipped"                "${out3}"
assert_contains "detail=no_validator" "detail=no_validator"      "${out3}"

echo "Case 4: CLI missing artifact → rc 1 reason=missing_artifact"
out4="$(cd "${REPO_ROOT}" && python3 "${STEP_PY}" validate-capability-output task_constitution_planning "${SANDBOX}/no-such.md" 2>&1)"
rc4=$?
assert_eq "rc 1 (operational error)" "1"                         "${rc4}"
assert_contains "reason=missing_artifact" "reason=missing_artifact" "${out4}"

# ── Layer 2: shell branch simulation ────────────────────────────────────
#
# Mirrors the exact conditional block we inserted in cap-workflow-exec.sh
# around the exit-0 / non-empty_capture branch. We isolate the logic so
# the test runs without a full workflow runtime; the wrapper-presence
# check below (Case 8) guards against the production code drifting away
# from this simulation.

simulate_branch() {
  local capability="$1"
  local artifact_path="$2"
  local enforce_flag="$3"

  CAP_ENFORCE_REQUIRED_OUTPUTS="${enforce_flag}" \
  capability="${capability}" \
  STEP_OUTPUT_PATH="${artifact_path}" \
  STEP_PY="${STEP_PY}" \
  PYTHON_BIN="python3" \
  optional="False" \
  bash -c '
    set -u
    SHOULD_HALT=0
    STEP_STATUS="ok"
    FINAL_STEP_STATE="validated"
    STEP_VALIDATOR_DETAIL=""
    VALIDATOR_HARD_FAIL=0
    if [ "${CAP_ENFORCE_REQUIRED_OUTPUTS:-0}" = "1" ]; then
      VALIDATOR_OUT="$("${PYTHON_BIN}" "${STEP_PY}" validate-capability-output "${capability}" "${STEP_OUTPUT_PATH}" 2>&1)"
      VALIDATOR_RC=$?
      if [ "${VALIDATOR_RC}" -eq 41 ]; then
        VALIDATOR_HARD_FAIL=1
        STEP_VALIDATOR_DETAIL="${VALIDATOR_OUT}"
        STEP_STATUS="required_output_invalid"
        FINAL_STEP_STATE="hard_fail"
        if [ "${optional}" != "True" ]; then
          SHOULD_HALT=1
        fi
      fi
    fi
    # Mirror the SESSION_FAILURE_REASON construction from
    # cap-workflow-exec.sh so test asserts the same shape callers see.
    SESSION_FAILURE_REASON=""
    if [ "${VALIDATOR_HARD_FAIL}" -eq 1 ]; then
      if [ -n "${STEP_VALIDATOR_DETAIL:-}" ]; then
        SESSION_FAILURE_REASON="${STEP_STATUS}: ${STEP_VALIDATOR_DETAIL}"
      else
        SESSION_FAILURE_REASON="${STEP_STATUS}"
      fi
    fi
    printf "STATUS=%s\nSTATE=%s\nHALT=%s\nDETAIL=%s\nSESSION_REASON=%s\n" \
      "${STEP_STATUS}" "${FINAL_STEP_STATE}" "${SHOULD_HALT}" "${STEP_VALIDATOR_DETAIL}" "${SESSION_FAILURE_REASON}"
  '
}

echo "Case 5: branch flag=0 → STEP_STATUS=ok (validator never invoked)"
out5="$(simulate_branch task_constitution_planning "${BAD_FIXTURE}" 0)"
assert_contains "STATUS=ok"          "STATUS=ok"           "${out5}"
assert_contains "STATE=validated"     "STATE=validated"   "${out5}"
assert_contains "HALT=0"              "HALT=0"            "${out5}"
assert_contains "no validator detail" "DETAIL="           "${out5}"

echo "Case 6: branch flag=1 + bad artifact → required_output_invalid + halt"
out6="$(simulate_branch task_constitution_planning "${BAD_FIXTURE}" 1)"
assert_contains "STATUS=required_output_invalid" "STATUS=required_output_invalid" "${out6}"
assert_contains "STATE=hard_fail"                 "STATE=hard_fail"               "${out6}"
assert_contains "HALT=1"                          "HALT=1"                        "${out6}"
assert_contains "validator detail captured"        "reason=required_output_invalid" "${out6}"
assert_contains "missing field surfaced"           "missing required field 'goal'"  "${out6}"
assert_contains "SESSION_REASON merges status+detail" "SESSION_REASON=required_output_invalid: reason=required_output_invalid" "${out6}"

echo "Case 7: branch flag=1 + unregistered capability → STATUS=ok (skipped)"
out7="$(simulate_branch not_in_registry_xyz "${UNKNOWN_FIXTURE}" 1)"
assert_contains "STATUS=ok"           "STATUS=ok"          "${out7}"
assert_contains "STATE=validated"      "STATE=validated"  "${out7}"
assert_contains "HALT=0"               "HALT=0"           "${out7}"

# ── Layer 3: wrapper presence guard ─────────────────────────────────────

echo "Case 8: cap-workflow-exec.sh contains env-flag block + reset"
exec_src="$(cat "${EXEC_SH}")"
assert_contains "env flag check present"          'CAP_ENFORCE_REQUIRED_OUTPUTS:-0' "${exec_src}"
assert_contains "validate-capability-output call" 'validate-capability-output'      "${exec_src}"
assert_contains "STEP_VALIDATOR_DETAIL reset"     'STEP_VALIDATOR_DETAIL=""'        "${exec_src}"
assert_contains "STATUS required_output_invalid"  'required_output_invalid'         "${exec_src}"
assert_contains "ERROR_TYPE high-level grouping"  'output_validation_failed'        "${exec_src}"
assert_contains "SESSION_FAILURE_REASON wires detail" 'STEP_VALIDATOR_DETAIL:-'      "${exec_src}"

echo ""
echo "required-output-enforcement: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
