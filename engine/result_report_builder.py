"""P7 Phase A — read-only workflow result aggregator.

Builds the workflow-result dict defined by ``schemas/workflow-result.schema.yaml``
from the on-disk SSOT files of one ``cap workflow run``. Pure read-only:
the builder NEVER writes, NEVER mutates ``runtime-state.json`` or
``agent-sessions.json``, and NEVER calls a network or AI provider.

Phase A scope (deliberate):
  * Library function only — no CLI subcommand and no
    ``scripts/cap-workflow-exec.sh`` wiring.
  * ``promote_candidates`` is always ``[]`` (P10 owns the producer).
  * Missing optional sources (``workflow.log`` /
    ``route-history.jsonl`` / ``handoffs/<step>.ticket.json`` /
    ``status_file``) degrade gracefully — never raise.

Sources consumed (per docs/cap recon, rc12 baseline):
  * ``<run_dir>/runtime-state.json``        — required (steps + artifacts)
  * ``<run_dir>/agent-sessions.json``       — required (sessions ledger)
  * ``<run_dir>/run-summary.md``            — required (header + Steps + Finished)
  * ``<run_dir>/workflow.log``              — optional (logs pointer + line count)
  * ``<run_dir>/route-history.jsonl``       — optional (P6 #8, only when route_back fired)
  * ``<cap_home>/projects/<id>/handoffs/<step>.ticket.json``
                                            — optional (failure route_back_to_step)
  * ``status_file``                         — optional (workflow-runs.json;
                                              best-effort future-compatible
                                              ``task_id`` linkage — see
                                              :func:`build_workflow_result`
                                              docstring; the current
                                              producer does not write
                                              per-run ``task_id``, so this
                                              lookup normally yields
                                              ``None`` today)
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Optional

SCHEMA_VERSION = 1

_FINAL_STATE_VALUES = {"running", "completed", "failed", "cancelled", "blocked"}
_STATUS_VALUES = {"ok", "failed", "skipped", "blocked", "running"}


def build_workflow_result(
    run_dir: Path | str,
    *,
    cap_home: Optional[Path | str] = None,
    status_file: Optional[Path | str] = None,
) -> dict[str, Any]:
    """Aggregate run_dir SSOT into a workflow-result dict.

    Args:
        run_dir: Absolute or relative path to the run directory under
            ``~/.cap/projects/<id>/reports/workflows/<workflow_id>/<run_id>/``.
            Required; raises ``FileNotFoundError`` if the directory does
            not exist.
        cap_home: Optional override for ``$CAP_HOME``. Used to locate
            the ``handoffs/`` directory for the resolved project. When
            ``None`` the handoff-ticket cross-reference is skipped and
            ``failures[*].route_back_to`` falls back to ``None``.
        status_file: Optional path to ``workflow-runs.json`` (typically
            ``<cap_home>/projects/<id>/workflow-runs.json``).
            Best-effort future-compatible linkage: the current
            ``step_runtime.update_status`` producer does NOT write
            per-run ``task_id`` into ``runs[]`` (it only maintains the
            workflow-level ``workflows{}`` map), so this lookup
            normally yields ``None`` today. The hook stays wired so a
            future producer (e.g. a task lifecycle / envelope persist
            step that starts writing ``runs[*].task_id``) is picked up
            without builder changes. ``None`` (no argument, file
            missing, no matching ``run_id``, or absent ``task_id``)
            all yield ``task_id=None``.

    Returns:
        A dict that conforms to ``schemas/workflow-result.schema.yaml``
        (callers are responsible for invoking validation).
    """
    run_dir_path = Path(run_dir).expanduser().resolve()
    if not run_dir_path.is_dir():
        raise FileNotFoundError(f"run_dir does not exist: {run_dir_path}")

    runtime_state = _load_json(run_dir_path / "runtime-state.json", default={})
    agent_sessions = _load_json(run_dir_path / "agent-sessions.json", default={})
    summary_meta = _parse_run_summary(run_dir_path / "run-summary.md")

    run_id = (
        summary_meta.get("run_id")
        or _safe_str(agent_sessions.get("run_id"))
        or run_dir_path.name
    )
    workflow_id = (
        summary_meta.get("workflow_id")
        or _safe_str(agent_sessions.get("workflow_id"))
        or _safe_parent_name(run_dir_path, depth=1)
        or "unknown"
    )
    workflow_name = (
        summary_meta.get("workflow_name")
        or _safe_str(agent_sessions.get("workflow_name"))
    )
    project_id = _resolve_project_id(run_dir_path)

    started_at = summary_meta.get("started_at") or ""
    finished_at = summary_meta.get("finished_at") or None
    total_duration = _parse_int(summary_meta.get("total_duration_seconds"))

    steps = _build_steps(runtime_state, summary_meta)
    summary = _compute_summary(steps, summary_meta)

    finished = bool(finished_at) or bool(summary_meta.get("_finished_section"))
    final_state = _derive_final_state(summary, finished)
    final_result = _derive_final_result(final_state, summary)

    sessions = _project_sessions(agent_sessions.get("sessions", []))
    artifacts = _flatten_artifacts(runtime_state.get("artifacts", {}))

    handoff_tickets = _load_handoff_tickets(cap_home, project_id)
    failures = _build_failures(steps, sessions, handoff_tickets)

    promote_candidates: list[dict[str, Any]] = []  # v1: always empty (P10 owns producer).
    logs = _build_logs(run_dir_path)
    task_id = _resolve_task_id(status_file, run_id)

    result: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "run_id": run_id,
        "workflow_id": workflow_id,
        "project_id": project_id,
        "started_at": started_at,
        "final_state": final_state,
        "summary": summary,
        "steps": steps,
        "sessions": sessions,
        "artifacts": artifacts,
    }
    if workflow_name:
        result["workflow_name"] = workflow_name
    result["task_id"] = task_id
    result["finished_at"] = finished_at
    result["total_duration_seconds"] = total_duration
    result["final_result"] = final_result
    result["failures"] = failures
    result["promote_candidates"] = promote_candidates
    result["logs"] = logs
    return result


def render_result_md(result: dict[str, Any]) -> str:
    """Render a workflow-result dict (matching workflow-result schema) as
    a human-readable Markdown projection.

    Mirrors the same top-level ``# Workflow Result`` heading the legacy
    hardcoded ``result.md`` template used (so any reader that grep'd
    ``- workflow_id:`` / ``- run_id:`` / ``- final_state:`` keeps
    working) and adds ``## Summary`` / ``## Steps`` / ``## Artifacts``
    / ``## Failures`` / ``## Logs`` sections that surface the new
    builder output. Does not write to disk; pure function.
    """
    lines: list[str] = []
    lines.append("# Workflow Result")
    lines.append("")
    lines.append(f"- workflow_id: {result.get('workflow_id', '')}")
    if result.get("workflow_name"):
        lines.append(f"- workflow_name: {result['workflow_name']}")
    lines.append(f"- run_id: {result.get('run_id', '')}")
    lines.append(f"- project_id: {result.get('project_id', '')}")
    if result.get("task_id"):
        lines.append(f"- task_id: {result['task_id']}")
    lines.append(f"- started_at: {result.get('started_at', '')}")
    finished_at = result.get("finished_at")
    lines.append(f"- finished_at: {finished_at if finished_at else 'null'}")
    lines.append(f"- final_state: {result.get('final_state', '')}")
    fr = result.get("final_result")
    lines.append(f"- final_result: {fr if fr else 'null'}")
    td = result.get("total_duration_seconds")
    lines.append(f"- total_duration_seconds: {td if td is not None else 'null'}")

    summary = result.get("summary", {}) or {}
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append(f"- total_steps: {summary.get('total_steps', 0)}")
    lines.append(f"- completed: {summary.get('completed', 0)}")
    lines.append(f"- failed: {summary.get('failed', 0)}")
    lines.append(f"- skipped: {summary.get('skipped', 0)}")
    lines.append(f"- blocked: {summary.get('blocked', 0)}")

    steps = result.get("steps") or []
    lines.append("")
    lines.append("## Steps")
    lines.append("")
    if not steps:
        lines.append("_(none)_")
    else:
        for step in steps:
            sid = step.get("step_id", "")
            status = step.get("status", "")
            phase = step.get("phase", "")
            cap = step.get("capability", "")
            dur = step.get("duration_seconds")
            dur_str = f"{dur}s" if dur is not None else "n/a"
            lines.append(
                f"- {sid} [{status}] (phase={phase}, capability={cap}, duration={dur_str})"
            )

    artifacts = result.get("artifacts") or []
    lines.append("")
    lines.append("## Artifacts")
    lines.append("")
    if not artifacts:
        lines.append("_(none)_")
    else:
        for art in artifacts:
            lines.append(f"- {art.get('name', '')}: {art.get('path', '')}")

    failures = result.get("failures") or []
    if failures:
        lines.append("")
        lines.append("## Failures")
        lines.append("")
        for failure in failures:
            sid = failure.get("step_id", "")
            reason = failure.get("reason", "")
            detail = failure.get("detail")
            rb = failure.get("route_back_to")
            lines.append(f"- step_id: {sid}")
            lines.append(f"  - reason: {reason}")
            if detail:
                lines.append(f"  - detail: {detail}")
            lines.append(f"  - route_back_to: {rb if rb else 'null'}")

    logs = result.get("logs") or {}
    if isinstance(logs, dict) and logs:
        lines.append("")
        lines.append("## Logs")
        lines.append("")
        if logs.get("workflow_log"):
            lines.append(f"- workflow_log: {logs['workflow_log']}")
        wll = logs.get("workflow_log_lines")
        if wll is not None:
            lines.append(f"- workflow_log_lines: {wll}")

    lines.append("")
    lines.append("## Notes")
    lines.append("")
    lines.append(
        "Rendered from workflow-result.json by P7 result_report_builder."
    )
    lines.append("")
    return "\n".join(lines)


# ─────────────────────────────────────────────────────────────────────────
# Load helpers
# ─────────────────────────────────────────────────────────────────────────


def _load_json(path: Path, *, default: Any) -> Any:
    """Best-effort JSON load: missing file or parse error → ``default``."""
    if not path.is_file():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return default


def _parse_run_summary(path: Path) -> dict[str, Any]:
    """Parse ``run-summary.md`` line by line.

    Returns a flat dict of header / Finished-section fields plus a
    private ``_steps`` mapping ``step_id -> per-step dict``. Marks
    ``_finished_section: True`` when a ``## Finished`` header was seen
    so callers can treat the run as ended even without a
    ``finished_at`` value.
    """
    meta: dict[str, Any] = {"_steps": {}}
    if not path.is_file():
        return meta

    text = path.read_text(encoding="utf-8")
    current_step: Optional[str] = None
    in_steps = False
    in_finished = False

    for raw in text.splitlines():
        line = raw.rstrip()
        h2 = re.match(r"^##\s+(.+?)\s*$", line)
        if h2:
            section = h2.group(1).strip()
            in_steps = section.lower() == "steps"
            in_finished = section.lower() == "finished"
            current_step = None
            if in_finished:
                meta["_finished_section"] = True
            continue
        h3 = re.match(r"^###\s+(\S+)\s*$", line)
        if h3 and in_steps:
            current_step = h3.group(1)
            meta["_steps"].setdefault(current_step, {})
            continue
        kv = re.match(r"^-\s+([A-Za-z_]+):\s*(.*)$", line)
        if kv:
            key, value = kv.group(1), kv.group(2).strip()
            target = (
                meta["_steps"][current_step]
                if (in_steps and current_step is not None)
                else meta
            )
            target[key] = value
    return meta


# ─────────────────────────────────────────────────────────────────────────
# Steps + summary + final_state derivation
# ─────────────────────────────────────────────────────────────────────────


def _build_steps(
    runtime_state: dict[str, Any],
    summary_meta: dict[str, Any],
) -> list[dict[str, Any]]:
    rs_steps = runtime_state.get("steps", {}) or {}
    rsum_steps = summary_meta.get("_steps", {}) or {}

    ordered_keys: list[str] = list(rs_steps.keys())
    for step_id in rsum_steps.keys():
        if step_id not in ordered_keys:
            ordered_keys.append(step_id)

    out: list[dict[str, Any]] = []
    for step_id in ordered_keys:
        rs_entry = rs_steps.get(step_id, {}) or {}
        rsum_entry = rsum_steps.get(step_id, {}) or {}

        execution_state = _safe_str(rs_entry.get("execution_state")) or None
        rsum_status = _safe_str(rsum_entry.get("status"))
        status = _normalize_status(execution_state, rsum_status)

        out.append(
            {
                "step_id": step_id,
                "phase": _coerce_phase(
                    rs_entry.get("phase") or rsum_entry.get("phase") or "0"
                ),
                "capability": _safe_str(
                    rs_entry.get("capability") or rsum_entry.get("capability") or ""
                ),
                "status": status,
                "execution_state": execution_state,
                "duration_seconds": _parse_int(rsum_entry.get("duration_seconds")),
                "output_path": _safe_str(
                    rs_entry.get("output_path") or rsum_entry.get("output")
                )
                or None,
                "handoff_path": _safe_str(
                    rs_entry.get("handoff_path") or rsum_entry.get("handoff")
                )
                or None,
                "output_source": _safe_str(
                    rs_entry.get("output_source") or rsum_entry.get("output_source")
                )
                or None,
                "input_mode": _safe_str(rsum_entry.get("input_mode")) or None,
                "output_tier": _safe_str(rsum_entry.get("output_tier")) or None,
                "blocked_reason": _safe_str(rs_entry.get("blocked_reason")) or None,
                "failure": None,  # populated below by _build_failures.
            }
        )
    return out


def _normalize_status(
    execution_state: Optional[str], rsum_status: Optional[str]
) -> str:
    """Map raw signals to the schema's ``steps[*].status`` enum.

    Run-summary ``status: ok`` is the strongest positive signal (cap
    workflow exec writes it on a successful step). Otherwise execution
    state keywords (``validated`` / ``completed`` / ``fail`` /
    ``block`` / ``skip`` / ``running``) drive the mapping. When both
    are empty the step is considered ``running`` (in flight).
    """
    rsum = (rsum_status or "").lower()
    es = (execution_state or "").lower()
    if rsum == "ok" or es in {"validated", "completed"}:
        return "ok"
    if "fail" in es or rsum == "failed":
        return "failed"
    if "block" in es or rsum == "blocked":
        return "blocked"
    if "skip" in es or rsum == "skipped":
        return "skipped"
    if rsum == "running" or es == "running":
        return "running"
    if rsum in _STATUS_VALUES:
        return rsum
    return "running"


def _compute_summary(
    steps: list[dict[str, Any]], summary_meta: dict[str, Any]
) -> dict[str, int]:
    """Prefer Finished-section counts; otherwise tally from steps[]."""
    completed = _parse_int(summary_meta.get("completed"))
    failed = _parse_int(summary_meta.get("failed"))
    skipped = _parse_int(summary_meta.get("skipped"))
    if completed is not None and failed is not None and skipped is not None:
        blocked = sum(1 for s in steps if s["status"] == "blocked")
        total_from_steps = len(steps)
        total_from_counts = completed + failed + skipped + blocked
        total_steps = total_from_steps if total_from_steps else total_from_counts
        return {
            "total_steps": total_steps,
            "completed": completed,
            "failed": failed,
            "skipped": skipped,
            "blocked": blocked,
        }

    counts = {
        "total_steps": len(steps),
        "completed": 0,
        "failed": 0,
        "skipped": 0,
        "blocked": 0,
    }
    for step in steps:
        bucket = {
            "ok": "completed",
            "failed": "failed",
            "skipped": "skipped",
            "blocked": "blocked",
        }.get(step["status"])
        if bucket:
            counts[bucket] += 1
    return counts


def _derive_final_state(summary: dict[str, int], finished: bool) -> str:
    """Map summary + finished flag to the ``final_state`` enum.

    Precedence: not-finished → ``running``; any failed → ``failed``;
    any blocked → ``blocked``; otherwise ``completed``. ``cancelled``
    is a state only an external observer (Ctrl-C / SIGTERM /
    ``cap workflow cancel``) can stamp; this builder cannot infer it
    from on-disk SSOT alone, so it is never produced here.
    """
    if not finished:
        return "running"
    if summary.get("failed", 0) > 0:
        return "failed"
    if summary.get("blocked", 0) > 0:
        return "blocked"
    return "completed"


def _derive_final_result(final_state: str, summary: dict[str, int]) -> Optional[str]:
    """Schema description: ``final_result`` is set ONLY when
    ``final_state == "completed"``; null otherwise.

    When completed: any skipped → ``partial``; otherwise ``success``.
    The ``failed`` final_result branch is unreachable through
    :func:`_derive_final_state` (which routes failed runs to
    ``final_state="failed"``), but is kept enum-compatible so a
    future upstream consumer that distinguishes "soft-fail completed"
    can populate it without touching this builder.
    """
    if final_state != "completed":
        return None
    if summary.get("failed", 0) > 0:
        return "failed"
    if summary.get("skipped", 0) > 0:
        return "partial"
    return "success"


# ─────────────────────────────────────────────────────────────────────────
# Sessions / artifacts / failures projections
# ─────────────────────────────────────────────────────────────────────────


def _project_sessions(raw: list[Any]) -> list[dict[str, Any]]:
    """Project agent-sessions ledger entries to the schema's
    ``sessions[*]`` shape.

    Required fields fall back to safe defaults (``role="shell"`` /
    ``executor="shell"`` / ``lifecycle="completed"``) when the source
    entry is incomplete. Optional fields are passed through only when
    present so the projection stays close to the source ledger.
    """
    out: list[dict[str, Any]] = []
    for item in raw or []:
        if not isinstance(item, dict):
            continue
        entry = {
            "session_id": _safe_str(item.get("session_id")),
            "step_id": _safe_str(item.get("step_id")),
            "role": _safe_str(item.get("role")) or "shell",
            "capability": _safe_str(item.get("capability")),
            "executor": _safe_str(item.get("executor")) or "shell",
            "lifecycle": _safe_str(item.get("lifecycle")) or "completed",
        }
        for key in ("provider", "provider_cli", "result", "duration_seconds", "failure_reason"):
            if key in item:
                entry[key] = item[key]
        out.append(entry)
    return out


def _flatten_artifacts(artifacts_dict: Any) -> list[dict[str, Any]]:
    """Flatten ``runtime-state.artifacts`` (``{name -> {...}}``) into
    schema-shaped list entries. Missing fields fall back to empty
    string for ``path`` and ``None`` for optional pointers; the schema
    only requires ``name`` and ``path``."""
    out: list[dict[str, Any]] = []
    if not isinstance(artifacts_dict, dict):
        return out
    for name, info in artifacts_dict.items():
        if not isinstance(info, dict):
            continue
        out.append(
            {
                "name": _safe_str(info.get("artifact")) or _safe_str(name),
                "path": _safe_str(info.get("path")) or "",
                "producer_step_id": _safe_str(info.get("source_step")) or None,
                "promoted": False,
            }
        )
    return out


def _load_handoff_tickets(
    cap_home: Optional[Path | str], project_id: str
) -> dict[str, dict[str, Any]]:
    """Index handoff tickets by ``step_id`` for failure cross-reference.

    Returns ``{}`` when ``cap_home`` is ``None``, the project handoffs
    directory does not exist, or any ticket fails to parse. Sequence
    suffixes (``<step>-<seq>.ticket.json``) override the bare
    ``<step>.ticket.json`` because the highest-seq ticket is the most
    recent dispatch attempt.
    """
    if not cap_home or not project_id:
        return {}
    handoffs_dir = Path(cap_home).expanduser() / "projects" / project_id / "handoffs"
    if not handoffs_dir.is_dir():
        return {}

    out: dict[str, dict[str, Any]] = {}
    for ticket_path in sorted(handoffs_dir.glob("*.ticket.json")):
        try:
            data = json.loads(ticket_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue
        if not isinstance(data, dict):
            continue
        step_id = data.get("step_id")
        if isinstance(step_id, str) and step_id:
            out[step_id] = data
    return out


def _build_failures(
    steps: list[dict[str, Any]],
    sessions: list[dict[str, Any]],
    handoff_tickets: dict[str, dict[str, Any]],
) -> list[dict[str, Any]]:
    """Build ``failures[]`` for every step with status in
    {``failed``, ``blocked``}. Reason / detail come from the matching
    session's ``failure_reason`` (compact ``reason=X;detail=Y`` form
    is split when present); ``route_back_to`` comes from the ticket's
    ``failure_routing.route_back_to_step``. Inline ``step.failure``
    is also populated for in-line view consumers."""
    session_by_step: dict[str, dict[str, Any]] = {}
    for session in sessions:
        sid = session.get("step_id")
        if not (isinstance(sid, str) and sid):
            continue
        # Prefer a failed lifecycle entry over a non-failed one for the same step.
        existing = session_by_step.get(sid)
        if existing is None or session.get("lifecycle") == "failed":
            session_by_step[sid] = session

    out: list[dict[str, Any]] = []
    for step in steps:
        if step["status"] not in {"failed", "blocked"}:
            continue
        step_id = step["step_id"]
        session = session_by_step.get(step_id, {})
        ticket = handoff_tickets.get(step_id, {})
        route_back = None
        if isinstance(ticket, dict):
            routing = ticket.get("failure_routing")
            if isinstance(routing, dict):
                rb = routing.get("route_back_to_step")
                if isinstance(rb, str) and rb:
                    route_back = rb

        raw_reason = (
            _safe_str(session.get("failure_reason"))
            or _safe_str(step.get("blocked_reason"))
            or "step failed"
        )
        reason, detail = _split_reason_detail(raw_reason)

        failure_entry = {
            "step_id": step_id,
            "reason": reason,
            "detail": detail,
            "route_back_to": route_back,
        }
        out.append(failure_entry)
        step["failure"] = {
            "reason": reason,
            "detail": detail,
            "route_back_to": route_back,
        }
    return out


def _split_reason_detail(raw: str) -> tuple[str, Optional[str]]:
    """Split the rc9 compact ``reason=X;detail=Y`` failure-reason form
    into (reason, detail). When the form is absent, the whole string
    becomes the reason and detail falls back to ``None``."""
    if not raw:
        return ("step failed", None)
    if "reason=" in raw:
        m_reason = re.search(r"reason=([^;]+)", raw)
        m_detail = re.search(r"detail=(.+)", raw)
        reason = m_reason.group(1).strip() if m_reason else raw
        detail = m_detail.group(1).strip() if m_detail else None
        return (reason, detail or None)
    return (raw, None)


# ─────────────────────────────────────────────────────────────────────────
# Logs + identifiers + tiny utilities
# ─────────────────────────────────────────────────────────────────────────


def _build_logs(run_dir: Path) -> Optional[dict[str, Any]]:
    log_path = run_dir / "workflow.log"
    if not log_path.is_file():
        return None
    try:
        with log_path.open("r", encoding="utf-8") as fh:
            line_count = sum(1 for _ in fh)
    except OSError:
        line_count = None
    return {"workflow_log": str(log_path), "workflow_log_lines": line_count}


def _resolve_project_id(run_dir: Path) -> str:
    """Recover ``project_id`` from the canonical run_dir layout
    (``~/.cap/projects/<id>/reports/workflows/<wf>/<run_id>``).

    Falls back to ``"unknown"`` for non-canonical layouts because this
    builder must never raise on shape; the schema requires a string and
    the caller can override via a future explicit kwarg if needed.
    """
    parents = list(run_dir.parents)
    if len(parents) >= 4:
        return parents[3].name
    return "unknown"


def _safe_parent_name(run_dir: Path, *, depth: int) -> Optional[str]:
    parents = list(run_dir.parents)
    if depth - 1 < 0 or depth - 1 >= len(parents):
        return None
    return parents[depth - 1].name


def _resolve_task_id(status_file: Optional[Path | str], run_id: str) -> Optional[str]:
    if not status_file or not run_id:
        return None
    sf = Path(status_file).expanduser()
    if not sf.is_file():
        return None
    try:
        data = json.loads(sf.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None
    runs = data.get("runs", []) if isinstance(data, dict) else []
    for entry in runs:
        if isinstance(entry, dict) and entry.get("run_id") == run_id:
            tid = entry.get("task_id")
            return tid if isinstance(tid, str) and tid else None
    return None


def _safe_str(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    return str(value)


def _parse_int(value: Any) -> Optional[int]:
    if value is None:
        return None
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        trimmed = value.strip()
        if not trimmed:
            return None
        try:
            return int(trimmed)
        except ValueError:
            return None
    return None


def _coerce_phase(value: Any) -> Any:
    """Schema accepts ``[integer, string]`` for phase. Try int first
    (cleaner downstream comparisons); fall back to string passthrough."""
    if isinstance(value, int) and not isinstance(value, bool):
        return value
    if isinstance(value, str):
        trimmed = value.strip()
        if not trimmed:
            return 0
        try:
            return int(trimmed)
        except ValueError:
            return trimmed
    return _safe_str(value) or 0
