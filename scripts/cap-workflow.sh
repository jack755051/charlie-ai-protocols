#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKFLOWS_DIR="${CAP_ROOT}/schemas/workflows"
VENV_PYTHON="${CAP_ROOT}/.venv/bin/python"
PATH_HELPER="${SCRIPT_DIR}/cap-paths.sh"
AGENT_HELPER="${SCRIPT_DIR}/cap-agent.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  bash scripts/cap-workflow.sh list
  bash scripts/cap-workflow.sh <workflow_id|short_id|file>
  bash scripts/cap-workflow.sh show <workflow_id|file>
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

  return 1
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

read_status_json() {
  local status_file="$1"
  if [ -f "${status_file}" ]; then
    cat "${status_file}"
  else
    printf '{}\n'
  fi
}

record_workflow_run() {
  local workflow_id="$1"
  local workflow_name="$2"
  local state="$3"
  local result="$4"
  local status_file
  status_file="$(get_status_store)"
  "${PYTHON_BIN}" - <<'PY' "${status_file}" "${workflow_id}" "${workflow_name}" "${state}" "${result}"
from pathlib import Path
import json
import sys
from datetime import datetime

status_file = Path(sys.argv[1])
workflow_id = sys.argv[2]
workflow_name = sys.argv[3]
state = sys.argv[4]
result = sys.argv[5]

data = {}
if status_file.exists():
    data = json.loads(status_file.read_text(encoding="utf-8"))

entry = data.get(workflow_id, {})
entry["workflow_name"] = workflow_name
entry["state"] = state
entry["last_result"] = result
entry["last_run_at"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
entry["run_count"] = int(entry.get("run_count", 0)) + 1
data[workflow_id] = entry

status_file.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
PY
}

status_field() {
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

if not status_file.exists():
    sys.exit(0)

data = json.loads(status_file.read_text(encoding="utf-8"))
entry = data.get(workflow_id, {})
value = entry.get(field, "")
if value is None:
    value = ""
print(value)
PY
}

PYTHON_BIN="$(resolve_python)"
ensure_status_store

COMMAND="${1:-}"
if [ -n "${COMMAND}" ] && [[ "${COMMAND}" != "list" && "${COMMAND}" != "show" && "${COMMAND}" != "plan" && "${COMMAND}" != "run" ]]; then
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
status_data = {}
if status_file.exists():
    status_data = json.loads(status_file.read_text(encoding="utf-8"))

rows = []
for path in files:
    raw = path.read_text(encoding="utf-8")
    data = yaml.safe_load(raw) if path.suffix in {".yaml", ".yml"} else {}
    workflow_id = data.get("workflow_id", path.stem)
    name = data.get("name", path.stem)
    summary = data.get("summary", "")
    short_id = "wf_" + hashlib.sha1(workflow_id.encode("utf-8")).hexdigest()[:8]
    status = status_data.get(workflow_id, {}).get("state", "ready")
    run_count = status_data.get(workflow_id, {}).get("run_count", 0)
    last_run_at = status_data.get(workflow_id, {}).get("last_run_at", "-")
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
status_data = {}
if status_file.exists():
    status_data = json.loads(status_file.read_text(encoding="utf-8"))
status = status_data.get(workflow["workflow_id"], {})

print("WORKFLOW INSPECT")
print(f"ID:          {workflow['workflow_id']}")
print(f"NAME:        {workflow['name']}")
print(f"VERSION:     {workflow['version']}")
print(f"STATUS:      {status.get('state', 'ready')}")
print(f"RUN COUNT:   {status.get('run_count', 0)}")
print(f"LAST RUN:    {status.get('last_run_at', '-')}")
print(f"LAST RESULT: {status.get('last_result', '-')}")
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

    # Parse -d flag
    DETACH=0
    if [ "${1:-}" = "-d" ]; then
      DETACH=1
      shift
    fi

    [ "$#" -ge 1 ] || {
      echo "Usage: cap workflow run [-d] <workflow> [prompt...]" >&2
      exit 1
    }

    WORKFLOW_REF="$(resolve_workflow_ref "$1")" || {
      echo "找不到 workflow：$1" >&2
      exit 1
    }
    shift
    USER_PROMPT="$*"

    # Build execution phases
    WORKFLOW_META="$("${PYTHON_BIN}" - <<'PY' "${CAP_ROOT}" "${WORKFLOW_REF}"
from pathlib import Path
import json
import sys

base_dir = Path(sys.argv[1])
sys.path.insert(0, str(base_dir))
from engine.workflow_loader import WorkflowLoader

workflow_ref = sys.argv[2]
loader = WorkflowLoader(base_dir=base_dir)
result = loader.build_execution_phases(workflow_ref)

phases_display = []
for phase in result["phases"]:
    steps = phase["steps"]
    ids = [s["step_id"] for s in steps]
    agents = list(dict.fromkeys(s["agent_alias"] for s in steps))
    gate = phase.get("gate", {}).get("type", "")
    phases_display.append({
        "phase": phase["phase"],
        "steps": ids,
        "agents": agents,
        "gate": gate,
    })

standby = [s["step_id"] for s in result["standby_steps"]]

print(json.dumps({
    "workflow_id": result["workflow_id"],
    "name": result["name"],
    "summary": result["summary"],
    "source": result["source_path"],
    "phases": phases_display,
    "standby": standby,
    "optional": result["optional_steps"],
}, ensure_ascii=False))
PY
)"

    WORKFLOW_ID="$(printf '%s' "${WORKFLOW_META}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["workflow_id"])')"
    WORKFLOW_NAME="$(printf '%s' "${WORKFLOW_META}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
    WORKFLOW_SUMMARY="$(printf '%s' "${WORKFLOW_META}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["summary"])')"
    WORKFLOW_SOURCE="$(printf '%s' "${WORKFLOW_META}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["source"])')"

    record_workflow_run "${WORKFLOW_ID}" "${WORKFLOW_NAME}" "running" "started"
    bash "${SCRIPT_DIR}/trace-log.sh" append "Workflow" "workflow:${WORKFLOW_ID} 啟動 (${WORKFLOW_NAME})" "成功" >/dev/null 2>&1 || true

    # Display phase plan
    echo ""
    echo "WORKFLOW RUN — ${WORKFLOW_NAME}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    "${PYTHON_BIN}" - <<'PY' "${WORKFLOW_META}"
import json, sys
meta = json.loads(sys.argv[1])
for p in meta["phases"]:
    steps_str = " + ".join(p["steps"])
    agents_str = ", ".join(p["agents"])
    suffix = ""
    if len(p["steps"]) > 1:
        suffix = "  (parallel)"
    if p["gate"]:
        suffix = f"  gate:{p['gate']}"
    print(f"  Phase {p['phase']:>2}   {steps_str:<40} -> {agents_str}{suffix}")
if meta["standby"]:
    print(f"\n  Standby: {', '.join(meta['standby'])}")
PY

    echo ""

    if [ "${DETACH}" -eq 1 ]; then
      # Background mode — record and exit
      record_workflow_run "${WORKFLOW_ID}" "${WORKFLOW_NAME}" "detached" "background_start"
      echo "  Background mode is not yet implemented."
      echo "  Use foreground: cap workflow run ${WORKFLOW_ID} \"<prompt>\""
      echo ""
      exit 0
    fi

    if [ -z "${USER_PROMPT}" ]; then
      echo "  Usage: cap workflow run <workflow> \"<prompt>\""
      echo ""
      exit 0
    fi

    echo "  Attaching to supervisor..."
    echo ""
    record_workflow_run "${WORKFLOW_ID}" "${WORKFLOW_NAME}" "invoked" "delegated_to_supervisor"
    exec bash "${AGENT_HELPER}" supervisor "請依照 ${WORKFLOW_SOURCE} 執行此 workflow。Workflow ID: ${WORKFLOW_ID}。Summary: ${WORKFLOW_SUMMARY}。使用者補充需求：${USER_PROMPT}"
    ;;
  *)
    usage
    ;;
esac
