#!/usr/bin/env bash
#
# test-binding-source-metadata.sh — P9 #4 focused test.
#
# Exercises Binding Report Source Metadata producer wiring in
# ``engine/runtime_binder.py:bind_semantic_plan``. Reference:
# docs/cap/P9-SOURCE-RESOLVER-DESIGN.md §6.
#
# Cases:
#   1. workflow_source populated from semantic_plan source_layer +
#      source_path (project / shared / builtin).
#   2. effective_allowed_roots placeholder is [] (P9 #5 will populate).
#   3. skill_source per step:
#      - resolved AI step → tagged with chosen skill's _source_layer.
#      - shell step (builtin-shell) → fallback / null.
#      - layered project skill override → source_layer=project.
#   4. binding report passes schemas/binding-report.schema.yaml
#      validation with the new optional fields populated.
#   5. unresolved branch → skill_source=null (no skill picked).
#   6. Synthesized inline semantic plan (no source_path / source_layer)
#      → workflow_source=null without breaking schema.
#
# Drives the binder with explicit project_root / cap_home kwargs and
# stages a tiny workflow + skill registry per case so each scenario
# is hermetic.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
SCHEMA_PATH="${REPO_ROOT}/schemas/binding-report.schema.yaml"
STEP_RUNTIME="${REPO_ROOT}/engine/step_runtime.py"

[ -f "${REPO_ROOT}/engine/runtime_binder.py" ] || { echo "FAIL: runtime_binder.py missing"; exit 1; }
[ -f "${SCHEMA_PATH}" ]  || { echo "FAIL: binding-report.schema.yaml missing"; exit 1; }
[ -f "${STEP_RUNTIME}" ] || { echo "FAIL: step_runtime.py missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-binding-source-metadata-test.XXXXXX)"
SANDBOX="$(cd "${SANDBOX}" && pwd -P)"
trap 'rm -rf "${SANDBOX}"' EXIT

# Sandbox is not a git repo and has no .cap/project.yaml, so
# ProjectContextLoader's project_id resolution would otherwise raise.
# Pin a stable id and route the ledger storage at our sandbox so each
# run is hermetic (avoids collisions from prior failed runs that wrote
# to ~/.cap/projects/<id>/.identity.json).
export CAP_PROJECT_ID_OVERRIDE="cap-binding-source-metadata-test"
export CAP_HOME="${SANDBOX}/cap_home"
mkdir -p "${CAP_HOME}/projects"

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

assert_schema_ok() {
  local desc="$1" json_path="$2"
  local out
  out="$("${PYTHON_BIN}" "${STEP_RUNTIME}" validate-jsonschema "${json_path}" "${SCHEMA_PATH}" 2>&1)"
  local rc=$?
  if [ "${rc}" -eq 0 ] && printf '%s' "${out}" | grep -q '"ok": true'; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    rc:  ${rc}"
    echo "    out: ${out}"
    fail_count=$((fail_count + 1))
  fi
}

# ── Sandbox layout ────────────────────────────────────────────────────
#   ${SANDBOX}/proj/.cap/skills.yaml      (project skill registry)
#   ${SANDBOX}/proj/.cap/workflows/<wf>   (project workflow)
#   ${SANDBOX}/builtin/.cap/skills.yaml   (builtin skill registry)
#   ${SANDBOX}/builtin/schemas/workflows/ (builtin workflow dir)
#   ${SANDBOX}/builtin/schemas/capabilities.yaml
#
# All steps go through binder with explicit project_root + cap_home so
# the live cap-protocols repo isn't touched.

PROJECT_ROOT="${SANDBOX}/proj"
CAP_HOME_DIR="${SANDBOX}/cap_home"
BUILTIN_BASE="${SANDBOX}/builtin"

mkdir -p \
  "${PROJECT_ROOT}/.cap/workflows" \
  "${CAP_HOME_DIR}/shared" \
  "${BUILTIN_BASE}/.cap" \
  "${BUILTIN_BASE}/schemas/workflows"

# Minimal constitution so ProjectContextLoader doesn't flag the run
# as bootstrap mode (which would otherwise route every step through
# the blocked_by_constitution branch and starve the test of resolved
# / shell / unresolved coverage). Empty binding_policy keeps the
# allowed_capabilities gate inactive. Lands at the legacy
# .cap.constitution.yaml path because that is
# ProjectContextLoader.DEFAULT_PROJECT_CONSTITUTION; reaching the
# namespaced .cap/constitution.yaml would require also planting a
# .cap.project.yaml with constitution_file pointing there.
cat > "${BUILTIN_BASE}/.cap.constitution.yaml" <<'EOF'
schema_version: 1
constitution_id: focused-test-constitution
constitution_name: focused test
binding_policy: {}
workflow_policy: {}
EOF

# Minimal capabilities.yaml so semantic plan loading doesn't bomb.
# Two capabilities so the test's unresolved step stays inside the
# "no skill" branch instead of tripping contract_missing_steps (which
# the binding-report schema requires to be objects, not strings — a
# pre-existing producer/schema gap unrelated to P9 #4).
cat > "${BUILTIN_BASE}/schemas/capabilities.yaml" <<'EOF'
schema_version: 1
capabilities:
  test_capability:
    summary: focused test capability
    default_agent: test-agent
    allowed_agents: [test-agent]
    inputs: []
    outputs: []
  another_capability:
    summary: capability with no registry skill (drives optional_unresolved)
    default_agent: test-agent
    allowed_agents: [test-agent]
    inputs: []
    outputs: []
EOF

# Builtin skill registry: provides one AI skill for test_capability.
cat > "${BUILTIN_BASE}/.cap/skills.yaml" <<'EOF'
schema_version: 1
default_provider: builtin
binding_defaults:
  binding_mode: prefer_skill
  missing_policy: halt
skills:
  - skill_id: builtin-test-skill
    provider: claude
    enabled: true
    priority: 100
    compatible_workflow_versions: []
    provided_capabilities: [test_capability]
    fallback_roles: []
    agent_alias: test-agent
    prompt_file: agent-skills/00-core-protocol.md
    cli: claude
EOF

# Builtin workflow with one AI step + one shell step + one optional
# step that has no skill.
cat > "${BUILTIN_BASE}/schemas/workflows/wf-mixed.yaml" <<'EOF'
schema_version: 1
workflow_id: wf-mixed
name: wf-mixed
version: 1
summary: mixed AI + shell + unresolved fixture
triggers: []
steps:
  - id: ai_step
    name: ai_step
    capability: test_capability
    executor: ai
  - id: shell_step
    name: shell_step
    capability: test_capability
    executor: shell
    script: scripts/workflows/dummy.sh
  - id: unresolved_optional_step
    name: unresolved_optional_step
    capability: another_capability
    executor: ai
    optional: true
EOF

# build_binding <ref>
# Build a binding for the workflow at <ref> via RuntimeBinder using
# the sandbox roots. Outputs JSON to stdout. Traceback (if any) goes
# to the calling shell's stderr so the test summary surfaces the
# real cause when something blows up.
build_binding() {
  local ref="$1"
  PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${BUILTIN_BASE}" "${PROJECT_ROOT}" "${CAP_HOME_DIR}" "${ref}" <<'PY'
import json
import sys
from pathlib import Path

from engine.runtime_binder import RuntimeBinder

builtin_base, project_root, cap_home_dir, ref = sys.argv[1:5]
binder = RuntimeBinder(
    base_dir=Path(builtin_base),
    project_root=Path(project_root),
    cap_home=Path(cap_home_dir),
)
binding = binder.bind_capabilities(ref)
print(json.dumps(binding, ensure_ascii=False, default=str))
PY
}

# json_field <json_str> <python_expr_on_data>
# Pass json_str via argv (not stdin) because the heredoc itself
# occupies stdin — using ``printf | python - <<EOF`` would have the
# heredoc clobber the pipe and leave the eval reading the Python
# source as input.
json_field() {
  local json_str="$1" expr="$2"
  "${PYTHON_BIN}" - "${json_str}" "${expr}" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
print(eval(sys.argv[2], {"data": data}))
PY
}

# ── Case 1+2+3+5: builtin-only binding (no project overlay) ─────────

echo "Case 1+2+3+5: builtin workflow + builtin skill + shell + unresolved"
BINDING1="$(build_binding "wf-mixed")"
[ -n "${BINDING1}" ] || { echo "FAIL: build_binding returned empty"; exit 1; }

# 1. workflow_source
assert_eq "wf source_layer=builtin" "builtin" \
  "$(json_field "${BINDING1}" 'data["workflow_source"]["source_layer"]')"
assert_eq "wf source_path is builtin file" \
  "${BUILTIN_BASE}/schemas/workflows/wf-mixed.yaml" \
  "$(json_field "${BINDING1}" 'data["workflow_source"]["source_path"]')"

# 2. effective_allowed_roots placeholder
assert_eq "effective_allowed_roots is []" "[]" \
  "$(json_field "${BINDING1}" 'data["effective_allowed_roots"]')"

# 3. skill_source per step — AI step
assert_eq "ai_step skill_source.source_layer=builtin" "builtin" \
  "$(json_field "${BINDING1}" '[s for s in data["steps"] if s["step_id"]=="ai_step"][0]["skill_source"]["source_layer"]')"
assert_eq "ai_step skill_source.source_path is builtin skills.yaml" \
  "${BUILTIN_BASE}/.cap/skills.yaml" \
  "$(json_field "${BINDING1}" '[s for s in data["steps"] if s["step_id"]=="ai_step"][0]["skill_source"]["source_path"]')"

# 3. skill_source per step — shell step
assert_eq "shell_step resolution_status=resolved" "resolved" \
  "$(json_field "${BINDING1}" '[s for s in data["steps"] if s["step_id"]=="shell_step"][0]["resolution_status"]')"
assert_eq "shell_step skill_source.source_layer=fallback" "fallback" \
  "$(json_field "${BINDING1}" '[s for s in data["steps"] if s["step_id"]=="shell_step"][0]["skill_source"]["source_layer"]')"
assert_eq "shell_step skill_source.source_path=None" "None" \
  "$(json_field "${BINDING1}" '[s for s in data["steps"] if s["step_id"]=="shell_step"][0]["skill_source"]["source_path"]')"

# 5. unresolved optional step → skill_source=null
assert_eq "unresolved_optional_step skill_source=None" "None" \
  "$(json_field "${BINDING1}" '[s for s in data["steps"] if s["step_id"]=="unresolved_optional_step"][0]["skill_source"]')"
assert_eq "unresolved_optional_step status=optional_unresolved" "optional_unresolved" \
  "$(json_field "${BINDING1}" '[s for s in data["steps"] if s["step_id"]=="unresolved_optional_step"][0]["resolution_status"]')"

# 4. schema validation
BINDING1_FILE="${SANDBOX}/binding1.json"
printf '%s' "${BINDING1}" > "${BINDING1_FILE}"
assert_schema_ok "case1: builtin-only binding passes binding-report schema" "${BINDING1_FILE}"

# ── Case 3 (project override): same binding with project skill staged

echo ""
echo "Case 3 (override): project skill same id wins → skill_source.source_layer=project"
cat > "${PROJECT_ROOT}/.cap/skills.yaml" <<'EOF'
schema_version: 1
default_provider: project
skills:
  - skill_id: builtin-test-skill
    provider: claude
    enabled: true
    priority: 100
    compatible_workflow_versions: []
    provided_capabilities: [test_capability]
    fallback_roles: []
    agent_alias: test-agent
    prompt_file: agent-skills/00-core-protocol.md
    cli: claude
EOF

BINDING2="$(build_binding "wf-mixed")"
BINDING2_FILE="${SANDBOX}/binding2.json"
printf '%s' "${BINDING2}" > "${BINDING2_FILE}"

assert_eq "case3: ai_step skill_source.source_layer=project (override)" "project" \
  "$(json_field "${BINDING2}" '[s for s in data["steps"] if s["step_id"]=="ai_step"][0]["skill_source"]["source_layer"]')"
assert_eq "case3: ai_step skill_source.source_path is project skills.yaml" \
  "${PROJECT_ROOT}/.cap/skills.yaml" \
  "$(json_field "${BINDING2}" '[s for s in data["steps"] if s["step_id"]=="ai_step"][0]["skill_source"]["source_path"]')"
assert_schema_ok "case3: project-override binding passes binding-report schema" "${BINDING2_FILE}"

rm -f "${PROJECT_ROOT}/.cap/skills.yaml"

# ── Case 6: synthesized inline semantic plan → workflow_source=null

echo ""
echo "Case 6: synthesized semantic_plan with no source_path → workflow_source=null"
SYNTH_BINDING="$(PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${BUILTIN_BASE}" "${PROJECT_ROOT}" "${CAP_HOME_DIR}" <<'PY'
import json
import sys
from pathlib import Path

from engine.runtime_binder import RuntimeBinder

builtin_base, project_root, cap_home_dir = sys.argv[1:4]
binder = RuntimeBinder(
    base_dir=Path(builtin_base),
    project_root=Path(project_root),
    cap_home=Path(cap_home_dir),
)
# Inline plan without source_path / source_layer (mimics test harness
# fixtures or future synthesised plans not backed by a real workflow).
synthetic_plan = {
    "workflow_id": "synthetic-inline",
    "version": 1,
    "name": "synthetic",
    "summary": "inline test fixture",
    "phases": [],
    "steps": [],
    "contract_missing_steps": [],
}
binding = binder.bind_semantic_plan(synthetic_plan)
print(json.dumps(binding, ensure_ascii=False, default=str))
PY
)"

SYNTH_FILE="${SANDBOX}/binding-synth.json"
printf '%s' "${SYNTH_BINDING}" > "${SYNTH_FILE}"
assert_eq "case6: workflow_source=None" "None" \
  "$(json_field "${SYNTH_BINDING}" 'data["workflow_source"]')"
assert_eq "case6: effective_allowed_roots=[]" "[]" \
  "$(json_field "${SYNTH_BINDING}" 'data["effective_allowed_roots"]')"
assert_schema_ok "case6: synthesized binding passes binding-report schema" "${SYNTH_FILE}"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
