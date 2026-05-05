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
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


# ─────────────────────────────────────────────────────────
# Verdict aggregation
# ─────────────────────────────────────────────────────────

# Severity ranks for picking the dominant finding (higher = worse).
_SEVERITY_RANK = {"info": 0, "low": 1, "medium": 2, "high": 3, "critical": 4}


def _severity_to_risk(sev: str) -> str:
    """Map finding severity to envelope risk_level.

    Mirrors the schema enum so consumer halt-on-risk policy can use
    risk_level directly without re-deriving from findings.
    """
    return {
        "info": "low",
        "low": "low",
        "medium": "medium",
        "high": "high",
        "critical": "critical",
    }.get(sev, "low")


def _aggregate_verdict(
    findings: list[dict[str, Any]],
    *,
    has_blocking_input_error: bool,
) -> tuple[str, str]:
    """Pick (result, risk_level) from a list of findings.

    Rules:
      * Any blocking input error (e.g., target artifact missing) →
        ``blocked`` / ``high``. The gate could not run cleanly so
        downstream MUST halt regardless of other findings.
      * Any ``critical`` / ``high`` severity finding → ``fail`` /
        matching risk; consumer reads fail_routing for next action.
      * Any ``medium`` severity finding → ``warn`` / ``medium``;
        downstream MAY proceed but the finding is worth surfacing.
      * Empty findings → ``pass`` / ``none``.
      * ``low`` / ``info`` only → ``pass`` / ``low``. We keep them on
        the envelope for traceability but do not promote to warn.

    Severity rank is taken from the worst finding to keep the output
    deterministic for tests.
    """
    if has_blocking_input_error:
        return "blocked", "high"

    if not findings:
        return "pass", "none"

    worst = max(
        findings,
        key=lambda f: _SEVERITY_RANK.get(f.get("severity", "info"), 0),
    )
    worst_sev = worst.get("severity", "info")
    rank = _SEVERITY_RANK.get(worst_sev, 0)

    if rank >= _SEVERITY_RANK["high"]:
        return "fail", _severity_to_risk(worst_sev)
    if rank == _SEVERITY_RANK["medium"]:
        return "warn", "medium"
    return "pass", "low"


# ─────────────────────────────────────────────────────────
# Built-in mechanical checks
# ─────────────────────────────────────────────────────────


@dataclass
class CheckOutcome:
    """One mechanical check's outcome.

    ``finding`` is non-None only when the check actually surfaces an
    issue; passing checks contribute to ``checks_passed`` counter on
    the envelope ``metrics`` block but do not pollute findings.

    ``input_blocking`` flags missing / unreadable artifacts that prevent
    the gate from running cleanly. The aggregator escalates any such
    outcome to ``result=blocked`` regardless of finding severity.
    """

    name: str
    passed: bool
    finding: dict[str, Any] | None = None
    input_blocking: bool = False


def _check_artifact_exists(artifact: str) -> CheckOutcome:
    """Verify the target artifact exists on disk.

    Watcher governance cannot audit what isn't written; missing
    artifact escalates to ``input_blocking`` so the runner emits
    ``result=blocked`` rather than fabricating a pass.
    """
    if Path(artifact).exists():
        return CheckOutcome(name="artifact_exists", passed=True)
    return CheckOutcome(
        name="artifact_exists",
        passed=False,
        input_blocking=True,
        finding={
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
        },
    )


def _check_artifact_non_empty(artifact: str) -> CheckOutcome:
    """Verify the target artifact has non-zero size.

    Empty markdown / JSON SSOT files are a common upstream silent
    failure (mkdir succeeded, write failed). Surface as ``medium``
    finding which aggregates to ``result=warn`` rather than fail —
    governance MAY still proceed but the finding is worth surfacing.

    Pre-condition: caller MUST ensure the artifact exists before
    invoking this check (existence is a separate check). If the file
    disappears between the two checks (extremely rare race), we record
    a ``low`` informational finding rather than crashing.
    """
    p = Path(artifact)
    try:
        size = p.stat().st_size
    except FileNotFoundError:  # pragma: no cover — race guard only
        return CheckOutcome(
            name="artifact_non_empty",
            passed=False,
            input_blocking=False,
            finding={
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
            },
        )

    if size > 0:
        return CheckOutcome(name="artifact_non_empty", passed=True)
    return CheckOutcome(
        name="artifact_non_empty",
        passed=False,
        input_blocking=False,
        finding={
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
        },
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
      3. Aggregate findings into (result, risk_level).
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
        findings.append(
            {
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
        )

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

    result, risk_level = _aggregate_verdict(
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
        "produced_at": _now_iso(),
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


def _now_iso() -> str:
    """Produce an ISO-8601 timestamp with explicit UTC offset.

    Schema only requires the field be a string; the explicit offset
    keeps the artifact reproducible-friendly (no local-tz drift between
    machines) and matches the timestamps already emitted by P3
    orchestration snapshots.
    """
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


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


def _default_output_path(spec: WatcherGateInput) -> Path:
    """Default emit location: ``<cwd>/<step_id>.gate-result.json``.

    Callers that want to land the artifact under
    ``~/.cap/projects/<id>/runs/<run>/`` MUST pass --output explicitly.
    The runner deliberately does **not** know cap storage layout to keep
    this module decoupled from project_context_loader.
    """
    return Path.cwd() / f"{spec.step_id}.gate-result.json"


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
    target = output_path or _default_output_path(spec)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(envelope, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return target, envelope


def parse_target_artifacts(values: Iterable[str] | None) -> list[str]:
    """Normalize CLI repeated --target-artifact values into a list.

    argparse hands us either ``None`` (flag never used) or a list. The
    runner treats ``None`` as the same degenerate case as an empty list
    so the verdict aggregator can flag it consistently.
    """
    if not values:
        return []
    return [v for v in values if v]
