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
  bash scripts/cap-workflow.sh bind <workflow_id|file> [registry]
  bash scripts/cap-workflow.sh constitution <request...>
  bash scripts/cap-workflow.sh compile <request...> [--registry path]
  bash scripts/cap-workflow.sh run-task [--dry-run] [-d] [--cli codex|claude] [--registry path] <request...>
  bash scripts/cap-workflow.sh run [--dry-run] [-d] [--cli codex|claude] <workflow_id|file> [prompt...]
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

persist_constitution_artifact() {
  local constitution_json="$1"
  local request="$2"
  local origin="$3"
  local constitution_dir

  bash "${PATH_HELPER}" ensure >/dev/null
  constitution_dir="$(bash "${PATH_HELPER}" get constitution_dir)"

  "${PYTHON_BIN}" - <<'PY' "${constitution_dir}" "${request}" "${origin}" "${constitution_json}"
from pathlib import Path
from datetime import datetime
import json
import sys

constitution_dir = Path(sys.argv[1])
request = sys.argv[2]
origin = sys.argv[3]
constitution = json.loads(sys.argv[4])

stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
task_id = constitution.get("task_id") or f"task-{stamp}"
task_dir = constitution_dir / task_id
task_dir.mkdir(parents=True, exist_ok=True)

json_path = task_dir / f"constitution-{stamp}.json"
md_path = task_dir / f"constitution-{stamp}.md"

payload = {
    "origin": origin,
    "request": request,
    "constitution": constitution,
}
json_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

lines = [
    "# Task Constitution Snapshot",
    "",
    f"- task_id: {task_id}",
    f"- origin: {origin}",
    f"- saved_at: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
    f"- goal_stage: {constitution.get('goal_stage', '-')}",
    f"- risk_profile: {constitution.get('risk_profile', '-')}",
    "",
    "## Request",
    "",
    request,
    "",
    "## Goal",
    "",
    constitution.get("goal", ""),
    "",
    "## Scope",
    "",
]
for item in constitution.get("scope", []):
    lines.append(f"- {item}")
lines.extend(["", "## Success Criteria", ""])
for item in constitution.get("success_criteria", []):
    lines.append(f"- {item}")
md_path.write_text("\n".join(lines).strip() + "\n", encoding="utf-8")

print(
    json.dumps(
        {
            "task_id": task_id,
            "json_path": str(json_path),
            "markdown_path": str(md_path),
        },
        ensure_ascii=False,
    )
)
PY
}

persist_binding_snapshot() {
  local binding_json="$1"
  local workflow_id="$2"
  local workflow_name="$3"
  local workflow_ref="$4"
  local origin="$5"
  local binding_dir

  bash "${PATH_HELPER}" ensure >/dev/null
  binding_dir="$(bash "${PATH_HELPER}" get binding_dir)"

  "${PYTHON_BIN}" - <<'PY' "${binding_dir}" "${workflow_id}" "${workflow_name}" "${workflow_ref}" "${origin}" "${binding_json}"
from pathlib import Path
from datetime import datetime
import json
import sys

binding_dir = Path(sys.argv[1])
workflow_id = sys.argv[2]
workflow_name = sys.argv[3]
workflow_ref = sys.argv[4]
origin = sys.argv[5]
binding = json.loads(sys.argv[6])

stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
workflow_dir = binding_dir / workflow_id
workflow_dir.mkdir(parents=True, exist_ok=True)

json_path = workflow_dir / f"binding-{stamp}.json"
md_path = workflow_dir / f"binding-{stamp}.md"

payload = {
    "origin": origin,
    "workflow_id": workflow_id,
    "workflow_name": workflow_name,
    "workflow_ref": workflow_ref,
    "saved_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    "binding": binding,
}
json_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

lines = [
    "# Workflow Binding Snapshot",
    "",
    f"- workflow_id: {workflow_id}",
    f"- workflow_name: {workflow_name}",
    f"- workflow_ref: {workflow_ref}",
    f"- origin: {origin}",
    f"- saved_at: {payload['saved_at']}",
    f"- binding_status: {binding.get('binding_status', '-')}",
    f"- registry_source: {binding.get('registry_source_path', '-')}",
    "",
    "## Steps",
    "",
]
for step in binding.get("steps", []):
    lines.append(
        f"- {step['step_id']}: {step['resolution_status']} / capability={step['capability']} / "
        f"skill={step.get('selected_skill_id') or '-'}"
    )
md_path.write_text("\n".join(lines).strip() + "\n", encoding="utf-8")

print(
    json.dumps(
        {
            "json_path": str(json_path),
            "markdown_path": str(md_path),
        },
        ensure_ascii=False,
    )
)
PY
}

persist_task_compile_bundle() {
  local compiled_json="$1"
  local request="$2"
  local registry_ref="$3"
  local origin="$4"
  local constitution_dir
  local compiled_workflow_dir
  local binding_dir

  bash "${PATH_HELPER}" ensure >/dev/null
  constitution_dir="$(bash "${PATH_HELPER}" get constitution_dir)"
  compiled_workflow_dir="$(bash "${PATH_HELPER}" get compiled_workflow_dir)"
  binding_dir="$(bash "${PATH_HELPER}" get binding_dir)"

  "${PYTHON_BIN}" - <<'PY' "${constitution_dir}" "${compiled_workflow_dir}" "${binding_dir}" "${request}" "${registry_ref}" "${origin}" "${compiled_json}"
from pathlib import Path
from datetime import datetime
import json
import sys

constitution_dir = Path(sys.argv[1])
compiled_workflow_dir = Path(sys.argv[2])
binding_dir = Path(sys.argv[3])
request = sys.argv[4]
registry_ref = sys.argv[5]
origin = sys.argv[6]
compiled = json.loads(sys.argv[7])

stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
constitution = compiled["task_constitution"]
graph = compiled["capability_graph"]
compiled_workflow = compiled["compiled_workflow"]
binding = compiled["binding"]
policy = compiled["unresolved_policy"]
plan = compiled["plan"]

task_id = constitution["task_id"]
workflow_id = plan["workflow_id"]

constitution_task_dir = constitution_dir / task_id
constitution_task_dir.mkdir(parents=True, exist_ok=True)
constitution_json_path = constitution_task_dir / f"constitution-{stamp}.json"
constitution_md_path = constitution_task_dir / f"constitution-{stamp}.md"
constitution_json_path.write_text(
    json.dumps({"origin": origin, "request": request, "constitution": constitution}, ensure_ascii=False, indent=2),
    encoding="utf-8",
)
constitution_md_lines = [
    "# Task Constitution Snapshot",
    "",
    f"- task_id: {task_id}",
    f"- origin: {origin}",
    f"- saved_at: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
    f"- goal_stage: {constitution.get('goal_stage', '-')}",
    f"- risk_profile: {constitution.get('risk_profile', '-')}",
    "",
    "## Request",
    "",
    request,
]
constitution_md_path.write_text("\n".join(constitution_md_lines).strip() + "\n", encoding="utf-8")

binding_task_dir = binding_dir / workflow_id
binding_task_dir.mkdir(parents=True, exist_ok=True)
binding_json_path = binding_task_dir / f"binding-{stamp}.json"
binding_md_path = binding_task_dir / f"binding-{stamp}.md"
binding_json_path.write_text(
    json.dumps(
        {
            "origin": origin,
            "task_id": task_id,
            "workflow_id": workflow_id,
            "request": request,
            "registry_ref": registry_ref or "",
            "binding": binding,
        },
        ensure_ascii=False,
        indent=2,
    ),
    encoding="utf-8",
)
binding_md_lines = [
    "# Workflow Binding Snapshot",
    "",
    f"- workflow_id: {workflow_id}",
    f"- task_id: {task_id}",
    f"- origin: {origin}",
    f"- saved_at: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
    f"- binding_status: {binding.get('binding_status', '-')}",
    f"- registry_source: {binding.get('registry_source_path', '-')}",
    "",
    "## Steps",
    "",
]
for step in binding.get("steps", []):
    binding_md_lines.append(
        f"- {step['step_id']}: {step['resolution_status']} / capability={step['capability']} / skill={step.get('selected_skill_id') or '-'}"
    )
binding_md_path.write_text("\n".join(binding_md_lines).strip() + "\n", encoding="utf-8")

bundle_dir = compiled_workflow_dir / task_id / stamp
bundle_dir.mkdir(parents=True, exist_ok=True)

bundle_files = {
    "task-constitution.json": constitution,
    "capability-graph.json": graph,
    "compiled-workflow.json": compiled_workflow,
    "binding-report.json": binding,
    "unresolved-policy.json": policy,
    "bound-plan.json": plan,
}
for filename, payload in bundle_files.items():
    (bundle_dir / filename).write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

summary_lines = [
    "# Compiled Workflow Bundle",
    "",
    f"- task_id: {task_id}",
    f"- workflow_id: {workflow_id}",
    f"- origin: {origin}",
    f"- saved_at: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
    f"- registry_ref: {registry_ref or '-'}",
    f"- binding_status: {binding.get('binding_status', '-')}",
    "",
    "## Request",
    "",
    request,
    "",
    "## Active Phases",
    "",
]
for phase in plan.get("phases", []):
    summary_lines.append(
        f"- Phase {phase['phase']}: " + " + ".join(step["step_id"] for step in phase.get("steps", []))
    )
if plan.get("standby_steps"):
    summary_lines.extend(["", "## Standby Steps", ""])
    for step in plan["standby_steps"]:
        summary_lines.append(f"- {step['step_id']}: {step.get('governance_reason', step.get('resolution_status', '-'))}")
    summary_lines.append("")
summary_lines.extend(
    [
        "## Stored Files",
        "",
        f"- constitution_json: {constitution_json_path}",
        f"- constitution_markdown: {constitution_md_path}",
        f"- binding_json: {binding_json_path}",
        f"- binding_markdown: {binding_md_path}",
        f"- bundle_dir: {bundle_dir}",
        "",
    ]
)
summary_path = bundle_dir / "README.md"
summary_path.write_text("\n".join(summary_lines), encoding="utf-8")

print(
    json.dumps(
        {
            "task_id": task_id,
            "workflow_id": workflow_id,
            "constitution_json_path": str(constitution_json_path),
            "constitution_markdown_path": str(constitution_md_path),
            "binding_json_path": str(binding_json_path),
            "binding_markdown_path": str(binding_md_path),
            "bundle_dir": str(bundle_dir),
            "bundle_readme_path": str(summary_path),
        },
        ensure_ascii=False,
    )
)
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
if [ -n "${COMMAND}" ] && [[ "${COMMAND}" != "list" && "${COMMAND}" != "ps" && "${COMMAND}" != "show" && "${COMMAND}" != "inspect" && "${COMMAND}" != "plan" && "${COMMAND}" != "bind" && "${COMMAND}" != "constitution" && "${COMMAND}" != "compile" && "${COMMAND}" != "run-task" && "${COMMAND}" != "run" && "${COMMAND}" != "update-run-status" ]]; then
  # cap workflow <id> "prompt" → run <id> "prompt"
  # cap workflow <id>          → show <id>
  if [ "$#" -ge 2 ]; then
    set -- run "$@"
  else
    set -- show "$@"
  fi
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
    summary = data.get("summary", "")
    rows.append((workflow_id, path.name, summary))

headers = ("ID", "FILE", "SUMMARY")
widths = [len(h) for h in headers]
for row in rows:
    for i, value in enumerate(row):
        widths[i] = min(max(widths[i], len(str(value))), 70)


def clip(value, width):
    value = str(value)
    return value if len(value) <= width else value[: width - 3] + "..."


print("WORKFLOW LIST")
print(
    f"{headers[0]:<{widths[0]}}  "
    f"{headers[1]:<{widths[1]}}  "
    f"{headers[2]:<{widths[2]}}"
)
print(
    f"{'-' * widths[0]}  "
    f"{'-' * widths[1]}  "
    f"{'-' * widths[2]}"
)
for row in rows:
    print(
        f"{clip(row[0], widths[0]):<{widths[0]}}  "
        f"{clip(row[1], widths[1]):<{widths[1]}}  "
        f"{clip(row[2], widths[2]):<{widths[2]}}"
    )
PY
    ;;
  ps)
    shift || true
    PS_FILTER="active"
    if [ "${1:-}" = "--all" ] || [ "${1:-}" = "-a" ]; then
      PS_FILTER="all"
      shift || true
    fi
    "${PYTHON_BIN}" - <<'PY' "$(get_status_store)" "${PS_FILTER}"
from pathlib import Path
import json
import sys

status_file = Path(sys.argv[1])
ps_filter = sys.argv[2] if len(sys.argv) > 2 else "active"


def normalize(payload):
    if isinstance(payload, dict) and ("workflows" in payload or "runs" in payload):
        runs = payload.get("runs", [])
    else:
        runs = []
    return runs if isinstance(runs, list) else []


runs = []
if status_file.exists():
    runs = normalize(json.loads(status_file.read_text(encoding="utf-8")))

if ps_filter == "active":
    runs = [r for r in runs if r.get("state") in {"executing", "pending"}]

runs = sorted(
    runs,
    key=lambda r: (
        r.get("updated_at", ""),
        r.get("created_at", ""),
        r.get("run_id", ""),
    ),
    reverse=True,
)

header_label = "ACTIVE WORKFLOW RUNS" if ps_filter == "active" else "ALL WORKFLOW RUNS"
print(header_label)
if not runs:
    if ps_filter == "active":
        print("No active workflow runs. Use 'cap workflow ps --all' to see history.")
    else:
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
from engine.runtime_binder import RuntimeBinder

workflow_ref = sys.argv[2]
loader = WorkflowLoader(base_dir=base_dir)
binder = RuntimeBinder(base_dir=base_dir)
semantic = loader.build_semantic_plan(workflow_ref)
plan = binder.build_bound_execution_phases(workflow_ref)
binding = plan["binding"]

print(f"workflow_id: {plan['workflow_id']}")
print(f"name: {plan['name']}")
print(f"version: {plan['version']}")
print(f"summary: {plan['summary']}")
print(f"source: {plan['source_path']}")
print(f"binding_status: {binding['binding_status']}")
print(f"registry_missing: {binding['registry_missing']}")
print(f"adapter_from_legacy: {binding['adapter_from_legacy']}")
print("semantic_phases:")
for phase in semantic["phases"]:
    print(f"  Phase {phase['phase']}:")
    for step in phase["steps"]:
        print(
            f"    - {step['step_id']} => capability={step['capability']} / "
            f"needs={step['needs']} / optional={step['optional']}"
        )
print("phases:")
for phase in plan["phases"]:
    print(f"  Phase {phase['phase']}:")
    for step in phase["steps"]:
        print(
            f"    - {step['step_id']} => capability={step['capability']} / "
            f"agent={step['agent_alias'] or '-'} / needs={step['needs']}"
        )
if plan["standby_steps"]:
    print("standby_steps:")
    for step in plan["standby_steps"]:
        print(f"  - {step['step_id']}")
print("binding_steps:")
for step in binding["steps"]:
    print(
        f"  - {step['step_id']} => status={step['resolution_status']} / "
        f"skill={step['selected_skill_id'] or '-'} / policy={step['missing_policy']}"
    )
PY
    ;;
  bind)
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
    WORKFLOW_REF="$(resolve_workflow_ref "$2")" || {
      echo "找不到 workflow：$2" >&2
      exit 1
    }
    REGISTRY_REF="${3:-}"
    BINDING_JSON="$("${PYTHON_BIN}" - <<'PY' "${CAP_ROOT}" "${WORKFLOW_REF}" "${REGISTRY_REF}"
from pathlib import Path
import json
import sys

base_dir = Path(sys.argv[1])
sys.path.insert(0, str(base_dir))
from engine.runtime_binder import RuntimeBinder

workflow_ref = sys.argv[2]
registry_ref = sys.argv[3] or None
binder = RuntimeBinder(base_dir=base_dir)
report = binder.bind_capabilities(workflow_ref, registry_ref)
print(json.dumps(report, ensure_ascii=False))
PY
)"
    BINDING_WORKFLOW_ID="$(printf '%s' "${BINDING_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["workflow_id"])')"
    BINDING_WORKFLOW_NAME="$(basename "${WORKFLOW_REF}")"
    BINDING_SNAPSHOT_JSON="$(persist_binding_snapshot "${BINDING_JSON}" "${BINDING_WORKFLOW_ID}" "${BINDING_WORKFLOW_NAME}" "${WORKFLOW_REF}" "bind")"
    "${PYTHON_BIN}" - <<'PY' "${BINDING_JSON}" "${BINDING_SNAPSHOT_JSON}"
import json
import sys

report = json.loads(sys.argv[1])
snapshot = json.loads(sys.argv[2])
print("WORKFLOW BINDING REPORT")
print(f"workflow_id: {report['workflow_id']}")
print(f"workflow_version: {report['workflow_version']}")
print(f"binding_status: {report['binding_status']}")
print(f"registry_source: {report['registry_source_path']}")
print(f"registry_missing: {report['registry_missing']}")
print(f"adapter_from_legacy: {report['adapter_from_legacy']}")
print("stored:")
print(f"  - json: {snapshot['json_path']}")
print(f"  - markdown: {snapshot['markdown_path']}")
print(
    "summary: "
    f"total={report['summary']['total_steps']}, "
    f"resolved={report['summary']['resolved_steps']}, "
    f"fallback={report['summary']['fallback_steps']}, "
    f"required_unresolved={report['summary']['unresolved_required_steps']}, "
    f"optional_unresolved={report['summary']['unresolved_optional_steps']}"
)
if report["contract_missing_steps"]:
    print(f"contract_missing_steps: {', '.join(report['contract_missing_steps'])}")
print("steps:")
for step in report["steps"]:
    print(
        f"  - {step['step_id']} (phase {step['phase']}) => "
        f"{step['resolution_status']} / capability={step['capability']} / "
        f"skill={step['selected_skill_id'] or '-'} / provider={step['selected_provider'] or '-'}"
    )
    print(
        f"    binding_mode={step['binding_mode']} / missing_policy={step['missing_policy']} / "
        f"reason={step['reason']}"
    )
PY
    ;;
  constitution)
    shift || true
    [ "$#" -ge 1 ] || {
      echo "Usage: cap workflow constitution <request...>" >&2
      exit 1
    }
    REQUEST="$*"
    CONSTITUTION_JSON="$("${PYTHON_BIN}" - <<'PY' "${CAP_ROOT}" "${REQUEST}"
from pathlib import Path
import json
import sys

base_dir = Path(sys.argv[1])
request = sys.argv[2]
sys.path.insert(0, str(base_dir))
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler

compiler = TaskScopedWorkflowCompiler(base_dir=base_dir)
constitution = compiler.build_task_constitution(request)
print(json.dumps(constitution, ensure_ascii=False))
PY
)"
    CONSTITUTION_SNAPSHOT_JSON="$(persist_constitution_artifact "${CONSTITUTION_JSON}" "${REQUEST}" "constitution")"
    "${PYTHON_BIN}" - <<'PY' "${CONSTITUTION_JSON}" "${CONSTITUTION_SNAPSHOT_JSON}"
import json
import sys

constitution = json.loads(sys.argv[1])
snapshot = json.loads(sys.argv[2])
print("TASK CONSTITUTION")
print(f"task_id: {constitution['task_id']}")
print(f"goal_stage: {constitution['goal_stage']}")
print(f"risk_profile: {constitution['risk_profile']}")
print(f"goal: {constitution['goal']}")
print("scope:")
for item in constitution.get("scope", []):
    print(f"  - {item}")
print("success_criteria:")
for item in constitution.get("success_criteria", []):
    print(f"  - {item}")
if constitution.get("constraints"):
    print("constraints:")
    for item in constitution["constraints"]:
        print(f"  - {item}")
if constitution.get("non_goals"):
    print("non_goals:")
    for item in constitution["non_goals"]:
        print(f"  - {item}")
print("inferred_context:")
for key, value in constitution.get("inferred_context", {}).items():
    print(f"  - {key}: {value}")
if constitution.get("required_questions"):
    print("required_questions:")
    for item in constitution["required_questions"]:
        print(f"  - {item}")
print("stored:")
print(f"  - json: {snapshot['json_path']}")
print(f"  - markdown: {snapshot['markdown_path']}")
print("raw_json:")
print(json.dumps(constitution, ensure_ascii=False, indent=2))
PY
    ;;
  compile)
    shift || true
    REGISTRY_REF=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --registry) REGISTRY_REF="$2"; shift 2 ;;
        *) break ;;
      esac
    done
    [ "$#" -ge 1 ] || {
      echo "Usage: cap workflow compile <request...> [--registry path]" >&2
      exit 1
    }
    REQUEST="$*"
    COMPILED_JSON="$("${PYTHON_BIN}" - <<'PY' "${CAP_ROOT}" "${REQUEST}" "${REGISTRY_REF}"
from pathlib import Path
import json
import sys

base_dir = Path(sys.argv[1])
request = sys.argv[2]
registry_ref = sys.argv[3] or None
sys.path.insert(0, str(base_dir))
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler

compiler = TaskScopedWorkflowCompiler(base_dir=base_dir)
compiled = compiler.compile_task(request, registry_ref=registry_ref)
print(json.dumps(compiled, ensure_ascii=False))
PY
)"
    COMPILE_SNAPSHOT_JSON="$(persist_task_compile_bundle "${COMPILED_JSON}" "${REQUEST}" "${REGISTRY_REF}" "compile")"
    "${PYTHON_BIN}" - <<'PY' "${COMPILED_JSON}" "${COMPILE_SNAPSHOT_JSON}"
import json
import sys

compiled = json.loads(sys.argv[1])
snapshot = json.loads(sys.argv[2])
constitution = compiled["task_constitution"]
graph = compiled["capability_graph"]
binding = compiled["binding"]
plan = compiled["plan"]
policy = compiled["unresolved_policy"]

print("TASK COMPILE REPORT")
print(f"task_id: {constitution['task_id']}")
print(f"goal_stage: {constitution['goal_stage']}")
print(f"workflow_id: {plan['workflow_id']}")
print(f"binding_status: {binding['binding_status']}")
print("stored:")
print(f"  - constitution_json: {snapshot['constitution_json_path']}")
print(f"  - binding_json: {snapshot['binding_json_path']}")
print(f"  - bundle_dir: {snapshot['bundle_dir']}")
print("capability_graph:")
for node in graph["nodes"]:
    print(f"  - {node['step_id']} => {node['capability']} / required={node['required']} / depends_on={node['depends_on']}")
print("unresolved_policy:")
for decision in policy["decisions"]:
    print(
        f"  - {decision['step_id']} => {decision['resolution_status']} / "
        f"action={decision['action']} / reason={decision['reason']}"
    )
print("compiled_phases:")
for phase in plan["phases"]:
    print(f"  Phase {phase['phase']}:")
    for step in phase["steps"]:
        print(
            f"    - {step['step_id']} => capability={step['capability']} / "
            f"agent={step['agent_alias'] or '-'} / input_mode={step.get('input_mode')} / "
            f"continue_reason={step.get('continue_reason')}"
        )
if plan["standby_steps"]:
    print("standby_steps:")
    for step in plan["standby_steps"]:
        print(f"  - {step['step_id']} => {step.get('governance_reason', step.get('resolution_status'))}")
PY
    ;;
  run-task)
    shift || true

    DETACH=0
    DRY_RUN=0
    RUN_CLI="${CAP_DEFAULT_AGENT_CLI:-auto}"
    CLI_OVERRIDE=0
    REGISTRY_REF=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -d) DETACH=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --cli) RUN_CLI="$2"; CLI_OVERRIDE=1; shift 2 ;;
        --registry) REGISTRY_REF="$2"; shift 2 ;;
        *) break ;;
      esac
    done

    [ "$#" -ge 1 ] || {
      echo "Usage: cap workflow run-task [--dry-run] [-d] [--cli codex|claude] [--registry path] <request...>" >&2
      exit 1
    }

    USER_PROMPT="$*"
    COMPILED_JSON="$("${PYTHON_BIN}" - <<'PY' "${CAP_ROOT}" "${USER_PROMPT}" "${REGISTRY_REF}"
from pathlib import Path
import json
import sys

base_dir = Path(sys.argv[1])
request = sys.argv[2]
registry_ref = sys.argv[3] or None
sys.path.insert(0, str(base_dir))
from engine.task_scoped_compiler import TaskScopedWorkflowCompiler

compiler = TaskScopedWorkflowCompiler(base_dir=base_dir)
compiled = compiler.compile_task(request, registry_ref=registry_ref)
print(json.dumps(compiled, ensure_ascii=False))
PY
)"

    PLAN_JSON="$(printf '%s' "${COMPILED_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["plan"], ensure_ascii=False))')"
    CONSTITUTION_JSON="$(printf '%s' "${COMPILED_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["task_constitution"], ensure_ascii=False))')"
    POLICY_JSON="$(printf '%s' "${COMPILED_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["unresolved_policy"], ensure_ascii=False))')"
    WORKFLOW_ID="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["workflow_id"])')"
    WORKFLOW_NAME="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
    BINDING_JSON="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["binding"], ensure_ascii=False))')"
    BINDING_STATUS="$(printf '%s' "${BINDING_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["binding_status"])')"
    COMPILE_SNAPSHOT_JSON="$(persist_task_compile_bundle "${COMPILED_JSON}" "${USER_PROMPT}" "${REGISTRY_REF}" "run-task")"

    if [ "${DRY_RUN}" -eq 1 ]; then
      echo ""
      echo "COMPILED WORKFLOW DRY RUN — ${WORKFLOW_NAME}"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      "${PYTHON_BIN}" - <<'PY' "${CONSTITUTION_JSON}" "${POLICY_JSON}" "${PLAN_JSON}" "${COMPILE_SNAPSHOT_JSON}"
import json
import sys

constitution = json.loads(sys.argv[1])
policy = json.loads(sys.argv[2])
plan = json.loads(sys.argv[3])
snapshot = json.loads(sys.argv[4])

print(f"task_id: {constitution['task_id']}")
print(f"goal_stage: {constitution['goal_stage']}")
print(f"risk_profile: {constitution['risk_profile']}")
print("stored:")
print(f"  - constitution_json: {snapshot['constitution_json_path']}")
print(f"  - binding_json: {snapshot['binding_json_path']}")
print(f"  - bundle_dir: {snapshot['bundle_dir']}")
print("unresolved_policy:")
for item in policy["decisions"]:
    print(f"  - {item['step_id']}: {item['action']} ({item['resolution_status']})")
print("phases:")
total = len(plan["phases"])
for p in plan["phases"]:
    ids = " + ".join(s["step_id"] for s in p["steps"])
    agents = ", ".join(dict.fromkeys((s["agent_alias"] or s["skill_id"] or "-") for s in p["steps"]))
    print(f"  Phase {p['phase']:>2}/{total}   {ids:<30} -> {agents}")
if plan["standby_steps"]:
    print("standby:")
    for step in plan["standby_steps"]:
        print(f"  - {step['step_id']} => {step.get('governance_reason', step.get('resolution_status'))}")
PY
      echo ""
      exit 0
    fi

    if [ "${BINDING_STATUS}" = "blocked" ]; then
      echo ""
      echo "COMPILED WORKFLOW PREFLIGHT BLOCKED — ${WORKFLOW_NAME}"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      "${PYTHON_BIN}" - <<'PY' "${CONSTITUTION_JSON}" "${POLICY_JSON}" "${BINDING_JSON}" "${COMPILE_SNAPSHOT_JSON}"
import json
import sys

constitution = json.loads(sys.argv[1])
policy = json.loads(sys.argv[2])
binding = json.loads(sys.argv[3])
snapshot = json.loads(sys.argv[4])
print(f"task_id: {constitution['task_id']}")
print(f"goal_stage: {constitution['goal_stage']}")
print(f"binding_status: {binding['binding_status']}")
print(f"binding_json: {snapshot['binding_json_path']}")
print(f"bundle_dir: {snapshot['bundle_dir']}")
print("policy decisions:")
for item in policy["decisions"]:
    if item["action"] in {"pending", "manual", "re_scope"}:
        print(f"  - {item['step_id']} => {item['action']} / {item['reason']}")
PY
      echo ""
      exit 2
    fi

    if [ "${BINDING_STATUS}" = "degraded" ]; then
      echo ""
      echo "COMPILED WORKFLOW PREFLIGHT DEGRADED — ${WORKFLOW_NAME}"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      "${PYTHON_BIN}" - <<'PY' "${POLICY_JSON}" "${COMPILE_SNAPSHOT_JSON}"
import json
import sys

policy = json.loads(sys.argv[1])
snapshot = json.loads(sys.argv[2])
print(f"binding_json: {snapshot['binding_json_path']}")
print(f"bundle_dir: {snapshot['bundle_dir']}")
for item in policy["decisions"]:
    if item["action"] in {"fallback", "skip"}:
        print(f"  - {item['step_id']} => {item['action']} / {item['reason']}")
PY
      echo ""
    fi

    if [ "${DETACH}" -eq 1 ]; then
      RUN_ID="$(create_workflow_run "${WORKFLOW_ID}" "${WORKFLOW_NAME}" "detached" "background_start" "detached" "${RUN_CLI}" "${USER_PROMPT}")"
      echo "Background mode is not yet implemented."
      echo "RUN ID: ${RUN_ID}"
      exit 0
    fi

    RUN_ID="$(create_workflow_run "${WORKFLOW_ID}" "${WORKFLOW_NAME}" "executing" "foreground_start" "foreground" "${RUN_CLI}" "${USER_PROMPT}")"
    bash "${SCRIPT_DIR}/trace-log.sh" append "Workflow" "compiled_workflow:${WORKFLOW_ID} run:${RUN_ID} 啟動 (${WORKFLOW_NAME})" "成功" >/dev/null 2>&1 || true
    "${PYTHON_BIN}" - <<'PY' "${COMPILE_SNAPSHOT_JSON}" "${RUN_ID}"
import json
import sys

snapshot = json.loads(sys.argv[1])
run_id = sys.argv[2]
print(f"  Constitution: {snapshot['constitution_json_path']}")
print(f"  Binding: {snapshot['binding_json_path']}")
print(f"  Compiled bundle: {snapshot['bundle_dir']}")
print(f"  Run ID: {run_id}")
PY
    if [ "${CLI_OVERRIDE}" -eq 1 ]; then
      exec bash "${SCRIPT_DIR}/cap-workflow-exec.sh" "${PLAN_JSON}" "${USER_PROMPT}" --cli "${RUN_CLI}" --run-id "${RUN_ID}"
    fi
    exec bash "${SCRIPT_DIR}/cap-workflow-exec.sh" "${PLAN_JSON}" "${USER_PROMPT}" --run-id "${RUN_ID}"
    ;;
  run)
    shift || true

    DETACH=0
    DRY_RUN=0
    RUN_CLI="${CAP_DEFAULT_AGENT_CLI:-auto}"
    CLI_OVERRIDE=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -d)       DETACH=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --cli)    RUN_CLI="$2"; CLI_OVERRIDE=1; shift 2 ;;
        *)        break ;;
      esac
    done

    [ "$#" -ge 1 ] || {
      echo "Usage: cap workflow run [--dry-run] [-d] [--cli codex|claude] <workflow> [prompt...]" >&2
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
from engine.runtime_binder import RuntimeBinder

workflow_ref = sys.argv[2]
loader = RuntimeBinder(base_dir=base_dir)
result = loader.build_bound_execution_phases(workflow_ref)
print(json.dumps(result, ensure_ascii=False))
PY
)"

    WORKFLOW_ID="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["workflow_id"])')"
    WORKFLOW_NAME="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
    BINDING_JSON="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["binding"], ensure_ascii=False))')"
    BINDING_STATUS="$(printf '%s' "${BINDING_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["binding_status"])')"
    BINDING_SNAPSHOT_JSON="$(persist_binding_snapshot "${BINDING_JSON}" "${WORKFLOW_ID}" "${WORKFLOW_NAME}" "${WORKFLOW_REF}" "run")"

    if [ -z "${USER_PROMPT}" ]; then
      if [ -t 0 ]; then
        printf '請輸入 workflow 任務說明（直接 Enter 僅顯示 plan）: ' >&2
        read -r USER_PROMPT || true
      fi
    fi

    if [ -z "${USER_PROMPT}" ] || [ "${DRY_RUN}" -eq 1 ]; then
      echo ""
      if [ "${DRY_RUN}" -eq 1 ]; then
        echo "WORKFLOW DRY RUN — ${WORKFLOW_NAME}"
      else
        echo "WORKFLOW PLAN — ${WORKFLOW_NAME}"
      fi
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
    agents = ", ".join(dict.fromkeys((s["agent_alias"] or s["skill_id"] or "-") for s in steps))
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
      "${PYTHON_BIN}" - <<'PY' "${BINDING_JSON}" "${BINDING_SNAPSHOT_JSON}"
import json
import sys

binding = json.loads(sys.argv[1])
snapshot = json.loads(sys.argv[2])
print(f"  Binding: {binding['binding_status']}  |  registry_missing={binding['registry_missing']}  |  adapter_from_legacy={binding['adapter_from_legacy']}")
print(f"  Binding file: {snapshot['json_path']}")
for step in binding["steps"]:
    print(f"    - {step['step_id']}: {step['resolution_status']} -> {step['selected_skill_id'] or '-'}")
PY
      echo ""
      if [ "${DRY_RUN}" -eq 1 ]; then
        echo "  Dry run only — no step was executed."
      else
        echo "  To execute: cap workflow run ${WORKFLOW_ID} \"<prompt>\""
      fi
      echo ""
      exit 0
    fi

    if [ "${BINDING_STATUS}" = "blocked" ]; then
      echo ""
      echo "WORKFLOW PREFLIGHT BLOCKED — ${WORKFLOW_NAME}"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      "${PYTHON_BIN}" - <<'PY' "${BINDING_JSON}" "${BINDING_SNAPSHOT_JSON}"
import json
import sys

binding = json.loads(sys.argv[1])
snapshot = json.loads(sys.argv[2])
print(f"binding_status: {binding['binding_status']}")
print(f"registry_source: {binding['registry_source_path']}")
print(f"registry_missing: {binding['registry_missing']}")
print(f"adapter_from_legacy: {binding['adapter_from_legacy']}")
print(f"binding_json: {snapshot['json_path']}")
print("unresolved steps:")
for step in binding["steps"]:
    if step["resolution_status"] in {"required_unresolved", "incompatible"}:
        print(f"  - {step['step_id']} => {step['resolution_status']} / capability={step['capability']} / reason={step['reason']}")
PY
      echo ""
      echo "Workflow 已停止，請先補齊 skill registry 或調整 binding policy。"
      exit 2
    fi

    if [ "${BINDING_STATUS}" = "degraded" ]; then
      echo ""
      echo "WORKFLOW PREFLIGHT DEGRADED — ${WORKFLOW_NAME}"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      "${PYTHON_BIN}" - <<'PY' "${BINDING_JSON}" "${BINDING_SNAPSHOT_JSON}"
import json
import sys

binding = json.loads(sys.argv[1])
snapshot = json.loads(sys.argv[2])
print(f"binding_status: {binding['binding_status']}")
print(f"registry_source: {binding['registry_source_path']}")
print(f"registry_missing: {binding['registry_missing']}")
print(f"adapter_from_legacy: {binding['adapter_from_legacy']}")
print(f"binding_json: {snapshot['json_path']}")
print("degraded steps:")
for step in binding["steps"]:
    if step["resolution_status"] in {"fallback_available", "optional_unresolved"}:
        print(f"  - {step['step_id']} => {step['resolution_status']} / capability={step['capability']} / selected={step['selected_skill_id'] or '-'}")
PY
      echo ""
      echo "將以 degraded 模式繼續執行。"
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
    "${PYTHON_BIN}" - <<'PY' "${BINDING_SNAPSHOT_JSON}" "${RUN_ID}"
import json
import sys

snapshot = json.loads(sys.argv[1])
run_id = sys.argv[2]
print(f"  Binding: {snapshot['json_path']}")
print(f"  Run ID: {run_id}")
PY
    if [ "${CLI_OVERRIDE}" -eq 1 ]; then
      exec bash "${SCRIPT_DIR}/cap-workflow-exec.sh" "${PLAN_JSON}" "${USER_PROMPT}" --cli "${RUN_CLI}" --run-id "${RUN_ID}"
    fi
    exec bash "${SCRIPT_DIR}/cap-workflow-exec.sh" "${PLAN_JSON}" "${USER_PROMPT}" --run-id "${RUN_ID}"
    ;;
  update-run-status)
    [ "$#" -eq 4 ] || usage
    update_workflow_run "$2" "$3" "$4"
    ;;
  *)
    usage
    ;;
esac
