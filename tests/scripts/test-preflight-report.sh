#!/usr/bin/env bash
#
# test-preflight-report.sh — P4 #10 gate.
#
# Verifies engine.preflight_report.build_preflight_report and that
# engine.task_scoped_compiler.compile_task / compile_task_from_envelope
# return a `preflight_report` key in their output dict that satisfies
# schemas/preflight-report.schema.yaml.
#
# Coverage (inline-Python, no YAML fixtures):
#   Case 1 happy:                compile_task happy path → preflight has
#                                schema_version=1, is_executable=True,
#                                binding_status='ready', empty warnings
#                                and blocking_reasons.
#   Case 2 envelope path:        compile_task_from_envelope returns the
#                                same preflight shape on its happy path.
#   Case 3 schema validation:    preflight_report passes
#                                schemas/preflight-report.schema.yaml
#                                via step_runtime.validate-jsonschema.
#   Case 4 optional unresolved:  monkey-patched binding bumps
#                                summary.unresolved_optional_steps and
#                                marks a step optional_unresolved →
#                                preflight surfaces a warning but stays
#                                is_executable=True (binding_status not
#                                'blocked').
#   Case 5 fallback step:        monkey-patched binding marks a step
#                                fallback_available with selected_skill_id
#                                'generic-X' → preflight warning
#                                identifies the step + skill.
#   Case 6 blocked deterministic halt: monkey-patched binding flagged as
#                                      blocked → BindingPolicyError raised
#                                      before build_preflight_report runs;
#                                      no preflight_report leaks into the
#                                      caller path (verified by no
#                                      preflight key in caught state).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

[ -f "${REPO_ROOT}/engine/preflight_report.py" ] || {
  echo "FAIL: engine/preflight_report.py missing"; exit 1;
}
[ -f "${REPO_ROOT}/schemas/preflight-report.schema.yaml" ] || {
  echo "FAIL: schemas/preflight-report.schema.yaml missing"; exit 1;
}

PYTHON_BIN="python3"

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

run_py() {
  local code="$1"
  ( cd "${REPO_ROOT}" && python3 -c "${code}" 2>&1 )
}

# ── Case 1 ──────────────────────────────────────────────────────────────
echo "Case 1: compile_task happy path → preflight is_executable=True, ready"
out1="$(run_py "
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler
c = TaskScopedWorkflowCompiler()
result = c.compile_task('add new feature for testing')
pf = result['preflight_report']
required = {'schema_version','workflow_id','binding_status','is_executable','gates','unresolved_summary','warnings','blocking_reasons'}
missing = sorted(required - set(pf.keys()))
print('missing=' + ','.join(missing) if missing else 'all_required_present')
print('schema_version=' + str(pf['schema_version']))
print('is_executable=' + str(pf['is_executable']))
print('binding_status=' + pf['binding_status'])
print('warnings_count=' + str(len(pf['warnings'])))
print('blocking_count=' + str(len(pf['blocking_reasons'])))
print('gates_keys=' + ','.join(sorted(pf['gates'].keys())))
")"
assert_contains "all 8 required fields present" "all_required_present"  "${out1}"
assert_contains "schema_version=1"              "schema_version=1"      "${out1}"
assert_contains "is_executable=True"            "is_executable=True"    "${out1}"
assert_contains "binding_status=ready"          "binding_status=ready"  "${out1}"
assert_contains "no warnings on happy path"     "warnings_count=0"      "${out1}"
assert_contains "no blocking reasons"           "blocking_count=0"      "${out1}"
assert_contains "all 4 gates present"           "gates_keys=binding_policy,binding_report_schema,compiled_workflow_schema,source_root_policy" "${out1}"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: compile_task_from_envelope → same preflight shape"
out2="$(run_py "
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler
c = TaskScopedWorkflowCompiler()
envelope = {
  'schema_version': 1,
  'task_id': 'env-preflight-happy',
  'source_request': 'envelope preflight smoke',
  'produced_at': '2026-05-04T00:00:00Z',
  'supervisor_role': '01-Supervisor',
  'task_constitution': {
    'task_id': 'env-preflight-happy',
    'project_id': 'charlie-ai-protocols',
    'source_request': 'envelope preflight smoke',
    'goal': 'verify envelope preflight',
    'goal_stage': 'informal_planning',
    'success_criteria': ['preflight built'],
    'non_goals': [],
    'execution_plan': [{'step_id': 'plan', 'capability': 'task_constitution_planning'}],
  },
  'capability_graph': {
    'task_id': 'env-preflight-happy',
    'goal_stage': 'informal_planning',
    'nodes': [{'step_id': 'plan', 'capability': 'task_constitution_planning',
               'required': True, 'depends_on': [], 'reason': 'plan'}],
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
result = c.compile_task_from_envelope(envelope)
pf = result['preflight_report']
print('schema_version=' + str(pf['schema_version']))
print('is_executable=' + str(pf['is_executable']))
print('workflow_id=' + pf['workflow_id'])
")"
assert_contains "envelope preflight schema_version" "schema_version=1"     "${out2}"
assert_contains "envelope preflight is_executable"  "is_executable=True"   "${out2}"
assert_contains "envelope preflight workflow_id"    "workflow_id=compiled-env-preflight-happy" "${out2}"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: preflight_report satisfies preflight-report.schema.yaml"
SANDBOX="$(mktemp -d -t cap-preflight-test.XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT
PREFLIGHT_PATH="${SANDBOX}/preflight.json"
( cd "${REPO_ROOT}" && python3 -c "
import json
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler
c = TaskScopedWorkflowCompiler()
result = c.compile_task('add new feature for testing')
with open('${PREFLIGHT_PATH}', 'w') as fh:
    json.dump(result['preflight_report'], fh)
" )
schema_check_exit=0
( cd "${REPO_ROOT}" && "${PYTHON_BIN}" engine/step_runtime.py validate-jsonschema "${PREFLIGHT_PATH}" "${REPO_ROOT}/schemas/preflight-report.schema.yaml" >/dev/null 2>&1 ) || schema_check_exit=$?
assert_eq "preflight passes schema gate" "0" "${schema_check_exit}"

# Cases 4 / 5 unit-test build_preflight_report directly so they do not
# trigger compile_task's apply_unresolved_policy step-removal side effect
# (which would orphan governance checkpoints and ValueError on the next
# normalize). The builder contract is the focus here, not the full pipeline.

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: optional unresolved → warning surfaced, is_executable=True"
out4="$(run_py "
from engine.preflight_report import build_preflight_report
compiled_workflow = {'workflow_id': 'wf-degraded-optional'}
binding = {
  'binding_status': 'degraded',
  'summary': {
    'total_steps': 3,
    'resolved_steps': 2,
    'fallback_steps': 0,
    'unresolved_optional_steps': 1,
  },
  'steps': [
    {'step_id': 'opt-step', 'optional': True, 'resolution_status': 'optional_unresolved'},
  ],
}
pf = build_preflight_report(compiled_workflow, binding)
print('is_executable=' + str(pf['is_executable']))
print('binding_status=' + pf['binding_status'])
print('warnings_count=' + str(len(pf['warnings'])))
for w in pf['warnings']:
    if 'optional' in w.lower():
        print('optional_warning_present')
        break
print('blocking_count=' + str(len(pf['blocking_reasons'])))
print('summary_optional=' + str(pf['unresolved_summary']['unresolved_optional_steps']))
")"
assert_contains "is_executable still True"        "is_executable=True"             "${out4}"
assert_contains "binding_status=degraded"          "binding_status=degraded"       "${out4}"
assert_contains "optional warning surfaced"        "optional_warning_present"      "${out4}"
assert_contains "no blocking reasons"              "blocking_count=0"              "${out4}"
assert_contains "summary count propagated"         "summary_optional=1"            "${out4}"

# ── Case 5 ──────────────────────────────────────────────────────────────
echo "Case 5: fallback step → warning identifies step and selected skill"
out5="$(run_py "
from engine.preflight_report import build_preflight_report
compiled_workflow = {'workflow_id': 'wf-fallback'}
binding = {
  'binding_status': 'degraded',
  'summary': {
    'total_steps': 3,
    'resolved_steps': 2,
    'fallback_steps': 1,
    'unresolved_optional_steps': 0,
  },
  'steps': [
    {'step_id': 'plan-step', 'optional': False,
     'resolution_status': 'fallback_available',
     'selected_skill_id': 'generic-planner'},
  ],
}
pf = build_preflight_report(compiled_workflow, binding)
print('is_executable=' + str(pf['is_executable']))
print('warnings_count=' + str(len(pf['warnings'])))
for w in pf['warnings']:
    if 'generic-planner' in w and 'plan-step' in w:
        print('fallback_step_and_skill_in_warning')
        break
print('summary_fallback=' + str(pf['unresolved_summary']['fallback_steps']))
")"
assert_contains "is_executable=True under degraded"      "is_executable=True"                  "${out5}"
assert_contains "fallback step + skill named in warning" "fallback_step_and_skill_in_warning"  "${out5}"
assert_contains "fallback summary count propagated"      "summary_fallback=1"                  "${out5}"

# ── Case 6 ──────────────────────────────────────────────────────────────
echo "Case 6: blocked binding → halt before preflight (no preflight key produced)"
out6="$(run_py "
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler
from engine.runtime_binder import BindingPolicyError
c = TaskScopedWorkflowCompiler()

orig = c.binder.bind_semantic_plan
def patched(*a, **kw):
    b = orig(*a, **kw)
    b['binding_status'] = 'blocked'
    b['summary']['unresolved_required_steps'] = 1
    if b['steps']:
        b['steps'][0]['resolution_status'] = 'required_unresolved'
    return b
c.binder.bind_semantic_plan = patched

try:
    result = c.compile_task('add new feature for testing')
    print('NO_RAISE')
    print('preflight_in_result=' + str('preflight_report' in result))
except BindingPolicyError as exc:
    print('halted_at_stage=' + exc.stage)
    print('preflight_never_built')
")"
assert_contains "blocked halts via BindingPolicyError" "halted_at_stage=post_bind_policy" "${out6}"
assert_contains "preflight never built when blocked"   "preflight_never_built"            "${out6}"

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "preflight-report: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
