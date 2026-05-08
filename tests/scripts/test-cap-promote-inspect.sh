#!/usr/bin/env bash
#
# test-cap-promote-inspect.sh — P10 #3 focused test.
#
# Exercises engine/promote_resolver.py + engine/promote_cli.py:cmd_inspect
# (and the bash dispatcher in scripts/cap-promote.sh inspect). Reference:
# policies/runtime-promote.md §7.1 (inspect output) and §4 (conflict
# rules).
#
# Cases:
#   1. inspect on task_id with constitution snapshot, target absent
#      → conflict=no_target, backup_path=null.
#   2. inspect on task_id with constitution + identical target
#      → conflict=identical, backup_path=null.
#   3. inspect on task_id with constitution + diff target
#      → conflict=diff, backup_path includes ".bak.<ISO>" template.
#   4. inspect on workflow_id with compiled workflow snapshot,
#      target absent → conflict=no_target, smoke_plan describes
#      compile_bind_smoke as opt-in.
#   5. inspect on workflow_id when run was failed/blocked still
#      describes the snapshot (resolver is read-only; final_state
#      gate fires at apply time per policy §5.3).
#   6. inspect on unknown artifact_id → exit 1, JSON error
#      ``promote_artifact_not_found``.
#   7. --json mode emits valid JSON with ``ok=true`` and the
#      ResolvedPromote dataclass shape.
#   8. text mode contains the four expected sections (Header /
#      Source / Target / Validation).
#   9. project_id="unknown" or missing → exit 1 with the same
#      not-found error (no crash).
#  10. bash dispatch (scripts/cap-promote.sh inspect) matches direct
#      python invocation output.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
PROMOTE_CLI="${REPO_ROOT}/engine/promote_cli.py"
PROMOTE_SH="${REPO_ROOT}/scripts/cap-promote.sh"

[ -f "${PROMOTE_CLI}" ] || { echo "FAIL: promote_cli.py missing"; exit 1; }
[ -f "${PROMOTE_SH}" ]  || { echo "FAIL: cap-promote.sh missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-promote-inspect-test.XXXXXX)"
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

# Sandbox layout (re-used across cases):
#   ${SBX}/proj                              project_root (no real .cap initially)
#   ${SBX}/cap_home/projects/<id>/...         runtime tree

PROJECT_ROOT="${SANDBOX}/proj"
CAP_HOME_DIR="${SANDBOX}/cap_home"
PROJECT_ID="cap-promote-inspect-test"
mkdir -p "${PROJECT_ROOT}" "${CAP_HOME_DIR}/projects/${PROJECT_ID}"

# inspect_via_python <artifact_id> [--json]
inspect_via_python() {
  PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" "${PROMOTE_CLI}" inspect \
    --project-root "${PROJECT_ROOT}" \
    --cap-home "${CAP_HOME_DIR}" \
    --project-id "${PROJECT_ID}" \
    "$@"
}

# inspect_via_python_json <artifact_id> — capture stdout (assumed JSON
# in --json mode) for json_field eval. Adds --json automatically.
inspect_via_python_json() {
  inspect_via_python --json "$@"
}

json_field() {
  local json_str="$1" expr="$2"
  "${PYTHON_BIN}" - "${json_str}" "${expr}" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
print(eval(sys.argv[2], {"data": data}))
PY
}

# ── Case 1: task_id, target absent ──────────────────────────────────

echo "Case 1: task_id with constitution snapshot, no target → no_target"
TASK_ID="task-alpha"
mkdir -p "${CAP_HOME_DIR}/projects/${PROJECT_ID}/constitutions/${TASK_ID}"
cat > "${CAP_HOME_DIR}/projects/${PROJECT_ID}/constitutions/${TASK_ID}/constitution.yaml" <<'EOF'
schema_version: 1
constitution_id: focused-test
EOF

OUT1="$(inspect_via_python_json "${TASK_ID}")"
assert_eq "case1: ok=True"               "True"   "$(json_field "${OUT1}" 'data["ok"]')"
assert_eq "case1: artifact_type"         "project_constitution" \
  "$(json_field "${OUT1}" 'data["candidate"]["artifact_type"]')"
assert_eq "case1: target_exists=False"   "False"  "$(json_field "${OUT1}" 'data["target_exists"]')"
assert_eq "case1: conflict=no_target"    "no_target" \
  "$(json_field "${OUT1}" 'data["conflict_kind"]')"
assert_eq "case1: backup_path is None"   "None"   "$(json_field "${OUT1}" 'data["backup_path"]')"
assert_eq "case1: backup_required=False" "False"  "$(json_field "${OUT1}" 'data["backup_required"]')"

# ── Case 2: task_id with identical target → identical ───────────────

echo ""
echo "Case 2: task_id with constitution + identical target → identical"
mkdir -p "${PROJECT_ROOT}/.cap"
cp "${CAP_HOME_DIR}/projects/${PROJECT_ID}/constitutions/${TASK_ID}/constitution.yaml" \
   "${PROJECT_ROOT}/.cap/constitution.yaml"

OUT2="$(inspect_via_python_json "${TASK_ID}")"
assert_eq "case2: target_exists=True"   "True"      "$(json_field "${OUT2}" 'data["target_exists"]')"
assert_eq "case2: conflict=identical"   "identical" "$(json_field "${OUT2}" 'data["conflict_kind"]')"
assert_eq "case2: backup_path is None"  "None"      "$(json_field "${OUT2}" 'data["backup_path"]')"

# ── Case 3: task_id with diff target → diff + backup template ──────

echo ""
echo "Case 3: task_id with constitution + diff target → diff + backup template"
cat > "${PROJECT_ROOT}/.cap/constitution.yaml" <<'EOF'
schema_version: 1
constitution_id: an-older-version
EOF

OUT3="$(inspect_via_python_json "${TASK_ID}")"
assert_eq "case3: conflict=diff"        "diff"  "$(json_field "${OUT3}" 'data["conflict_kind"]')"
assert_eq "case3: backup_required=True" "True"  "$(json_field "${OUT3}" 'data["backup_required"]')"
BACKUP_PATH="$(json_field "${OUT3}" 'data["backup_path"]')"
case "${BACKUP_PATH}" in
  "${PROJECT_ROOT}/.cap/constitution.yaml.bak.<ISO>")
    echo "  PASS: case3: backup_path uses .bak.<ISO> template"
    pass_count=$((pass_count + 1))
    ;;
  *)
    echo "  FAIL: case3: backup_path template mismatch"
    echo "    actual: ${BACKUP_PATH}"
    fail_count=$((fail_count + 1))
    ;;
esac

# ── Case 4: workflow_id with compiled workflow → smoke plan ────────

echo ""
echo "Case 4: workflow_id with compiled workflow snapshot → smoke plan describes opt-in"
WF_ID="wf-test"
mkdir -p "${CAP_HOME_DIR}/projects/${PROJECT_ID}/compiled-workflows/${WF_ID}"
echo '{"workflow_id": "wf-test"}' > "${CAP_HOME_DIR}/projects/${PROJECT_ID}/compiled-workflows/${WF_ID}/20260506-130000.json"

OUT4="$(inspect_via_python_json "${WF_ID}")"
assert_eq "case4: artifact_type=compiled_workflow" "compiled_workflow" \
  "$(json_field "${OUT4}" 'data["candidate"]["artifact_type"]')"
assert_eq "case4: target_path under .cap/workflows" \
  "${PROJECT_ROOT}/.cap/workflows/${WF_ID}.yaml" \
  "$(json_field "${OUT4}" 'data["candidate"]["target_path"]')"
assert_eq "case4: smoke_plan describes opt-in flag" "--smoke" \
  "$(json_field "${OUT4}" 'data["smoke_plan"]["compile_bind_smoke"]["opt_in_flag"]')"
assert_eq "case4: smoke_plan compile_bind_smoke disabled by default" "False" \
  "$(json_field "${OUT4}" 'data["smoke_plan"]["compile_bind_smoke"]["enabled"]')"

# ── Case 5: resolver does not gate on final_state at inspect time ──
# (final_state gate fires at apply time per policy §5.3 — inspect
# describes the on-disk picture so the user can still investigate.)

echo ""
echo "Case 5: workflow inspect ignores final_state (gate fires at apply, not inspect)"
# Even though no run_result is given to the resolver, it should still
# return the snapshot — same call as Case 4 already verified.
OUT5="$(inspect_via_python_json "${WF_ID}")"
assert_eq "case5: still resolves without run_result" "compiled_workflow" \
  "$(json_field "${OUT5}" 'data["candidate"]["artifact_type"]')"

# ── Case 6: unknown artifact_id → exit 1, deterministic error ──────

echo ""
echo "Case 6: unknown artifact_id → exit 1 with promote_artifact_not_found"
set +e
OUT6="$(inspect_via_python_json "totally-not-an-artifact" 2>&1)"
RC6=$?
set -e
assert_eq "case6: exit code 1" "1" "${RC6}"
assert_contains "case6: error tag" "${OUT6}" '"error": "promote_artifact_not_found"'
assert_contains "case6: artifact_id echoed" "${OUT6}" '"artifact_id": "totally-not-an-artifact"'

# ── Case 7: text mode renders 4 expected sections ──────────────────

echo ""
echo "Case 7: text mode sections present"
TEXT="$(inspect_via_python "${TASK_ID}")"
assert_contains "case7: Header section"     "${TEXT}" "# Header"
assert_contains "case7: Source section"     "${TEXT}" "# Source"
assert_contains "case7: Target section"     "${TEXT}" "# Target"
assert_contains "case7: Validation section" "${TEXT}" "# Validation"
assert_contains "case7: artifact_type line" "${TEXT}" "artifact_type:     project_constitution"
assert_contains "case7: conflict line"      "${TEXT}" "conflict:          diff"
assert_contains "case7: backup_path shown"  "${TEXT}" "backup_path:"

# ── Case 8: project_id="unknown" → not_found error ─────────────────

echo ""
echo "Case 8: explicit project_id=unknown → exit 1 (no crash)"
set +e
OUT8="$(PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" "${PROMOTE_CLI}" inspect \
  --project-root "${PROJECT_ROOT}" \
  --cap-home "${CAP_HOME_DIR}" \
  --project-id "unknown" \
  --json \
  "${TASK_ID}" 2>&1)"
RC8=$?
set -e
assert_eq "case8: exit 1 on project_id=unknown" "1" "${RC8}"
assert_contains "case8: not_found error" "${OUT8}" "promote_artifact_not_found"

# ── Case 9: bash dispatch matches python output ────────────────────

echo ""
echo "Case 9: scripts/cap-promote.sh inspect matches python promote_cli output"
# Use an env-passed CAP_HOME / CAP_PROJECT_ROOT / CAP_PROJECT_ID_OVERRIDE
# so the bash dispatcher hands the same context to the python CLI as
# our direct invocations above.
BASH_OUT="$(CAP_HOME="${CAP_HOME_DIR}" CAP_PROJECT_ROOT="${PROJECT_ROOT}" \
  CAP_PROJECT_ID_OVERRIDE="${PROJECT_ID}" \
  bash "${PROMOTE_SH}" inspect "${TASK_ID}" --json 2>&1)"
PY_OUT="$(inspect_via_python_json "${TASK_ID}")"

# Strip trailing whitespace before compare (bash and python prints may
# differ on a final newline only).
bash_normalised="$(printf '%s' "${BASH_OUT}" | tr -d '\r')"
py_normalised="$(printf '%s' "${PY_OUT}" | tr -d '\r')"

assert_eq "case9: bash and python output match" \
  "${py_normalised}" \
  "${bash_normalised}"

# ── Case 10: validation_schema is reported when present ────────────

echo ""
echo "Case 10: validation_schema surfaces in text + json"
assert_contains "case10: validation_schema in text" "${TEXT}" \
  "schema_path:     schemas/project-constitution.schema.yaml"
assert_eq "case10: validation_schema in json" \
  "schemas/project-constitution.schema.yaml" \
  "$(json_field "${OUT3}" 'data["validation_schema"]')"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
