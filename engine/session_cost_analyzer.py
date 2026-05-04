"""Session cost analyzer — aggregate token / time analytics over agent-sessions.json.

Powers ``cap session analyze`` so users and downstream agents can spot
hotspots (longest sessions, largest prompts, repeated prompts that
could share a cache, failure / timeout concentrations) without
manually crunching the ledger JSON.

Read-only: reuses ``engine.session_inspector`` scanning helpers
(``_iter_sessions_files`` / ``_load_sessions``) so the on-disk format
stays single-sourced. Default scan walks
``<CAP_HOME or ~/.cap>/projects/*/reports/workflows/*/*/agent-sessions.json``;
``--sessions-path`` overrides for hermetic tests and single-file inspection.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter, defaultdict
from typing import Any

try:
    from .session_inspector import _iter_sessions_files, _load_sessions
except ImportError:  # pragma: no cover
    from session_inspector import _iter_sessions_files, _load_sessions  # type: ignore[no-redef]


def collect_sessions(
    *,
    sessions_path: str | None = None,
    run_id: str | None = None,
    workflow_id: str | None = None,
) -> list[dict]:
    """Scan ledger files and return matching session dicts.

    Each entry gains a ``_source_path`` annotation so downstream tools
    can locate the on-disk record.
    """
    matches: list[dict] = []
    for path in _iter_sessions_files(sessions_path):
        for session in _load_sessions(path):
            if run_id is not None and session.get("run_id") != run_id:
                continue
            if workflow_id is not None and session.get("workflow_id") != workflow_id:
                continue
            annotated = dict(session)
            annotated["_source_path"] = str(path)
            matches.append(annotated)
    return matches


def _safe_int(value: Any) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def analyze(sessions: list[dict], *, top_n: int = 5) -> dict:
    """Build the aggregate report dict over a session list.

    Returned shape (matches ``cap session analyze --json`` envelope):
    ``total_sessions`` / ``total_duration_seconds`` / ``lifecycle_counts``
    / ``by_provider[]`` / ``by_capability[]`` / ``largest_prompts[]``
    / ``duplicate_prompts[]`` / ``longest_sessions[]`` / ``failures{}``.
    Each top-N list is truncated by the caller-supplied ``top_n``.
    """
    total = len(sessions)
    total_duration = sum(_safe_int(s.get("duration_seconds")) for s in sessions)

    lifecycle_counts: Counter[str] = Counter(
        (s.get("lifecycle") or "<unknown>") for s in sessions
    )

    provider_groups: dict[str, dict] = defaultdict(
        lambda: {"count": 0, "duration_seconds": 0, "failed": 0}
    )
    for session in sessions:
        key = session.get("provider_cli") or session.get("provider") or "<unknown>"
        provider_groups[key]["count"] += 1
        provider_groups[key]["duration_seconds"] += _safe_int(
            session.get("duration_seconds")
        )
        if session.get("lifecycle") == "failed":
            provider_groups[key]["failed"] += 1

    capability_groups: dict[str, dict] = defaultdict(
        lambda: {"count": 0, "duration_seconds": 0, "failed": 0}
    )
    for session in sessions:
        key = session.get("capability") or "<unknown>"
        capability_groups[key]["count"] += 1
        capability_groups[key]["duration_seconds"] += _safe_int(
            session.get("duration_seconds")
        )
        if session.get("lifecycle") == "failed":
            capability_groups[key]["failed"] += 1

    sized_sessions = [
        s for s in sessions if _safe_int(s.get("prompt_size_bytes")) > 0
    ]
    largest_prompts = sorted(
        sized_sessions,
        key=lambda s: _safe_int(s.get("prompt_size_bytes")),
        reverse=True,
    )[:top_n]

    hash_counts: Counter[str] = Counter(
        s["prompt_hash"] for s in sessions if s.get("prompt_hash")
    )
    duplicate_prompts = [
        {"prompt_hash": h, "occurrences": c}
        for h, c in hash_counts.most_common()
        if c > 1
    ][:top_n]

    longest_sessions = sorted(
        sessions, key=lambda s: _safe_int(s.get("duration_seconds")), reverse=True
    )[:top_n]

    failed_sessions = [s for s in sessions if s.get("lifecycle") == "failed"]
    timeout_failures = [
        s for s in failed_sessions
        if (s.get("failure_reason") or "").startswith("timeout:")
    ]
    failures_by_capability: Counter[str] = Counter(
        (s.get("capability") or "<unknown>") for s in failed_sessions
    )

    return {
        "total_sessions": total,
        "total_duration_seconds": total_duration,
        "lifecycle_counts": dict(lifecycle_counts),
        "by_provider": [
            {"name": name, **stats}
            for name, stats in sorted(
                provider_groups.items(),
                key=lambda kv: kv[1]["duration_seconds"],
                reverse=True,
            )
        ],
        "by_capability": [
            {"name": name, **stats}
            for name, stats in sorted(
                capability_groups.items(),
                key=lambda kv: kv[1]["duration_seconds"],
                reverse=True,
            )
        ],
        "largest_prompts": [
            {
                "session_id": s.get("session_id"),
                "prompt_size_bytes": _safe_int(s.get("prompt_size_bytes")),
                "prompt_hash": s.get("prompt_hash"),
                "step_id": s.get("step_id"),
                "capability": s.get("capability"),
            }
            for s in largest_prompts
        ],
        "duplicate_prompts": duplicate_prompts,
        "longest_sessions": [
            {
                "session_id": s.get("session_id"),
                "duration_seconds": _safe_int(s.get("duration_seconds")),
                "step_id": s.get("step_id"),
                "capability": s.get("capability"),
                "provider_cli": s.get("provider_cli"),
                "lifecycle": s.get("lifecycle"),
            }
            for s in longest_sessions
        ],
        "failures": {
            "total": len(failed_sessions),
            "timeout": len(timeout_failures),
            "by_capability": dict(failures_by_capability),
        },
    }


def render_text(report: dict, *, top_n: int = 5) -> str:
    """Human-readable text rendering."""
    lines: list[str] = []
    lines.append(f"total_sessions: {report['total_sessions']}")
    lines.append(f"total_duration_seconds: {report['total_duration_seconds']}")

    lines.append("")
    lines.append("lifecycle:")
    if report["lifecycle_counts"]:
        for state, count in sorted(
            report["lifecycle_counts"].items(), key=lambda kv: kv[1], reverse=True
        ):
            lines.append(f"  {state}: {count}")
    else:
        lines.append("  (none)")

    lines.append("")
    lines.append(f"by_provider (top {top_n} by duration):")
    if report["by_provider"]:
        for group in report["by_provider"][:top_n]:
            lines.append(
                f"  {group['name']:<16} "
                f"count={group['count']:<4} "
                f"duration={group['duration_seconds']:<6}s "
                f"failed={group['failed']}"
            )
    else:
        lines.append("  (none)")

    lines.append("")
    lines.append(f"by_capability (top {top_n} by duration):")
    if report["by_capability"]:
        for group in report["by_capability"][:top_n]:
            lines.append(
                f"  {group['name']:<32} "
                f"count={group['count']:<4} "
                f"duration={group['duration_seconds']:<6}s "
                f"failed={group['failed']}"
            )
    else:
        lines.append("  (none)")

    lines.append("")
    lines.append(f"largest_prompts (top {top_n} by size):")
    if report["largest_prompts"]:
        for entry in report["largest_prompts"]:
            cap = entry.get("capability") or "-"
            step = entry.get("step_id") or "-"
            lines.append(
                f"  {entry['prompt_size_bytes']:>8}B  "
                f"{entry['session_id']}  step={step}  cap={cap}"
            )
    else:
        lines.append("  (no prompt_size_bytes recorded)")

    lines.append("")
    lines.append(f"duplicate_prompts (top {top_n} by occurrences):")
    if report["duplicate_prompts"]:
        for entry in report["duplicate_prompts"]:
            short_hash = (entry["prompt_hash"] or "")[:16]
            lines.append(f"  {entry['occurrences']}x  {short_hash}...")
    else:
        lines.append("  (no duplicates — every prompt is unique)")

    lines.append("")
    lines.append(f"longest_sessions (top {top_n} by duration):")
    if report["longest_sessions"]:
        for entry in report["longest_sessions"]:
            cap = entry.get("capability") or "-"
            lifecycle = entry.get("lifecycle") or "-"
            lines.append(
                f"  {entry['duration_seconds']:>5}s  "
                f"{entry['session_id']}  {lifecycle:<10} cap={cap}"
            )
    else:
        lines.append("  (none)")

    lines.append("")
    failures = report["failures"]
    lines.append(
        f"failures: total={failures['total']} timeout={failures['timeout']}"
    )
    if failures["by_capability"]:
        lines.append("  by_capability:")
        for cap, count in sorted(
            failures["by_capability"].items(), key=lambda kv: kv[1], reverse=True
        ):
            lines.append(f"    {cap}: {count}")

    return "\n".join(lines)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="cap session analyze",
        description=(
            "Aggregate token / time analytics over the CAP agent session ledger "
            "(read-only). Use --json for machine consumers."
        ),
    )
    parser.add_argument("--run-id", default=None, help="Restrict to a single run_id.")
    parser.add_argument(
        "--workflow-id", default=None, help="Restrict to a single workflow_id."
    )
    parser.add_argument(
        "--top",
        type=int,
        default=5,
        help="Top-N depth for hot lists (default 5).",
    )
    parser.add_argument(
        "--json", action="store_true", help="Emit JSON envelope instead of text."
    )
    parser.add_argument(
        "--sessions-path",
        default=None,
        help="Read from a specific agent-sessions.json file (overrides default scan).",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    sessions = collect_sessions(
        sessions_path=args.sessions_path,
        run_id=args.run_id,
        workflow_id=args.workflow_id,
    )

    if not sessions:
        query = {
            "run_id": args.run_id,
            "workflow_id": args.workflow_id,
            "sessions_path": args.sessions_path,
        }
        query = {k: v for k, v in query.items() if v is not None}
        print(
            json.dumps(
                {"ok": False, "error": "no_sessions_found", "query": query},
                ensure_ascii=False,
            )
        )
        return 1

    report = analyze(sessions, top_n=args.top)

    if args.json:
        print(json.dumps({"ok": True, **report}, ensure_ascii=False))
    else:
        print(render_text(report, top_n=args.top))
    return 0


if __name__ == "__main__":
    sys.exit(main())
