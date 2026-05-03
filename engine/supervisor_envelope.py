"""supervisor_envelope — Pure helpers for the Supervisor Orchestration Envelope (P3 #3).

This module provides three deterministic, side-effect-free operations
the supervisor and runtime layers will share:

1. **Fence extraction** — pull the canonical envelope JSON out of a
   markdown / free-text response delimited by
   ``<<<SUPERVISOR_ORCHESTRATION_BEGIN>>>`` /
   ``<<<SUPERVISOR_ORCHESTRATION_END>>>``. Per the P3 #1 boundary memo
   §4.1 (and Q2 = A in the P3 #3 ratification) this is the **only**
   accepted fence form: producers must emit the explicit pair so
   runtime never has to disambiguate between supervisor decision JSON
   and unrelated ```` ```json ```` code blocks the supervisor may use
   for examples.

2. **JSON-Schema validation** — verify the extracted payload against
   ``schemas/supervisor-orchestration.schema.yaml`` using the same
   jsonschema 4.x ``Draft202012Validator`` shape as
   ``engine/step_runtime.py:validate_constitution`` and
   ``engine/project_constitution_runner.py:_run_jsonschema`` so all
   three validators agree on verdict shape and error formatting.

3. **Drift check** — confirm the envelope's identity fields match
   their nested counterparts in ``task_constitution`` (task_id /
   source_request). The boundary memo §4.1 makes producers responsible
   for this; the runtime hook in P3 #4 will refuse drifted envelopes.

**Out of scope for P3 #3** (and intentionally not implemented here):

* No subprocess invocation, no I/O beyond reading the schema file
  during validation. Pure functions only.
* No write path — storage layout under
  ``~/.cap/projects/<id>/orchestrations/<stamp>/`` is owned by the
  P3 #4 / #5 commits.
* No runtime hook — callers (CLI, future runtime layer) wire these
  helpers in; this module never inserts itself anywhere.
* No producer-side prompt construction — the supervisor agent skill
  ``agent-skills/01-supervisor-agent.md`` §3.8 captures the producer
  rules; the supervisor authors envelopes itself, this module only
  reads them back.

The standalone CLI (``python -m engine.supervisor_envelope <subcommand>``)
exposes ``extract`` / ``validate`` / ``drift`` for shell smoke and
manual debugging; it deliberately does not add a "do everything" mode
because each helper has a distinct failure surface that callers should
classify on their own.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Literal

import yaml


# ─────────────────────────────────────────────────────────
# Errors
# ─────────────────────────────────────────────────────────


class SupervisorEnvelopeError(Exception):
    """Base class for envelope-helper failures.

    Distinct from the standard library exception hierarchy so callers
    can ``except SupervisorEnvelopeError`` without accidentally
    swallowing unrelated I/O / parse errors.
    """


# ─────────────────────────────────────────────────────────
# Module constants
# ─────────────────────────────────────────────────────────


_REPO_ROOT = Path(__file__).resolve().parent.parent
_DEFAULT_SCHEMA_PATH = _REPO_ROOT / "schemas" / "supervisor-orchestration.schema.yaml"

_FENCE_BEGIN = re.compile(r"^<<<SUPERVISOR_ORCHESTRATION_BEGIN>>>\s*$", re.MULTILINE)
_FENCE_END = re.compile(r"^<<<SUPERVISOR_ORCHESTRATION_END>>>\s*$", re.MULTILINE)


def resolve_schema_path(override: Path | None = None) -> Path:
    """Locate ``schemas/supervisor-orchestration.schema.yaml``.

    Defaults to the schema bundled with the cap installation that hosts
    this module so test fixtures can ``--schema-path`` an alternate
    file without monkey-patching.
    """
    if override is not None:
        return override
    return _DEFAULT_SCHEMA_PATH


# ─────────────────────────────────────────────────────────
# Fence extraction
# ─────────────────────────────────────────────────────────


@dataclass(frozen=True)
class FenceExtractionResult:
    """Outcome of pulling envelope JSON out of a free-text response.

    ``payload`` is the parsed dict when extraction + JSON parsing both
    succeed; otherwise ``None`` and ``error`` carries the human-readable
    reason. ``raw_json`` retains the still-stringified payload for
    callers that want to persist or fingerprint the literal bytes.
    """

    payload: dict[str, Any] | None
    raw_json: str | None
    error: str | None

    @property
    def ok(self) -> bool:
        return self.payload is not None and self.error is None

    def to_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "payload_present": self.payload is not None,
            "raw_json_length": len(self.raw_json) if self.raw_json else 0,
            "error": self.error,
        }


def extract_envelope(text: str) -> FenceExtractionResult:
    """Pull the canonical envelope JSON out of ``text``.

    Rules (Q2 = A in the P3 #3 ratification):

    * Exactly one matching pair of
      ``<<<SUPERVISOR_ORCHESTRATION_BEGIN>>>`` /
      ``<<<SUPERVISOR_ORCHESTRATION_END>>>`` markers must be present,
      each on its own line.
    * No ```` ```json ```` fallback. The supervisor is the conductor,
      not a passive LLM, and must use the explicit fence so runtime
      never has to guess which JSON block holds the decision.
    * The body between markers must parse as a JSON object (top-level
      mapping); arrays / scalars at the top level are rejected.

    Returns a :class:`FenceExtractionResult`; never raises for the
    normal "fence missing / malformed JSON" cases — callers branch on
    ``result.ok`` to keep the error surface uniform.
    """
    begins = list(_FENCE_BEGIN.finditer(text))
    ends = list(_FENCE_END.finditer(text))

    if not begins and not ends:
        return FenceExtractionResult(
            payload=None,
            raw_json=None,
            error=(
                "missing envelope fence: expected exactly one "
                "<<<SUPERVISOR_ORCHESTRATION_BEGIN>>> ... "
                "<<<SUPERVISOR_ORCHESTRATION_END>>> pair"
            ),
        )
    if len(begins) != 1 or len(ends) != 1:
        return FenceExtractionResult(
            payload=None,
            raw_json=None,
            error=(
                f"unbalanced envelope fences: expected exactly one pair, "
                f"got begin={len(begins)}, end={len(ends)}"
            ),
        )
    begin_match = begins[0]
    end_match = ends[0]
    if end_match.start() <= begin_match.end():
        return FenceExtractionResult(
            payload=None,
            raw_json=None,
            error=(
                "envelope fences in wrong order: END marker must follow "
                "BEGIN marker"
            ),
        )

    raw = text[begin_match.end():end_match.start()].strip()
    if not raw:
        return FenceExtractionResult(
            payload=None,
            raw_json=None,
            error="envelope body between fences is empty",
        )

    try:
        loaded = json.loads(raw)
    except json.JSONDecodeError as exc:
        return FenceExtractionResult(
            payload=None,
            raw_json=raw,
            error=f"envelope JSON parse error: {exc}",
        )
    if not isinstance(loaded, dict):
        return FenceExtractionResult(
            payload=None,
            raw_json=raw,
            error=(
                "envelope JSON must be an object at the top level; "
                f"got {type(loaded).__name__}"
            ),
        )
    return FenceExtractionResult(payload=loaded, raw_json=raw, error=None)


# ─────────────────────────────────────────────────────────
# Validation
# ─────────────────────────────────────────────────────────


@dataclass(frozen=True)
class ValidationVerdict:
    ok: bool
    errors: list[str]
    schema_path: str
    validator: Literal["jsonschema", "fallback_required_only"]

    def to_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "errors": list(self.errors),
            "schema_path": self.schema_path,
            "validator": self.validator,
        }


def validate_envelope(
    payload: Any,
    schema_path: Path | None = None,
) -> ValidationVerdict:
    """Validate ``payload`` against the supervisor-orchestration schema.

    Mirrors :func:`engine.project_constitution_runner._run_jsonschema`
    so all CAP validators agree on verdict shape:

    * Schema YAML loaded with PyYAML.
    * jsonschema 4.x ``Draft202012Validator`` preferred; fallback to a
      required-only check when jsonschema is absent (matches
      ``engine/step_runtime.py:validate_constitution`` parity).
    * Errors surface as ``"<path>: <message>"`` sorted by absolute
      path so repeated runs produce stable diffs.
    """
    sp = resolve_schema_path(schema_path)
    if not sp.is_file():
        return ValidationVerdict(
            ok=False,
            errors=[f"schema file not found: {sp}"],
            schema_path=str(sp),
            validator="jsonschema",
        )
    try:
        schema = yaml.safe_load(sp.read_text(encoding="utf-8")) or {}
    except (OSError, yaml.YAMLError) as exc:
        return ValidationVerdict(
            ok=False,
            errors=[f"schema YAML parse error: {exc}"],
            schema_path=str(sp),
            validator="jsonschema",
        )

    errors: list[str] = []
    try:
        from jsonschema import Draft202012Validator  # type: ignore[import]

        validator_obj = Draft202012Validator(schema)
        for err in sorted(
            validator_obj.iter_errors(payload),
            key=lambda e: list(e.absolute_path),
        ):
            loc = "/".join(str(p) for p in err.absolute_path) or "<root>"
            errors.append(f"{loc}: {err.message}")
        which: Literal["jsonschema", "fallback_required_only"] = "jsonschema"
    except ImportError:
        which = "fallback_required_only"
        if not isinstance(payload, dict):
            errors.append("<root>: payload must be a JSON object")
        else:
            for key in schema.get("required") or []:
                if key not in payload:
                    errors.append(f"<root>: missing required field '{key}'")

    return ValidationVerdict(
        ok=not errors,
        errors=errors,
        schema_path=str(sp),
        validator=which,
    )


# ─────────────────────────────────────────────────────────
# Drift check
# ─────────────────────────────────────────────────────────


@dataclass(frozen=True)
class DriftReport:
    ok: bool
    mismatches: list[str]

    def to_dict(self) -> dict[str, Any]:
        return {"ok": self.ok, "mismatches": list(self.mismatches)}


def check_envelope_drift(payload: dict[str, Any]) -> DriftReport:
    """Verify envelope identity fields match their nested counterparts.

    Per the P3 #1 boundary memo §4.1, producers must guarantee:

    * ``payload["task_id"] == payload["task_constitution"]["task_id"]``
    * ``payload["source_request"] == payload["task_constitution"]["source_request"]``

    Drift is the canonical "supervisor changed its mind mid-fence"
    failure mode the runtime hook in P3 #4 will halt on. This helper
    reports it without enforcing — callers decide whether to halt,
    re-roll, or escalate.

    Both checks tolerate missing nested fields gracefully: a missing
    ``task_constitution`` or missing nested key is reported as a drift
    rather than raising, since the validation step is responsible for
    the strict required-field enforcement.
    """
    mismatches: list[str] = []

    if not isinstance(payload, dict):
        return DriftReport(
            ok=False,
            mismatches=["payload is not a JSON object; cannot check drift"],
        )

    tc = payload.get("task_constitution")
    if not isinstance(tc, dict):
        return DriftReport(
            ok=False,
            mismatches=[
                "task_constitution missing or not an object; "
                "schema validation should have rejected this earlier"
            ],
        )

    envelope_task_id = payload.get("task_id")
    nested_task_id = tc.get("task_id")
    if envelope_task_id != nested_task_id:
        mismatches.append(
            f"task_id drift: envelope={envelope_task_id!r} vs "
            f"task_constitution.task_id={nested_task_id!r}"
        )

    envelope_source = payload.get("source_request")
    nested_source = tc.get("source_request")
    if envelope_source != nested_source:
        mismatches.append(
            f"source_request drift: envelope={envelope_source!r} vs "
            f"task_constitution.source_request={nested_source!r}"
        )

    return DriftReport(ok=not mismatches, mismatches=mismatches)


# ─────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────


def _read_input(source: str | None) -> str:
    """Read CLI input from stdin (when source is None or '-') or a file."""
    if source is None or source == "-":
        return sys.stdin.read()
    return Path(source).read_text(encoding="utf-8")


def _print_json(obj: Any) -> None:
    sys.stdout.write(json.dumps(obj, indent=2, ensure_ascii=False) + "\n")


def _cmd_extract(args: argparse.Namespace) -> int:
    text = _read_input(args.input)
    result = extract_envelope(text)
    _print_json(result.to_dict())
    return 0 if result.ok else 1


def _cmd_validate(args: argparse.Namespace) -> int:
    text = _read_input(args.input)
    extraction = extract_envelope(text)
    if not extraction.ok or extraction.payload is None:
        _print_json({
            "stage": "extract",
            "ok": False,
            "error": extraction.error,
        })
        return 1
    verdict = validate_envelope(extraction.payload, args.schema_path)
    _print_json({
        "stage": "validate",
        **verdict.to_dict(),
    })
    return 0 if verdict.ok else 1


def _cmd_drift(args: argparse.Namespace) -> int:
    text = _read_input(args.input)
    extraction = extract_envelope(text)
    if not extraction.ok or extraction.payload is None:
        _print_json({
            "stage": "extract",
            "ok": False,
            "error": extraction.error,
        })
        return 1
    report = check_envelope_drift(extraction.payload)
    _print_json({"stage": "drift", **report.to_dict()})
    return 0 if report.ok else 1


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m engine.supervisor_envelope",
        description=(
            "Pure helpers for the Supervisor Orchestration Envelope: "
            "fence extraction, JSON-Schema validation, and "
            "task_id / source_request drift detection. No I/O beyond "
            "reading the schema; never spawns subprocesses."
        ),
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    extract = sub.add_parser(
        "extract",
        help="Extract the envelope JSON from supervisor stdout / a file.",
    )
    extract.add_argument(
        "--input",
        default=None,
        help="Path to the input file; '-' or omitted means stdin.",
    )
    extract.set_defaults(func=_cmd_extract)

    validate = sub.add_parser(
        "validate",
        help=(
            "Extract + validate against "
            "schemas/supervisor-orchestration.schema.yaml."
        ),
    )
    validate.add_argument("--input", default=None)
    validate.add_argument(
        "--schema-path",
        type=Path,
        default=None,
        help=(
            "Override the schema file (default: bundled "
            "schemas/supervisor-orchestration.schema.yaml)."
        ),
    )
    validate.set_defaults(func=_cmd_validate)

    drift = sub.add_parser(
        "drift",
        help=(
            "Extract + check envelope.task_id / source_request match "
            "their task_constitution counterparts."
        ),
    )
    drift.add_argument("--input", default=None)
    drift.set_defaults(func=_cmd_drift)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":  # pragma: no cover - CLI entrypoint
    raise SystemExit(main())
