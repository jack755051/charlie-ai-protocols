"""gate_result_rerun — P8 rerun-failed-gate consumer.

Sibling of :mod:`engine.gate_result_consumer` (P8 #6 fail-route
handler) on the consumer side. Reads an existing
``<step_id>.gate-result.json`` envelope, rebuilds the matching
producer input spec, re-runs the original gate (watcher / security
/ qa / logger), and emits a versioned envelope so the original
file stays untouched as audit trail.

Design constraints:

* **Original is never overwritten by default.** Versioning follows
  the same ``<step_id>-<seq>.gate-result.json`` convention used by
  P6 #3 handoff tickets, so a single step can accumulate multiple
  reruns and an operator scanning the directory can trace the
  entire decision history.
* **Schema-first guard.** The original envelope must satisfy
  ``schemas/gate-result.schema.yaml`` before we'll dispatch a
  rerun; we never act on a malformed governance state.
* **Eligibility gate.** ``fail`` / ``blocked`` verdicts are
  rerun-eligible by default. ``pass`` / ``warn`` require explicit
  ``--force`` because reruns of clean gates are usually noise; the
  guard keeps casual misuse from spamming the audit trail with
  identical envelopes.
* **Domain parameter recovery.** Each rail persists its
  domain-specific knobs differently:

    - watcher / security: only need ``target_artifacts`` (verbatim
      from envelope) plus the standard identity tuple.
    - qa: ``coverage_threshold`` lives on
      ``envelope.metrics.coverage_threshold``; we recover it
      faithfully so a rerun honours the same threshold the original
      used (a different threshold would be a different gate, not a
      rerun).
    - logger: dedicated paths are persisted positionally in
      ``target_artifacts`` (workflow_result, optional result_md,
      optional archive_summary — same order the producer emits)
      and ``mode`` lives on ``envelope.metrics.mode``. We rebuild
      ``LoggerGateInput`` from these signals.

* **Boundary with P8 #6 fail-route handling.** The consumer
  already supports ``fail_routing.action=retry`` by emitting a
  ``retry_unsupported`` decision; that decision tag is the signal
  this CLI is meant to consume. Future integration could chain
  ``consume-gate-result`` → if decision is ``retry_unsupported``
  AND policy permits → invoke ``rerun-gate`` automatically. For
  v1 the chaining is operator-driven (CLI-by-CLI); the runtime
  hook is left for a downstream commit.
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    from . import gate_runner_common as common
except ImportError:  # pragma: no cover — direct-script fallback
    import gate_runner_common as common  # type: ignore[no-redef]


# ─────────────────────────────────────────────────────────
# Outcome dataclass
# ─────────────────────────────────────────────────────────


@dataclass
class RerunOutcome:
    """Per-call result describing what the rerun did (or skipped).

    ``action`` is the primary signal:

    * ``executed`` — the rerun actually fired a producer; ``new_envelope``
      and ``new_path`` are populated, ``new_result`` carries the verdict
      of the rerun.
    * ``skipped`` — eligibility check refused the rerun (typically
      pass/warn without ``--force``); ``skip_reason`` explains why,
      and the envelope/path fields are None.
    * ``unsupported_gate_type`` — original envelope used a gate_type
      this module doesn't know how to dispatch (defensive guard for
      future producers).
    """

    action: str
    original_path: Path
    original_result: str
    original_gate_type: str
    original_gate_id: str
    original_step_id: str
    skip_reason: str | None = None
    new_envelope: dict[str, Any] | None = None
    new_path: Path | None = None
    new_result: str | None = None
    force: bool = False
    notes: list[str] = field(default_factory=list)


# ─────────────────────────────────────────────────────────
# Eligibility
# ─────────────────────────────────────────────────────────


def determine_rerun_eligibility(
    envelope: dict[str, Any],
    *,
    force: bool,
) -> tuple[bool, str | None]:
    """Return ``(eligible, skip_reason)`` for a rerun decision.

    Rules:
      * ``result in {"fail", "blocked"}`` → eligible (rerun is the
        whole point of this CLI).
      * ``result in {"pass", "warn"}`` → eligible only when
        ``force=True``; otherwise ``skip_reason="verdict_<verdict>_no_force"``.
      * any other / unknown value → eligible only when ``force=True``;
        ``skip_reason="verdict_unknown_no_force"`` otherwise. We keep
        this branch defensive even though schema validation should
        guarantee a known enum value.
    """
    result = envelope.get("result")
    if result in ("fail", "blocked"):
        return True, None
    if result in ("pass", "warn"):
        if force:
            return True, None
        return False, f"verdict_{result}_no_force"
    if force:
        return True, None
    return False, "verdict_unknown_no_force"


# ─────────────────────────────────────────────────────────
# Output path resolution (versioning)
# ─────────────────────────────────────────────────────────


_VERSION_PATTERN_TEMPLATE = r"^{stem}-(\d+)\.gate-result\.json$"


def resolve_next_output_path(
    original_path: Path,
    step_id: str,
) -> Path:
    """Pick the next free ``<step_id>-<seq>.gate-result.json`` slot.

    Algorithm:
      * Start at seq=2 (seq=1 is implicitly the original
        ``<step_id>.gate-result.json``).
      * Scan ``original_path.parent`` for files matching the version
        pattern and pick highest existing seq + 1.
      * Place the new file alongside the original; never inside a
        subdirectory, so an operator listing the parent sees the
        full timeline at one glance.
    """
    parent = original_path.parent
    pattern = re.compile(_VERSION_PATTERN_TEMPLATE.format(stem=re.escape(step_id)))
    highest = 1  # original counts as seq=1; next rerun starts at seq=2
    if parent.exists():
        for entry in parent.iterdir():
            if not entry.is_file():
                continue
            m = pattern.match(entry.name)
            if not m:
                continue
            try:
                seq = int(m.group(1))
            except (TypeError, ValueError):
                continue
            if seq > highest:
                highest = seq
    next_seq = highest + 1
    return parent / f"{step_id}-{next_seq}.gate-result.json"


# ─────────────────────────────────────────────────────────
# Dispatch by gate_type
# ─────────────────────────────────────────────────────────


class UnsupportedGateTypeError(Exception):
    """Raised when the original envelope's gate_type is unknown to
    the rerun dispatcher. Caller should map this to a CLI-level
    ``unsupported_gate_type`` outcome rather than crash.
    """


def _common_identity(envelope: dict[str, Any]) -> dict[str, Any]:
    """Pull the rail-agnostic identity tuple every runner needs.

    Keeps the per-rail builders below short by sharing the boilerplate
    (gate_id / checkpoint / workflow_id / run_id / step_id /
    project_id / task_id / gate_subtype / produced_by).
    """
    return {
        "gate_id": envelope["gate_id"],
        "checkpoint": envelope["checkpoint"],
        "workflow_id": envelope["workflow_id"],
        "run_id": envelope["run_id"],
        "step_id": envelope["step_id"],
        "project_id": envelope["project_id"],
        "task_id": envelope.get("task_id"),
        "gate_subtype": envelope.get("gate_subtype"),
    }


def _rerun_watcher(envelope: dict[str, Any]) -> dict[str, Any]:
    try:
        from .watcher_gate_runner import WatcherGateInput, run_watcher_gate
    except ImportError:  # pragma: no cover — direct-script fallback
        from watcher_gate_runner import WatcherGateInput, run_watcher_gate  # type: ignore[no-redef]

    spec = WatcherGateInput(
        target_artifacts=list(envelope.get("target_artifacts") or []),
        produced_by=envelope.get("produced_by") or "90-Watcher",
        **_common_identity(envelope),
    )
    return run_watcher_gate(spec)


def _rerun_security(envelope: dict[str, Any]) -> dict[str, Any]:
    try:
        from .security_gate_runner import SecurityGateInput, run_security_gate
    except ImportError:  # pragma: no cover — direct-script fallback
        from security_gate_runner import SecurityGateInput, run_security_gate  # type: ignore[no-redef]

    spec = SecurityGateInput(
        target_artifacts=list(envelope.get("target_artifacts") or []),
        produced_by=envelope.get("produced_by") or "08-Security",
        **_common_identity(envelope),
    )
    return run_security_gate(spec)


def _rerun_qa(envelope: dict[str, Any]) -> dict[str, Any]:
    try:
        from .qa_gate_runner import QAGateInput, run_qa_gate
    except ImportError:  # pragma: no cover — direct-script fallback
        from qa_gate_runner import QAGateInput, run_qa_gate  # type: ignore[no-redef]

    metrics = envelope.get("metrics") or {}
    threshold = metrics.get("coverage_threshold")
    # Default to QAGateInput's own default (80.0) when the metric is
    # absent — keeps reruns of envelopes from older runners (without
    # the threshold metric) still functional rather than crashing.
    coverage_threshold = float(threshold) if isinstance(threshold, (int, float)) else 80.0

    spec = QAGateInput(
        target_artifacts=list(envelope.get("target_artifacts") or []),
        produced_by=envelope.get("produced_by") or "07-QA",
        coverage_threshold=coverage_threshold,
        **_common_identity(envelope),
    )
    return run_qa_gate(spec)


def _rerun_logger(envelope: dict[str, Any]) -> dict[str, Any]:
    try:
        from .logger_gate_runner import LoggerGateInput, run_logger_gate
    except ImportError:  # pragma: no cover — direct-script fallback
        from logger_gate_runner import LoggerGateInput, run_logger_gate  # type: ignore[no-redef]

    target_artifacts = list(envelope.get("target_artifacts") or [])
    # Logger producer persists target_artifacts in a fixed positional
    # order:
    #   [0] workflow_result_path  (always present when gate fired)
    #   [1] result_md_path        (optional)
    #   [2] archive_summary_path  (optional)
    # Recover them by index; missing indices stay None so the rerun
    # surfaces the same "no_target_artifacts" finding the original
    # would have.
    workflow_result_path = target_artifacts[0] if len(target_artifacts) >= 1 else ""
    result_md_path = target_artifacts[1] if len(target_artifacts) >= 2 else None
    archive_summary_path = target_artifacts[2] if len(target_artifacts) >= 3 else None

    metrics = envelope.get("metrics") or {}
    mode = metrics.get("mode") or "milestone"

    spec = LoggerGateInput(
        workflow_result_path=workflow_result_path,
        result_md_path=result_md_path,
        archive_summary_path=archive_summary_path,
        mode=str(mode),
        produced_by=envelope.get("produced_by") or "99-Logger",
        **_common_identity(envelope),
    )
    return run_logger_gate(spec)


_DISPATCH_TABLE = {
    "watcher": _rerun_watcher,
    "security": _rerun_security,
    "qa": _rerun_qa,
    "logger": _rerun_logger,
}


def dispatch_rerun(envelope: dict[str, Any]) -> dict[str, Any]:
    """Build the right input spec and re-run the matching producer.

    Raises :class:`UnsupportedGateTypeError` for unknown gate_type
    so the CLI can map the failure to an exit code without exposing
    the raw exception to shell wrappers.
    """
    gate_type = envelope.get("gate_type")
    builder = _DISPATCH_TABLE.get(gate_type)
    if builder is None:
        raise UnsupportedGateTypeError(
            f"gate_type={gate_type!r} not supported by rerun dispatcher"
        )
    return builder(envelope)


# ─────────────────────────────────────────────────────────
# Audit-trail writers
# ─────────────────────────────────────────────────────────


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def append_workflow_log(log_path: Path, outcome: RerunOutcome) -> None:
    """Append one human-readable line per rerun call.

    Format mirrors ``gate_result_consumer.append_workflow_log`` so
    operators can grep ``gate-rerun`` or ``gate-decision`` from the
    same workflow.log without context switches.
    """
    parts = [
        f"[{_now_iso()}]",
        "gate-rerun",
        f"gate={outcome.original_gate_id}",
        f"step={outcome.original_step_id}",
        f"original_result={outcome.original_result}",
        f"action={outcome.action}",
    ]
    if outcome.action == "executed" and outcome.new_result:
        parts.append(f"new_result={outcome.new_result}")
    if outcome.action == "skipped" and outcome.skip_reason:
        parts.append(f"skip_reason={outcome.skip_reason}")
    if outcome.force:
        parts.append("force=true")
    if outcome.new_path:
        parts.append(f"new_path={outcome.new_path}")
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a", encoding="utf-8") as fh:
        fh.write(" ".join(parts) + "\n")


def append_route_history(
    history_path: Path,
    outcome: RerunOutcome,
) -> None:
    """Append one JSON record per rerun call.

    Schema is intentionally informal — same convention as the
    consumer's audit trail. ``decision`` field uses ``rerun_*``
    prefix so a downstream stream-reader can distinguish gate
    decisions (``halt`` / ``proceed`` / ``route_back`` / ...) from
    rerun events (``rerun_executed`` / ``rerun_skipped`` /
    ``rerun_unsupported_gate_type``).
    """
    record = {
        "timestamp": _now_iso(),
        "decision": f"rerun_{outcome.action}",
        "original_result": outcome.original_result,
        "new_result": outcome.new_result,
        "skip_reason": outcome.skip_reason,
        "force": outcome.force,
        "notes": list(outcome.notes),
        "source_gate_id": outcome.original_gate_id,
        "source_gate_type": outcome.original_gate_type,
        "source_step_id": outcome.original_step_id,
        "original_path": str(outcome.original_path),
        "new_path": str(outcome.new_path) if outcome.new_path else None,
        "consumer_version": 1,
    }
    history_path.parent.mkdir(parents=True, exist_ok=True)
    with history_path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, ensure_ascii=False) + "\n")


# ─────────────────────────────────────────────────────────
# CLI entry point
# ─────────────────────────────────────────────────────────


def _format_stdout_line(outcome: RerunOutcome) -> str:
    """Single-line stdout payload following the sibling-CLI convention."""
    parts = [
        f"status=ok",
        f"rerun_action={outcome.action}",
        f"original_result={outcome.original_result}",
        f"force={'true' if outcome.force else 'false'}",
        f"original_path={outcome.original_path}",
    ]
    if outcome.action == "executed":
        parts.append(f"new_result={outcome.new_result}")
        parts.append(f"new_path={outcome.new_path}")
    if outcome.action == "skipped" and outcome.skip_reason:
        parts.append(f"skip_reason={outcome.skip_reason}")
    parts.append(f"source_gate_id={outcome.original_gate_id}")
    parts.append(f"source_step_id={outcome.original_step_id}")
    return ";".join(parts)


def rerun_gate_cli(
    *,
    result_path: str,
    output_path: str | None,
    force: bool,
    workflow_log_path: str | None,
    route_history_path: str | None,
) -> None:
    """CLI entry point — load + validate + check eligibility + dispatch
    + persist + audit.

    Exit code policy mirrors :mod:`engine.gate_result_consumer`:
      * exit 0  — outcome emitted (executed, skipped, or unsupported
                  gate_type all share this code; caller reads stdout
                  for the actual action). Note: skip is **not** a
                  failure; it's a deliberate refusal.
      * exit 41 — schema validation failed
                  (``reason=gate_result_schema_invalid``).
      * exit 1  — operational error (missing artifact, JSON parse).

    Stdout is **always** the single-line outcome payload on the
    success path; on failure, stdout carries a ``reason=...`` line
    matching sibling validators' shape.
    """
    p = Path(result_path)
    if not p.exists():
        print(f"reason=missing_artifact;detail=gate-result not found: {result_path}")
        sys.exit(1)

    try:
        envelope = json.loads(p.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"reason=parse_error;detail=gate-result JSON invalid: {exc}")
        sys.exit(1)
    except OSError as exc:  # pragma: no cover — defensive read guard
        print(f"reason=parse_error;detail=gate-result read failed: {exc}")
        sys.exit(1)

    schema_errors = common.validate_gate_result_payload(envelope)
    if schema_errors:
        joined = " | ".join(schema_errors)
        print(f"reason=gate_result_schema_invalid;detail={joined}")
        sys.exit(41)

    original_result = envelope.get("result", "<unknown>")
    original_gate_type = envelope.get("gate_type", "<unknown>")
    original_gate_id = envelope.get("gate_id", "<unknown>")
    original_step_id = envelope.get("step_id", "<unknown>")

    eligible, skip_reason = determine_rerun_eligibility(envelope, force=force)
    if not eligible:
        outcome = RerunOutcome(
            action="skipped",
            original_path=p,
            original_result=original_result,
            original_gate_type=original_gate_type,
            original_gate_id=original_gate_id,
            original_step_id=original_step_id,
            skip_reason=skip_reason,
            force=force,
        )
        _audit(outcome, workflow_log_path, route_history_path)
        print(_format_stdout_line(outcome))
        sys.exit(0)

    # Dispatch to the appropriate runner.
    try:
        new_envelope = dispatch_rerun(envelope)
    except UnsupportedGateTypeError as exc:
        outcome = RerunOutcome(
            action="unsupported_gate_type",
            original_path=p,
            original_result=original_result,
            original_gate_type=original_gate_type,
            original_gate_id=original_gate_id,
            original_step_id=original_step_id,
            skip_reason=str(exc),
            force=force,
            notes=["unsupported_gate_type"],
        )
        _audit(outcome, workflow_log_path, route_history_path)
        print(f"reason=unsupported_gate_type;detail={exc}")
        sys.exit(1)

    # Persist new envelope (versioned by default; explicit --output overrides).
    target = (
        Path(output_path)
        if output_path
        else resolve_next_output_path(p, original_step_id)
    )
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(
            json.dumps(new_envelope, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
    except OSError as exc:
        print(f"reason=persist_failed;detail={exc}")
        sys.exit(1)

    # Re-validate persisted artifact (cheap producer-drift guard).
    try:
        on_disk = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"reason=persist_readback_failed;detail={exc}")
        sys.exit(1)
    post_errors = common.validate_gate_result_payload(on_disk)
    if post_errors:
        joined = " | ".join(post_errors)
        print(f"reason=gate_result_schema_invalid;detail={joined}")
        sys.exit(41)

    outcome = RerunOutcome(
        action="executed",
        original_path=p,
        original_result=original_result,
        original_gate_type=original_gate_type,
        original_gate_id=original_gate_id,
        original_step_id=original_step_id,
        new_envelope=new_envelope,
        new_path=target,
        new_result=new_envelope.get("result"),
        force=force,
    )
    _audit(outcome, workflow_log_path, route_history_path)
    print(_format_stdout_line(outcome))
    sys.exit(0)


def _audit(
    outcome: RerunOutcome,
    workflow_log_path: str | None,
    route_history_path: str | None,
) -> None:
    """Write to optional audit trails. Failures here are non-fatal:
    we still emit the outcome to stdout so the caller can act, but
    log the IO error to stderr for triage."""
    if workflow_log_path:
        try:
            append_workflow_log(Path(workflow_log_path), outcome)
        except OSError as exc:
            print(
                f"reason=workflow_log_write_failed;detail={exc}",
                file=sys.stderr,
            )
    if route_history_path:
        try:
            append_route_history(Path(route_history_path), outcome)
        except OSError as exc:
            print(
                f"reason=route_history_write_failed;detail={exc}",
                file=sys.stderr,
            )
