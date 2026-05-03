#!/usr/bin/env bash
#
# test-compile-task-from-envelope.sh — Smoke for
# engine.task_scoped_compiler.TaskScopedWorkflowCompiler.compile_task_from_envelope
# (P3 #5-b envelope-driven compile entry).
#
# Coverage scope, per the P3 #5-b ratification (new entry only; legacy
# compile_task untouched; binder kwargs unchanged; no workflow YAML
# wiring; no storage write; no failure routing dispatch):
#
#   Case 0 happy:           valid envelope passes schema + drift,
#                           compile_task_from_envelope returns the
#                           legacy 7-key dict plus a new
#                           compile_hints_applied trace; envelope
#                           authoritative fields (task_id, goal,
#                           goal_stage) end up in the merged
#                           task_constitution unchanged.
#   Case 1 schema invalid:  envelope missing failure_routing required
#                           raises CompileFromEnvelopeError with
#                           "schema validation" in the message; legacy
#                           compile_task is NOT triggered.
#   Case 2 drift detected:  envelope.task_id != task_constitution.task_id
#                           raises CompileFromEnvelopeError with
#                           "drift" in the message.
#   Case 3 legacy untouched: compile_task("plain prompt") still returns
#                           the original 7-key dict (no
#                           compile_hints_applied) and ignores any
#                           envelope-shaped state — proves the new
#                           method is purely additive.
#   Case 4 hint trace:      compile_hints_applied carries the envelope's
#                           compile_hints verbatim (full hints +
#                           registry_preference / notes / etc).
#   Case 5 hint pass-through: envelope with empty compile_hints={} still
#                           returns compile_hints_applied={}, not missing
#                           or None — caller can rely on the key.
#
# Determinism: all cases run in-process via `python3 - <<EOF` against
# the engine module; no AI / no network / no installed cap. Each case
# starts with a fresh TaskScopedWorkflowCompiler() so cross-case state
# cannot leak.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

[ -f "${REPO_ROOT}/engine/task_scoped_compiler.py" ] || {
  echo "FAIL: engine/task_scoped_compiler.py missing"; exit 1;
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

# Run an inline python snippet from REPO_ROOT so engine package imports work.
run_py() {
  local code="$1"
  ( cd "${REPO_ROOT}" && python3 -c "${code}" 2>&1 )
}

# ── Case 0 ──────────────────────────────────────────────────────────────
echo "Case 0: happy path → legacy 7 keys + compile_hints_applied; envelope wins"
out0="$(run_py "
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler
c = TaskScopedWorkflowCompiler()
envelope = {
  'schema_version': 1, 'task_id': 'env-happy', 'source_request': 'envelope happy path',
  'produced_at': '2026-05-03T22:00:00Z', 'supervisor_role': '01-Supervisor',
  'task_constitution': {
    'task_id': 'env-happy', 'project_id': 'p', 'source_request': 'envelope happy path',
    'goal': 'envelope-supplied goal text',
    'goal_stage': 'formal_specification',
    'success_criteria': ['ok'], 'non_goals': [],
    'execution_plan': [{'step_id':'prd','capability':'prd_generation'}]
  },
  'capability_graph': {
    'schema_version': 1, 'task_id': 'env-happy', 'goal_stage': 'formal_specification',
    'nodes': [{'step_id':'prd','capability':'prd_generation','required':True,'depends_on':[],'reason':'scope'}]
  },
  'governance': {'goal_stage':'formal_specification','watcher_mode':'milestone_gate','logger_mode':'milestone_log','context_mode':'summary_first'},
  'compile_hints': {'registry_preference':'project_first','notes':['from-supervisor']},
  'failure_routing': {'default_action':'halt','overrides':[]}
}
out = c.compile_task_from_envelope(envelope)
print('keys=' + ','.join(sorted(out.keys())))
print('task_id=' + out['task_constitution']['task_id'])
print('goal=' + out['task_constitution']['goal'])
print('goal_stage=' + out['task_constitution']['goal_stage'])
print('hints_applied_keys=' + ','.join(sorted(out['compile_hints_applied'].keys())))
print('hints_registry=' + str(out['compile_hints_applied']['registry_preference']))
print('hints_notes=' + str(out['compile_hints_applied']['notes']))
")"
assert_contains "case 0 returns 8-key dict" "keys=binding,capability_graph,compile_hints_applied,compiled_workflow,plan,project_context,task_constitution,unresolved_policy" "${out0}"
assert_contains "case 0 envelope task_id wins" "task_id=env-happy" "${out0}"
assert_contains "case 0 envelope goal wins" "goal=envelope-supplied goal text" "${out0}"
assert_contains "case 0 envelope goal_stage wins" "goal_stage=formal_specification" "${out0}"
assert_contains "case 0 hints registry preference traced" "hints_registry=project_first" "${out0}"
assert_contains "case 0 hints notes preserved" "hints_notes=['from-supervisor']" "${out0}"

# ── Case 1 ──────────────────────────────────────────────────────────────
echo "Case 1: schema-invalid envelope (missing failure_routing) → CompileFromEnvelopeError"
out1="$(run_py "
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler, CompileFromEnvelopeError
c = TaskScopedWorkflowCompiler()
broken = {
  'schema_version': 1, 'task_id': 'env-broken', 'source_request': 'no failure_routing',
  'produced_at': '2026-05-03T22:00:00Z', 'supervisor_role': '01-Supervisor',
  'task_constitution': {
    'task_id': 'env-broken', 'project_id': 'p', 'source_request': 'no failure_routing',
    'goal': 'g', 'goal_stage': 'informal_planning',
    'success_criteria': ['x'], 'non_goals': [],
    'execution_plan': [{'step_id':'prd','capability':'prd_generation'}]
  },
  'capability_graph': {
    'schema_version': 1, 'task_id': 'env-broken', 'goal_stage': 'informal_planning',
    'nodes': [{'step_id':'prd','capability':'prd_generation','required':True,'depends_on':[],'reason':'scope'}]
  },
  'governance': {'goal_stage':'informal_planning','watcher_mode':'final_only','logger_mode':'milestone_log','context_mode':'summary_first'},
  'compile_hints': {}
  # failure_routing intentionally missing
}
try:
    c.compile_task_from_envelope(broken)
    print('UNEXPECTED_PASS')
except CompileFromEnvelopeError as e:
    print('raised=' + str(e)[:200])
")"
assert_contains "case 1 raised CompileFromEnvelopeError" "raised=" "${out1}"
assert_contains "case 1 names schema validation" "schema validation" "${out1}"
assert_contains "case 1 names failure_routing field" "failure_routing" "${out1}"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: drift → CompileFromEnvelopeError"
out2="$(run_py "
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler, CompileFromEnvelopeError
c = TaskScopedWorkflowCompiler()
drift = {
  'schema_version': 1, 'task_id': 'env-X', 'source_request': 'drift demo',
  'produced_at': '2026-05-03T22:00:00Z', 'supervisor_role': '01-Supervisor',
  'task_constitution': {
    'task_id': 'env-Y', 'project_id': 'p', 'source_request': 'drift demo',
    'goal': 'g', 'goal_stage': 'informal_planning',
    'success_criteria': ['x'], 'non_goals': [],
    'execution_plan': [{'step_id':'prd','capability':'prd_generation'}]
  },
  'capability_graph': {
    'schema_version': 1, 'task_id': 'env-X', 'goal_stage': 'informal_planning',
    'nodes': [{'step_id':'prd','capability':'prd_generation','required':True,'depends_on':[],'reason':'scope'}]
  },
  'governance': {'goal_stage':'informal_planning','watcher_mode':'final_only','logger_mode':'milestone_log','context_mode':'summary_first'},
  'compile_hints': {},
  'failure_routing': {'default_action':'halt','overrides':[]}
}
try:
    c.compile_task_from_envelope(drift)
    print('UNEXPECTED_PASS')
except CompileFromEnvelopeError as e:
    print('raised=' + str(e)[:200])
")"
assert_contains "case 2 raised CompileFromEnvelopeError" "raised=" "${out2}"
assert_contains "case 2 names drift" "drift" "${out2}"
assert_contains "case 2 names task_id" "task_id" "${out2}"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: legacy compile_task unchanged → 7-key dict, no compile_hints_applied"
out3="$(run_py "
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler
c = TaskScopedWorkflowCompiler()
result = c.compile_task('plain legacy prompt')
print('keys=' + ','.join(sorted(result.keys())))
print('has_hints=' + str('compile_hints_applied' in result))
print('has_constitution=' + str('task_constitution' in result))
")"
assert_contains "case 3 legacy returns 7 keys" "keys=binding,capability_graph,compiled_workflow,plan,project_context,task_constitution,unresolved_policy" "${out3}"
assert_contains "case 3 legacy has no compile_hints_applied" "has_hints=False" "${out3}"
assert_contains "case 3 legacy still produces task_constitution" "has_constitution=True" "${out3}"

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: full compile_hints round-trip in compile_hints_applied"
out4="$(run_py "
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler
c = TaskScopedWorkflowCompiler()
hints = {
  'registry_preference': 'shared_allowed',
  'fallback_policy': 'fallback_to_generic',
  'preferred_cli': 'codex',
  'skip_optional_unresolved': True,
  'attach_inputs': ['docs/architecture/foo.md'],
  'notes': ['supervisor has confirmed v0.21.6 baseline'],
}
envelope = {
  'schema_version': 1, 'task_id': 'env-hints', 'source_request': 'hint round trip',
  'produced_at': '2026-05-03T22:00:00Z', 'supervisor_role': '01-Supervisor',
  'task_constitution': {
    'task_id': 'env-hints', 'project_id': 'p', 'source_request': 'hint round trip',
    'goal': 'g', 'goal_stage': 'informal_planning',
    'success_criteria': ['x'], 'non_goals': [],
    'execution_plan': [{'step_id':'prd','capability':'prd_generation'}]
  },
  'capability_graph': {
    'schema_version': 1, 'task_id': 'env-hints', 'goal_stage': 'informal_planning',
    'nodes': [{'step_id':'prd','capability':'prd_generation','required':True,'depends_on':[],'reason':'scope'}]
  },
  'governance': {'goal_stage':'informal_planning','watcher_mode':'final_only','logger_mode':'milestone_log','context_mode':'summary_first'},
  'compile_hints': hints,
  'failure_routing': {'default_action':'halt','overrides':[]}
}
out = c.compile_task_from_envelope(envelope)
trace = out['compile_hints_applied']
print('equal=' + str(trace == hints))
print('cli=' + str(trace['preferred_cli']))
print('skip=' + str(trace['skip_optional_unresolved']))
print('attach_count=' + str(len(trace['attach_inputs'])))
")"
assert_contains "case 4 hint trace equals input" "equal=True" "${out4}"
assert_contains "case 4 preferred_cli preserved" "cli=codex" "${out4}"
assert_contains "case 4 skip_optional preserved" "skip=True" "${out4}"
assert_contains "case 4 attach_inputs preserved" "attach_count=1" "${out4}"

# ── Case 5 ──────────────────────────────────────────────────────────────
echo "Case 5: empty compile_hints={} still surfaces compile_hints_applied={}"
out5="$(run_py "
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler
c = TaskScopedWorkflowCompiler()
envelope = {
  'schema_version': 1, 'task_id': 'env-empty', 'source_request': 'empty hints',
  'produced_at': '2026-05-03T22:00:00Z', 'supervisor_role': '01-Supervisor',
  'task_constitution': {
    'task_id': 'env-empty', 'project_id': 'p', 'source_request': 'empty hints',
    'goal': 'g', 'goal_stage': 'informal_planning',
    'success_criteria': ['x'], 'non_goals': [],
    'execution_plan': [{'step_id':'prd','capability':'prd_generation'}]
  },
  'capability_graph': {
    'schema_version': 1, 'task_id': 'env-empty', 'goal_stage': 'informal_planning',
    'nodes': [{'step_id':'prd','capability':'prd_generation','required':True,'depends_on':[],'reason':'scope'}]
  },
  'governance': {'goal_stage':'informal_planning','watcher_mode':'final_only','logger_mode':'milestone_log','context_mode':'summary_first'},
  'compile_hints': {},
  'failure_routing': {'default_action':'halt','overrides':[]}
}
out = c.compile_task_from_envelope(envelope)
print('present=' + str('compile_hints_applied' in out))
print('value=' + str(out['compile_hints_applied']))
print('type=' + type(out['compile_hints_applied']).__name__)
")"
assert_contains "case 5 key present" "present=True" "${out5}"
assert_contains "case 5 value is empty dict" "value={}" "${out5}"
assert_contains "case 5 type is dict" "type=dict" "${out5}"

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "----------------------------------------------------------------"
echo "Summary: ${pass_count} passed, ${fail_count} failed"
echo "----------------------------------------------------------------"

[ ${fail_count} -eq 0 ]
