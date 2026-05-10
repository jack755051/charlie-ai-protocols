#!/usr/bin/env bash
#
# test-promote-candidate-producer-spec-artifact.sh — Lock the v0.25.7
# spec_artifact promote candidate emission contract.
#
# Pre-fix: ``promote_candidate_producer.produce_candidates`` only
# detected ``project_constitution`` and ``compiled_workflow``. Spec
# pipeline runs produced PRD / TechPlan / BA / Schema / API / UI
# markdowns under ``<run_dir>/`` but the producer never marked them
# as candidates, so ``cap promote inspect`` had nothing to show and
# downstream pipelines (project-implementation-pipeline) had no
# automated way to know the user should run a follow-up promote.
#
# Fix (v0.25.7): producer adds a third detector
# ``_detect_spec_artifact_candidates`` that fires only for
# ``project-spec-pipeline + final_state="completed"`` runs. It walks
# the run's ``runtime-state.json`` for the six known spec artifact
# names, filters to validated source steps with on-disk paths, and
# emits candidates with the canonical target mapping (per policy
# §3.3) — ``docs/architecture/<module>_*.md`` and
# ``docs/design/<module>_UI_v1.md``. Module name resolves task_id →
# project_id → "module" literal fallback.
#
# Coverage:
#   Case 1: spec pipeline completed run with 6 validated artifacts →
#           6 spec_artifact candidates emitted with correct targets.
#   Case 2: workflow_id != project-spec-pipeline → no spec
#           candidates (other detectors still fire).
#   Case 3: final_state != "completed" → no spec candidates.
#   Case 4: source_step.execution_state != "validated" → that
#           specific candidate is skipped, others still emit.
#   Case 5: source_path missing on disk → skip that candidate
#           silently, others still emit.
#   Case 6: schema enum accepts spec_artifact via validate-jsonschema.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

[ -f "${REPO_ROOT}/engine/promote_candidate_producer.py" ] || {
  echo "FAIL: producer module missing"; exit 1;
}

SANDBOX="$(mktemp -d -t cap-promote-spec-test.XXXXXX)"
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

# Project storage layout for a completed spec pipeline run.
PROJECT_ID="bug6-promote-test-proj"
TASK_ID="happy-path-feature-spec"
RUN_ID="run_20260202000000_aaaaaaaa"
PROJECT_STORAGE="${SANDBOX}/cap_home/projects/${PROJECT_ID}"
RUN_DIR="${PROJECT_STORAGE}/reports/workflows/project-spec-pipeline/${RUN_ID}"
PROJECT_ROOT="${SANDBOX}/proj-root"
mkdir -p "${RUN_DIR}" "${PROJECT_ROOT}"

# Materialize the six spec artifacts on disk.
for fname in 4-prd.md 6-tech_plan.md 8-ba.md 10-dba_api.md 10-ui.md; do
  echo "# ${fname} content" > "${RUN_DIR}/${fname}"
done

write_runtime_state_full() {
  cat > "${RUN_DIR}/runtime-state.json" <<EOF
{
  "artifacts": {
    "prd_document": {"artifact": "prd_document", "source_step": "prd", "path": "${RUN_DIR}/4-prd.md", "handoff_path": ""},
    "tech_plan_document": {"artifact": "tech_plan_document", "source_step": "tech_plan", "path": "${RUN_DIR}/6-tech_plan.md", "handoff_path": ""},
    "ba_spec": {"artifact": "ba_spec", "source_step": "ba", "path": "${RUN_DIR}/8-ba.md", "handoff_path": ""},
    "schema_ssot": {"artifact": "schema_ssot", "source_step": "dba_api", "path": "${RUN_DIR}/10-dba_api.md", "handoff_path": ""},
    "api_contract": {"artifact": "api_contract", "source_step": "dba_api", "path": "${RUN_DIR}/10-dba_api.md", "handoff_path": ""},
    "ui_spec": {"artifact": "ui_spec", "source_step": "ui", "path": "${RUN_DIR}/10-ui.md", "handoff_path": ""}
  },
  "steps": {
    "prd": {"execution_state": "validated"},
    "tech_plan": {"execution_state": "validated"},
    "ba": {"execution_state": "validated"},
    "dba_api": {"execution_state": "validated"},
    "ui": {"execution_state": "validated"}
  }
}
EOF
}
write_runtime_state_full

# Helper: invoke produce_candidates with a synthesised run_result.
run_producer() {
  local workflow_id="$1" final_state="$2" task_id_arg="$3" run_id_arg="$4"
  WF_ID="${workflow_id}" FS="${final_state}" TID="${task_id_arg}" RID="${run_id_arg}" \
    PROJECT_ID="${PROJECT_ID}" PROJECT_ROOT="${PROJECT_ROOT}" CAP_HOME_DIR="${SANDBOX}/cap_home" \
    PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["PYTHONPATH"])
from pathlib import Path
from engine.promote_candidate_producer import produce_candidates

run_result = {
    "workflow_id": os.environ["WF_ID"],
    "final_state": os.environ["FS"],
    "project_id": os.environ["PROJECT_ID"],
    "task_id": os.environ["TID"] or None,
    "run_id": os.environ["RID"],
    "source_layer": None,
}
candidates = produce_candidates(
    run_result,
    project_root=Path(os.environ["PROJECT_ROOT"]),
    cap_home=Path(os.environ["CAP_HOME_DIR"]),
)
print(json.dumps(candidates))
PY
}

# ── Case 1: spec pipeline completed → 6 candidates ──────────────────
echo "Case 1: completed spec pipeline run emits 6 spec_artifact candidates"
out1="$(run_producer project-spec-pipeline completed "${TASK_ID}" "${RUN_ID}")"
spec_count="$(${PYTHON_BIN} -c '
import json, sys
data = json.loads(sys.argv[1])
print(sum(1 for c in data if c.get("artifact_type") == "spec_artifact"))
' "${out1}")"
assert_eq "1a. emits 6 spec_artifact candidates" "6" "${spec_count}"

# Verify each artifact_type / target_path mapping
assert_contains "1b. prd_document → docs/architecture/<task>_PRD_v1.md" \
  "docs/architecture/happy-path-feature-spec_PRD_v1.md" "${out1}"
assert_contains "1c. tech_plan_document → docs/architecture/<task>_TechPlan_v1.md" \
  "docs/architecture/happy-path-feature-spec_TechPlan_v1.md" "${out1}"
assert_contains "1d. ba_spec → docs/architecture/<task>_BA_v1.md" \
  "docs/architecture/happy-path-feature-spec_BA_v1.md" "${out1}"
assert_contains "1e. schema_ssot → docs/architecture/database/<task>_schema_v1.md" \
  "docs/architecture/database/happy-path-feature-spec_schema_v1.md" "${out1}"
assert_contains "1f. api_contract → docs/architecture/<task>_API_v1.md" \
  "docs/architecture/happy-path-feature-spec_API_v1.md" "${out1}"
assert_contains "1g. ui_spec → docs/design/<task>_UI_v1.md" \
  "docs/design/happy-path-feature-spec_UI_v1.md" "${out1}"

# Source path absolute, source_revision = run_id
assert_contains "1h. source_path is absolute and points at run dir" \
  "/reports/workflows/project-spec-pipeline/${RUN_ID}/4-prd.md" "${out1}"
assert_contains "1i. source_revision tagged with run_id" \
  "${RUN_ID}" "${out1}"
assert_contains "1j. validation_schema null per policy §6.1" \
  '"validation_schema": null' "${out1}"

# ── Case 2: non-spec workflow → no spec candidates ──────────────────
echo "Case 2: non-spec workflow does not emit spec candidates"
out2="$(run_producer project-implementation-pipeline completed "${TASK_ID}" "${RUN_ID}")"
spec_count2="$(${PYTHON_BIN} -c '
import json, sys
data = json.loads(sys.argv[1])
print(sum(1 for c in data if c.get("artifact_type") == "spec_artifact"))
' "${out2}")"
assert_eq "2. no spec_artifact candidates for impl pipeline" "0" "${spec_count2}"

# ── Case 3: failed spec run → no candidates ─────────────────────────
echo "Case 3: spec pipeline failed → no spec candidates"
out3="$(run_producer project-spec-pipeline failed "${TASK_ID}" "${RUN_ID}")"
spec_count3="$(${PYTHON_BIN} -c '
import json, sys
data = json.loads(sys.argv[1])
print(sum(1 for c in data if c.get("artifact_type") == "spec_artifact"))
' "${out3}")"
assert_eq "3. failed spec run emits 0 spec candidates" "0" "${spec_count3}"

# ── Case 4: one source_step blocked → that artifact skipped ─────────
echo "Case 4: blocked source_step skipped, others emit"
cat > "${RUN_DIR}/runtime-state.json" <<EOF
{
  "artifacts": {
    "prd_document": {"artifact": "prd_document", "source_step": "prd", "path": "${RUN_DIR}/4-prd.md", "handoff_path": ""},
    "ba_spec": {"artifact": "ba_spec", "source_step": "ba", "path": "${RUN_DIR}/8-ba.md", "handoff_path": ""},
    "ui_spec": {"artifact": "ui_spec", "source_step": "ui", "path": "${RUN_DIR}/10-ui.md", "handoff_path": ""}
  },
  "steps": {
    "prd": {"execution_state": "validated"},
    "ba": {"execution_state": "blocked"},
    "ui": {"execution_state": "validated"}
  }
}
EOF
out4="$(run_producer project-spec-pipeline completed "${TASK_ID}" "${RUN_ID}")"
ids4="$(${PYTHON_BIN} -c '
import json, sys
data = json.loads(sys.argv[1])
spec = [c for c in data if c.get("artifact_type") == "spec_artifact"]
print(",".join(c["target_path"].rsplit("/", 1)[-1] for c in spec))
' "${out4}")"
assert_eq "4a. blocked ba_spec excluded; prd + ui emitted" \
  "happy-path-feature-spec_PRD_v1.md,happy-path-feature-spec_UI_v1.md" "${ids4}"

# ── Case 5: source_path missing on disk → skip ──────────────────────
echo "Case 5: missing source on disk silently skipped"
write_runtime_state_full
rm -f "${RUN_DIR}/8-ba.md"  # ba.md no longer on disk
out5="$(run_producer project-spec-pipeline completed "${TASK_ID}" "${RUN_ID}")"
spec_count5="$(${PYTHON_BIN} -c '
import json, sys
data = json.loads(sys.argv[1])
print(sum(1 for c in data if c.get("artifact_type") == "spec_artifact"))
' "${out5}")"
assert_eq "5a. 5 candidates after ba.md removed (was 6)" "5" "${spec_count5}"
case "${out5}" in
  *"happy-path-feature-spec_BA_v1.md"*)
    echo "  FAIL: 5b. removed ba_spec should NOT be in candidates"
    fail_count=$((fail_count + 1)) ;;
  *)
    echo "  PASS: 5b. removed ba_spec correctly excluded"
    pass_count=$((pass_count + 1)) ;;
esac
# Restore for subsequent cases
echo "# 8-ba.md content" > "${RUN_DIR}/8-ba.md"

# ── Case 6: schema accepts spec_artifact ────────────────────────────
echo "Case 6: workflow-result schema accepts spec_artifact in enum"
write_runtime_state_full
fixture6="${SANDBOX}/result.json"
cat > "${fixture6}" <<EOF
{
  "schema_version": 1,
  "run_id": "${RUN_ID}",
  "workflow_id": "project-spec-pipeline",
  "workflow_name": "Project Specification Pipeline",
  "project_id": "${PROJECT_ID}",
  "started_at": "2026-02-02 00:00:00",
  "finished_at": "2026-02-02 00:01:00",
  "final_state": "completed",
  "final_result": "success",
  "total_duration_seconds": 60,
  "summary": {"total_steps": 1, "completed": 1, "failed": 0, "skipped": 0, "blocked": 0},
  "inputs": {},
  "steps": [],
  "sessions": [],
  "artifacts": [],
  "failures": [],
  "logs": {"workflow_log": "${RUN_DIR}/workflow.log", "workflow_log_lines": 1, "result_md": "${RUN_DIR}/result.md", "agent_sessions_path": "${RUN_DIR}/agent-sessions.json", "runtime_state_path": "${RUN_DIR}/runtime-state.json"},
  "promote_candidates": [
    {
      "source_path": "${RUN_DIR}/4-prd.md",
      "target_path": "${PROJECT_ROOT}/docs/architecture/happy-path-feature-spec_PRD_v1.md",
      "artifact_type": "spec_artifact",
      "reason": "spec pipeline produced PRD; ready to promote",
      "validation_schema": null,
      "source_layer": null,
      "source_revision": "${RUN_ID}"
    }
  ]
}
EOF
schema_rc="$(${PYTHON_BIN} "${REPO_ROOT}/engine/step_runtime.py" validate-jsonschema \
  "${fixture6}" "${REPO_ROOT}/schemas/workflow-result.schema.yaml" >/dev/null 2>&1; echo $?)"
assert_eq "6. schema validate-jsonschema accepts spec_artifact" "0" "${schema_rc}"

# ── Case 7: detect_spec_artifact_candidate_for_name single-name lookup ─
echo "Case 7: inspect-side helper resolves single artifact_name"
write_runtime_state_full
case7_target="$(WF_ID=project-spec-pipeline FS=completed TID="${TASK_ID}" RID="${RUN_ID}" \
  PROJECT_ID="${PROJECT_ID}" PROJECT_ROOT="${PROJECT_ROOT}" CAP_HOME_DIR="${SANDBOX}/cap_home" \
  PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["PYTHONPATH"])
from pathlib import Path
from engine.promote_candidate_producer import detect_spec_artifact_candidate_for_name

hit = detect_spec_artifact_candidate_for_name(
    "prd_document",
    project_storage=Path(os.environ["CAP_HOME_DIR"]) / "projects" / os.environ["PROJECT_ID"],
    project_root=Path(os.environ["PROJECT_ROOT"]),
)
print(json.dumps(hit) if hit else "")
PY
)"
case7_artifact_type="$(${PYTHON_BIN} -c '
import json, sys
data = json.loads(sys.argv[1])
print(data.get("artifact_type") if data else "<none>")
' "${case7_target}")"
assert_eq "7a. detect_spec_artifact_candidate_for_name returns spec_artifact" \
  "spec_artifact" "${case7_artifact_type}"

# Inspect uses project_id basename when runtime-state has no task_id
case7_target_filename="$(${PYTHON_BIN} -c '
import json, sys
data = json.loads(sys.argv[1])
print(data["target_path"].rsplit("/", 1)[-1] if data else "")
' "${case7_target}")"
assert_eq "7b. target_filename uses project_id basename when state has no task_id" \
  "bug6-promote-test-proj_PRD_v1.md" "${case7_target_filename}"

# Negative leg — unknown name returns None
case7_unknown="$(WF_ID=project-spec-pipeline FS=completed TID="${TASK_ID}" RID="${RUN_ID}" \
  PROJECT_ID="${PROJECT_ID}" PROJECT_ROOT="${PROJECT_ROOT}" CAP_HOME_DIR="${SANDBOX}/cap_home" \
  PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["PYTHONPATH"])
from pathlib import Path
from engine.promote_candidate_producer import detect_spec_artifact_candidate_for_name

hit = detect_spec_artifact_candidate_for_name(
    "not_a_real_artifact_name",
    project_storage=Path(os.environ["CAP_HOME_DIR"]) / "projects" / os.environ["PROJECT_ID"],
    project_root=Path(os.environ["PROJECT_ROOT"]),
)
print("HIT" if hit else "NONE")
PY
)"
assert_eq "7c. unknown artifact_name returns None" "NONE" "${case7_unknown}"

# ── Case 8: resolve_promote (inspect data layer) finds spec_artifact ─
echo "Case 8: resolve_promote inspect-side returns ResolvedPromote for spec_artifact"
case8_resolved="$(PROJECT_ID="${PROJECT_ID}" PROJECT_ROOT="${PROJECT_ROOT}" CAP_HOME_DIR="${SANDBOX}/cap_home" \
  PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["PYTHONPATH"])
from pathlib import Path
from engine.promote_resolver import resolve_promote

resolved = resolve_promote(
    "ba_spec",
    project_id=os.environ["PROJECT_ID"],
    project_root=Path(os.environ["PROJECT_ROOT"]),
    cap_home=Path(os.environ["CAP_HOME_DIR"]),
)
if resolved is None:
    print("NONE")
else:
    print(json.dumps({
        "artifact_type": resolved.candidate.get("artifact_type"),
        "target_filename": resolved.candidate.get("target_path", "").rsplit("/", 1)[-1],
        "conflict_kind": resolved.conflict_kind,
        "validation_schema": resolved.validation_schema,
    }))
PY
)"
case8_artifact_type="$(${PYTHON_BIN} -c '
import json, sys
data = json.loads(sys.argv[1]) if sys.argv[1] != "NONE" else {}
print(data.get("artifact_type", "<none>"))
' "${case8_resolved}")"
case8_filename="$(${PYTHON_BIN} -c '
import json, sys
data = json.loads(sys.argv[1]) if sys.argv[1] != "NONE" else {}
print(data.get("target_filename", "<none>"))
' "${case8_resolved}")"
assert_eq "8a. resolve_promote returns spec_artifact for ba_spec" \
  "spec_artifact" "${case8_artifact_type}"
assert_eq "8b. resolve target uses project_id basename when state has no task_id" \
  "bug6-promote-test-proj_BA_v1.md" "${case8_filename}"

echo ""
total=$((pass_count + fail_count))
echo "promote-candidate-producer-spec-artifact: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
