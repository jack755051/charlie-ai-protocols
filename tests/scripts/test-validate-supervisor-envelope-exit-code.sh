#!/usr/bin/env bash
#
# test-validate-supervisor-envelope-exit-code.sh — assert that
# scripts/workflows/validate-supervisor-envelope.sh halts with exit 41
# (schema_validation_failed) for every failure class the schema-class
# contract covers, and exits 0 for a well-formed valid envelope.
#
# Per policies/workflow-executor-exit-codes.md the script is schema-class
# so all failures must surface as exit 41 with a single condition string.
#
# Coverage (5 cases / 18 assertions):
#   Case 0 happy:           valid envelope passing extract + schema + drift
#                           → exit 0, schema_validation_passed
#   Case 1 missing artifact: empty CAP_WORKFLOW_INPUT_CONTEXT
#                           → exit 41, missing_envelope_artifact
#   Case 2 fence missing:   artifact has prose but no fence pair
#                           → exit 41, envelope_extraction_failed
#   Case 3 schema invalid:  fence + valid JSON but missing
#                           failure_routing required block
#                           → exit 41, schema_validation_failed
#   Case 4 drift detected:  fence + schema-valid JSON but
#                           envelope.task_id != task_constitution.task_id
#                           → exit 41, envelope_drift_detected

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
EXEC="${REPO_ROOT}/scripts/workflows/validate-supervisor-envelope.sh"

[ -x "${EXEC}" ] || { echo "FAIL: ${EXEC} not executable"; exit 1; }

SANDBOX="$(mktemp -d -t cap-validate-supervisor.XXXXXX)"
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
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected to contain: ${needle}"
    fail_count=$((fail_count + 1))
  fi
}

# Helper: run the executor with a path-style input context pointing at
# `${SANDBOX}/<name>` and return "STDOUT_AND_STDERR|EXIT".
run_exec() {
  local artifact_path="$1"
  local out code tmp_out
  tmp_out="$(mktemp)"
  set +e
  CAP_WORKFLOW_INPUT_CONTEXT="path=${artifact_path} artifact=supervisor_orchestration_envelope" \
    bash "${EXEC}" >"${tmp_out}" 2>&1
  code=$?
  set -e
  out="$(cat "${tmp_out}")"
  rm -f "${tmp_out}"
  printf '%s|%s' "${out}" "${code}"
}

# Helper: build a standard valid envelope body. Tests mutate this
# minimally so each negative case isolates one failure mode.
write_valid_envelope_artifact() {
  local target="$1"
  local task_id="${2:-smoke-001}"
  local nested_task_id="${3:-${task_id}}"
  local nested_source="${4:-smoke source}"
  cat > "${target}" <<EOF
narrative line above the fence

<<<SUPERVISOR_ORCHESTRATION_BEGIN>>>
{
  "schema_version": 1,
  "task_id": "${task_id}",
  "source_request": "smoke source",
  "produced_at": "2026-05-03T22:00:00Z",
  "supervisor_role": "01-Supervisor",
  "task_constitution": {
    "task_id": "${nested_task_id}",
    "project_id": "smoke-proj",
    "source_request": "${nested_source}",
    "goal": "exercise executor",
    "goal_stage": "informal_planning",
    "success_criteria": ["validate executor wires"],
    "non_goals": [],
    "execution_plan": [{"step_id":"prd","capability":"prd_generation"}]
  },
  "capability_graph": {
    "schema_version": 1,
    "task_id": "${task_id}",
    "goal_stage": "informal_planning",
    "nodes": [{"step_id":"prd","capability":"prd_generation","required":true,"depends_on":[],"reason":"scope"}]
  },
  "governance": {
    "goal_stage": "informal_planning",
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log",
    "context_mode": "summary_first"
  },
  "compile_hints": {},
  "failure_routing": {"default_action": "halt", "overrides": []}
}
<<<SUPERVISOR_ORCHESTRATION_END>>>
EOF
}

# ── Case 0 ──────────────────────────────────────────────────────────────
echo "Case 0: well-formed envelope passes extract + schema + drift"
ART0="${SANDBOX}/c0-happy.md"
write_valid_envelope_artifact "${ART0}"
result="$(run_exec "${ART0}")"
out0="${result%|*}"; rc0="${result##*|}"
assert_eq "case 0 exit 0" "0" "${rc0}"
assert_contains "case 0 reports schema_validation_passed" \
  "condition: schema_validation_passed" "${out0}"
assert_contains "case 0 names envelope artifact path" "${ART0}" "${out0}"

# ── Case 1 ──────────────────────────────────────────────────────────────
echo "Case 1: empty input context → missing_envelope_artifact"
out="$(CAP_WORKFLOW_INPUT_CONTEXT="" bash "${EXEC}" 2>&1)"
rc=$?
assert_eq "case 1 exit 41 on missing artifact" "41" "${rc}"
assert_contains "case 1 condition: schema_validation_failed" \
  "condition: schema_validation_failed" "${out}"
assert_contains "case 1 reason: missing_envelope_artifact" \
  "reason: missing_envelope_artifact" "${out}"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: artifact with no fence → envelope_extraction_failed"
ART2="${SANDBOX}/c2-no-fence.md"
cat > "${ART2}" <<'EOF'
# Supervisor reply (no fence at all)

The supervisor wrote prose only and forgot to wrap the canonical JSON
in <<<SUPERVISOR_ORCHESTRATION_BEGIN/END>>> markers. Extraction must
fail before the schema validator ever sees a payload.
EOF
result="$(run_exec "${ART2}")"
out2="${result%|*}"; rc2="${result##*|}"
assert_eq "case 2 exit 41 on missing fence" "41" "${rc2}"
assert_contains "case 2 condition: schema_validation_failed" \
  "condition: schema_validation_failed" "${out2}"
assert_contains "case 2 reason: envelope_extraction_failed" \
  "reason: envelope_extraction_failed" "${out2}"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: fence + JSON but missing failure_routing required → schema_validation_failed"
ART3="${SANDBOX}/c3-no-failure-routing.md"
cat > "${ART3}" <<'EOF'
<<<SUPERVISOR_ORCHESTRATION_BEGIN>>>
{
  "schema_version": 1,
  "task_id": "smoke-002",
  "source_request": "missing failure_routing",
  "produced_at": "2026-05-03T22:00:00Z",
  "supervisor_role": "01-Supervisor",
  "task_constitution": {
    "task_id": "smoke-002",
    "project_id": "smoke-proj",
    "source_request": "missing failure_routing",
    "goal": "exercise schema fail path",
    "goal_stage": "informal_planning",
    "success_criteria": ["schema must reject this"],
    "non_goals": [],
    "execution_plan": [{"step_id":"prd","capability":"prd_generation"}]
  },
  "capability_graph": {
    "schema_version": 1,
    "task_id": "smoke-002",
    "goal_stage": "informal_planning",
    "nodes": [{"step_id":"prd","capability":"prd_generation","required":true,"depends_on":[],"reason":"scope"}]
  },
  "governance": {
    "goal_stage": "informal_planning",
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log",
    "context_mode": "summary_first"
  },
  "compile_hints": {}
}
<<<SUPERVISOR_ORCHESTRATION_END>>>
EOF
result="$(run_exec "${ART3}")"
out3="${result%|*}"; rc3="${result##*|}"
assert_eq "case 3 exit 41 on schema fail" "41" "${rc3}"
assert_contains "case 3 condition: schema_validation_failed" \
  "condition: schema_validation_failed" "${out3}"
assert_contains "case 3 reason: schema_validation_failed" \
  "reason: schema_validation_failed" "${out3}"
assert_contains "case 3 names failure_routing in errors" \
  "failure_routing" "${out3}"

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: schema-valid envelope with task_id drift → envelope_drift_detected"
ART4="${SANDBOX}/c4-drift.md"
# envelope.task_id = "envelope-says-X" but task_constitution.task_id = "nested-says-Y"
write_valid_envelope_artifact "${ART4}" "envelope-says-X" "nested-says-Y" "smoke source"
result="$(run_exec "${ART4}")"
out4="${result%|*}"; rc4="${result##*|}"
assert_eq "case 4 exit 41 on drift" "41" "${rc4}"
assert_contains "case 4 condition: schema_validation_failed" \
  "condition: schema_validation_failed" "${out4}"
assert_contains "case 4 reason: envelope_drift_detected" \
  "reason: envelope_drift_detected" "${out4}"
# The drift output block must show task_id mismatch detail.
assert_contains "case 4 drift output names task_id drift" \
  "task_id drift" "${out4}"

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "----------------------------------------------------------------"
echo "Summary: ${pass_count} passed, ${fail_count} failed"
echo "----------------------------------------------------------------"

[ ${fail_count} -eq 0 ]
