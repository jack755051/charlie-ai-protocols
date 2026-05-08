#!/usr/bin/env bash
#
# test-promote-candidate-producer.sh — P10 #2.2 focused test.
#
# Exercises engine/promote_candidate_producer.py:produce_candidates and
# its wire-in via engine/result_report_builder.build_workflow_result.
# Reference: policies/runtime-promote.md §5.
#
# Cases:
#   1. project_constitution candidate emitted when task_id + on-disk
#      snapshot both exist; target_path = <project_root>/.cap/constitution.yaml.
#   2. compiled_workflow candidate emitted when final_state=completed
#      AND <cap_home>/.../compiled-workflows/<workflow_id>/ has files;
#      target_path = <project_root>/.cap/workflows/<workflow_id>.yaml.
#   3. final_state != completed → compiled_workflow candidate NOT
#      emitted (failed run safety, policy §5.3).
#   4. task_id missing → project_constitution NOT emitted.
#   5. project_id == "unknown" → producer returns []; no crash.
#   6. Both types emit together; order is project_constitution first.
#   7. Each emitted candidate validates against the schema's strict
#      required field set (P10 #2.1 contract).
#   8. build_workflow_result wire-in: result["promote_candidates"] is
#      no longer hard-coded []; reflects producer output.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
SCHEMA_PATH="${REPO_ROOT}/schemas/workflow-result.schema.yaml"
STEP_RUNTIME="${REPO_ROOT}/engine/step_runtime.py"

[ -f "${REPO_ROOT}/engine/promote_candidate_producer.py" ] || {
  echo "FAIL: promote_candidate_producer.py missing"; exit 1;
}
[ -f "${SCHEMA_PATH}" ]  || { echo "FAIL: workflow-result.schema.yaml missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-promote-candidate-producer-test.XXXXXX)"
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
    echo "    haystack head: $(printf '%s' "${haystack}" | head -c 200)"
    fail_count=$((fail_count + 1))
  fi
}

# Sandbox layout (re-used across cases):
#   ${SBX}/proj/                          (project_root)
#   ${SBX}/cap_home/projects/<id>/constitutions/<task_id>/constitution.yaml
#   ${SBX}/cap_home/projects/<id>/compiled-workflows/<wf>/<timestamp>.json
PROJECT_ROOT="${SANDBOX}/proj"
CAP_HOME_DIR="${SANDBOX}/cap_home"
PROJECT_ID="cap-promote-producer-test"
mkdir -p "${PROJECT_ROOT}" "${CAP_HOME_DIR}/projects/${PROJECT_ID}"

# produce_via_python <result_json>
# Run produce_candidates with the sandbox roots and dump JSON of the result.
produce_via_python() {
  local result_json="$1"
  PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${result_json}" "${PROJECT_ROOT}" "${CAP_HOME_DIR}" <<'PY'
import json, sys
from pathlib import Path
from engine.promote_candidate_producer import produce_candidates

result_json, project_root, cap_home = sys.argv[1:4]
result = json.loads(result_json)
candidates = produce_candidates(result, project_root=Path(project_root), cap_home=Path(cap_home))
print(json.dumps(candidates, ensure_ascii=False))
PY
}

# json_field <json_str> <expr>
json_field() {
  local json_str="$1" expr="$2"
  "${PYTHON_BIN}" - "${json_str}" "${expr}" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
print(eval(sys.argv[2], {"data": data}))
PY
}

# ── Case 1: project_constitution emitted ─────────────────────────────

echo "Case 1: project_constitution candidate emitted from task_id snapshot"
TASK_ID="task-alpha"
mkdir -p "${CAP_HOME_DIR}/projects/${PROJECT_ID}/constitutions/${TASK_ID}"
cat > "${CAP_HOME_DIR}/projects/${PROJECT_ID}/constitutions/${TASK_ID}/constitution.yaml" <<'EOF'
schema_version: 1
constitution_id: focused-test
EOF

RESULT1='{"project_id": "'"${PROJECT_ID}"'", "task_id": "'"${TASK_ID}"'", "workflow_id": "wf", "final_state": "running"}'
OUT1="$(produce_via_python "${RESULT1}")"
assert_eq "case1: candidate count = 1"             "1" \
  "$(json_field "${OUT1}" 'len(data)')"
assert_eq "case1: artifact_type = project_constitution" "project_constitution" \
  "$(json_field "${OUT1}" 'data[0]["artifact_type"]')"
assert_eq "case1: source_path points at constitution snapshot" \
  "${CAP_HOME_DIR}/projects/${PROJECT_ID}/constitutions/${TASK_ID}/constitution.yaml" \
  "$(json_field "${OUT1}" 'data[0]["source_path"]')"
assert_eq "case1: target_path = <project_root>/.cap/constitution.yaml" \
  "${PROJECT_ROOT}/.cap/constitution.yaml" \
  "$(json_field "${OUT1}" 'data[0]["target_path"]')"
assert_eq "case1: validation_schema points at project-constitution.schema.yaml" \
  "schemas/project-constitution.schema.yaml" \
  "$(json_field "${OUT1}" 'data[0]["validation_schema"]')"
assert_eq "case1: source_revision = task_id" "${TASK_ID}" \
  "$(json_field "${OUT1}" 'data[0]["source_revision"]')"

# ── Case 2: compiled_workflow emitted on completed run ───────────────

echo ""
echo "Case 2: compiled_workflow candidate emitted on completed run"
WF_ID="wf-completed"
WF_DIR="${CAP_HOME_DIR}/projects/${PROJECT_ID}/compiled-workflows/${WF_ID}"
mkdir -p "${WF_DIR}"
echo '{"workflow_id": "'"${WF_ID}"'", "version": 1}' > "${WF_DIR}/20260506-122014.json"

RESULT2='{"project_id": "'"${PROJECT_ID}"'", "task_id": null, "workflow_id": "'"${WF_ID}"'", "final_state": "completed"}'
OUT2="$(produce_via_python "${RESULT2}")"
assert_eq "case2: candidate count = 1" "1" \
  "$(json_field "${OUT2}" 'len(data)')"
assert_eq "case2: artifact_type = compiled_workflow" "compiled_workflow" \
  "$(json_field "${OUT2}" 'data[0]["artifact_type"]')"
assert_eq "case2: target_path = <project_root>/.cap/workflows/<wf>.yaml" \
  "${PROJECT_ROOT}/.cap/workflows/${WF_ID}.yaml" \
  "$(json_field "${OUT2}" 'data[0]["target_path"]')"
assert_eq "case2: source_revision = file stem" "20260506-122014" \
  "$(json_field "${OUT2}" 'data[0]["source_revision"]')"

# ── Case 3: failed run → no compiled_workflow candidate ──────────────

echo ""
echo "Case 3: final_state=failed → compiled_workflow NOT emitted"
RESULT3='{"project_id": "'"${PROJECT_ID}"'", "task_id": null, "workflow_id": "'"${WF_ID}"'", "final_state": "failed"}'
OUT3="$(produce_via_python "${RESULT3}")"
assert_eq "case3: candidate count = 0" "0" \
  "$(json_field "${OUT3}" 'len(data)')"

# Same logic should also no-emit for "blocked" / "cancelled" / "running".
for state in blocked cancelled running; do
  result="{\"project_id\": \"${PROJECT_ID}\", \"task_id\": null, \"workflow_id\": \"${WF_ID}\", \"final_state\": \"${state}\"}"
  out="$(produce_via_python "${result}")"
  assert_eq "case3: final_state=${state} → no candidate" "0" \
    "$(json_field "${out}" 'len(data)')"
done

# ── Case 4: task_id missing → no project_constitution candidate ─────

echo ""
echo "Case 4: task_id missing → no project_constitution candidate"
RESULT4='{"project_id": "'"${PROJECT_ID}"'", "task_id": null, "workflow_id": "wf-other", "final_state": "running"}'
OUT4="$(produce_via_python "${RESULT4}")"
assert_eq "case4: candidate count = 0" "0" \
  "$(json_field "${OUT4}" 'len(data)')"

# ── Case 5: project_id = "unknown" → empty list, no crash ───────────

echo ""
echo 'Case 5: project_id = "unknown" → producer returns [] (no crash)'
RESULT5='{"project_id": "unknown", "task_id": "'"${TASK_ID}"'", "workflow_id": "'"${WF_ID}"'", "final_state": "completed"}'
OUT5="$(produce_via_python "${RESULT5}")"
assert_eq "case5: candidate count = 0" "0" \
  "$(json_field "${OUT5}" 'len(data)')"

# Same with project_id missing entirely.
RESULT5B='{"task_id": "'"${TASK_ID}"'", "workflow_id": "'"${WF_ID}"'", "final_state": "completed"}'
OUT5B="$(produce_via_python "${RESULT5B}")"
assert_eq "case5b: project_id missing → []" "0" \
  "$(json_field "${OUT5B}" 'len(data)')"

# ── Case 6: both types emitted together; order project first ────────

echo ""
echo "Case 6: both project_constitution and compiled_workflow → order project first"
RESULT6='{"project_id": "'"${PROJECT_ID}"'", "task_id": "'"${TASK_ID}"'", "workflow_id": "'"${WF_ID}"'", "final_state": "completed"}'
OUT6="$(produce_via_python "${RESULT6}")"
assert_eq "case6: candidate count = 2" "2" \
  "$(json_field "${OUT6}" 'len(data)')"
assert_eq "case6: index 0 type = project_constitution" "project_constitution" \
  "$(json_field "${OUT6}" 'data[0]["artifact_type"]')"
assert_eq "case6: index 1 type = compiled_workflow" "compiled_workflow" \
  "$(json_field "${OUT6}" 'data[1]["artifact_type"]')"

# ── Case 7: emitted candidates pass schema validation ───────────────

echo ""
echo "Case 7: emitted candidates pass workflow-result schema validation"
# Wrap candidates in a minimal valid workflow-result envelope so we can
# run it through the existing validator without forking a new fixture.
SCHEMA_FIXTURE="${SANDBOX}/result.json"
ENVELOPE_OUT="$(PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${OUT6}" "${SCHEMA_FIXTURE}" <<'PY'
import json, sys
candidates = json.loads(sys.argv[1])
envelope = {
    "schema_version": 1,
    "run_id": "run-test", "workflow_id": "wf-completed", "project_id": "cap-promote-producer-test",
    "started_at": "2026-05-06T00:00:00+08:00",
    "final_state": "completed",
    "summary": {"total_steps": 0, "completed": 0, "failed": 0, "skipped": 0, "blocked": 0},
    "steps": [], "sessions": [], "artifacts": [],
    "promote_candidates": candidates,
}
import pathlib
pathlib.Path(sys.argv[2]).write_text(json.dumps(envelope), encoding="utf-8")
print("wrote_fixture")
PY
)"
SCHEMA_OUT="$("${PYTHON_BIN}" "${STEP_RUNTIME}" validate-jsonschema "${SCHEMA_FIXTURE}" "${SCHEMA_PATH}" 2>&1)"
SCHEMA_RC=$?
if [ "${SCHEMA_RC}" -eq 0 ] && grep -q '"ok": true' <<<"${SCHEMA_OUT}"; then
  echo "  PASS: case7: emitted candidates validate against the P10 #2.1 schema contract"
  pass_count=$((pass_count + 1))
else
  echo "  FAIL: case7: schema validation failed"
  echo "    rc:  ${SCHEMA_RC}"
  echo "    out: ${SCHEMA_OUT}"
  fail_count=$((fail_count + 1))
fi

# ── Case 8: build_workflow_result wire-in ──────────────────────────

echo ""
echo "Case 8: build_workflow_result threads producer output into result.promote_candidates"
RUN_DIR="${CAP_HOME_DIR}/projects/${PROJECT_ID}/reports/workflows/${WF_ID}/run-test"
mkdir -p "${RUN_DIR}"
cat > "${RUN_DIR}/runtime-state.json" <<'EOF'
{"artifacts": {}, "steps": {}}
EOF
cat > "${RUN_DIR}/agent-sessions.json" <<EOF
{"version": 1, "run_id": "run-test", "workflow_id": "${WF_ID}", "sessions": []}
EOF
cat > "${RUN_DIR}/run-summary.md" <<EOF
# Workflow Run Summary

- workflow_id: ${WF_ID}
- run_id: run-test
- started_at: 2026-05-06 00:00:00

## Finished
- finished_at: 2026-05-06 00:00:01
- total_duration_seconds: 1
- completed: 0
- failed: 0
- skipped: 0
EOF

# status_file with task_id link so build_workflow_result picks it up
# (P7 future-compatible linkage path).
STATUS_FILE="${SANDBOX}/workflow-runs.json"
cat > "${STATUS_FILE}" <<EOF
{"version": 2, "workflows": {}, "runs": [{"run_id": "run-test", "workflow_id": "${WF_ID}", "task_id": "${TASK_ID}"}]}
EOF

BUILDER_OUT="$(PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${RUN_DIR}" "${CAP_HOME_DIR}" "${STATUS_FILE}" "${PROJECT_ROOT}" <<'PY'
import json, sys
from engine.result_report_builder import build_workflow_result

run_dir, cap_home, status_file, project_root = sys.argv[1:5]
result = build_workflow_result(
    run_dir,
    cap_home=cap_home,
    status_file=status_file,
    project_root=project_root,
)
print(json.dumps(result.get("promote_candidates", []), ensure_ascii=False))
PY
)"
assert_eq "case8: builder emits 2 candidates (project + workflow)" "2" \
  "$(json_field "${BUILDER_OUT}" 'len(data)')"
assert_contains "case8: builder output includes project_constitution" \
  "${BUILDER_OUT}" '"artifact_type": "project_constitution"'
assert_contains "case8: builder output includes compiled_workflow" \
  "${BUILDER_OUT}" '"artifact_type": "compiled_workflow"'

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
