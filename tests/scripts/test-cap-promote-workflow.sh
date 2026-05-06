#!/usr/bin/env bash
#
# test-cap-promote-workflow.sh — P10 #5 focused test.
#
# Exercises engine/promote_cli.py:cmd_workflow + the
# scripts/cap-promote.sh workflow dispatch. Reference:
# policies/runtime-promote.md §3.2 (target path), §4 (overwrite +
# backup), §6 (validation + rollback), §7.3 (CLI shape).
#
# Cases (mirrors P10 #4 layout for predictability):
#   1. dry-run when no target → dry_run_no_target.
#   2. --apply on no-target → applied_fresh + validation passes.
#   3. --apply on identical target → applied_identical_skip.
#   4. --apply on diff without --force → halted_conflict, target
#      untouched.
#   5. --apply --force on diff → applied_force_with_backup with a
#      real ISO timestamp and backup file landed.
#   6. invalid source content → schema validation fails →
#      validation_failed_rolled_back; target restored.
#   7. workflow invoked on a task_id (resolves as
#      project_constitution) → exit 1 with promote_artifact_not_found
#      because the workflow guard rejects type mismatch.
#   8. unknown workflow_id → exit 1 with promote_artifact_not_found.
#   9. bash dispatcher matches Python CLI output.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
PROMOTE_CLI="${REPO_ROOT}/engine/promote_cli.py"
PROMOTE_SH="${REPO_ROOT}/scripts/cap-promote.sh"

[ -f "${PROMOTE_CLI}" ] || { echo "FAIL: promote_cli.py missing"; exit 1; }
[ -f "${PROMOTE_SH}" ]  || { echo "FAIL: cap-promote.sh missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-promote-wf-test.XXXXXX)"
SANDBOX="$(cd "${SANDBOX}" && pwd -P)"
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
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    needle: ${needle}"
    echo "    head:   $(printf '%s' "${haystack}" | head -c 200)"
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

# ── Sandbox layout ────────────────────────────────────────────────

PROJECT_ROOT="${SANDBOX}/proj"
CAP_HOME_DIR="${SANDBOX}/cap_home"
PROJECT_ID="cap-promote-wf-test"
WF_ID="wf-test-promote"
mkdir -p \
  "${PROJECT_ROOT}/.cap/workflows" \
  "${CAP_HOME_DIR}/projects/${PROJECT_ID}/compiled-workflows/${WF_ID}"

WF_SOURCE="${CAP_HOME_DIR}/projects/${PROJECT_ID}/compiled-workflows/${WF_ID}/20260506-130000.json"
WF_TARGET="${PROJECT_ROOT}/.cap/workflows/${WF_ID}.yaml"

# Minimal compiled workflow that satisfies
# schemas/compiled-workflow.schema.yaml (mirrors the Positive 1
# fixture in test-compiled-workflow-schema.sh). JSON form because
# the runtime tree usually emits .json snapshots; the apply path
# loads JSON or YAML interchangeably and writes whatever filename
# extension the target expects (.yaml in this test fixture).
write_valid_workflow() {
  cat > "$1" <<EOF
{
  "schema_version": 1,
  "workflow_id": "${WF_ID}",
  "version": 2,
  "name": "Compiled Workflow Promote Smoke",
  "summary": "minimal valid compiled workflow used by P10 #5 promote tests",
  "owner": "supervisor",
  "triggers": ["manual", "compiled"],
  "governance": {
    "goal_stage": "informal_planning",
    "context_mode": "summary_first",
    "halt_on_missing_handoff": true,
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log"
  },
  "steps": [
    {
      "id": "prd",
      "name": "Task PRD",
      "capability": "prd_generation",
      "needs": [],
      "inputs": ["user_requirement"],
      "outputs": ["prd_document"],
      "done_when": ["PRD acknowledged by user"],
      "optional": false,
      "on_fail": "halt",
      "record_level": "trace_only",
      "input_mode": "summary",
      "output_tier": "planning_artifact",
      "continue_reason": "define goal and scope"
    }
  ]
}
EOF
}

write_valid_workflow "${WF_SOURCE}"

# wf_run [--apply] [--force] [--json]
wf_run() {
  PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" "${PROMOTE_CLI}" workflow \
    --project-root "${PROJECT_ROOT}" \
    --cap-home "${CAP_HOME_DIR}" \
    --project-id "${PROJECT_ID}" \
    "${WF_ID}" "$@"
}

wf_run_id() {
  local id="$1"
  shift
  PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" "${PROMOTE_CLI}" workflow \
    --project-root "${PROJECT_ROOT}" \
    --cap-home "${CAP_HOME_DIR}" \
    --project-id "${PROJECT_ID}" \
    "${id}" "$@"
}

json_field() {
  local json_str="$1" expr="$2"
  "${PYTHON_BIN}" - "${json_str}" "${expr}" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
print(eval(sys.argv[2], {"data": data}))
PY
}

# ── Case 1: dry-run, no target ────────────────────────────────────

echo "Case 1: dry-run when no target → dry_run_no_target"
[ ! -f "${WF_TARGET}" ] || rm -f "${WF_TARGET}"

OUT1="$(wf_run --json)"
assert_eq "case1: ok=True" "True" "$(json_field "${OUT1}" 'data["ok"]')"
assert_eq "case1: action=dry_run_no_target" "dry_run_no_target" \
  "$(json_field "${OUT1}" 'data["action"]')"
assert_eq "case1: artifact_type=compiled_workflow" "compiled_workflow" \
  "$(json_field "${OUT1}" 'data["artifact_type"]')"
assert_file_absent "case1: target NOT written during dry-run" "${WF_TARGET}"

# ── Case 2: --apply on no_target → applied_fresh ──────────────────

echo ""
echo "Case 2: --apply on no_target → applied_fresh + validation passes"
OUT2="$(wf_run --apply --json)"
assert_eq "case2: ok=True" "True" "$(json_field "${OUT2}" 'data["ok"]')"
assert_eq "case2: action=applied_fresh" "applied_fresh" \
  "$(json_field "${OUT2}" 'data["action"]')"
assert_eq "case2: validation.ok=True" "True" \
  "$(json_field "${OUT2}" 'data["validation"]["ok"]')"
[ -f "${WF_TARGET}" ] && {
  echo "  PASS: case2: target landed under .cap/workflows/"
  pass_count=$((pass_count + 1))
} || {
  echo "  FAIL: case2: target missing"
  fail_count=$((fail_count + 1))
}
# Target path under <project_root>/.cap/workflows/<workflow_id>.yaml.
assert_eq "case2: target_path matches policy §3.2 layout" \
  "${WF_TARGET}" "$(json_field "${OUT2}" 'data["target_path"]')"

# ── Case 3: --apply on identical → applied_identical_skip ─────────

echo ""
echo "Case 3: --apply on identical → applied_identical_skip (no validation re-run)"
OUT3="$(wf_run --apply --json)"
assert_eq "case3: action=applied_identical_skip" "applied_identical_skip" \
  "$(json_field "${OUT3}" 'data["action"]')"
assert_eq "case3: backup_path=null" "None" \
  "$(json_field "${OUT3}" 'data["backup_path"]')"
assert_eq "case3: validation skipped (None)" "None" \
  "$(json_field "${OUT3}" 'data["validation"]')"

# ── Case 4: --apply on diff without --force → halted_conflict ─────

echo ""
echo "Case 4: --apply on diff without --force → halted_conflict (target untouched)"
echo '{"workflow_id": "tampered", "schema_version": 1}' > "${WF_TARGET}"
TARGET_BEFORE="$(cat "${WF_TARGET}")"

set +e
OUT4="$(wf_run --apply --json)"
RC4=$?
set -e
assert_eq "case4: exit code 1" "1" "${RC4}"
assert_eq "case4: action=halted_conflict" "halted_conflict" \
  "$(json_field "${OUT4}" 'data["action"]')"
assert_eq "case4: error=promote_conflict_halt" "promote_conflict_halt" \
  "$(json_field "${OUT4}" 'data["error"]')"
TARGET_AFTER="$(cat "${WF_TARGET}")"
assert_eq "case4: target untouched on halt" "${TARGET_BEFORE}" "${TARGET_AFTER}"

# ── Case 5: --apply --force on diff → applied_force_with_backup ──

echo ""
echo "Case 5: --apply --force on diff → applied_force_with_backup + backup landed"
OUT5="$(wf_run --apply --force --json)"
assert_eq "case5: ok=True" "True" "$(json_field "${OUT5}" 'data["ok"]')"
assert_eq "case5: action=applied_force_with_backup" "applied_force_with_backup" \
  "$(json_field "${OUT5}" 'data["action"]')"
BACKUP_PATH5="$(json_field "${OUT5}" 'data["backup_path"]')"
case "${BACKUP_PATH5}" in
  *"<ISO>"*)
    echo "  FAIL: case5: backup_path still has <ISO> placeholder"
    fail_count=$((fail_count + 1)) ;;
  "${WF_TARGET}.bak."*)
    echo "  PASS: case5: backup_path uses real timestamp"
    pass_count=$((pass_count + 1)) ;;
  *)
    echo "  FAIL: case5: backup_path unexpected: ${BACKUP_PATH5}"
    fail_count=$((fail_count + 1)) ;;
esac
[ -f "${BACKUP_PATH5}" ] && {
  echo "  PASS: case5: backup file actually written"
  pass_count=$((pass_count + 1))
} || {
  echo "  FAIL: case5: backup file missing"
  fail_count=$((fail_count + 1))
}
DIFF_OUT="$(diff -q "${WF_TARGET}" "${WF_SOURCE}" 2>&1 || true)"
assert_eq "case5: target now byte-equal source" "" "${DIFF_OUT}"

# ── Case 6: invalid source → validation rollback ─────────────────

echo ""
echo "Case 6: invalid source content → validation_failed_rolled_back"
INVALID_WF_ID="wf-invalid-promote"
INVALID_DIR="${CAP_HOME_DIR}/projects/${PROJECT_ID}/compiled-workflows/${INVALID_WF_ID}"
mkdir -p "${INVALID_DIR}"
# Compiled workflow that fails schema (missing required fields).
cat > "${INVALID_DIR}/20260506-140000.json" <<'EOF'
{
  "schema_version": 1,
  "workflow_id": "wf-invalid-promote",
  "incomplete": "missing required fields like version, owner, governance, steps"
}
EOF

# Snapshot target so we can verify rollback restores the pre-apply
# state. Re-use the (now valid) WF_TARGET from case 5.
TARGET_BEFORE6="$(cat "${WF_TARGET}")"

set +e
OUT6="$(wf_run_id "${INVALID_WF_ID}" --apply --force --json)"
RC6=$?
set -e
# The invalid workflow uses a different workflow_id, so target is
# .cap/workflows/wf-invalid-promote.yaml (which doesn't exist).
# Apply path: target=no_target → fresh write → validate → fail →
# rollback unlinks the target.
INVALID_TARGET="${PROJECT_ROOT}/.cap/workflows/${INVALID_WF_ID}.yaml"
assert_eq "case6: exit code 1" "1" "${RC6}"
assert_eq "case6: action=validation_failed_rolled_back" "validation_failed_rolled_back" \
  "$(json_field "${OUT6}" 'data["action"]')"
assert_eq "case6: validation.ok=False" "False" \
  "$(json_field "${OUT6}" 'data["validation"]["ok"]')"
assert_file_absent "case6: invalid target removed by rollback (was no_target)" \
  "${INVALID_TARGET}"
TARGET_AFTER6="$(cat "${WF_TARGET}")"
assert_eq "case6: original valid target untouched" "${TARGET_BEFORE6}" "${TARGET_AFTER6}"

# ── Case 7: workflow invoked on a task_id → not found ────────────

echo ""
echo "Case 7: workflow invoked on a task_id → exit 1 (artifact_type guard rejects)"
TASK_ID="task-conflicting-id"
mkdir -p "${CAP_HOME_DIR}/projects/${PROJECT_ID}/constitutions/${TASK_ID}"
cat > "${CAP_HOME_DIR}/projects/${PROJECT_ID}/constitutions/${TASK_ID}/constitution.yaml" <<'EOF'
schema_version: 1
constitution_id: distractor
EOF

set +e
OUT7="$(wf_run_id "${TASK_ID}" --json)"
RC7=$?
set -e
assert_eq "case7: exit code 1" "1" "${RC7}"
assert_contains "case7: error=promote_artifact_not_found" "${OUT7}" \
  '"error": "promote_artifact_not_found"'
assert_contains "case7: artifact_type filter mentions compiled_workflow" "${OUT7}" \
  '"artifact_type": "compiled_workflow"'

# ── Case 8: unknown workflow_id → not_found ──────────────────────

echo ""
echo "Case 8: unknown workflow_id → exit 1 with promote_artifact_not_found"
set +e
OUT8="$(wf_run_id "unknown-workflow-doesnt-exist" --json)"
RC8=$?
set -e
assert_eq "case8: exit code 1" "1" "${RC8}"
assert_contains "case8: error tag" "${OUT8}" '"error": "promote_artifact_not_found"'

# ── Case 9: bash dispatcher matches python ───────────────────────

echo ""
echo "Case 9: scripts/cap-promote.sh workflow matches python CLI"
# Reset target to byte-equal source for deterministic identical action.
cp "${WF_SOURCE}" "${WF_TARGET}"

PY_OUT="$(wf_run --json)"
BASH_OUT="$(CAP_HOME="${CAP_HOME_DIR}" CAP_PROJECT_ROOT="${PROJECT_ROOT}" \
  CAP_PROJECT_ID_OVERRIDE="${PROJECT_ID}" \
  bash "${PROMOTE_SH}" workflow "${WF_ID}" --json 2>&1)"

assert_eq "case9: bash and python output match" \
  "$(printf '%s' "${PY_OUT}" | tr -d '\r')" \
  "$(printf '%s' "${BASH_OUT}" | tr -d '\r')"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
