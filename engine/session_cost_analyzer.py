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


def _humanize_duration(seconds: int) -> str:
    """Convert int seconds to a human-readable HH? MM SS form.

    Examples: 45 -> "45s", 1498 -> "24m 58s", 2665 -> "44m 25s",
    7325 -> "2h 02m 05s". Used by the Summary header so operators can
    read total duration without converting seconds in their head; the
    raw int still appears in parentheses for precise comparisons.
    """
    if not isinstance(seconds, int) or seconds < 0:
        return "0s"
    if seconds < 60:
        return f"{seconds}s"
    minutes, secs = divmod(seconds, 60)
    if minutes < 60:
        return f"{minutes}m {secs:02d}s"
    hours, mins = divmod(minutes, 60)
    return f"{hours}h {mins:02d}m {secs:02d}s"


def _build_unique_identifiers(sessions: list[dict]) -> dict[str, list[str]]:
    """Aggregate unique non-empty run_id / workflow_id strings.

    Used by the Summary section so a single-run aggregation shows the
    one id (``run_id: run_20260513...``) while a multi-run scan shows
    the set (``run_id: multi (run_A, run_B)``).
    """
    run_ids: set[str] = set()
    workflow_ids: set[str] = set()
    for session in sessions:
        rid = session.get("run_id")
        if isinstance(rid, str) and rid:
            run_ids.add(rid)
        wid = session.get("workflow_id")
        if isinstance(wid, str) and wid:
            workflow_ids.add(wid)
    return {
        "run_ids": sorted(run_ids),
        "workflow_ids": sorted(workflow_ids),
    }


def _build_decision_signals(
    sessions: list[dict], total_duration_seconds: int
) -> dict[str, Any]:
    """Compute the four operator-facing decision signals.

    1. top_2_steps_share_pct — wall-time share captured by the two
       longest steps. Answers "is the cost concentrated in 1-2 steps
       (good optimization target) or evenly spread (refactor unlikely
       to help)?"
    2. ai_implementation_share_pct — share consumed by AI sessions
       whose capability contains ``implementation`` (covers
       ``backend_implementation`` / ``frontend_implementation``).
       Answers "is most of the budget actually code-emit vs
       planning / audit / ticket scaffolding?"
    3. failed_longest_step — the longest step whose lifecycle=failed.
       Answers "what failure cost the most before we noticed?"
    4. largest_prompt_step — session with the biggest prompt size in
       bytes. Answers "where does the prompt context bloat live?"

    Returns a dict with the four signals; nested step objects are
    ``None`` when no qualifying session exists.
    """
    enriched: list[dict[str, Any]] = []
    for session in sessions:
        usage = session.get("usage") if isinstance(session.get("usage"), dict) else None
        prompt_bytes: int | None = None
        if usage and isinstance(usage.get("prompt_size_bytes"), int):
            prompt_bytes = usage["prompt_size_bytes"]
        elif isinstance(session.get("prompt_size_bytes"), int):
            prompt_bytes = session["prompt_size_bytes"]
        enriched.append({
            "step_id": session.get("step_id") or "",
            "capability": session.get("capability") or "",
            "executor": session.get("executor") or "",
            "lifecycle": session.get("lifecycle") or "",
            "duration_seconds": _safe_int(session.get("duration_seconds")),
            "prompt_size_bytes": prompt_bytes,
        })

    by_duration = sorted(
        enriched, key=lambda e: e["duration_seconds"], reverse=True
    )

    top_2 = by_duration[:2]
    top_2_duration = sum(e["duration_seconds"] for e in top_2)
    top_2_share = (
        (top_2_duration / total_duration_seconds * 100)
        if total_duration_seconds > 0
        else 0.0
    )

    impl_duration = sum(
        e["duration_seconds"]
        for e in enriched
        if e["executor"] == "ai" and "implementation" in e["capability"]
    )
    ai_impl_share = (
        (impl_duration / total_duration_seconds * 100)
        if total_duration_seconds > 0
        else 0.0
    )

    failed_longest = next(
        (e for e in by_duration if e["lifecycle"] == "failed"), None
    )

    sized = [e for e in by_duration if isinstance(e["prompt_size_bytes"], int)]
    largest_prompt = (
        max(sized, key=lambda e: e["prompt_size_bytes"]) if sized else None
    )

    def _project_step(entry: dict[str, Any] | None) -> dict[str, Any] | None:
        if entry is None:
            return None
        return {
            "step_id": entry["step_id"],
            "capability": entry["capability"],
            "duration_seconds": entry["duration_seconds"],
            "prompt_size_bytes": entry["prompt_size_bytes"],
            "lifecycle": entry["lifecycle"],
        }

    return {
        "top_2_steps_share_pct": round(top_2_share, 1),
        "top_2_steps": [_project_step(e) for e in top_2],
        "ai_implementation_share_pct": round(ai_impl_share, 1),
        "ai_implementation_duration_seconds": impl_duration,
        "failed_longest_step": _project_step(failed_longest),
        "largest_prompt_step": _project_step(largest_prompt),
    }


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

    Also collects unique ``usage.provider`` / ``usage.source`` strings
    so the rendered Usage Summary can show one provider/source line
    (single-provider run) or ``multi (a, b)`` (multi-provider run)
    without re-walking the session list at render time.
    """
    available = 0
    unavailable = 0
    total_prompt_bytes = 0
    total_output_bytes = 0
    total_tokens = 0
    saw_prompt_bytes = False
    saw_output_bytes = False
    saw_tokens = False
    providers: set[str] = set()
    token_sources: set[str] = set()

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

        if usage:
            prov = usage.get("provider") or session.get("provider_cli") or session.get("provider")
            if isinstance(prov, str) and prov:
                providers.add(prov)
            src = usage.get("source")
            if isinstance(src, str) and src:
                token_sources.add(src)

    return {
        "available_sessions": available,
        "unavailable_sessions": unavailable,
        "total_prompt_bytes": total_prompt_bytes if saw_prompt_bytes else None,
        "total_output_bytes": total_output_bytes if saw_output_bytes else None,
        "total_tokens": total_tokens if saw_tokens else None,
        "providers": sorted(providers),
        "token_sources": sorted(token_sources),
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
        # P0b-2 readability keys (additive). Summary header pulls
        # run/workflow identity; decision_signals answers four
        # operator questions (cost concentration, AI-implementation
        # share, failure cost, prompt bloat) without re-walking the
        # ledger.
        "unique_run_ids": _build_unique_identifiers(sessions)["run_ids"],
        "unique_workflow_ids": _build_unique_identifiers(sessions)["workflow_ids"],
        "decision_signals": _build_decision_signals(sessions, total_duration),
    }


def render_text(report: dict, *, top_n: int = 5, verbose: bool = False) -> str:
    """Human-readable text rendering.

    Default output is a sparse three-section view designed for at-a-
    glance cost triage:

      1. **Summary** — run/workflow identity + provider + humanized
         duration + sessions count + token availability. The first
         thing the operator sees when they run ``cap session analyze
         --run-id <id>``.
      2. **Hotspots** — top N steps by wall time with percentage
         share, per-step prompt/output bytes, and an ``[FAILED]``
         marker so expensive failures jump out.
      3. **Decision Signals** — four numbers that drive the next
         optimization decision (top-2 share, AI implementation
         share, failed longest step, largest prompt step).

    Pass ``verbose=True`` to also render the previously-default
    detailed tables (lifecycle / by_provider / by_capability /
    Largest Prompt Snapshots / duplicate_prompts / longest_sessions /
    failures / Usage Summary / tokens_unavailable_reasons / Top
    Steps By X / Top Capabilities By Prompt Bytes). The JSON
    envelope is unchanged regardless of this flag — machine consumers
    keep the full data.
    """
    lines: list[str] = []

    def _fmt_bytes(value: Any) -> str:
        return f"{value}B" if isinstance(value, int) else "null"

    def _fmt_int(value: Any) -> str:
        return str(value) if isinstance(value, int) else "null"

    def _fmt_set(values: list[str]) -> str:
        if not values:
            return "unknown"
        if len(values) == 1:
            return values[0]
        return "multi (" + ", ".join(values) + ")"

    total_sessions = report.get("total_sessions", 0)
    total_duration = report.get("total_duration_seconds", 0)
    usage_totals = report.get("usage_totals") or {}
    providers = usage_totals.get("providers") or []
    avail = usage_totals.get("available_sessions", 0)
    unavail = usage_totals.get("unavailable_sessions", 0)
    run_ids = report.get("unique_run_ids") or []
    workflow_ids = report.get("unique_workflow_ids") or []

    # ── Section 1: Summary ─────────────────────────────────────────────
    lines.append("Summary:")
    lines.append(f"  run_id: {_fmt_set(run_ids)}")
    lines.append(f"  workflow_id: {_fmt_set(workflow_ids)}")
    lines.append(f"  provider: {_fmt_set(providers)}")
    lines.append(
        f"  duration: {_humanize_duration(total_duration)} ({total_duration}s)"
    )
    lines.append(f"  sessions: {total_sessions}")
    total_telemetry = avail + unavail
    if total_telemetry == 0:
        tokens_state = "unavailable (no telemetry recorded)"
    elif avail == 0:
        tokens_state = f"unavailable ({avail}/{total_telemetry} sessions exposed token counts)"
    elif unavail == 0:
        tokens_state = f"available ({avail}/{total_telemetry} sessions)"
    else:
        tokens_state = f"partial ({avail}/{total_telemetry} sessions exposed token counts)"
    lines.append(f"  tokens: {tokens_state}")

    # ── Section 2: Hotspots ────────────────────────────────────────────
    longest = report.get("longest_sessions") or []
    if longest:
        lines.append("")
        lines.append(f"Hotspots (top {top_n} by duration):")
        hotspot_payload = report.get("cost_hotspot") or {}
        by_step_lookup: dict[str, dict[str, Any]] = {}
        for step_entry in hotspot_payload.get("by_step") or []:
            sid_key = step_entry.get("step_id")
            if isinstance(sid_key, str) and sid_key:
                by_step_lookup[sid_key] = step_entry
        for idx, entry in enumerate(longest[:top_n], start=1):
            dur = entry.get("duration_seconds") or 0
            pct = (dur / total_duration * 100) if total_duration > 0 else 0.0
            sid = entry.get("step_id") or entry.get("session_id") or "-"
            cap = entry.get("capability") or "-"
            lifecycle = entry.get("lifecycle") or ""
            marker = "  [FAILED]" if lifecycle == "failed" else ""
            step_metrics = by_step_lookup.get(sid) if isinstance(sid, str) else None
            byte_part = ""
            if step_metrics:
                pb = step_metrics.get("prompt_size_bytes")
                ob = step_metrics.get("output_size_bytes")
                if isinstance(pb, int) or isinstance(ob, int):
                    byte_part = (
                        f"  prompt={_fmt_bytes(pb)} out={_fmt_bytes(ob)}"
                    )
            lines.append(
                f"  {idx}. {sid:<24} "
                f"{_humanize_duration(dur):>11} "
                f"({pct:>5.1f}%)  "
                f"cap={cap}{byte_part}{marker}"
            )

    # ── Section 3: Decision Signals ────────────────────────────────────
    signals = report.get("decision_signals") or {}
    if signals:
        lines.append("")
        lines.append("Decision Signals:")
        top2 = signals.get("top_2_steps") or []
        top2_share = signals.get("top_2_steps_share_pct", 0)
        if top2 and all(e for e in top2):
            top2_detail = " + ".join(
                f"{e['step_id']} {_humanize_duration(e['duration_seconds'])}"
                for e in top2
            )
            lines.append(f"  top 2 steps share: {top2_share}% ({top2_detail})")
        else:
            lines.append(f"  top 2 steps share: {top2_share}% (no qualifying steps)")
        impl_share = signals.get("ai_implementation_share_pct", 0)
        impl_dur = signals.get("ai_implementation_duration_seconds", 0)
        lines.append(
            f"  AI implementation share: {impl_share}% "
            f"({_humanize_duration(impl_dur)} of {_humanize_duration(total_duration)})"
        )
        fls = signals.get("failed_longest_step")
        if fls:
            lines.append(
                f"  failed longest step: {fls['step_id']} "
                f"({_humanize_duration(fls['duration_seconds'])}, cap={fls['capability']})"
            )
        else:
            lines.append("  failed longest step: (none)")
        lps = signals.get("largest_prompt_step")
        if lps and isinstance(lps.get("prompt_size_bytes"), int):
            lines.append(
                f"  largest prompt step: {lps['step_id']} "
                f"({lps['prompt_size_bytes']}B, cap={lps['capability']})"
            )
        else:
            lines.append("  largest prompt step: (none recorded)")

    if not verbose:
        lines.append("")
        lines.append(
            "(re-run with --verbose for full lifecycle / by_provider / "
            "by_capability / hotspot tables)"
        )
        return "\n".join(lines)

    # ── Verbose tables (previously the default) ────────────────────────
    lines.append("")
    lines.append("──── Detailed Tables (--verbose) ────")
    lines.append("")
    lines.append(f"total_sessions: {total_sessions}")
    lines.append(f"total_duration_seconds: {total_duration}")

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
    lines.append(f"Largest Prompt Snapshots (top {top_n} by size):")
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

    if usage_totals:
        token_sources = usage_totals.get("token_sources") or []
        total_tokens = usage_totals.get("total_tokens")
        token_display = (
            str(total_tokens) if isinstance(total_tokens, int) else "unavailable"
        )
        lines.append("")
        lines.append("Usage Summary:")
        lines.append(f"  provider: {_fmt_set(providers)}")
        lines.append(f"  token_source: {_fmt_set(token_sources)}")
        lines.append(
            f"  provider_token_telemetry_available: {avail}/{avail + unavail}"
        )
        lines.append(f"  total_duration_seconds: {total_duration}")
        lines.append(
            f"  total_prompt_bytes: {_fmt_bytes(usage_totals.get('total_prompt_bytes'))}"
        )
        lines.append(
            f"  total_output_bytes: {_fmt_bytes(usage_totals.get('total_output_bytes'))}"
        )
        lines.append(f"  tokens: {token_display}")

    unavailable_reasons = report.get("unavailable_reasons") or []
    if unavailable_reasons:
        lines.append("")
        lines.append("tokens_unavailable_reasons:")
        for entry in unavailable_reasons:
            lines.append(f"  {entry['count']}x  {entry['reason']}")

    hotspot = report.get("cost_hotspot") or {}
    by_step = hotspot.get("by_step") or []
    if by_step:
        lines.append("")
        lines.append(f"Top Steps By Prompt Bytes (top {top_n}):")
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
            lines.append(f"Top Steps By Output Bytes (top {top_n}):")
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

        by_duration_full = sorted(
            by_step,
            key=lambda s: (
                s["duration_seconds"]
                if isinstance(s.get("duration_seconds"), int)
                else -1
            ),
            reverse=True,
        )
        if any(isinstance(s.get("duration_seconds"), int) for s in by_duration_full):
            lines.append("")
            lines.append(f"Top Steps By Duration (top {top_n}):")
            for entry in by_duration_full[:top_n]:
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
        lines.append(f"Top Capabilities By Prompt Bytes (top {top_n}):")
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
        "--verbose",
        "-v",
        action="store_true",
        help=(
            "Render the full detailed tables (lifecycle / by_provider / "
            "by_capability / hotspot / Largest Prompt Snapshots / etc.) "
            "after the sparse Summary + Hotspots + Decision Signals view. "
            "Default output stays sparse for at-a-glance triage."
        ),
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
        print(render_text(report, top_n=args.top, verbose=args.verbose))
    return 0


if __name__ == "__main__":
    sys.exit(main())
