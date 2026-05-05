"""security_gate_runner — P8 #3 Security checkpoint runner (second gate producer).

Mirrors the producer shape established by P8 #2
(``engine.watcher_gate_runner``) but the check semantics are scoped to
the **08-security-agent.md** domain:

* secret leakage detection (AWS access keys, private key blocks, generic
  high-entropy API key / JWT-style tokens, hardcoded passwords)
* risky-keyword detection (``dangerouslySetInnerHTML`` / ``v-html``
  XSS bypass surfaces, ``eval(`` code-injection smell)
* the same artifact existence / non-empty guards every gate runner
  needs to keep verdict aggregation honest

Boundary:

* This is **not** a full SAST scanner. Patterns are deliberately
  high-signal and few; deep CVE / CWE coverage stays with external
  tools (semgrep / snyk / github code scanning) referenced in
  ``08-security-agent.md``. The runner's job is to give horizontal
  Security governance a deterministic, machine-callable hook so
  ``security_scan`` checkpoints can fire without spawning the AI
  Security agent every time.
* Findings cap per artifact (default 10) keeps the envelope bounded;
  if a file is so dirty that the cap is hit, governance should route
  it to a real SAST tool rather than expand the gate-result envelope.
* The runner does **not** decide ``halt`` vs ``escalate`` policy
  beyond defaults — P8 #6 fail-route handler & P8 #7 halt-on-risk
  policy are the consumers that read ``risk_level`` / ``fail_routing``
  and apply workflow-level routing.

After v0.22.0 P8 refactor: rail-agnostic mechanics
(severity/aggregate/now_iso/output-path/check primitives/
read_text_safely) live in :mod:`engine.gate_runner_common`; this
module retains the security domain-specific bits (input dataclass,
pattern banks, finding text, summary line, halt-on-critical
fail_routing policy).
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

try:
    from . import gate_runner_common as common
except ImportError:  # pragma: no cover — direct-script fallback
    import gate_runner_common as common  # type: ignore[no-redef]


# ─────────────────────────────────────────────────────────
# Finding-cap policy
# ─────────────────────────────────────────────────────────

# Cap on how many findings any single artifact may contribute. Keeps
# the gate-result envelope bounded so consumers (P8 #6 / #7 / #8)
# can predict its size without streaming.
_MAX_FINDINGS_PER_ARTIFACT = 10


# ─────────────────────────────────────────────────────────
# Pattern definitions
# ─────────────────────────────────────────────────────────

# Each pattern entry:
#   (compiled_regex, severity, category, description_template, recommendation)
# We intentionally avoid `(?i)` on the AWS / private-key patterns —
# they're case-sensitive in the wild and mixed-case noise gives false
# positives.
_SECRET_PATTERNS: list[tuple[re.Pattern[str], str, str, str, str]] = [
    (
        re.compile(r"AKIA[0-9A-Z]{16}"),
        "critical",
        "secret_leak_aws_key",
        "AWS access key ID pattern detected (AKIA-prefixed 20-char token).",
        "Rotate the key immediately, scrub commit history, move secret to env / vault.",
    ),
    (
        re.compile(r"-----BEGIN (?:RSA |DSA |EC |OPENSSH |PGP )?PRIVATE KEY"),
        "critical",
        "secret_leak_private_key",
        "Private key block detected; in-tree storage of private keys is forbidden.",
        "Remove the key, rotate the corresponding credential, store in an external secret manager.",
    ),
    (
        re.compile(
            r"""(?ix)
            (?:api[_-]?key|secret[_-]?key|access[_-]?key|client[_-]?secret)
            \s*[:=]\s*
            ["']
            (?P<value>[A-Za-z0-9_/+=-]{16,})
            ["']
            """
        ),
        "high",
        "secret_leak_api_key",
        "Hardcoded API/secret key assignment detected (>=16-char value in quotes).",
        "Replace with environment variable or secret manager lookup; never commit literal credentials.",
    ),
    (
        re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
        "high",
        "secret_leak_jwt_like",
        "JWT-shaped 3-segment token detected; may be a session / access token.",
        "If real, rotate the issuer; remove from source. If sample data, replace with placeholder.",
    ),
    (
        re.compile(
            r"""(?ix)
            (?:password|passwd|pwd)
            \s*[:=]\s*
            ["']
            (?P<value>[^"'\s]{6,})
            ["']
            """
        ),
        "high",
        "secret_leak_hardcoded_password",
        "Hardcoded password assignment detected (>=6-char quoted value).",
        "Move to secrets store; never commit literal credentials, even for development fixtures.",
    ),
]

# Risky keywords: defensible but lower confidence than secret patterns.
# Severity matches 08-security-agent.md hard-failure categories where
# applicable; "eval(" stays at medium since it has many legitimate
# uses (interpreters, JSON parsers).
_RISKY_KEYWORDS: list[tuple[re.Pattern[str], str, str, str, str]] = [
    (
        re.compile(r"\bdangerouslySetInnerHTML\b"),
        "high",
        "xss_risk_react",
        "React dangerouslySetInnerHTML usage detected; bypasses XSS protection.",
        "Avoid raw HTML injection; if unavoidable, sanitize with DOMPurify or equivalent before passing in.",
    ),
    (
        re.compile(r"(?:^|[\s>])v-html\s*=\s*"),
        "high",
        "xss_risk_vue",
        "Vue v-html directive detected; bypasses XSS protection.",
        "Avoid v-html for user-controlled data; pre-sanitize content before binding.",
    ),
    (
        re.compile(r"\beval\s*\("),
        "medium",
        "code_injection_risk_eval",
        "eval() usage detected; consider whether input is fully trusted.",
        "Replace with structured parsing (JSON.parse, ast.literal_eval, etc.) where possible.",
    ),
]


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
            "artifact before the security gate fires; if intentional, "
            "drop it from target_artifacts."
        ),
        "target_capability": None,
    }


def _empty_artifact_finding(artifact: str) -> dict[str, Any]:
    """Security tolerates empty files (placeholder before generation
    is occasionally legitimate); flag at ``low`` severity so a single
    blank file does not promote the verdict to ``warn``.
    """
    return {
        "finding_id": None,
        "severity": "low",
        "category": "artifact_empty",
        "location": artifact,
        "description": f"Target artifact present but zero bytes: {artifact}",
        "recommendation": (
            "Investigate the upstream producer for silent write failure; "
            "empty files cannot be security-audited."
        ),
        "target_capability": None,
    }


def _race_finding(artifact: str) -> dict[str, Any]:
    return {
        "finding_id": None,
        "severity": "low",
        "category": "artifact_race_disappeared",
        "location": artifact,
        "description": "Artifact existed at gate entry but vanished mid-scan.",
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
            "Security gate fired with empty target_artifacts; "
            "governance has nothing to audit."
        ),
        "recommendation": (
            "Wire upstream artifact paths into the gate step's "
            "target_artifacts before re-running."
        ),
        "target_capability": None,
    }


def _scan_skipped_finding(artifact: str, err: str) -> dict[str, Any]:
    return {
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
    }


def _findings_capped_finding(artifact: str, count: int) -> dict[str, Any]:
    return {
        "finding_id": None,
        "severity": "info",
        "category": "findings_capped",
        "location": artifact,
        "description": (
            f"Artifact produced {count} findings; "
            f"truncated to {_MAX_FINDINGS_PER_ARTIFACT}."
        ),
        "recommendation": (
            "Run a dedicated SAST tool (semgrep / snyk) "
            "for full coverage on this artifact."
        ),
        "target_capability": None,
    }


# ─────────────────────────────────────────────────────────
# Built-in mechanical checks (thin wrappers over common primitives)
# ─────────────────────────────────────────────────────────


def _check_artifact_exists(artifact: str) -> common.CheckOutcome:
    """Missing file blocks the security audit; high severity (matches
    watcher) because governance still cannot review absent code.
    """
    return common.check_artifact_exists(
        artifact,
        missing_finding=_missing_artifact_finding(artifact),
    )


def _check_artifact_non_empty(artifact: str) -> common.CheckOutcome:
    """Empty source/config files in a security audit are mostly noise;
    flag at ``low`` (diverges from watcher's ``medium`` because a
    single blank file should not promote the verdict to ``warn``).
    """
    return common.check_artifact_non_empty(
        artifact,
        empty_finding=_empty_artifact_finding(artifact),
        race_finding=_race_finding(artifact),
    )


def _scan_secret_patterns(artifact: str, text: str) -> list[dict[str, Any]]:
    """Run the secret regex bank against ``text``; return findings.

    Each pattern can contribute multiple findings up to the per-artifact
    cap enforced by the caller. We deliberately surface ``location`` as
    ``<artifact>:<line>`` so consumers can sort / dedupe / link to a
    diff hunk without re-reading the file.
    """
    out: list[dict[str, Any]] = []
    for pattern, severity, category, desc, rec in _SECRET_PATTERNS:
        for match in pattern.finditer(text):
            line_no = text.count("\n", 0, match.start()) + 1
            out.append(
                {
                    "finding_id": None,
                    "severity": severity,
                    "category": category,
                    "location": f"{artifact}:{line_no}",
                    "description": desc,
                    "recommendation": rec,
                    "target_capability": None,
                }
            )
    return out


def _scan_risky_keywords(artifact: str, text: str) -> list[dict[str, Any]]:
    """Run the risky-keyword bank against ``text``; return findings.

    Same shape as ``_scan_secret_patterns``; kept separate so a future
    config knob (e.g., ``--disable-keyword-scan``) can flip just one
    surface without touching secret detection.
    """
    out: list[dict[str, Any]] = []
    for pattern, severity, category, desc, rec in _RISKY_KEYWORDS:
        for match in pattern.finditer(text):
            line_no = text.count("\n", 0, match.start()) + 1
            out.append(
                {
                    "finding_id": None,
                    "severity": severity,
                    "category": category,
                    "location": f"{artifact}:{line_no}",
                    "description": desc,
                    "recommendation": rec,
                    "target_capability": None,
                }
            )
    return out


def _content_check(artifact: str) -> common.CheckOutcome:
    """Combined content scan: read once, then run pattern + keyword banks.

    Returns one ``CheckOutcome`` carrying every match in
    ``extra_findings``. Capping happens at the caller so cap policy is
    visible at the runner top level rather than buried in helpers.
    """
    text, err = common.read_text_safely(Path(artifact))
    if err:
        # Treat skipped files as low-severity informational findings;
        # the runner still reports they were considered.
        return common.CheckOutcome(
            name="content_scan",
            passed=False,
            finding=_scan_skipped_finding(artifact, err),
        )
    if text is None:  # pragma: no cover — defensive guard
        return common.CheckOutcome(name="content_scan", passed=True)

    findings = _scan_secret_patterns(artifact, text)
    findings.extend(_scan_risky_keywords(artifact, text))
    return common.CheckOutcome(
        name="content_scan",
        passed=not findings,
        extra_findings=findings,
    )


# ─────────────────────────────────────────────────────────
# Runner
# ─────────────────────────────────────────────────────────


@dataclass
class SecurityGateInput:
    """Identity + audit target inputs for one security gate fire.

    Mirrors :class:`watcher_gate_runner.WatcherGateInput` so cross-rail
    callers can reuse the same identity payload shape; only
    ``produced_by`` and ``gate_subtype`` defaults differ.
    """

    gate_id: str
    checkpoint: str
    workflow_id: str
    run_id: str
    step_id: str
    project_id: str
    target_artifacts: list[str] = field(default_factory=list)
    task_id: str | None = None
    gate_subtype: str | None = "secret_scan"
    produced_by: str = "08-Security"


def run_security_gate(spec: SecurityGateInput) -> dict[str, Any]:
    """Run one security checkpoint and return the envelope dict.

    Steps mirror :func:`watcher_gate_runner.run_watcher_gate` but the
    inner check set runs the security pattern banks. Per-artifact
    finding cap (``_MAX_FINDINGS_PER_ARTIFACT``) is enforced after
    pattern scanning so callers cannot exceed envelope size budget
    by feeding in a single very dirty file.
    """
    findings: list[dict[str, Any]] = []
    has_blocking_input_error = False
    checks_executed = 0
    checks_passed = 0
    artifacts_scanned = 0
    artifacts_capped = 0

    if not spec.target_artifacts:
        has_blocking_input_error = True
        findings.append(_no_target_artifacts_finding())

    for artifact in spec.target_artifacts:
        # 1. Existence check
        outcome = _check_artifact_exists(artifact)
        checks_executed += 1
        if outcome.passed:
            checks_passed += 1
        if outcome.finding:
            findings.append(outcome.finding)
        if outcome.input_blocking:
            has_blocking_input_error = True
            continue

        # 2. Non-empty check (low-severity finding only; non-blocking)
        outcome = _check_artifact_non_empty(artifact)
        checks_executed += 1
        if outcome.passed:
            checks_passed += 1
        if outcome.finding:
            findings.append(outcome.finding)
            # Empty file → skip content scan entirely; no patterns to match.
            continue

        # 3. Content scan: secret patterns + risky keywords
        outcome = _content_check(artifact)
        checks_executed += 1
        if outcome.passed:
            checks_passed += 1
        if outcome.finding:
            findings.append(outcome.finding)
        if outcome.extra_findings:
            artifacts_scanned += 1
            capped = outcome.extra_findings[:_MAX_FINDINGS_PER_ARTIFACT]
            findings.extend(capped)
            if len(outcome.extra_findings) > _MAX_FINDINGS_PER_ARTIFACT:
                artifacts_capped += 1
                findings.append(
                    _findings_capped_finding(artifact, len(outcome.extra_findings))
                )
        else:
            artifacts_scanned += 1

    result, risk_level = common.aggregate_verdict(
        findings,
        has_blocking_input_error=has_blocking_input_error,
    )

    summary = _build_summary(spec.checkpoint, result, len(findings))

    envelope: dict[str, Any] = {
        "schema_version": 1,
        "gate_id": spec.gate_id,
        "gate_type": "security",
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
            "artifacts_scanned": artifacts_scanned,
            "artifacts_capped": artifacts_capped,
        },
    }

    if result in ("fail", "blocked"):
        envelope["fail_routing"] = _derive_fail_routing(result, findings)

    return envelope


def _build_summary(checkpoint: str, result: str, finding_count: int) -> str:
    base = f"Security checkpoint at {checkpoint!s}: result={result}"
    if finding_count:
        return f"{base}; {finding_count} finding(s) recorded."
    return f"{base}; no findings."


def _derive_fail_routing(result: str, findings: list[dict[str, Any]]) -> dict[str, Any]:
    """Pick a default fail_routing block.

    Diverges from watcher in two places:

    * For ``fail`` we default to ``halt`` (not ``escalate``) when any
      ``critical`` finding exists; secret leakage cannot be left
      pending escalation. ``high``-only failures still escalate.
    * Reasoning text references the security domain explicitly so
      consumers / log readers can tell at a glance which rail produced
      the routing recommendation.
    """
    if result == "blocked":
        return {
            "action": "halt",
            "route_back_to_step": None,
            "reason": (
                "Security gate could not run to completion (missing or empty "
                "audit surface); halt for supervisor inspection."
            ),
        }

    has_critical = any(f.get("severity") == "critical" for f in findings)
    if has_critical:
        return {
            "action": "halt",
            "route_back_to_step": None,
            "reason": (
                "Critical security finding (secret leak / private key) detected; "
                "halt the run before any downstream emit / push."
            ),
        }
    return {
        "action": "escalate",
        "route_back_to_step": None,
        "reason": (
            "Security gate surfaced high-severity findings; escalate to "
            "supervisor for routing decision (route_back vs accept)."
        ),
    }


# ─────────────────────────────────────────────────────────
# CLI helpers (called by step_runtime.py)
# ─────────────────────────────────────────────────────────


def emit_security_gate_result(
    spec: SecurityGateInput,
    output_path: Path | None = None,
) -> tuple[Path, dict[str, Any]]:
    """Run the gate, persist envelope, return (path, envelope)."""
    envelope = run_security_gate(spec)
    target = output_path or common.default_output_path(spec.step_id)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(envelope, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return target, envelope


def parse_target_artifacts(values: Iterable[str] | None) -> list[str]:
    """Re-export :func:`gate_runner_common.parse_target_artifacts`."""
    return common.parse_target_artifacts(values)
