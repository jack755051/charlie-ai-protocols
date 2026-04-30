#!/usr/bin/env bash
#
# emit-handoff-ticket.sh — Pipeline step: deterministically emit a Type C
# handoff ticket JSON for a single workflow step, by unwrapping the
# corresponding entry from a persisted Task Constitution.
#
# Reads:
#   - task_constitution artifact path (from CAP_WORKFLOW_INPUT_CONTEXT or
#     CAP_TASK_CONSTITUTION_PATH env)
#   - target step id (from CAP_TARGET_STEP_ID env or step's input parameter)
#   - upstream handoff summaries (optional; from CAP_UPSTREAM_HANDOFFS env,
#     newline-separated `step_id=path` pairs)
#
# Validation (two passes):
#   1. Inline minimal structural assertion (pre-write, fast-fail):
#      - target_step_id must exist in task_constitution.execution_plan
#      - emitted ticket must have all required top-level fields
#      - context_payload must include project_constitution_path and
#        task_constitution_path
#      - output_expectations must include primary_artifacts and
#        handoff_summary_path
#      - failure_routing must include on_fail
#   2. Full JSON Schema validation (post-write):
#      - Delegates to engine/step_runtime.py validate-jsonschema against
#        schemas/handoff-ticket.schema.yaml
#      - Catches type errors, enum violations on failure_routing.on_fail and
#        provider_hint, and nested array-of-object shape issues.
#
# Behavior:
#   - Load task constitution JSON.
#   - Locate execution_plan[target_step_id].
#   - Build a Type C ticket (per schemas/handoff-ticket.schema.yaml) including
#     ticket_id, task_id, step_id, target_capability, rules_to_load (best
#     effort defaults), context_payload (with summary-first upstream handoffs),
#     acceptance_criteria (from execution_plan entry), failure_routing
#     defaults, and bookkeeping (created_at / created_by).
#   - Validate the constructed ticket against required field set.
#   - Write to ~/.cap/projects/<project_id>/handoffs/<step_id>.ticket.json.
#   - If a prior ticket exists at that path, the new one is written with
#     suffix `-<seq>.ticket.json` (per supervisor protocol §3.6 rule 2).
#
# Exit codes:
#   - 0  : success (ticket emitted)
#   - 40 : critical failure — missing task constitution, step not in
#          execution_plan, JSON parse error, or write failure.

set -u

step_id="${CAP_WORKFLOW_STEP_ID:-emit_handoff_ticket}"
target_step_id="${CAP_TARGET_STEP_ID:-}"
input_context="${CAP_WORKFLOW_INPUT_CONTEXT:-}"
task_constitution_path="${CAP_TASK_CONSTITUTION_PATH:-}"

# When invoked as a workflow step named `emit_<target>_ticket`, derive the
# target step id automatically so the workflow YAML does not need to inject
# CAP_TARGET_STEP_ID per step. Explicit env var still wins if set.
#
# Only fire when CAP_WORKFLOW_STEP_ID is *explicitly* set; never derive from
# the local default `emit_handoff_ticket` because that would silently produce
# target_step_id=handoff and mask the user's missing-input mistake.
if [ -z "${target_step_id}" ] && [ -n "${CAP_WORKFLOW_STEP_ID:-}" ]; then
  case "${CAP_WORKFLOW_STEP_ID}" in
    emit_*_ticket)
      stripped="${CAP_WORKFLOW_STEP_ID#emit_}"
      target_step_id="${stripped%_ticket}"
      ;;
  esac
fi

CAP_ROOT="${CAP_ROOT:-}"
if [ -z "${CAP_ROOT}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CAP_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
fi

VENV_PY="${CAP_ROOT}/.venv/bin/python"
if [ -x "${VENV_PY}" ]; then
  PYTHON_BIN="${VENV_PY}"
else
  PYTHON_BIN="python3"
fi

print_header() {
  printf '# %s\n\n' "${step_id}"
  printf '## Handoff Ticket Emission Report\n\n'
}

fail_with() {
  local reason="$1"
  shift
  printf 'condition: workflow_step_failed\n'
  printf 'reason: %s\n' "${reason}"
  for line in "$@"; do
    printf 'detail: %s\n' "${line}"
  done
  exit 40
}

extract_artifact_path() {
  local context="$1"
  local artifact_name="$2"
  printf '%s' "${context}" | "${PYTHON_BIN}" -c '
import re
import sys

want = sys.argv[1]
for line in sys.stdin.read().splitlines():
    if want in line and "path=" in line:
        m = re.search(r"path=([^\s]+)", line)
        if m:
            print(m.group(1))
            raise SystemExit(0)
print("")
' "${artifact_name}"
}

print_header

# Resolve task_constitution path
if [ -z "${task_constitution_path}" ] && [ -n "${input_context}" ]; then
  task_constitution_path="$(extract_artifact_path "${input_context}" "task_constitution")"
fi
if [ -z "${task_constitution_path}" ]; then
  fail_with "missing_task_constitution_path" "set CAP_TASK_CONSTITUTION_PATH or pass via input_context"
fi
if [ ! -f "${task_constitution_path}" ]; then
  fail_with "task_constitution_not_found" "${task_constitution_path}"
fi

if [ -z "${target_step_id}" ]; then
  fail_with "missing_target_step_id" "set CAP_TARGET_STEP_ID env"
fi

CAP_HOME="${CAP_HOME:-${HOME}/.cap}"
upstream_handoffs="${CAP_UPSTREAM_HANDOFFS:-}"

ticket_payload="$(
  CAP_TASK_CONSTITUTION_PATH="${task_constitution_path}" \
  CAP_TARGET_STEP_ID="${target_step_id}" \
  CAP_UPSTREAM_HANDOFFS="${upstream_handoffs}" \
  CAP_HOME="${CAP_HOME}" \
  "${PYTHON_BIN}" - <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

tc_path = Path(os.environ["CAP_TASK_CONSTITUTION_PATH"])
target_step_id = os.environ["CAP_TARGET_STEP_ID"]
upstream_raw = os.environ.get("CAP_UPSTREAM_HANDOFFS", "")
cap_home = Path(os.environ["CAP_HOME"])

with tc_path.open() as f:
    tc = json.load(f)

project_id = tc.get("project_id")
task_id = tc.get("task_id")
if not project_id or not task_id:
    print("ERROR:missing_project_or_task_id", file=sys.stderr)
    raise SystemExit(2)

execution_plan = tc.get("execution_plan", [])
step_entry = next((s for s in execution_plan if s.get("step_id") == target_step_id), None)
if step_entry is None:
    print(f"ERROR:step_not_in_execution_plan:{target_step_id}", file=sys.stderr)
    raise SystemExit(3)

# Compute ticket path with seq increment if prior exists
handoffs_dir = cap_home / "projects" / project_id / "handoffs"
handoffs_dir.mkdir(parents=True, exist_ok=True)
base_name = f"{target_step_id}.ticket.json"
ticket_path = handoffs_dir / base_name
seq = 1
if ticket_path.exists():
    seq = 2
    while True:
        candidate = handoffs_dir / f"{target_step_id}-{seq}.ticket.json"
        if not candidate.exists():
            ticket_path = candidate
            break
        seq += 1

ticket_id = f"{task_id}-{target_step_id}-{seq}"

# Build upstream handoff summaries
upstream_summaries = []
if upstream_raw:
    for line in upstream_raw.splitlines():
        line = line.strip()
        if "=" in line:
            sid, p = line.split("=", 1)
            upstream_summaries.append({
                "step_id": sid.strip(),
                "summary_path": p.strip(),
            })

# Build ticket per handoff-ticket.schema.yaml
ticket = {
    "ticket_id": ticket_id,
    "task_id": task_id,
    "step_id": target_step_id,
    "created_at": datetime.now(timezone.utc).isoformat(),
    "created_by": "01-Supervisor",
    "target_capability": step_entry.get("capability"),
    "bound_to": step_entry.get("bound_to"),
    "task_objective": step_entry.get("objective", f"Execute {target_step_id}"),
    "rules_to_load": {
        "agent_skill": step_entry.get("agent_skill_path", ""),
        "core_protocol": "agent-skills/00-core-protocol.md",
    },
    "context_payload": {
        "project_constitution_path": str(Path.cwd() / ".cap.constitution.yaml"),
        "task_constitution_path": str(tc_path),
        "upstream_handoff_summaries": upstream_summaries,
        "upstream_full_artifacts": [],
        "inherited_constraints": tc.get("constraints_inherited_from_constitution", []),
        "inherited_stop_conditions": tc.get("stop_conditions", []),
    },
    "acceptance_criteria": step_entry.get("acceptance_criteria", []) or step_entry.get("done_when", []),
    "output_expectations": {
        "primary_artifacts": step_entry.get("output_paths", []),
        "handoff_summary_path": str(
            cap_home / "projects" / project_id / "reports" / "workflows" / task_id /
            f"{target_step_id}.handoff.md"
        ),
    },
    "governance": {
        "watcher_required": target_step_id in (tc.get("governance", {}) or {}).get("watcher_checkpoints", []),
        "security_required": False,
        "logger_required": True,
    },
    "failure_routing": {
        "on_fail": step_entry.get("on_fail", "halt"),
        "route_back_to_step": step_entry.get("route_back_to"),
        "max_retries": step_entry.get("max_retries"),
    },
    "timeout_seconds": step_entry.get("timeout_seconds", 600),
    "budget_slot": {
        "task_budget_total": (tc.get("governance", {}) or {}).get("budget_sub_agent_sessions"),
        "slot_index": seq,
    },
}

# Minimal structural validation against schemas/handoff-ticket.schema.yaml
# (top-level required fields + key nested required fields). Honest scope:
# this is field-presence checking, not full JSON Schema validation.
required_top = [
    "ticket_id", "task_id", "step_id", "created_at", "created_by",
    "target_capability", "task_objective", "rules_to_load",
    "context_payload", "acceptance_criteria", "output_expectations",
    "failure_routing",
]
missing_top = [k for k in required_top if k not in ticket or ticket[k] in (None, "")]
if missing_top:
    print(f"ERROR:ticket_missing_top_required:{','.join(missing_top)}", file=sys.stderr)
    raise SystemExit(4)

context_payload = ticket["context_payload"]
required_context = ["project_constitution_path", "task_constitution_path"]
missing_context = [k for k in required_context if k not in context_payload or not context_payload[k]]
if missing_context:
    print(
        f"ERROR:ticket_missing_context_required:{','.join(missing_context)}",
        file=sys.stderr,
    )
    raise SystemExit(5)

output_expectations = ticket["output_expectations"]
required_output = ["primary_artifacts", "handoff_summary_path"]
missing_output = [k for k in required_output if k not in output_expectations]
if missing_output:
    print(
        f"ERROR:ticket_missing_output_required:{','.join(missing_output)}",
        file=sys.stderr,
    )
    raise SystemExit(6)

failure_routing = ticket["failure_routing"]
if "on_fail" not in failure_routing or not failure_routing["on_fail"]:
    print("ERROR:ticket_missing_failure_routing_on_fail", file=sys.stderr)
    raise SystemExit(7)

with ticket_path.open("w") as f:
    json.dump(ticket, f, ensure_ascii=False, indent=2, sort_keys=False)
    f.write("\n")

print(f"OK:{ticket_path}")
PY
)"

emit_rc=$?
if [ ${emit_rc} -ne 0 ]; then
  fail_with "python_emission_failed" "${ticket_payload}"
fi

ticket_path="${ticket_payload#OK:}"

# Full JSON Schema validation against schemas/handoff-ticket.schema.yaml
# via engine/step_runtime.py validate-jsonschema. Catches type / enum / nested
# shape issues that the inline pre-write assertion cannot see.
SCHEMA_PATH="${CAP_ROOT}/schemas/handoff-ticket.schema.yaml"
STEP_PY="${CAP_ROOT}/engine/step_runtime.py"
if [ -f "${SCHEMA_PATH}" ] && [ -f "${STEP_PY}" ]; then
  schema_result="$("${PYTHON_BIN}" "${STEP_PY}" validate-jsonschema "${ticket_path}" "${SCHEMA_PATH}" 2>&1)"
  schema_rc=$?
  if [ ${schema_rc} -ne 0 ]; then
    fail_with "schema_validation_failed" "${schema_result}"
  fi
fi

printf -- 'condition: ok\n'
printf -- 'target_step_id: %s\n' "${target_step_id}"
printf -- 'ticket_path: %s\n' "${ticket_path}"
printf -- '\n'
printf -- '## Output Artifacts\n\n'
printf -- '- name=handoff_ticket path=%s\n' "${ticket_path}"

exit 0
