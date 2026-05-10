#!/usr/bin/env bash
#
# test-cross-pipeline-named-artifacts.sh — Lock the v0.25.6 contract
# for named-artifact discovery across prior pipeline runs.
#
# Pre-fix: validate-inputs._try_resolve only consulted (a) the
# current run's runtime-state.json registry and (b) _INTRINSIC_ARTIFACTS.
# Workflow YAML files for project-implementation-pipeline and
# project-qa-pipeline declare individual spec artifact names like
# ``schema_ssot``, ``api_contract``, ``ba_spec``, ``ui_spec`` as
# required step inputs. None of those are in the current run
# (different pipeline, different run id) and none are intrinsic, so
# every downstream step blocked at validate-inputs even though the
# spec pipeline had successfully produced them on disk.
#
# Fix (v0.25.6): _try_resolve falls through to
# _resolve_artifact_from_prior_pipelines which scans every
# ${CAP_HOME}/projects/<project_id>/reports/workflows/*/run_*/
# runtime-state.json for the artifact name; latest validated
# producer wins (lexical max on the timestamped run id).
#
# Coverage:
#   Case 1: spec pipeline run has schema_ssot validated → backend
#           step inputs resolve schema_ssot via the prior-pipeline
#           lookup (current run's registry empty).
#   Case 2: latest run wins when multiple runs of the same pipeline
#           produced the artifact.
#   Case 3: artifact present but not validated (execution_state !=
#           validated) is skipped → still missing.
#   Case 4: no prior run at all → missing.
#   Case 5: cross-pipeline lookup respects project_id env (only the
#           configured project's runs are considered).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"

[ -f "${STEP_PY}" ] || { echo "FAIL: step_runtime.py missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-cross-pipeline-named-test.XXXXXX)"
SANDBOX="$(cd "${SANDBOX}" && pwd -P)"
trap 'rm -rf "${SANDBOX}"' EXIT
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

PROJECT_ID="bug10-named-artifact-proj"
PROJ_HOME="${CAP_HOME}/projects/${PROJECT_ID}"

build_plan_with_input() {
  local artifact_name="$1"
  cat <<JSON
{
  "phases": [
    {
      "phase": 1,
      "steps": [{
        "step_id": "consume_artifact",
        "phase": 1,
        "capability": "demo_capability",
        "needs": [],
        "inputs": ["${artifact_name}"],
        "outputs": []
      }]
    }
  ],
  "steps": [{
    "step_id": "consume_artifact",
    "phase": 1,
    "capability": "demo_capability",
    "needs": [],
    "inputs": ["${artifact_name}"],
    "outputs": []
  }]
}
JSON
}

empty_registry() {
  local registry_path="$1"
  echo '{"artifacts": {}, "steps": {}}' > "${registry_path}"
}

# ── Case 1: spec pipeline produced schema_ssot → backend step finds it ─
echo "Case 1: prior spec run's schema_ssot resolves for backend step"
SPEC_RUN_DIR="${PROJ_HOME}/reports/workflows/project-spec-pipeline/run_20260101000000_aaaaaaaa"
mkdir -p "${SPEC_RUN_DIR}"
SCHEMA_PATH="${SPEC_RUN_DIR}/10-dba_api.md"
echo "schema content" > "${SCHEMA_PATH}"
cat > "${SPEC_RUN_DIR}/runtime-state.json" <<EOF
{
  "artifacts": {
    "schema_ssot": {
      "artifact": "schema_ssot",
      "source_step": "dba_api",
      "path": "${SCHEMA_PATH}",
      "handoff_path": "${SPEC_RUN_DIR}/10-dba_api.handoff.md"
    },
    "api_contract": {
      "artifact": "api_contract",
      "source_step": "dba_api",
      "path": "${SCHEMA_PATH}",
      "handoff_path": ""
    }
  },
  "steps": {
    "dba_api": {"execution_state": "validated"}
  }
}
EOF

mkdir -p "${SANDBOX}/cwd1"
empty_registry "${SANDBOX}/cwd1/runtime-state.json"
case1_out="$(cd "${SANDBOX}/cwd1" && CAP_HOME="${CAP_HOME}" CAP_PROJECT_ID="${PROJECT_ID}" \
  "${PYTHON_BIN}" "${STEP_PY}" validate-inputs \
  "$(build_plan_with_input schema_ssot)" "consume_artifact" \
  "${SANDBOX}/cwd1/runtime-state.json")"
case1_ok="$(${PYTHON_BIN} -c '
import json, sys
print(json.loads(sys.argv[1]).get("ok"))
' "${case1_out}")"
case1_path="$(${PYTHON_BIN} -c '
import json, sys
data = json.loads(sys.argv[1])
match = [r for r in data.get("resolved", []) if r.get("artifact") == "schema_ssot"]
print(match[0].get("path") if match else "<not_resolved>")
' "${case1_out}")"
assert_eq "1a. ok=True (resolved from prior spec run)" "True" "${case1_ok}"
assert_contains "1b. resolved path points to spec pipeline run" \
  "project-spec-pipeline/run_20260101000000_aaaaaaaa/10-dba_api.md" "${case1_path}"

# ── Case 2: latest run wins ─────────────────────────────────────────
echo ""
echo "Case 2: latest run wins among multiple spec runs"
SPEC_RUN_DIR2="${PROJ_HOME}/reports/workflows/project-spec-pipeline/run_20260202000000_bbbbbbbb"
mkdir -p "${SPEC_RUN_DIR2}"
SCHEMA_PATH2="${SPEC_RUN_DIR2}/10-dba_api.md"
echo "newer schema content" > "${SCHEMA_PATH2}"
cat > "${SPEC_RUN_DIR2}/runtime-state.json" <<EOF
{
  "artifacts": {
    "schema_ssot": {
      "artifact": "schema_ssot",
      "source_step": "dba_api",
      "path": "${SCHEMA_PATH2}",
      "handoff_path": ""
    }
  },
  "steps": {
    "dba_api": {"execution_state": "validated"}
  }
}
EOF
case2_out="$(cd "${SANDBOX}/cwd1" && CAP_HOME="${CAP_HOME}" CAP_PROJECT_ID="${PROJECT_ID}" \
  "${PYTHON_BIN}" "${STEP_PY}" validate-inputs \
  "$(build_plan_with_input schema_ssot)" "consume_artifact" \
  "${SANDBOX}/cwd1/runtime-state.json")"
case2_path="$(${PYTHON_BIN} -c '
import json, sys
data = json.loads(sys.argv[1])
match = [r for r in data.get("resolved", []) if r.get("artifact") == "schema_ssot"]
print(match[0].get("path") if match else "<not_resolved>")
' "${case2_out}")"
assert_contains "2. latest run_20260202_bbbb wins" \
  "run_20260202000000_bbbbbbbb" "${case2_path}"

# ── Case 3: not-validated steps are skipped ─────────────────────────
echo ""
echo "Case 3: artifact whose source_step is not 'validated' is skipped"
SPEC_RUN_DIR3="${PROJ_HOME}/reports/workflows/project-spec-pipeline/run_20260303000000_cccccccc"
mkdir -p "${SPEC_RUN_DIR3}"
cat > "${SPEC_RUN_DIR3}/runtime-state.json" <<EOF
{
  "artifacts": {
    "ui_spec": {
      "artifact": "ui_spec",
      "source_step": "ui",
      "path": "${SPEC_RUN_DIR3}/ui.md",
      "handoff_path": ""
    }
  },
  "steps": {
    "ui": {"execution_state": "blocked"}
  }
}
EOF
case3_out="$(cd "${SANDBOX}/cwd1" && CAP_HOME="${CAP_HOME}" CAP_PROJECT_ID="${PROJECT_ID}" \
  "${PYTHON_BIN}" "${STEP_PY}" validate-inputs \
  "$(build_plan_with_input ui_spec)" "consume_artifact" \
  "${SANDBOX}/cwd1/runtime-state.json")"
case3_ok="$(${PYTHON_BIN} -c '
import json, sys
print(json.loads(sys.argv[1]).get("ok"))
' "${case3_out}")"
assert_eq "3. blocked source_step → ok=False" "False" "${case3_ok}"

# ── Case 4: no prior runs at all ────────────────────────────────────
echo ""
echo "Case 4: no prior runs → missing"
EMPTY_PROJECT="bug10-empty-project"
EMPTY_PROJ_HOME="${CAP_HOME}/projects/${EMPTY_PROJECT}"
mkdir -p "${EMPTY_PROJ_HOME}/reports"
mkdir -p "${SANDBOX}/cwd4"
empty_registry "${SANDBOX}/cwd4/runtime-state.json"
case4_out="$(cd "${SANDBOX}/cwd4" && CAP_HOME="${CAP_HOME}" CAP_PROJECT_ID="${EMPTY_PROJECT}" \
  "${PYTHON_BIN}" "${STEP_PY}" validate-inputs \
  "$(build_plan_with_input api_contract)" "consume_artifact" \
  "${SANDBOX}/cwd4/runtime-state.json")"
case4_ok="$(${PYTHON_BIN} -c '
import json, sys
print(json.loads(sys.argv[1]).get("ok"))
' "${case4_out}")"
case4_missing="$(${PYTHON_BIN} -c '
import json, sys
print(",".join(json.loads(sys.argv[1]).get("missing", [])))
' "${case4_out}")"
assert_eq "4a. ok=False when no prior runs" "False" "${case4_ok}"
assert_eq "4b. api_contract listed missing" "api_contract" "${case4_missing}"

# ── Case 5: project_id env scopes the lookup ────────────────────────
echo ""
echo "Case 5: prior pipeline lookup is project-scoped"
OTHER_PROJECT="bug10-other-project"
OTHER_HOME="${CAP_HOME}/projects/${OTHER_PROJECT}/reports/workflows/project-spec-pipeline/run_20260404000000_dddddddd"
mkdir -p "${OTHER_HOME}"
echo "other content" > "${OTHER_HOME}/api.md"
cat > "${OTHER_HOME}/runtime-state.json" <<EOF
{
  "artifacts": {
    "ba_spec": {
      "artifact": "ba_spec",
      "source_step": "ba",
      "path": "${OTHER_HOME}/api.md",
      "handoff_path": ""
    }
  },
  "steps": {"ba": {"execution_state": "validated"}}
}
EOF
# Query with EMPTY_PROJECT id — must NOT see the other project's artifact.
case5_out="$(cd "${SANDBOX}/cwd4" && CAP_HOME="${CAP_HOME}" CAP_PROJECT_ID="${EMPTY_PROJECT}" \
  "${PYTHON_BIN}" "${STEP_PY}" validate-inputs \
  "$(build_plan_with_input ba_spec)" "consume_artifact" \
  "${SANDBOX}/cwd4/runtime-state.json")"
case5_ok="$(${PYTHON_BIN} -c '
import json, sys
print(json.loads(sys.argv[1]).get("ok"))
' "${case5_out}")"
assert_eq "5. cross-project leak prevented (still missing)" "False" "${case5_ok}"

echo ""
total=$((pass_count + fail_count))
echo "cross-pipeline-named-artifacts: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
