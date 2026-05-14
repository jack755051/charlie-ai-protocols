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

try:
    from .cost_hotspot_report import build_cost_hotspot
except ImportError:  # pragma: no cover
    from cost_hotspot_report import build_cost_hotspot  # type: ignore[no-redef]


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


def _build_usage_totals(sessions: list[dict]) -> dict[str, Any]:
    """Aggregate per-run usage totals over the ledger.

    Pulls metric values out of ``session["usage"]`` (the normalized
    telemetry shape persisted since 9fd8355). Falls back to the
    session-level ``prompt_size_bytes`` first-class field for sessions
    that pre-date that commit so legacy runs still get partial coverage.

    None / 0 telemetry sessions are tracked separately via
    ``available_sessions`` / ``unavailable_sessions`` so operators can
    see provider parity at a glance (P0d will eventually push this to
    100% available across both Claude and Codex).
    """
    available = 0
    unavailable = 0
    total_prompt_bytes = 0
    total_output_bytes = 0
    total_tokens = 0
    saw_prompt_bytes = False
    saw_output_bytes = False
    saw_tokens = False

    for session in sessions:
        usage = session.get("usage") if isinstance(session.get("usage"), dict) else None
        if usage and usage.get("available") is True:
            available += 1
        elif usage is not None:
            unavailable += 1

        # Prompt bytes — prefer usage.prompt_size_bytes, fall back to legacy top-level.
        pb = None
        if usage and isinstance(usage.get("prompt_size_bytes"), int):
            pb = usage["prompt_size_bytes"]
        elif isinstance(session.get("prompt_size_bytes"), int):
            pb = session["prompt_size_bytes"]
        if pb is not None:
            total_prompt_bytes += pb
            saw_prompt_bytes = True

        if usage and isinstance(usage.get("output_size_bytes"), int):
            total_output_bytes += usage["output_size_bytes"]
            saw_output_bytes = True

        if usage and isinstance(usage.get("total_tokens"), int):
            total_tokens += usage["total_tokens"]
            saw_tokens = True

    return {
        "available_sessions": available,
        "unavailable_sessions": unavailable,
        "total_prompt_bytes": total_prompt_bytes if saw_prompt_bytes else None,
        "total_output_bytes": total_output_bytes if saw_output_bytes else None,
        "total_tokens": total_tokens if saw_tokens else None,
    }


def _build_unavailable_reasons(sessions: list[dict]) -> list[dict[str, Any]]:
    """Aggregate ``usage.reason`` strings for sessions whose provider
    did not expose token counts.

    Returns a list of ``{reason, count}`` entries sorted by count desc.
    Empty list when all sessions are either ``available=true`` or have
    no usage object at all. Surfaces provider-specific gaps (e.g.
    ``"provider did not expose token usage; byte counts recorded"``)
    so the operator can see *why* tokens are null instead of guessing.
    """
    reasons: Counter[str] = Counter()
    for session in sessions:
        usage = session.get("usage")
        if not isinstance(usage, dict):
            continue
        if usage.get("available") is True:
            continue
        reason = usage.get("reason")
        if isinstance(reason, str) and reason:
            reasons[reason] += 1
        else:
            reasons["(no reason recorded)"] += 1
    return [
        {"reason": reason, "count": count}
        for reason, count in reasons.most_common()
    ]


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
        # P0b-1: per-step usage telemetry projection. Built from
        # session.usage objects (post-9fd8355) plus the legacy
        # session.prompt_size_bytes fallback for older ledgers. Sourced
        # via the same build_cost_hotspot library that result_report_
        # builder uses, so per-run result.md and `cap session analyze
        # --run-id` show the same shape.
        "usage_totals": _build_usage_totals(sessions),
        "unavailable_reasons": _build_unavailable_reasons(sessions),
        "cost_hotspot": build_cost_hotspot(sessions),
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

    # P0b-1: usage telemetry sections — totals, provider parity reasons,
    # and per-step ranking pulled from build_cost_hotspot.
    def _fmt_bytes(value: Any) -> str:
        return f"{value}B" if isinstance(value, int) else "null"

    def _fmt_int(value: Any) -> str:
        return str(value) if isinstance(value, int) else "null"

    usage_totals = report.get("usage_totals") or {}
    if usage_totals:
        avail = usage_totals.get("available_sessions", 0)
        unavail = usage_totals.get("unavailable_sessions", 0)
        total_seen = avail + unavail
        lines.append("")
        lines.append("usage_totals:")
        lines.append(
            f"  provider_token_telemetry_available: {avail}/{total_seen}"
        )
        lines.append(
            f"  total_prompt_bytes:  {_fmt_bytes(usage_totals.get('total_prompt_bytes'))}"
        )
        lines.append(
            f"  total_output_bytes:  {_fmt_bytes(usage_totals.get('total_output_bytes'))}"
        )
        lines.append(
            f"  total_tokens:        {_fmt_int(usage_totals.get('total_tokens'))}"
        )

    unavailable_reasons = report.get("unavailable_reasons") or []
    if unavailable_reasons:
        lines.append("")
        lines.append("tokens_unavailable_reasons:")
        for entry in unavailable_reasons:
            lines.append(f"  {entry['count']}x  {entry['reason']}")

    hotspot = report.get("cost_hotspot") or {}
    by_step = hotspot.get("by_step") or []
    if by_step:
        # Top N by prompt bytes (already sorted by build_cost_hotspot).
        lines.append("")
        lines.append(f"cost_hotspot.by_step (top {top_n} by prompt bytes):")
        for entry in by_step[:top_n]:
            sid = entry.get("step_id") or "-"
            cap = entry.get("capability") or "-"
            lines.append(
                f"  {sid:<28} cap={cap:<28} "
                f"prompt={_fmt_bytes(entry.get('prompt_size_bytes')):<10} "
                f"out={_fmt_bytes(entry.get('output_size_bytes')):<10} "
                f"tokens={_fmt_int(entry.get('total_tokens')):<8} "
                f"dur={_fmt_int(entry.get('duration_seconds'))}s"
            )

        # Top N by output bytes — same source list, re-sorted.
        by_output = sorted(
            by_step,
            key=lambda s: (
                s["output_size_bytes"]
                if isinstance(s.get("output_size_bytes"), int)
                else -1
            ),
            reverse=True,
        )
        if any(isinstance(s.get("output_size_bytes"), int) for s in by_output):
            lines.append("")
            lines.append(f"cost_hotspot.by_step (top {top_n} by output bytes):")
            for entry in by_output[:top_n]:
                if not isinstance(entry.get("output_size_bytes"), int):
                    continue
                sid = entry.get("step_id") or "-"
                cap = entry.get("capability") or "-"
                lines.append(
                    f"  {sid:<28} cap={cap:<28} "
                    f"out={_fmt_bytes(entry.get('output_size_bytes')):<10} "
                    f"prompt={_fmt_bytes(entry.get('prompt_size_bytes')):<10} "
                    f"dur={_fmt_int(entry.get('duration_seconds'))}s"
                )

        # Top N by duration — same source list, re-sorted.
        by_duration = sorted(
            by_step,
            key=lambda s: (
                s["duration_seconds"]
                if isinstance(s.get("duration_seconds"), int)
                else -1
            ),
            reverse=True,
        )
        if any(isinstance(s.get("duration_seconds"), int) for s in by_duration):
            lines.append("")
            lines.append(f"cost_hotspot.by_step (top {top_n} by duration):")
            for entry in by_duration[:top_n]:
                if not isinstance(entry.get("duration_seconds"), int):
                    continue
                sid = entry.get("step_id") or "-"
                cap = entry.get("capability") or "-"
                lines.append(
                    f"  {entry['duration_seconds']:>5}s  {sid:<28} cap={cap}"
                )

    by_capability_hotspot = hotspot.get("by_capability") or []
    if by_capability_hotspot:
        lines.append("")
        lines.append(f"cost_hotspot.by_capability (top {top_n} by prompt bytes):")
        for entry in by_capability_hotspot[:top_n]:
            cap = entry.get("capability") or "-"
            sess = entry.get("sessions") or 0
            lines.append(
                f"  {cap:<32} sessions={sess:<4} "
                f"prompt={_fmt_bytes(entry.get('prompt_size_bytes')):<10} "
                f"out={_fmt_bytes(entry.get('output_size_bytes')):<10} "
                f"tokens={_fmt_int(entry.get('total_tokens'))}"
            )

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
