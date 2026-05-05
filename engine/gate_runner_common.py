"""gate_runner_common — Shared mechanics for P8 governance gate runners.

Extracted in v0.22.0 once the third caller (qa) landed and the
rule-of-three threshold for "shared module worth extracting" was met.
The three callers are:

* :mod:`engine.watcher_gate_runner` (P8 #1)
* :mod:`engine.security_gate_runner` (P8 #3)
* :mod:`engine.qa_gate_runner`       (P8 #4)

Boundary:

* This module hosts only the **rail-agnostic** mechanics — severity
  ranking, verdict aggregation, ISO timestamps, output path defaults,
  schema validation, the emit-then-self-validate persistence flow
  used by every CLI subcommand. Domain-specific knowledge stays in
  the per-rail modules:

    - ``*GateInput`` dataclasses (each rail has its own defaults for
      ``produced_by`` / ``gate_subtype`` / domain-specific knobs like
      ``coverage_threshold``).
    - Pattern banks (secret regexes, test summary regexes, etc.).
    - ``_build_summary`` / ``_derive_fail_routing`` (each rail picks
      its own halt-vs-escalate policy).
    - Finding text construction (description / recommendation
      wording is rail-aware on purpose).

* The mechanical check primitives (``check_artifact_exists`` and
  ``check_artifact_non_empty``) take the rail-specific finding dict
  as a parameter rather than building it inline. This keeps the text
  divergence visible at the call site (where the domain context
  lives) while still deduplicating the ``Path.exists()`` /
  ``stat().st_size`` plumbing.

* The schema-validation path uses a late import of
  ``validate_jsonschema_fallback`` from :mod:`engine.step_runtime`
  to avoid an import cycle: ``step_runtime`` imports this module
  for the validation + emit helpers, while this module needs the
  fallback only when ``jsonschema`` is missing. The late-import
  pattern matches the conventions already in
  ``capability_validator`` and ``compiled_workflow_validator``.

Refactor invariants (preserved by this commit):

* Every CLI stdout line, exit code, envelope field name, severity /
  category / risk_level / fail_routing.action enum value, and
  per-rail finding text remains byte-for-byte identical to the
  pre-refactor producers. See ``refactor(governance-gates): extract
  gate runner common helpers`` commit message for the audit.
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


# ─────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────

# Cap on read_text_safely() input size. Reports above this are almost
# certainly binary blobs or generated artefacts; surface a finding
# rather than slurp them into memory.
MAX_SCAN_BYTES = 2 * 1024 * 1024  # 2 MiB

# Severity rank used by aggregate_verdict; kept here so each rail
# operates against the same ladder. Higher rank = worse.
_SEVERITY_RANK = {"info": 0, "low": 1, "medium": 2, "high": 3, "critical": 4}


# ─────────────────────────────────────────────────────────
# Severity / verdict
# ─────────────────────────────────────────────────────────


def severity_to_risk(sev: str) -> str:
    """Map finding severity to envelope risk_level enum.

    Identity-mapping for ``low|medium|high|critical``; ``info`` and
    unknown values both fall through to ``low`` so consumers never
    see a severity that escapes the schema enum.
    """
    return {
        "info": "low",
        "low": "low",
        "medium": "medium",
        "high": "high",
        "critical": "critical",
    }.get(sev, "low")


def aggregate_verdict(
    findings: list[dict[str, Any]],
    *,
    has_blocking_input_error: bool,
) -> tuple[str, str]:
    """Pick (result, risk_level) from findings.

    Rules:
      * Any blocking input error → ``blocked`` / ``high``. The gate
        could not run cleanly so downstream MUST halt regardless of
        other findings.
      * Empty findings → ``pass`` / ``none``.
      * Any ``critical`` / ``high`` finding → ``fail`` / matching
        risk; consumer reads fail_routing for next action.
      * Any ``medium`` finding → ``warn`` / ``medium``; downstream
        MAY proceed but the finding is worth surfacing.
      * ``low`` / ``info`` only → ``pass`` / ``low``. Recorded for
        traceability without promoting verdict to warn.

    Severity rank uses the worst finding to keep output deterministic
    for tests.
    """
    if has_blocking_input_error:
        return "blocked", "high"
    if not findings:
        return "pass", "none"
    worst = max(findings, key=lambda f: _SEVERITY_RANK.get(f.get("severity", "info"), 0))
    worst_sev = worst.get("severity", "info")
    rank = _SEVERITY_RANK.get(worst_sev, 0)
    if rank >= _SEVERITY_RANK["high"]:
        return "fail", severity_to_risk(worst_sev)
    if rank == _SEVERITY_RANK["medium"]:
        return "warn", "medium"
    return "pass", "low"


# ─────────────────────────────────────────────────────────
# Time / paths / parsing
# ─────────────────────────────────────────────────────────


def now_iso() -> str:
    """ISO-8601 UTC timestamp with seconds precision.

    Explicit UTC offset keeps the artifact reproducible across
    machines (no local-tz drift) and matches the timestamps emitted
    by P3 orchestration snapshots.
    """
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def default_output_path(step_id: str) -> Path:
    """Default emit location: ``<cwd>/<step_id>.gate-result.json``.

    Callers that want to land the artifact under
    ``~/.cap/projects/<id>/runs/<run>/`` MUST pass an explicit
    output_path. This helper deliberately knows nothing about cap
    storage layout so the runners stay decoupled from
    project_context_loader.
    """
    return Path.cwd() / f"{step_id}.gate-result.json"


def default_gate_result_schema_path() -> Path:
    """Resolve the canonical gate-result schema shipped with the repo.

    Located at ``<repo>/schemas/gate-result.schema.yaml`` next to
    ``<repo>/engine/``. Used by both the validate-gate-result CLI
    (consumer side) and the per-rail emit_and_validate_or_exit flow
    (producer side).
    """
    return Path(__file__).resolve().parent.parent / "schemas" / "gate-result.schema.yaml"


def parse_target_artifacts(values: Iterable[str] | None) -> list[str]:
    """Normalize CLI repeated --target-artifact values into a list.

    argparse hands us either ``None`` (flag never used) or a list. We
    treat ``None`` and an empty list identically so the verdict
    aggregator can flag "no audit surface" consistently across rails.
    """
    if not values:
        return []
    return [v for v in values if v]


# ─────────────────────────────────────────────────────────
# Filesystem
# ─────────────────────────────────────────────────────────


def read_text_safely(path: Path) -> tuple[str | None, str | None]:
    """Read a file as text within ``MAX_SCAN_BYTES`` cap.

    Returns ``(text, error)``. On success ``error`` is ``None``;
    on failure ``text`` is ``None`` and ``error`` is a short tag
    string the caller can surface in a finding (e.g., to keep
    governance traceable when the file was skipped).
    """
    try:
        size = path.stat().st_size
    except FileNotFoundError:
        return None, "vanished_during_scan"
    if size > MAX_SCAN_BYTES:
        return None, f"file_exceeds_scan_cap:{size}_bytes"
    try:
        return path.read_text(encoding="utf-8", errors="replace"), None
    except OSError as exc:  # pragma: no cover — disk-error guard
        return None, f"read_failed:{exc}"


# ─────────────────────────────────────────────────────────
# CheckOutcome
# ─────────────────────────────────────────────────────────


@dataclass
class CheckOutcome:
    """One mechanical check's outcome.

    ``finding`` carries the single primary issue (or ``None`` for a
    clean pass). ``extra_findings`` lets content scanners surface
    multiple issues from one read of the artifact (e.g., security's
    secret + xss matches). ``input_blocking`` flags missing /
    unreadable artifacts that escalate the verdict to ``blocked``
    regardless of finding severity. ``metrics`` carries scan-local
    numeric data the runner can later aggregate into envelope
    metrics.
    """

    name: str
    passed: bool
    finding: dict[str, Any] | None = None
    input_blocking: bool = False
    extra_findings: list[dict[str, Any]] = field(default_factory=list)
    metrics: dict[str, Any] | None = None


# ─────────────────────────────────────────────────────────
# Generic check primitives
# ─────────────────────────────────────────────────────────


def check_artifact_exists(
    artifact: str,
    *,
    missing_finding: dict[str, Any],
) -> CheckOutcome:
    """Verify the target artifact exists on disk.

    Caller passes the rail-specific ``missing_finding`` dict so the
    description / recommendation wording reflects which gate is
    firing (watcher / security / qa). Returns ``input_blocking=True``
    on failure so the aggregator escalates to ``result=blocked``.
    """
    if Path(artifact).exists():
        return CheckOutcome(name="artifact_exists", passed=True)
    return CheckOutcome(
        name="artifact_exists",
        passed=False,
        input_blocking=True,
        finding=missing_finding,
    )


def check_artifact_non_empty(
    artifact: str,
    *,
    empty_finding: dict[str, Any],
    race_finding: dict[str, Any],
) -> CheckOutcome:
    """Verify the target artifact has non-zero size.

    Pre-condition: caller MUST have already confirmed existence (via
    :func:`check_artifact_exists`). The ``race_finding`` is used only
    when the file disappears between the two checks (extremely rare
    race); kept as a parameter so each rail can phrase the recovery
    advice consistently with its own domain.

    The check itself is non-blocking — empty files surface a finding
    of whatever severity the rail considers appropriate (watcher /
    qa: medium; security: low) but do not promote the verdict to
    blocked.
    """
    p = Path(artifact)
    try:
        size = p.stat().st_size
    except FileNotFoundError:  # pragma: no cover — race guard only
        return CheckOutcome(
            name="artifact_non_empty",
            passed=False,
            finding=race_finding,
        )
    if size > 0:
        return CheckOutcome(name="artifact_non_empty", passed=True)
    return CheckOutcome(
        name="artifact_non_empty",
        passed=False,
        finding=empty_finding,
    )


# ─────────────────────────────────────────────────────────
# Schema validation
# ─────────────────────────────────────────────────────────


def validate_gate_result_payload(envelope: dict[str, Any]) -> list[str]:
    """In-memory validation of a gate-result envelope.

    Returns an ordered list of human-readable error messages — empty
    list means the envelope is clean. Used by both:

      * :func:`emit_and_validate_or_exit` for producer-side double
        validation (memory + on-disk).
      * ``step_runtime.validate_gate_result_cli`` for the consumer-side
        CLI gate that downstream governance reads through.

    Uses ``jsonschema.Draft202012Validator`` when available; falls
    back to ``step_runtime.validate_jsonschema_fallback`` (late
    import) when not, matching the pattern already used in
    ``capability_validator`` and ``compiled_workflow_validator``.
    """
    schema_p = default_gate_result_schema_path()
    if not schema_p.exists():
        return [f"schema not found: {schema_p}"]

    try:
        import yaml  # type: ignore[import]

        schema = yaml.safe_load(schema_p.read_text(encoding="utf-8")) or {}
    except ImportError:
        return ["PyYAML unavailable; cannot load gate-result schema"]
    except Exception as exc:  # pragma: no cover — defensive YAML guard
        return [f"schema YAML invalid: {exc}"]

    errors: list[str] = []
    try:
        from jsonschema import Draft202012Validator  # type: ignore[import]

        validator = Draft202012Validator(schema)
        for err in sorted(validator.iter_errors(envelope), key=lambda e: list(e.absolute_path)):
            loc = "/".join(str(p) for p in err.absolute_path) or "<root>"
            errors.append(f"{loc}: {err.message}")
    except ImportError:
        # Late import to break the engine.step_runtime ↔ engine.gate_runner_common
        # import cycle; matches the convention in capability_validator.
        try:
            from .step_runtime import validate_jsonschema_fallback
        except ImportError:  # pragma: no cover — direct-script fallback
            from step_runtime import validate_jsonschema_fallback  # type: ignore[no-redef]
        errors.extend(validate_jsonschema_fallback(envelope, schema))

    return errors


# ─────────────────────────────────────────────────────────
# Emit-then-self-validate flow
# ─────────────────────────────────────────────────────────


def emit_and_validate_or_exit(
    envelope: dict[str, Any],
    *,
    step_id: str,
    output_path: str | None,
) -> None:
    """Persist the envelope to disk, double-validate, exit with proper code.

    Used by every per-rail CLI subcommand (run-watcher-gate /
    run-security-gate / run-qa-gate) after the rail has built its
    envelope dict. The flow:

      1. **Pre-write validation** — guards against producer drift.
         If the envelope this runner just built does not satisfy
         ``schemas/gate-result.schema.yaml``, write nothing and exit
         41 with ``reason=producer_envelope_invalid``. The producer
         is buggy.
      2. **Persist** to ``output_path`` (or
         ``default_output_path(step_id)`` when None). Filesystem
         errors exit 1 with ``reason=persist_failed``.
      3. **Read-back** from disk. JSON / OS errors exit 1 with
         ``reason=persist_readback_failed``. Catches truncated
         writes, encoding mishaps, etc.
      4. **Post-write validation** — guards against persistence
         drift. Mostly redundant with (1) but cheap, and the
         on-disk artifact is what consumers will read so we want
         to validate exactly that. Exit 41 with
         ``reason=gate_result_schema_invalid`` if it fails.
      5. **Success line** — print
         ``status=ok;result=<verdict>;risk=<level>;path=<file>`` and
         exit 0. The single-line shape lets shell wrappers grep for
         ``status=ok`` without reparsing JSON.

    Caller does NOT return from this function (every branch ends in
    ``sys.exit``). The intentional shape mirrors the existing
    ``validate_*_cli`` helpers in ``step_runtime``.
    """
    # 1. Pre-write validation
    pre_errors = validate_gate_result_payload(envelope)
    if pre_errors:
        joined = " | ".join(pre_errors)
        print(f"reason=producer_envelope_invalid;detail={joined}")
        sys.exit(41)

    # 2. Persist
    target = Path(output_path) if output_path else default_output_path(step_id)
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(
            json.dumps(envelope, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
    except OSError as exc:
        print(f"reason=persist_failed;detail={exc}")
        sys.exit(1)

    # 3. Read-back
    try:
        on_disk = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"reason=persist_readback_failed;detail={exc}")
        sys.exit(1)

    # 4. Post-write validation
    post_errors = validate_gate_result_payload(on_disk)
    if post_errors:
        joined = " | ".join(post_errors)
        print(f"reason=gate_result_schema_invalid;detail={joined}")
        sys.exit(41)

    # 5. Success
    print(
        f"status=ok;result={envelope['result']};risk={envelope['risk_level']};path={target}"
    )
    sys.exit(0)
