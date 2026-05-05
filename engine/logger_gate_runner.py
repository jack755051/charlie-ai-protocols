"""logger_gate_runner — P8 #5 Logger milestone runner (fourth gate producer).

Mirrors the producer shape established by P8 #2 (watcher) / P8 #3
(security) / P8 #4 (qa) but with a fundamentally different audit
target: instead of scanning source files for patterns, the Logger
gate validates **archive readiness** at run-end milestones. It
reads the P7 ``workflow-result.json`` as primary SSOT, optionally
checks the human-readable ``result.md`` projection and the
``archive-summary.md`` final-state document, and emits a
``gate_type=logger`` envelope summarising whether the run is ready
to be archived (or, in milestone mode, ready to roll forward).

Boundary:

* This is **not** a port of the full Logger agent. Logger AI
  produces narrative summaries (Daily Devlog, ADR commentary,
  archive narratives) which require human-aware writing. The
  runner only fires the **mechanical** subset: artifact
  presence + schema validity + count extraction. Narrative
  archive writing stays with 99-logger-agent.md.
* The runner is the first concrete consumer of the P7
  ``workflow-result.json`` schema in the gate-runner family —
  proving the contract that earlier P8 producers built around.
* Verdict policy: archive-readiness failures matter at the **end**
  of a run. Mode ``final`` treats a missing archive-summary as
  blocking (``blocked``); mode ``milestone`` treats it as a
  ``warn``-level finding (recoverable by the next checkpoint).

Modes:

* ``milestone`` (default): mid-run logger checkpoint. Missing
  ``archive-summary.md`` → ``warn`` (medium); missing
  ``result.md`` → ``warn`` (medium). The run can keep moving;
  next checkpoint will re-evaluate.
* ``final``: end-of-run logger gate. Missing
  ``archive-summary.md`` → ``blocked`` (governance cannot deem
  the run archive-ready); missing ``result.md`` → ``warn``
  (still recoverable but flagged for triage).

Sharing P8 mechanics: rail-agnostic helpers
(``aggregate_verdict`` / ``check_artifact_exists`` /
``check_artifact_non_empty`` / ``emit_and_validate_or_exit`` /
identity-tier ``CheckOutcome``) live in
:mod:`engine.gate_runner_common`; this module only carries the
Logger domain-specific bits (input dataclass with mode + dedicated
artifact paths, workflow-result schema validation, metric
extraction from validated payload, mode-aware fail_routing).
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

try:
    from . import gate_runner_common as common
except ImportError:  # pragma: no cover — direct-script fallback
    import gate_runner_common as common  # type: ignore[no-redef]


# ─────────────────────────────────────────────────────────
# Schema location
# ─────────────────────────────────────────────────────────


def _default_workflow_result_schema_path() -> Path:
    """Resolve ``schemas/workflow-result.schema.yaml`` next to ``engine/``.

    Mirrors :func:`gate_runner_common.default_gate_result_schema_path`
    but points at the P7 contract rather than the P8 contract. Kept
    private to this module because no other consumer needs it.
    """
    return (
        Path(__file__).resolve().parent.parent
        / "schemas"
        / "workflow-result.schema.yaml"
    )


def _validate_workflow_result(payload: dict[str, Any]) -> list[str]:
    """Validate a ``workflow-result.json`` payload against its schema.

    Returns ordered error messages — empty list means clean. Same
    jsonschema-or-fallback path as
    :func:`gate_runner_common.validate_gate_result_payload`; we keep
    this inline rather than parameterising the common helper because
    the workflow-result schema is the only secondary schema the gate
    runners need to validate today.
    """
    schema_p = _default_workflow_result_schema_path()
    if not schema_p.exists():
        return [f"workflow-result schema not found: {schema_p}"]
    try:
        import yaml  # type: ignore[import]

        schema = yaml.safe_load(schema_p.read_text(encoding="utf-8")) or {}
    except ImportError:
        return ["PyYAML unavailable; cannot load workflow-result schema"]
    except Exception as exc:  # pragma: no cover — defensive YAML guard
        return [f"workflow-result schema YAML invalid: {exc}"]

    errors: list[str] = []
    try:
        from jsonschema import Draft202012Validator  # type: ignore[import]

        validator = Draft202012Validator(schema)
        for err in sorted(validator.iter_errors(payload), key=lambda e: list(e.absolute_path)):
            loc = "/".join(str(p) for p in err.absolute_path) or "<root>"
            errors.append(f"{loc}: {err.message}")
    except ImportError:
        try:
            from .step_runtime import validate_jsonschema_fallback
        except ImportError:  # pragma: no cover — direct-script fallback
            from step_runtime import validate_jsonschema_fallback  # type: ignore[no-redef]
        errors.extend(validate_jsonschema_fallback(payload, schema))
    return errors


# ─────────────────────────────────────────────────────────
# Domain-specific finding constructors
# ─────────────────────────────────────────────────────────


def _missing_workflow_result_finding(path: str) -> dict[str, Any]:
    return {
        "finding_id": None,
        "severity": "high",
        "category": "workflow_result_missing",
        "location": path,
        "description": (
            f"Primary SSOT workflow-result.json missing on disk: {path}"
        ),
        "recommendation": (
            "Verify the P7 result-report-builder ran to completion; "
            "the Logger gate cannot audit a run without its workflow-result."
        ),
        "target_capability": None,
    }


def _empty_workflow_result_finding(path: str) -> dict[str, Any]:
    return {
        "finding_id": None,
        "severity": "high",
        "category": "workflow_result_empty",
        "location": path,
        "description": f"workflow-result.json present but zero bytes: {path}",
        "recommendation": (
            "Inspect the P7 builder for silent crash; an empty "
            "workflow-result usually means the writer died after mkdir."
        ),
        "target_capability": None,
    }


def _race_finding(path: str) -> dict[str, Any]:
    return {
        "finding_id": None,
        "severity": "low",
        "category": "artifact_race_disappeared",
        "location": path,
        "description": "Artifact existed at gate entry but vanished mid-scan.",
        "recommendation": "Re-run the gate after upstream stabilizes.",
        "target_capability": None,
    }


def _workflow_result_parse_error_finding(
    path: str, detail: str
) -> dict[str, Any]:
    return {
        "finding_id": None,
        "severity": "high",
        "category": "workflow_result_parse_error",
        "location": path,
        "description": (
            f"workflow-result.json failed JSON parse: {detail}"
        ),
        "recommendation": (
            "Re-run the P7 builder; if the file looks corrupted, inspect "
            "for partial / interrupted writes."
        ),
        "target_capability": None,
    }


def _workflow_result_schema_invalid_finding(
    path: str, errors: list[str]
) -> dict[str, Any]:
    joined = " | ".join(errors[:5])
    if len(errors) > 5:
        joined = f"{joined} (+{len(errors) - 5} more)"
    return {
        "finding_id": None,
        "severity": "high",
        "category": "workflow_result_schema_invalid",
        "location": path,
        "description": (
            f"workflow-result.json fails schemas/workflow-result.schema.yaml: "
            f"{joined}"
        ),
        "recommendation": (
            "Fix the P7 builder so its emitted artifact satisfies the "
            "workflow-result contract; archive cannot proceed on a "
            "schema-invalid SSOT."
        ),
        "target_capability": None,
    }


def _result_md_missing_finding(path: str) -> dict[str, Any]:
    return {
        "finding_id": None,
        "severity": "medium",
        "category": "result_md_missing",
        "location": path,
        "description": f"result.md projection missing on disk: {path}",
        "recommendation": (
            "Re-run the P7 builder to regenerate the human-readable "
            "projection; archive readers expect both JSON SSOT and MD "
            "summary to coexist."
        ),
        "target_capability": None,
    }


def _archive_summary_missing_finding(path: str, mode: str) -> dict[str, Any]:
    """Mode-aware finding: ``final`` mode escalates to ``high``
    severity (and the runner promotes verdict to ``blocked`` via
    ``input_blocking``); ``milestone`` mode keeps it at ``medium``
    (verdict reaches ``warn``).
    """
    if mode == "final":
        severity = "high"
        suffix = (
            "Final-mode archive cannot proceed without an archive-summary; "
            "the run is not archive-ready."
        )
    else:
        severity = "medium"
        suffix = (
            "Milestone mode: the next checkpoint can recover this; surface "
            "as a warning so the gap is visible without halting."
        )
    return {
        "finding_id": None,
        "severity": severity,
        "category": "archive_summary_missing",
        "location": path,
        "description": (
            f"archive-summary.md missing on disk: {path} (mode={mode})"
        ),
        "recommendation": (
            "Have Logger AI (99-Logger) produce archive-summary.md per "
            f"99-logger-agent.md §2.4. {suffix}"
        ),
        "target_capability": None,
    }


# ─────────────────────────────────────────────────────────
# Built-in mechanical checks
# ─────────────────────────────────────────────────────────


def _check_workflow_result_exists(path: str) -> common.CheckOutcome:
    """Missing workflow-result blocks the entire Logger gate."""
    return common.check_artifact_exists(
        path,
        missing_finding=_missing_workflow_result_finding(path),
    )


def _check_workflow_result_non_empty(path: str) -> common.CheckOutcome:
    """Empty workflow-result also blocks; flag stays at ``high`` because
    the gate cannot extract any metrics from zero bytes.

    Implementation note: the common ``check_artifact_non_empty`` helper
    is non-blocking by design (``input_blocking`` defaults to False
    and is fixed). To make empty-file blocking for Logger, we don't
    set ``input_blocking`` directly; instead the runner inspects the
    finding's severity after the call. See ``run_logger_gate``.
    """
    return common.check_artifact_non_empty(
        path,
        empty_finding=_empty_workflow_result_finding(path),
        race_finding=_race_finding(path),
    )


# ─────────────────────────────────────────────────────────
# Metric extraction
# ─────────────────────────────────────────────────────────


def _extract_metrics(payload: dict[str, Any]) -> dict[str, Any]:
    """Pull machine-readable counts + headline state out of a validated
    workflow-result payload.

    Every field is defensive: workflow-result schema makes
    ``summary`` / ``steps`` / ``sessions`` / ``artifacts`` required,
    but failures / promote_candidates / final_result are optional.
    The runner returns ``None`` for missing fields rather than
    fabricating defaults so consumers can distinguish "absent" from
    "zero".
    """
    summary = payload.get("summary") or {}
    return {
        "final_state": payload.get("final_state"),
        "final_result": payload.get("final_result"),
        "total_steps": summary.get("total_steps"),
        "completed_steps": summary.get("completed"),
        "failed_steps": summary.get("failed"),
        "skipped_steps": summary.get("skipped"),
        "blocked_steps": summary.get("blocked"),
        "failure_count": len(payload.get("failures") or []),
        "artifact_count": len(payload.get("artifacts") or []),
        "session_count": len(payload.get("sessions") or []),
        "promote_candidate_count": len(payload.get("promote_candidates") or []),
    }


# ─────────────────────────────────────────────────────────
# Runner
# ─────────────────────────────────────────────────────────


@dataclass
class LoggerGateInput:
    """Identity + audit target inputs for one Logger gate fire.

    Diverges from sibling runners by accepting **dedicated artifact
    paths** instead of a generic ``target_artifacts`` list. The Logger
    gate has named roles for each artifact (workflow-result is SSOT,
    result.md is human projection, archive-summary is final
    narrative); a flat list would lose this provenance.

    The envelope's ``target_artifacts`` field is still populated by
    the runner from whichever paths were supplied so consumers can
    inspect what was audited.
    """

    gate_id: str
    checkpoint: str
    workflow_id: str
    run_id: str
    step_id: str
    project_id: str
    workflow_result_path: str
    result_md_path: str | None = None
    archive_summary_path: str | None = None
    mode: str = "milestone"  # "milestone" or "final"
    task_id: str | None = None
    gate_subtype: str | None = "milestone_archive"
    produced_by: str = "99-Logger"


def run_logger_gate(spec: LoggerGateInput) -> dict[str, Any]:
    """Run one Logger archive-readiness checkpoint and return envelope.

    Pipeline:
      1. Validate ``workflow_result_path``: exists → non-empty → JSON
         parses → schema-valid. Any failure here is blocking; the
         Logger gate cannot proceed without a valid SSOT.
      2. Extract metrics from the validated payload (state, result,
         step counts, failure / artifact / session / promote counts).
      3. Optionally check ``result_md_path``: missing →
         ``warn``-level finding (medium).
      4. Optionally check ``archive_summary_path``: missing →
         ``warn`` (mode=milestone) or ``blocked`` (mode=final). Empty
         archive-summary is treated like missing in final mode.
      5. Aggregate verdict via :func:`common.aggregate_verdict`;
         emit envelope.
    """
    findings: list[dict[str, Any]] = []
    has_blocking_input_error = False
    checks_executed = 0
    checks_passed = 0
    metrics: dict[str, Any] = {
        "workflow_result_validated": False,
    }

    target_artifacts: list[str] = [spec.workflow_result_path]
    if spec.result_md_path:
        target_artifacts.append(spec.result_md_path)
    if spec.archive_summary_path:
        target_artifacts.append(spec.archive_summary_path)

    # ── 1a. workflow-result existence (blocking on miss) ──────────
    outcome = _check_workflow_result_exists(spec.workflow_result_path)
    checks_executed += 1
    if outcome.passed:
        checks_passed += 1
    else:
        if outcome.finding:
            findings.append(outcome.finding)
        if outcome.input_blocking:
            has_blocking_input_error = True

    # Skip downstream checks when SSOT is gone — the rest of the
    # pipeline depends on its content.
    if not has_blocking_input_error:
        # ── 1b. workflow-result non-empty (also blocking) ─────────
        outcome = _check_workflow_result_non_empty(spec.workflow_result_path)
        checks_executed += 1
        if outcome.passed:
            checks_passed += 1
        else:
            if outcome.finding:
                findings.append(outcome.finding)
            # Non-empty failures aren't input_blocking by common
            # convention, but for Logger an empty SSOT is fatal —
            # promote it to blocking here.
            has_blocking_input_error = True

    if not has_blocking_input_error:
        # ── 1c. JSON parse ────────────────────────────────────────
        try:
            payload = json.loads(
                Path(spec.workflow_result_path).read_text(encoding="utf-8")
            )
            checks_executed += 1
            checks_passed += 1
        except (OSError, json.JSONDecodeError) as exc:
            checks_executed += 1
            findings.append(
                _workflow_result_parse_error_finding(
                    spec.workflow_result_path, str(exc)
                )
            )
            has_blocking_input_error = True
            payload = None

        if payload is not None:
            # ── 1d. schema validation ─────────────────────────────
            schema_errors = _validate_workflow_result(payload)
            checks_executed += 1
            if not schema_errors:
                checks_passed += 1
                metrics["workflow_result_validated"] = True
                # ── 2. metric extraction ──────────────────────────
                metrics.update(_extract_metrics(payload))
            else:
                findings.append(
                    _workflow_result_schema_invalid_finding(
                        spec.workflow_result_path, schema_errors
                    )
                )
                has_blocking_input_error = True

    # ── 3. result.md (optional, never blocking) ───────────────────
    if spec.result_md_path:
        if Path(spec.result_md_path).exists():
            checks_executed += 1
            checks_passed += 1
        else:
            checks_executed += 1
            findings.append(_result_md_missing_finding(spec.result_md_path))

    # ── 4. archive-summary.md (optional; mode-aware) ──────────────
    if spec.archive_summary_path:
        archive_p = Path(spec.archive_summary_path)
        if archive_p.exists() and archive_p.stat().st_size > 0:
            checks_executed += 1
            checks_passed += 1
        else:
            checks_executed += 1
            finding = _archive_summary_missing_finding(
                spec.archive_summary_path, spec.mode
            )
            findings.append(finding)
            if spec.mode == "final":
                # Final-mode missing archive blocks the gate verdict.
                has_blocking_input_error = True

    result, risk_level = common.aggregate_verdict(
        findings,
        has_blocking_input_error=has_blocking_input_error,
    )

    summary = _build_summary(
        spec.checkpoint,
        spec.mode,
        result,
        len(findings),
        metrics,
    )

    envelope_metrics: dict[str, Any] = {
        "checks_executed": checks_executed,
        "checks_passed": checks_passed,
        "checks_failed": checks_executed - checks_passed,
        "mode": spec.mode,
    }
    envelope_metrics.update(metrics)

    envelope: dict[str, Any] = {
        "schema_version": 1,
        "gate_id": spec.gate_id,
        "gate_type": "logger",
        "gate_subtype": spec.gate_subtype,
        "checkpoint": spec.checkpoint,
        "workflow_id": spec.workflow_id,
        "run_id": spec.run_id,
        "step_id": spec.step_id,
        "project_id": spec.project_id,
        "task_id": spec.task_id,
        "produced_at": common.now_iso(),
        "produced_by": spec.produced_by,
        "target_artifacts": target_artifacts,
        "result": result,
        "risk_level": risk_level,
        "summary": summary,
        "findings": findings,
        "metrics": envelope_metrics,
    }

    if result in ("fail", "blocked"):
        envelope["fail_routing"] = _derive_fail_routing(result, spec.mode)

    return envelope


def _build_summary(
    checkpoint: str,
    mode: str,
    result: str,
    finding_count: int,
    metrics: dict[str, Any],
) -> str:
    """Single-line summary including run state + run counts when known."""
    parts = [f"Logger gate at {checkpoint!s} (mode={mode}): result={result}"]
    final_state = metrics.get("final_state")
    final_result = metrics.get("final_result")
    if final_state:
        suffix = f"run final_state={final_state}"
        if final_result:
            suffix = f"{suffix}/{final_result}"
        parts.append(suffix)
    total_steps = metrics.get("total_steps")
    failed_steps = metrics.get("failed_steps")
    if total_steps is not None:
        parts.append(f"steps {failed_steps or 0}/{total_steps} failed")
    if finding_count:
        parts.append(f"{finding_count} finding(s)")
    return "; ".join(parts) + "."


def _derive_fail_routing(result: str, mode: str) -> dict[str, Any]:
    """Pick a default fail_routing block.

    * ``blocked`` always halts — Logger cannot archive without its
      inputs (missing/invalid workflow-result, or final-mode missing
      archive-summary).
    * ``fail`` (high finding without input-blocker) escalates so
      supervisor can decide whether to route_back to P7 builder or
      accept the gap.
    """
    if result == "blocked":
        if mode == "final":
            reason = (
                "Logger final-mode gate could not deem run archive-ready "
                "(missing/invalid SSOT or missing archive-summary); halt "
                "for supervisor inspection."
            )
        else:
            reason = (
                "Logger milestone gate could not run to completion "
                "(missing or invalid workflow-result); halt for "
                "supervisor inspection."
            )
        return {
            "action": "halt",
            "route_back_to_step": None,
            "reason": reason,
        }
    return {
        "action": "escalate",
        "route_back_to_step": None,
        "reason": (
            "Logger gate surfaced high-severity findings; escalate to "
            "supervisor for routing decision (route_back to P7 builder "
            "or accept and archive)."
        ),
    }


# ─────────────────────────────────────────────────────────
# CLI helpers (called by step_runtime.py)
# ─────────────────────────────────────────────────────────


def emit_logger_gate_result(
    spec: LoggerGateInput,
    output_path: Path | None = None,
) -> tuple[Path, dict[str, Any]]:
    """Run the gate, persist envelope, return (path, envelope)."""
    envelope = run_logger_gate(spec)
    target = output_path or common.default_output_path(spec.step_id)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        json.dumps(envelope, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    return target, envelope


def parse_target_artifacts(values: Iterable[str] | None) -> list[str]:
    """Re-export :func:`gate_runner_common.parse_target_artifacts`.

    The Logger CLI does not consume ``--target-artifact`` (it uses
    dedicated flags) but the helper is kept as a re-export for API
    parity with sibling runner modules.
    """
    return common.parse_target_artifacts(values)
