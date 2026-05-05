#!/usr/bin/env bash
#
# test-result-report-wiring.sh — P7 Phase B focused test.
#
# Exercises ``scripts/cap-result-emit.sh`` (the producer wiring helper
# that ``cap-workflow-exec.sh`` end-of-run logic delegates to) without
# spinning up a full workflow run. Cases:
#
#   1. happy path        → cap_result_emit returns 0; workflow-result.json
#                          + result.md written; json passes schema; md
#                          contains the expected headings + fields.
#   2. schema-fail path  → CAP_RESULT_SCHEMA_OVERRIDE points at a
#                          deliberately stricter schema so validation
#                          fails; helper returns non-zero, files NOT
#                          written, workflow.log records the fallback.
#   3. builder-fail path → run_dir does not exist; helper returns
#                          non-zero, files NOT written, workflow.log
#                          records the builder rc fallback.
#
# Deliberately scoped to the helper itself; we are NOT booting the full
# cap-workflow-exec.sh end-to-end here. The wiring inside
# cap-workflow-exec.sh is exercised separately (by smoke runs) — this
# test guards the contract of cap_result_emit so a regression cannot
# mask itself behind the legacy fallback path.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
EMIT_HELPER="${REPO_ROOT}/scripts/cap-result-emit.sh"
SCHEMA_PATH="${REPO_ROOT}/schemas/workflow-result.schema.yaml"
STEP_RUNTIME="${REPO_ROOT}/engine/step_runtime.py"

[ -f "${EMIT_HELPER}" ]  || { echo "FAIL: ${EMIT_HELPER} missing"; exit 1; }
[ -f "${SCHEMA_PATH}" ]  || { echo "FAIL: ${SCHEMA_PATH} missing"; exit 1; }
[ -f "${STEP_RUNTIME}" ] || { echo "FAIL: ${STEP_RUNTIME} missing"; exit 1; }

# shellcheck source=../../scripts/cap-result-emit.sh
. "${EMIT_HELPER}"

SANDBOX="$(mktemp -d -t cap-result-wiring-test.XXXXXX)"
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

assert_file_exists() {
  local desc="$1" path="$2"
  if [ -s "${path}" ]; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc} (missing or empty): ${path}"
    fail_count=$((fail_count + 1))
  fi
}

assert_file_absent() {
  local desc="$1" path="$2"
  if [ ! -e "${path}" ]; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc} (file unexpectedly present): ${path}"
    fail_count=$((fail_count + 1))
  fi
}

assert_log_contains() {
  local desc="$1" path="$2" needle="$3"
  if grep -qF -- "${needle}" "${path}" 2>/dev/null; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    needle: ${needle}"
    echo "    file:   ${path}"
    fail_count=$((fail_count + 1))
  fi
}

assert_md_contains() {
  local desc="$1" path="$2" needle="$3"
  if grep -qF -- "${needle}" "${path}" 2>/dev/null; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    needle: ${needle}"
    echo "    file:   ${path}"
    fail_count=$((fail_count + 1))
  fi
}

stage_run_dir() {
  local case_name="$1"
  local project_id="${2:-wiring-proj}"
  local cap_home="${SANDBOX}/${case_name}/cap"
  local run_dir="${cap_home}/projects/${project_id}/reports/workflows/wiring-wf/run_${case_name}"
  mkdir -p "${run_dir}"
  cat > "${run_dir}/runtime-state.json" <<'EOF'
{
  "artifacts": {
    "stub": {"artifact": "stub", "source_step": "only_step", "path": "/tmp/stub.md"}
  },
  "steps": {
    "only_step": {
      "phase": "1",
      "capability": "wiring_test",
      "execution_state": "validated",
      "blocked_reason": "",
      "output_source": "captured_stdout",
      "output_path": "/tmp/stub.md",
      "handoff_path": ""
    }
  }
}
EOF
  cat > "${run_dir}/agent-sessions.json" <<EOF
{
  "version": 1,
  "run_id": "run_${case_name}",
  "workflow_id": "wiring-wf",
  "workflow_name": "Wiring Focused Test",
  "sessions": [
    {
      "session_id": "run_${case_name}.1.only_step",
      "step_id": "only_step",
      "role": "shell",
      "capability": "wiring_test",
      "executor": "shell",
      "lifecycle": "completed",
      "result": "success",
      "duration_seconds": 1
    }
  ]
}
EOF
  cat > "${run_dir}/run-summary.md" <<EOF
# Workflow Run Summary

- workflow_id: wiring-wf
- workflow_name: Wiring Focused Test
- run_id: run_${case_name}
- started_at: 2026-05-05 09:00:00

## Steps

### only_step

- status: ok
- duration_seconds: 1

## Finished

- finished_at: 2026-05-05 09:00:01
- total_duration_seconds: 1
- completed: 1
- failed: 0
- skipped: 0
EOF
  printf '[2026-05-05 09:00:00][workflow][started]\n' > "${run_dir}/workflow.log"
  printf '%s' "${run_dir}"
}

cap_home_for() {
  local case_name="$1"
  printf '%s' "${SANDBOX}/${case_name}/cap"
}

# ── Case 1: happy path ─────────────────────────────────────────────────

echo "Case 1: happy path → schema ok → workflow-result.json + result.md written"
RUN1="$(stage_run_dir happy)"
OUT_JSON1="${RUN1}/workflow-result.json"
OUT_MD1="${RUN1}/result.md"
LOG1="${RUN1}/workflow.log"

set +e
cap_result_emit "${RUN1}" "$(cap_home_for happy)" "" "${OUT_JSON1}" "${OUT_MD1}" "${LOG1}"
rc1=$?
set -e

assert_eq "happy: cap_result_emit rc=0" "0" "${rc1}"
assert_file_exists "happy: workflow-result.json written" "${OUT_JSON1}"
assert_file_exists "happy: result.md written"            "${OUT_MD1}"

# Schema-validate the produced JSON via step_runtime.
schema_out1="$("${PYTHON_BIN}" "${STEP_RUNTIME}" validate-jsonschema "${OUT_JSON1}" "${SCHEMA_PATH}" 2>&1)"
schema_rc1=$?
if [ "${schema_rc1}" -eq 0 ] && printf '%s' "${schema_out1}" | grep -q '"ok": true'; then
  echo "  PASS: happy: workflow-result.json validates against schema"
  pass_count=$((pass_count + 1))
else
  echo "  FAIL: happy: schema validation failed"
  echo "    rc:  ${schema_rc1}"
  echo "    out: ${schema_out1}"
  fail_count=$((fail_count + 1))
fi

assert_md_contains "happy: result.md heading"          "${OUT_MD1}" "# Workflow Result"
assert_md_contains "happy: result.md workflow_id"      "${OUT_MD1}" "- workflow_id: wiring-wf"
assert_md_contains "happy: result.md run_id"           "${OUT_MD1}" "- run_id: run_happy"
assert_md_contains "happy: result.md final_state"      "${OUT_MD1}" "- final_state: completed"
assert_md_contains "happy: result.md final_result"     "${OUT_MD1}" "- final_result: success"
assert_md_contains "happy: result.md Steps section"    "${OUT_MD1}" "## Steps"
assert_md_contains "happy: result.md only_step bullet" "${OUT_MD1}" "- only_step [ok]"
assert_log_contains "happy: workflow.log records schema=ok" "${LOG1}" "workflow-result.json schema=ok"

# ── Case 2: schema-fail path ──────────────────────────────────────────

echo ""
echo "Case 2: schema-fail path → fallback (no json/md written, log records failure)"
RUN2="$(stage_run_dir schemafail)"
OUT_JSON2="${RUN2}/workflow-result.json"
OUT_MD2="${RUN2}/result.md"
LOG2="${RUN2}/workflow.log"

# Stricter override schema: requires a field the builder never emits, so
# validate-jsonschema MUST fail. This is the cleanest way to exercise
# the schema-fail branch without having to corrupt builder output.
STRICT_SCHEMA="${SANDBOX}/strict-schema.yaml"
cat > "${STRICT_SCHEMA}" <<'EOF'
schema_version: 1
title: Strict override (forces validation failure)
required:
  - schema_version
  - run_id
  - this_field_will_never_exist
properties:
  schema_version:
    type: integer
    enum: [1]
  run_id:
    type: string
EOF

set +e
CAP_RESULT_SCHEMA_OVERRIDE="${STRICT_SCHEMA}" \
  cap_result_emit "${RUN2}" "$(cap_home_for schemafail)" "" \
    "${OUT_JSON2}" "${OUT_MD2}" "${LOG2}"
rc2=$?
set -e

assert_eq "schemafail: cap_result_emit rc!=0" "1" "${rc2}"
assert_file_absent "schemafail: workflow-result.json NOT written" "${OUT_JSON2}"
assert_file_absent "schemafail: result.md NOT written"            "${OUT_MD2}"
assert_log_contains "schemafail: workflow.log records fallback" \
  "${LOG2}" "workflow-result fallback: schema validation failed"

# ── Case 3: builder-fail path ─────────────────────────────────────────

echo ""
echo "Case 3: builder-fail path (missing run_dir) → fallback, no files written"
MISSING_RUN="${SANDBOX}/no-such-run"
LOG3="${SANDBOX}/builder-fail.workflow.log"
: > "${LOG3}"
OUT_JSON3="${SANDBOX}/no-such-run-result.json"
OUT_MD3="${SANDBOX}/no-such-run-result.md"

set +e
cap_result_emit "${MISSING_RUN}" "${SANDBOX}/no-such-cap" "" \
  "${OUT_JSON3}" "${OUT_MD3}" "${LOG3}"
rc3=$?
set -e

assert_eq "builderfail: cap_result_emit rc!=0" "1" "${rc3}"
assert_file_absent "builderfail: workflow-result.json NOT written" "${OUT_JSON3}"
assert_file_absent "builderfail: result.md NOT written"            "${OUT_MD3}"
assert_log_contains "builderfail: workflow.log records builder rc fallback" \
  "${LOG3}" "workflow-result fallback: builder rc"

# ── Case 4: write-fail path ──────────────────────────────────────────
#
# Builder runs and schema passes, but the final mv to out_json / out_md
# fails (parent directory does not exist). The pre-fix helper would
# silently return 0 even though no file landed; this case guards the
# bug fix that makes mv failure behave like schema failure.

echo ""
echo "Case 4a: write-fail at JSON mv → fallback, no files written"
RUN4A="$(stage_run_dir writefailjson)"
LOG4A="${RUN4A}/workflow.log"
# Parent directory deliberately does not exist → mv must fail.
OUT_JSON4A="${RUN4A}/no-such-subdir/workflow-result.json"
OUT_MD4A="${RUN4A}/result.md"

set +e
cap_result_emit "${RUN4A}" "$(cap_home_for writefailjson)" "" \
  "${OUT_JSON4A}" "${OUT_MD4A}" "${LOG4A}"
rc4a=$?
set -e

assert_eq "writefailjson: cap_result_emit rc!=0" "1" "${rc4a}"
assert_file_absent "writefailjson: workflow-result.json NOT written" "${OUT_JSON4A}"
assert_file_absent "writefailjson: result.md NOT written"            "${OUT_MD4A}"
assert_log_contains "writefailjson: workflow.log records write-fail fallback" \
  "${LOG4A}" "workflow-result fallback: write failed at"

echo ""
echo "Case 4b: write-fail at MD mv → JSON rolled back, no files written"
RUN4B="$(stage_run_dir writefailmd)"
LOG4B="${RUN4B}/workflow.log"
# JSON destination is fine; MD destination's parent does not exist so the
# second mv fails after the first already moved the JSON. The helper
# must roll back the just-moved JSON so the caller's fallback observes
# a clean state.
OUT_JSON4B="${RUN4B}/workflow-result.json"
OUT_MD4B="${RUN4B}/no-such-subdir/result.md"

set +e
cap_result_emit "${RUN4B}" "$(cap_home_for writefailmd)" "" \
  "${OUT_JSON4B}" "${OUT_MD4B}" "${LOG4B}"
rc4b=$?
set -e

assert_eq "writefailmd: cap_result_emit rc!=0" "1" "${rc4b}"
assert_file_absent "writefailmd: workflow-result.json rolled back" "${OUT_JSON4B}"
assert_file_absent "writefailmd: result.md NOT written"             "${OUT_MD4B}"
assert_log_contains "writefailmd: workflow.log records rolled-back fallback" \
  "${LOG4B}" "rolled back"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
