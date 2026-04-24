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

def _intrinsic_context(artifact: str) -> str:
    """產生內建 intrinsic artifact 的上下文文字。"""
    if artifact == "user_requirement":
        return "intrinsic_request"

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

    return "intrinsic_unknown"


_INTRINSIC_ARTIFACTS = frozenset(
    {"user_requirement", "repo_changes", "project_context", "commit_scope"}
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
            for detail in _intrinsic_context(artifact).splitlines():
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

    for artifact in target.get("inputs", []):
        if artifact in _INTRINSIC_ARTIFACTS:
            resolved.append(
                {
                    "artifact": artifact,
                    "source_step": "__request__",
                    "path": "<inline:user_request>",
                    "handoff_path": "",
                }
            )
            continue

        entry = registry.get("artifacts", {}).get(artifact)
        if not entry:
            missing.append(artifact)
            continue

        source_step = entry.get("source_step")
        source_state = (
            registry.get("steps", {}).get(source_step, {}).get("execution_state")
        )
        if source_state != "validated":
            missing.append(artifact)
            continue

        resolved.append(
            {
                "artifact": artifact,
                "source_step": source_step,
                "path": entry.get("path"),
                "handoff_path": entry.get("handoff_path"),
            }
        )

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
# 7. flatten-steps
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
            print("|".join([
                str(pnum), str(total), ids_joined, agents_joined,
                step["step_id"], step["capability"],
                step.get("agent_alias") or "",
                step.get("prompt_file") or "",
                step.get("cli") or "",
                inputs, opt, resolution_status,
                timeout_seconds, stall_seconds, stall_action,
                input_mode, output_tier, continue_reason,
            ]))


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
    p_fs = sub.add_parser("flatten-steps", help="展平 plan JSON 為 pipe-delimited 記錄")
    p_fs.add_argument("plan_json")

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
        case "flatten-steps":
            flatten_steps(args.plan_json)


if __name__ == "__main__":
    main()
