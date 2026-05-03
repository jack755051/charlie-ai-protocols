#!/usr/bin/env bash
#
# test-supervisor-orchestration-release-gate.sh — P3 #8 release-gate
# end-to-end smoke that exercises the full P3 envelope flow: producer
# fence -> envelope helpers -> four-part snapshot writer -> envelope-
# driven compile entry -> minimal workflow binding. The deterministic
# e2e fixture is the closeout marker for the P3 (Supervisor Structured
# Orchestration) phase.
#
# Coverage (5 cases / ~30 assertions):
#
#   Case 0 happy:       valid envelope passes extract + validate +
#                       drift + xref + resolve via supervisor_envelope;
#                       orchestration_snapshot writes the four-part
#                       snapshot with validation.json status=ok;
#                       compile_task_from_envelope returns the 9-key
#                       output dict including failure_routing_resolved
#                       aligned with capability_graph node order. End-
#                       to-end exit 0 across every stage.
#
#   Case 1 schema halt: envelope missing the failure_routing required
#                       block. supervisor_envelope validate exits 41,
#                       orchestration_snapshot still writes four
#                       artefacts (Q1 = A: doctor / status can observe
#                       partial state) but exits 41 with status=failed,
#                       compile_task_from_envelope raises
#                       CompileFromEnvelopeError naming "schema
#                       validation".
#
#   Case 2 drift halt:  envelope.task_id != task_constitution.task_id.
#                       Schema passes, drift fails, orchestration_snapshot
#                       still writes four artefacts but with
#                       validation.json status=failed and exit 41,
#                       compile_task_from_envelope raises
#                       CompileFromEnvelopeError naming "drift".
#
#   Case 3 xref halt:   envelope.failure_routing.overrides[].step_id
#                       references a phantom node not in
#                       capability_graph.nodes. Schema and drift pass,
#                       xref fails, compile_task_from_envelope raises
#                       CompileFromEnvelopeError naming "xref" — the
#                       third entry-gate failure class distinguishable
#                       from schema and drift.
#
#   Case 4 binding:     `cap workflow bind supervisor-orchestration`
#                       (delegated to scripts/cap-workflow.sh per the
#                       smoke-per-stage helper convention) reports
#                       binding_status: ready and required_unresolved=0,
#                       proving the P3 #5-c minimal wiring still binds
#                       cleanly after every preceding P3 module change.
#
# Determinism: zero AI calls, zero network, zero installed `cap` on
# PATH. The fixture invokes `engine.supervisor_envelope`,
# `engine.orchestration_snapshot`, and `engine.task_scoped_compiler`
# in-process (or via `python3 -m`), and `cap-workflow.sh` for the
# bind step (binding is a static graph traversal, no AI). Each case
# uses a fresh per-case CAP_HOME under mktemp so cross-case state
# cannot leak.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CAP_WORKFLOW="${REPO_ROOT}/scripts/cap-workflow.sh"

[ -x "${CAP_WORKFLOW}" ] || { echo "FAIL: ${CAP_WORKFLOW} missing"; exit 1; }
[ -f "${REPO_ROOT}/engine/supervisor_envelope.py" ] || { echo "FAIL: engine/supervisor_envelope.py missing"; exit 1; }
[ -f "${REPO_ROOT}/engine/orchestration_snapshot.py" ] || { echo "FAIL: engine/orchestration_snapshot.py missing"; exit 1; }
[ -f "${REPO_ROOT}/engine/task_scoped_compiler.py" ] || { echo "FAIL: engine/task_scoped_compiler.py missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-p3-release-gate.XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

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

assert_file_exists() {
  local desc="$1" path="$2"
  if [ -f "${path}" ]; then
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc} (missing: ${path})"
    fail_count=$((fail_count + 1))
  fi
}

# Compose a fenced supervisor envelope artifact with the given task_id /
# nested task_id / failure_routing override step_id. Every other field
# is a fixed legal payload so each case isolates exactly one mutation.
emit_envelope() {
  local target="$1"
  local envelope_task_id="${2:-rg-001}"
  local nested_task_id="${3:-${envelope_task_id}}"
  local override_step_id="${4:-tech}"   # must exist in capability_graph
  local include_failure_routing="${5:-1}"
  local routing_block=""
  if [ "${include_failure_routing}" = "1" ]; then
    routing_block=$(cat <<EOF
,
  "failure_routing": {
    "default_action": "halt",
    "overrides": [
      {"step_id": "${override_step_id}", "on_fail": "retry", "max_retries": 2}
    ]
  }
EOF
)
  fi
  cat > "${target}" <<EOF
release-gate fixture narrative

<<<SUPERVISOR_ORCHESTRATION_BEGIN>>>
{
  "schema_version": 1,
  "task_id": "${envelope_task_id}",
  "source_request": "release-gate envelope flow",
  "produced_at": "2026-05-04T00:00:00Z",
  "supervisor_role": "01-Supervisor",
  "task_constitution": {
    "task_id": "${nested_task_id}",
    "project_id": "rg-proj",
    "source_request": "release-gate envelope flow",
    "goal": "exercise full P3 envelope flow",
    "goal_stage": "informal_planning",
    "success_criteria": ["all P3 modules align"],
    "non_goals": [],
    "execution_plan": [
      {"step_id":"prd","capability":"prd_generation"},
      {"step_id":"tech","capability":"technical_planning"}
    ]
  },
  "capability_graph": {
    "schema_version": 1,
    "task_id": "${envelope_task_id}",
    "goal_stage": "informal_planning",
    "nodes": [
      {"step_id":"prd","capability":"prd_generation","required":true,"depends_on":[],"reason":"scope"},
      {"step_id":"tech","capability":"technical_planning","required":true,"depends_on":["prd"],"reason":"select stack"}
    ]
  },
  "governance": {
    "goal_stage": "informal_planning",
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log",
    "context_mode": "summary_first"
  },
  "compile_hints": {}${routing_block}
}
<<<SUPERVISOR_ORCHESTRATION_END>>>
EOF
}

# Run a python -c snippet from REPO_ROOT so engine package imports work.
run_py() {
  ( cd "${REPO_ROOT}" && python3 -c "$1" 2>&1 )
}

# ── Case 0 ──────────────────────────────────────────────────────────────
echo "Case 0: full envelope flow happy path → all stages exit 0"
C0_HOME="${SANDBOX}/c0-cap"
C0_ART="${SANDBOX}/c0-envelope.md"
emit_envelope "${C0_ART}"

# Stage A: helper validate / drift / xref / resolve via CLI
helper_validate="$(run_py "
import json, sys
sys.path.insert(0, '${REPO_ROOT}')
from engine.supervisor_envelope import (
    extract_envelope, validate_envelope, check_envelope_drift,
    check_failure_routing_xrefs, resolve_failure_routing,
)
text = open('${C0_ART}').read()
ext = extract_envelope(text)
print('extract.ok=' + str(ext.ok))
v = validate_envelope(ext.payload)
print('validate.ok=' + str(v.ok))
d = check_envelope_drift(ext.payload)
print('drift.ok=' + str(d.ok))
x = check_failure_routing_xrefs(ext.payload)
print('xref.ok=' + str(x.ok))
r = resolve_failure_routing(ext.payload)
print('resolve_count=' + str(len(r)))
print('tech_source=' + r[1]['source'])
print('tech_on_fail=' + r[1]['on_fail'])
")"
assert_contains "case 0 extract ok" "extract.ok=True" "${helper_validate}"
assert_contains "case 0 validate ok" "validate.ok=True" "${helper_validate}"
assert_contains "case 0 drift ok" "drift.ok=True" "${helper_validate}"
assert_contains "case 0 xref ok" "xref.ok=True" "${helper_validate}"
assert_contains "case 0 resolve aligned with two-node graph" \
  "resolve_count=2" "${helper_validate}"
assert_contains "case 0 override branch on tech" "tech_source=override" "${helper_validate}"
assert_contains "case 0 override on_fail=retry" "tech_on_fail=retry" "${helper_validate}"

# Stage B: snapshot writer CLI
snap_out="$(CAP_HOME="${C0_HOME}" python3 -m engine.orchestration_snapshot write \
  --envelope-path "${C0_ART}" --project-id rg-proj \
  --stamp 20260504T000000Z 2>&1)"
snap_rc=$?
assert_eq "case 0 snapshot exit 0" "0" "${snap_rc}"
assert_contains "case 0 snapshot status=ok" '"status": "ok"' "${snap_out}"
C0_DIR="${C0_HOME}/projects/rg-proj/orchestrations/20260504T000000Z"
assert_file_exists "case 0 snapshot envelope.json" "${C0_DIR}/envelope.json"
assert_file_exists "case 0 snapshot envelope.md" "${C0_DIR}/envelope.md"
assert_file_exists "case 0 snapshot validation.json" "${C0_DIR}/validation.json"
assert_file_exists "case 0 snapshot source-prompt.txt" "${C0_DIR}/source-prompt.txt"

# Stage C: compile_task_from_envelope
compile_out="$(run_py "
import sys, json
sys.path.insert(0, '${REPO_ROOT}')
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler
from engine.supervisor_envelope import extract_envelope
ext = extract_envelope(open('${C0_ART}').read())
out = TaskScopedWorkflowCompiler().compile_task_from_envelope(ext.payload)
print('keys=' + ','.join(sorted(out.keys())))
print('routing_count=' + str(len(out['failure_routing_resolved'])))
print('routing_tech_source=' + out['failure_routing_resolved'][1]['source'])
")"
assert_contains "case 0 compile output 9-key shape" \
  "keys=binding,capability_graph,compile_hints_applied,compiled_workflow,failure_routing_resolved,plan,project_context,task_constitution,unresolved_policy" \
  "${compile_out}"
assert_contains "case 0 compile resolved 2 routes" "routing_count=2" "${compile_out}"
assert_contains "case 0 compile carries override label" \
  "routing_tech_source=override" "${compile_out}"

# ── Case 1 ──────────────────────────────────────────────────────────────
echo "Case 1: schema halt — envelope missing failure_routing"
C1_HOME="${SANDBOX}/c1-cap"
C1_ART="${SANDBOX}/c1-envelope.md"
emit_envelope "${C1_ART}" "rg-002" "rg-002" "tech" "0"  # include_failure_routing=0

snap_out="$(CAP_HOME="${C1_HOME}" python3 -m engine.orchestration_snapshot write \
  --envelope-path "${C1_ART}" --project-id rg-proj \
  --stamp 20260504T000100Z 2>&1)"
snap_rc=$?
assert_eq "case 1 snapshot exit 41 (Q1=A still writes)" "41" "${snap_rc}"
assert_contains "case 1 snapshot status=failed" '"status": "failed"' "${snap_out}"
C1_DIR="${C1_HOME}/projects/rg-proj/orchestrations/20260504T000100Z"
assert_file_exists "case 1 four-part still landed (envelope.json)" "${C1_DIR}/envelope.json"
assert_file_exists "case 1 four-part still landed (validation.json)" "${C1_DIR}/validation.json"
v1="$(cat "${C1_DIR}/validation.json")"
assert_contains "case 1 validation.json names failure_routing" \
  "failure_routing" "${v1}"

compile_out1="$(run_py "
import sys
sys.path.insert(0, '${REPO_ROOT}')
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler, CompileFromEnvelopeError
from engine.supervisor_envelope import extract_envelope
ext = extract_envelope(open('${C1_ART}').read())
try:
    TaskScopedWorkflowCompiler().compile_task_from_envelope(ext.payload)
    print('UNEXPECTED_PASS')
except CompileFromEnvelopeError as e:
    print('raised=' + str(e)[:200])
")"
assert_contains "case 1 compile raised CompileFromEnvelopeError" "raised=" "${compile_out1}"
assert_contains "case 1 compile names schema validation" "schema validation" "${compile_out1}"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: drift halt — envelope.task_id != task_constitution.task_id"
C2_HOME="${SANDBOX}/c2-cap"
C2_ART="${SANDBOX}/c2-envelope.md"
emit_envelope "${C2_ART}" "envelope-X" "nested-Y" "tech" "1"

snap_out="$(CAP_HOME="${C2_HOME}" python3 -m engine.orchestration_snapshot write \
  --envelope-path "${C2_ART}" --project-id rg-proj \
  --stamp 20260504T000200Z 2>&1)"
snap_rc=$?
assert_eq "case 2 snapshot exit 41" "41" "${snap_rc}"
assert_contains "case 2 snapshot status=failed" '"status": "failed"' "${snap_out}"
C2_DIR="${C2_HOME}/projects/rg-proj/orchestrations/20260504T000200Z"
assert_file_exists "case 2 four-part still landed" "${C2_DIR}/validation.json"
v2="$(cat "${C2_DIR}/validation.json")"
assert_contains "case 2 validation.json names task_id drift" "task_id drift" "${v2}"

compile_out2="$(run_py "
import sys
sys.path.insert(0, '${REPO_ROOT}')
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler, CompileFromEnvelopeError
from engine.supervisor_envelope import extract_envelope
ext = extract_envelope(open('${C2_ART}').read())
try:
    TaskScopedWorkflowCompiler().compile_task_from_envelope(ext.payload)
    print('UNEXPECTED_PASS')
except CompileFromEnvelopeError as e:
    print('raised=' + str(e)[:200])
")"
assert_contains "case 2 compile raised CompileFromEnvelopeError" "raised=" "${compile_out2}"
assert_contains "case 2 compile names drift" "drift" "${compile_out2}"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: xref halt — overrides[].step_id references phantom node"
C3_HOME="${SANDBOX}/c3-cap"
C3_ART="${SANDBOX}/c3-envelope.md"
# Schema-valid + drift-clean envelope with override pointing at phantom step.
emit_envelope "${C3_ART}" "rg-003" "rg-003" "phantom-step" "1"

# Schema gate passes (overrides shape is valid; xref is enforced at the
# compile-entry gate, not at schema validation). Snapshot writer therefore
# lands status=ok at this layer; xref enforcement is the compile entry's
# responsibility per the P3 #6 boundary.
snap_out="$(CAP_HOME="${C3_HOME}" python3 -m engine.orchestration_snapshot write \
  --envelope-path "${C3_ART}" --project-id rg-proj \
  --stamp 20260504T000300Z 2>&1)"
snap_rc=$?
assert_eq "case 3 snapshot exit 0 (xref not enforced at writer layer)" "0" "${snap_rc}"

compile_out3="$(run_py "
import sys
sys.path.insert(0, '${REPO_ROOT}')
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler, CompileFromEnvelopeError
from engine.supervisor_envelope import extract_envelope
ext = extract_envelope(open('${C3_ART}').read())
try:
    TaskScopedWorkflowCompiler().compile_task_from_envelope(ext.payload)
    print('UNEXPECTED_PASS')
except CompileFromEnvelopeError as e:
    print('raised=' + str(e)[:200])
")"
assert_contains "case 3 compile raised CompileFromEnvelopeError" "raised=" "${compile_out3}"
assert_contains "case 3 compile names xref class" "xref" "${compile_out3}"
assert_contains "case 3 compile surfaces phantom step" "phantom-step" "${compile_out3}"

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: supervisor-orchestration workflow binding still ready"
bind_out="$(bash "${CAP_WORKFLOW}" bind supervisor-orchestration 2>&1)"
bind_rc=$?
assert_eq "case 4 bind exit 0" "0" "${bind_rc}"
assert_contains "case 4 binding_status: ready" \
  "binding_status: ready" "${bind_out}"
assert_contains "case 4 required_unresolved=0" \
  "required_unresolved=0" "${bind_out}"

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "----------------------------------------------------------------"
echo "Summary: ${pass_count} passed, ${fail_count} failed"
echo "----------------------------------------------------------------"

[ ${fail_count} -eq 0 ]
