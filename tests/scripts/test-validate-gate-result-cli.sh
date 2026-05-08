#!/usr/bin/env bash
#
# test-validate-gate-result-cli.sh — P8 #5 gate-result validation CLI gate.
#
# Verifies the engine/step_runtime.py validate-gate-result subcommand exit-code
# + stdout contract that downstream governance consumers (P8 #6 fail-route
# handler, P8 #7 halt-on-risk policy, P8 #8 rerun-failed-gate selector) will
# rely on. The contract mirrors the validate-handoff-ticket gate (P6 #3):
#
#   exit 0  → reason=ok;detail=gate_result_schema_valid
#   exit 41 → reason=gate_result_schema_invalid;detail=<jsonschema errors>
#   exit 1  → reason=parse_error / reason=missing_artifact
#
# This is the **CLI contract test**. The schema itself is covered by
# tests/scripts/test-gate-result-schema.sh (10 fixture cases). This file
# instead pins the per-rc reason= prefix and detail= shape that the future
# wrapper invocation in cap-workflow-exec.sh (P8 #6/#7) must consume.
#
# Producers: P8 watcher / security / qa / logger checkpoint runners write
# <step_id>.gate-result.json next to the run's artifacts and then call
# `python3 engine/step_runtime.py validate-gate-result <path>` to confirm
# the envelope is well-formed before downstream policy steps read it.
#
# Cases:
#   1. CLI ok                       → rc 0,  reason=ok / detail=gate_result_schema_valid
#   2. CLI schema_invalid (missing) → rc 41, reason=gate_result_schema_invalid + missing field surfaced
#   3. CLI schema_invalid (enum)    → rc 41, reason=gate_result_schema_invalid + enum diagnostic
#   4. CLI parse_error              → rc 1,  reason=parse_error
#   5. CLI missing_artifact         → rc 1,  reason=missing_artifact
#   6. CLI override --schema flag   → rc 0,  uses caller-provided schema path
#   7. CLI default schema resolves  → no --schema arg still validates against repo schema

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"
GATE_SCHEMA="${REPO_ROOT}/schemas/gate-result.schema.yaml"

[ -f "${STEP_PY}" ]    || { echo "FAIL: engine/step_runtime.py missing"; exit 1; }
[ -f "${GATE_SCHEMA}" ] || { echo "FAIL: schemas/gate-result.schema.yaml missing"; exit 1; }

VENV_PY="${REPO_ROOT}/.venv/bin/python"
if [ -x "${VENV_PY}" ]; then
  PYTHON_BIN="${VENV_PY}"
else
  PYTHON_BIN="python3"
fi

SANDBOX="$(mktemp -d -t cap-gate-result-cli-test.XXXXXX)"
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

# ── Fixture: clean watcher pass envelope ────────────────────────────────
GOOD_RESULT="${SANDBOX}/good.gate-result.json"
cat > "${GOOD_RESULT}" <<'EOF'
{
  "schema_version": 1,
  "gate_id": "spec_audit",
  "gate_type": "watcher",
  "gate_subtype": "structure_audit",
  "checkpoint": "spec_phase",
  "workflow_id": "project-spec-pipeline",
  "run_id": "run_20260505000000_aaaaaaaa",
  "step_id": "spec_audit",
  "project_id": "smoke-proj",
  "task_id": null,
  "produced_at": "2026-05-05T00:00:00+08:00",
  "produced_by": "90-Watcher",
  "target_artifacts": [],
  "result": "pass",
  "risk_level": "low",
  "summary": "Spec coherence check passed",
  "findings": []
}
EOF

# ── Fixture: missing required gate_type ─────────────────────────────────
BAD_MISSING="${SANDBOX}/bad-missing.gate-result.json"
cat > "${BAD_MISSING}" <<'EOF'
{
  "schema_version": 1,
  "gate_id": "spec_audit",
  "checkpoint": "spec_phase",
  "workflow_id": "wf",
  "run_id": "r",
  "step_id": "s",
  "project_id": "p",
  "produced_at": "2026-05-05T00:00:00+08:00",
  "produced_by": "90-Watcher",
  "result": "pass",
  "risk_level": "low"
}
EOF

# ── Fixture: result enum violation ──────────────────────────────────────
BAD_ENUM="${SANDBOX}/bad-enum.gate-result.json"
cat > "${BAD_ENUM}" <<'EOF'
{
  "schema_version": 1,
  "gate_id": "spec_audit",
  "gate_type": "watcher",
  "checkpoint": "spec_phase",
  "workflow_id": "wf",
  "run_id": "r",
  "step_id": "s",
  "project_id": "p",
  "produced_at": "2026-05-05T00:00:00+08:00",
  "produced_by": "90-Watcher",
  "result": "maybe",
  "risk_level": "low"
}
EOF

# ── Fixture: non-JSON ───────────────────────────────────────────────────
PARSE_RESULT="${SANDBOX}/parse.gate-result.json"
echo 'this is not json' > "${PARSE_RESULT}"

# ── Layer 1: CLI exit-code + stdout contract ────────────────────────────

echo "Case 1: CLI ok → rc 0 stdout reason=ok"
out1="$(cd "${REPO_ROOT}" && "${PYTHON_BIN}" "${STEP_PY}" validate-gate-result "${GOOD_RESULT}" --schema "${GATE_SCHEMA}" 2>&1)"
rc1=$?
assert_eq "rc 0"                   "0"                                     "${rc1}"
assert_contains "reason=ok"        "reason=ok"                             "${out1}"
assert_contains "detail valid"     "detail=gate_result_schema_valid"       "${out1}"

echo "Case 2: CLI missing required gate_type → rc 41 reason=gate_result_schema_invalid"
out2="$(cd "${REPO_ROOT}" && "${PYTHON_BIN}" "${STEP_PY}" validate-gate-result "${BAD_MISSING}" --schema "${GATE_SCHEMA}" 2>&1)"
rc2=$?
assert_eq "rc 41 (schema_validation_failed)"     "41"                              "${rc2}"
assert_contains "reason=gate_result_schema_invalid" "reason=gate_result_schema_invalid" "${out2}"
assert_contains "missing gate_type surfaced"     "'gate_type' is a required property" "${out2}"

echo "Case 3: CLI result enum violation → rc 41 reason=gate_result_schema_invalid"
out3="$(cd "${REPO_ROOT}" && "${PYTHON_BIN}" "${STEP_PY}" validate-gate-result "${BAD_ENUM}" --schema "${GATE_SCHEMA}" 2>&1)"
rc3=$?
assert_eq "rc 41 (schema_validation_failed)"     "41"                              "${rc3}"
assert_contains "reason=gate_result_schema_invalid" "reason=gate_result_schema_invalid" "${out3}"
assert_contains "enum diagnostic surfaced"       "'maybe' is not one of"           "${out3}"

echo "Case 4: CLI parse error → rc 1 reason=parse_error"
out4="$(cd "${REPO_ROOT}" && "${PYTHON_BIN}" "${STEP_PY}" validate-gate-result "${PARSE_RESULT}" --schema "${GATE_SCHEMA}" 2>&1)"
rc4=$?
assert_eq "rc 1 (operational error)"             "1"                               "${rc4}"
assert_contains "reason=parse_error"             "reason=parse_error"              "${out4}"

echo "Case 5: CLI missing artifact → rc 1 reason=missing_artifact"
out5="$(cd "${REPO_ROOT}" && "${PYTHON_BIN}" "${STEP_PY}" validate-gate-result "${SANDBOX}/no-such.json" --schema "${GATE_SCHEMA}" 2>&1)"
rc5=$?
assert_eq "rc 1 (operational error)"             "1"                               "${rc5}"
assert_contains "reason=missing_artifact"        "reason=missing_artifact"         "${out5}"

echo "Case 6: CLI override --schema flag → uses caller-provided schema"
ALT_SCHEMA="${SANDBOX}/alt.schema.yaml"
cp "${GATE_SCHEMA}" "${ALT_SCHEMA}"
out6="$(cd "${REPO_ROOT}" && "${PYTHON_BIN}" "${STEP_PY}" validate-gate-result "${GOOD_RESULT}" --schema "${ALT_SCHEMA}" 2>&1)"
rc6=$?
assert_eq "rc 0 with overridden schema"          "0"                               "${rc6}"
assert_contains "valid via override schema"      "detail=gate_result_schema_valid" "${out6}"

echo "Case 7: CLI default schema resolves (no --schema flag)"
out7="$(cd "${REPO_ROOT}" && "${PYTHON_BIN}" "${STEP_PY}" validate-gate-result "${GOOD_RESULT}" 2>&1)"
rc7=$?
assert_eq "rc 0 with default schema path"        "0"                               "${rc7}"
assert_contains "valid via default schema"       "detail=gate_result_schema_valid" "${out7}"

echo ""
echo "validate-gate-result-cli: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
