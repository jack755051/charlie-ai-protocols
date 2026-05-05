"""qa_gate_runner — P8 #4 QA checkpoint runner (third gate producer).

Mirrors the producer shape established by P8 #2 (watcher) and P8 #3
(security) but the check semantics are scoped to the **07-qa-agent.md**
domain:

* test summary parsing (jest / pytest / mocha text reports → counts)
* coverage threshold parsing (jest text-summary, generic ``coverage:
  N%``, ``Lines: N%``)
* the same artifact existence / non-empty guards every gate runner
  needs to keep verdict aggregation honest

Boundary:

* This is **not** a port of the full QA agent. The runner does NOT
  execute Playwright / k6 / Lighthouse — those run in their native
  environments and write reports; the runner audits the **reports**
  and surfaces machine-readable verdicts. Deep behavioural
  verification stays with 07-qa-agent.md.
* Pattern bank is deliberately minimal; first-match-wins per artifact
  to keep results deterministic for tests. Polyglot test runners that
  output multiple summaries will be picked by pattern order, not by
  best-match heuristics.
* Verdict severity is calibrated to QA-domain norms: test failures →
  ``high`` (recoverable, escalate to supervisor); coverage below
  threshold → ``medium`` (warn rather than fail). This diverges from
  security where critical secret leaks halt immediately.

Code-shape rationale:

This is the **third caller** in the gate-runner family
(watcher / security / qa). Verdict aggregation, identity dataclass,
filesystem helpers and existence/non-empty checks are now
copy-paste duplicated three ways. The natural extraction point —
``engine/gate_runner_common.py`` — is intentionally **deferred to a
follow-up refactor commit** so this commit only adds new behaviour
and the refactor diff stays orthogonal. Every "MIRROR OF
watcher_gate_runner" / "MIRROR OF security_gate_runner" comment
below identifies the candidate to lift into the shared module.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


# ─────────────────────────────────────────────────────────
# Severity → risk_level mapping
# (MIRROR OF watcher_gate_runner / security_gate_runner.)
# ─────────────────────────────────────────────────────────

_SEVERITY_RANK = {"info": 0, "low": 1, "medium": 2, "high": 3, "critical": 4}


def _severity_to_risk(sev: str) -> str:
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
    """Pick (result, risk_level). MIRROR OF watcher / security runners."""
    if has_blocking_input_error:
        return "blocked", "high"
    if not findings:
        return "pass", "none"
    worst = max(findings, key=lambda f: _SEVERITY_RANK.get(f.get("severity", "info"), 0))
    worst_sev = worst.get("severity", "info")
    rank = _SEVERITY_RANK.get(worst_sev, 0)
    if rank >= _SEVERITY_RANK["high"]:
        return "fail", _severity_to_risk(worst_sev)
    if rank == _SEVERITY_RANK["medium"]:
        return "warn", "medium"
    return "pass", "low"


# ─────────────────────────────────────────────────────────
# File ingestion (MIRROR OF security_gate_runner)
# ─────────────────────────────────────────────────────────

_MAX_SCAN_BYTES = 2 * 1024 * 1024  # 2 MiB; reports beyond this are likely generated noise


def _read_text_safely(path: Path) -> tuple[str | None, str | None]:
    try:
        size = path.stat().st_size
    except FileNotFoundError:
        return None, "vanished_during_scan"
    if size > _MAX_SCAN_BYTES:
        return None, f"file_exceeds_scan_cap:{size}_bytes"
    try:
        return path.read_text(encoding="utf-8", errors="replace"), None
    except OSError as exc:  # pragma: no cover — disk error guard
        return None, f"read_failed:{exc}"


# ─────────────────────────────────────────────────────────
# Pattern definitions
# ─────────────────────────────────────────────────────────
#
# Test summary patterns — first match per artifact wins. Order matters:
# place high-confidence formats (jest / pytest standardised lines)
# before fuzzier matchers (mocha-style raw counts) so polyglot reports
# don't get pulled into the wrong dialect's group capture.

_TEST_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    # jest default reporter: "Tests:       1 failed, 47 passed, 48 total"
    # Both failed and passed segments are independently optional;
    # `total` is always present.
    (
        "jest",
        re.compile(
            r"Tests:\s+"
            r"(?:(?P<failed>\d+)\s+failed,\s+)?"
            r"(?:(?P<passed>\d+)\s+passed,\s+)?"
            r"(?P<total>\d+)\s+total"
        ),
    ),
    # pytest summary line: "===== 1 failed, 47 passed in 1.23s ====="
    # Or pure-pass: "===== 47 passed in 1.23s ====="
    # Or pure-fail: "===== 1 failed in 1.23s ====="
    (
        "pytest",
        re.compile(
            r"={3,}\s+"
            r"(?:(?P<failed>\d+)\s+failed,?\s+)?"
            r"(?:(?P<passed>\d+)\s+passed,?\s+)?"
            r"(?:\d+\s+\w+,?\s+)?"  # absorb optional skipped/xfailed segment
            r"in\s+[\d.]+\s*s"
        ),
    ),
    # mocha: standalone "  47 passing\n  1 failing"
    (
        "mocha",
        re.compile(
            r"(?P<passed>\d+)\s+passing"
            r"(?:\s+\(.*?\))?"  # optional duration like "(2s)"
            r"(?:.*?(?P<failed>\d+)\s+failing)?",
            re.DOTALL,
        ),
    ),
]

# Coverage patterns — first match wins. The runner tracks the **lowest**
# percentage seen across all artifacts in the gate fire (worst score
# wins) so a single below-threshold report can flip the verdict to warn.

_COVERAGE_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    # jest text-summary reporter: "All files | 85.71 | ..."
    (
        "jest_text_summary",
        re.compile(r"All files\s*\|\s*(?P<percent>\d+(?:\.\d+)?)"),
    ),
    # generic line: "Total coverage: 85.71%" / "Coverage: 85%"
    (
        "generic_coverage",
        re.compile(
            r"(?i)(?:total\s+)?coverage[:\s]+(?P<percent>\d+(?:\.\d+)?)\s*%"
        ),
    ),
    # python coverage textual: "Lines       :  85.71%"
    (
        "lines_coverage",
        re.compile(
            r"(?im)^\s*Lines\s*:\s*(?P<percent>\d+(?:\.\d+)?)\s*%"
        ),
    ),
]


# ─────────────────────────────────────────────────────────
# Built-in mechanical checks
# ─────────────────────────────────────────────────────────


@dataclass
class CheckOutcome:
    """One check's outcome.

    ``extra_findings`` is used by the content scanners (test summary +
    coverage) to surface multiple findings from one read of the file.
    ``input_blocking`` flags missing artifacts that escalate the verdict
    to ``blocked`` regardless of finding severity (consistent with
    sibling runners).
    """

    name: str
    passed: bool
    finding: dict[str, Any] | None = None
    input_blocking: bool = False
    extra_findings: list[dict[str, Any]] = field(default_factory=list)
    metrics: dict[str, Any] | None = None


def _check_artifact_exists(artifact: str) -> CheckOutcome:
    """Missing report blocks the QA audit.

    Same severity ladder as watcher / security: governance cannot
    rule on QA quality from an absent artifact, so we surface ``high``
    + ``input_blocking=True`` and the aggregator escalates to
    ``result=blocked``.
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
            "description": f"Target QA report missing on disk: {artifact}",
            "recommendation": (
                "Verify the QA producer step (jest / pytest / Playwright / "
                "k6 / Lighthouse) actually emitted this report before the "
                "gate fires; if intentional, drop it from target_artifacts."
            ),
            "target_capability": None,
        },
    )


def _check_artifact_non_empty(artifact: str) -> CheckOutcome:
    """Empty QA report is a strong negative signal.

    QA reports that produce zero bytes almost always mean the runner
    crashed before writing — flagging ``medium`` (matches watcher's
    behaviour, deliberately stronger than security's ``low`` because
    QA has no legitimate "placeholder before generation" use case).
    """
    p = Path(artifact)
    try:
        size = p.stat().st_size
    except FileNotFoundError:  # pragma: no cover — race guard
        return CheckOutcome(
            name="artifact_non_empty",
            passed=False,
            finding={
                "finding_id": None,
                "severity": "low",
                "category": "artifact_race_disappeared",
                "location": artifact,
                "description": "Artifact existed at gate entry but vanished mid-scan.",
                "recommendation": "Re-run the gate after upstream stabilizes.",
                "target_capability": None,
            },
        )
    if size > 0:
        return CheckOutcome(name="artifact_non_empty", passed=True)
    return CheckOutcome(
        name="artifact_non_empty",
        passed=False,
        finding={
            "finding_id": None,
            "severity": "medium",
            "category": "artifact_empty",
            "location": artifact,
            "description": f"QA report present but zero bytes: {artifact}",
            "recommendation": (
                "Inspect the QA producer for silent crash; an empty test "
                "report usually means the runner died before flushing."
            ),
            "target_capability": None,
        },
    )


def _scan_test_summary(artifact: str, text: str) -> CheckOutcome:
    """Run the test-summary pattern bank; return findings + counts.

    First-match-wins per artifact; downstream callers pick the global
    worst (highest failed count) when aggregating across multiple
    reports. Returns informational finding when no pattern matches so
    governance can still tell which artifacts were considered but
    unparseable, separately from artifacts that truly had clean tests.
    """
    for dialect, pattern in _TEST_PATTERNS:
        match = pattern.search(text)
        if not match:
            continue
        groups = match.groupdict()
        failed = int(groups["failed"]) if groups.get("failed") else 0
        passed = int(groups["passed"]) if groups.get("passed") else 0
        # `total` only exists on jest pattern; for pytest / mocha derive it.
        total_str = groups.get("total")
        total = int(total_str) if total_str else (failed + passed)

        metrics = {
            "tests_dialect": dialect,
            "tests_total": total,
            "tests_passed": passed,
            "tests_failed": failed,
        }

        if failed > 0:
            return CheckOutcome(
                name="test_summary_scan",
                passed=False,
                metrics=metrics,
                finding={
                    "finding_id": None,
                    "severity": "high",
                    "category": "test_failure",
                    "location": artifact,
                    "description": (
                        f"{dialect} test summary: {failed} failed / "
                        f"{passed} passed / {total} total."
                    ),
                    "recommendation": (
                        "Fix failing tests before merging; QA gate must "
                        "show zero failures to pass."
                    ),
                    "target_capability": None,
                },
            )
        return CheckOutcome(name="test_summary_scan", passed=True, metrics=metrics)

    # No pattern matched — record info finding so governance can see
    # the artifact was considered but unparseable.
    return CheckOutcome(
        name="test_summary_scan",
        passed=True,
        finding={
            "finding_id": None,
            "severity": "info",
            "category": "test_summary_unparsed",
            "location": artifact,
            "description": (
                "Could not parse test summary from artifact (no jest / "
                "pytest / mocha pattern matched)."
            ),
            "recommendation": (
                "If this file is a QA report, ensure the runner uses a "
                "supported reporter format; otherwise drop it from "
                "target_artifacts."
            ),
            "target_capability": None,
        },
    )


def _scan_coverage(
    artifact: str,
    text: str,
    threshold: float,
) -> CheckOutcome:
    """Run the coverage pattern bank; return finding + percent metric.

    First-match-wins per artifact. ``threshold`` is inclusive: a
    coverage value strictly less than threshold triggers a
    ``medium`` finding; equal-or-above is silent.
    """
    for dialect, pattern in _COVERAGE_PATTERNS:
        match = pattern.search(text)
        if not match:
            continue
        percent = float(match.group("percent"))
        metrics = {
            "coverage_dialect": dialect,
            "coverage_percent": percent,
        }
        if percent < threshold:
            return CheckOutcome(
                name="coverage_scan",
                passed=False,
                metrics=metrics,
                finding={
                    "finding_id": None,
                    "severity": "medium",
                    "category": "coverage_below_threshold",
                    "location": artifact,
                    "description": (
                        f"{dialect} coverage {percent:.2f}% is below the "
                        f"configured threshold {threshold:.2f}%."
                    ),
                    "recommendation": (
                        "Add unit tests to raise coverage above the threshold "
                        "or, with supervisor approval, lower the threshold."
                    ),
                    "target_capability": None,
                },
            )
        return CheckOutcome(name="coverage_scan", passed=True, metrics=metrics)

    # No pattern matched — coverage is genuinely optional, so we record
    # a low-severity informational finding rather than treating absence
    # as a regression. Aggregator keeps `pass` if nothing else trips.
    return CheckOutcome(
        name="coverage_scan",
        passed=True,
        finding={
            "finding_id": None,
            "severity": "info",
            "category": "coverage_unparsed",
            "location": artifact,
            "description": (
                "Could not parse coverage percent from artifact "
                "(no jest text-summary / generic / lines pattern matched)."
            ),
            "recommendation": (
                "If coverage is expected, ensure the reporter prints a "
                "supported line; otherwise this is informational only."
            ),
            "target_capability": None,
        },
    )


def _content_check(artifact: str, threshold: float) -> CheckOutcome:
    """Combined content scan: read once, run test + coverage banks.

    Returns one ``CheckOutcome`` carrying merged findings + merged
    metrics. Caller is responsible for de-duplicating metrics across
    multiple artifacts (worst-coverage / sum-failed semantics).
    """
    text, err = _read_text_safely(Path(artifact))
    if err:
        return CheckOutcome(
            name="content_scan",
            passed=False,
            finding={
                "finding_id": None,
                "severity": "low",
                "category": "scan_skipped",
                "location": artifact,
                "description": f"Content scan skipped: {err}",
                "recommendation": (
                    "If the artifact should be scanned, ensure it is plain "
                    "text and below the 2 MiB scan cap; otherwise drop it "
                    "from target_artifacts."
                ),
                "target_capability": None,
            },
        )
    if text is None:  # pragma: no cover — defensive guard
        return CheckOutcome(name="content_scan", passed=True)

    test_outcome = _scan_test_summary(artifact, text)
    coverage_outcome = _scan_coverage(artifact, text, threshold)

    extra_findings: list[dict[str, Any]] = []
    if test_outcome.finding:
        extra_findings.append(test_outcome.finding)
    if coverage_outcome.finding:
        extra_findings.append(coverage_outcome.finding)

    merged_metrics: dict[str, Any] = {}
    if test_outcome.metrics:
        merged_metrics.update(test_outcome.metrics)
    if coverage_outcome.metrics:
        merged_metrics.update(coverage_outcome.metrics)

    return CheckOutcome(
        name="content_scan",
        passed=test_outcome.passed and coverage_outcome.passed,
        extra_findings=extra_findings,
        metrics=merged_metrics or None,
    )


# ─────────────────────────────────────────────────────────
# Runner
# ─────────────────────────────────────────────────────────


@dataclass
class QAGateInput:
    """Identity + audit target inputs for one QA gate fire.

    Mirrors the sibling runners' input shape so cross-rail callers can
    reuse the same identity payload; the QA-specific knob is
    ``coverage_threshold``.
    """

    gate_id: str
    checkpoint: str
    workflow_id: str
    run_id: str
    step_id: str
    project_id: str
    target_artifacts: list[str] = field(default_factory=list)
    task_id: str | None = None
    gate_subtype: str | None = "test_summary"
    produced_by: str = "07-QA"
    coverage_threshold: float = 80.0


def run_qa_gate(spec: QAGateInput) -> dict[str, Any]:
    """Run one QA checkpoint and return the envelope dict.

    Steps mirror sibling runners but the inner check set runs the QA
    pattern banks. Cross-artifact metrics aggregation:

      * ``tests_total`` / ``tests_passed`` / ``tests_failed`` — summed
        across artifacts, so multi-report runs get a meaningful total.
      * ``coverage_percent`` — minimum across artifacts (worst score
        wins) so a single below-threshold report flags the verdict.
    """
    findings: list[dict[str, Any]] = []
    has_blocking_input_error = False
    checks_executed = 0
    checks_passed = 0
    artifacts_scanned = 0

    # Aggregated metrics
    tests_total: int | None = None
    tests_passed: int | None = None
    tests_failed: int | None = None
    coverage_percent: float | None = None
    # Dialect lists are preserved across artifacts so multi-runner runs
    # (e.g., a backend pytest report + a frontend jest report) keep
    # provenance visible in the envelope without forcing a single
    # canonical dialect.
    tests_dialects: list[str] = []
    coverage_dialects: list[str] = []

    if not spec.target_artifacts:
        has_blocking_input_error = True
        findings.append(
            {
                "finding_id": None,
                "severity": "high",
                "category": "no_target_artifacts",
                "location": None,
                "description": (
                    "QA gate fired with empty target_artifacts; "
                    "governance has nothing to audit."
                ),
                "recommendation": (
                    "Wire upstream QA report paths into the gate step's "
                    "target_artifacts before re-running."
                ),
                "target_capability": None,
            }
        )

    for artifact in spec.target_artifacts:
        # 1. Existence
        outcome = _check_artifact_exists(artifact)
        checks_executed += 1
        if outcome.passed:
            checks_passed += 1
        if outcome.finding:
            findings.append(outcome.finding)
        if outcome.input_blocking:
            has_blocking_input_error = True
            continue

        # 2. Non-empty
        outcome = _check_artifact_non_empty(artifact)
        checks_executed += 1
        if outcome.passed:
            checks_passed += 1
        if outcome.finding:
            findings.append(outcome.finding)
            continue

        # 3. Content scan (test summary + coverage)
        outcome = _content_check(artifact, spec.coverage_threshold)
        checks_executed += 1
        if outcome.passed:
            checks_passed += 1
        artifacts_scanned += 1
        if outcome.finding:
            findings.append(outcome.finding)
        findings.extend(outcome.extra_findings)

        # Merge metrics
        m = outcome.metrics or {}
        if "tests_total" in m:
            tests_total = (tests_total or 0) + int(m["tests_total"])
            tests_passed = (tests_passed or 0) + int(m.get("tests_passed", 0))
            tests_failed = (tests_failed or 0) + int(m.get("tests_failed", 0))
        if "tests_dialect" in m and m["tests_dialect"] not in tests_dialects:
            tests_dialects.append(str(m["tests_dialect"]))
        if "coverage_percent" in m:
            cp = float(m["coverage_percent"])
            coverage_percent = cp if coverage_percent is None else min(coverage_percent, cp)
        if "coverage_dialect" in m and m["coverage_dialect"] not in coverage_dialects:
            coverage_dialects.append(str(m["coverage_dialect"]))

    result, risk_level = _aggregate_verdict(
        findings,
        has_blocking_input_error=has_blocking_input_error,
    )

    summary = _build_summary(
        spec.checkpoint,
        result,
        len(findings),
        tests_total,
        tests_failed,
        coverage_percent,
    )

    metrics: dict[str, Any] = {
        "checks_executed": checks_executed,
        "checks_passed": checks_passed,
        "checks_failed": checks_executed - checks_passed,
        "artifacts_scanned": artifacts_scanned,
        "tests_total": tests_total,
        "tests_passed": tests_passed,
        "tests_failed": tests_failed,
        "tests_dialects": tests_dialects,
        "coverage_percent": coverage_percent,
        "coverage_dialects": coverage_dialects,
        "coverage_threshold": spec.coverage_threshold,
    }

    envelope: dict[str, Any] = {
        "schema_version": 1,
        "gate_id": spec.gate_id,
        "gate_type": "qa",
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
        "metrics": metrics,
    }

    if result in ("fail", "blocked"):
        envelope["fail_routing"] = _derive_fail_routing(result, findings)

    return envelope


def _now_iso() -> str:
    """ISO-8601 UTC timestamp. MIRROR OF watcher / security runners."""
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _build_summary(
    checkpoint: str,
    result: str,
    finding_count: int,
    tests_total: int | None,
    tests_failed: int | None,
    coverage_percent: float | None,
) -> str:
    """Single-line summary: result + headline metrics when available."""
    parts = [f"QA checkpoint at {checkpoint!s}: result={result}"]
    if tests_total is not None:
        parts.append(f"tests {tests_failed or 0}/{tests_total} failed")
    if coverage_percent is not None:
        parts.append(f"coverage {coverage_percent:.2f}%")
    if finding_count:
        parts.append(f"{finding_count} finding(s)")
    return "; ".join(parts) + "."


def _derive_fail_routing(result: str, findings: list[dict[str, Any]]) -> dict[str, Any]:
    """Pick a default fail_routing block for QA verdicts.

    QA fails are recoverable (re-run after fixing tests), so default
    action is ``escalate`` rather than security's ``halt``. ``blocked``
    still maps to ``halt`` because the gate could not run.
    """
    if result == "blocked":
        return {
            "action": "halt",
            "route_back_to_step": None,
            "reason": (
                "QA gate could not run to completion (missing or empty "
                "test report); halt for supervisor inspection."
            ),
        }
    return {
        "action": "escalate",
        "route_back_to_step": None,
        "reason": (
            "QA gate surfaced high-severity findings (test failures or "
            "missing report content); escalate to supervisor for routing "
            "decision (route_back to implementation vs accept)."
        ),
    }


# ─────────────────────────────────────────────────────────
# CLI helpers (called by step_runtime.py)
# ─────────────────────────────────────────────────────────


def _default_output_path(spec: QAGateInput) -> Path:
    return Path.cwd() / f"{spec.step_id}.gate-result.json"


def emit_qa_gate_result(
    spec: QAGateInput,
    output_path: Path | None = None,
) -> tuple[Path, dict[str, Any]]:
    """Run the gate, persist envelope, return (path, envelope)."""
    envelope = run_qa_gate(spec)
    target = output_path or _default_output_path(spec)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(envelope, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return target, envelope


def parse_target_artifacts(values: Iterable[str] | None) -> list[str]:
    """MIRROR OF sibling runners; kept local for module independence."""
    if not values:
        return []
    return [v for v in values if v]
