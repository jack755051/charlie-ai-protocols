"""step_runtime — workflow step 輔助函式集

將 scripts/cap-workflow-exec.sh 中所有行內 Python heredoc 區塊
整合為獨立模組，提供 CLI 子指令介面。

Usage:
    python3 engine/step_runtime.py <subcommand> [args...]

Subcommands:
    update-status      更新 workflow 狀態檔
    handoff-summary    從 artifact 擷取交接摘要
    resolve-inputs     解析 step 輸入上下文
    resolve-contract   解析 step 契約與完成條件
    validate-inputs    驗證 step 輸入是否齊備
    register-state     註冊 step 執行狀態至 registry
    upsert-session     註冊或更新 CAP agent session ledger
    flatten-steps      將 plan JSON 展平為 pipe-delimited 記錄
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Any


# ─────────────────────────────────────────────────────────
# Shared helpers
# ─────────────────────────────────────────────────────────

def _find_step(plan: dict[str, Any], step_id: str) -> tuple[dict[str, Any] | None, str]:
    """在 plan 中搜尋指定 step，回傳 (step_dict, phase_label)。"""
    for phase in plan.get("phases", []):
        for step in phase.get("steps", []):
            if step["step_id"] == step_id:
                return step, str(phase["phase"])
    return None, ""


def _run_git(*args: str) -> str:
    """執行 git 指令並回傳 stdout（靜默失敗）。"""
    try:
        result = subprocess.run(
            ["git", *args],
            check=False,
            capture_output=True,
            text=True,
        )
    except Exception:
        return ""
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def _load_registry(registry_path: Path) -> dict[str, Any]:
    """讀取 runtime-state registry JSON；不存在時回傳空結構。"""
    if registry_path.exists():
        return json.loads(registry_path.read_text(encoding="utf-8"))
    return {"artifacts": {}, "steps": {}}


def _project_id_from_config() -> str:
    """Best-effort read of the current project's .cap.project.yaml project_id."""
    config_path = Path.cwd() / ".cap.project.yaml"
    if config_path.is_file():
        for line in config_path.read_text(encoding="utf-8").splitlines():
            match = re.match(r'^project_id:\s*"?([^"#]+)"?\s*$', line)
            if match:
                return match.group(1).strip()
    return Path.cwd().name


def _read_constitution_design_source() -> dict[str, Any] | None:
    """Best-effort read of design_source block from the project's
    .cap.constitution.yaml. Returns the dict when found, None when the
    constitution is missing, the block is absent, type is 'none', or YAML
    parsing fails. Never raises — callers fall back to the legacy
    ~/.cap/designs/<project_id> path on None.
    """
    constitution_path = Path.cwd() / ".cap.constitution.yaml"
    if not constitution_path.is_file():
        return None
    try:
        import yaml  # type: ignore[import]
    except ImportError:
        return None
    try:
        with constitution_path.open("r", encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}
    except Exception:
        return None
    block = data.get("design_source")
    if not isinstance(block, dict):
        return None
    if block.get("type") == "none":
        return None
    return block


def _design_source_path() -> Path:
    """Resolve the active design package path with constitution-first
    precedence:

      1. constitution.design_source.source_path (absolute or ~ expanded)
      2. {constitution.design_source.design_root}/{constitution.design_source.package}
      3. legacy fallback: ~/.cap/designs/<project_id>

    The legacy fallback exists so older constitutions without a design_source
    block keep working; new bootstraps fill in the explicit block via
    bootstrap-constitution-defaults.sh and the supervisor draft step.
    """
    block = _read_constitution_design_source()
    if block is not None:
        raw_path = block.get("source_path")
        if isinstance(raw_path, str) and raw_path.strip():
            return Path(raw_path).expanduser().resolve()
        design_root = block.get("design_root")
        package = block.get("package")
        if isinstance(design_root, str) and isinstance(package, str) and package.strip():
            return (Path(design_root).expanduser() / package).resolve()
    cap_home = Path.home() / ".cap"
    return cap_home / "designs" / _project_id_from_config()


def _design_tree(path: Path, limit: int = 120) -> list[str]:
    if not path.is_dir():
        return []
    files = sorted(
        p for p in path.rglob("*")
        if p.is_file() and p.name != ".DS_Store"
    )
    lines = [str(p.relative_to(path)) for p in files[:limit]]
    if len(files) > limit:
        lines.append(f"... truncated, total_files={len(files)}")
    return lines


# ─────────────────────────────────────────────────────────
# 1. update-status
# ─────────────────────────────────────────────────────────

def update_status(
    status_file: str,
    workflow_id: str,
    name: str,
    state: str,
    result: str,
) -> None:
    """更新 workflow-runs.json 狀態檔。"""
    path = Path(status_file)

    def normalize(payload: Any) -> dict[str, Any]:
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

    if path.exists():
        raw = path.read_text(encoding="utf-8").strip()
        payload = normalize(json.loads(raw)) if raw else normalize({})
    else:
        payload = normalize({})
    entry = payload["workflows"].get(workflow_id, {})
    entry["workflow_name"] = name
    entry["state"] = state
    entry["last_result"] = result
    entry["last_run_at"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    entry["run_count"] = int(entry.get("run_count", 0))
    payload["workflows"][workflow_id] = entry

    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
    )


# ─────────────────────────────────────────────────────────
# 2. handoff-summary
# ─────────────────────────────────────────────────────────

def handoff_summary(artifact_path: str) -> None:
    """從 artifact 擷取 ``## 交接摘要`` 區段並印出。"""
    path = Path(artifact_path)
    text = path.read_text(encoding="utf-8") if path.exists() else ""

    match = re.search(r"^##\s*交接摘要\s*$", text, flags=re.M)
    if match:
        tail = text[match.start():].strip()
        print(tail)
        return

    lines = [line.rstrip() for line in text.splitlines() if line.strip()]
    snippet = "\n".join(lines[:40]).strip()
    print(snippet)


# ─────────────────────────────────────────────────────────
# 3. resolve-inputs
# ─────────────────────────────────────────────────────────

def _intrinsic_context(artifact: str, plan: dict[str, Any] | None = None) -> str:
    """產生內建 intrinsic artifact 的上下文文字。"""
    if artifact in {"user_requirement", "user_intent"}:
        return "intrinsic_request"

    if artifact == "project_constitution":
        constitution_path = Path.cwd() / ".cap.constitution.yaml"
        lines = ["intrinsic_project_constitution", f"  path: {constitution_path}"]
        if constitution_path.is_file():
            text = constitution_path.read_text(encoding="utf-8").strip()
            if text:
                lines.append("  content:")
                lines.extend(f"    {line}" for line in text.splitlines())
        else:
            lines.append("  status: missing")
        return "\n".join(lines)

    if artifact == "goal_stage_hint":
        goal_stage = ""
        if plan:
            governance = plan.get("governance") or {}
            runtime = plan.get("governance_runtime") or {}
            goal_stage = str(runtime.get("goal_stage") or governance.get("goal_stage") or "")
        if not goal_stage:
            workflow_id = str((plan or {}).get("workflow_id") or "")
            goal_stage = {
                "project-spec-pipeline": "formal_specification",
                "project-implementation-pipeline": "implementation",
                "project-qa-pipeline": "quality_assurance",
            }.get(workflow_id, "")
        lines = ["intrinsic_goal_stage_hint"]
        if goal_stage:
            lines.append(f"  goal_stage: {goal_stage}")
        else:
            lines.append("  status: unspecified")
        return "\n".join(lines)

    if artifact == "design_source":
        design_path = _design_source_path()
        lines = [
            "intrinsic_design_source",
            f"  path: {design_path}",
            "  mode: read_only_reference",
        ]
        tree = _design_tree(design_path)
        if tree:
            lines.append("  files:")
            lines.extend(f"    {item}" for item in tree)
        else:
            lines.append("  status: missing")
        return "\n".join(lines)

    if artifact == "repo_changes":
        status = _run_git("status", "--short")
        staged = _run_git("diff", "--cached", "--stat")
        unstaged = _run_git("diff", "--stat")
        lines = ["intrinsic_repo_changes"]
        if status:
            lines.append("  status:")
            lines.extend(f"    {line}" for line in status.splitlines())
        if staged:
            lines.append("  staged_diff_stat:")
            lines.extend(f"    {line}" for line in staged.splitlines())
        if unstaged:
            lines.append("  unstaged_diff_stat:")
            lines.extend(f"    {line}" for line in unstaged.splitlines())
        return "\n".join(lines)

    if artifact == "project_context":
        top = _run_git("rev-parse", "--show-toplevel")
        branch = _run_git("branch", "--show-current") or "DETACHED"
        head = _run_git("rev-parse", "--short", "HEAD")
        latest_tag = _run_git("describe", "--tags", "--abbrev=0")
        lines = ["intrinsic_project_context"]
        if top:
            lines.append(f"  repo_root: {top}")
        lines.append(f"  branch: {branch}")
        if head:
            lines.append(f"  head: {head}")
        if latest_tag:
            lines.append(f"  latest_tag: {latest_tag}")
        return "\n".join(lines)

    if artifact == "commit_scope":
        changed = _run_git("status", "--short")
        paths: list[str] = []
        for line in changed.splitlines():
            if not line.strip():
                continue
            parts = line.split(maxsplit=1)
            path = parts[1] if len(parts) == 2 else line.strip()
            if " -> " in path:
                path = path.split(" -> ", 1)[1]
            paths.append(path)

        top_levels: list[str] = []
        for path in paths:
            if "/" in path:
                top_levels.append(path.split("/", 1)[0])
            else:
                top_levels.append(".")

        unique = sorted(set(top_levels))
        suggested_scope = "repo"
        if unique == ["docs"]:
            suggested_scope = "docs"
        elif unique == ["schemas"] or unique == ["engine"] or unique == ["scripts"]:
            suggested_scope = unique[0]
        elif set(unique).issubset(
            {".", "README.md", "CHANGELOG.md", "docs", "schemas", "engine", "scripts"}
        ):
            suggested_scope = "workflow"

        lines = ["intrinsic_commit_scope", f"  suggested_scope: {suggested_scope}"]
        if paths:
            lines.append("  changed_paths:")
            lines.extend(f"    {path}" for path in paths)
        return "\n".join(lines)

    if artifact == "repo_files":
        # 給需要看 repo 檔案結構的 step（如 readme_normalization、code analysis）
        # 一份精簡的 file inventory，避免 agent 重新呼叫 find / ls。
        # 來源：git ls-files（追蹤中）+ git ls-files --others --exclude-standard（未追蹤、非 ignore）。
        # 為避免噪音，把節錄上限設為 400 條；超出時提示 agent 自行用 git ls-files 補查。
        tracked = _run_git("ls-files")
        untracked = _run_git("ls-files", "--others", "--exclude-standard")
        files: list[str] = []
        for chunk in (tracked, untracked):
            if not chunk:
                continue
            for line in chunk.splitlines():
                line = line.strip()
                if line:
                    files.append(line)
        files = sorted(set(files))

        max_listed = 400
        truncated = len(files) > max_listed
        listed = files[:max_listed]

        lines = [
            "intrinsic_repo_files",
            f"  total_count: {len(files)}",
            "  files:",
        ]
        lines.extend(f"    {path}" for path in listed)
        if truncated:
            lines.append(
                f"  note: list truncated to first {max_listed} entries; "
                "agent may call `git ls-files` for the full set"
            )
        return "\n".join(lines)

    return "intrinsic_unknown"


_INTRINSIC_ARTIFACTS = frozenset(
    {
        "user_requirement",
        "user_intent",
        "project_constitution",
        "goal_stage_hint",
        "design_source",
        "repo_changes",
        "project_context",
        "commit_scope",
        "repo_files",
    }
)


def resolve_inputs(
    plan_json: str,
    step_id: str,
    input_mode: str,
    registry_path: str,
) -> None:
    """解析 step 輸入上下文（含 git 偵測、intrinsic、registry lookup）。"""
    plan: dict[str, Any] = json.loads(plan_json)
    reg_path = Path(registry_path)
    registry = _load_registry(reg_path)

    target, _ = _find_step(plan, step_id)

    if target is None:
        print("- 無法解析當前 step 輸入")
        return

    inputs: list[str] = target.get("inputs", [])
    if not inputs:
        print("- 無上游輸入")
        return

    lines: list[str] = []
    for artifact in inputs:
        if artifact in _INTRINSIC_ARTIFACTS:
            lines.append(f"- {artifact}:")
            for detail in _intrinsic_context(artifact, plan).splitlines():
                lines.append(f"  {detail}")
            continue

        producer = registry.get("artifacts", {}).get(artifact)
        if not producer:
            lines.append(f"- {artifact}: unresolved")
            continue

        artifact_path = producer.get("path")
        handoff_path = producer.get("handoff_path")
        if input_mode == "full":
            selected = artifact_path
            mode = "full_artifact"
        else:
            selected = (
                handoff_path
                if handoff_path and Path(handoff_path).exists()
                else artifact_path
            )
            mode = (
                "handoff_summary"
                if handoff_path and Path(handoff_path).exists()
                else "artifact_fallback"
            )
        lines.append(
            f"- {artifact}: step={producer['source_step']} mode={mode} path={selected}"
        )

    print("\n".join(lines))


# ─────────────────────────────────────────────────────────
# 4. resolve-contract
# ─────────────────────────────────────────────────────────

def resolve_contract(plan_json: str, step_id: str) -> None:
    """解析 step 契約（inputs / outputs / done_when / notes）。"""
    plan: dict[str, Any] = json.loads(plan_json)
    target, _ = _find_step(plan, step_id)

    if target is None:
        print("- 無法解析 step 契約")
        return

    def emit_list(title: str, values: list[str]) -> list[str]:
        if not values:
            return [f"{title}: -"]
        result = [f"{title}:"]
        result.extend(f"  - {value}" for value in values)
        return result

    lines: list[str] = []
    lines.extend(emit_list("inputs", target.get("inputs", [])))
    lines.extend(emit_list("outputs", target.get("outputs", [])))
    lines.extend(emit_list("done_when", target.get("done_when", [])))
    lines.extend(emit_list("notes", target.get("notes", [])))
    print("\n".join(lines))


# ─────────────────────────────────────────────────────────
# 5. validate-inputs
# ─────────────────────────────────────────────────────────

def validate_inputs(
    plan_json: str,
    step_id: str,
    registry_path: str,
) -> None:
    """驗證 step 輸入是否齊備，輸出 JSON（ok / missing / resolved）。"""
    plan: dict[str, Any] = json.loads(plan_json)
    reg_path = Path(registry_path)
    registry = _load_registry(reg_path)

    target, _ = _find_step(plan, step_id)

    if target is None:
        print(
            json.dumps(
                {"ok": False, "missing": [], "resolved": [], "reason": "step_not_found"},
                ensure_ascii=False,
            )
        )
        return

    missing: list[str] = []
    resolved: list[dict[str, Any]] = []

    def _try_resolve(artifact: str) -> dict[str, Any] | None:
        """Return a resolved artifact descriptor if available; None when
        the artifact does not yet exist (caller decides whether to treat
        absence as missing or as a graceful no-op)."""
        if artifact in _INTRINSIC_ARTIFACTS:
            if artifact == "project_constitution" and not (Path.cwd() / ".cap.constitution.yaml").is_file():
                return None
            if artifact == "design_source" and not _design_source_path().is_dir():
                return None
            return {
                "artifact": artifact,
                "source_step": "__request__",
                "path": (
                    str(Path.cwd() / ".cap.constitution.yaml")
                    if artifact == "project_constitution"
                    else str(_design_source_path())
                    if artifact == "design_source"
                    else "<inline:user_request>"
                ),
                "handoff_path": "",
            }

        entry = registry.get("artifacts", {}).get(artifact)
        if not entry:
            return None
        source_step = entry.get("source_step")
        source_state = (
            registry.get("steps", {}).get(source_step, {}).get("execution_state")
        )
        if source_state != "validated":
            return None
        return {
            "artifact": artifact,
            "source_step": source_step,
            "path": entry.get("path"),
            "handoff_path": entry.get("handoff_path"),
        }

    # Required inputs — absence blocks the step.
    for artifact in target.get("inputs", []):
        descriptor = _try_resolve(artifact)
        if descriptor is None:
            missing.append(artifact)
        else:
            resolved.append(descriptor)

    # Optional inputs — present means include in resolved with optional flag,
    # absent means silently skip. Lets workflow YAML mark inputs whose
    # absence should trigger the step's documented graceful no-op path
    # (e.g. ingest_design_source when design_source is type=none / unset)
    # rather than have runtime gate them off before the shell runs.
    for artifact in target.get("optional_inputs", []):
        descriptor = _try_resolve(artifact)
        if descriptor is not None:
            descriptor["optional"] = True
            resolved.append(descriptor)

    print(
        json.dumps(
            {
                "ok": not missing,
                "missing": missing,
                "resolved": resolved,
                "reason": "" if not missing else "missing_input_artifact",
            },
            ensure_ascii=False,
        )
    )


# ─────────────────────────────────────────────────────────
# 6. register-state
# ─────────────────────────────────────────────────────────

def register_state(
    plan_json: str,
    registry_path: str,
    step_id: str,
    execution_state: str,
    blocked_reason: str,
    output_source: str,
    output_path: str,
    handoff_path: str,
) -> None:
    """將 step 執行狀態寫入 runtime-state registry。"""
    plan: dict[str, Any] = json.loads(plan_json)
    reg_path = Path(registry_path)
    registry = _load_registry(reg_path)

    target, target_phase = _find_step(plan, step_id)

    if target is None:
        return

    registry["steps"][step_id] = {
        "phase": target_phase,
        "capability": target.get("capability"),
        "execution_state": execution_state,
        "blocked_reason": blocked_reason or "",
        "output_source": output_source or "",
        "output_path": output_path or "",
        "handoff_path": handoff_path or "",
    }

    if execution_state == "validated":
        for artifact in target.get("outputs", []):
            registry["artifacts"][artifact] = {
                "artifact": artifact,
                "source_step": step_id,
                "path": output_path,
                "handoff_path": handoff_path,
            }

    reg_path.write_text(
        json.dumps(registry, ensure_ascii=False, indent=2), encoding="utf-8"
    )


# ─────────────────────────────────────────────────────────
# 7. upsert-session
# ─────────────────────────────────────────────────────────

def _load_session_ledger(path: Path, run_id: str, workflow_id: str, workflow_name: str) -> dict[str, Any]:
    if path.exists():
        payload = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(payload, dict) and isinstance(payload.get("sessions"), list):
            return payload
    return {
        "version": 1,
        "run_id": run_id,
        "workflow_id": workflow_id,
        "workflow_name": workflow_name,
        "sessions": [],
    }


def _provider_from_cli(provider_cli: str, executor: str) -> str:
    if executor == "shell":
        return "shell"
    if provider_cli in {"codex", "claude"}:
        return provider_cli
    return "builtin"


def upsert_session(
    sessions_path: str,
    run_id: str,
    workflow_id: str,
    workflow_name: str,
    session_id: str,
    step_id: str,
    capability: str,
    agent_alias: str,
    prompt_file: str,
    provider_cli: str,
    executor: str,
    lifecycle: str,
    result: str,
    input_mode: str,
    output_path: str,
    handoff_path: str,
    failure_reason: str,
    duration_seconds: str,
) -> None:
    """Upsert one CAP agent session into agent-sessions.json."""
    path = Path(sessions_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = _load_session_ledger(path, run_id, workflow_id, workflow_name)
    payload["run_id"] = run_id
    payload["workflow_id"] = workflow_id
    payload["workflow_name"] = workflow_name

    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    sessions = payload.setdefault("sessions", [])
    existing = None
    for item in sessions:
        if item.get("session_id") == session_id:
            existing = item
            break

    if existing is None:
        existing = {
            "session_id": session_id,
            "run_id": run_id,
            "workflow_id": workflow_id,
            "workflow_name": workflow_name,
            "step_id": step_id,
            "parent_session_id": None,
            "role": agent_alias,
            "capability": capability,
            "provider": _provider_from_cli(provider_cli, executor),
            "provider_cli": provider_cli,
            "executor": executor,
            "prompt_file": prompt_file or None,
            "lifecycle": lifecycle,
            "inputs": [],
            "outputs": [],
            "scratch_paths": [],
            "result": result,
            "started_at": now if lifecycle in {"planned", "running"} else None,
            "completed_at": None,
            "duration_seconds": None,
            "failure_reason": None,
            "recycle_policy": {
                "keep_raw_logs": True,
                "keep_prompts": False,
                "delete_scratch_on_success": False,
            },
        }
        sessions.append(existing)

    existing.update(
        {
            "run_id": run_id,
            "workflow_id": workflow_id,
            "workflow_name": workflow_name,
            "step_id": step_id,
            "role": agent_alias,
            "capability": capability,
            "provider": _provider_from_cli(provider_cli, executor),
            "provider_cli": provider_cli,
            "executor": executor,
            "prompt_file": prompt_file or None,
            "lifecycle": lifecycle,
            "result": result,
        }
    )

    if input_mode:
        existing["inputs"] = [{"artifact": "step_inputs", "path": "<resolved-context>", "mode": input_mode}]
    if output_path:
        outputs = [{"artifact": "step_output", "path": output_path, "promoted": False}]
        if handoff_path:
            outputs.append({"artifact": "handoff_summary", "path": handoff_path, "promoted": False})
        existing["outputs"] = outputs
    if lifecycle in {"completed", "failed", "blocked", "cancelled", "recycled"}:
        existing["completed_at"] = now
    if failure_reason:
        existing["failure_reason"] = failure_reason
    if duration_seconds:
        try:
            existing["duration_seconds"] = int(duration_seconds)
        except ValueError:
            existing["duration_seconds"] = None

    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


# ─────────────────────────────────────────────────────────
# 8. flatten-steps
# ─────────────────────────────────────────────────────────

def flatten_steps(plan_json: str) -> None:
    """將 plan JSON 展平為 pipe-delimited step 記錄（每行一個 step）。"""
    plan: dict[str, Any] = json.loads(plan_json)
    total = len(plan["phases"])

    for phase in plan["phases"]:
        pnum = phase["phase"]
        ids_joined = " + ".join(s["step_id"] for s in phase["steps"])
        agents_joined = ", ".join(
            dict.fromkeys(
                (s.get("agent_alias") or s.get("skill_id") or "-")
                for s in phase["steps"]
            )
        )
        for step in phase["steps"]:
            inputs = ",".join(step.get("inputs", []))
            opt = str(step.get("optional", False))
            resolution_status = step.get("resolution_status", "resolved")
            timeout_seconds = str(step.get("timeout_seconds") or "")
            stall_seconds = str(step.get("stall_seconds") or "")
            stall_action = str(step.get("stall_action") or "")
            input_mode = str(step.get("input_mode") or "")
            output_tier = str(step.get("output_tier") or "")
            continue_reason = str(step.get("continue_reason") or "").replace("|", "/")
            executor = str(step.get("executor") or "ai")
            script = str(step.get("script") or "").replace("|", "/")
            fallback = step.get("fallback") or {}
            fallback_executor = str(fallback.get("executor") or "")
            fallback_when = ",".join(fallback.get("when") or [])
            print("|".join([
                str(pnum), str(total), ids_joined, agents_joined,
                step["step_id"], step["capability"],
                step.get("agent_alias") or "",
                step.get("prompt_file") or "",
                step.get("cli") or "",
                inputs, opt, resolution_status,
                timeout_seconds, stall_seconds, stall_action,
                input_mode, output_tier, continue_reason,
                executor, script, fallback_executor, fallback_when,
            ]))


# ─────────────────────────────────────────────────────────
# 9. plan-meta
# ─────────────────────────────────────────────────────────

def plan_meta(plan_json: str) -> None:
    """從 plan JSON 抽出 workflow_id / workflow_name / total_phases，pipe-delimited。

    給 cap-workflow-exec.sh 之類的 shell 端用 `IFS='|' read` 拆解，
    取代散落多處的 ``python3 -c 'json.loads(...)'`` heredoc。
    """
    plan: dict[str, Any] = json.loads(plan_json)
    workflow_id = plan.get("workflow_id", "")
    workflow_name = plan.get("name", "")
    total_phases = len(plan.get("phases", []))
    print(f"{workflow_id}|{workflow_name}|{total_phases}")


# ─────────────────────────────────────────────────────────
# 10. parse-input-check
# ─────────────────────────────────────────────────────────

def parse_input_check() -> None:
    """從 stdin 讀 validate-inputs JSON，輸出 shell 友善兩行格式。

    輸出範例（用 newline 分隔）::

        True
        artifact_a, artifact_b

    第一行是 ok flag（``True`` 或 ``False``），第二行是 missing 清單以 ``", "`` 連接。
    """
    payload = json.load(sys.stdin)
    print("True" if payload.get("ok") else "False")
    missing = payload.get("missing", []) or []
    print(", ".join(missing))


# ─────────────────────────────────────────────────────────
# 11. registry-list / registry-get
# ─────────────────────────────────────────────────────────

def registry_list(registry_file: str) -> None:
    """列出 .cap.agents.json 內所有 agent，tab-delimited 行。

    取代 cap-registry.sh 內的 heredoc Python。
    """
    with open(registry_file, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    default_cli = data.get("default_cli", "codex")
    for alias, meta in sorted(data.get("agents", {}).items()):
        provider = meta.get("provider", "unknown")
        prompt_file = meta.get("prompt_file", "")
        cli = meta.get("cli", default_cli)
        print(f"{alias}\t{provider}\t{prompt_file}\t{cli}")


def registry_get(registry_file: str, alias: str) -> None:
    """取得指定 alias 的 agent metadata，輸出 JSON。

    缺 alias 時 exit 1（與原 cap-registry.sh 行為相同）。
    """
    with open(registry_file, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    meta = data.get("agents", {}).get(alias)
    if not meta:
        sys.exit(1)
    default_cli = data.get("default_cli", "codex")
    print(
        json.dumps(
            {
                "alias": alias,
                "provider": meta.get("provider", "builtin"),
                "prompt_file": meta.get("prompt_file", ""),
                "cli": meta.get("cli", default_cli),
            },
            ensure_ascii=False,
        )
    )


# ─────────────────────────────────────────────────────────
# 13. validate-constitution
# ─────────────────────────────────────────────────────────

def validate_constitution(constitution_path: str, schema_path: str) -> None:
    """Validate a Project Constitution JSON against the project-constitution schema.

    Output: JSON ``{"ok": bool, "errors": [...]}`` to stdout.
    Exit 0 on pass, exit 1 on fail (including missing files).

    Schema YAML is a JSON-Schema-style document (required + properties + type +
    enum). When jsonschema 4.x is installed we delegate to it; otherwise we fall
    back to a minimal required-field + type checker so the workflow does not
    break in degraded environments.
    """
    try:
        import yaml  # type: ignore[import]
    except ImportError:
        print(
            json.dumps(
                {"ok": False, "errors": ["pyyaml is required for validate-constitution"]},
                ensure_ascii=False,
            )
        )
        sys.exit(1)

    cpath = Path(constitution_path)
    spath = Path(schema_path)
    if not cpath.is_file():
        print(
            json.dumps(
                {"ok": False, "errors": [f"constitution file not found: {cpath}"]},
                ensure_ascii=False,
            )
        )
        sys.exit(1)
    if not spath.is_file():
        print(
            json.dumps(
                {"ok": False, "errors": [f"schema file not found: {spath}"]},
                ensure_ascii=False,
            )
        )
        sys.exit(1)

    try:
        with cpath.open("r", encoding="utf-8") as fh:
            constitution = json.load(fh)
    except Exception as exc:
        print(
            json.dumps(
                {"ok": False, "errors": [f"constitution JSON parse error: {exc}"]},
                ensure_ascii=False,
            )
        )
        sys.exit(1)

    try:
        with spath.open("r", encoding="utf-8") as fh:
            schema = yaml.safe_load(fh) or {}
    except Exception as exc:
        print(
            json.dumps(
                {"ok": False, "errors": [f"schema YAML parse error: {exc}"]},
                ensure_ascii=False,
            )
        )
        sys.exit(1)

    errors: list[str] = []
    try:
        from jsonschema import Draft202012Validator  # type: ignore[import]

        validator = Draft202012Validator(schema)
        for err in sorted(validator.iter_errors(constitution), key=lambda e: list(e.absolute_path)):
            loc = "/".join(str(p) for p in err.absolute_path) or "<root>"
            errors.append(f"{loc}: {err.message}")
    except ImportError:
        errors.extend(validate_jsonschema_fallback(constitution, schema))

    ok = not errors
    print(json.dumps({"ok": ok, "errors": errors}, ensure_ascii=False))
    if not ok:
        sys.exit(1)


_FALLBACK_TYPE_MAP: dict[str, type | tuple[type, ...]] = {
    "string": str,
    "integer": int,
    "number": (int, float),
    "boolean": bool,
    "array": list,
    "object": dict,
    "null": type(None),
}


def validate_jsonschema_fallback(data: Any, schema: Any) -> list[str]:
    """Lightweight JSON Schema validator used when ``jsonschema`` is absent.

    Supports the keywords actually used by CAP schemas:

    * ``required`` (recursive into nested objects via ``properties``)
    * ``type`` (recursive; accepts both single ``"string"`` and union
      ``["string", "null"]`` forms; ``"null"`` matches Python ``None``)
    * ``enum`` (recursive)
    * ``minItems`` for arrays
    * ``properties`` (recursive into object properties)
    * ``items`` (recursive into array items)

    Returns a list of ``"loc: message"`` strings (empty when valid).
    Location format mirrors ``Draft202012Validator``'s ``"/"``-joined
    absolute path, with ``<root>`` for the empty path, so callers can
    format both branches identically.
    """
    return _check_against_schema(data, schema, [])


def _resolve_allowed_types(
    expected: Any,
) -> list[type | tuple[type, ...]]:
    """Resolve a schema ``type`` keyword into the Python types we accept.

    Returns an empty list when the keyword is missing or unrecognized so
    callers can treat "no type assertion" and "unknown type label" as
    no-ops (matching ``Draft202012Validator``'s permissive handling of
    unknown type labels).
    """
    if isinstance(expected, str):
        py = _FALLBACK_TYPE_MAP.get(expected)
        return [py] if py is not None else []
    if isinstance(expected, list):
        resolved: list[type | tuple[type, ...]] = []
        for label in expected:
            if not isinstance(label, str):
                continue
            py = _FALLBACK_TYPE_MAP.get(label)
            if py is not None:
                resolved.append(py)
        return resolved
    return []


def _check_against_schema(data: Any, schema: Any, path: list[str]) -> list[str]:
    if not isinstance(schema, dict):
        return []

    errors: list[str] = []
    loc = "/".join(path) or "<root>"

    expected = schema.get("type")
    allowed = _resolve_allowed_types(expected)
    if allowed and not any(isinstance(data, t) for t in allowed):
        label = expected if isinstance(expected, str) else "|".join(
            str(x) for x in expected
        )
        errors.append(
            f"{loc}: expected type '{label}', got '{type(data).__name__}'"
        )
        return errors

    enum = schema.get("enum")
    if isinstance(enum, list) and data not in enum:
        errors.append(f"{loc}: value '{data}' not in enum {enum}")

    if isinstance(data, dict):
        for key in schema.get("required") or []:
            if key not in data:
                errors.append(f"{loc}: missing required field '{key}'")
        for key, sub in (schema.get("properties") or {}).items():
            if key in data and isinstance(sub, dict):
                errors.extend(_check_against_schema(data[key], sub, path + [key]))

    if isinstance(data, list):
        min_items = schema.get("minItems")
        if isinstance(min_items, int) and len(data) < min_items:
            errors.append(
                f"{loc}: array length {len(data)} less than minItems {min_items}"
            )
        items_schema = schema.get("items")
        if isinstance(items_schema, dict):
            for index, item in enumerate(data):
                errors.extend(
                    _check_against_schema(item, items_schema, path + [str(index)])
                )

    return errors


# ─────────────────────────────────────────────────────────
# CLI entry point
# ─────────────────────────────────────────────────────────

def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="step_runtime",
        description="Workflow step 輔助函式集 — cap-workflow-exec.sh 行內 Python 整合",
    )
    sub = parser.add_subparsers(dest="subcommand", required=True)

    # 1. update-status
    p_us = sub.add_parser("update-status", help="更新 workflow 狀態檔")
    p_us.add_argument("status_file")
    p_us.add_argument("workflow_id")
    p_us.add_argument("name")
    p_us.add_argument("state")
    p_us.add_argument("result")

    # 2. handoff-summary
    p_hs = sub.add_parser("handoff-summary", help="擷取 artifact 交接摘要")
    p_hs.add_argument("artifact_path")

    # 3. resolve-inputs
    p_ri = sub.add_parser("resolve-inputs", help="解析 step 輸入上下文")
    p_ri.add_argument("plan_json")
    p_ri.add_argument("step_id")
    p_ri.add_argument("input_mode")
    p_ri.add_argument("registry_path")

    # 4. resolve-contract
    p_rc = sub.add_parser("resolve-contract", help="解析 step 契約與完成條件")
    p_rc.add_argument("plan_json")
    p_rc.add_argument("step_id")

    # 5. validate-inputs
    p_vi = sub.add_parser("validate-inputs", help="驗證 step 輸入是否齊備")
    p_vi.add_argument("plan_json")
    p_vi.add_argument("step_id")
    p_vi.add_argument("registry_path")

    # 6. register-state
    p_rs = sub.add_parser("register-state", help="註冊 step 執行狀態至 registry")
    p_rs.add_argument("plan_json")
    p_rs.add_argument("registry_path")
    p_rs.add_argument("step_id")
    p_rs.add_argument("execution_state")
    p_rs.add_argument("blocked_reason")
    p_rs.add_argument("output_source")
    p_rs.add_argument("output_path")
    p_rs.add_argument("handoff_path")

    # 7. flatten-steps
    p_usess = sub.add_parser("upsert-session", help="註冊或更新 CAP agent session ledger")
    p_usess.add_argument("sessions_path")
    p_usess.add_argument("run_id")
    p_usess.add_argument("workflow_id")
    p_usess.add_argument("workflow_name")
    p_usess.add_argument("session_id")
    p_usess.add_argument("step_id")
    p_usess.add_argument("capability")
    p_usess.add_argument("agent_alias")
    p_usess.add_argument("prompt_file")
    p_usess.add_argument("provider_cli")
    p_usess.add_argument("executor")
    p_usess.add_argument("lifecycle")
    p_usess.add_argument("result")
    p_usess.add_argument("input_mode")
    p_usess.add_argument("output_path")
    p_usess.add_argument("handoff_path")
    p_usess.add_argument("failure_reason")
    p_usess.add_argument("duration_seconds")

    # 8. flatten-steps
    p_fs = sub.add_parser("flatten-steps", help="展平 plan JSON 為 pipe-delimited 記錄")
    p_fs.add_argument("plan_json")

    # 9. plan-meta
    p_pm = sub.add_parser("plan-meta", help="抽 plan JSON 的 workflow_id / name / phase 數")
    p_pm.add_argument("plan_json")

    # 10. parse-input-check
    sub.add_parser(
        "parse-input-check",
        help="從 stdin 讀 validate-inputs JSON，輸出 shell 友善兩行格式",
    )

    # 11. registry-list
    p_rl = sub.add_parser("registry-list", help="列出 .cap.agents.json 所有 agent")
    p_rl.add_argument("registry_file")

    # 12. registry-get
    p_rg = sub.add_parser("registry-get", help="取得指定 alias 的 agent metadata（JSON）")
    p_rg.add_argument("registry_file")
    p_rg.add_argument("alias")

    # 13. validate-constitution
    p_vc = sub.add_parser(
        "validate-constitution",
        help="用 jsonschema 對照 project-constitution schema 驗證 constitution JSON",
    )
    p_vc.add_argument("constitution_path")
    p_vc.add_argument("schema_path")

    # 14. validate-jsonschema (generic alias)
    p_vjs = sub.add_parser(
        "validate-jsonschema",
        help="generic JSON Schema validator; delegates to the same engine as validate-constitution",
    )
    p_vjs.add_argument("json_path")
    p_vjs.add_argument("schema_path")

    return parser


def main(argv: list[str] | None = None) -> None:
    parser = _build_parser()
    args = parser.parse_args(argv)

    match args.subcommand:
        case "update-status":
            update_status(
                args.status_file,
                args.workflow_id,
                args.name,
                args.state,
                args.result,
            )
        case "handoff-summary":
            handoff_summary(args.artifact_path)
        case "resolve-inputs":
            resolve_inputs(
                args.plan_json,
                args.step_id,
                args.input_mode,
                args.registry_path,
            )
        case "resolve-contract":
            resolve_contract(args.plan_json, args.step_id)
        case "validate-inputs":
            validate_inputs(
                args.plan_json,
                args.step_id,
                args.registry_path,
            )
        case "register-state":
            register_state(
                args.plan_json,
                args.registry_path,
                args.step_id,
                args.execution_state,
                args.blocked_reason,
                args.output_source,
                args.output_path,
                args.handoff_path,
            )
        case "upsert-session":
            upsert_session(
                args.sessions_path,
                args.run_id,
                args.workflow_id,
                args.workflow_name,
                args.session_id,
                args.step_id,
                args.capability,
                args.agent_alias,
                args.prompt_file,
                args.provider_cli,
                args.executor,
                args.lifecycle,
                args.result,
                args.input_mode,
                args.output_path,
                args.handoff_path,
                args.failure_reason,
                args.duration_seconds,
            )
        case "flatten-steps":
            flatten_steps(args.plan_json)
        case "plan-meta":
            plan_meta(args.plan_json)
        case "parse-input-check":
            parse_input_check()
        case "registry-list":
            registry_list(args.registry_file)
        case "registry-get":
            registry_get(args.registry_file, args.alias)
        case "validate-constitution":
            validate_constitution(args.constitution_path, args.schema_path)
        case "validate-jsonschema":
            validate_constitution(args.json_path, args.schema_path)


if __name__ == "__main__":
    main()
