"""Consolidated CLI entry point for workflow operations.

Replaces all inline Python heredoc blocks from ``scripts/cap-workflow.sh``
with proper functions, callable as::

    python3 engine/workflow_cli.py <subcommand> [args...]

Requires Python 3.10+.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import uuid
from datetime import datetime, timedelta
from pathlib import Path

import yaml


# ---------------------------------------------------------------------------
# Shared helpers (status store normalisation)
# ---------------------------------------------------------------------------

def _normalize_payload(payload: object) -> dict:
    """Normalise a legacy or v2 status store payload to v2 format."""
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


def _load_payload(path: Path) -> dict:
    if not path.exists():
        return _normalize_payload({})
    return _normalize_payload(json.loads(path.read_text(encoding="utf-8")))


def _normalize_workflows_only(payload: object) -> dict:
    """Return only the workflows dict from a status store payload."""
    if isinstance(payload, dict) and ("workflows" in payload or "runs" in payload):
        workflows = payload.get("workflows", {})
    elif isinstance(payload, dict):
        workflows = {k: v for k, v in payload.items() if isinstance(v, dict)}
    else:
        workflows = {}
    return workflows if isinstance(workflows, dict) else {}


def _normalize_runs_only(payload: object) -> list:
    """Return only the runs list from a status store payload."""
    if isinstance(payload, dict) and ("workflows" in payload or "runs" in payload):
        runs = payload.get("runs", [])
    else:
        runs = []
    return runs if isinstance(runs, list) else []


def _recompute_workflow(payload: dict, target_workflow_id: str) -> None:
    """Recompute the workflows summary entry for *target_workflow_id*."""
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


def _clip(value: str, width: int) -> str:
    value = str(value)
    return value if len(value) <= width else value[: width - 3] + "..."


def _load_json_arg(raw: str) -> dict:
    return json.loads(raw)


# ---------------------------------------------------------------------------
# Subcommand: resolve-ref
# ---------------------------------------------------------------------------

def cmd_resolve_ref(workflows_dir: str, raw_ref: str) -> None:
    """Resolve a workflow reference to an absolute file path."""
    legacy_aliases = {
        "version-control-private": "version-control",
        "version-control-quick": "version-control",
        "version-control-company": "version-control",
    }
    raw_ref = legacy_aliases.get(raw_ref, raw_ref)
    wdir = Path(workflows_dir)
    for path in sorted(wdir.iterdir()):
        if not path.is_file() or path.suffix not in {".yaml", ".yml", ".json"}:
            continue
        data = yaml.safe_load(path.read_text(encoding="utf-8")) if path.suffix in {".yaml", ".yml"} else {}
        workflow_id = data.get("workflow_id", path.stem)
        short_id = "wf_" + hashlib.sha1(workflow_id.encode("utf-8")).hexdigest()[:8]
        if raw_ref in {workflow_id, short_id, path.stem, path.name}:
            print(path)
            sys.exit(0)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Subcommand: resolve-mode
# ---------------------------------------------------------------------------

def cmd_resolve_mode(
    cap_root: str,
    workflow_ref: str,
    requested_strategy: str,
    user_prompt: str,
    changed_files: str,
) -> None:
    """Resolve execution strategy for the version-control workflow."""
    base_dir = Path(cap_root)
    workflow_path = Path(workflow_ref)
    changed = [line.strip() for line in changed_files.splitlines() if line.strip()]

    workflow_data = yaml.safe_load(workflow_path.read_text(encoding="utf-8"))
    workflow_id = workflow_data.get("workflow_id", workflow_path.stem)

    version_control_path = base_dir / "schemas/workflows/version-control.yaml"
    family_ids = {
        "version-control",
        "version-control-private",
        "version-control-quick",
        "version-control-company",
    }

    result: dict = {
        "selector_applied": False,
        "requested_strategy": requested_strategy,
        "selected_strategy": "fixed",
        "requested_mode": requested_strategy,
        "selected_mode": "fixed",
        "confidence": "high",
        "reason": "workflow does not require strategy routing",
        "selected_workflow_ref": str(workflow_path),
        "selected_workflow_id": workflow_id,
        "original_workflow_id": workflow_id,
    }

    if workflow_id not in family_ids:
        print(json.dumps(result, ensure_ascii=False))
        raise SystemExit(0)

    prompt = user_prompt.lower().strip()
    release_keywords = [
        "release", "tag", "changelog", "readme", "版本號", "版號", "發版", "正式發版",
        "同步 changelog", "同步 readme", "版本徽章", "release note", "發佈",
    ]
    quick_keywords = [
        "版本更新", "commit", "提交", "快速提交", "只要 commit", "只做 commit",
        "整理這次變更", "存檔", "快速版控", "quick commit",
    ]

    changed_lower = [p.lower() for p in changed]
    release_file_touched = any(
        p in {"readme.md", "changelog.md", "repo.manifest.yaml"} or p.endswith("/readme.md")
        for p in changed_lower
    )
    explicit_governed = any(keyword in prompt for keyword in release_keywords)
    explicit_quick = any(keyword in prompt for keyword in quick_keywords)

    if requested_strategy in {"quick", "fast"}:
        selected_strategy = "fast"
        reason = "explicit fast strategy"
        confidence = "high"
    elif requested_strategy == "governed":
        selected_strategy = "governed"
        reason = "explicit governed strategy"
        confidence = "high"
    elif requested_strategy in {"strict", "company"}:
        selected_strategy = "strict"
        reason = "explicit strict strategy"
        confidence = "high"
    elif workflow_id == "version-control-quick":
        selected_strategy = "fast"
        reason = "legacy quick workflow alias requested"
        confidence = "high"
    elif workflow_id == "version-control-company":
        selected_strategy = "strict"
        reason = "legacy company workflow alias requested"
        confidence = "high"
    elif workflow_id == "version-control-private":
        selected_strategy = "governed"
        reason = "legacy private workflow alias requested"
        confidence = "high"
    elif explicit_governed:
        selected_strategy = "governed"
        reason = "prompt includes release/tag/changelog/readme intent"
        confidence = "high"
    elif explicit_quick:
        selected_strategy = "fast"
        reason = "prompt indicates commit-only intent"
        confidence = "high"
    elif release_file_touched:
        selected_strategy = "governed"
        reason = "release-related files changed (README.md / CHANGELOG.md / repo.manifest.yaml)"
        confidence = "medium"
    elif len(changed) <= 6:
        selected_strategy = "fast"
        reason = "auto default for lightweight version-control requests"
        confidence = "medium"
    else:
        selected_strategy = "governed"
        reason = "change set is larger and no fast intent was detected"
        confidence = "medium"

    selected_ref = version_control_path
    selected_data = yaml.safe_load(selected_ref.read_text(encoding="utf-8"))
    result.update(
        {
            "selector_applied": True,
            "selected_strategy": selected_strategy,
            "selected_mode": selected_strategy,
            "confidence": confidence,
            "reason": reason,
            "selected_workflow_ref": str(selected_ref),
            "selected_workflow_id": selected_data.get("workflow_id", selected_ref.stem),
        }
    )
    print(json.dumps(result, ensure_ascii=False))


# ---------------------------------------------------------------------------
# Subcommand: create-run
# ---------------------------------------------------------------------------

def cmd_create_run(
    status_file: str,
    workflow_id: str,
    name: str,
    state: str,
    result: str,
    mode: str,
    cli: str,
    prompt: str,
) -> None:
    """Create a new workflow run entry in the status store."""
    sf = Path(status_file)
    payload = _load_payload(sf)
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    run_id = f"run_{datetime.now().strftime('%Y%m%d%H%M%S')}_{uuid.uuid4().hex[:8]}"
    prompt_preview = " ".join(prompt.split())[:160]

    payload["runs"].append(
        {
            "run_id": run_id,
            "workflow_id": workflow_id,
            "workflow_name": name,
            "state": state,
            "result": result,
            "mode": mode,
            "cli": cli,
            "prompt_preview": prompt_preview,
            "created_at": now,
            "updated_at": now,
            "started_at": now,
            "finished_at": now if state in {"completed", "failed", "cancelled"} else "",
        }
    )
    _recompute_workflow(payload, workflow_id)
    sf.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(run_id)


# ---------------------------------------------------------------------------
# Subcommand: update-run
# ---------------------------------------------------------------------------

def cmd_update_run(status_file: str, run_id: str, state: str, result: str) -> None:
    """Update an existing workflow run's state and result."""
    sf = Path(status_file)
    payload = _load_payload(sf)

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

    _recompute_workflow(payload, target.get("workflow_id", ""))
    sf.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


# ---------------------------------------------------------------------------
# Subcommand: summary-field
# ---------------------------------------------------------------------------

def cmd_summary_field(status_file: str, workflow_id: str, field: str) -> None:
    """Print a single field from a workflow's summary entry."""
    sf = Path(status_file)
    if not sf.exists():
        sys.exit(0)

    workflows = _normalize_workflows_only(json.loads(sf.read_text(encoding="utf-8")))
    entry = workflows.get(workflow_id, {})
    value = entry.get(field, "")
    if value is None:
        value = ""
    print(value)


# ---------------------------------------------------------------------------
# Subcommand: list
# ---------------------------------------------------------------------------

def cmd_list(workflows_dir: str, status_file: str) -> None:
    """List all available workflows with short IDs and summaries."""
    wdir = Path(workflows_dir)
    sf = Path(status_file)
    files = sorted(p for p in wdir.iterdir() if p.is_file() and p.suffix in {".yaml", ".yml", ".json"})

    status_data: dict = {}
    if sf.exists():
        status_data = _normalize_workflows_only(json.loads(sf.read_text(encoding="utf-8")))

    rows: list[tuple[str, str, str]] = []
    for path in files:
        raw = path.read_text(encoding="utf-8")
        data = yaml.safe_load(raw) if path.suffix in {".yaml", ".yml"} else {}
        wid = data.get("workflow_id", path.stem)
        short_id = "wf_" + hashlib.sha1(wid.encode("utf-8")).hexdigest()[:8]
        summary = data.get("summary", "")
        rows.append((short_id, path.name, summary))

    headers = ("ID", "FILE", "SUMMARY")
    widths = [len(h) for h in headers]
    for row in rows:
        for i, value in enumerate(row):
            widths[i] = min(max(widths[i], len(str(value))), 70)

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
            f"{_clip(row[0], widths[0]):<{widths[0]}}  "
            f"{_clip(row[1], widths[1]):<{widths[1]}}  "
            f"{_clip(row[2], widths[2]):<{widths[2]}}"
        )


# ---------------------------------------------------------------------------
# Subcommand: ps
# ---------------------------------------------------------------------------

def cmd_ps(status_file: str, ps_filter: str) -> None:
    """List workflow runs with optional stale auto-cleanup."""
    sf = Path(status_file)

    runs: list[dict] = []
    dirty = False
    raw_data: dict = {}
    if sf.exists():
        raw_data = json.loads(sf.read_text(encoding="utf-8"))
        runs = _normalize_runs_only(raw_data)

    # Auto-mark stale: executing runs older than 2 hours
    now = datetime.now()
    stale_threshold = timedelta(hours=2)
    for r in runs:
        if r.get("state") == "executing":
            updated = r.get("updated_at") or r.get("created_at", "")
            if updated:
                try:
                    ts = datetime.strptime(updated, "%Y-%m-%d %H:%M:%S")
                    if now - ts > stale_threshold:
                        r["state"] = "stale"
                        r["result"] = "zombie_auto_cleanup"
                        dirty = True
                except ValueError:
                    pass

    if dirty:
        sf.write_text(json.dumps(raw_data, ensure_ascii=False, indent=2), encoding="utf-8")

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
            f"{_clip(row[0], widths[0]):<{widths[0]}}  "
            f"{_clip(row[1], widths[1]):<{widths[1]}}  "
            f"{_clip(row[2], widths[2]):<{widths[2]}}  "
            f"{_clip(row[3], widths[3]):<{widths[3]}}  "
            f"{_clip(row[4], widths[4]):<{widths[4]}}  "
            f"{_clip(row[5], widths[5]):<{widths[5]}}  "
            f"{_clip(row[6], widths[6]):<{widths[6]}}"
        )


# ---------------------------------------------------------------------------
# Subcommand: show
# ---------------------------------------------------------------------------

def cmd_show(cap_root: str, workflow_ref: str, status_file: str) -> None:
    """Show detailed info for a single workflow."""
    base_dir = Path(cap_root)
    sf = Path(status_file)

    sys.path.insert(0, str(base_dir))
    from engine.workflow_loader import WorkflowLoader  # noqa: E402

    loader = WorkflowLoader(base_dir=base_dir)
    workflow = loader.load_workflow(workflow_ref)

    status_data: dict = {}
    if sf.exists():
        status_data = _normalize_workflows_only(json.loads(sf.read_text(encoding="utf-8")))
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


# ---------------------------------------------------------------------------
# Subcommand: inspect
# ---------------------------------------------------------------------------

def cmd_inspect(status_file: str, run_id: str) -> None:
    """Inspect a specific workflow run by run_id."""
    sf = Path(status_file)

    if not sf.exists():
        print(f"找不到 run_id：{run_id}", file=sys.stderr)
        sys.exit(1)

    runs = _normalize_runs_only(json.loads(sf.read_text(encoding="utf-8")))
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
    print(f"STATUS FILE: {sf}")


# ---------------------------------------------------------------------------
# Subcommand: plan
# ---------------------------------------------------------------------------

def cmd_plan(cap_root: str, workflow_ref: str) -> None:
    """Display the semantic and bound execution plan for a workflow."""
    base_dir = Path(cap_root)
    sys.path.insert(0, str(base_dir))
    from engine.workflow_loader import WorkflowLoader  # noqa: E402
    from engine.runtime_binder import RuntimeBinder  # noqa: E402

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


# ---------------------------------------------------------------------------
# Subcommand: bind
# ---------------------------------------------------------------------------

def cmd_bind(cap_root: str, workflow_ref: str, registry_ref: str | None = None) -> None:
    """Run capability binding for a workflow and print the report."""
    base_dir = Path(cap_root)
    sys.path.insert(0, str(base_dir))
    from engine.runtime_binder import RuntimeBinder  # noqa: E402

    binder = RuntimeBinder(base_dir=base_dir)
    report = binder.bind_capabilities(workflow_ref, registry_ref or None)
    print(json.dumps(report, ensure_ascii=False))


# ---------------------------------------------------------------------------
# Subcommand: build-bound-plan
# ---------------------------------------------------------------------------

def cmd_build_bound_plan(cap_root: str, workflow_ref: str) -> None:
    """Build a bound execution plan and print JSON."""
    base_dir = Path(cap_root)
    sys.path.insert(0, str(base_dir))
    from engine.runtime_binder import RuntimeBinder  # noqa: E402

    binder = RuntimeBinder(base_dir=base_dir)
    result = binder.build_bound_execution_phases(workflow_ref)
    print(json.dumps(result, ensure_ascii=False))


# ---------------------------------------------------------------------------
# Subcommand: constitution-json
# ---------------------------------------------------------------------------

def cmd_constitution_json(cap_root: str, request: str) -> None:
    """Build a task constitution JSON from a one-line request."""
    base_dir = Path(cap_root)
    sys.path.insert(0, str(base_dir))
    from engine.task_scoped_compiler import TaskScopedWorkflowCompiler  # noqa: E402

    compiler = TaskScopedWorkflowCompiler(base_dir=base_dir)
    constitution = compiler.build_task_constitution(request)
    print(json.dumps(constitution, ensure_ascii=False))


# ---------------------------------------------------------------------------
# Subcommand: compile-json
# ---------------------------------------------------------------------------

def cmd_compile_json(cap_root: str, request: str, registry_ref: str | None = None) -> None:
    """Compile a task-scoped workflow and print JSON.

    On schema-class failure (compiled_workflow rejected by
    ``schemas/compiled-workflow.schema.yaml`` at any compile-pipeline
    stage) prints a deterministic JSON error to stdout and exits 1.
    Schema-class exit code 41 alignment is intentionally left to the
    shell executor wrapper; the Python CLI keeps the established
    "JSON + exit 1" contract used by ``validate-constitution``.
    """
    base_dir = Path(cap_root)
    sys.path.insert(0, str(base_dir))
    from engine.binding_report_validator import BindingReportSchemaError  # noqa: E402
    from engine.compiled_workflow_validator import CompiledWorkflowSchemaError  # noqa: E402
    from engine.task_scoped_compiler import TaskScopedWorkflowCompiler  # noqa: E402

    compiler = TaskScopedWorkflowCompiler(base_dir=base_dir)
    try:
        compiled = compiler.compile_task(request, registry_ref=registry_ref or None)
    except CompiledWorkflowSchemaError as exc:
        print(
            json.dumps(
                {
                    "ok": False,
                    "error": "compiled_workflow_schema_error",
                    "stage": exc.stage,
                    "errors": exc.errors,
                },
                ensure_ascii=False,
            )
        )
        sys.exit(1)
    except BindingReportSchemaError as exc:
        print(
            json.dumps(
                {
                    "ok": False,
                    "error": "binding_report_schema_error",
                    "stage": exc.stage,
                    "errors": exc.errors,
                },
                ensure_ascii=False,
            )
        )
        sys.exit(1)
    print(json.dumps(compiled, ensure_ascii=False))


# ---------------------------------------------------------------------------
# Render helpers for shell UI
# ---------------------------------------------------------------------------

def cmd_print_constitution_report(constitution_json: str, snapshot_json: str) -> None:
    constitution = _load_json_arg(constitution_json)
    snapshot = _load_json_arg(snapshot_json)
    project_context = constitution.get("project_context", {})
    print("TASK CONSTITUTION")
    print(f"task_id: {constitution['task_id']}")
    print(f"goal_stage: {constitution['goal_stage']}")
    print(f"risk_profile: {constitution['risk_profile']}")
    print(f"goal: {constitution['goal']}")
    if project_context:
        print("project_context:")
        print(f"  - project_id: {project_context.get('project_id', '-')}")
        print(f"  - project_type: {project_context.get('project_type', '-')}")
        print(f"  - constitution_id: {project_context.get('constitution_id', '-')}")
        print(f"  - project_constitution_path: {project_context.get('project_constitution_path', '-')}")
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


def cmd_print_compile_report(compiled_json: str, snapshot_json: str) -> None:
    compiled = _load_json_arg(compiled_json)
    snapshot = _load_json_arg(snapshot_json)
    constitution = compiled["task_constitution"]
    project_context = compiled.get("project_context") or constitution.get("project_context", {})
    graph = compiled["capability_graph"]
    binding = compiled["binding"]
    plan = compiled["plan"]
    policy = compiled["unresolved_policy"]

    print("TASK COMPILE REPORT")
    print(f"task_id: {constitution['task_id']}")
    print(f"goal_stage: {constitution['goal_stage']}")
    print(f"workflow_id: {plan['workflow_id']}")
    print(f"binding_status: {binding['binding_status']}")
    if project_context:
        print(f"project_id: {project_context.get('project_id', '-')}")
        print(f"project_constitution: {project_context.get('project_constitution_path', '-')}")
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


def cmd_print_compiled_dry_run(constitution_json: str, policy_json: str, plan_json: str, snapshot_json: str) -> None:
    constitution = _load_json_arg(constitution_json)
    policy = _load_json_arg(policy_json)
    plan = _load_json_arg(plan_json)
    snapshot = _load_json_arg(snapshot_json)

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


def cmd_print_compiled_blocked(constitution_json: str, policy_json: str, binding_json: str, snapshot_json: str) -> None:
    constitution = _load_json_arg(constitution_json)
    policy = _load_json_arg(policy_json)
    binding = _load_json_arg(binding_json)
    snapshot = _load_json_arg(snapshot_json)
    print(f"task_id: {constitution['task_id']}")
    print(f"goal_stage: {constitution['goal_stage']}")
    print(f"binding_status: {binding['binding_status']}")
    print(f"binding_json: {snapshot['binding_json_path']}")
    print(f"bundle_dir: {snapshot['bundle_dir']}")
    print("policy decisions:")
    for item in policy["decisions"]:
        if item["action"] in {"pending", "manual", "re_scope"}:
            print(f"  - {item['step_id']} => {item['action']} / {item['reason']}")


def cmd_print_compiled_degraded(policy_json: str, snapshot_json: str) -> None:
    policy = _load_json_arg(policy_json)
    snapshot = _load_json_arg(snapshot_json)
    print(f"binding_json: {snapshot['binding_json_path']}")
    print(f"bundle_dir: {snapshot['bundle_dir']}")
    for item in policy["decisions"]:
        if item["action"] in {"fallback", "skip"}:
            print(f"  - {item['step_id']} => {item['action']} / {item['reason']}")


def cmd_print_compile_start(snapshot_json: str, run_id: str) -> None:
    snapshot = _load_json_arg(snapshot_json)
    print(f"  Constitution: {snapshot['constitution_json_path']}")
    print(f"  Binding: {snapshot['binding_json_path']}")
    print(f"  Compiled bundle: {snapshot['bundle_dir']}")
    print(f"  Run ID: {run_id}")


def cmd_print_workflow_plan(plan_json: str) -> None:
    plan = _load_json_arg(plan_json)
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


def cmd_print_binding_summary(binding_json: str, snapshot_json: str) -> None:
    binding = _load_json_arg(binding_json)
    snapshot = _load_json_arg(snapshot_json)
    print(f"  Binding: {binding['binding_status']}  |  registry_missing={binding['registry_missing']}  |  adapter_from_legacy={binding['adapter_from_legacy']}")
    print(f"  Binding file: {snapshot['json_path']}")
    for step in binding["steps"]:
        print(f"    - {step['step_id']}: {step['resolution_status']} -> {step['selected_skill_id'] or '-'}")


def cmd_print_bind_report(report_json: str, snapshot_json: str) -> None:
    report = _load_json_arg(report_json)
    snapshot = _load_json_arg(snapshot_json)
    project_context = report.get("project_context", {})
    print("WORKFLOW BINDING REPORT")
    print(f"workflow_id: {report['workflow_id']}")
    print(f"workflow_version: {report['workflow_version']}")
    print(f"binding_status: {report['binding_status']}")
    print(f"registry_source: {report['registry_source_path']}")
    if project_context:
        print(f"project_id: {project_context.get('project_id', '-')}")
        print(f"project_constitution: {project_context.get('project_constitution_path', '-')}")
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


def cmd_print_binding_blocked(binding_json: str, snapshot_json: str) -> None:
    binding = _load_json_arg(binding_json)
    snapshot = _load_json_arg(snapshot_json)
    print(f"binding_status: {binding['binding_status']}")
    print(f"registry_source: {binding['registry_source_path']}")
    print(f"registry_missing: {binding['registry_missing']}")
    print(f"adapter_from_legacy: {binding['adapter_from_legacy']}")
    print(f"binding_json: {snapshot['json_path']}")
    print("unresolved steps:")
    for step in binding["steps"]:
        if step["resolution_status"] in {"required_unresolved", "incompatible", "blocked_by_constitution"}:
            print(f"  - {step['step_id']} => {step['resolution_status']} / capability={step['capability']} / reason={step['reason']}")


def cmd_print_binding_degraded(binding_json: str, snapshot_json: str) -> None:
    binding = _load_json_arg(binding_json)
    snapshot = _load_json_arg(snapshot_json)
    print(f"binding_status: {binding['binding_status']}")
    print(f"registry_source: {binding['registry_source_path']}")
    print(f"registry_missing: {binding['registry_missing']}")
    print(f"adapter_from_legacy: {binding['adapter_from_legacy']}")
    print(f"binding_json: {snapshot['json_path']}")
    print("degraded steps:")
    for step in binding["steps"]:
        if step["resolution_status"] in {"fallback_available", "optional_unresolved"}:
            print(f"  - {step['step_id']} => {step['resolution_status']} / capability={step['capability']} / selected={step['selected_skill_id'] or '-'}")


def cmd_print_binding_start(snapshot_json: str, run_id: str) -> None:
    snapshot = _load_json_arg(snapshot_json)
    print(f"  Binding: {snapshot['json_path']}")
    print(f"  Run ID: {run_id}")


# ---------------------------------------------------------------------------
# Subcommand: persist-constitution
# ---------------------------------------------------------------------------

def cmd_persist_constitution(
    constitution_dir: str,
    request: str,
    origin: str,
    constitution_json: str,
) -> None:
    """Persist a task constitution as JSON + Markdown snapshots."""
    cdir = Path(constitution_dir)
    constitution: dict = json.loads(constitution_json)

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    task_id = constitution.get("task_id") or f"task-{stamp}"
    task_dir = cdir / task_id
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
        "## Project Context",
        "",
        f"- project_id: {constitution.get('project_context', {}).get('project_id', '-')}",
        f"- project_type: {constitution.get('project_context', {}).get('project_type', '-')}",
        f"- constitution_id: {constitution.get('project_context', {}).get('constitution_id', '-')}",
        f"- project_constitution_path: {constitution.get('project_context', {}).get('project_constitution_path', '-')}",
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


# ---------------------------------------------------------------------------
# Subcommand: persist-binding
# ---------------------------------------------------------------------------

def cmd_persist_binding(
    binding_dir: str,
    workflow_id: str,
    binding_json: str,
) -> None:
    """Persist a binding report as JSON + Markdown snapshots.

    The shell caller also passes workflow_name, workflow_ref and origin,
    which are embedded inside the binding_json payload when called from
    the shell wrapper. This function extracts those from the binding payload
    itself to remain compatible with the original behaviour.
    """
    bdir = Path(binding_dir)
    binding: dict = json.loads(binding_json)

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    workflow_dir = bdir / workflow_id
    workflow_dir.mkdir(parents=True, exist_ok=True)

    json_path = workflow_dir / f"binding-{stamp}.json"
    md_path = workflow_dir / f"binding-{stamp}.md"

    # The shell script wraps extra fields around the binding before calling
    # persist.  We accept both "raw binding" and "wrapped binding" formats.
    workflow_name = binding.get("workflow_name", workflow_id)
    workflow_ref_val = binding.get("workflow_ref", "-")
    origin = binding.get("origin", "persist-binding")

    payload = {
        "origin": origin,
        "workflow_id": workflow_id,
        "workflow_name": workflow_name,
        "workflow_ref": workflow_ref_val,
        "saved_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "binding": binding,
    }
    json_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

    lines = [
        "# Workflow Binding Snapshot",
        "",
        f"- workflow_id: {workflow_id}",
        f"- workflow_name: {workflow_name}",
        f"- workflow_ref: {workflow_ref_val}",
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


# ---------------------------------------------------------------------------
# Subcommand: persist-compile-bundle
# ---------------------------------------------------------------------------

def cmd_persist_compile_bundle(
    constitution_dir: str,
    compiled_workflow_dir: str,
    binding_dir: str,
    request: str,
    registry_ref: str,
    origin: str,
    compiled_json: str,
) -> None:
    """Persist a full compile bundle (constitution + binding + workflow artifacts)."""
    cdir = Path(constitution_dir)
    cwdir = Path(compiled_workflow_dir)
    bdir = Path(binding_dir)
    compiled: dict = json.loads(compiled_json)

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    constitution = compiled["task_constitution"]
    graph = compiled["capability_graph"]
    compiled_workflow = compiled["compiled_workflow"]
    binding = compiled["binding"]
    policy = compiled["unresolved_policy"]
    plan = compiled["plan"]

    task_id = constitution["task_id"]
    workflow_id = plan["workflow_id"]

    # -- Constitution snapshot --
    constitution_task_dir = cdir / task_id
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

    # -- Binding snapshot --
    binding_task_dir = bdir / workflow_id
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

    # -- Bundle directory --
    bundle_dir = cwdir / task_id / stamp
    bundle_dir.mkdir(parents=True, exist_ok=True)

    bundle_files = {
        "task-constitution.json": constitution,
        "capability-graph.json": graph,
        "compiled-workflow.json": compiled_workflow,
        "binding-report.json": binding,
        "unresolved-policy.json": policy,
        "bound-plan.json": plan,
    }
    for filename, file_payload in bundle_files.items():
        (bundle_dir / filename).write_text(json.dumps(file_payload, ensure_ascii=False, indent=2), encoding="utf-8")

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


# ---------------------------------------------------------------------------
# Argparse CLI wiring
# ---------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="workflow_cli",
        description="Consolidated CLI for cap-workflow operations.",
    )
    sub = parser.add_subparsers(dest="subcommand", required=True)

    # resolve-ref
    p = sub.add_parser("resolve-ref", help="Resolve a workflow reference to a file path")
    p.add_argument("workflows_dir")
    p.add_argument("raw_ref")

    # resolve-mode
    p = sub.add_parser("resolve-mode", help="Resolve execution mode for version-control family")
    p.add_argument("cap_root")
    p.add_argument("workflow_ref")
    p.add_argument("requested_mode")
    p.add_argument("user_prompt")
    p.add_argument("changed_files")

    # create-run
    p = sub.add_parser("create-run", help="Create a workflow run entry")
    p.add_argument("status_file")
    p.add_argument("workflow_id")
    p.add_argument("name")
    p.add_argument("state")
    p.add_argument("result")
    p.add_argument("mode")
    p.add_argument("cli")
    p.add_argument("prompt")

    # update-run
    p = sub.add_parser("update-run", help="Update a workflow run's state/result")
    p.add_argument("status_file")
    p.add_argument("run_id")
    p.add_argument("state")
    p.add_argument("result")

    # summary-field
    p = sub.add_parser("summary-field", help="Read a single field from workflow summary")
    p.add_argument("status_file")
    p.add_argument("workflow_id")
    p.add_argument("field")

    # list
    p = sub.add_parser("list", help="List available workflows")
    p.add_argument("workflows_dir")
    p.add_argument("status_file")

    # ps
    p = sub.add_parser("ps", help="List workflow runs (with stale auto-cleanup)")
    p.add_argument("status_file")
    p.add_argument("filter", nargs="?", default="active")

    # show
    p = sub.add_parser("show", help="Show details of a specific workflow")
    p.add_argument("cap_root")
    p.add_argument("workflow_ref")
    p.add_argument("status_file")

    # inspect
    p = sub.add_parser("inspect", help="Inspect a specific workflow run")
    p.add_argument("status_file")
    p.add_argument("run_id")

    # plan
    p = sub.add_parser("plan", help="Display semantic + bound execution plan")
    p.add_argument("cap_root")
    p.add_argument("workflow_ref")

    # bind
    p = sub.add_parser("bind", help="Run capability binding and print report")
    p.add_argument("cap_root")
    p.add_argument("workflow_ref")
    p.add_argument("registry_ref", nargs="?", default=None)

    # build-bound-plan
    p = sub.add_parser("build-bound-plan", help="Build bound execution plan JSON")
    p.add_argument("cap_root")
    p.add_argument("workflow_ref")

    # constitution-json
    p = sub.add_parser("constitution-json", help="Build task constitution JSON")
    p.add_argument("cap_root")
    p.add_argument("request")

    # compile-json
    p = sub.add_parser("compile-json", help="Compile task-scoped workflow JSON")
    p.add_argument("cap_root")
    p.add_argument("request")
    p.add_argument("registry_ref", nargs="?", default=None)

    # persist-constitution
    p = sub.add_parser("persist-constitution", help="Persist a task constitution snapshot")
    p.add_argument("constitution_dir")
    p.add_argument("request")
    p.add_argument("origin")
    p.add_argument("constitution_json")

    # persist-binding
    p = sub.add_parser("persist-binding", help="Persist a binding snapshot")
    p.add_argument("binding_dir")
    p.add_argument("workflow_id")
    p.add_argument("binding_json")

    # persist-compile-bundle
    p = sub.add_parser("persist-compile-bundle", help="Persist a full compile bundle")
    p.add_argument("constitution_dir")
    p.add_argument("compiled_workflow_dir")
    p.add_argument("binding_dir")
    p.add_argument("request")
    p.add_argument("registry_ref")
    p.add_argument("origin")
    p.add_argument("compiled_json")

    # print-constitution-report
    p = sub.add_parser("print-constitution-report", help="Render constitution report for shell UI")
    p.add_argument("constitution_json")
    p.add_argument("snapshot_json")

    # print-compile-report
    p = sub.add_parser("print-compile-report", help="Render compile report for shell UI")
    p.add_argument("compiled_json")
    p.add_argument("snapshot_json")

    # print-compiled-dry-run
    p = sub.add_parser("print-compiled-dry-run", help="Render compiled workflow dry-run summary")
    p.add_argument("constitution_json")
    p.add_argument("policy_json")
    p.add_argument("plan_json")
    p.add_argument("snapshot_json")

    # print-compiled-blocked
    p = sub.add_parser("print-compiled-blocked", help="Render compiled workflow blocked summary")
    p.add_argument("constitution_json")
    p.add_argument("policy_json")
    p.add_argument("binding_json")
    p.add_argument("snapshot_json")

    # print-compiled-degraded
    p = sub.add_parser("print-compiled-degraded", help="Render compiled workflow degraded summary")
    p.add_argument("policy_json")
    p.add_argument("snapshot_json")

    # print-compile-start
    p = sub.add_parser("print-compile-start", help="Render compiled workflow start paths")
    p.add_argument("snapshot_json")
    p.add_argument("run_id")

    # print-workflow-plan
    p = sub.add_parser("print-workflow-plan", help="Render workflow phase summary")
    p.add_argument("plan_json")

    # print-binding-summary
    p = sub.add_parser("print-binding-summary", help="Render binding summary")
    p.add_argument("binding_json")
    p.add_argument("snapshot_json")

    # print-bind-report
    p = sub.add_parser("print-bind-report", help="Render full binding report")
    p.add_argument("report_json")
    p.add_argument("snapshot_json")

    # print-binding-blocked
    p = sub.add_parser("print-binding-blocked", help="Render blocked binding summary")
    p.add_argument("binding_json")
    p.add_argument("snapshot_json")

    # print-binding-degraded
    p = sub.add_parser("print-binding-degraded", help="Render degraded binding summary")
    p.add_argument("binding_json")
    p.add_argument("snapshot_json")

    # print-binding-start
    p = sub.add_parser("print-binding-start", help="Render workflow start paths")
    p.add_argument("snapshot_json")
    p.add_argument("run_id")

    return parser


def main() -> None:
    parser = _build_parser()
    args = parser.parse_args()

    match args.subcommand:
        case "resolve-ref":
            cmd_resolve_ref(args.workflows_dir, args.raw_ref)
        case "resolve-mode":
            cmd_resolve_mode(
                args.cap_root,
                args.workflow_ref,
                args.requested_mode,
                args.user_prompt,
                args.changed_files,
            )
        case "create-run":
            cmd_create_run(
                args.status_file,
                args.workflow_id,
                args.name,
                args.state,
                args.result,
                args.mode,
                args.cli,
                args.prompt,
            )
        case "update-run":
            cmd_update_run(args.status_file, args.run_id, args.state, args.result)
        case "summary-field":
            cmd_summary_field(args.status_file, args.workflow_id, args.field)
        case "list":
            cmd_list(args.workflows_dir, args.status_file)
        case "ps":
            cmd_ps(args.status_file, args.filter)
        case "show":
            cmd_show(args.cap_root, args.workflow_ref, args.status_file)
        case "inspect":
            cmd_inspect(args.status_file, args.run_id)
        case "plan":
            cmd_plan(args.cap_root, args.workflow_ref)
        case "bind":
            cmd_bind(args.cap_root, args.workflow_ref, args.registry_ref)
        case "build-bound-plan":
            cmd_build_bound_plan(args.cap_root, args.workflow_ref)
        case "constitution-json":
            cmd_constitution_json(args.cap_root, args.request)
        case "compile-json":
            cmd_compile_json(args.cap_root, args.request, args.registry_ref)
        case "persist-constitution":
            cmd_persist_constitution(
                args.constitution_dir,
                args.request,
                args.origin,
                args.constitution_json,
            )
        case "persist-binding":
            cmd_persist_binding(args.binding_dir, args.workflow_id, args.binding_json)
        case "persist-compile-bundle":
            cmd_persist_compile_bundle(
                args.constitution_dir,
                args.compiled_workflow_dir,
                args.binding_dir,
                args.request,
                args.registry_ref,
                args.origin,
                args.compiled_json,
            )
        case "print-constitution-report":
            cmd_print_constitution_report(args.constitution_json, args.snapshot_json)
        case "print-compile-report":
            cmd_print_compile_report(args.compiled_json, args.snapshot_json)
        case "print-compiled-dry-run":
            cmd_print_compiled_dry_run(args.constitution_json, args.policy_json, args.plan_json, args.snapshot_json)
        case "print-compiled-blocked":
            cmd_print_compiled_blocked(args.constitution_json, args.policy_json, args.binding_json, args.snapshot_json)
        case "print-compiled-degraded":
            cmd_print_compiled_degraded(args.policy_json, args.snapshot_json)
        case "print-compile-start":
            cmd_print_compile_start(args.snapshot_json, args.run_id)
        case "print-workflow-plan":
            cmd_print_workflow_plan(args.plan_json)
        case "print-binding-summary":
            cmd_print_binding_summary(args.binding_json, args.snapshot_json)
        case "print-bind-report":
            cmd_print_bind_report(args.report_json, args.snapshot_json)
        case "print-binding-blocked":
            cmd_print_binding_blocked(args.binding_json, args.snapshot_json)
        case "print-binding-degraded":
            cmd_print_binding_degraded(args.binding_json, args.snapshot_json)
        case "print-binding-start":
            cmd_print_binding_start(args.snapshot_json, args.run_id)
        case _:
            parser.print_help()
            sys.exit(1)


if __name__ == "__main__":
    main()
