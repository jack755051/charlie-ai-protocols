"""Artifact inspector — read-only queries against the runtime-state.json registry.

Powers ``cap artifact list / inspect / by-step`` so users and downstream
agents can audit which artifacts a workflow run produced, who produced
each one, and which capabilities could potentially consume them — all
without touching the runtime executor or the registry on disk.

Read-only by design: no mutation paths live here. Mirrors
``engine.session_inspector`` shape so the two query layers stay
parallel (sessions inspector reads ``agent-sessions.json``; this one
reads ``runtime-state.json``).

Default scan walks
``<CAP_HOME or ~/.cap>/projects/*/reports/workflows/*/*/runtime-state.json``;
``--runtime-state`` overrides for hermetic tests and explicit single-file
inspection.

Consumer derivation rule (P6 #2 lineage, conservative):
  An artifact's ``derived_consumers`` are the steps in the same run
  whose capability declares the artifact name in its ``inputs:`` list
  (per ``schemas/capabilities.yaml``). The label is **derived**, not
  ``actual_consumers`` — the registry today does not record actual
  consumption events; this is a static cross-reference. When the
  capabilities map cannot be loaded the field is omitted entirely
  rather than reported as empty (avoids false negatives).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Iterable

DEFAULT_SCAN_GLOB = "*/reports/workflows/*/*/runtime-state.json"


def _cap_projects_root() -> Path:
    home = os.environ.get("CAP_HOME")
    if home:
        return Path(home) / "projects"
    return Path.home() / ".cap" / "projects"


def _iter_runtime_state_files(runtime_state_path: str | None) -> Iterable[Path]:
    if runtime_state_path:
        path = Path(runtime_state_path)
        if path.is_file():
            yield path
        return
    root = _cap_projects_root()
    if not root.is_dir():
        return
    yield from sorted(root.glob(DEFAULT_SCAN_GLOB))


def _load_runtime_state(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def _load_capabilities_index(repo_root: Path | None = None) -> dict[str, list[str]]:
    """Build artifact_name → [capability_name, ...] reverse index.

    Returns an empty dict when ``schemas/capabilities.yaml`` cannot be
    read or yaml is unavailable; callers should treat the
    ``derived_consumers`` field as unknown / unavailable in that case
    rather than asserting "no consumers".
    """
    try:
        import yaml  # type: ignore[import]
    except ImportError:
        return {}
    root = repo_root or Path(__file__).resolve().parents[1]
    schema_path = root / "schemas" / "capabilities.yaml"
    if not schema_path.is_file():
        return {}
    try:
        data = yaml.safe_load(schema_path.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError:
        return {}
    capabilities = data.get("capabilities") or {}
    index: dict[str, list[str]] = {}
    for cap_name, cap_info in capabilities.items():
        if not isinstance(cap_info, dict):
            continue
        for input_name in cap_info.get("inputs") or []:
            if isinstance(input_name, str):
                index.setdefault(input_name, []).append(cap_name)
    return index


def collect_artifacts(
    *,
    runtime_state_path: str | None = None,
    artifact_name: str | None = None,
    step_id: str | None = None,
) -> list[dict]:
    """Return artifact entries (with annotations) from one or many runtime-state ledgers.

    Each result entry has the original 4 fields from runtime-state plus:
    ``_source_runtime_state`` (path of the ledger file) and
    ``derived_consumers`` (capabilities that declare this artifact as
    input AND have a matching step in the same run; omitted entirely
    when the capabilities index cannot be built).
    """
    cap_index = _load_capabilities_index()
    matches: list[dict] = []
    for path in _iter_runtime_state_files(runtime_state_path):
        state = _load_runtime_state(path)
        artifacts = state.get("artifacts") or {}
        steps = state.get("steps") or {}

        # Build per-run reverse index: capability_name → [step_id, ...]
        cap_to_steps: dict[str, list[str]] = {}
        for sid, sinfo in steps.items():
            if not isinstance(sinfo, dict):
                continue
            cap = sinfo.get("capability")
            if isinstance(cap, str):
                cap_to_steps.setdefault(cap, []).append(sid)

        for name, info in artifacts.items():
            if not isinstance(info, dict):
                continue
            if artifact_name is not None and info.get("artifact") != artifact_name:
                continue
            if step_id is not None and info.get("source_step") != step_id:
                continue

            entry = dict(info)
            entry["_source_runtime_state"] = str(path)
            if cap_index:
                consumer_steps: list[dict] = []
                for cap_name in cap_index.get(name, []):
                    for sid in cap_to_steps.get(cap_name, []):
                        consumer_steps.append({"step_id": sid, "capability": cap_name})
                entry["derived_consumers"] = consumer_steps
            matches.append(entry)
    return matches


def render_artifact_list(matches: list[dict]) -> str:
    """Compact one-line-per-artifact text rendering for `cap artifact list`."""
    if not matches:
        return "(no artifacts found)"
    lines: list[str] = []
    lines.append(f"{'ARTIFACT':<32} {'PRODUCER STEP':<28} CONSUMERS")
    for entry in matches:
        name = entry.get("artifact", "-")
        producer = entry.get("source_step", "-")
        consumers = entry.get("derived_consumers")
        if consumers is None:
            cons_label = "(unknown)"
        elif not consumers:
            cons_label = "(no derived consumers)"
        else:
            cons_label = ", ".join(c["step_id"] for c in consumers)
        lines.append(f"{name:<32} {producer:<28} {cons_label}")
    return "\n".join(lines)


def render_artifact_detail(entry: dict) -> str:
    """Multi-line block per artifact for `cap artifact inspect`."""
    lines: list[str] = []
    lines.append(f"artifact: {entry.get('artifact', '-')}")
    lines.append(f"  source_step: {entry.get('source_step', '-')}")
    lines.append(f"  path: {entry.get('path', '-')}")
    lines.append(f"  handoff_path: {entry.get('handoff_path', '-')}")
    consumers = entry.get("derived_consumers")
    if consumers is None:
        lines.append("derived_consumers: (capabilities index unavailable)")
    elif not consumers:
        lines.append("derived_consumers: (no capability in this run declares it as input)")
    else:
        lines.append("derived_consumers:")
        for c in consumers:
            lines.append(f"  - step_id={c['step_id']}  capability={c['capability']}")
    source = entry.get("_source_runtime_state")
    if source:
        lines.append(f"source_runtime_state: {source}")
    return "\n".join(lines)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="cap artifact",
        description="Inspect runtime-state.json artifact registry (read-only).",
    )
    sub = parser.add_subparsers(dest="subcommand", required=True)

    p_list = sub.add_parser("list", help="List all artifacts in the registry.")
    p_list.add_argument("--json", action="store_true")
    p_list.add_argument("--runtime-state", default=None)

    p_inspect = sub.add_parser(
        "inspect", help="Inspect a single artifact by name."
    )
    p_inspect.add_argument("artifact_name")
    p_inspect.add_argument("--json", action="store_true")
    p_inspect.add_argument("--runtime-state", default=None)

    p_by_step = sub.add_parser(
        "by-step",
        help="List artifacts produced by a given source step_id.",
    )
    p_by_step.add_argument("step_id")
    p_by_step.add_argument("--json", action="store_true")
    p_by_step.add_argument("--runtime-state", default=None)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    if args.subcommand == "list":
        matches = collect_artifacts(runtime_state_path=args.runtime_state)
        if not matches:
            query = (
                {"runtime_state": args.runtime_state}
                if args.runtime_state else {}
            )
            print(
                json.dumps(
                    {"ok": False, "error": "no_artifacts_found", "query": query},
                    ensure_ascii=False,
                )
            )
            return 1
        if args.json:
            print(
                json.dumps(
                    {"ok": True, "count": len(matches), "artifacts": matches},
                    ensure_ascii=False,
                )
            )
        else:
            print(render_artifact_list(matches))
        return 0

    if args.subcommand == "inspect":
        matches = collect_artifacts(
            runtime_state_path=args.runtime_state,
            artifact_name=args.artifact_name,
        )
        if not matches:
            query = {"artifact_name": args.artifact_name}
            if args.runtime_state:
                query["runtime_state"] = args.runtime_state
            print(
                json.dumps(
                    {"ok": False, "error": "artifact_not_found", "query": query},
                    ensure_ascii=False,
                )
            )
            return 1
        if args.json:
            print(
                json.dumps(
                    {"ok": True, "count": len(matches), "artifacts": matches},
                    ensure_ascii=False,
                )
            )
            return 0
        for index, entry in enumerate(matches):
            if index > 0:
                print()
                print("-" * 60)
                print()
            print(render_artifact_detail(entry))
        return 0

    if args.subcommand == "by-step":
        matches = collect_artifacts(
            runtime_state_path=args.runtime_state,
            step_id=args.step_id,
        )
        if not matches:
            query = {"step_id": args.step_id}
            if args.runtime_state:
                query["runtime_state"] = args.runtime_state
            print(
                json.dumps(
                    {"ok": False, "error": "no_artifacts_for_step", "query": query},
                    ensure_ascii=False,
                )
            )
            return 1
        if args.json:
            print(
                json.dumps(
                    {"ok": True, "count": len(matches), "artifacts": matches},
                    ensure_ascii=False,
                )
            )
        else:
            print(render_artifact_list(matches))
        return 0

    parser.error(f"unknown subcommand: {args.subcommand}")
    return 2


if __name__ == "__main__":
    sys.exit(main())
