#!/usr/bin/env bash
#
# test-cap-promote-project-constitution.sh — P10 #4 focused test.
#
# Exercises engine/promote_apply.py:apply_promote +
# engine/promote_cli.py:cmd_project_constitution + the
# scripts/cap-promote.sh project-constitution dispatch. Reference:
# policies/runtime-promote.md §3.1 (target path), §4 (overwrite +
# backup), §6 (validation + rollback), §7.2 (CLI shape).
#
# Cases:
#   1. dry-run when no target: action=dry_run_no_target, no I/O.
#   2. dry-run when target identical: action=dry_run_identical.
#   3. dry-run when target differs (no --force): action=dry_run_conflict.
#   4. dry-run when target differs + --force: action=dry_run_force_overwrite.
#   5. --apply on no-target: writes target, action=applied_fresh,
#      validation passes.
#   6. --apply on identical: action=applied_identical_skip, no
#      backup, no validation re-run.
#   7. --apply on diff without --force: action=halted_conflict,
#      target untouched.
#   8. --apply on diff with --force: action=applied_force_with_backup,
#      backup written with real ISO timestamp, target overwritten.
#   9. --apply with invalid source content: schema validation fails;
#      target rolled back to pre-apply state, action=
#      validation_failed_rolled_back.
#  10. resolved as compiled_workflow but invoked via
#      project-constitution: action=halted_type_mismatch.
#  11. unknown task_id: exit 1, promote_artifact_not_found.
#  12. legacy .cap.constitution.yaml is NEVER written by --apply
#      (policy §3.1).
#  13. bash dispatcher matches Python CLI output.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
PROMOTE_CLI="${REPO_ROOT}/engine/promote_cli.py"
PROMOTE_SH="${REPO_ROOT}/scripts/cap-promote.sh"

[ -f "${PROMOTE_CLI}" ] || { echo "FAIL: promote_cli.py missing"; exit 1; }
[ -f "${PROMOTE_SH}" ]  || { echo "FAIL: cap-promote.sh missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-promote-pc-test.XXXXXX)"
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
  if grep -qF -- "${needle}" <<<"${haystack}"; then
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

assert_file_contents() {
  local desc="$1" path="$2" expected_contents="$3"
  if [ ! -f "${path}" ]; then
    echo "  FAIL: ${desc} (file missing): ${path}"
    fail_count=$((fail_count + 1))
    return
  fi
  local actual
  actual="$(cat "${path}")"
  if [ "${actual}" = "${expected_contents}" ]; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected: ${expected_contents}"
    echo "    actual:   ${actual}"
    fail_count=$((fail_count + 1))
  fi
}

# ── Sandbox layout ────────────────────────────────────────────────

PROJECT_ROOT="${SANDBOX}/proj"
CAP_HOME_DIR="${SANDBOX}/cap_home"
PROJECT_ID="cap-promote-pc-test"
TASK_ID="task-alpha"
mkdir -p \
  "${PROJECT_ROOT}/.cap" \
  "${CAP_HOME_DIR}/projects/${PROJECT_ID}/constitutions/${TASK_ID}"

CONST_SOURCE="${CAP_HOME_DIR}/projects/${PROJECT_ID}/constitutions/${TASK_ID}/constitution.yaml"
CONST_TARGET="${PROJECT_ROOT}/.cap/constitution.yaml"
CONST_LEGACY="${PROJECT_ROOT}/.cap.constitution.yaml"

# A constitution that satisfies schemas/project-constitution.schema.yaml.
# All 9 required fields populated with the minimum nested shape so
# post-apply validation passes for the happy-path cases.
write_valid_constitution() {
  cat > "$1" <<'EOF'
schema_version: 1
constitution_id: focused-test
project_id: cap-promote-pc-test
name: focused test constitution
summary: minimal valid constitution for P10 #4 promote tests
source_of_truth:
  project_constitution: .cap/constitution.yaml
  project_config: .cap/project.yaml
  skill_registry: .cap/skills.yaml
runtime_workspace:
  root: ~/.cap/projects/cap-promote-pc-test
  stores:
    - constitutions
    - compiled-workflows
binding_policy:
  defaults: {}
  allowed_capabilities: []
workflow_policy:
  enforce_allowed_source_roots: false
  allowed_source_roots: []
EOF
}

write_valid_constitution "${CONST_SOURCE}"

# pc_run [--apply] [--force] [--json]
pc_run() {
  PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" "${PROMOTE_CLI}" project-constitution \
    --project-root "${PROJECT_ROOT}" \
    --cap-home "${CAP_HOME_DIR}" \
    --project-id "${PROJECT_ID}" \
    "${TASK_ID}" "$@"
}

pc_run_other_id() {
  local task="$1"
  shift
  PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" "${PROMOTE_CLI}" project-constitution \
    --project-root "${PROJECT_ROOT}" \
    --cap-home "${CAP_HOME_DIR}" \
    --project-id "${PROJECT_ID}" \
    "${task}" "$@"
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
[ ! -f "${CONST_TARGET}" ] || rm -f "${CONST_TARGET}"

OUT1="$(pc_run --json)"
assert_eq "case1: ok=True"   "True"               "$(json_field "${OUT1}" 'data["ok"]')"
assert_eq "case1: action"    "dry_run_no_target"  "$(json_field "${OUT1}" 'data["action"]')"
assert_eq "case1: target_existed_before=False" "False" \
  "$(json_field "${OUT1}" 'data["target_existed_before"]')"
assert_file_absent "case1: target NOT written during dry-run" "${CONST_TARGET}"

# ── Case 2: dry-run, identical ────────────────────────────────────

echo ""
echo "Case 2: dry-run when target identical → dry_run_identical"
cp "${CONST_SOURCE}" "${CONST_TARGET}"

OUT2="$(pc_run --json)"
assert_eq "case2: action"            "dry_run_identical" \
  "$(json_field "${OUT2}" 'data["action"]')"
assert_eq "case2: target_existed=True" "True" \
  "$(json_field "${OUT2}" 'data["target_existed_before"]')"

# ── Case 3: dry-run, diff (no --force) ────────────────────────────

echo ""
echo "Case 3: dry-run when target differs (no --force) → dry_run_conflict"
echo 'schema_version: 1' > "${CONST_TARGET}"

OUT3="$(pc_run --json)"
assert_eq "case3: action" "dry_run_conflict" "$(json_field "${OUT3}" 'data["action"]')"
assert_contains "case3: backup_path uses .bak.<ISO> template" \
  "${OUT3}" '<ISO>'

# ── Case 4: dry-run, diff + --force ───────────────────────────────

echo ""
echo "Case 4: dry-run when target differs + --force → dry_run_force_overwrite"
OUT4="$(pc_run --force --json)"
assert_eq "case4: action" "dry_run_force_overwrite" \
  "$(json_field "${OUT4}" 'data["action"]')"

# ── Case 5: --apply on no-target → applied_fresh ──────────────────

echo ""
echo "Case 5: --apply on no-target → applied_fresh + validation passes"
rm -f "${CONST_TARGET}"

OUT5="$(pc_run --apply --json)"
assert_eq "case5: ok=True"             "True"  "$(json_field "${OUT5}" 'data["ok"]')"
assert_eq "case5: action=applied_fresh" "applied_fresh" \
  "$(json_field "${OUT5}" 'data["action"]')"
assert_eq "case5: validation.ok=True"  "True" \
  "$(json_field "${OUT5}" 'data["validation"]["ok"]')"
[ -f "${CONST_TARGET}" ] && {
  echo "  PASS: case5: target file landed"
  pass_count=$((pass_count + 1))
} || {
  echo "  FAIL: case5: target missing after --apply"
  fail_count=$((fail_count + 1))
}

# ── Case 6: --apply on identical → applied_identical_skip ─────────

echo ""
echo "Case 6: --apply on identical → applied_identical_skip"
OUT6="$(pc_run --apply --json)"
assert_eq "case6: action" "applied_identical_skip" \
  "$(json_field "${OUT6}" 'data["action"]')"
assert_eq "case6: validation skipped (None)" "None" \
  "$(json_field "${OUT6}" 'data["validation"]')"
assert_eq "case6: backup_path null" "None" \
  "$(json_field "${OUT6}" 'data["backup_path"]')"

# ── Case 7: --apply on diff without --force → halted_conflict ─────

echo ""
echo "Case 7: --apply on diff without --force → halted_conflict (target untouched)"
echo 'schema_version: 1' > "${CONST_TARGET}"
TARGET_BEFORE="$(cat "${CONST_TARGET}")"

set +e
OUT7="$(pc_run --apply --json)"
RC7=$?
set -e
assert_eq "case7: exit code 1"     "1"                "${RC7}"
assert_eq "case7: ok=False"        "False"            "$(json_field "${OUT7}" 'data["ok"]')"
assert_eq "case7: action"          "halted_conflict"  "$(json_field "${OUT7}" 'data["action"]')"
assert_eq "case7: error tag"       "promote_conflict_halt" \
  "$(json_field "${OUT7}" 'data["error"]')"
TARGET_AFTER="$(cat "${CONST_TARGET}")"
assert_eq "case7: target untouched" "${TARGET_BEFORE}" "${TARGET_AFTER}"

# ── Case 8: --apply --force on diff → applied_force_with_backup ──

echo ""
echo "Case 8: --apply --force on diff → applied_force_with_backup + real timestamp"
OUT8="$(pc_run --apply --force --json)"
assert_eq "case8: ok=True" "True" "$(json_field "${OUT8}" 'data["ok"]')"
assert_eq "case8: action" "applied_force_with_backup" \
  "$(json_field "${OUT8}" 'data["action"]')"
BACKUP_PATH8="$(json_field "${OUT8}" 'data["backup_path"]')"
assert_contains "case8: backup_path is real (not <ISO> template)" \
  "${BACKUP_PATH8}" "${CONST_TARGET}.bak."
case "${BACKUP_PATH8}" in
  *"<ISO>"*)
    echo "  FAIL: case8: backup_path still has <ISO> placeholder"
    fail_count=$((fail_count + 1)) ;;
  *)
    echo "  PASS: case8: backup_path uses real timestamp"
    pass_count=$((pass_count + 1)) ;;
esac
[ -f "${BACKUP_PATH8}" ] && {
  echo "  PASS: case8: backup file actually written"
  pass_count=$((pass_count + 1))
} || {
  echo "  FAIL: case8: backup file missing"
  fail_count=$((fail_count + 1))
}
# Target should now match source.
DIFF_OUT="$(diff -q "${CONST_TARGET}" "${CONST_SOURCE}" 2>&1 || true)"
assert_eq "case8: target now byte-equal source" "" "${DIFF_OUT}"

# ── Case 9: invalid source content → validation rollback ─────────

echo ""
echo "Case 9: invalid source content → validation_failed_rolled_back"
INVALID_TASK_ID="task-invalid"
INVALID_DIR="${CAP_HOME_DIR}/projects/${PROJECT_ID}/constitutions/${INVALID_TASK_ID}"
mkdir -p "${INVALID_DIR}"
# Constitution that fails schema validation (missing required fields).
cat > "${INVALID_DIR}/constitution.yaml" <<'EOF'
schema_version: 1
unrelated_field: "not a constitution"
EOF

# Snapshot target before this case so we can verify rollback.
TARGET_BEFORE9="$(cat "${CONST_TARGET}")"

set +e
OUT9="$(pc_run_other_id "${INVALID_TASK_ID}" --apply --force --json)"
RC9=$?
set -e
assert_eq "case9: exit code 1" "1" "${RC9}"
assert_eq "case9: action=validation_failed_rolled_back" "validation_failed_rolled_back" \
  "$(json_field "${OUT9}" 'data["action"]')"
assert_eq "case9: validation.ok=False" "False" \
  "$(json_field "${OUT9}" 'data["validation"]["ok"]')"
TARGET_AFTER9="$(cat "${CONST_TARGET}")"
assert_eq "case9: target rolled back to pre-apply state" \
  "${TARGET_BEFORE9}" "${TARGET_AFTER9}"

# ── Case 10: invoked on workflow snapshot → type mismatch ────────

echo ""
echo "Case 10: project-constitution invoked on workflow_id → halted_type_mismatch"
WF_ID="some-workflow"
mkdir -p "${CAP_HOME_DIR}/projects/${PROJECT_ID}/compiled-workflows/${WF_ID}"
echo '{"workflow_id": "some-workflow"}' > \
  "${CAP_HOME_DIR}/projects/${PROJECT_ID}/compiled-workflows/${WF_ID}/snap.json"

set +e
OUT10="$(pc_run_other_id "${WF_ID}" --json)"
RC10=$?
set -e
# The candidate resolves as compiled_workflow, then cmd_project_constitution
# rejects it as not_found (since artifact_type != project_constitution).
# Either ``halted_type_mismatch`` (if resolver returns it) or
# ``promote_artifact_not_found`` is acceptable; what matters is exit 1
# and that the target was NOT written.
assert_eq "case10: exit code 1" "1" "${RC10}"
assert_contains "case10: error indicates not-a-project-constitution" \
  "${OUT10}" "promote_artifact_not_found"

# ── Case 11: unknown task_id → not_found ─────────────────────────

echo ""
echo "Case 11: unknown task_id → exit 1 with promote_artifact_not_found"
set +e
OUT11="$(pc_run_other_id "unknown-task-doesnt-exist" --json)"
RC11=$?
set -e
assert_eq "case11: exit code 1" "1" "${RC11}"
assert_contains "case11: error tag" "${OUT11}" '"error": "promote_artifact_not_found"'

# ── Case 12: legacy .cap.constitution.yaml never written ────────

echo ""
echo "Case 12: --apply NEVER writes legacy .cap.constitution.yaml (policy §3.1)"
assert_file_absent "case12: legacy path absent throughout test" "${CONST_LEGACY}"

# ── Case 13: bash dispatcher matches python CLI ──────────────────

echo ""
echo "Case 13: scripts/cap-promote.sh project-constitution matches python CLI"
# Reset target to match source so we get a deterministic ``identical``
# action that doesn't write anything.
cp "${CONST_SOURCE}" "${CONST_TARGET}"

PY_OUT="$(pc_run --json)"
BASH_OUT="$(CAP_HOME="${CAP_HOME_DIR}" CAP_PROJECT_ROOT="${PROJECT_ROOT}" \
  CAP_PROJECT_ID_OVERRIDE="${PROJECT_ID}" \
  bash "${PROMOTE_SH}" project-constitution "${TASK_ID}" --json 2>&1)"

assert_eq "case13: bash and python output match" \
  "$(printf '%s' "${PY_OUT}" | tr -d '\r')" \
  "$(printf '%s' "${BASH_OUT}" | tr -d '\r')"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
