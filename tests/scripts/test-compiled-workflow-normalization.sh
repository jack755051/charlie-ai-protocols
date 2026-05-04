#!/usr/bin/env bash
#
# test-compiled-workflow-normalization.sh — P4 #4 gate.
#
# Verifies engine.workflow_loader.WorkflowLoader.normalize_workflow_data
# converts the backward-compatible ``depends_on`` step alias into the
# canonical ``needs`` field, while strictly refusing to fill in any
# required compiled-workflow schema field (so producer-level fixes
# from P4 #1 cannot be silently masked by normalization).
#
# Coverage (inline-Python, no YAML fixtures):
#   Case 1 canonical needs unchanged: a step that already declares
#                                     ``needs`` retains the same value
#                                     and the alias never overwrites it.
#   Case 2 depends_on → needs:        a step with ``depends_on`` and no
#                                     ``needs`` gets a ``needs`` field
#                                     equal to the depends_on list.
#   Case 3 needs wins over depends_on: when both are present, ``needs``
#                                      is preserved and ``depends_on``
#                                      is left alone (no overwrite).
#   Case 4 missing schema_version not filled: a workflow stripped of
#                                             ``schema_version`` still
#                                             fails the post_build
#                                             schema gate (normalization
#                                             does not auto-fill).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

[ -f "${REPO_ROOT}/engine/workflow_loader.py" ] || {
  echo "FAIL: engine/workflow_loader.py missing"; exit 1;
}
[ -f "${REPO_ROOT}/engine/task_scoped_compiler.py" ] || {
  echo "FAIL: engine/task_scoped_compiler.py missing"; exit 1;
}

pass_count=0
fail_count=0

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected to contain: ${needle}"
    echo "    actual head: $(printf '%s' "${haystack}" | head -3)"
    fail_count=$((fail_count + 1))
  fi
}

run_py() {
  local code="$1"
  ( cd "${REPO_ROOT}" && python3 -c "${code}" 2>&1 )
}

# Reusable inline payload that satisfies workflow_loader._validate_workflow
# (5 top-level required + 3 step required) so we can exercise the alias
# normalization without tripping the upstream loader gate.
make_payload() {
  cat <<'EOF'
{
  'workflow_id': 'norm-fixture',
  'version': 2,
  'name': 'normalization fixture',
  'summary': 'inline payload for P4 #4 alias smoke',
  'steps': [
    {'id': 'a', 'name': 'A', 'capability': 'task_constitution_planning'},
    {'id': 'b', 'name': 'B', 'capability': 'task_constitution_planning'},
  ],
}
EOF
}

# ── Case 1 ──────────────────────────────────────────────────────────────
echo "Case 1: canonical needs unchanged"
out1="$(run_py "
from engine.workflow_loader import WorkflowLoader
loader = WorkflowLoader()
wf = {
  'workflow_id': 'norm-fixture',
  'version': 2,
  'name': 'normalization fixture',
  'summary': 'canonical needs',
  'steps': [
    {'id': 'a', 'name': 'A', 'capability': 'task_constitution_planning'},
    {'id': 'b', 'name': 'B', 'capability': 'task_constitution_planning', 'needs': ['a']},
  ],
}
out = loader.normalize_workflow_data(wf, '<inline>')
print('a_needs=' + repr(out['steps'][0].get('needs')))
print('b_needs=' + repr(out['steps'][1].get('needs')))
print('a_depends_on=' + repr(out['steps'][0].get('depends_on')))
print('b_depends_on=' + repr(out['steps'][1].get('depends_on')))
")"
assert_contains "step a keeps no needs"             "a_needs=None"          "${out1}"
assert_contains "step b keeps canonical needs=['a']" "b_needs=['a']"        "${out1}"
assert_contains "no depends_on injected"             "a_depends_on=None"    "${out1}"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: depends_on → needs when needs is absent"
out2="$(run_py "
from engine.workflow_loader import WorkflowLoader
loader = WorkflowLoader()
wf = {
  'workflow_id': 'norm-fixture',
  'version': 2,
  'name': 'normalization fixture',
  'summary': 'legacy depends_on',
  'steps': [
    {'id': 'a', 'name': 'A', 'capability': 'task_constitution_planning'},
    {'id': 'b', 'name': 'B', 'capability': 'task_constitution_planning', 'depends_on': ['a']},
  ],
}
out = loader.normalize_workflow_data(wf, '<inline>')
print('b_needs=' + repr(out['steps'][1].get('needs')))
print('b_depends_on_preserved=' + repr(out['steps'][1].get('depends_on')))
")"
assert_contains "depends_on copied to needs"        "b_needs=['a']"             "${out2}"
assert_contains "depends_on preserved on the step"   "b_depends_on_preserved=['a']" "${out2}"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: needs wins when both needs and depends_on present"
out3="$(run_py "
from engine.workflow_loader import WorkflowLoader
loader = WorkflowLoader()
wf = {
  'workflow_id': 'norm-fixture',
  'version': 2,
  'name': 'normalization fixture',
  'summary': 'needs wins',
  'steps': [
    {'id': 'a', 'name': 'A', 'capability': 'task_constitution_planning'},
    {'id': 'b', 'name': 'B', 'capability': 'task_constitution_planning',
     'needs': ['a'], 'depends_on': ['a', 'phantom']},
  ],
}
out = loader.normalize_workflow_data(wf, '<inline>')
print('b_needs=' + repr(out['steps'][1].get('needs')))
")"
assert_contains "needs preserved over depends_on"   "b_needs=['a']" "${out3}"

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: missing schema_version is NOT auto-filled (P4 #1 contract)"
out4="$(run_py "
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler
from engine.compiled_workflow_validator import CompiledWorkflowSchemaError
c = TaskScopedWorkflowCompiler()
orig = c.build_candidate_workflow
def patched(constitution, capability_graph):
    wf = orig(constitution, capability_graph)
    wf.pop('schema_version', None)
    return wf
c.build_candidate_workflow = patched
try:
    c.compile_task('add new feature for testing')
    print('NO_RAISE')
except CompiledWorkflowSchemaError as exc:
    print('stage=' + exc.stage)
    print('error_head=' + exc.errors[0])
")"
assert_contains "halt at post_build (not silently filled)" "stage=post_build" "${out4}"
assert_contains "missing schema_version still surfaced"    "missing required field 'schema_version'" "${out4}"

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "compiled-workflow-normalization: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
