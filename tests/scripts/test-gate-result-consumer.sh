#!/usr/bin/env bash
#
# test-gate-result-consumer.sh — P8 #6 fail-route handling consumer contract.
#
# Verifies the engine/step_runtime.py consume-gate-result subcommand
# (engine/gate_result_consumer.py) translates gate-result envelopes
# into runtime routing decisions correctly. This is the **first
# consumer-side test** in the gate-runner family; sibling tests
# exercise producer round-trips, this one exercises decision logic
# from the controller's perspective.
#
# Coverage maps directly to the user's acceptance criteria:
#   1. pass envelope → decision=proceed, no halt
#   2. warn envelope → decision=proceed, no halt
#   3. fail + halt → decision=halt
#   4. fail + route_back + route_back_to_step=ba → decision=route_back, route_back_to_step=ba
#   5. fail + route_back without route_back_to_step → conservative halt
#   6. fail + retry → decision=retry_unsupported (P8 #6 v1 boundary)
#   7. fail + escalate → decision=escalate, needs_supervisor=true
#   8. fail + none → decision=defer_to_workflow_yaml
#   9. blocked + missing fail_routing → conservative halt + needs_supervisor=true
#  10. malformed JSON envelope → exit 1 reason=parse_error
#  11. schema-invalid envelope (e.g. result not in enum) → exit 41 reason=gate_result_schema_invalid
#  12. missing artifact → exit 1 reason=missing_artifact
#  13. --workflow-log appends one line per call
#  14. --route-history appends one JSONL record per call
#  15. real producer envelope (watcher pass) → consumer reads clean
#  16. real producer envelope (watcher blocked) → consumer halts

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"

[ -f "${STEP_PY}" ] || { echo "FAIL: engine/step_runtime.py missing"; exit 1; }

VENV_PY="${REPO_ROOT}/.venv/bin/python"
if [ -x "${VENV_PY}" ]; then
  PYTHON_BIN="${VENV_PY}"
else
  PYTHON_BIN="python3"
fi

SANDBOX="$(mktemp -d -t cap-gate-consumer-test.XXXXXX)"
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

# Helper: write a hand-crafted envelope to ${SANDBOX}/<name>.json and
# return the path. We deliberately use hand-crafted fixtures rather
# than running real producers because the consumer's contract is
# decision derivation from any valid envelope, not specifically the
# four producers we shipped.
write_envelope() {
  local name="$1" body="$2"
  local path="${SANDBOX}/${name}.json"
  printf '%s\n' "${body}" > "${path}"
  printf '%s' "${path}"
}

# Helper: run consumer, return stdout. Caller checks rc + content.
run_consume() {
  cd "${REPO_ROOT}" && "${PYTHON_BIN}" "${STEP_PY}" consume-gate-result "$@" 2>&1
}

# ── Common envelope shells ─────────────────────────────────────────────

IDENTITY='"schema_version": 1,
  "gate_id": "spec_audit",
  "gate_type": "watcher",
  "checkpoint": "spec_phase",
  "workflow_id": "project-spec-pipeline",
  "run_id": "run_20260506000000_test0001",
  "step_id": "spec_audit",
  "project_id": "consumer-test",
  "produced_at": "2026-05-06T00:00:00+08:00",
  "produced_by": "90-Watcher",
  "target_artifacts": ["/run/spec.md"],
  "summary": "test",
  "findings": []'

# ── Case 1: pass envelope → proceed ────────────────────────────────────
echo "Case 1: pass envelope → decision=proceed"
PATH_1="$(write_envelope "case1-pass" "{
  ${IDENTITY},
  \"result\": \"pass\",
  \"risk_level\": \"none\"
}")"
out1="$(run_consume "${PATH_1}")"
rc1=$?
assert_eq        "rc 0 pass"                "0"             "${rc1}"
assert_contains  "decision=proceed"         "decision=proceed" "${out1}"
assert_contains  "result=pass"              "result=pass"    "${out1}"
assert_contains  "needs_supervisor=false"   "needs_supervisor=false" "${out1}"

# ── Case 2: warn envelope → proceed ────────────────────────────────────
echo "Case 2: warn envelope → decision=proceed (warn does not halt)"
PATH_2="$(write_envelope "case2-warn" "{
  ${IDENTITY},
  \"result\": \"warn\",
  \"risk_level\": \"medium\"
}")"
out2="$(run_consume "${PATH_2}")"
rc2=$?
assert_eq        "rc 0 warn"                "0"             "${rc2}"
assert_contains  "decision=proceed (warn)"  "decision=proceed" "${out2}"
assert_contains  "result=warn"              "result=warn"    "${out2}"

# ── Case 3: fail + halt → halt ─────────────────────────────────────────
echo "Case 3: fail + fail_routing.action=halt → decision=halt"
PATH_3="$(write_envelope "case3-fail-halt" "{
  ${IDENTITY},
  \"result\": \"fail\",
  \"risk_level\": \"critical\",
  \"fail_routing\": {
    \"action\": \"halt\",
    \"route_back_to_step\": null,
    \"reason\": \"Critical secret leak; halt before push.\"
  }
}")"
out3="$(run_consume "${PATH_3}")"
rc3=$?
assert_eq        "rc 0 fail+halt"           "0"             "${rc3}"
assert_contains  "decision=halt"            "decision=halt" "${out3}"
assert_contains  "reason carries producer text" "Critical secret leak" "${out3}"

# ── Case 4: fail + route_back → route_back ─────────────────────────────
echo "Case 4: fail + route_back + route_back_to_step=ba → decision=route_back"
PATH_4="$(write_envelope "case4-fail-routeback" "{
  ${IDENTITY},
  \"result\": \"fail\",
  \"risk_level\": \"high\",
  \"fail_routing\": {
    \"action\": \"route_back\",
    \"route_back_to_step\": \"ba\",
    \"reason\": \"Spec drift; rerun BA.\"
  }
}")"
out4="$(run_consume "${PATH_4}")"
rc4=$?
assert_eq        "rc 0 fail+route_back"            "0"             "${rc4}"
assert_contains  "decision=route_back"             "decision=route_back" "${out4}"
assert_contains  "route_back_to_step=ba"           "route_back_to_step=ba" "${out4}"
assert_contains  "needs_supervisor=false"          "needs_supervisor=false" "${out4}"

# ── Case 5: fail + route_back missing target → conservative halt ───────
echo "Case 5: fail + route_back without route_back_to_step → conservative halt"
PATH_5="$(write_envelope "case5-routeback-no-target" "{
  ${IDENTITY},
  \"result\": \"fail\",
  \"risk_level\": \"high\",
  \"fail_routing\": {
    \"action\": \"route_back\",
    \"route_back_to_step\": null,
    \"reason\": \"Producer forgot to declare target step.\"
  }
}")"
out5="$(run_consume "${PATH_5}")"
rc5=$?
assert_eq        "rc 0 conservative halt"           "0"             "${rc5}"
assert_contains  "decision=halt (downgrade)"        "decision=halt" "${out5}"
assert_contains  "needs_supervisor=true"            "needs_supervisor=true" "${out5}"

# ── Case 6: fail + retry → retry_unsupported ───────────────────────────
echo "Case 6: fail + fail_routing.action=retry → decision=retry_unsupported (P8 #6 v1 boundary)"
PATH_6="$(write_envelope "case6-fail-retry" "{
  ${IDENTITY},
  \"result\": \"fail\",
  \"risk_level\": \"high\",
  \"fail_routing\": {
    \"action\": \"retry\",
    \"route_back_to_step\": null,
    \"reason\": \"Flaky env; rerun the same gate.\"
  }
}")"
out6="$(run_consume "${PATH_6}")"
rc6=$?
assert_eq        "rc 0 retry_unsupported"            "0"             "${rc6}"
assert_contains  "decision=retry_unsupported"        "decision=retry_unsupported" "${out6}"
assert_contains  "needs_supervisor=true (retry)"     "needs_supervisor=true"      "${out6}"
assert_contains  "reason mentions overlap with P8 #8" "overlaps P8 #8"            "${out6}"

# ── Case 7: fail + escalate → escalate + needs_supervisor=true ─────────
echo "Case 7: fail + fail_routing.action=escalate → decision=escalate"
PATH_7="$(write_envelope "case7-fail-escalate" "{
  ${IDENTITY},
  \"result\": \"fail\",
  \"risk_level\": \"high\",
  \"fail_routing\": {
    \"action\": \"escalate\",
    \"route_back_to_step\": null,
    \"reason\": \"High-severity findings; supervisor decides.\"
  }
}")"
out7="$(run_consume "${PATH_7}")"
rc7=$?
assert_eq        "rc 0 escalate"                    "0"             "${rc7}"
assert_contains  "decision=escalate"                "decision=escalate" "${out7}"
assert_contains  "needs_supervisor=true"            "needs_supervisor=true" "${out7}"

# ── Case 8: fail + none → defer_to_workflow_yaml ──────────────────────
echo "Case 8: fail + fail_routing.action=none → decision=defer_to_workflow_yaml"
PATH_8="$(write_envelope "case8-fail-none" "{
  ${IDENTITY},
  \"result\": \"fail\",
  \"risk_level\": \"high\",
  \"fail_routing\": {
    \"action\": \"none\",
    \"route_back_to_step\": null,
    \"reason\": \"Producer declined; workflow YAML decides.\"
  }
}")"
out8="$(run_consume "${PATH_8}")"
rc8=$?
assert_eq        "rc 0 defer"                       "0"             "${rc8}"
assert_contains  "decision=defer_to_workflow_yaml"  "decision=defer_to_workflow_yaml" "${out8}"

# ── Case 9: blocked + missing fail_routing → conservative halt ────────
echo "Case 9: blocked + fail_routing absent → conservative halt with needs_supervisor=true"
PATH_9="$(write_envelope "case9-blocked-no-routing" "{
  ${IDENTITY},
  \"result\": \"blocked\",
  \"risk_level\": \"high\"
}")"
out9="$(run_consume "${PATH_9}")"
rc9=$?
assert_eq        "rc 0 blocked-no-routing"          "0"             "${rc9}"
assert_contains  "decision=halt"                    "decision=halt" "${out9}"
assert_contains  "needs_supervisor=true"            "needs_supervisor=true" "${out9}"
assert_contains  "reason mentions absent"           "fail_routing absent" "${out9}"

# ── Case 10: malformed JSON → exit 1 parse_error ──────────────────────
echo "Case 10: malformed JSON envelope → exit 1 reason=parse_error"
PATH_10="${SANDBOX}/case10-malformed.json"
echo "this is { not json" > "${PATH_10}"
out10="$(run_consume "${PATH_10}")"
rc10=$?
assert_eq        "rc 1 parse_error"                  "1"             "${rc10}"
assert_contains  "reason=parse_error"                "reason=parse_error" "${out10}"

# ── Case 11: schema-invalid envelope → exit 41 ────────────────────────
echo "Case 11: schema-invalid envelope (result not in enum) → exit 41"
PATH_11="$(write_envelope "case11-schema-bad" "{
  ${IDENTITY},
  \"result\": \"maybe\",
  \"risk_level\": \"low\"
}")"
out11="$(run_consume "${PATH_11}")"
rc11=$?
assert_eq        "rc 41 schema_validation_failed"    "41"            "${rc11}"
assert_contains  "reason=gate_result_schema_invalid" "reason=gate_result_schema_invalid" "${out11}"

# ── Case 12: missing artifact → exit 1 missing_artifact ───────────────
echo "Case 12: missing artifact → exit 1 reason=missing_artifact"
out12="$(run_consume "${SANDBOX}/no-such-envelope.json")"
rc12=$?
assert_eq        "rc 1 missing_artifact"             "1"             "${rc12}"
assert_contains  "reason=missing_artifact"           "reason=missing_artifact" "${out12}"

# ── Case 13: --workflow-log appends one line per call ─────────────────
echo "Case 13: --workflow-log appends one line per consume call"
LOG_PATH="${SANDBOX}/workflow.log"
run_consume "${PATH_3}" --workflow-log "${LOG_PATH}" >/dev/null
run_consume "${PATH_4}" --workflow-log "${LOG_PATH}" >/dev/null
log_lines="$(wc -l < "${LOG_PATH}" | tr -d ' ')"
assert_eq        "workflow.log line count"          "2"             "${log_lines}"
assert_contains  "log carries gate id"              "gate=spec_audit" "$(cat "${LOG_PATH}")"
assert_contains  "log carries decision=halt"        "decision=halt"   "$(cat "${LOG_PATH}")"
assert_contains  "log carries decision=route_back"  "decision=route_back" "$(cat "${LOG_PATH}")"

# ── Case 14: --route-history appends JSONL records ────────────────────
echo "Case 14: --route-history appends one JSON line per consume call"
HIST_PATH="${SANDBOX}/route-history.jsonl"
run_consume "${PATH_3}" --route-history "${HIST_PATH}" >/dev/null
run_consume "${PATH_4}" --route-history "${HIST_PATH}" >/dev/null
hist_lines="$(wc -l < "${HIST_PATH}" | tr -d ' ')"
assert_eq        "route-history line count"         "2"             "${hist_lines}"
# Each line must be valid JSON with the required shape.
hist_check="$("${PYTHON_BIN}" - "${HIST_PATH}" <<'PY'
import json, sys
ok = True
required = {"timestamp", "decision", "result", "risk_level", "reason",
            "route_back_to_step", "needs_supervisor", "notes",
            "source_gate_id", "source_step_id", "consumer_version"}
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except Exception:
        ok = False
        break
    if not required.issubset(rec.keys()):
        ok = False
        break
print("ok" if ok else "fail")
PY
)"
assert_eq        "route-history records validate"   "ok"            "${hist_check}"

# ── Case 15: real producer envelope (watcher pass) round-trip ─────────
echo "Case 15: real producer (watcher pass) → consumer decision=proceed"
ART_DIR="${SANDBOX}/producer"
mkdir -p "${ART_DIR}"
echo "# spec body" > "${ART_DIR}/spec.md"
PRODUCER_OUT="${ART_DIR}/spec_audit.gate-result.json"
"${PYTHON_BIN}" "${STEP_PY}" run-watcher-gate \
  --gate-id spec_audit --checkpoint spec_phase \
  --workflow-id project-spec-pipeline --run-id run_test_real_pass \
  --step-id spec_audit --project-id consumer-test \
  --target-artifact "${ART_DIR}/spec.md" \
  --output "${PRODUCER_OUT}" >/dev/null
out15="$(run_consume "${PRODUCER_OUT}")"
rc15=$?
assert_eq        "rc 0 real-producer pass"           "0"             "${rc15}"
assert_contains  "decision=proceed"                  "decision=proceed" "${out15}"

# ── Case 16: real producer envelope (watcher blocked) → consumer halts ─
echo "Case 16: real producer (watcher blocked) → consumer decision=halt"
PRODUCER_OUT_B="${ART_DIR}/missing_audit.gate-result.json"
"${PYTHON_BIN}" "${STEP_PY}" run-watcher-gate \
  --gate-id missing_audit --checkpoint impl_phase \
  --workflow-id project-spec-pipeline --run-id run_test_real_blocked \
  --step-id missing_audit --project-id consumer-test \
  --output "${PRODUCER_OUT_B}" >/dev/null
out16="$(run_consume "${PRODUCER_OUT_B}")"
rc16=$?
assert_eq        "rc 0 real-producer blocked"        "0"             "${rc16}"
assert_contains  "decision=halt"                     "decision=halt" "${out16}"

echo ""
echo "gate-result-consumer: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
