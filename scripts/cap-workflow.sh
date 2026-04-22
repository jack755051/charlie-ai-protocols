#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKFLOWS_DIR="${CAP_ROOT}/schemas/workflows"
VENV_PYTHON="${CAP_ROOT}/.venv/bin/python"
PATH_HELPER="${SCRIPT_DIR}/cap-paths.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  bash scripts/cap-workflow.sh list
  bash scripts/cap-workflow.sh ps
  bash scripts/cap-workflow.sh <workflow_id|short_id|file>
  bash scripts/cap-workflow.sh show <workflow_id|file>
  bash scripts/cap-workflow.sh inspect <run_id>
  bash scripts/cap-workflow.sh plan <workflow_id|file>
  bash scripts/cap-workflow.sh run <workflow_id|file> [prompt...]
EOF
  exit 1
}

resolve_python() {
  if [ -x "${VENV_PYTHON}" ]; then
    printf '%s\n' "${VENV_PYTHON}"
  else
    printf '%s\n' "python3"
  fi
}

resolve_workflow_ref() {
  local raw_ref="${1:-}"
  [ -n "${raw_ref}" ] || return 1

  if [ -f "${raw_ref}" ]; then
    printf '%s\n' "${raw_ref}"
    return 0
  fi

  if [[ "${raw_ref}" != *.yaml && "${raw_ref}" != *.yml && "${raw_ref}" != *.json ]]; then
    if [ -f "${WORKFLOWS_DIR}/${raw_ref}.yaml" ]; then
      printf '%s\n' "${WORKFLOWS_DIR}/${raw_ref}.yaml"
      return 0
    fi
  fi

  if [ -f "${WORKFLOWS_DIR}/${raw_ref}" ]; then
    printf '%s\n' "${WORKFLOWS_DIR}/${raw_ref}"
    return 0
  fi

  "${PYTHON_BIN}" - <<'PY' "${WORKFLOWS_DIR}" "${raw_ref}"
from pathlib import Path
import hashlib
import sys
import yaml

workflows_dir = Path(sys.argv[1])
raw_ref = sys.argv[2]

for path in sorted(workflows_dir.iterdir()):
    if not path.is_file() or path.suffix not in {".yaml", ".yml", ".json"}:
        continue
    data = yaml.safe_load(path.read_text(encoding="utf-8")) if path.suffix in {".yaml", ".yml"} else {}
    workflow_id = data.get("workflow_id", path.stem)
    short_id = "wf_" + hashlib.sha1(workflow_id.encode("utf-8")).hexdigest()[:8]
    if raw_ref in {workflow_id, short_id, path.stem, path.name}:
        print(path)
        sys.exit(0)
sys.exit(1)
PY
  return $?
}

ensure_status_store() {
  bash "${PATH_HELPER}" ensure >/dev/null
}

get_status_store() {
  local cache_dir
  local preferred
  local fallback
  cache_dir="$(bash "${PATH_HELPER}" get cache_dir)"
  preferred="${cache_dir}/workflow-runs.json"
  fallback="${CAP_ROOT}/workspace/history/workflow-runs.json"

  mkdir -p "$(dirname "${fallback}")" >/dev/null 2>&1 || true

  if [ -f "${fallback}" ]; then
    printf '%s\n' "${fallback}"
    return
  fi

  if { [ -f "${preferred}" ] && [ -w "${preferred}" ]; } || { [ ! -f "${preferred}" ] && [ -d "${cache_dir}" ] && [ -w "${cache_dir}" ]; }; then
    printf '%s\n' "${preferred}"
    return
  fi

  printf '%s\n' "${fallback}"
}

create_workflow_run() {
  local workflow_id="$1"
  local workflow_name="$2"
  local state="$3"
  local result="$4"
  local mode="$5"
  local cli_name="$6"
  local prompt="$7"
  local status_file
  status_file="$(get_status_store)"

  "${PYTHON_BIN}" - <<'PY' "${status_file}" "${workflow_id}" "${workflow_name}" "${state}" "${result}" "${mode}" "${cli_name}" "${prompt}"
from pathlib import Path
from datetime import datetime
import json
import sys
import uuid

status_file = Path(sys.argv[1])
workflow_id = sys.argv[2]
workflow_name = sys.argv[3]
state = sys.argv[4]
result = sys.argv[5]
mode = sys.argv[6]
cli_name = sys.argv[7]
prompt = sys.argv[8]


def normalize(payload):
    if isinstance(payload, dict) and ("workflows" in payload or "runs" in payload):
        workflows = payload.get("workflows", {})
        runs = payload.get("runs", [])
    elif isinstance(payload, dict):
        workflows = {k: v for k, v in payload.items() if isinstance(v, dict)}
        runs = []
    else:
        workflows = {}
        runs = []
    return {
        "version": 2,
        "workflows": workflows if isinstance(workflows, dict) else {},
        "runs": runs if isinstance(runs, list) else [],
    }


def load_payload(path):
    if not path.exists():
        return normalize({})
    return normalize(json.loads(path.read_text(encoding="utf-8")))


def recompute_workflow(payload, target_workflow_id):
    runs = [r for r in payload["runs"] if r.get("workflow_id") == target_workflow_id]
    if not runs:
        payload["workflows"].pop(target_workflow_id, None)
        return
    latest = max(
        runs,
        key=lambda r: (
            r.get("updated_at", ""),
            r.get("created_at", ""),
            r.get("run_id", ""),
        ),
    )
    payload["workflows"][target_workflow_id] = {
        "workflow_name": latest.get("workflow_name", target_workflow_id),
        "state": latest.get("state", "ready"),
        "last_result": latest.get("result", "-"),
        "last_run_at": latest.get("updated_at", "-"),
        "last_run_id": latest.get("run_id", ""),
        "run_count": len(runs),
    }


payload = load_payload(status_file)
now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
run_id = f"run_{datetime.now().strftime('%Y%m%d%H%M%S')}_{uuid.uuid4().hex[:8]}"
prompt_preview = " ".join(prompt.split())[:160]

payload["runs"].append(
    {
        "run_id": run_id,
        "workflow_id": workflow_id,
        "workflow_name": workflow_name,
        "state": state,
        "result": result,
        "mode": mode,
        "cli": cli_name,
        "prompt_preview": prompt_preview,
        "created_at": now,
        "updated_at": now,
        "started_at": now,
        "finished_at": now if state in {"completed", "failed", "cancelled"} else "",
    }
)
recompute_workflow(payload, workflow_id)
status_file.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
print(run_id)
PY
}

update_workflow_run() {
  local run_id="$1"
  local state="$2"
  local result="$3"
  local status_file
  status_file="$(get_status_store)"

  "${PYTHON_BIN}" - <<'PY' "${status_file}" "${run_id}" "${state}" "${result}"
from pathlib import Path
from datetime import datetime
import json
import sys

status_file = Path(sys.argv[1])
run_id = sys.argv[2]
state = sys.argv[3]
result = sys.argv[4]


def normalize(payload):
    if isinstance(payload, dict) and ("workflows" in payload or "runs" in payload):
        workflows = payload.get("workflows", {})
        runs = payload.get("runs", [])
    elif isinstance(payload, dict):
        workflows = {k: v for k, v in payload.items() if isinstance(v, dict)}
        runs = []
    else:
        workflows = {}
        runs = []
    return {
        "version": 2,
        "workflows": workflows if isinstance(workflows, dict) else {},
        "runs": runs if isinstance(runs, list) else [],
    }


def load_payload(path):
    if not path.exists():
        return normalize({})
    return normalize(json.loads(path.read_text(encoding="utf-8")))


def recompute_workflow(payload, target_workflow_id):
    runs = [r for r in payload["runs"] if r.get("workflow_id") == target_workflow_id]
    if not runs:
        payload["workflows"].pop(target_workflow_id, None)
        return
    latest = max(
        runs,
        key=lambda r: (
            r.get("updated_at", ""),
            r.get("created_at", ""),
            r.get("run_id", ""),
        ),
    )
    payload["workflows"][target_workflow_id] = {
        "workflow_name": latest.get("workflow_name", target_workflow_id),
        "state": latest.get("state", "ready"),
        "last_result": latest.get("result", "-"),
        "last_run_at": latest.get("updated_at", "-"),
        "last_run_id": latest.get("run_id", ""),
        "run_count": len(runs),
    }


payload = load_payload(status_file)
target = None
for run in payload["runs"]:
    if run.get("run_id") == run_id:
        target = run
        break

if target is None:
    print(f"找不到 run_id：{run_id}", file=sys.stderr)
    sys.exit(1)

now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
target["state"] = state
target["result"] = result
target["updated_at"] = now
if not target.get("started_at"):
    target["started_at"] = now
if state in {"completed", "failed", "cancelled"}:
    target["finished_at"] = now

recompute_workflow(payload, target.get("workflow_id", ""))
status_file.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
PY
}

workflow_summary_field() {
  local workflow_id="$1"
  local field="$2"
  local status_file
  status_file="$(get_status_store)"

  "${PYTHON_BIN}" - <<'PY' "${status_file}" "${workflow_id}" "${field}"
from pathlib import Path
import json
import sys

status_file = Path(sys.argv[1])
workflow_id = sys.argv[2]
field = sys.argv[3]


def normalize(payload):
    if isinstance(payload, dict) and ("workflows" in payload or "runs" in payload):
        workflows = payload.get("workflows", {})
    elif isinstance(payload, dict):
        workflows = {k: v for k, v in payload.items() if isinstance(v, dict)}
    else:
        workflows = {}
    return workflows if isinstance(workflows, dict) else {}


if not status_file.exists():
    sys.exit(0)

workflows = normalize(json.loads(status_file.read_text(encoding="utf-8")))
entry = workflows.get(workflow_id, {})
value = entry.get(field, "")
if value is None:
    value = ""
print(value)
PY
}

PYTHON_BIN="$(resolve_python)"
ensure_status_store

COMMAND="${1:-}"
if [ -n "${COMMAND}" ] && [[ "${COMMAND}" != "list" && "${COMMAND}" != "ps" && "${COMMAND}" != "show" && "${COMMAND}" != "inspect" && "${COMMAND}" != "plan" && "${COMMAND}" != "run" && "${COMMAND}" != "update-run-status" ]]; then
  set -- show "$@"
fi

case "${1:-}" in
  list)
    [ "$#" -eq 1 ] || usage
    "${PYTHON_BIN}" - <<'PY' "${WORKFLOWS_DIR}" "$(get_status_store)"
from pathlib import Path
import hashlib
import json
import sys
import yaml

workflows_dir = Path(sys.argv[1])
status_file = Path(sys.argv[2])
files = sorted(p for p in workflows_dir.iterdir() if p.is_file() and p.suffix in {".yaml", ".yml", ".json"})


def normalize(payload):
    if isinstance(payload, dict) and ("workflows" in payload or "runs" in payload):
        workflows = payload.get("workflows", {})
    elif isinstance(payload, dict):
        workflows = {k: v for k, v in payload.items() if isinstance(v, dict)}
    else:
        workflows = {}
    return workflows if isinstance(workflows, dict) else {}


status_data = {}
if status_file.exists():
    status_data = normalize(json.loads(status_file.read_text(encoding="utf-8")))

rows = []
for path in files:
    raw = path.read_text(encoding="utf-8")
    data = yaml.safe_load(raw) if path.suffix in {".yaml", ".yml"} else {}
    workflow_id = data.get("workflow_id", path.stem)
    name = data.get("name", path.stem)
    summary = data.get("summary", "")
    short_id = "wf_" + hashlib.sha1(workflow_id.encode("utf-8")).hexdigest()[:8]
    workflow_state = status_data.get(workflow_id, {})
    status = workflow_state.get("state", "ready")
    run_count = workflow_state.get("run_count", 0)
    last_run_at = workflow_state.get("last_run_at", "-")
    rows.append((short_id, name, path.name, status, run_count, last_run_at, summary))

headers = ("ID", "NAME", "FILE", "STATUS", "RUNS", "LAST RUN", "SUMMARY")
widths = [len(h) for h in headers]
for row in rows:
    for i, value in enumerate(row):
        widths[i] = min(max(widths[i], len(str(value))), 60)


def clip(value, width):
    value = str(value)
    return value if len(value) <= width else value[: width - 3] + "..."


print("WORKFLOW LIST")
print(
    f"{headers[0]:<{widths[0]}}  "
    f"{headers[1]:<{widths[1]}}  "
    f"{headers[2]:<{widths[2]}}  "
    f"{headers[3]:<{widths[3]}}  "
    f"{headers[4]:>{widths[4]}}  "
    f"{headers[5]:<{widths[5]}}  "
    f"{headers[6]:<{widths[6]}}"
)
print(
    f"{'-' * widths[0]}  "
    f"{'-' * widths[1]}  "
    f"{'-' * widths[2]}  "
    f"{'-' * widths[3]}  "
    f"{'-' * widths[4]}  "
    f"{'-' * widths[5]}  "
    f"{'-' * widths[6]}"
)
for row in rows:
    print(
        f"{clip(row[0], widths[0]):<{widths[0]}}  "
        f"{clip(row[1], widths[1]):<{widths[1]}}  "
        f"{clip(row[2], widths[2]):<{widths[2]}}  "
        f"{clip(row[3], widths[3]):<{widths[3]}}  "
        f"{clip(row[4], widths[4]):>{widths[4]}}  "
        f"{clip(row[5], widths[5]):<{widths[5]}}  "
        f"{clip(row[6], widths[6]):<{widths[6]}}"
    )
PY
    ;;
  ps)
    [ "$#" -eq 1 ] || usage
    "${PYTHON_BIN}" - <<'PY' "$(get_status_store)"
from pathlib import Path
import json
import sys

status_file = Path(sys.argv[1])


def normalize(payload):
    if isinstance(payload, dict) and ("workflows" in payload or "runs" in payload):
        runs = payload.get("runs", [])
    else:
        runs = []
    return runs if isinstance(runs, list) else []


runs = []
if status_file.exists():
    runs = normalize(json.loads(status_file.read_text(encoding="utf-8")))

runs = sorted(
    runs,
    key=lambda r: (
        r.get("updated_at", ""),
        r.get("created_at", ""),
        r.get("run_id", ""),
    ),
    reverse=True,
)

print("WORKFLOW RUNS")
if not runs:
    print("No workflow runs found.")
    sys.exit(0)

rows = [
    (
        run.get("run_id", "-"),
        run.get("workflow_id", "-"),
        run.get("state", "-"),
        run.get("result", "-"),
        run.get("mode", "-"),
        run.get("cli", "-"),
        run.get("updated_at", "-"),
    )
    for run in runs
]

headers = ("RUN ID", "WORKFLOW", "STATE", "RESULT", "MODE", "CLI", "UPDATED")
widths = [len(h) for h in headers]
for row in rows:
    for i, value in enumerate(row):
        widths[i] = min(max(widths[i], len(str(value))), 40)


def clip(value, width):
    value = str(value)
    return value if len(value) <= width else value[: width - 3] + "..."


print(
    f"{headers[0]:<{widths[0]}}  "
    f"{headers[1]:<{widths[1]}}  "
    f"{headers[2]:<{widths[2]}}  "
    f"{headers[3]:<{widths[3]}}  "
    f"{headers[4]:<{widths[4]}}  "
    f"{headers[5]:<{widths[5]}}  "
    f"{headers[6]:<{widths[6]}}"
)
print(
    f"{'-' * widths[0]}  "
    f"{'-' * widths[1]}  "
    f"{'-' * widths[2]}  "
    f"{'-' * widths[3]}  "
    f"{'-' * widths[4]}  "
    f"{'-' * widths[5]}  "
    f"{'-' * widths[6]}"
)
for row in rows:
    print(
        f"{clip(row[0], widths[0]):<{widths[0]}}  "
        f"{clip(row[1], widths[1]):<{widths[1]}}  "
        f"{clip(row[2], widths[2]):<{widths[2]}}  "
        f"{clip(row[3], widths[3]):<{widths[3]}}  "
        f"{clip(row[4], widths[4]):<{widths[4]}}  "
        f"{clip(row[5], widths[5]):<{widths[5]}}  "
        f"{clip(row[6], widths[6]):<{widths[6]}}"
    )
PY
    ;;
  show)
    [ "$#" -eq 2 ] || usage
    WORKFLOW_REF="$(resolve_workflow_ref "$2")" || {
      echo "找不到 workflow：$2" >&2
      exit 1
    }
    "${PYTHON_BIN}" - <<'PY' "${CAP_ROOT}" "${WORKFLOW_REF}" "$(get_status_store)"
from pathlib import Path
import json
import sys

base_dir = Path(sys.argv[1])
sys.path.insert(0, str(base_dir))
from engine.workflow_loader import WorkflowLoader

workflow_ref = sys.argv[2]
status_file = Path(sys.argv[3])
loader = WorkflowLoader(base_dir=base_dir)
workflow = loader.load_workflow(workflow_ref)


def normalize(payload):
    if isinstance(payload, dict) and ("workflows" in payload or "runs" in payload):
        workflows = payload.get("workflows", {})
    elif isinstance(payload, dict):
        workflows = {k: v for k, v in payload.items() if isinstance(v, dict)}
    else:
        workflows = {}
    return workflows if isinstance(workflows, dict) else {}


status_data = {}
if status_file.exists():
    status_data = normalize(json.loads(status_file.read_text(encoding="utf-8")))
status = status_data.get(workflow["workflow_id"], {})

print("WORKFLOW INSPECT")
print(f"ID:          {workflow['workflow_id']}")
print(f"NAME:        {workflow['name']}")
print(f"VERSION:     {workflow['version']}")
print(f"STATUS:      {status.get('state', 'ready')}")
print(f"RUN COUNT:   {status.get('run_count', 0)}")
print(f"LAST RUN:    {status.get('last_run_at', '-')}")
print(f"LAST RESULT: {status.get('last_result', '-')}")
print(f"LAST RUN ID: {status.get('last_run_id', '-')}")
print(f"SOURCE:      {workflow['_source_path']}")
print(f"SUMMARY:     {workflow['summary']}")
triggers = workflow.get("triggers", [])
print(f"TRIGGERS:    {', '.join(triggers) if triggers else '-'}")
artifacts = workflow.get("artifacts", {})
print("STEPS:")
for step in workflow["steps"]:
    needs = ", ".join(step.get("needs", [])) or "-"
    outputs = ", ".join(step.get("outputs", [])) or "-"
    print(f"  - {step['id']}: {step['name']}")
    print(f"    capability: {step['capability']}")
    print(f"    needs:      {needs}")
    print(f"    outputs:    {outputs}")
if artifacts:
    print("ARTIFACTS:")
    for key, value in artifacts.items():
        print(f"  - {key}: {value}")
PY
    ;;
  inspect)
    [ "$#" -eq 2 ] || usage
    "${PYTHON_BIN}" - <<'PY' "$(get_status_store)" "$2"
from pathlib import Path
from datetime import datetime
import json
import sys

status_file = Path(sys.argv[1])
run_id = sys.argv[2]


def normalize(payload):
    if isinstance(payload, dict) and ("workflows" in payload or "runs" in payload):
        runs = payload.get("runs", [])
    else:
        runs = []
    return runs if isinstance(runs, list) else []


if not status_file.exists():
    print(f"找不到 run_id：{run_id}", file=sys.stderr)
    sys.exit(1)

runs = normalize(json.loads(status_file.read_text(encoding="utf-8")))
run = next((item for item in runs if item.get("run_id") == run_id), None)
if run is None:
    print(f"找不到 run_id：{run_id}", file=sys.stderr)
    sys.exit(1)

print("WORKFLOW RUN INSPECT")
print(f"RUN ID:      {run.get('run_id', '-')}")
print(f"WORKFLOW ID: {run.get('workflow_id', '-')}")
print(f"NAME:        {run.get('workflow_name', '-')}")
print(f"STATE:       {run.get('state', '-')}")
print(f"RESULT:      {run.get('result', '-')}")
print(f"MODE:        {run.get('mode', '-')}")
print(f"CLI:         {run.get('cli', '-')}")
print(f"CREATED AT:  {run.get('created_at', '-')}")
print(f"UPDATED AT:  {run.get('updated_at', '-')}")
print(f"STARTED AT:  {run.get('started_at', '-')}")
print(f"FINISHED AT: {run.get('finished_at', '-')}")
if run.get("started_at") and run.get("finished_at"):
    started = datetime.strptime(run["started_at"], "%Y-%m-%d %H:%M:%S")
    finished = datetime.strptime(run["finished_at"], "%Y-%m-%d %H:%M:%S")
    print(f"DURATION:    {int((finished - started).total_seconds())}s")
print(f"PROMPT:      {run.get('prompt_preview', '-') or '-'}")
print(f"STATUS FILE: {status_file}")
PY
    ;;
  plan)
    [ "$#" -eq 2 ] || usage
    WORKFLOW_REF="$(resolve_workflow_ref "$2")" || {
      echo "找不到 workflow：$2" >&2
      exit 1
    }
    "${PYTHON_BIN}" - <<'PY' "${CAP_ROOT}" "${WORKFLOW_REF}"
from pathlib import Path
import sys

base_dir = Path(sys.argv[1])
sys.path.insert(0, str(base_dir))
from engine.workflow_loader import WorkflowLoader

workflow_ref = sys.argv[2]
loader = WorkflowLoader(base_dir=base_dir)
plan = loader.build_execution_phases(workflow_ref)

print(f"workflow_id: {plan['workflow_id']}")
print(f"name: {plan['name']}")
print(f"version: {plan['version']}")
print(f"summary: {plan['summary']}")
print(f"source: {plan['source_path']}")
print("phases:")
for phase in plan["phases"]:
    print(f"  Phase {phase['phase']}:")
    for step in phase["steps"]:
        print(
            f"    - {step['step_id']} => capability={step['capability']} / "
            f"agent={step['agent_alias']} / needs={step['needs']}"
        )
if plan["standby_steps"]:
    print("standby_steps:")
    for step in plan["standby_steps"]:
        print(f"  - {step['step_id']}")
PY
    ;;
  run)
    shift || true

    DETACH=0
    RUN_CLI="${CAP_DEFAULT_AGENT_CLI:-claude}"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -d)       DETACH=1; shift ;;
        --cli)    RUN_CLI="$2"; shift 2 ;;
        *)        break ;;
      esac
    done

    [ "$#" -ge 1 ] || {
      echo "Usage: cap workflow run [-d] [--cli codex|claude] <workflow> [prompt...]" >&2
      exit 1
    }

    WORKFLOW_REF="$(resolve_workflow_ref "$1")" || {
      echo "找不到 workflow：$1" >&2
      exit 1
    }
    shift
    USER_PROMPT="$*"

    PLAN_JSON="$("${PYTHON_BIN}" - <<'PY' "${CAP_ROOT}" "${WORKFLOW_REF}"
from pathlib import Path
import json
import sys

base_dir = Path(sys.argv[1])
sys.path.insert(0, str(base_dir))
from engine.workflow_loader import WorkflowLoader

workflow_ref = sys.argv[2]
loader = WorkflowLoader(base_dir=base_dir)
result = loader.build_execution_phases(workflow_ref)
print(json.dumps(result, ensure_ascii=False))
PY
)"

    WORKFLOW_ID="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["workflow_id"])')"
    WORKFLOW_NAME="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["name"])')"

    if [ -z "${USER_PROMPT}" ]; then
      echo ""
      echo "WORKFLOW PLAN — ${WORKFLOW_NAME}"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo ""
      "${PYTHON_BIN}" - <<'PY' "${PLAN_JSON}"
import json
import sys

plan = json.loads(sys.argv[1])
total = len(plan["phases"])
for p in plan["phases"]:
    steps = p["steps"]
    ids = " + ".join(s["step_id"] for s in steps)
    agents = ", ".join(dict.fromkeys(s["agent_alias"] for s in steps))
    suffix = ""
    if len(steps) > 1:
        suffix = "  (parallel)"
    gate = p.get("gate", {})
    if gate and gate.get("type"):
        suffix = f"  gate:{gate['type']}"
    print(f"  Phase {p['phase']:>2}/{total}   {ids:<40} -> {agents}{suffix}")
if plan["standby_steps"]:
    print(f"\n  Standby: {', '.join(s['step_id'] for s in plan['standby_steps'])}")
PY
      echo ""
      echo "  To execute: cap workflow run ${WORKFLOW_ID} \"<prompt>\""
      echo ""
      exit 0
    fi

    if [ "${DETACH}" -eq 1 ]; then
      RUN_ID="$(create_workflow_run "${WORKFLOW_ID}" "${WORKFLOW_NAME}" "detached" "background_start" "detached" "${RUN_CLI}" "${USER_PROMPT}")"
      bash "${SCRIPT_DIR}/trace-log.sh" append "Workflow" "workflow:${WORKFLOW_ID} run:${RUN_ID} 啟動背景執行 (${WORKFLOW_NAME})" "成功" >/dev/null 2>&1 || true
      echo "Background mode is not yet implemented."
      echo "RUN ID: ${RUN_ID}"
      echo "Use foreground: cap workflow run ${WORKFLOW_ID} \"<prompt>\""
      exit 0
    fi

    RUN_ID="$(create_workflow_run "${WORKFLOW_ID}" "${WORKFLOW_NAME}" "executing" "foreground_start" "foreground" "${RUN_CLI}" "${USER_PROMPT}")"
    bash "${SCRIPT_DIR}/trace-log.sh" append "Workflow" "workflow:${WORKFLOW_ID} run:${RUN_ID} 啟動 (${WORKFLOW_NAME})" "成功" >/dev/null 2>&1 || true
    exec bash "${SCRIPT_DIR}/cap-workflow-exec.sh" "${PLAN_JSON}" "${USER_PROMPT}" --cli "${RUN_CLI}" --run-id "${RUN_ID}"
    ;;
  update-run-status)
    [ "$#" -eq 4 ] || usage
    update_workflow_run "$2" "$3" "$4"
    ;;
  *)
    usage
    ;;
esac
