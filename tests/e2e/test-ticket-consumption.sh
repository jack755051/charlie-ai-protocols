#!/usr/bin/env bash
#
# test-ticket-consumption.sh — Deterministic e2e for the ticket consumption
# half of the dispatch loop.
#
# Exercises:
#   persist + emit (real)            → produces a Type C ticket
#   fake-sub-agent.sh (success)      → consumes ticket, writes Type D summary
#   fake-sub-agent.sh (failure mode) → still writes Type D with result=失敗
#   fake-sub-agent.sh + bad ticket   → halts with schema validation error
#   fake-sub-agent.sh + missing env  → halts with missing-ticket-path error
#
# Verifies:
#   - Type D handoff summary lands at ticket.output_expectations.handoff_summary_path
#   - Type D content includes YAML frontmatter (agent_id / step_id / task_id /
#     result / output_paths) and the body sections required by
#     policies/handoff-ticket-protocol.md §4
#   - Original ticket is not mutated by consumption (read-only contract)
#   - Failure path produces a Type D summary that downstream can detect

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PERSIST_SCRIPT="${REPO_ROOT}/scripts/workflows/persist-task-constitution.sh"
EMIT_SCRIPT="${REPO_ROOT}/scripts/workflows/emit-handoff-ticket.sh"
FAKE_AGENT_SCRIPT="${REPO_ROOT}/scripts/workflows/fake-sub-agent.sh"

[ -x "${PERSIST_SCRIPT}" ]    || { echo "FAIL: persist script missing"; exit 1; }
[ -x "${EMIT_SCRIPT}" ]       || { echo "FAIL: emit script missing"; exit 1; }
[ -x "${FAKE_AGENT_SCRIPT}" ] || { echo "FAIL: fake-sub-agent script missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-e2e-consumption.XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

CAP_HOME="${SANDBOX}/cap"
PROJECT_ID="token-monitor-minimal"
TASK_ID="e2e-consumption-001"

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
  if [ -f "${path}" ]; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    missing: ${path}"
    fail_count=$((fail_count + 1))
  fi
}

assert_file_contains() {
  local desc="$1" path="$2" needle="$3"
  if grep -qF -- "${needle}" "${path}" 2>/dev/null; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected to contain: ${needle}"
    echo "    in: ${path}"
    fail_count=$((fail_count + 1))
  fi
}

# ─────────────────────────────────────────────────────────
# Pre-stage: persist + emit produces a real ticket
# ─────────────────────────────────────────────────────────

cat > "${SANDBOX}/draft.md" <<'EOF'
<<<TASK_CONSTITUTION_JSON_BEGIN>>>
{
  "task_id": "e2e-consumption-001",
  "project_id": "token-monitor-minimal",
  "goal": "deterministic e2e of ticket consumption (fake sub-agent)",
  "goal_stage": "formal_specification",
  "success_criteria": ["Type D summary written at expected path", "ticket schema validation enforced"],
  "execution_plan": [
    {"step_id": "prd", "capability": "prd_generation", "bound_to": "01-supervisor"}
  ],
  "governance": {"watcher_mode": "milestone_gate"}
}
<<<TASK_CONSTITUTION_JSON_END>>>
EOF

CAP_HOME="${CAP_HOME}" \
CAP_PROJECT_ID_OVERRIDE="${PROJECT_ID}" \
CAP_WORKFLOW_INPUT_CONTEXT="- name=task_constitution_draft path=${SANDBOX}/draft.md" \
bash "${PERSIST_SCRIPT}" > /dev/null 2>&1
TC_PATH="${CAP_HOME}/projects/${PROJECT_ID}/constitutions/${TASK_ID}.json"

CAP_HOME="${CAP_HOME}" \
CAP_PROJECT_ID_OVERRIDE="${PROJECT_ID}" \
CAP_TASK_CONSTITUTION_PATH="${TC_PATH}" \
CAP_TARGET_STEP_ID=prd \
CAP_WORKFLOW_STEP_ID=emit_prd_ticket \
bash "${EMIT_SCRIPT}" > /dev/null 2>&1
TICKET_PATH="${CAP_HOME}/projects/${PROJECT_ID}/handoffs/prd.ticket.json"
[ -f "${TICKET_PATH}" ] || { echo "FAIL: pre-stage emit did not produce ticket"; exit 1; }

# Compute expected handoff_summary_path from the ticket itself
EXPECTED_SUMMARY_PATH="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['output_expectations']['handoff_summary_path'])" "${TICKET_PATH}")"

# ─────────────────────────────────────────────────────────
# Case 1: success consumption
# ─────────────────────────────────────────────────────────

echo "Case 1: success consumption writes Type D"

# Snapshot ticket bytes to verify read-only contract later
TICKET_HASH_BEFORE="$(shasum -a 256 "${TICKET_PATH}" | awk '{print $1}')"

CAP_HANDOFF_TICKET_PATH="${TICKET_PATH}" \
CAP_ROOT="${REPO_ROOT}" \
bash "${FAKE_AGENT_SCRIPT}" > "${SANDBOX}/fake-success.out" 2>&1
rc=$?
assert_eq "fake-sub-agent exits 0 on success" "0" "${rc}"
assert_file_contains "stdout reports FAKE_OK" "${SANDBOX}/fake-success.out" "FAKE_OK"

assert_file_exists "Type D summary at ticket-specified path" "${EXPECTED_SUMMARY_PATH}"
assert_file_contains "Type D has YAML frontmatter agent_id" "${EXPECTED_SUMMARY_PATH}" "agent_id:"
assert_file_contains "Type D has YAML frontmatter step_id" "${EXPECTED_SUMMARY_PATH}" "step_id: prd"
assert_file_contains "Type D has YAML frontmatter task_id" "${EXPECTED_SUMMARY_PATH}" "task_id: ${TASK_ID}"
assert_file_contains "Type D has YAML frontmatter result=成功" "${EXPECTED_SUMMARY_PATH}" "result: 成功"
assert_file_contains "Type D has output_paths block" "${EXPECTED_SUMMARY_PATH}" "output_paths:"
assert_file_contains "Type D body has task_summary section" "${EXPECTED_SUMMARY_PATH}" "## task_summary"
assert_file_contains "Type D body has key_decisions section" "${EXPECTED_SUMMARY_PATH}" "## key_decisions"
assert_file_contains "Type D body has downstream_notes section" "${EXPECTED_SUMMARY_PATH}" "## downstream_notes"
assert_file_contains "Type D body has halt_signals_raised section" "${EXPECTED_SUMMARY_PATH}" "## halt_signals_raised"

# Read-only contract: ticket bytes unchanged after consumption
TICKET_HASH_AFTER="$(shasum -a 256 "${TICKET_PATH}" | awk '{print $1}')"
assert_eq "ticket file unchanged after consumption (read-only contract)" "${TICKET_HASH_BEFORE}" "${TICKET_HASH_AFTER}"

# ─────────────────────────────────────────────────────────
# Case 2: failure consumption still emits Type D with result=失敗
# ─────────────────────────────────────────────────────────

echo "Case 2: failure consumption writes Type D with result=失敗"

# Use a fresh ticket to avoid overwriting the success-case Type D
CAP_HOME="${CAP_HOME}" \
CAP_PROJECT_ID_OVERRIDE="${PROJECT_ID}" \
CAP_TASK_CONSTITUTION_PATH="${TC_PATH}" \
CAP_TARGET_STEP_ID=prd \
CAP_WORKFLOW_STEP_ID=emit_prd_ticket \
bash "${EMIT_SCRIPT}" > /dev/null 2>&1
TICKET_PATH_2="${CAP_HOME}/projects/${PROJECT_ID}/handoffs/prd-2.ticket.json"
EXPECTED_SUMMARY_PATH_2="${EXPECTED_SUMMARY_PATH}"  # both tickets target same step → same handoff_summary_path

# Move the success-case Type D out of the way so we can verify failure overwrites
mv "${EXPECTED_SUMMARY_PATH}" "${SANDBOX}/prd.handoff.success-snapshot.md"

CAP_HANDOFF_TICKET_PATH="${TICKET_PATH_2}" \
CAP_ROOT="${REPO_ROOT}" \
CAP_FAKE_RESULT=failure \
CAP_FAKE_HALT_SIGNAL="simulated_halt_for_e2e" \
bash "${FAKE_AGENT_SCRIPT}" > "${SANDBOX}/fake-failure.out" 2>&1
rc=$?
assert_eq "fake-sub-agent exits 1 on failure" "1" "${rc}"
assert_file_contains "stdout reports FAKE_FAIL" "${SANDBOX}/fake-failure.out" "FAKE_FAIL"
assert_file_exists "Type D summary still written on failure" "${EXPECTED_SUMMARY_PATH_2}"
assert_file_contains "Type D records result=失敗" "${EXPECTED_SUMMARY_PATH_2}" "result: 失敗"
assert_file_contains "Type D records halt signal" "${EXPECTED_SUMMARY_PATH_2}" "simulated_halt_for_e2e"

# ─────────────────────────────────────────────────────────
# Case 3: malformed ticket halts with schema validation error
# ─────────────────────────────────────────────────────────

echo "Case 3: malformed ticket triggers schema validation halt"

cat > "${SANDBOX}/bad-ticket.json" <<'EOF'
{"this_is_not_a_handoff_ticket": true}
EOF

CAP_HANDOFF_TICKET_PATH="${SANDBOX}/bad-ticket.json" \
CAP_ROOT="${REPO_ROOT}" \
bash "${FAKE_AGENT_SCRIPT}" > "${SANDBOX}/fake-bad-ticket.out" 2>&1
rc=$?
assert_eq "fake-sub-agent exits 3 on schema fail" "3" "${rc}"
assert_file_contains "stderr captured schema fail" "${SANDBOX}/fake-bad-ticket.out" "ticket fails schema validation"

# ─────────────────────────────────────────────────────────
# Case 4: missing CAP_HANDOFF_TICKET_PATH halts cleanly
# ─────────────────────────────────────────────────────────

echo "Case 4: missing ticket path halts at exit 2"

CAP_ROOT="${REPO_ROOT}" \
bash "${FAKE_AGENT_SCRIPT}" > "${SANDBOX}/fake-noenv.out" 2>&1
rc=$?
assert_eq "fake-sub-agent exits 2 when no ticket given" "2" "${rc}"
assert_file_contains "stderr says CAP_HANDOFF_TICKET_PATH not set" "${SANDBOX}/fake-noenv.out" "CAP_HANDOFF_TICKET_PATH not set"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ ${fail_count} -eq 0 ]
