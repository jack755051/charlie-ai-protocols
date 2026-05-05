"""watcher_gate_runner — P8 #2 Watcher checkpoint runner (first gate producer).

This module is the **first concrete producer** that satisfies the
``schemas/gate-result.schema.yaml`` envelope contract introduced by P8
#1 (``validate-gate-result``). Its purpose is twofold:

1. Give horizontal Watcher governance (90-watcher-agent.md ``milestone_gate``)
   a deterministic, machine-callable runner so milestone checkpoints
   can be wired into workflows without depending on AI sub-agent
   spawn for every gate.
2. Verify that the validation CLI shipped in P8 #1 actually consumes a
   real producer's output. The runner emits an envelope, then re-runs
   the validation gate against its own output as a round-trip integrity
   check before returning. If the producer drifts from the schema, the
   runner halts at exit 41 instead of silently writing an unusable
   artifact.

Boundary:

* This is **not** a port of the full Watcher agent. The full Watcher
  audit is AI-driven (DDD boundary checks, framework strategy
  conformance, naming conventions, etc.) and stays in 90-watcher-agent.md.
  The runner only fires the **mechanical** subset that is genuinely
  deterministic — currently artifact existence and non-emptiness.
* Producers downstream of P8 #2 (Security #3 / QA #4 / Logger #5
  runners) are expected to follow the same emit-then-self-validate
  shape so consumers (P8 #6 fail-route handler / #7 halt-on-risk /
  #8 rerun-failed-gate) can rely on a uniform envelope.
* Verdict aggregation is intentionally simple in v1: enough to give
  governance a real decision (pass / warn / blocked / fail) without
  pretending the runner can reproduce full Watcher AI judgement.

After v0.22.0 P8 refactor: rail-agnostic mechanics
(severity/aggregate/now_iso/output-path/check primitives) live in
:mod:`engine.gate_runner_common`; this module retains the watcher
domain-specific bits (input dataclass, finding text, summary line,
fail_routing policy).
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
# Domain-specific finding constructors
# ─────────────────────────────────────────────────────────


def _missing_artifact_finding(artifact: str) -> dict[str, Any]:
    return {
        "finding_id": None,
        "severity": "high",
        "category": "artifact_missing",
        "location": artifact,
        "description": f"Target artifact missing on disk: {artifact}",
        "recommendation": (
            "Verify the upstream producer step actually emitted this "
            "artifact before the watcher gate fires; if intentional, "
            "drop it from target_artifacts."
        ),
        "target_capability": None,
    }


def _empty_artifact_finding(artifact: str) -> dict[str, Any]:
    return {
        "finding_id": None,
        "severity": "medium",
        "category": "artifact_empty",
        "location": artifact,
        "description": f"Target artifact present but zero bytes: {artifact}",
        "recommendation": (
            "Inspect the upstream producer for silent write failure; "
            "an empty SSOT file usually means the producer crashed "
            "after mkdir but before the content write."
        ),
        "target_capability": None,
    }


def _race_finding(artifact: str) -> dict[str, Any]:
    return {
        "finding_id": None,
        "severity": "low",
        "category": "artifact_race_disappeared",
        "location": artifact,
        "description": (
            "Artifact existed at gate entry but was unreadable "
            "during size check; possible upstream race."
        ),
        "recommendation": "Re-run the gate after upstream stabilizes.",
        "target_capability": None,
    }


def _no_target_artifacts_finding() -> dict[str, Any]:
    return {
        "finding_id": None,
        "severity": "high",
        "category": "no_target_artifacts",
        "location": None,
        "description": (
            "Watcher gate fired with empty target_artifacts; "
            "governance has nothing to audit."
        ),
        "recommendation": (
            "Wire upstream artifact paths into the gate step's "
            "target_artifacts before re-running."
        ),
        "target_capability": None,
    }


# ─────────────────────────────────────────────────────────
# Built-in mechanical checks (thin wrappers over common primitives)
# ─────────────────────────────────────────────────────────


def _check_artifact_exists(artifact: str) -> common.CheckOutcome:
    """Watcher-flavoured existence check; missing → blocked/high."""
    return common.check_artifact_exists(
        artifact,
        missing_finding=_missing_artifact_finding(artifact),
    )


def _check_artifact_non_empty(artifact: str) -> common.CheckOutcome:
    """Watcher-flavoured non-empty check; empty file → medium finding."""
    return common.check_artifact_non_empty(
        artifact,
        empty_finding=_empty_artifact_finding(artifact),
        race_finding=_race_finding(artifact),
    )


# ─────────────────────────────────────────────────────────
# Runner
# ─────────────────────────────────────────────────────────


@dataclass
class WatcherGateInput:
    """Identity + audit target inputs for one watcher gate fire.

    Mirrors the required identity fields on
    ``schemas/gate-result.schema.yaml`` so the runner can populate the
    envelope without re-deriving them from workflow context.
    """

    gate_id: str
    checkpoint: str
    workflow_id: str
    run_id: str
    step_id: str
    project_id: str
    target_artifacts: list[str] = field(default_factory=list)
    task_id: str | None = None
    gate_subtype: str | None = "structure_audit"
    produced_by: str = "90-Watcher"


def run_watcher_gate(spec: WatcherGateInput) -> dict[str, Any]:
    """Run one watcher milestone gate and return the envelope dict.

    Steps:
      1. Resolve identity into the schema-required fields.
      2. Run built-in mechanical checks per target artifact:
         * artifact_exists
         * artifact_non_empty (only when artifact_exists passed)
      3. Aggregate findings into (result, risk_level) via common helper.
      4. Populate metrics counters (checks_executed / checks_passed
         / checks_failed) so consumers can spot gates with mostly
         clean checks vs gates where every check tripped.
      5. Populate fail_routing when result is fail / blocked so P8 #6
         fail-route handler has a concrete recommendation; pass / warn
         leave fail_routing unset (consumer falls back to workflow YAML).

    No filesystem writes happen here — the caller (CLI wrapper) decides
    where to persist the envelope and whether to validate it via the
    P8 #1 CLI.
    """
    findings: list[dict[str, Any]] = []
    has_blocking_input_error = False
    checks_executed = 0
    checks_passed = 0

    if not spec.target_artifacts:
        # Degenerate input: no artifacts to audit. Treated as blocked
        # because governance cannot decide on an empty audit surface;
        # supervisor should fix the workflow YAML to point the gate at
        # real outputs.
        has_blocking_input_error = True
        findings.append(_no_target_artifacts_finding())

    for artifact in spec.target_artifacts:
        outcome = _check_artifact_exists(artifact)
        checks_executed += 1
        if outcome.passed:
            checks_passed += 1
        if outcome.finding:
            findings.append(outcome.finding)
        if outcome.input_blocking:
            has_blocking_input_error = True
            # Skip non-empty check when the file is missing entirely;
            # avoid duplicate noise on the same artifact.
            continue

        outcome = _check_artifact_non_empty(artifact)
        checks_executed += 1
        if outcome.passed:
            checks_passed += 1
        if outcome.finding:
            findings.append(outcome.finding)

    result, risk_level = common.aggregate_verdict(
        findings,
        has_blocking_input_error=has_blocking_input_error,
    )

    summary = _build_summary(spec.checkpoint, result, len(findings))

    envelope: dict[str, Any] = {
        "schema_version": 1,
        "gate_id": spec.gate_id,
        "gate_type": "watcher",
        "gate_subtype": spec.gate_subtype,
        "checkpoint": spec.checkpoint,
        "workflow_id": spec.workflow_id,
        "run_id": spec.run_id,
        "step_id": spec.step_id,
        "project_id": spec.project_id,
        "task_id": spec.task_id,
        "produced_at": common.now_iso(),
        "produced_by": spec.produced_by,
        "target_artifacts": list(spec.target_artifacts),
        "result": result,
        "risk_level": risk_level,
        "summary": summary,
        "findings": findings,
        "metrics": {
            "checks_executed": checks_executed,
            "checks_passed": checks_passed,
            "checks_failed": checks_executed - checks_passed,
        },
    }

    if result in ("fail", "blocked"):
        envelope["fail_routing"] = _derive_fail_routing(result, findings)

    return envelope


def _build_summary(checkpoint: str, result: str, finding_count: int) -> str:
    """Single-line human-readable summary suitable for run-summary.md.

    Kept short; envelope.findings carries the structured detail.
    """
    base = f"Watcher milestone gate at {checkpoint!s}: result={result}"
    if finding_count:
        return f"{base}; {finding_count} finding(s) recorded."
    return f"{base}; no findings."


def _derive_fail_routing(
    result: str, findings: list[dict[str, Any]]
) -> dict[str, Any]:
    """Pick a default fail_routing block.

    For ``blocked`` we default to ``halt`` because the gate could not
    audit cleanly — supervisor must inspect upstream before any rerun.
    For ``fail`` we default to ``escalate`` to flag a real quality issue
    that needs human / supervisor decision; consumer (P8 #6) MAY override
    based on workflow policy. We deliberately do **not** auto-pick
    ``route_back`` here since the runner has no insight into which
    upstream step owns the fix.
    """
    if result == "blocked":
        action = "halt"
        reason = (
            "Watcher gate could not run to completion (missing or empty "
            "audit surface); halt for supervisor inspection."
        )
    else:  # result == "fail"
        action = "escalate"
        reason = (
            "Watcher gate surfaced high/critical findings; escalate to "
            "supervisor for routing decision (route_back vs accept)."
        )

    return {
        "action": action,
        "route_back_to_step": None,
        "reason": reason,
    }


# ─────────────────────────────────────────────────────────
# CLI entry point helpers (called by step_runtime.py)
# ─────────────────────────────────────────────────────────


def emit_watcher_gate_result(
    spec: WatcherGateInput,
    output_path: Path | None = None,
) -> tuple[Path, dict[str, Any]]:
    """Run the gate, persist the envelope as JSON, return (path, envelope).

    Pure-write only — schema self-validation is the CLI wrapper's
    responsibility (it has access to the validate-gate-result subcommand
    inside the same step_runtime.py).
    """
    envelope = run_watcher_gate(spec)
    target = output_path or common.default_output_path(spec.step_id)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(envelope, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return target, envelope


def parse_target_artifacts(values: Iterable[str] | None) -> list[str]:
    """Re-export :func:`gate_runner_common.parse_target_artifacts`.

    Kept as a module-level callable so existing imports
    (``from engine.watcher_gate_runner import parse_target_artifacts``)
    continue to resolve without forcing call sites into the common
    module.
    """
    return common.parse_target_artifacts(values)
