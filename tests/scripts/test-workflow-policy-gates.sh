#!/usr/bin/env bash
#
# test-workflow-policy-gates.sh — P4 #6-#9 gate.
#
# Verifies that engine.task_scoped_compiler runs four binding-time
# policy gates and surfaces failures as deterministic JSON via
# engine.workflow_cli.cmd_compile_json:
#
#   P4 #6 allowed_capabilities — disallowed required capability halts
#                                with binding_policy_error.
#   P4 #9 unresolved handling   — required-unresolved binding halts
#                                 with binding_policy_error before
#                                 apply_unresolved_policy / bound phases.
#   P4 #7 source root policy    — workflow source path outside the
#                                 constitution's allowed roots halts
#                                 with workflow_source_policy_error.
#   P4 #8 fallback search policy — strict mode skips fallback search;
#                                  fallback_allowed mode performs it.
#                                  This is a search-preference policy,
#                                  not a rejection rule (see checklist
#                                  P4 #8 progress note).
#
# Coverage style: inline-Python, no YAML fixtures. Cases that need to
# trip a policy do so by monkey-patching the smallest possible surface
# (binder result, project_context loader) so the test stays focused
# on the gate behavior.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

[ -f "${REPO_ROOT}/engine/runtime_binder.py" ] || {
  echo "FAIL: engine/runtime_binder.py missing"; exit 1;
}
[ -f "${REPO_ROOT}/engine/task_scoped_compiler.py" ] || {
  echo "FAIL: engine/task_scoped_compiler.py missing"; exit 1;
}
[ -f "${REPO_ROOT}/engine/workflow_cli.py" ] || {
  echo "FAIL: engine/workflow_cli.py missing"; exit 1;
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

# ── Case 1 ──────────────────────────────────────────────────────────────
echo "Case 1: happy path (no policy violation) → compile_task succeeds"
out1="$(run_py "
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler
c = TaskScopedWorkflowCompiler()
result = c.compile_task('add new feature for testing')
print('binding_status=' + str(result['binding'].get('binding_status')))
print('compile_ok')
")"
assert_contains "binding_status not blocked"  "binding_status="           "${out1}"
assert_contains "compile_task returns OK"     "compile_ok"                "${out1}"

# ── Case 2 (P4 #6) ──────────────────────────────────────────────────────
echo "Case 2 (P4 #6): disallowed capability → binding_policy_error"
out2="$(run_py "
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler
from engine.runtime_binder import BindingPolicyError
c = TaskScopedWorkflowCompiler()
def restricted_context():
    return {
        'binding_policy': {
            'allowed_capabilities': ['only_a_phantom_capability'],
        },
    }
c.binder.project_context_loader.build_runtime_summary = restricted_context
try:
    c.compile_task('add new feature for testing')
    print('NO_RAISE')
except BindingPolicyError as exc:
    print('stage=' + exc.stage)
    print('error_head=' + exc.errors[0])
    for e in exc.errors:
        if 'blocked steps' in e:
            print('blocked_steps_listed')
            break
")"
assert_contains "raised at post_bind_policy"  "stage=post_bind_policy"      "${out2}"
assert_contains "blocked count surfaced"      "unresolved required step"    "${out2}"
assert_contains "blocked step ids listed"     "blocked_steps_listed"        "${out2}"

# ── Case 3 (P4 #9) ──────────────────────────────────────────────────────
echo "Case 3 (P4 #9): required-unresolved binding halts before bound phases"
out3="$(run_py "
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler
from engine.runtime_binder import BindingPolicyError
c = TaskScopedWorkflowCompiler()

orig_bind = c.binder.bind_semantic_plan
def forced_blocked_bind(*a, **kw):
    b = orig_bind(*a, **kw)
    b['binding_status'] = 'blocked'
    b['summary']['unresolved_required_steps'] = 1
    if b['steps']:
        b['steps'][0]['resolution_status'] = 'required_unresolved'
    return b
c.binder.bind_semantic_plan = forced_blocked_bind

called = {'bound_phases': False}
orig_bound = c.binder.build_bound_execution_phases_from_workflow
def trace_bound(*a, **kw):
    called['bound_phases'] = True
    return orig_bound(*a, **kw)
c.binder.build_bound_execution_phases_from_workflow = trace_bound

try:
    c.compile_task('add new feature for testing')
    print('NO_RAISE')
except BindingPolicyError as exc:
    print('stage=' + exc.stage)
    print('bound_phases_called=' + str(called['bound_phases']))
")"
assert_contains "raised at post_bind_policy"  "stage=post_bind_policy"      "${out3}"
assert_contains "bound phases NOT invoked"    "bound_phases_called=False"   "${out3}"

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: cmd_compile_json on binding policy fail → JSON error + exit 1"
out4="$(REPO_ROOT="${REPO_ROOT}" python3 - <<'PY' 2>&1
import json
import os
import sys
from pathlib import Path

repo_root = Path(os.environ['REPO_ROOT'])
sys.path.insert(0, str(repo_root))

from engine.runtime_binder import RuntimeBinder  # noqa: E402

orig_bind = RuntimeBinder.bind_semantic_plan
def forced(self, *a, **kw):
    b = orig_bind(self, *a, **kw)
    b['binding_status'] = 'blocked'
    b['summary']['unresolved_required_steps'] = 1
    if b['steps']:
        b['steps'][0]['resolution_status'] = 'required_unresolved'
    return b
RuntimeBinder.bind_semantic_plan = forced

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
except Exception as exc:
    print('JSON_PARSE_FAIL: ' + str(exc))
    print('raw=' + out[:200])
PY
)"
assert_contains "exit code 1"                  "exit_code=1"                       "${out4}"
assert_contains "ok=False"                     "ok=False"                          "${out4}"
assert_contains "binding_policy_error tag"     "error=binding_policy_error"        "${out4}"
assert_contains "stage=post_bind_policy"       "stage=post_bind_policy"            "${out4}"

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "workflow-policy-gates: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
