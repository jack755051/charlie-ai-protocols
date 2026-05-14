#!/usr/bin/env bash
#
# test-component-fast-workflow.sh — P1b slice 5 gate.
#
# Validates that the component-fast workflow YAML is well-formed,
# references existing capabilities, points its shell steps at the
# expected script paths, and stays inside the P1a memo budgets
# (<= 2 AI steps, no project-spec / project-implementation pipeline
# coupling). Also re-asserts the step_runtime code-emit whitelist
# additions.
#
# Slice 5 boundary: does NOT run the workflow, does NOT spawn an AI
# agent, does NOT validate that every referenced shell script
# actually exists (resolve / smoke wrappers land in a later slice).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
WORKFLOW="${REPO_ROOT}/schemas/workflows/component-fast.yaml"
CAPABILITIES="${REPO_ROOT}/schemas/capabilities.yaml"
STEP_RUNTIME="${REPO_ROOT}/engine/step_runtime.py"

[ -f "${WORKFLOW}" ]      || { echo "FAIL: ${WORKFLOW} missing";      exit 1; }
[ -f "${CAPABILITIES}" ]  || { echo "FAIL: ${CAPABILITIES} missing";  exit 1; }
[ -f "${STEP_RUNTIME}" ]  || { echo "FAIL: ${STEP_RUNTIME} missing";  exit 1; }

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
    fail_count=$((fail_count + 1))
  fi
}

# ── Case 1: workflow file parses + carries expected identity ─────────
echo "Case 1: workflow YAML parses and identifies as component-fast"
meta="$("${PYTHON_BIN}" - "${WORKFLOW}" <<'PY'
import sys
import yaml

data = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
print(f"workflow_id={data.get('workflow_id')}")
print(f"version={data.get('version')}")
print(f"name={data.get('name')}")
print(f"step_count={len(data.get('steps') or [])}")
PY
)"
assert_contains "workflow_id = component-fast"          "${meta}"  "workflow_id=component-fast"
assert_contains "schema version 1"                      "${meta}"  "version=1"
assert_contains "step_count = 7"                        "${meta}"  "step_count=7"

# ── Case 2: step IDs exactly match P1a memo order ────────────────────
echo ""
echo "Case 2: step ids match the seven phases from P1a memo"
step_ids="$("${PYTHON_BIN}" - "${WORKFLOW}" <<'PY'
import sys
import yaml

data = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
print("\n".join(step.get("id") or "" for step in data.get("steps") or []))
PY
)"
expected_ids="resolve_inputs
render_skeleton
deterministic_audit
smoke_runtime
compact_review
fix_or_polish
archive"
assert_eq "step ids exact order" "${expected_ids}" "${step_ids}"

# ── Case 3: shell step script paths point at expected files ──────────
#
# Render + audit + archive scripts MUST already exist on disk (slice
# 3 / slice 4 / P7 substrate). Resolve + smoke wrappers are referenced
# but not yet shipped; their on-disk existence is checked in a later
# slice. This case asserts the YAML *names* them at the right path.
echo ""
echo "Case 3: shell step scripts point at expected paths"
shell_scripts="$("${PYTHON_BIN}" - "${WORKFLOW}" <<'PY'
import sys
import yaml

data = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
for step in data.get("steps") or []:
    if step.get("executor") == "shell":
        print(f"{step['id']}={step.get('script') or ''}")
PY
)"
assert_contains "resolve_inputs script path"       "${shell_scripts}"  "resolve_inputs=scripts/workflows/component-fast-resolve.sh"
assert_contains "render_skeleton script path"      "${shell_scripts}"  "render_skeleton=scripts/workflows/component-fast-render.sh"
assert_contains "deterministic_audit script path"  "${shell_scripts}"  "deterministic_audit=scripts/workflows/component-fast-audit.sh"
assert_contains "smoke_runtime script path"        "${shell_scripts}"  "smoke_runtime=scripts/workflows/component-fast-smoke.sh"
assert_contains "archive script path"              "${shell_scripts}"  "archive=scripts/cap-result-emit.sh"

# Sub-case: the three slice-3/slice-4/P7 substrate scripts exist on disk.
for substrate_script in \
  scripts/workflows/component-fast-render.sh \
  scripts/workflows/component-fast-audit.sh \
  scripts/cap-result-emit.sh
do
  if [ -x "${REPO_ROOT}/${substrate_script}" ]; then
    echo "  PASS: substrate script exists + executable: ${substrate_script}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: substrate script missing or not +x: ${substrate_script}"
    fail_count=$((fail_count + 1))
  fi
done

# ── Case 4: every referenced capability is declared in capabilities.yaml ─
echo ""
echo "Case 4: every workflow capability is declared in capabilities.yaml"
cap_check="$("${PYTHON_BIN}" - "${WORKFLOW}" "${CAPABILITIES}" <<'PY'
import sys
import yaml

workflow_data = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
caps_data = yaml.safe_load(open(sys.argv[2], encoding="utf-8")) or {}
declared = set((caps_data.get("capabilities") or {}).keys())

missing = []
for step in workflow_data.get("steps") or []:
    cap = step.get("capability")
    if isinstance(cap, str) and cap and cap not in declared:
        missing.append(f"{step.get('id')}->{cap}")
print(",".join(missing))
PY
)"
assert_eq "no undeclared capability reference" "" "${cap_check}"

# ── Case 5: six new P1b capabilities present with non-empty contracts ─
echo ""
echo "Case 5: six P1b capabilities declared with description + done_when"
new_caps_check="$("${PYTHON_BIN}" - "${CAPABILITIES}" <<'PY'
import sys
import yaml

caps = (yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}).get("capabilities") or {}
expected = [
    "component_fast_inputs",
    "deterministic_scaffold",
    "deterministic_compliance_checklist",
    "runtime_smoke",
    "component_repo_compact_review",
    "component_repo_repair",
]
problems = []
for name in expected:
    entry = caps.get(name)
    if not isinstance(entry, dict):
        problems.append(f"{name}=missing")
        continue
    if not (entry.get("description") or "").strip():
        problems.append(f"{name}=empty_description")
    if not (entry.get("done_when") or []):
        problems.append(f"{name}=empty_done_when")
print(",".join(problems))
PY
)"
assert_eq "all 6 new capabilities populated" "" "${new_caps_check}"

# ── Case 6: deterministic_scaffold + component_repo_repair on code-emit whitelist ─
echo ""
echo "Case 6: code-emit whitelist updated for the two P1b code-writing steps"
emit_scaffold="$("${PYTHON_BIN}" "${STEP_RUNTIME}" capability-emits-code deterministic_scaffold)"
emit_repair="$("${PYTHON_BIN}"   "${STEP_RUNTIME}" capability-emits-code component_repo_repair)"
emit_review="$("${PYTHON_BIN}"   "${STEP_RUNTIME}" capability-emits-code component_repo_compact_review)"
emit_audit="$("${PYTHON_BIN}"    "${STEP_RUNTIME}" capability-emits-code deterministic_compliance_checklist)"
assert_eq "deterministic_scaffold emits code"             "true"   "${emit_scaffold}"
assert_eq "component_repo_repair emits code"              "true"   "${emit_repair}"
assert_eq "component_repo_compact_review is review only"  "false"  "${emit_review}"
assert_eq "deterministic_compliance_checklist is audit"   "false"  "${emit_audit}"

# ── Case 7: AI step count <= 2 (P1a budget) ──────────────────────────
echo ""
echo "Case 7: AI step budget respected (<= 2)"
ai_count="$("${PYTHON_BIN}" - "${WORKFLOW}" <<'PY'
import sys
import yaml

data = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
ai_steps = [s.get("id") for s in (data.get("steps") or []) if s.get("executor") == "ai"]
print(len(ai_steps))
PY
)"
if [ "${ai_count}" -le 2 ]; then
  echo "  PASS: ai step count ${ai_count} <= 2"
  pass_count=$((pass_count + 1))
else
  echo "  FAIL: ai step count ${ai_count} > 2"
  fail_count=$((fail_count + 1))
fi

# ── Case 8: no OPERATIONAL coupling to product-strict pipelines ──────
#
# Prose fields (summary / notes / name / description / artifacts) are
# allowed to cross-reference the strict pipelines for context — the
# point is that nothing in the runtime path (needs / capability /
# script / governance.required_upstream_artifacts) actually depends
# on them.
echo ""
echo "Case 8: no operational dependency on project-strict pipelines"
coupling="$("${PYTHON_BIN}" - "${WORKFLOW}" <<'PY'
import sys
import yaml

data = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
strict_ids = {
    "project-spec-pipeline",
    "project-implementation-pipeline",
    "project-qa-pipeline",
}
strict_caps = {
    # Pipeline-specific capabilities that would couple us.
    "task_constitution_persistence",
    "code_structure_audit",
    "business_analysis",
    "database_api_design",
    "ui_design",
}

hits = []

# Operational fields per step.
for step in data.get("steps") or []:
    if step.get("capability") in strict_caps:
        hits.append(f"step {step.get('id')!r} uses strict capability {step.get('capability')!r}")
    for need in step.get("needs") or []:
        if need in strict_ids:
            hits.append(f"step {step.get('id')!r} needs strict pipeline {need!r}")
    script = step.get("script") or ""
    for sid in strict_ids:
        if sid in script:
            hits.append(f"step {step.get('id')!r} script references {sid!r}")

# Governance upstream-artifact coupling.
gov = data.get("governance") or {}
if gov.get("required_upstream_artifacts"):
    hits.append("governance.required_upstream_artifacts is set (coupling)")

print(",".join(hits))
PY
)"
assert_eq "no operational coupling" "" "${coupling}"

# ── Case 9: dependency graph stays linear + ends on archive ──────────
#
# Sanity check that `needs:` forms a single linear chain ending with
# archive depending on fix_or_polish — matches the P1a memo's
# resolve_inputs → … → archive serial shape (no parallel fan-out yet).
echo ""
echo "Case 9: needs[] forms the expected linear chain"
chain="$("${PYTHON_BIN}" - "${WORKFLOW}" <<'PY'
import sys
import yaml

data = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
edges = []
for step in data.get("steps") or []:
    sid = step.get("id")
    needs = step.get("needs") or []
    edges.append(f"{sid}<-{','.join(needs) if needs else '(root)'}")
print("\n".join(edges))
PY
)"
expected_chain="resolve_inputs<-(root)
render_skeleton<-resolve_inputs
deterministic_audit<-render_skeleton
smoke_runtime<-deterministic_audit
compact_review<-smoke_runtime
fix_or_polish<-compact_review
archive<-fix_or_polish"
assert_eq "linear needs chain" "${expected_chain}" "${chain}"

echo ""
total=$((pass_count + fail_count))
echo "component-fast-workflow: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
