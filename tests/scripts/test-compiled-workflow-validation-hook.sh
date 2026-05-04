#!/usr/bin/env bash
#
# test-compiled-workflow-validation-hook.sh — P4 #1 gate.
#
# Verifies that engine.task_scoped_compiler hooks
# engine.compiled_workflow_validator.ensure_valid_compiled_workflow at
# both producer and post-transform stages, and that
# engine.workflow_cli.cmd_compile_json surfaces the failure as a
# deterministic JSON error (exit 1).
#
# Coverage (inline-Python, no YAML fixtures per the refined plan):
#   Case 1 happy:               compile_task returns a compiled_workflow
#                               that satisfies the 9 required top-level
#                               fields, including schema_version: 1.
#   Case 2 missing field:       monkey-patched build_candidate_workflow
#                               drops schema_version → raises
#                               CompiledWorkflowSchemaError(stage='post_build').
#   Case 3 bad version enum:    build_candidate_workflow returns version=99
#                               → raises with stage='post_build'.
#   Case 4 bad steps shape:     build_candidate_workflow returns steps={}
#                               → raises with stage='post_build'.
#   Case 5 transform corruption: apply_unresolved_policy mutates a valid
#                                workflow into a schema-invalid one →
#                                raises with stage='post_unresolved_policy';
#                                build_bound_execution_phases_from_workflow
#                                is NOT invoked (proves halt-before-bind
#                                semantics).
#   Case 6 envelope path:       compile_task_from_envelope inherits the
#                                same hook → bad producer raises with
#                                stage='post_build'.
#   Case 7 CLI contract:        cmd_compile_json prints
#                               {"ok": false, "error": "compiled_workflow_schema_error",
#                                "stage": "...", "errors": [...]} on
#                               schema fail and exits 1.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

[ -f "${REPO_ROOT}/engine/task_scoped_compiler.py" ] || {
  echo "FAIL: engine/task_scoped_compiler.py missing"; exit 1;
}
[ -f "${REPO_ROOT}/engine/compiled_workflow_validator.py" ] || {
  echo "FAIL: engine/compiled_workflow_validator.py missing"; exit 1;
}
[ -f "${REPO_ROOT}/engine/workflow_cli.py" ] || {
  echo "FAIL: engine/workflow_cli.py missing"; exit 1;
}

pass_count=0
fail_count=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected: ${expected}"
    echo "    actual:   ${actual}"
    fail_count=$((fail_count + 1))
  fi
}

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

# ── Case 1 ──────────────────────────────────────────────────────────────
echo "Case 1: happy path → compiled_workflow has 9 required fields"
out1="$(run_py "
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler
c = TaskScopedWorkflowCompiler()
result = c.compile_task('add new feature for testing')
cw = result['compiled_workflow']
required = {'schema_version','workflow_id','version','name','summary','owner','triggers','governance','steps'}
missing = sorted(required - set(cw.keys()))
print('missing=' + ','.join(missing) if missing else 'all_required_present')
print('schema_version=' + str(cw.get('schema_version')))
print('version=' + str(cw.get('version')))
")"
assert_contains "all 9 required fields present" "all_required_present" "${out1}"
assert_contains "schema_version=1"              "schema_version=1"      "${out1}"
assert_contains "version=2"                     "version=2"             "${out1}"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: missing schema_version → halt at post_build"
out2="$(run_py "
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
assert_contains "raised at post_build"        "stage=post_build"                                  "${out2}"
assert_contains "missing-field error surfaced" "missing required field 'schema_version'"          "${out2}"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: version=99 (enum violation) → halt at post_build"
out3="$(run_py "
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler
from engine.compiled_workflow_validator import CompiledWorkflowSchemaError
c = TaskScopedWorkflowCompiler()
orig = c.build_candidate_workflow
def patched(constitution, capability_graph):
    wf = orig(constitution, capability_graph)
    wf['version'] = 99
    return wf
c.build_candidate_workflow = patched
try:
    c.compile_task('add new feature for testing')
    print('NO_RAISE')
except CompiledWorkflowSchemaError as exc:
    print('stage=' + exc.stage)
    print('errors_count=' + str(len(exc.errors)))
    for e in exc.errors:
        if 'version' in e and 'enum' in e.lower() or '99' in e:
            print('version_error_present')
            break
")"
assert_contains "raised at post_build"  "stage=post_build"          "${out3}"
assert_contains "version error present" "version_error_present"     "${out3}"

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: steps shape wrong (object instead of array) → halt at post_build"
out4="$(run_py "
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler
from engine.compiled_workflow_validator import CompiledWorkflowSchemaError
c = TaskScopedWorkflowCompiler()
orig = c.build_candidate_workflow
def patched(constitution, capability_graph):
    wf = orig(constitution, capability_graph)
    wf['steps'] = {'not': 'an array'}
    return wf
c.build_candidate_workflow = patched
try:
    c.compile_task('add new feature for testing')
    print('NO_RAISE')
except CompiledWorkflowSchemaError as exc:
    print('stage=' + exc.stage)
    for e in exc.errors:
        if 'steps' in e and ('array' in e.lower() or 'dict' in e.lower()):
            print('steps_type_error_present')
            break
")"
assert_contains "raised at post_build"   "stage=post_build"            "${out4}"
assert_contains "steps type error"        "steps_type_error_present"    "${out4}"

# ── Case 5 ──────────────────────────────────────────────────────────────
echo "Case 5: transform corrupts workflow → halt at post_unresolved_policy, no bound phases"
out5="$(run_py "
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler
from engine.compiled_workflow_validator import CompiledWorkflowSchemaError
c = TaskScopedWorkflowCompiler()

# Wrap apply_unresolved_policy to corrupt output post-build success.
orig_apply = c.apply_unresolved_policy
def corrupt(workflow_data, unresolved_policy):
    cw = orig_apply(workflow_data, unresolved_policy)
    cw.pop('owner', None)
    return cw
c.apply_unresolved_policy = corrupt

# Trip the bound-phase builder: if the hook lets execution past
# apply_unresolved_policy, build_bound_execution_phases_from_workflow
# would be called and we record it. The hook should halt before that.
called = {'bound_phases': False}
orig_bound = c.binder.build_bound_execution_phases_from_workflow
def trace_bound(*a, **kw):
    called['bound_phases'] = True
    return orig_bound(*a, **kw)
c.binder.build_bound_execution_phases_from_workflow = trace_bound

try:
    c.compile_task('add new feature for testing')
    print('NO_RAISE')
except CompiledWorkflowSchemaError as exc:
    print('stage=' + exc.stage)
    print('bound_phases_called=' + str(called['bound_phases']))
")"
assert_contains "raised at post_unresolved_policy" "stage=post_unresolved_policy"  "${out5}"
assert_contains "bound phases NOT invoked"          "bound_phases_called=False"     "${out5}"

# ── Case 6 ──────────────────────────────────────────────────────────────
echo "Case 6: envelope path inherits the hook → halt at post_build"
out6="$(run_py "
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler
from engine.compiled_workflow_validator import CompiledWorkflowSchemaError
c = TaskScopedWorkflowCompiler()

orig = c.build_candidate_workflow
def patched(constitution, capability_graph):
    wf = orig(constitution, capability_graph)
    wf.pop('schema_version', None)
    return wf
c.build_candidate_workflow = patched

envelope = {
  'schema_version': 1,
  'task_id': 'env-validation-hook',
  'source_request': 'envelope validation hook smoke',
  'produced_at': '2026-05-04T00:00:00Z',
  'supervisor_role': '01-Supervisor',
  'task_constitution': {
    'task_id': 'env-validation-hook',
    'project_id': 'charlie-ai-protocols',
    'source_request': 'envelope validation hook smoke',
    'goal': 'verify envelope path validation hook',
    'goal_stage': 'informal_planning',
    'success_criteria': ['validation hook fires'],
    'non_goals': [],
    'execution_plan': [
      {'step_id': 'plan', 'capability': 'task_constitution_planning'}
    ],
  },
  'capability_graph': {
    'task_id': 'env-validation-hook',
    'goal_stage': 'informal_planning',
    'nodes': [
      {'step_id': 'plan', 'capability': 'task_constitution_planning',
       'required': True, 'depends_on': [], 'reason': 'plan'}
    ],
  },
  'governance': {
    'goal_stage': 'informal_planning',
    'watcher_mode': 'final_only',
    'logger_mode': 'milestone_log',
    'context_mode': 'summary_first',
  },
  'compile_hints': {},
  'failure_routing': {'default_action': 'halt', 'overrides': []},
}
try:
    c.compile_task_from_envelope(envelope)
    print('NO_RAISE')
except CompiledWorkflowSchemaError as exc:
    print('stage=' + exc.stage)
")"
assert_contains "envelope path raises at post_build" "stage=post_build" "${out6}"

# ── Case 7 ──────────────────────────────────────────────────────────────
echo "Case 7: cmd_compile_json on schema fail → JSON error + exit 1"
out7="$(REPO_ROOT="${REPO_ROOT}" python3 - <<'PY' 2>&1
import json
import sys
from pathlib import Path

import os
repo_root = Path(os.environ['REPO_ROOT'])
sys.path.insert(0, str(repo_root))

# Monkey-patch build_candidate_workflow to produce schema-invalid output,
# then drive cmd_compile_json directly to capture its stdout + exit code.
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler  # noqa: E402

orig_build = TaskScopedWorkflowCompiler.build_candidate_workflow
def broken(self, constitution, capability_graph):
    wf = orig_build(self, constitution, capability_graph)
    wf.pop('schema_version', None)
    return wf
TaskScopedWorkflowCompiler.build_candidate_workflow = broken

from engine import workflow_cli  # noqa: E402
import io
buf = io.StringIO()
sys.stdout = buf
exit_code = 0
try:
    workflow_cli.cmd_compile_json(str(repo_root), 'add new feature for testing')
except SystemExit as e:
    exit_code = e.code or 0
sys.stdout = sys.__stdout__
out = buf.getvalue().strip()
print('exit_code=' + str(exit_code))
try:
    payload = json.loads(out)
    print('ok=' + str(payload.get('ok')))
    print('error=' + str(payload.get('error')))
    print('stage=' + str(payload.get('stage')))
    print('errors_count=' + str(len(payload.get('errors') or [])))
except Exception as exc:
    print('JSON_PARSE_FAIL: ' + str(exc))
    print('raw=' + out[:200])
PY
)"
assert_contains "exit code 1"                  "exit_code=1"                              "${out7}"
assert_contains "ok=False"                     "ok=False"                                 "${out7}"
assert_contains "error tag matches contract"   "error=compiled_workflow_schema_error"     "${out7}"
assert_contains "stage=post_build"             "stage=post_build"                         "${out7}"

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "compiled-workflow-validation-hook: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
