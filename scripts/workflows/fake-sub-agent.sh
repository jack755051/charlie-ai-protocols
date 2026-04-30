#!/usr/bin/env bash
#
# fake-sub-agent.sh — A non-AI stand-in for any sub-agent in a CAP workflow.
#
# Purpose:
#   Simulate the protocol shape of a sub-agent run for deterministic e2e
#   tests:
#     - Read a Type C handoff ticket from CAP_HANDOFF_TICKET_PATH (or first
#       positional arg)
#     - Validate the ticket against schemas/handoff-ticket.schema.yaml
#     - Honor the ticket's output_expectations.handoff_summary_path: write a
#       minimal Type D handoff summary file with the required YAML
#       frontmatter and the body sections defined in
#       policies/handoff-ticket-protocol.md §4
#     - Return 0 on success, non-zero on simulated failure
#
# Test hooks (env-driven):
#   CAP_FAKE_RESULT       success | failure   (default: success)
#   CAP_FAKE_HALT_SIGNAL  optional string written into halt_signals_raised
#                         when CAP_FAKE_RESULT=failure
#   CAP_FAKE_AGENT_ID     overrides ticket.bound_to as the recorded agent_id
#                         (default: bound_to from ticket; fallback "fake-sub-agent")
#
# Exit codes:
#   0   success path (Type D summary written, no halt signal)
#   2   ticket missing or unreadable
#   3   ticket fails schema validation
#   4   handoff_summary_path missing in ticket
#   5   write of Type D summary failed
#   1   simulated failure (CAP_FAKE_RESULT=failure); Type D summary still
#       written with result: 失敗 so downstream consumers can react

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP_ROOT="${CAP_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

ticket_path="${CAP_HANDOFF_TICKET_PATH:-${1:-}}"
result_mode="${CAP_FAKE_RESULT:-success}"
halt_signal="${CAP_FAKE_HALT_SIGNAL:-}"
agent_id_override="${CAP_FAKE_AGENT_ID:-}"

if [ -z "${ticket_path}" ]; then
  echo "ERROR: CAP_HANDOFF_TICKET_PATH not set and no positional ticket path given" >&2
  exit 2
fi
if [ ! -f "${ticket_path}" ]; then
  echo "ERROR: ticket file not found: ${ticket_path}" >&2
  exit 2
fi

VENV_PY="${CAP_ROOT}/.venv/bin/python"
if [ -x "${VENV_PY}" ]; then
  PYTHON_BIN="${VENV_PY}"
else
  PYTHON_BIN="python3"
fi

# 1. Schema validation against handoff-ticket schema
SCHEMA_PATH="${CAP_ROOT}/schemas/handoff-ticket.schema.yaml"
STEP_PY="${CAP_ROOT}/engine/step_runtime.py"
if [ -f "${SCHEMA_PATH}" ] && [ -f "${STEP_PY}" ]; then
  if ! "${PYTHON_BIN}" "${STEP_PY}" validate-jsonschema "${ticket_path}" "${SCHEMA_PATH}" >/dev/null 2>&1; then
    echo "ERROR: ticket fails schema validation: ${ticket_path}" >&2
    "${PYTHON_BIN}" "${STEP_PY}" validate-jsonschema "${ticket_path}" "${SCHEMA_PATH}" 2>&1 >/dev/null | head -5 >&2
    exit 3
  fi
fi

# 2. Read fields we care about from the ticket
ticket_payload="$("${PYTHON_BIN}" - "${ticket_path}" <<'PY'
import json
import os
import sys

ticket = json.load(open(sys.argv[1]))
agent_id_override = os.environ.get("CAP_FAKE_AGENT_ID", "")
agent_id = agent_id_override or ticket.get("bound_to") or "fake-sub-agent"

handoff_summary_path = (ticket.get("output_expectations") or {}).get("handoff_summary_path", "")
acceptance = ticket.get("acceptance_criteria") or []
print(json.dumps({
    "agent_id": agent_id,
    "task_id": ticket.get("task_id", ""),
    "step_id": ticket.get("step_id", ""),
    "target_capability": ticket.get("target_capability", ""),
    "task_objective": ticket.get("task_objective", ""),
    "handoff_summary_path": handoff_summary_path,
    "acceptance_criteria": acceptance,
    "primary_artifacts": (ticket.get("output_expectations") or {}).get("primary_artifacts", []),
}))
PY
)"

handoff_summary_path="$("${PYTHON_BIN}" -c '
import json, sys
print(json.loads(sys.stdin.read())["handoff_summary_path"])
' <<< "${ticket_payload}")"

if [ -z "${handoff_summary_path}" ]; then
  echo "ERROR: ticket has no output_expectations.handoff_summary_path" >&2
  exit 4
fi

mkdir -p "$(dirname "${handoff_summary_path}")" || { echo "ERROR: cannot create handoff dir" >&2; exit 5; }

# 3. Write the Type D summary
agent_id="$("${PYTHON_BIN}" -c 'import json,sys; print(json.loads(sys.stdin.read())["agent_id"])' <<< "${ticket_payload}")"
task_id="$("${PYTHON_BIN}" -c 'import json,sys; print(json.loads(sys.stdin.read())["task_id"])' <<< "${ticket_payload}")"
step_id="$("${PYTHON_BIN}" -c 'import json,sys; print(json.loads(sys.stdin.read())["step_id"])' <<< "${ticket_payload}")"
target_capability="$("${PYTHON_BIN}" -c 'import json,sys; print(json.loads(sys.stdin.read())["target_capability"])' <<< "${ticket_payload}")"

if [ "${result_mode}" = "failure" ]; then
  result="失敗"
  halt_line="${halt_signal:-CAP_FAKE_RESULT=failure (simulated)}"
else
  result="成功"
  halt_line="無"
fi

{
  printf -- '---\n'
  printf -- 'agent_id: %s\n' "${agent_id}"
  printf -- 'step_id: %s\n' "${step_id}"
  printf -- 'task_id: %s\n' "${task_id}"
  printf -- 'result: %s\n' "${result}"
  printf -- 'output_paths:\n'
  printf -- '  - %s\n' "${handoff_summary_path}"
  printf -- '---\n\n'
  printf -- '# Handoff Summary (Fake Sub-Agent)\n\n'
  printf -- '## task_summary\n%s — simulated by fake-sub-agent.sh\n\n' "${target_capability}"
  printf -- '## key_decisions\n- Ran fake-sub-agent against ticket (no real AI work)\n- Echoed acceptance_criteria from ticket as if all were met\n\n'
  printf -- '## downstream_notes\n- This summary is for e2e testing only; do not consume in production\n\n'
  printf -- '## risks_carried_forward\n- 無\n\n'
  printf -- '## halt_signals_raised\n- %s\n' "${halt_line}"
} > "${handoff_summary_path}" || { echo "ERROR: failed to write handoff summary" >&2; exit 5; }

if [ "${result_mode}" = "failure" ]; then
  echo "FAKE_FAIL: ticket=${ticket_path} → handoff=${handoff_summary_path} (result=失敗)"
  exit 1
fi

echo "FAKE_OK: ticket=${ticket_path} → handoff=${handoff_summary_path}"
exit 0
