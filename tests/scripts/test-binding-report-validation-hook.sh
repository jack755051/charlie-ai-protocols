#!/usr/bin/env bash
#
# test-binding-report-validation-hook.sh — P4 #2 gate.
#
# Verifies that engine.task_scoped_compiler hooks
# engine.binding_report_validator.ensure_valid_binding_report after
# RuntimeBinder.bind_semantic_plan in both compile_task() and
# compile_task_from_envelope(), and that engine.workflow_cli.cmd_compile_json
# surfaces the failure as a deterministic JSON error (exit 1).
#
# Coverage (inline-Python, no YAML fixtures):
#   Case 1 happy:               compile_task returns a binding report
#                               with schema_version: 1 and the 6
#                               required top-level fields.
#   Case 2 missing schema_version: monkey-patched bind_semantic_plan
#                                  drops schema_version → raises
#                                  BindingReportSchemaError(stage='post_bind').
#   Case 3 bad binding_status enum: bind returns binding_status='weird'
#                                   → raises with stage='post_bind'.
#   Case 4 bad summary shape:   bind returns summary missing
#                               resolved_steps → raises (nested required).
#   Case 5 halt-before-bound:   binding fails post_bind → downstream
#                               build_bound_execution_phases_from_workflow
#                               is NOT invoked.
#   Case 6 envelope path:       compile_task_from_envelope inherits the
#                               same hook → bad binding raises with
#                               stage='post_bind'.
#   Case 7 CLI contract:        cmd_compile_json prints
#                               {"ok": false, "error": "binding_report_schema_error",
#                                "stage": "...", "errors": [...]} on
#                               schema fail and exits 1.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

[ -f "${REPO_ROOT}/engine/task_scoped_compiler.py" ] || {
  echo "FAIL: engine/task_scoped_compiler.py missing"; exit 1;
}
[ -f "${REPO_ROOT}/engine/binding_report_validator.py" ] || {
  echo "FAIL: engine/binding_report_validator.py missing"; exit 1;
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
echo "Case 1: happy path → binding report has 6 required fields + schema_version"
out1="$(run_py "
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler
c = TaskScopedWorkflowCompiler()
result = c.compile_task('add new feature for testing')
b = result['binding']
required = {'schema_version','workflow_id','workflow_version','binding_status','summary','steps'}
missing = sorted(required - set(b.keys()))
print('missing=' + ','.join(missing) if missing else 'all_required_present')
print('schema_version=' + str(b.get('schema_version')))
print('binding_status=' + str(b.get('binding_status')))
")"
assert_contains "all 6 required fields present" "all_required_present" "${out1}"
assert_contains "schema_version=1"              "schema_version=1"     "${out1}"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: missing schema_version → halt at post_bind"
out2="$(run_py "
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler
from engine.binding_report_validator import BindingReportSchemaError
c = TaskScopedWorkflowCompiler()
orig = c.binder.bind_semantic_plan
def patched(*a, **kw):
    b = orig(*a, **kw)
    b.pop('schema_version', None)
    return b
c.binder.bind_semantic_plan = patched
try:
    c.compile_task('add new feature for testing')
    print('NO_RAISE')
except BindingReportSchemaError as exc:
    print('stage=' + exc.stage)
    print('error_head=' + exc.errors[0])
")"
assert_contains "raised at post_bind"           "stage=post_bind"                                  "${out2}"
assert_contains "missing-field error surfaced"  "missing required field 'schema_version'"          "${out2}"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: binding_status not in enum → halt at post_bind"
out3="$(run_py "
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler
from engine.binding_report_validator import BindingReportSchemaError
c = TaskScopedWorkflowCompiler()
orig = c.binder.bind_semantic_plan
def patched(*a, **kw):
    b = orig(*a, **kw)
    b['binding_status'] = 'weird'
    return b
c.binder.bind_semantic_plan = patched
try:
    c.compile_task('add new feature for testing')
    print('NO_RAISE')
except BindingReportSchemaError as exc:
    print('stage=' + exc.stage)
    for e in exc.errors:
        if 'binding_status' in e and ('enum' in e.lower() or 'weird' in e):
            print('binding_status_error_present')
            break
")"
assert_contains "raised at post_bind"            "stage=post_bind"               "${out3}"
assert_contains "binding_status enum violation"  "binding_status_error_present"  "${out3}"

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: summary missing nested required (resolved_steps) → halt at post_bind"
out4="$(run_py "
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler
from engine.binding_report_validator import BindingReportSchemaError
c = TaskScopedWorkflowCompiler()
orig = c.binder.bind_semantic_plan
def patched(*a, **kw):
    b = orig(*a, **kw)
    b['summary'].pop('resolved_steps', None)
    return b
c.binder.bind_semantic_plan = patched
try:
    c.compile_task('add new feature for testing')
    print('NO_RAISE')
except BindingReportSchemaError as exc:
    print('stage=' + exc.stage)
    for e in exc.errors:
        if 'summary' in e and 'resolved_steps' in e:
            print('summary_required_error_present')
            break
")"
assert_contains "raised at post_bind"             "stage=post_bind"                  "${out4}"
assert_contains "summary nested required surfaced" "summary_required_error_present" "${out4}"

# ── Case 5 ──────────────────────────────────────────────────────────────
echo "Case 5: binding schema fail → bound phases NOT invoked"
out5="$(run_py "
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler
from engine.binding_report_validator import BindingReportSchemaError
c = TaskScopedWorkflowCompiler()

orig_bind = c.binder.bind_semantic_plan
def bad_bind(*a, **kw):
    b = orig_bind(*a, **kw)
    b.pop('schema_version', None)
    return b
c.binder.bind_semantic_plan = bad_bind

called = {'bound_phases': False}
orig_bound = c.binder.build_bound_execution_phases_from_workflow
def trace_bound(*a, **kw):
    called['bound_phases'] = True
    return orig_bound(*a, **kw)
c.binder.build_bound_execution_phases_from_workflow = trace_bound

try:
    c.compile_task('add new feature for testing')
    print('NO_RAISE')
except BindingReportSchemaError as exc:
    print('stage=' + exc.stage)
    print('bound_phases_called=' + str(called['bound_phases']))
")"
assert_contains "raised at post_bind"        "stage=post_bind"             "${out5}"
assert_contains "bound phases NOT invoked"    "bound_phases_called=False"   "${out5}"

# ── Case 6 ──────────────────────────────────────────────────────────────
echo "Case 6: envelope path inherits the hook → halt at post_bind"
out6="$(run_py "
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler
from engine.binding_report_validator import BindingReportSchemaError
c = TaskScopedWorkflowCompiler()

orig = c.binder.bind_semantic_plan
def patched(*a, **kw):
    b = orig(*a, **kw)
    b.pop('schema_version', None)
    return b
c.binder.bind_semantic_plan = patched

envelope = {
  'schema_version': 1,
  'task_id': 'env-binding-hook',
  'source_request': 'envelope binding hook smoke',
  'produced_at': '2026-05-04T00:00:00Z',
  'supervisor_role': '01-Supervisor',
  'task_constitution': {
    'task_id': 'env-binding-hook',
    'project_id': 'charlie-ai-protocols',
    'source_request': 'envelope binding hook smoke',
    'goal': 'verify envelope path binding hook',
    'goal_stage': 'informal_planning',
    'success_criteria': ['validation hook fires'],
    'non_goals': [],
    'execution_plan': [
      {'step_id': 'plan', 'capability': 'task_constitution_planning'}
    ],
  },
  'capability_graph': {
    'task_id': 'env-binding-hook',
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
except BindingReportSchemaError as exc:
    print('stage=' + exc.stage)
")"
assert_contains "envelope path raises at post_bind" "stage=post_bind" "${out6}"

# ── Case 7 ──────────────────────────────────────────────────────────────
echo "Case 7: cmd_compile_json on binding schema fail → JSON error + exit 1"
out7="$(REPO_ROOT="${REPO_ROOT}" python3 - <<'PY' 2>&1
import json
import sys
from pathlib import Path

import os
repo_root = Path(os.environ['REPO_ROOT'])
sys.path.insert(0, str(repo_root))

from engine.runtime_binder import RuntimeBinder  # noqa: E402

orig_bind = RuntimeBinder.bind_semantic_plan
def broken(self, *a, **kw):
    b = orig_bind(self, *a, **kw)
    b.pop('schema_version', None)
    return b
RuntimeBinder.bind_semantic_plan = broken

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
assert_contains "error tag matches contract"   "error=binding_report_schema_error"        "${out7}"
assert_contains "stage=post_bind"              "stage=post_bind"                          "${out7}"

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "binding-report-validation-hook: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
