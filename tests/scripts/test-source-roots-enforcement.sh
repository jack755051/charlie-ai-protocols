#!/usr/bin/env bash
#
# test-source-roots-enforcement.sh — P9 #5 focused test.
#
# Exercises Allowed Source Roots Enforcement implemented in
# ``engine/runtime_binder.py``: ``_compute_effective_allowed_roots``
# (helper) + ``_assert_workflow_source_allowed`` (upgraded) +
# ``_assert_skill_source_allowed`` (new). Reference:
# docs/cap/P9-SOURCE-RESOLVER-DESIGN.md §7.
#
# Cases:
#   1. enforce=false → both gates skip; effective_allowed_roots=[];
#      binding_status=ready (matches pre-P9 #5 behaviour).
#   2. enforce=true + project / builtin canonical paths → implicit
#      defaults populate effective set; project / builtin skills pass
#      without user having to spell those paths.
#   3. enforce=true + shared skill loaded but shared root NOT in
#      user-declared list → SkillSourcePolicyError halts the binding
#      (shared is not in implicit defaults per memo §3.1).
#   4. enforce=true + shared skill loaded AND shared root explicitly
#      added to user-declared allowed_source_roots → pass.
#   5. enforce=true + workflow path under explicit (outside layer
#      roots) and outside effective set → WorkflowSourcePolicyError
#      halts before any step skill check (memo §7.5: workflow gate
#      fires first).
#   6. exception class hierarchy: SkillSourcePolicyError and
#      WorkflowSourcePolicyError both inherit SourcePolicyError so
#      callers can ``except SourcePolicyError`` once.
#   7. effective_allowed_roots snapshot is recorded in the binding
#      report and lists user-declared first, implicit defaults after.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

[ -f "${REPO_ROOT}/engine/runtime_binder.py" ] || {
  echo "FAIL: runtime_binder.py missing"; exit 1;
}

SANDBOX="$(mktemp -d -t cap-source-roots-enforcement-test.XXXXXX)"
SANDBOX="$(cd "${SANDBOX}" && pwd -P)"
trap 'rm -rf "${SANDBOX}"' EXIT

# Hermetic ledger + project_id so the test never collides with the
# user's real ~/.cap/projects/<id>/.identity.json.
export CAP_PROJECT_ID_OVERRIDE="cap-source-roots-enforcement-test"
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

# Stage one full sandbox (constitution + builtin skill + workflow) and
# echo its key paths via env-style stdout so each case can re-use the
# layout. Layout:
#   ${SBX}/proj/.cap/skills.yaml          (project layer registry)
#   ${SBX}/cap_home/shared/skills.yaml    (shared layer registry)
#   ${SBX}/builtin/.cap/skills.yaml       (builtin layer registry)
#   ${SBX}/builtin/.cap.constitution.yaml (constitution; legacy path
#                                          because DEFAULT_PROJECT_CONSTITUTION
#                                          is the legacy form)
#   ${SBX}/builtin/schemas/workflows/wf.yaml (workflow under builtin)
#   ${SBX}/builtin/schemas/capabilities.yaml
PROJECT_ROOT="${SANDBOX}/proj"
CAP_HOME_DIR="${SANDBOX}/cap_home"
BUILTIN_BASE="${SANDBOX}/builtin"

mkdir -p \
  "${PROJECT_ROOT}/.cap" \
  "${CAP_HOME_DIR}/shared" \
  "${BUILTIN_BASE}/.cap" \
  "${BUILTIN_BASE}/schemas/workflows"

cat > "${BUILTIN_BASE}/schemas/capabilities.yaml" <<'EOF'
schema_version: 1
capabilities:
  test_capability:
    summary: focused test capability
    default_agent: test-agent
    allowed_agents: [test-agent]
    inputs: []
    outputs: []
EOF

# Helper to write a constitution. Caller passes 'true' or 'false' for
# enforce flag, and an optional newline-separated list of user-declared
# allowed_source_roots paths.
write_constitution() {
  local enforce="$1" extra_roots="${2:-}"
  {
    echo "schema_version: 1"
    echo "constitution_id: focused-test-constitution"
    echo "constitution_name: focused test"
    echo "binding_policy: {}"
    echo "workflow_policy:"
    echo "  enforce_allowed_source_roots: ${enforce}"
    if [ -n "${extra_roots}" ]; then
      echo "  allowed_source_roots:"
      printf '%s\n' "${extra_roots}" | while IFS= read -r root; do
        [ -z "${root}" ] && continue
        echo "    - ${root}"
      done
    else
      echo "  allowed_source_roots: []"
    fi
  } > "${BUILTIN_BASE}/.cap.constitution.yaml"
}

# Builtin skill registry (always present).
write_builtin_skills() {
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
}

# Workflow under builtin layer.
write_builtin_workflow() {
  cat > "${BUILTIN_BASE}/schemas/workflows/wf.yaml" <<'EOF'
schema_version: 1
workflow_id: wf
name: wf
version: 1
summary: focused source-roots enforcement fixture
triggers: []
steps:
  - id: ai_step
    name: ai_step
    capability: test_capability
    executor: ai
EOF
}

# run_bind <python_expr_after_bind> [<workflow_ref>]
# Run binder, evaluate expr against the binding (or surface the typed
# exception class). Outputs whatever expr prints.
run_bind() {
  local expr="$1" wf_ref="${2:-wf}"
  PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${BUILTIN_BASE}" "${PROJECT_ROOT}" "${CAP_HOME_DIR}" "${wf_ref}" "${expr}" <<'PY'
import json
import sys
from pathlib import Path

from engine.runtime_binder import (
    RuntimeBinder,
    SkillSourcePolicyError,
    SourcePolicyError,
    WorkflowSourcePolicyError,
)

builtin_base, project_root, cap_home_dir, wf_ref, expr = sys.argv[1:6]
binder = RuntimeBinder(
    base_dir=Path(builtin_base),
    project_root=Path(project_root),
    cap_home=Path(cap_home_dir),
)
try:
    binding = binder.bind_capabilities(wf_ref)
    ctx = {"binding": binding}
    print(eval(expr, ctx))
except WorkflowSourcePolicyError as exc:
    print("RAISE:WorkflowSourcePolicyError:" + exc.stage + ":" + exc.errors[0])
except SkillSourcePolicyError as exc:
    print("RAISE:SkillSourcePolicyError:" + exc.stage + ":" + exc.errors[0])
except SourcePolicyError as exc:  # pragma: no cover — defensive base catch
    print("RAISE:SourcePolicyError:" + exc.stage + ":" + exc.errors[0])
PY
}

# ── Shared fixture writes (re-used across cases) ──────────────────────

write_builtin_skills
write_builtin_workflow

# ── Case 1: enforce=false → both gates skip ───────────────────────────

echo "Case 1: enforce=false → no enforcement, effective_allowed_roots=[]"
write_constitution "false"

assert_eq "case1: binding_status=ready" "ready" \
  "$(run_bind 'binding["binding_status"]')"
assert_eq "case1: effective_allowed_roots=[]" "[]" \
  "$(run_bind 'binding["effective_allowed_roots"]')"
assert_eq "case1: ai_step skill_source.source_layer=builtin" "builtin" \
  "$(run_bind '[s for s in binding["steps"] if s["step_id"]=="ai_step"][0]["skill_source"]["source_layer"]')"

# ── Case 2: enforce=true + canonical project / builtin paths → pass ──

echo ""
echo "Case 2: enforce=true + canonical paths covered by implicit defaults → pass"
write_constitution "true"

assert_eq "case2: binding_status=ready (implicit defaults cover builtin skill)" "ready" \
  "$(run_bind 'binding["binding_status"]')"

# effective_allowed_roots should include implicit project + builtin paths.
EFFECTIVE_LIST="$(run_bind 'binding["effective_allowed_roots"]')"
assert_contains "case2: effective list mentions builtin schemas/workflows" \
  "${EFFECTIVE_LIST}" "${BUILTIN_BASE}/schemas/workflows"
assert_contains "case2: effective list mentions builtin .cap/skills.yaml" \
  "${EFFECTIVE_LIST}" "${BUILTIN_BASE}/.cap/skills.yaml"
assert_contains "case2: effective list mentions project .cap/skills.yaml" \
  "${EFFECTIVE_LIST}" "${PROJECT_ROOT}/.cap/skills.yaml"

# ── Case 3: enforce=true + shared skill not in user list → halt ──────

echo ""
echo "Case 3: enforce=true + shared skill (not in implicit defaults) → SkillSourcePolicyError"
# Stage a shared skill that the binder will pick (no project / builtin
# competitor for the new capability).
cat > "${CAP_HOME_DIR}/shared/skills.yaml" <<'EOF'
schema_version: 1
default_provider: shared
skills:
  - skill_id: shared-only-skill
    provider: claude
    enabled: true
    priority: 100
    compatible_workflow_versions: []
    provided_capabilities: [shared_only_capability]
    fallback_roles: []
    agent_alias: test-agent
    prompt_file: agent-skills/00-core-protocol.md
    cli: claude
EOF
# Add shared_only_capability to the capability dictionary so the
# semantic plan loader doesn't put it on contract_missing_steps.
cat >> "${BUILTIN_BASE}/schemas/capabilities.yaml" <<'EOF'
  shared_only_capability:
    summary: provided only by shared layer
    default_agent: test-agent
    allowed_agents: [test-agent]
    inputs: []
    outputs: []
EOF
# Workflow that needs shared_only_capability so the binder selects the
# shared skill.
cat > "${BUILTIN_BASE}/schemas/workflows/wf-shared.yaml" <<'EOF'
schema_version: 1
workflow_id: wf-shared
name: wf-shared
version: 1
summary: forces shared layer selection
triggers: []
steps:
  - id: shared_step
    name: shared_step
    capability: shared_only_capability
    executor: ai
EOF

write_constitution "true"  # no shared root in user-declared

OUT3="$(run_bind 'binding["binding_status"]' 'wf-shared')"
assert_contains "case3: SkillSourcePolicyError raised" "${OUT3}" \
  "RAISE:SkillSourcePolicyError"
assert_contains "case3: stage tag=skill_source_policy" "${OUT3}" \
  "skill_source_policy"
assert_contains "case3: error mentions shared skills.yaml" "${OUT3}" \
  "${CAP_HOME_DIR}/shared/skills.yaml"

# ── Case 4: enforce=true + user adds shared root → pass ──────────────

echo ""
echo "Case 4: shared root explicitly declared in constitution → pass"
write_constitution "true" "${CAP_HOME_DIR}/shared/skills.yaml"

assert_eq "case4: binding_status=ready" "ready" \
  "$(run_bind 'binding["binding_status"]' 'wf-shared')"
assert_eq "case4: shared_step skill_source.source_layer=shared" "shared" \
  "$(run_bind '[s for s in binding["steps"] if s["step_id"]=="shared_step"][0]["skill_source"]["source_layer"]' 'wf-shared')"

# ── Case 5: workflow gate fires before skill gate ────────────────────

echo ""
echo "Case 5: workflow source outside effective set → WorkflowSourcePolicyError before skill gate"
# Plant a workflow at an absolute path outside any layer root and
# outside user-declared list.
EXTERNAL_DIR="${SANDBOX}/external"
mkdir -p "${EXTERNAL_DIR}"
cat > "${EXTERNAL_DIR}/wf-external.yaml" <<'EOF'
schema_version: 1
workflow_id: wf-external
name: wf-external
version: 1
summary: external (explicit-layer) workflow
triggers: []
steps:
  - id: ai_step
    name: ai_step
    capability: test_capability
    executor: ai
EOF

# Constitution still does NOT list ${EXTERNAL_DIR}.
write_constitution "true"

# Pass absolute path to bind_capabilities; resolver tags it as
# source_layer=explicit and gate must fire first.
OUT5="$(run_bind 'binding["binding_status"]' "${EXTERNAL_DIR}/wf-external.yaml")"
assert_contains "case5: WorkflowSourcePolicyError raised" "${OUT5}" \
  "RAISE:WorkflowSourcePolicyError"
assert_contains "case5: stage tag=workflow_source_policy" "${OUT5}" \
  "workflow_source_policy"
assert_contains "case5: error mentions external workflow path" "${OUT5}" \
  "${EXTERNAL_DIR}/wf-external.yaml"

# ── Case 6: exception class hierarchy ────────────────────────────────

echo ""
echo "Case 6: SourcePolicyError base catches both subclasses"
HIERARCHY_OUT="$(PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - <<'PY'
from engine.runtime_binder import (
    SkillSourcePolicyError,
    SourcePolicyError,
    WorkflowSourcePolicyError,
)
print("workflow_subclass=" + str(issubclass(WorkflowSourcePolicyError, SourcePolicyError)))
print("skill_subclass=" + str(issubclass(SkillSourcePolicyError, SourcePolicyError)))
print("workflow_init_kwargs:", WorkflowSourcePolicyError("m", stage="x", errors=["a"]).stage)
print("skill_init_kwargs:", SkillSourcePolicyError("m", stage="y", errors=["b"]).stage)
PY
)"
assert_contains "case6: WorkflowSourcePolicyError <: SourcePolicyError" "${HIERARCHY_OUT}" "workflow_subclass=True"
assert_contains "case6: SkillSourcePolicyError <: SourcePolicyError"   "${HIERARCHY_OUT}" "skill_subclass=True"
assert_contains "case6: workflow stage carry-through" "${HIERARCHY_OUT}" "workflow_init_kwargs: x"
assert_contains "case6: skill stage carry-through"    "${HIERARCHY_OUT}" "skill_init_kwargs: y"

# ── Case 7: effective_allowed_roots ordering (user-declared first) ──

echo ""
echo "Case 7: effective_allowed_roots lists user-declared before implicit"
write_constitution "true" "/some/explicit/user/path"

ORDER_OUT="$(PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${BUILTIN_BASE}" "${PROJECT_ROOT}" "${CAP_HOME_DIR}" <<'PY'
import sys
from pathlib import Path
from engine.runtime_binder import RuntimeBinder

builtin_base, project_root, cap_home_dir = sys.argv[1:4]
binder = RuntimeBinder(
    base_dir=Path(builtin_base),
    project_root=Path(project_root),
    cap_home=Path(cap_home_dir),
)
binding = binder.bind_capabilities("wf")
roots = binding["effective_allowed_roots"]
print("first=" + roots[0])
print("count=" + str(len(roots)))
PY
)"
assert_contains "case7: user-declared root first" "${ORDER_OUT}" "first=/some/explicit/user/path"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
