#!/usr/bin/env bash
#
# test-cross-pipeline-bridges.sh — Lock the v0.25.4 contract for the
# three dogfood-discovered fixes:
#
#   bug #4 — persist-constitution.sh writes to CAP_PROJECT_ROOT
#   bug #5 — ProjectContextLoader prefers .cap/constitution.yaml
#            (namespaced) over the legacy .cap.constitution.yaml
#   bug #7 — _INTRINSIC_ARTIFACTS includes prior_spec_artifacts and
#            prior_implementation_artifacts; _try_resolve maps them
#            to the latest run dir's artifact-index.md under
#            ${CAP_HOME}/projects/<project_id>/reports/workflows/<pipeline>/
#
# All three were surfaced during the cap-test/component-next-dotnet-stt
# Component Repo dogfood baseline run after v0.25.3. Without them
# Phase D (project-implementation-pipeline) cannot start because step 1
# needs prior_spec_artifacts and the runtime has no resolver.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"

[ -f "${STEP_PY}" ] || { echo "FAIL: step_runtime.py missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-cross-pipeline-test.XXXXXX)"
SANDBOX="$(cd "${SANDBOX}" && pwd -P)"
trap 'rm -rf "${SANDBOX}"' EXIT

# Sandbox CAP_HOME so the test does not write to the real ~/.cap.
export CAP_HOME="${SANDBOX}/cap_home"

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
  case "${haystack}" in
    *"${needle}"*)
      echo "  PASS: ${desc}"
      pass_count=$((pass_count + 1)) ;;
    *)
      echo "  FAIL: ${desc}"
      echo "    expected substring: ${needle}"
      echo "    actual:             ${haystack}"
      fail_count=$((fail_count + 1)) ;;
  esac
}

# ── Bug #5: ProjectContextLoader namespace fallback ─────────────────
echo "Bug #5: ProjectContextLoader prefers .cap/constitution.yaml over legacy"
proj1="${SANDBOX}/proj1"
mkdir -p "${proj1}/.cap"
git -C "${proj1}" init -q
echo "project_id: bug5-proj-namespaced" > "${proj1}/.cap/project.yaml"
cat > "${proj1}/.cap/constitution.yaml" <<'EOF'
schema_version: 1
constitution_id: bug5-namespaced-constitution
project_id: bug5-proj-namespaced
EOF

case5_out="$(PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${proj1}" <<'PY'
import sys
from pathlib import Path
from engine.project_context_loader import ProjectContextLoader

base_dir = sys.argv[1]
loader = ProjectContextLoader(Path(base_dir))
ctx = loader.load()
print(f"_bootstrap={ctx['_bootstrap']}")
print(f"constitution_id={ctx['project_constitution'].get('constitution_id', '')}")
print(f"path={ctx['project_constitution_path']}")
PY
)"
assert_contains "5a. namespaced constitution loaded (bootstrap=False)" \
  "_bootstrap=False" "${case5_out}"
assert_contains "5b. constitution_id read from .cap/constitution.yaml" \
  "constitution_id=bug5-namespaced-constitution" "${case5_out}"
assert_contains "5c. constitution_path resolves to .cap/constitution.yaml" \
  ".cap/constitution.yaml" "${case5_out}"

# Negative leg: explicit constitution_file in project.yaml still wins
proj1b="${SANDBOX}/proj1b"
mkdir -p "${proj1b}/.cap"
git -C "${proj1b}" init -q
cat > "${proj1b}/.cap/project.yaml" <<EOF
project_id: bug5-explicit-ref
constitution_file: ${proj1b}/elsewhere.yaml
EOF
cat > "${proj1b}/elsewhere.yaml" <<'EOF'
schema_version: 1
constitution_id: explicit-elsewhere-constitution
EOF
case5d_out="$(PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${proj1b}" <<'PY'
import sys
from pathlib import Path
from engine.project_context_loader import ProjectContextLoader

ctx = ProjectContextLoader(Path(sys.argv[1])).load()
print(f"constitution_id={ctx['project_constitution'].get('constitution_id', '')}")
PY
)"
assert_contains "5d. explicit constitution_file in project.yaml still wins" \
  "explicit-elsewhere-constitution" "${case5d_out}"

# ── Bug #7a: prior_spec_artifacts resolves to latest run's artifact-index ─
echo ""
echo "Bug #7a: prior_spec_artifacts resolver"
proj7="${SANDBOX}/proj7"
mkdir -p "${proj7}/.cap"
git -C "${proj7}" init -q
echo "project_id: bug7-spec-bridge-proj" > "${proj7}/.cap/project.yaml"

# Layout two run dirs so we can also assert "latest wins"
RUNS_DIR="${CAP_HOME}/projects/bug7-spec-bridge-proj/reports/workflows/project-spec-pipeline"
mkdir -p "${RUNS_DIR}/run_20260101000000_aaaaaaaa"
mkdir -p "${RUNS_DIR}/run_20260202000000_bbbbbbbb"
echo "earlier index" > "${RUNS_DIR}/run_20260101000000_aaaaaaaa/artifact-index.md"
echo "latest index"  > "${RUNS_DIR}/run_20260202000000_bbbbbbbb/artifact-index.md"

# Build a synthetic plan that needs prior_spec_artifacts.
PLAN_PRIOR='{
  "phases": [
    {
      "phase": 1,
      "steps": [{
        "step_id": "draft_task_constitution",
        "phase": 1,
        "capability": "task_constitution_planning",
        "needs": [],
        "inputs": ["prior_spec_artifacts"],
        "outputs": ["task_constitution_draft"]
      }]
    }
  ],
  "steps": [{
    "step_id": "draft_task_constitution",
    "phase": 1,
    "capability": "task_constitution_planning",
    "needs": [],
    "inputs": ["prior_spec_artifacts"],
    "outputs": ["task_constitution_draft"]
  }]
}'
EMPTY_REGISTRY="${proj7}/runtime-state.json"
echo '{"artifacts": {}, "steps": {}}' > "${EMPTY_REGISTRY}"

case7a_out="$(cd "${proj7}" && CAP_HOME="${CAP_HOME}" "${PYTHON_BIN}" "${STEP_PY}" \
  validate-inputs "${PLAN_PRIOR}" "draft_task_constitution" "${EMPTY_REGISTRY}")"
case7a_ok="$(${PYTHON_BIN} -c '
import json, sys
print(json.loads(sys.argv[1]).get("ok"))
' "${case7a_out}")"
case7a_path="$(${PYTHON_BIN} -c '
import json, sys
data = json.loads(sys.argv[1])
match = [r for r in data.get("resolved", []) if r.get("artifact") == "prior_spec_artifacts"]
print(match[0].get("path") if match else "<not_resolved>")
' "${case7a_out}")"
case7a_source="$(${PYTHON_BIN} -c '
import json, sys
data = json.loads(sys.argv[1])
match = [r for r in data.get("resolved", []) if r.get("artifact") == "prior_spec_artifacts"]
print(match[0].get("source_step") if match else "<not_resolved>")
' "${case7a_out}")"
assert_eq "7a. ok=True when latest spec run exists" "True" "${case7a_ok}"
assert_contains "7b. resolved to LATEST run_20260202_bbbb (lexical max)" \
  "run_20260202000000_bbbbbbbb" "${case7a_path}"
assert_eq "7c. source_step tagged __prior_pipeline__" \
  "__prior_pipeline__" "${case7a_source}"

# Negative: no spec runs yet → missing
proj7b="${SANDBOX}/proj7b"
mkdir -p "${proj7b}/.cap"
git -C "${proj7b}" init -q
echo "project_id: bug7-spec-bridge-proj-noruns" > "${proj7b}/.cap/project.yaml"
case7d_out="$(cd "${proj7b}" && CAP_HOME="${CAP_HOME}" "${PYTHON_BIN}" "${STEP_PY}" \
  validate-inputs "${PLAN_PRIOR}" "draft_task_constitution" "${EMPTY_REGISTRY}")"
case7d_ok="$(${PYTHON_BIN} -c '
import json, sys
print(json.loads(sys.argv[1]).get("ok"))
' "${case7d_out}")"
case7d_missing="$(${PYTHON_BIN} -c '
import json, sys
print(",".join(json.loads(sys.argv[1]).get("missing", [])))
' "${case7d_out}")"
assert_eq "7d. ok=False when no prior spec run exists" "False" "${case7d_ok}"
assert_eq "7e. missing list includes prior_spec_artifacts" \
  "prior_spec_artifacts" "${case7d_missing}"

# ── Bug #7b: prior_implementation_artifacts mirrors the same shape ──
echo ""
echo "Bug #7b: prior_implementation_artifacts resolver (mirror of 7a)"
IMPL_RUNS="${CAP_HOME}/projects/bug7-spec-bridge-proj/reports/workflows/project-implementation-pipeline"
mkdir -p "${IMPL_RUNS}/run_20260303000000_cccccccc"
echo "impl index" > "${IMPL_RUNS}/run_20260303000000_cccccccc/artifact-index.md"

PLAN_PRIOR_IMPL='{
  "phases": [
    {
      "phase": 1,
      "steps": [{
        "step_id": "draft_task_constitution",
        "phase": 1,
        "capability": "task_constitution_planning",
        "needs": [],
        "inputs": ["prior_implementation_artifacts"],
        "outputs": ["task_constitution_draft"]
      }]
    }
  ],
  "steps": [{
    "step_id": "draft_task_constitution",
    "phase": 1,
    "capability": "task_constitution_planning",
    "needs": [],
    "inputs": ["prior_implementation_artifacts"],
    "outputs": ["task_constitution_draft"]
  }]
}'
case7f_out="$(cd "${proj7}" && CAP_HOME="${CAP_HOME}" "${PYTHON_BIN}" "${STEP_PY}" \
  validate-inputs "${PLAN_PRIOR_IMPL}" "draft_task_constitution" "${EMPTY_REGISTRY}")"
case7f_path="$(${PYTHON_BIN} -c '
import json, sys
data = json.loads(sys.argv[1])
match = [r for r in data.get("resolved", []) if r.get("artifact") == "prior_implementation_artifacts"]
print(match[0].get("path") if match else "<not_resolved>")
' "${case7f_out}")"
assert_contains "7f. prior_implementation_artifacts resolves under project-implementation-pipeline" \
  "run_20260303000000_cccccccc" "${case7f_path}"

# ── Bug #4: persist-constitution.sh honors CAP_PROJECT_ROOT ─────────
echo ""
echo "Bug #4: persist-constitution.sh writes to CAP_PROJECT_ROOT"
# Build a fake project_root distinct from CAP_ROOT, plus a draft
# constitution artifact with the required fence + JSON. Drive the
# script through CAP_WORKFLOW_INPUT_CONTEXT (which is what
# cap-workflow-exec.sh threads in) and verify TARGET_PROJECT_ROOT
# tracks CAP_PROJECT_ROOT.
proj4="${SANDBOX}/user-working-repo"
fake_install="${SANDBOX}/cap-install"
mkdir -p "${proj4}/.cap" "${fake_install}/.cap"
git -C "${proj4}" init -q
echo "project_id: bug4-persist-target" > "${proj4}/.cap/project.yaml"

# Minimal cap install layout so persist-constitution.sh's helper paths exist.
cp -r "${REPO_ROOT}/scripts" "${fake_install}/scripts"
mkdir -p "${fake_install}/schemas"
cp "${REPO_ROOT}/schemas/project-constitution.schema.yaml" "${fake_install}/schemas/" 2>/dev/null || true

# Draft markdown with constitution JSON between the explicit fence.
draft="${SANDBOX}/draft.md"
cat > "${draft}" <<'EOF'
# draft

<<<CONSTITUTION_JSON_BEGIN>>>
{
  "schema_version": 1,
  "constitution_id": "bug4-persist-target-constitution",
  "project_id": "bug4-persist-target",
  "name": "Bug 4 Persist Target Test",
  "summary": "fixture",
  "project_goal": "verify persist writes to CAP_PROJECT_ROOT",
  "constraints": ["fixture-constraint"],
  "stop_conditions": ["fixture-stop"],
  "binding_policy": {"allowed_capabilities": ["bootstrap_platform_defaults"]},
  "workflow_policy": {"enforce_allowed_source_roots": false}
}
<<<CONSTITUTION_JSON_END>>>
EOF

# Validation report stub so persist doesn't refuse on upstream failure.
val_report="${SANDBOX}/val.md"
echo "condition: ok" > "${val_report}"

# CAP_WORKFLOW_INPUT_CONTEXT drives the script's artifact lookup.
input_ctx="$(cat <<EOF
- artifact=project_constitution path=${draft}
- artifact=project_constitution_json path=${draft}
- artifact=constitution_validation_report path=${val_report}
EOF
)"

# Run persist with explicit CAP_PROJECT_ROOT.
case4_out="$(
  CAP_ROOT="${fake_install}" \
  CAP_PROJECT_ROOT="${proj4}" \
  CAP_PROJECT_ID="bug4-persist-target" \
  CAP_HOME="${CAP_HOME}" \
  CAP_WORKFLOW_STEP_ID="persist_constitution" \
  CAP_WORKFLOW_INPUT_CONTEXT="${input_ctx}" \
  CAP_WORKFLOW_OUTPUT_PATH="${SANDBOX}/persist.md" \
  CAP_WORKFLOW_ARTIFACT_INDEX="${SANDBOX}/artifact-index.md" \
  CAP_WORKFLOW_CONTRACT_CONTEXT="" \
  CAP_WORKFLOW_USER_PROMPT="" \
  bash "${REPO_ROOT}/scripts/workflows/persist-constitution.sh" 2>&1
)"
case4_target="$(echo "${case4_out}" | grep -oE 'repo_target: \S+' | head -1 | awk '{print $2}')"
case4_proot="$(echo "${case4_out}" | grep -oE '^project_root: \S+' | head -1 | awk '{print $2}')"

assert_contains "4a. repo_target is under CAP_PROJECT_ROOT, not CAP_ROOT scaffold" \
  "${proj4}/.cap/constitution.yaml" "${case4_target}"
assert_eq "4b. project_root reports CAP_PROJECT_ROOT verbatim" \
  "${proj4}" "${case4_proot}"

# Check no pollution at the wrong path (where bug #4 would have written).
WRONG_TARGET="${SANDBOX}/bug4-persist-target/.cap/constitution.yaml"
[ -f "${WRONG_TARGET}" ] && wrong_exists="yes" || wrong_exists="no"
assert_eq "4c. legacy scaffold path NOT written (no home pollution)" \
  "no" "${wrong_exists}"

# Confirm constitution actually landed at the correct path.
[ -f "${proj4}/.cap/constitution.yaml" ] && correct_exists="yes" || correct_exists="no"
assert_eq "4d. correct CAP_PROJECT_ROOT path written" \
  "yes" "${correct_exists}"

echo ""
total=$((pass_count + fail_count))
echo "cross-pipeline-bridges: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
