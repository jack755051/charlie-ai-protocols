#!/usr/bin/env bash
#
# test-qa-gate-runner.sh — P8 #4 QA checkpoint runner contract.
#
# Verifies the engine/step_runtime.py run-qa-gate subcommand
# (engine/qa_gate_runner.py) acts as the third concrete producer for
# schemas/gate-result.schema.yaml. Test shape mirrors
# test-watcher-gate-runner / test-security-gate-runner; only the
# check semantics differ.
#
# Coverage:
#   1. jest summary clean                    → result=pass, tests metrics populated
#   2. jest summary with failure             → result=fail risk=high escalate, finding=test_failure
#   3. pytest summary clean                  → result=pass, dialect=pytest
#   4. pytest summary with failure           → result=fail risk=high
#   5. mocha summary clean                   → result=pass
#   6. mocha summary with failure            → result=fail
#   7. coverage above threshold              → result=pass, coverage_percent populated
#   8. coverage below default threshold      → result=warn risk=medium, finding=coverage_below_threshold
#   9. test fail + low coverage (high beats medium) → result=fail risk=high
#  10. unparseable artifact (info findings)  → result=pass risk=low
#  11. empty target_artifact                 → result=warn (medium severity for QA)
#  12. missing artifact                      → result=blocked risk=high halt
#  13. no --target-artifact                  → result=blocked degenerate
#  14. default --output resolves to cwd      → ./<step_id>.gate-result.json written
#  15. round-trip with validate-gate-result  → all envelopes rc 0 reason=ok
#  16. --coverage-threshold override (lower) → coverage_below_threshold can be silenced
#  17. --produced-by / --gate-subtype override → propagate to envelope

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

SANDBOX="$(mktemp -d -t cap-qa-runner-test.XXXXXX)"
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

GATE_ID="qa_unit"
CHECKPOINT="pre_release"
WORKFLOW_ID="project-qa-pipeline"
RUN_ID="run_20260505000000_qa000001"
PROJECT_ID="qa-runner-test"

run_gate() {
  local step_id="$1" output="$2"; shift 2
  # Remaining args = artifacts, then optional flags after `--`
  local args=(
    --gate-id "${GATE_ID}"
    --checkpoint "${CHECKPOINT}"
    --workflow-id "${WORKFLOW_ID}"
    --run-id "${RUN_ID}"
    --step-id "${step_id}"
    --project-id "${PROJECT_ID}"
    --output "${output}"
  )
  local saw_dashdash=0
  local a
  for a in "$@"; do
    if [ "${saw_dashdash}" -eq 1 ]; then
      args+=("${a}")
    elif [ "${a}" = "--" ]; then
      saw_dashdash=1
    else
      args+=(--target-artifact "${a}")
    fi
  done
  cd "${REPO_ROOT}" && "${PYTHON_BIN}" "${STEP_PY}" run-qa-gate "${args[@]}" 2>&1
}

# ── Case 1: jest summary clean → result=pass ────────────────────────────
echo "Case 1: jest summary clean → result=pass tests metrics populated"
ART_DIR_1="${SANDBOX}/case1"
mkdir -p "${ART_DIR_1}"
cat > "${ART_DIR_1}/jest.txt" <<'EOF'
Test Suites: 1 passed, 1 total
Tests:       47 passed, 47 total
Snapshots:   0 total
Time:        2.131s
EOF
OUT_1="${ART_DIR_1}/qa.gate-result.json"
out1="$(run_gate qa_jest_clean "${OUT_1}" "${ART_DIR_1}/jest.txt")"
rc1=$?
assert_eq        "rc 0 jest clean"               "0"            "${rc1}"
assert_contains  "stdout result=pass"            "result=pass"   "${out1}"
assert_eq        "envelope gate_type=qa"         "qa"           "$(read_field "${OUT_1}" gate_type)"
assert_eq        "envelope produced_by=07-QA"    "07-QA"        "$(read_field "${OUT_1}" produced_by)"
assert_eq        "metric tests_total=47"         "47"           "$(read_metric "${OUT_1}" tests_total)"
assert_eq        "metric tests_passed=47"        "47"           "$(read_metric "${OUT_1}" tests_passed)"
assert_eq        "metric tests_failed=0"         "0"            "$(read_metric "${OUT_1}" tests_failed)"

# ── Case 2: jest summary with failure → result=fail risk=high ──────────
echo "Case 2: jest summary failed → result=fail risk=high escalate"
ART_DIR_2="${SANDBOX}/case2"
mkdir -p "${ART_DIR_2}"
cat > "${ART_DIR_2}/jest.txt" <<'EOF'
Test Suites: 1 failed, 1 total
Tests:       1 failed, 47 passed, 48 total
EOF
OUT_2="${ART_DIR_2}/qa.gate-result.json"
out2="$(run_gate qa_jest_fail "${OUT_2}" "${ART_DIR_2}/jest.txt")"
rc2=$?
assert_eq        "rc 0 jest fail"                "0"            "${rc2}"
assert_contains  "stdout result=fail"            "result=fail"  "${out2}"
assert_contains  "stdout risk=high"              "risk=high"    "${out2}"
assert_eq        "envelope result=fail"          "fail"         "$(read_field "${OUT_2}" result)"
assert_eq        "fail_routing.action=escalate"   "escalate"    "$(read_nested_field "${OUT_2}" fail_routing action)"
assert_contains  "finding category=test_failure" "test_failure" "$(cat "${OUT_2}")"
assert_eq        "metric tests_failed=1"         "1"            "$(read_metric "${OUT_2}" tests_failed)"

# ── Case 3: pytest summary clean → result=pass ──────────────────────────
echo "Case 3: pytest summary clean → result=pass dialect=pytest"
ART_DIR_3="${SANDBOX}/case3"
mkdir -p "${ART_DIR_3}"
cat > "${ART_DIR_3}/pytest.txt" <<'EOF'
============================== 47 passed in 1.23s ==============================
EOF
OUT_3="${ART_DIR_3}/qa.gate-result.json"
out3="$(run_gate qa_pytest_clean "${OUT_3}" "${ART_DIR_3}/pytest.txt")"
rc3=$?
assert_eq        "rc 0 pytest clean"             "0"            "${rc3}"
assert_contains  "stdout result=pass"            "result=pass"   "${out3}"
assert_eq        "metric tests_dialects=[pytest]" '["pytest"]'  "$(read_metric "${OUT_3}" tests_dialects)"
assert_eq        "metric tests_passed=47"        "47"           "$(read_metric "${OUT_3}" tests_passed)"

# ── Case 4: pytest with failure → result=fail ──────────────────────────
echo "Case 4: pytest summary failed → result=fail risk=high"
ART_DIR_4="${SANDBOX}/case4"
mkdir -p "${ART_DIR_4}"
cat > "${ART_DIR_4}/pytest.txt" <<'EOF'
==================== 1 failed, 47 passed in 1.23s ====================
EOF
OUT_4="${ART_DIR_4}/qa.gate-result.json"
out4="$(run_gate qa_pytest_fail "${OUT_4}" "${ART_DIR_4}/pytest.txt")"
rc4=$?
assert_eq        "rc 0 pytest fail"              "0"            "${rc4}"
assert_contains  "stdout result=fail"            "result=fail"  "${out4}"
assert_contains  "finding category=test_failure" "test_failure" "$(cat "${OUT_4}")"

# ── Case 5: mocha summary clean → result=pass ──────────────────────────
echo "Case 5: mocha summary clean → result=pass dialect=mocha"
ART_DIR_5="${SANDBOX}/case5"
mkdir -p "${ART_DIR_5}"
cat > "${ART_DIR_5}/mocha.txt" <<'EOF'

  ✓ test 1
  ✓ test 2

  47 passing (2s)
EOF
OUT_5="${ART_DIR_5}/qa.gate-result.json"
out5="$(run_gate qa_mocha_clean "${OUT_5}" "${ART_DIR_5}/mocha.txt")"
rc5=$?
assert_eq        "rc 0 mocha clean"              "0"            "${rc5}"
assert_contains  "stdout result=pass"            "result=pass"  "${out5}"
assert_eq        "metric tests_dialects=[mocha]" '["mocha"]'    "$(read_metric "${OUT_5}" tests_dialects)"

# ── Case 6: mocha with failures ────────────────────────────────────────
echo "Case 6: mocha summary failed → result=fail risk=high"
ART_DIR_6="${SANDBOX}/case6"
mkdir -p "${ART_DIR_6}"
cat > "${ART_DIR_6}/mocha.txt" <<'EOF'

  47 passing (2s)
  1 failing

  1) some test:
     AssertionError: expected 1 to equal 2
EOF
OUT_6="${ART_DIR_6}/qa.gate-result.json"
out6="$(run_gate qa_mocha_fail "${OUT_6}" "${ART_DIR_6}/mocha.txt")"
rc6=$?
assert_eq        "rc 0 mocha fail"               "0"            "${rc6}"
assert_contains  "stdout result=fail"            "result=fail"  "${out6}"
assert_eq        "metric tests_failed=1"         "1"            "$(read_metric "${OUT_6}" tests_failed)"

# ── Case 7: coverage above threshold → result=pass ────────────────────
echo "Case 7: coverage above default 80% threshold → result=pass coverage_percent populated"
ART_DIR_7="${SANDBOX}/case7"
mkdir -p "${ART_DIR_7}"
cat > "${ART_DIR_7}/cov.txt" <<'EOF'
=========== Coverage Summary ===========
All files | 87.50 | 80.00 | 75.00 | 87.50
EOF
# Include a clean test summary so we don't trip the unparsed-summary info finding.
cat > "${ART_DIR_7}/jest.txt" <<'EOF'
Tests:       47 passed, 47 total
EOF
OUT_7="${ART_DIR_7}/qa.gate-result.json"
out7="$(run_gate qa_cov_high "${OUT_7}" "${ART_DIR_7}/jest.txt" "${ART_DIR_7}/cov.txt")"
rc7=$?
assert_eq        "rc 0 coverage above"           "0"            "${rc7}"
assert_contains  "stdout result=pass"            "result=pass"  "${out7}"
assert_eq        "metric coverage_percent=87.5"  "87.5"         "$(read_metric "${OUT_7}" coverage_percent)"

# ── Case 8: coverage below threshold → result=warn risk=medium ────────
echo "Case 8: coverage below 80% → result=warn risk=medium category=coverage_below_threshold"
ART_DIR_8="${SANDBOX}/case8"
mkdir -p "${ART_DIR_8}"
cat > "${ART_DIR_8}/cov.txt" <<'EOF'
All files | 65.43 | 50.00 | 60.00 | 65.43
EOF
cat > "${ART_DIR_8}/jest.txt" <<'EOF'
Tests:       47 passed, 47 total
EOF
OUT_8="${ART_DIR_8}/qa.gate-result.json"
out8="$(run_gate qa_cov_low "${OUT_8}" "${ART_DIR_8}/jest.txt" "${ART_DIR_8}/cov.txt")"
rc8=$?
assert_eq        "rc 0 coverage below"           "0"            "${rc8}"
assert_contains  "stdout result=warn"            "result=warn"  "${out8}"
assert_contains  "stdout risk=medium"            "risk=medium"  "${out8}"
assert_contains  "finding category=coverage_below_threshold" "coverage_below_threshold" "$(cat "${OUT_8}")"
# warn verdicts must NOT auto-populate fail_routing
if grep -qF '"fail_routing"' "${OUT_8}"; then
  echo "  FAIL: warn verdict unexpectedly produced fail_routing block"
  fail_count=$((fail_count + 1))
else
  echo "  PASS: warn verdict omits fail_routing"
  pass_count=$((pass_count + 1))
fi

# ── Case 9: failed test + low coverage → high beats medium ─────────────
echo "Case 9: failed test + low coverage → result=fail (high beats medium)"
ART_DIR_9="${SANDBOX}/case9"
mkdir -p "${ART_DIR_9}"
cat > "${ART_DIR_9}/jest.txt" <<'EOF'
Tests:       3 failed, 44 passed, 47 total
EOF
cat > "${ART_DIR_9}/cov.txt" <<'EOF'
All files | 60.00 | ...
EOF
OUT_9="${ART_DIR_9}/qa.gate-result.json"
out9="$(run_gate qa_combined_bad "${OUT_9}" "${ART_DIR_9}/jest.txt" "${ART_DIR_9}/cov.txt")"
rc9=$?
assert_eq        "rc 0 combined fail"            "0"            "${rc9}"
assert_contains  "stdout result=fail"            "result=fail"  "${out9}"
assert_contains  "stdout risk=high"              "risk=high"    "${out9}"
assert_eq        "metric tests_failed=3"         "3"            "$(read_metric "${OUT_9}" tests_failed)"
assert_eq        "metric coverage_percent=60.0"  "60.0"         "$(read_metric "${OUT_9}" coverage_percent)"

# ── Case 10: unparseable artifact → result=pass with info findings ─────
echo "Case 10: unparseable artifact → result=pass with info finding"
ART_DIR_10="${SANDBOX}/case10"
mkdir -p "${ART_DIR_10}"
cat > "${ART_DIR_10}/random.txt" <<'EOF'
Hello, this is not a test summary.
Just some narrative text.
EOF
OUT_10="${ART_DIR_10}/qa.gate-result.json"
out10="$(run_gate qa_unparsed "${OUT_10}" "${ART_DIR_10}/random.txt")"
rc10=$?
assert_eq        "rc 0 unparsed pass"            "0"            "${rc10}"
assert_contains  "stdout result=pass"            "result=pass"  "${out10}"
assert_contains  "finding category=test_summary_unparsed" "test_summary_unparsed" "$(cat "${OUT_10}")"
assert_contains  "finding category=coverage_unparsed"     "coverage_unparsed"     "$(cat "${OUT_10}")"

# ── Case 11: empty artifact → warn medium ──────────────────────────────
echo "Case 11: empty target artifact → result=warn risk=medium (QA expects content)"
ART_DIR_11="${SANDBOX}/case11"
mkdir -p "${ART_DIR_11}"
: > "${ART_DIR_11}/empty.txt"
OUT_11="${ART_DIR_11}/qa.gate-result.json"
out11="$(run_gate qa_empty "${OUT_11}" "${ART_DIR_11}/empty.txt")"
rc11=$?
assert_eq        "rc 0 empty warn"               "0"            "${rc11}"
assert_contains  "stdout result=warn"            "result=warn"  "${out11}"
assert_contains  "stdout risk=medium"            "risk=medium"  "${out11}"
assert_contains  "finding category=artifact_empty" "artifact_empty" "$(cat "${OUT_11}")"

# ── Case 12: missing artifact → blocked halt ──────────────────────────
echo "Case 12: missing artifact → result=blocked risk=high halt"
ART_DIR_12="${SANDBOX}/case12"
mkdir -p "${ART_DIR_12}"
OUT_12="${ART_DIR_12}/qa.gate-result.json"
out12="$(run_gate qa_missing "${OUT_12}" "${ART_DIR_12}/no-such.txt")"
rc12=$?
assert_eq        "rc 0 missing blocked"          "0"            "${rc12}"
assert_contains  "stdout result=blocked"         "result=blocked" "${out12}"
assert_contains  "stdout risk=high"              "risk=high"    "${out12}"
assert_eq        "fail_routing.action=halt"      "halt"         "$(read_nested_field "${OUT_12}" fail_routing action)"
assert_contains  "finding category=artifact_missing" "artifact_missing" "$(cat "${OUT_12}")"

# ── Case 13: no target_artifacts → blocked degenerate ──────────────────
echo "Case 13: empty target_artifacts → result=blocked"
ART_DIR_13="${SANDBOX}/case13"
mkdir -p "${ART_DIR_13}"
OUT_13="${ART_DIR_13}/qa.gate-result.json"
out13="$(cd "${REPO_ROOT}" && "${PYTHON_BIN}" "${STEP_PY}" run-qa-gate \
  --gate-id "${GATE_ID}" --checkpoint "${CHECKPOINT}" \
  --workflow-id "${WORKFLOW_ID}" --run-id "${RUN_ID}" \
  --step-id qa_no_target --project-id "${PROJECT_ID}" \
  --output "${OUT_13}" 2>&1)"
rc13=$?
assert_eq        "rc 0 degenerate blocked"       "0"            "${rc13}"
assert_contains  "stdout result=blocked"         "result=blocked" "${out13}"
assert_contains  "finding flags no_target_artifacts" "no_target_artifacts" "$(cat "${OUT_13}")"

# ── Case 14: default --output resolves to cwd ──────────────────────────
echo "Case 14: default --output resolves to cwd/<step_id>.gate-result.json"
ART_DIR_14="${SANDBOX}/case14"
mkdir -p "${ART_DIR_14}"
cat > "${ART_DIR_14}/jest.txt" <<'EOF'
Tests:       47 passed, 47 total
EOF
out14="$(cd "${ART_DIR_14}" && "${PYTHON_BIN}" "${STEP_PY}" run-qa-gate \
  --gate-id "${GATE_ID}" --checkpoint final \
  --workflow-id "${WORKFLOW_ID}" --run-id "${RUN_ID}" \
  --step-id qa_default_path --project-id "${PROJECT_ID}" \
  --target-artifact "${ART_DIR_14}/jest.txt" 2>&1)"
rc14=$?
DEFAULT_OUT="${ART_DIR_14}/qa_default_path.gate-result.json"
assert_eq        "rc 0 default-path"             "0"            "${rc14}"
assert_eq        "default file written"          "yes"          "$([ -f "${DEFAULT_OUT}" ] && echo yes || echo no)"

# ── Case 15: round-trip with validate-gate-result CLI ──────────────────
echo "Case 15: round-trip — every emitted envelope passes validate-gate-result CLI"
for envelope in "${OUT_1}" "${OUT_2}" "${OUT_3}" "${OUT_4}" "${OUT_5}" "${OUT_6}" "${OUT_7}" "${OUT_8}" "${OUT_9}" "${OUT_10}" "${OUT_11}" "${OUT_12}" "${OUT_13}" "${DEFAULT_OUT}"; do
  out_v="$(cd "${REPO_ROOT}" && "${PYTHON_BIN}" "${STEP_PY}" validate-gate-result "${envelope}" 2>&1)"
  rc_v=$?
  assert_eq "rc 0 for $(basename "${envelope}")" "0" "${rc_v}"
done

# ── Case 16: --coverage-threshold override ─────────────────────────────
echo "Case 16: --coverage-threshold override silences below-threshold finding"
ART_DIR_16="${SANDBOX}/case16"
mkdir -p "${ART_DIR_16}"
cat > "${ART_DIR_16}/cov.txt" <<'EOF'
All files | 65.00 | ...
EOF
cat > "${ART_DIR_16}/jest.txt" <<'EOF'
Tests:       47 passed, 47 total
EOF
OUT_16="${ART_DIR_16}/qa.gate-result.json"
out16="$(cd "${REPO_ROOT}" && "${PYTHON_BIN}" "${STEP_PY}" run-qa-gate \
  --gate-id "${GATE_ID}" --checkpoint "${CHECKPOINT}" \
  --workflow-id "${WORKFLOW_ID}" --run-id "${RUN_ID}" \
  --step-id qa_threshold_override --project-id "${PROJECT_ID}" \
  --target-artifact "${ART_DIR_16}/jest.txt" \
  --target-artifact "${ART_DIR_16}/cov.txt" \
  --output "${OUT_16}" \
  --coverage-threshold 50.0 2>&1)"
rc16=$?
assert_eq        "rc 0 with lowered threshold"   "0"            "${rc16}"
assert_contains  "stdout result=pass"            "result=pass"  "${out16}"
assert_eq        "metric coverage_threshold=50.0" "50.0"        "$(read_metric "${OUT_16}" coverage_threshold)"

# ── Case 17: --produced-by / --gate-subtype propagation ────────────────
echo "Case 17: --produced-by / --gate-subtype propagate to envelope"
ART_DIR_17="${SANDBOX}/case17"
mkdir -p "${ART_DIR_17}"
cat > "${ART_DIR_17}/jest.txt" <<'EOF'
Tests:       47 passed, 47 total
EOF
OUT_17="${ART_DIR_17}/qa.gate-result.json"
"${PYTHON_BIN}" "${STEP_PY}" run-qa-gate \
  --gate-id qa_e2e_audit --checkpoint always_on \
  --workflow-id "${WORKFLOW_ID}" --run-id "${RUN_ID}" \
  --step-id qa_e2e_subtype_test --project-id "${PROJECT_ID}" \
  --target-artifact "${ART_DIR_17}/jest.txt" \
  --output "${OUT_17}" \
  --gate-subtype lighthouse_audit \
  --produced-by 07-QA-PerfBuild >/dev/null 2>&1
assert_eq "envelope produced_by override"      "07-QA-PerfBuild"   "$(read_field "${OUT_17}" produced_by)"
assert_eq "envelope gate_subtype override"     "lighthouse_audit"  "$(read_field "${OUT_17}" gate_subtype)"

echo ""
echo "qa-gate-runner: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
