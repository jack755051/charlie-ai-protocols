#!/usr/bin/env bash
#
# test-project-spec-pipeline-deterministic.sh — Deterministic e2e for the
# project-spec-pipeline shell-executor chain.
#
# Exercises (without AI):
#   draft (mocked) → persist-task-constitution.sh
#                  → emit-handoff-ticket.sh × 6 (one per AI step in spec)
#                  → re-emit (seq increment verification)
#
# The actual AI step bodies (prd, tech_plan, ba, dba_api, ui, spec_audit) are
# not executed; this test verifies the deterministic envelope around them
# behaves correctly end to end. AI sub-agent ticket consumption is covered by
# tests/e2e/test-ticket-consumption.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PERSIST_SCRIPT="${REPO_ROOT}/scripts/workflows/persist-task-constitution.sh"
EMIT_SCRIPT="${REPO_ROOT}/scripts/workflows/emit-handoff-ticket.sh"

[ -x "${PERSIST_SCRIPT}" ] || { echo "FAIL: persist script not executable"; exit 1; }
[ -x "${EMIT_SCRIPT}" ]    || { echo "FAIL: emit script not executable"; exit 1; }

SANDBOX="$(mktemp -d -t cap-e2e-spec.XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

CAP_HOME="${SANDBOX}/cap"
PROJECT_ID="token-monitor-minimal"
TASK_ID="e2e-spec-001"

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

assert_json_field() {
  local desc="$1" path="$2" key="$3" expected="$4"
  local actual
  actual="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ''))" "${path}" "${key}" 2>/dev/null)"
  assert_eq "${desc}" "${expected}" "${actual}"
}

# ─────────────────────────────────────────────────────────
# Stage A: build the task constitution draft fixture
# ─────────────────────────────────────────────────────────

echo "Stage A: build task_constitution_draft fixture"

DRAFT_PATH="${SANDBOX}/draft.md"
cat > "${DRAFT_PATH}" <<'EOF'
# Task Constitution Draft (e2e fixture)

<<<TASK_CONSTITUTION_JSON_BEGIN>>>
{
  "task_id": "e2e-spec-001",
  "project_id": "token-monitor-minimal",
  "goal": "deterministic e2e of project-spec-pipeline executor chain",
  "goal_stage": "formal_specification",
  "success_criteria": [
    "persist task constitution",
    "emit ticket for every AI step",
    "seq increment on retry"
  ],
  "execution_plan": [
    {"step_id": "prd",         "capability": "prd_generation",       "bound_to": "01-supervisor"},
    {"step_id": "tech_plan",   "capability": "technical_planning",   "bound_to": "02-techlead"},
    {"step_id": "ba",          "capability": "business_analysis",    "bound_to": "02a-ba"},
    {"step_id": "dba_api",     "capability": "database_api_design",  "bound_to": "02b-dba"},
    {"step_id": "ui",          "capability": "ui_design",            "bound_to": "03-ui"},
    {"step_id": "spec_audit",  "capability": "code_structure_audit", "bound_to": "90-watcher"}
  ],
  "governance": {
    "watcher_mode": "milestone_gate",
    "watcher_checkpoints": ["tech_plan", "spec_audit"],
    "logger_mode": "milestone_log",
    "budget_sub_agent_sessions": 6
  }
}
<<<TASK_CONSTITUTION_JSON_END>>>
EOF
assert_file_exists "draft fixture written" "${DRAFT_PATH}"

# ─────────────────────────────────────────────────────────
# Stage B: persist
# ─────────────────────────────────────────────────────────

echo "Stage B: persist-task-constitution"

CAP_HOME="${CAP_HOME}" \
CAP_WORKFLOW_INPUT_CONTEXT="- name=task_constitution_draft path=${DRAFT_PATH}" \
CAP_WORKFLOW_STEP_ID=persist_task_constitution \
bash "${PERSIST_SCRIPT}" > "${SANDBOX}/persist.out" 2>&1
persist_rc=$?
assert_eq "persist exits 0" "0" "${persist_rc}"

TC_PATH="${CAP_HOME}/projects/${PROJECT_ID}/constitutions/${TASK_ID}.json"
assert_file_exists "task_constitution persisted at expected path" "${TC_PATH}"

assert_json_field "persisted task_id matches" "${TC_PATH}" "task_id" "${TASK_ID}"
assert_json_field "persisted project_id matches" "${TC_PATH}" "project_id" "${PROJECT_ID}"
assert_json_field "persisted goal_stage matches" "${TC_PATH}" "goal_stage" "formal_specification"

# ─────────────────────────────────────────────────────────
# Stage C: emit one ticket per AI step
# ─────────────────────────────────────────────────────────

echo "Stage C: emit handoff tickets per AI step"

declare -a steps=(prd tech_plan ba dba_api ui spec_audit)
declare -A expected_capability=(
  [prd]=prd_generation
  [tech_plan]=technical_planning
  [ba]=business_analysis
  [dba_api]=database_api_design
  [ui]=ui_design
  [spec_audit]=code_structure_audit
)

for step in "${steps[@]}"; do
  CAP_HOME="${CAP_HOME}" \
  CAP_TASK_CONSTITUTION_PATH="${TC_PATH}" \
  CAP_TARGET_STEP_ID="${step}" \
  CAP_WORKFLOW_STEP_ID="emit_${step}_ticket" \
  bash "${EMIT_SCRIPT}" > "${SANDBOX}/emit-${step}.out" 2>&1
  rc=$?
  assert_eq "emit ${step} exits 0" "0" "${rc}"

  ticket_path="${CAP_HOME}/projects/${PROJECT_ID}/handoffs/${step}.ticket.json"
  assert_file_exists "ticket file for ${step} exists" "${ticket_path}"
  assert_json_field "${step} ticket target_capability" "${ticket_path}" "target_capability" "${expected_capability[${step}]}"
  assert_json_field "${step} ticket step_id" "${ticket_path}" "step_id" "${step}"
  assert_json_field "${step} ticket ticket_id seq=1" "${ticket_path}" "ticket_id" "${TASK_ID}-${step}-1"
done

# ─────────────────────────────────────────────────────────
# Stage D: seq increment verification (re-emit prd)
# ─────────────────────────────────────────────────────────

echo "Stage D: seq increment on re-emit"

CAP_HOME="${CAP_HOME}" \
CAP_TASK_CONSTITUTION_PATH="${TC_PATH}" \
CAP_TARGET_STEP_ID=prd \
CAP_WORKFLOW_STEP_ID=emit_prd_ticket \
bash "${EMIT_SCRIPT}" > "${SANDBOX}/reemit-prd.out" 2>&1
assert_eq "re-emit prd exits 0" "0" "$?"

prd_seq2="${CAP_HOME}/projects/${PROJECT_ID}/handoffs/prd-2.ticket.json"
assert_file_exists "prd-2.ticket.json exists" "${prd_seq2}"
assert_json_field "prd-2 ticket_id has seq=2" "${prd_seq2}" "ticket_id" "${TASK_ID}-prd-2"

prd_seq1="${CAP_HOME}/projects/${PROJECT_ID}/handoffs/prd.ticket.json"
assert_file_exists "original prd.ticket.json preserved (audit trail)" "${prd_seq1}"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ ${fail_count} -eq 0 ]
