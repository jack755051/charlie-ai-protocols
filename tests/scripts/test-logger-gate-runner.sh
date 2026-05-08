#!/usr/bin/env bash
#
# test-logger-gate-runner.sh — P8 #5 Logger milestone runner contract.
#
# Verifies the engine/step_runtime.py run-logger-gate subcommand
# (engine/logger_gate_runner.py) acts as the fourth concrete producer
# for schemas/gate-result.schema.yaml. Test shape mirrors
# test-watcher-gate-runner / test-security-gate-runner /
# test-qa-gate-runner; only the check semantics differ. Logger is
# unique in:
#
#   - taking dedicated artifact flags (--workflow-result / --result-md
#     / --archive-summary) instead of generic --target-artifact
#   - validating P7 workflow-result.json against its own schema
#   - extracting metrics from a structured upstream payload (final_state,
#     summary counts, failure / artifact / session counts)
#   - having a mode-aware (milestone | final) archive-summary policy
#
# Coverage:
#   1. happy path: workflow-result + result.md + archive-summary, mode=final
#   2. milestone mode + missing archive-summary → result=warn risk=medium
#   3. final mode + missing archive-summary → result=blocked risk=high halt
#   4. result.md missing only → result=warn risk=medium
#   5. workflow-result missing → result=blocked risk=high halt
#   6. workflow-result empty → result=blocked risk=high halt
#   7. workflow-result invalid JSON → result=blocked risk=high halt
#   8. workflow-result schema invalid → result=blocked risk=high halt
#   9. only workflow-result provided (no result.md / archive) → pass
#  10. metrics propagation: final_state / final_result / counts
#  11. default --output resolves to cwd/<step_id>.gate-result.json
#  12. round-trip with validate-gate-result CLI on all envelopes
#  13. --produced-by / --gate-subtype / --task-id propagate

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

SANDBOX="$(mktemp -d -t cap-logger-runner-test.XXXXXX)"
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
  if grep -qF -- "${needle}" <<<"${haystack}"; then
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected substring: ${needle}"
    echo "    actual head: $(printf '%s' "${haystack}" | head -3)"
    fail_count=$((fail_count + 1))
  fi
}

read_field() {
  local path="$1" key="$2"
  "${PYTHON_BIN}" - "${path}" "${key}" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    data = json.loads(open(path, encoding="utf-8").read())
except Exception:
    print("<absent>")
    sys.exit(0)
val = data.get(key, "<absent>")
print(val if isinstance(val, str) else json.dumps(val, ensure_ascii=False))
PY
}

read_metric() {
  local path="$1" key="$2"
  "${PYTHON_BIN}" - "${path}" "${key}" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    data = json.loads(open(path, encoding="utf-8").read())
except Exception:
    print("<absent>")
    sys.exit(0)
metrics = data.get("metrics", {})
val = metrics.get(key, "<absent>")
print(val if isinstance(val, str) else json.dumps(val, ensure_ascii=False))
PY
}

read_nested_field() {
  local path="$1" outer="$2" inner="$3"
  "${PYTHON_BIN}" - "${path}" "${outer}" "${inner}" <<'PY'
import json, sys
path, outer, inner = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    data = json.loads(open(path, encoding="utf-8").read())
except Exception:
    print("<absent>")
    sys.exit(0)
node = data.get(outer, {})
if not isinstance(node, dict):
    print("<absent>")
    sys.exit(0)
val = node.get(inner, "<absent>")
print(val if isinstance(val, str) else json.dumps(val, ensure_ascii=False))
PY
}

# ── Shared fixtures ──────────────────────────────────────────────────
GATE_ID="logger_archive"
WORKFLOW_ID="logger-test-flow"
RUN_ID="run_20260506000000_log00001"
PROJECT_ID="logger-runner-test"

# A minimal valid workflow-result.json that we'll reuse across cases.
WF_DIR="${SANDBOX}/wf"
mkdir -p "${WF_DIR}"
cat > "${WF_DIR}/wf-result.json" <<'EOF'
{
  "schema_version": 1,
  "run_id": "run_20260506000000_log00001",
  "workflow_id": "logger-test-flow",
  "project_id": "logger-runner-test",
  "started_at": "2026-05-06T00:00:00+08:00",
  "finished_at": "2026-05-06T00:01:30+08:00",
  "total_duration_seconds": 90,
  "final_state": "completed",
  "final_result": "success",
  "summary": {"total_steps": 2, "completed": 2, "failed": 0, "skipped": 0, "blocked": 0},
  "steps": [
    {"step_id": "prd", "phase": 1, "capability": "prd_generation", "status": "ok", "duration_seconds": 60, "output_path": "/run/1-prd.md", "handoff_path": "/run/1-prd.handoff.md"},
    {"step_id": "ba",  "phase": 2, "capability": "business_analysis", "status": "ok", "duration_seconds": 30, "output_path": "/run/2-ba.md", "handoff_path": "/run/2-ba.handoff.md"}
  ],
  "sessions": [
    {"session_id": "run_20260506000000_log00001.1.prd", "step_id": "prd", "role": "supervisor", "capability": "prd_generation", "provider": "claude", "executor": "ai", "lifecycle": "completed", "result": "success", "duration_seconds": 60},
    {"session_id": "run_20260506000000_log00001.2.ba",  "step_id": "ba",  "role": "ba",         "capability": "business_analysis", "provider": "claude", "executor": "ai", "lifecycle": "completed", "result": "success", "duration_seconds": 30}
  ],
  "artifacts": [
    {"name": "prd_document", "path": "/run/1-prd.md", "producer_step_id": "prd", "promoted": false},
    {"name": "ba_spec",      "path": "/run/2-ba.md", "producer_step_id": "ba",  "promoted": false}
  ]
}
EOF
WF_RESULT="${WF_DIR}/wf-result.json"
echo "minimal result.md projection" > "${WF_DIR}/result.md"
echo "minimal archive-summary.md" > "${WF_DIR}/archive-summary.md"
RESULT_MD="${WF_DIR}/result.md"
ARCHIVE_MD="${WF_DIR}/archive-summary.md"

run_gate() {
  # run_gate <step_id> <output> <mode> [extra args...]
  local step_id="$1" output="$2" mode="$3"; shift 3
  cd "${REPO_ROOT}" && "${PYTHON_BIN}" "${STEP_PY}" run-logger-gate \
    --gate-id "${GATE_ID}" \
    --checkpoint "${mode}" \
    --workflow-id "${WORKFLOW_ID}" \
    --run-id "${RUN_ID}" \
    --step-id "${step_id}" \
    --project-id "${PROJECT_ID}" \
    --mode "${mode}" \
    --output "${output}" \
    "$@" 2>&1
}

# ── Case 1: full happy path final mode ─────────────────────────────────
echo "Case 1: workflow-result + result.md + archive-summary, mode=final → pass"
OUT_1="${SANDBOX}/case1.gate-result.json"
out1="$(run_gate logger_full "${OUT_1}" final \
  --workflow-result "${WF_RESULT}" \
  --result-md "${RESULT_MD}" \
  --archive-summary "${ARCHIVE_MD}")"
rc1=$?
assert_eq        "rc 0 happy path"               "0"             "${rc1}"
assert_contains  "stdout result=pass"            "result=pass"    "${out1}"
assert_contains  "stdout risk=none"              "risk=none"      "${out1}"
assert_eq        "envelope gate_type=logger"     "logger"         "$(read_field "${OUT_1}" gate_type)"
assert_eq        "envelope produced_by=99-Logger" "99-Logger"     "$(read_field "${OUT_1}" produced_by)"
assert_eq        "envelope findings empty"       "[]"             "$(read_field "${OUT_1}" findings)"
assert_eq        "metric mode=final"             "final"          "$(read_metric "${OUT_1}" mode)"

# ── Case 2: milestone mode + missing archive-summary → warn ────────────
echo "Case 2: milestone mode + missing archive-summary → warn medium"
OUT_2="${SANDBOX}/case2.gate-result.json"
out2="$(run_gate logger_milestone_warn "${OUT_2}" milestone \
  --workflow-result "${WF_RESULT}" \
  --result-md "${RESULT_MD}" \
  --archive-summary "${SANDBOX}/no-archive.md")"
rc2=$?
assert_eq        "rc 0 milestone warn"            "0"             "${rc2}"
assert_contains  "stdout result=warn"             "result=warn"    "${out2}"
assert_contains  "stdout risk=medium"             "risk=medium"    "${out2}"
assert_contains  "finding category=archive_summary_missing" "archive_summary_missing" "$(cat "${OUT_2}")"
# warn must NOT auto-populate fail_routing
if grep -qF '"fail_routing"' "${OUT_2}"; then
  echo "  FAIL: warn verdict unexpectedly produced fail_routing block"
  fail_count=$((fail_count + 1))
else
  echo "  PASS: warn verdict omits fail_routing"
  pass_count=$((pass_count + 1))
fi

# ── Case 3: final mode + missing archive-summary → blocked halt ────────
echo "Case 3: final mode + missing archive-summary → blocked high halt"
OUT_3="${SANDBOX}/case3.gate-result.json"
out3="$(run_gate logger_final_block "${OUT_3}" final \
  --workflow-result "${WF_RESULT}" \
  --result-md "${RESULT_MD}" \
  --archive-summary "${SANDBOX}/no-archive.md")"
rc3=$?
assert_eq        "rc 0 final blocked"             "0"             "${rc3}"
assert_contains  "stdout result=blocked"          "result=blocked" "${out3}"
assert_contains  "stdout risk=high"               "risk=high"      "${out3}"
assert_eq        "fail_routing.action=halt"       "halt"           "$(read_nested_field "${OUT_3}" fail_routing action)"

# ── Case 4: result.md missing only → warn ──────────────────────────────
echo "Case 4: result.md missing (workflow-result + archive-summary present, milestone) → warn"
OUT_4="${SANDBOX}/case4.gate-result.json"
out4="$(run_gate logger_md_warn "${OUT_4}" milestone \
  --workflow-result "${WF_RESULT}" \
  --result-md "${SANDBOX}/no-result.md" \
  --archive-summary "${ARCHIVE_MD}")"
rc4=$?
assert_eq        "rc 0 result.md warn"            "0"             "${rc4}"
assert_contains  "stdout result=warn"             "result=warn"    "${out4}"
assert_contains  "finding category=result_md_missing" "result_md_missing" "$(cat "${OUT_4}")"

# ── Case 5: workflow-result missing → blocked ─────────────────────────
echo "Case 5: workflow-result missing → blocked high halt"
OUT_5="${SANDBOX}/case5.gate-result.json"
out5="$(run_gate logger_wf_missing "${OUT_5}" final \
  --workflow-result "${SANDBOX}/no-such-wf.json")"
rc5=$?
assert_eq        "rc 0 wf missing blocked"        "0"             "${rc5}"
assert_contains  "stdout result=blocked"          "result=blocked" "${out5}"
assert_eq        "fail_routing.action=halt"       "halt"           "$(read_nested_field "${OUT_5}" fail_routing action)"
assert_contains  "finding category=workflow_result_missing" "workflow_result_missing" "$(cat "${OUT_5}")"

# ── Case 6: workflow-result empty → blocked ───────────────────────────
echo "Case 6: workflow-result empty bytes → blocked high halt"
EMPTY_DIR="${SANDBOX}/empty"
mkdir -p "${EMPTY_DIR}"
: > "${EMPTY_DIR}/wf.json"
OUT_6="${SANDBOX}/case6.gate-result.json"
out6="$(run_gate logger_wf_empty "${OUT_6}" final \
  --workflow-result "${EMPTY_DIR}/wf.json")"
rc6=$?
assert_eq        "rc 0 wf empty blocked"          "0"             "${rc6}"
assert_contains  "stdout result=blocked"          "result=blocked" "${out6}"
assert_contains  "finding category=workflow_result_empty" "workflow_result_empty" "$(cat "${OUT_6}")"

# ── Case 7: workflow-result invalid JSON → blocked ────────────────────
echo "Case 7: workflow-result not JSON → blocked high halt"
PARSE_DIR="${SANDBOX}/parse"
mkdir -p "${PARSE_DIR}"
echo "this is not json {" > "${PARSE_DIR}/wf.json"
OUT_7="${SANDBOX}/case7.gate-result.json"
out7="$(run_gate logger_wf_parse "${OUT_7}" final \
  --workflow-result "${PARSE_DIR}/wf.json")"
rc7=$?
assert_eq        "rc 0 wf parse blocked"          "0"             "${rc7}"
assert_contains  "stdout result=blocked"          "result=blocked" "${out7}"
assert_contains  "finding category=workflow_result_parse_error" "workflow_result_parse_error" "$(cat "${OUT_7}")"

# ── Case 8: workflow-result schema invalid → blocked ──────────────────
echo "Case 8: workflow-result fails schema → blocked high halt"
SCHEMA_DIR="${SANDBOX}/schema"
mkdir -p "${SCHEMA_DIR}"
# valid JSON but missing required fields (run_id, workflow_id, ...)
echo '{"schema_version": 1, "what": "incomplete"}' > "${SCHEMA_DIR}/wf.json"
OUT_8="${SANDBOX}/case8.gate-result.json"
out8="$(run_gate logger_wf_schema "${OUT_8}" final \
  --workflow-result "${SCHEMA_DIR}/wf.json")"
rc8=$?
assert_eq        "rc 0 wf schema blocked"         "0"             "${rc8}"
assert_contains  "stdout result=blocked"          "result=blocked" "${out8}"
assert_contains  "finding category=workflow_result_schema_invalid" "workflow_result_schema_invalid" "$(cat "${OUT_8}")"
# metrics still report workflow_result_validated=false
assert_eq        "metric workflow_result_validated=false" "false" "$(read_metric "${OUT_8}" workflow_result_validated)"

# ── Case 9: workflow-result alone (milestone, no md / no archive) → pass ─
echo "Case 9: only workflow-result provided (milestone) → pass"
OUT_9="${SANDBOX}/case9.gate-result.json"
out9="$(run_gate logger_wf_only "${OUT_9}" milestone \
  --workflow-result "${WF_RESULT}")"
rc9=$?
assert_eq        "rc 0 wf only pass"              "0"             "${rc9}"
assert_contains  "stdout result=pass"             "result=pass"    "${out9}"

# ── Case 10: metrics propagation ──────────────────────────────────────
echo "Case 10: metrics from workflow-result (final_state / counts) populated"
assert_eq        "metric final_state=completed"   "completed"      "$(read_metric "${OUT_1}" final_state)"
assert_eq        "metric final_result=success"    "success"        "$(read_metric "${OUT_1}" final_result)"
assert_eq        "metric total_steps=2"           "2"              "$(read_metric "${OUT_1}" total_steps)"
assert_eq        "metric completed_steps=2"       "2"              "$(read_metric "${OUT_1}" completed_steps)"
assert_eq        "metric failure_count=0"         "0"              "$(read_metric "${OUT_1}" failure_count)"
assert_eq        "metric artifact_count=2"        "2"              "$(read_metric "${OUT_1}" artifact_count)"
assert_eq        "metric session_count=2"         "2"              "$(read_metric "${OUT_1}" session_count)"
assert_eq        "metric workflow_result_validated=true" "true"    "$(read_metric "${OUT_1}" workflow_result_validated)"

# ── Case 11: default --output resolves to cwd ─────────────────────────
echo "Case 11: default --output resolves to cwd/<step_id>.gate-result.json"
DEFAULT_DIR="${SANDBOX}/case11"
mkdir -p "${DEFAULT_DIR}"
out11="$(cd "${DEFAULT_DIR}" && "${PYTHON_BIN}" "${STEP_PY}" run-logger-gate \
  --gate-id "${GATE_ID}" \
  --checkpoint final \
  --workflow-id "${WORKFLOW_ID}" \
  --run-id "${RUN_ID}" \
  --step-id logger_default_path \
  --project-id "${PROJECT_ID}" \
  --workflow-result "${WF_RESULT}" \
  --mode milestone 2>&1)"
rc11=$?
DEFAULT_OUT="${DEFAULT_DIR}/logger_default_path.gate-result.json"
assert_eq        "rc 0 default-path"              "0"             "${rc11}"
assert_eq        "default file written"           "yes"           "$([ -f "${DEFAULT_OUT}" ] && echo yes || echo no)"

# ── Case 12: round-trip with validate-gate-result CLI ─────────────────
echo "Case 12: round-trip — every emitted envelope passes validate-gate-result CLI"
for envelope in "${OUT_1}" "${OUT_2}" "${OUT_3}" "${OUT_4}" "${OUT_5}" "${OUT_6}" "${OUT_7}" "${OUT_8}" "${OUT_9}" "${DEFAULT_OUT}"; do
  out_v="$(cd "${REPO_ROOT}" && "${PYTHON_BIN}" "${STEP_PY}" validate-gate-result "${envelope}" 2>&1)"
  rc_v=$?
  assert_eq "rc 0 for $(basename "${envelope}")" "0" "${rc_v}"
done

# ── Case 13: --produced-by / --gate-subtype / --task-id propagate ─────
echo "Case 13: --produced-by / --gate-subtype / --task-id propagate"
OUT_13="${SANDBOX}/case13.gate-result.json"
"${PYTHON_BIN}" "${STEP_PY}" run-logger-gate \
  --gate-id logger_custom \
  --checkpoint always_on \
  --workflow-id "${WORKFLOW_ID}" \
  --run-id "${RUN_ID}" \
  --step-id logger_custom_audit \
  --project-id "${PROJECT_ID}" \
  --workflow-result "${WF_RESULT}" \
  --mode milestone \
  --output "${OUT_13}" \
  --task-id token-monitor-spec \
  --gate-subtype final_only \
  --produced-by 99-Logger-PerfBuild >/dev/null 2>&1
assert_eq "envelope produced_by override"      "99-Logger-PerfBuild" "$(read_field "${OUT_13}" produced_by)"
assert_eq "envelope gate_subtype override"     "final_only"          "$(read_field "${OUT_13}" gate_subtype)"
assert_eq "envelope task_id override"          "token-monitor-spec"  "$(read_field "${OUT_13}" task_id)"

echo ""
echo "logger-gate-runner: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
