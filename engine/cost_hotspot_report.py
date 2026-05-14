"""Per-run cost hotspot aggregator over agent-sessions usage telemetry.

Pure read-only library. Consumes the projected sessions list
(post ``result_report_builder._project_sessions``) and emits a
structured hotspot view that answers the three operator questions
documented in ``docs/cap/COST-OPTIMIZATION-MEMO.md``:

  * Which step carries the heaviest context?
    -> ``by_step[]`` ranked by ``prompt_size_bytes`` desc
  * Which capability class is most expensive overall?
    -> ``by_capability[]`` aggregated across sessions
  * Which prompts repeat within this run? (context bloat)
    -> ``duplicate_prompts[]`` using ``prompt_hash`` collisions

Schema slot: ``schemas/workflow-result.schema.yaml:usage_hotspot``
(optional; adding the field does not bump ``schema_version`` per the
schema header's forward-compatibility rule).

Surfaced in two places:

  * ``workflow-result.json:usage_hotspot`` (machine-readable).
  * ``result.md`` ``## Cost Hotspot`` section
    (rendered by ``result_report_builder.render_result_md``).

Never raises on missing / null usage fields; sessions with no usage
data still appear in ``by_step`` with null metric values so per-run
provenance stays complete.
"""

from __future__ import annotations

from collections import defaultdict
from typing import Any

_LARGEST_PROMPTS_LIMIT = 5
_DUPLICATE_OCCURRENCE_THRESHOLD = 2


def _coerce_int(value: Any) -> int | None:
    """Return ``value`` if it is an int (and not a bool), else None."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    return None


def _session_usage_metric(session: dict[str, Any], field: str) -> int | None:
    """Pull a numeric field off ``session["usage"]`` returning None when
    the usage object is missing, malformed, or the field is not an int."""
    usage = session.get("usage")
    if not isinstance(usage, dict):
        return None
    return _coerce_int(usage.get(field))


def build_cost_hotspot(sessions: list[dict[str, Any]]) -> dict[str, Any]:
    """Aggregate per-run cost hotspot view over projected sessions.

    Args:
        sessions: The projected sessions list (post _project_sessions).
            Each entry may carry an optional ``usage`` dict (see
            ``schemas/agent-session.schema.yaml:usage``), optional
            ``prompt_hash`` / ``prompt_size_bytes`` first-class fields,
            and ``duration_seconds``.

    Returns:
        Dict with four keys: ``by_step`` / ``by_capability`` /
        ``duplicate_prompts`` / ``largest_prompts``. All return empty
        lists when input has no usage data; the dict shape itself is
        always present so downstream consumers can rely on it.
    """
    by_step: list[dict[str, Any]] = []
    capability_agg: defaultdict[str, dict[str, Any]] = defaultdict(
        lambda: {
            "sessions": 0,
            "duration_seconds": 0,
            "prompt_size_bytes": 0,
            "output_size_bytes": 0,
            "total_tokens": 0,
            "_saw_duration": False,
            "_saw_prompt": False,
            "_saw_output": False,
            "_saw_tokens": False,
        }
    )
    hash_groups: defaultdict[str, list[dict[str, Any]]] = defaultdict(list)

    for session in sessions:
        if not isinstance(session, dict):
            continue
        step_id = session.get("step_id") or ""
        capability = session.get("capability") or ""
        duration_seconds = _coerce_int(session.get("duration_seconds"))
        prompt_bytes = _session_usage_metric(session, "prompt_size_bytes")
        output_bytes = _session_usage_metric(session, "output_size_bytes")
        total_tokens = _session_usage_metric(session, "total_tokens")

        by_step.append({
            "step_id": step_id,
            "capability": capability,
            "duration_seconds": duration_seconds,
            "prompt_size_bytes": prompt_bytes,
            "output_size_bytes": output_bytes,
            "total_tokens": total_tokens,
        })

        cap_entry = capability_agg[capability]
        cap_entry["sessions"] += 1
        if duration_seconds is not None:
            cap_entry["duration_seconds"] += duration_seconds
            cap_entry["_saw_duration"] = True
        if prompt_bytes is not None:
            cap_entry["prompt_size_bytes"] += prompt_bytes
            cap_entry["_saw_prompt"] = True
        if output_bytes is not None:
            cap_entry["output_size_bytes"] += output_bytes
            cap_entry["_saw_output"] = True
        if total_tokens is not None:
            cap_entry["total_tokens"] += total_tokens
            cap_entry["_saw_tokens"] = True

        prompt_hash = session.get("prompt_hash")
        if isinstance(prompt_hash, str) and prompt_hash:
            hash_groups[prompt_hash].append({
                "step_id": step_id,
                "prompt_size_bytes": prompt_bytes,
            })

    # by_step: descending by prompt_size_bytes (None ranks last via -1 key).
    by_step.sort(
        key=lambda s: (
            s["prompt_size_bytes"] if isinstance(s["prompt_size_bytes"], int) else -1
        ),
        reverse=True,
    )

    by_capability: list[dict[str, Any]] = []
    for capability, agg in capability_agg.items():
        by_capability.append({
            "capability": capability,
            "sessions": agg["sessions"],
            "duration_seconds": agg["duration_seconds"] if agg["_saw_duration"] else None,
            "prompt_size_bytes": agg["prompt_size_bytes"] if agg["_saw_prompt"] else None,
            "output_size_bytes": agg["output_size_bytes"] if agg["_saw_output"] else None,
            "total_tokens": agg["total_tokens"] if agg["_saw_tokens"] else None,
        })
    by_capability.sort(
        key=lambda c: (
            c["prompt_size_bytes"] if isinstance(c["prompt_size_bytes"], int) else -1
        ),
        reverse=True,
    )

    duplicate_prompts: list[dict[str, Any]] = []
    for prompt_hash, entries in hash_groups.items():
        if len(entries) >= _DUPLICATE_OCCURRENCE_THRESHOLD:
            sample_size = next(
                (
                    entry["prompt_size_bytes"]
                    for entry in entries
                    if isinstance(entry.get("prompt_size_bytes"), int)
                ),
                None,
            )
            duplicate_prompts.append({
                "prompt_hash": prompt_hash,
                "occurrences": len(entries),
                "step_ids": [entry["step_id"] for entry in entries],
                "prompt_size_bytes": sample_size,
            })
    duplicate_prompts.sort(key=lambda d: d["occurrences"], reverse=True)

    largest_prompts: list[dict[str, Any]] = sorted(
        (
            {
                "step_id": s["step_id"],
                "capability": s["capability"],
                "prompt_size_bytes": s["prompt_size_bytes"],
            }
            for s in by_step
            if isinstance(s["prompt_size_bytes"], int)
        ),
        key=lambda s: s["prompt_size_bytes"],
        reverse=True,
    )[:_LARGEST_PROMPTS_LIMIT]

    return {
        "by_step": by_step,
        "by_capability": by_capability,
        "duplicate_prompts": duplicate_prompts,
        "largest_prompts": largest_prompts,
    }
