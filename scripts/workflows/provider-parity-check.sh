#!/usr/bin/env bash
#
# provider-parity-check.sh — Artifact-only verifier for the
# `docs/cap/PROVIDER-PARITY-E2E.md` checklist sections 4.1–4.6.
#
# This script does NOT call any AI; it only inspects on-disk
# artifacts produced by a real `cap workflow run` so the same
# checklist can be applied to Claude and Codex outputs identically.
#
# Required inputs:
#   --run-dir <path>      Run output directory (e.g.
#                         ~/.cap/projects/<id>/reports/workflows/<wf>/run_<ts>)
#   --task-id <id>        Task constitution id (used to locate
#                         ~/.cap/projects/<id>/constitutions/<task_id>.json)
#   --project-id <id>     Project id (used to locate cap home subtree)
#
# Optional inputs:
#   --workflow <id>       Workflow id; defaults to the parent dir name of
#                         <run-dir> (e.g. project-spec-pipeline). Determines
#                         which AI steps to check tickets for.
#   --cap-home <path>     Override CAP_HOME; defaults to ~/.cap
#
# Exit codes:
#   0  all required artifacts present and Type B passes strict field check
#   1  at least one missing artifact or strict-schema failure (stderr lists)
#   2  bad invocation (missing required flag)

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
SCHEMA_HANDOFF="${REPO_ROOT}/schemas/handoff-ticket.schema.yaml"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"

RUN_DIR=""
TASK_ID=""
PROJECT_ID=""
WORKFLOW_ID=""
CAP_HOME_OVERRIDE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-dir)    RUN_DIR="$2"; shift 2 ;;
    --task-id)    TASK_ID="$2"; shift 2 ;;
    --project-id) PROJECT_ID="$2"; shift 2 ;;
    --workflow)   WORKFLOW_ID="$2"; shift 2 ;;
    --cap-home)   CAP_HOME_OVERRIDE="$2"; shift 2 ;;
    -h|--help)
      cat <<'EOF' >&2
Usage: provider-parity-check.sh --run-dir <path> --task-id <id> --project-id <id>
                                [--workflow <wf>] [--cap-home <path>]
EOF
      exit 2
      ;;
    *)
      echo "ERROR: unknown flag $1" >&2
      exit 2
      ;;
  esac
done

[ -n "${RUN_DIR}" ]    || { echo "ERROR: --run-dir is required" >&2; exit 2; }
[ -n "${TASK_ID}" ]    || { echo "ERROR: --task-id is required" >&2; exit 2; }
[ -n "${PROJECT_ID}" ] || { echo "ERROR: --project-id is required" >&2; exit 2; }

CAP_HOME="${CAP_HOME_OVERRIDE:-${CAP_HOME:-${HOME}/.cap}}"

if [ -z "${WORKFLOW_ID}" ]; then
  WORKFLOW_ID="$(basename "$(dirname "${RUN_DIR}")")"
fi

pass=0
fail=0
fail_lines=()

ok()    { echo "  PASS: $1"; pass=$((pass + 1)); }
miss()  { echo "  FAIL: $1" >&2; fail=$((fail + 1)); fail_lines+=("$1"); }

check_file() {
  local desc="$1" path="$2"
  if [ -f "${path}" ]; then ok "${desc}"; else miss "${desc}: missing ${path}"; fi
}

check_dir() {
  local desc="$1" path="$2"
  if [ -d "${path}" ]; then ok "${desc}"; else miss "${desc}: missing dir ${path}"; fi
}

echo "Provider parity check"
echo "  run_dir:    ${RUN_DIR}"
echo "  task_id:    ${TASK_ID}"
echo "  project_id: ${PROJECT_ID}"
echo "  workflow:   ${WORKFLOW_ID}"
echo "  cap_home:   ${CAP_HOME}"
echo ""

# ── 4.1 流程完整性 ──
echo "[4.1] Run dir contents"
check_dir  "run dir exists"          "${RUN_DIR}"
check_file "run-summary.md"          "${RUN_DIR}/run-summary.md"
check_file "result.md"               "${RUN_DIR}/result.md"
check_file "agent-sessions.json"     "${RUN_DIR}/agent-sessions.json"
check_file "workflow.log"            "${RUN_DIR}/workflow.log"
check_file "runtime-state.json"      "${RUN_DIR}/runtime-state.json"

# ── 4.2 Type B Task Constitution ──
echo ""
echo "[4.2] Type B Task Constitution"
TC_PATH="${CAP_HOME}/projects/${PROJECT_ID}/constitutions/${TASK_ID}.json"
check_file "task constitution persisted" "${TC_PATH}"
if [ -f "${TC_PATH}" ]; then
  required_fields=(task_id project_id source_request goal goal_stage success_criteria non_goals execution_plan)
  for field in "${required_fields[@]}"; do
    if "${PYTHON_BIN}" -c "
import json, sys
data = json.load(open(sys.argv[1]))
val = data.get(sys.argv[2])
if val in (None, '', []):
    sys.exit(1)
sys.exit(0)
" "${TC_PATH}" "${field}" 2>/dev/null; then
      ok "Type B has required field: ${field}"
    else
      miss "Type B missing required field: ${field}"
    fi
  done
  # alias detection (warn-style; counts as fail per v0.21.1+ contract)
  for alias in task_summary user_intent_excerpt scope; do
    if "${PYTHON_BIN}" -c "
import json, sys
data = json.load(open(sys.argv[1]))
sys.exit(0 if sys.argv[2] in data and data[sys.argv[2]] not in (None, '', []) else 1)
" "${TC_PATH}" "${alias}" 2>/dev/null; then
      miss "Type B uses banned alias '${alias}' (v0.21.1+ strict schema forbids it)"
    else
      ok "Type B does not use banned alias '${alias}'"
    fi
  done
fi

# ── 4.3 Type C Handoff Tickets ──
echo ""
echo "[4.3] Type C Handoff Tickets"
HANDOFFS_DIR="${CAP_HOME}/projects/${PROJECT_ID}/handoffs"
check_dir "handoffs dir exists" "${HANDOFFS_DIR}"

case "${WORKFLOW_ID}" in
  project-spec-pipeline)
    expected_steps=(prd tech_plan ba dba_api ui spec_audit)
    ;;
  project-implementation-pipeline)
    expected_steps=(frontend backend qa_testing security_audit devops_packaging impl_audit)
    ;;
  project-qa-pipeline)
    expected_steps=(qa_testing security_audit qa_audit)
    ;;
  *)
    expected_steps=()
    ok "workflow=${WORKFLOW_ID}: no canonical step list — skipping ticket count check"
    ;;
esac

for step in "${expected_steps[@]}"; do
  ticket="${HANDOFFS_DIR}/${step}.ticket.json"
  if [ -f "${ticket}" ]; then
    ok "ticket exists for step: ${step}"
    if [ -f "${SCHEMA_HANDOFF}" ] && [ -f "${STEP_PY}" ]; then
      if "${PYTHON_BIN}" "${STEP_PY}" validate-jsonschema "${ticket}" "${SCHEMA_HANDOFF}" >/dev/null 2>&1; then
        ok "${step} ticket validates against handoff-ticket schema"
      else
        miss "${step} ticket fails schema validation"
      fi
    fi
  else
    miss "ticket missing for step: ${step}"
  fi
done

# ── 4.4 Type D Handoff Summaries ──
echo ""
echo "[4.4] Type D Handoff Summaries"
for step in "${expected_steps[@]}"; do
  matches=$(find "${RUN_DIR}" -maxdepth 1 -name "*-${step}.handoff.md" 2>/dev/null | head -1)
  if [ -n "${matches}" ]; then
    ok "handoff summary exists for step: ${step}"
  else
    miss "handoff summary missing for step: ${step}"
  fi
done

# ── 4.5 Design Source ──
echo ""
echo "[4.5] Design Source artifacts"
PROJECT_ROOT="$(dirname "${TC_PATH%/constitutions/*}")/${PROJECT_ID}"
# Note: design source artifacts live in the project repo's docs/design/, not
# in the runtime workspace. provider-parity-check trusts the caller to have
# cwd=project_root or to skip this section when not applicable. We probe
# both common locations.
for design_root in "${PWD}/docs/design" "${RUN_DIR}/docs/design"; do
  if [ -d "${design_root}" ]; then
    check_file "${design_root}/source-summary.md present" "${design_root}/source-summary.md"
    check_file "${design_root}/source-tree.txt present" "${design_root}/source-tree.txt"
    check_file "${design_root}/design-source.yaml present" "${design_root}/design-source.yaml"
    check_file "${design_root}/.source-hash.txt sentinel present" "${design_root}/.source-hash.txt"
    break
  fi
done

# ── 4.6 Spec layer artifacts (only for spec pipeline) ──
if [ "${WORKFLOW_ID}" = "project-spec-pipeline" ]; then
  echo ""
  echo "[4.6] Spec layer artifacts (best-effort filename match)"
  for token in prd tech_plan ba spec_audit _archive; do
    matches=$(find "${RUN_DIR}" -maxdepth 1 -name "*${token}*" -type f 2>/dev/null | head -1)
    if [ -n "${matches}" ]; then
      ok "found spec artifact matching: ${token}"
    else
      miss "no file in run dir matches: ${token}"
    fi
  done
fi

echo ""
echo "================================================"
echo "Summary: ${pass} passed, ${fail} failed"
echo "================================================"
if [ ${fail} -ne 0 ]; then
  echo ""
  echo "Failed checks:"
  for line in "${fail_lines[@]}"; do
    echo "  - ${line}"
  done
  exit 1
fi
exit 0
