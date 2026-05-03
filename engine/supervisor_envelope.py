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
# Failure routing resolution
# ─────────────────────────────────────────────────────────


@dataclass(frozen=True)
class XrefReport:
    """Cross-reference result between envelope.failure_routing and
    envelope.capability_graph.

    Per the P3 #6 ratification (Q2 = B), this is a separate failure
    class from drift: drift covers envelope-vs-task_constitution
    consistency, xref covers internal envelope-field consistency
    between failure_routing and capability_graph.
    """

    ok: bool
    mismatches: list[str]

    def to_dict(self) -> dict[str, Any]:
        return {"ok": self.ok, "mismatches": list(self.mismatches)}


def _capability_graph_step_ids(payload: dict[str, Any]) -> list[str] | None:
    """Best-effort extraction of step ids from envelope.capability_graph.

    Returns ``None`` when the structure is malformed enough that xref
    checking cannot proceed; callers should treat that as "schema
    validation should have caught this" and report it as an xref
    mismatch rather than raising.
    """
    graph = payload.get("capability_graph")
    if not isinstance(graph, dict):
        return None
    nodes = graph.get("nodes")
    if not isinstance(nodes, list):
        return None
    return [
        node.get("step_id")
        for node in nodes
        if isinstance(node, dict) and isinstance(node.get("step_id"), str)
    ]


def check_failure_routing_xrefs(payload: dict[str, Any]) -> XrefReport:
    """Verify failure_routing step_id references against capability_graph.

    Per the P3 #1 boundary memo §4.4 / §7 Q3 = A and the P3 #2 schema
    rationale, the envelope schema deliberately does NOT enforce
    cross-references between failure_routing and capability_graph
    nodes — schema validation is envelope-shape-only. This helper
    closes the gap by reading both sub-objects and reporting any
    dangling reference. Three classes of dangling reference are
    detected:

    1. ``failure_routing.default_route_back_to_step`` set but
       not in ``capability_graph.nodes[].step_id``. Only checked
       when ``default_action == "route_back_to"`` (the field is
       null-tolerated otherwise per the schema).
    2. ``failure_routing.overrides[].step_id`` not in graph nodes.
    3. ``failure_routing.overrides[].route_back_to_step`` set but
       not in graph nodes (only when ``on_fail == "route_back_to"``).

    Mirrors the read-only / never-raise contract of
    :func:`check_envelope_drift`: malformed input yields an
    ``ok=False`` report with descriptive mismatches rather than a
    Python exception.
    """
    mismatches: list[str] = []

    if not isinstance(payload, dict):
        return XrefReport(
            ok=False,
            mismatches=["payload is not a JSON object; cannot check xref"],
        )

    fr = payload.get("failure_routing")
    if not isinstance(fr, dict):
        return XrefReport(
            ok=False,
            mismatches=[
                "failure_routing missing or not an object; "
                "schema validation should have rejected this earlier"
            ],
        )

    step_ids = _capability_graph_step_ids(payload)
    if step_ids is None:
        return XrefReport(
            ok=False,
            mismatches=[
                "capability_graph.nodes missing or malformed; "
                "schema validation should have rejected this earlier"
            ],
        )
    valid_step_ids = set(step_ids)

    default_action = fr.get("default_action")
    default_route_back = fr.get("default_route_back_to_step")
    if default_action == "route_back_to" and default_route_back is not None:
        if default_route_back not in valid_step_ids:
            mismatches.append(
                "dangling default_route_back_to_step: "
                f"{default_route_back!r} not in capability_graph step_ids "
                f"{sorted(valid_step_ids)}"
            )

    overrides = fr.get("overrides")
    if isinstance(overrides, list):
        for idx, ov in enumerate(overrides):
            if not isinstance(ov, dict):
                continue  # schema validation owns shape errors
            ov_step_id = ov.get("step_id")
            if isinstance(ov_step_id, str) and ov_step_id not in valid_step_ids:
                mismatches.append(
                    f"dangling overrides[{idx}].step_id: "
                    f"{ov_step_id!r} not in capability_graph step_ids "
                    f"{sorted(valid_step_ids)}"
                )
            ov_on_fail = ov.get("on_fail")
            ov_route_back = ov.get("route_back_to_step")
            if (
                ov_on_fail == "route_back_to"
                and ov_route_back is not None
                and ov_route_back not in valid_step_ids
            ):
                mismatches.append(
                    f"dangling overrides[{idx}].route_back_to_step: "
                    f"{ov_route_back!r} not in capability_graph step_ids "
                    f"{sorted(valid_step_ids)}"
                )

    return XrefReport(ok=not mismatches, mismatches=mismatches)


def resolve_failure_routing(payload: dict[str, Any]) -> list[dict[str, Any]]:
    """Resolve per-step failure routing by merging defaults + overrides.

    For every node in ``envelope.capability_graph.nodes`` the resolver
    produces one entry describing the effective routing the runtime
    should apply when that step fails. Entries are aligned with the
    graph node order so callers can iterate them positionally.

    Resolution rule:

    * If a per-step override exists in ``failure_routing.overrides[]``
      whose ``step_id`` matches the node's ``step_id``, it wins:
      ``source = "override"`` and the override's
      ``on_fail`` / ``route_back_to_step`` / ``max_retries`` carry over.
    * Otherwise fall back to ``failure_routing.default_action`` plus
      ``default_route_back_to_step`` / ``default_max_retries``:
      ``source = "default"``.

    Per the P3 #6 ratification (Q1 = A) this resolver is a pure
    helper in :mod:`engine.supervisor_envelope`; it does NOT validate
    the envelope and does NOT cross-reference dangling step_ids.
    Callers that need those guarantees should run
    :func:`validate_envelope` and :func:`check_failure_routing_xrefs`
    first; the resolver is happy-path-only.

    The resolver tolerates missing optional fields (e.g. an override
    with ``on_fail == "halt"`` carries no route_back_to_step or
    max_retries) by emitting ``None`` for them — the schema already
    enforces conditional presence at the producer side.
    """
    if not isinstance(payload, dict):
        return []
    fr = payload.get("failure_routing")
    if not isinstance(fr, dict):
        return []
    step_ids = _capability_graph_step_ids(payload)
    if step_ids is None:
        return []

    overrides = fr.get("overrides")
    override_by_step: dict[str, dict[str, Any]] = {}
    if isinstance(overrides, list):
        for ov in overrides:
            if isinstance(ov, dict) and isinstance(ov.get("step_id"), str):
                override_by_step[ov["step_id"]] = ov

    default_action = fr.get("default_action")
    default_route_back = fr.get("default_route_back_to_step")
    default_max_retries = fr.get("default_max_retries")

    resolved: list[dict[str, Any]] = []
    for sid in step_ids:
        if sid is None:
            continue
        if sid in override_by_step:
            ov = override_by_step[sid]
            resolved.append({
                "step_id": sid,
                "on_fail": ov.get("on_fail"),
                "route_back_to_step": ov.get("route_back_to_step"),
                "max_retries": ov.get("max_retries"),
                "source": "override",
            })
        else:
            resolved.append({
                "step_id": sid,
                "on_fail": default_action,
                "route_back_to_step": default_route_back,
                "max_retries": default_max_retries,
                "source": "default",
            })
    return resolved


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


def _cmd_xref(args: argparse.Namespace) -> int:
    text = _read_input(args.input)
    extraction = extract_envelope(text)
    if not extraction.ok or extraction.payload is None:
        _print_json({
            "stage": "extract",
            "ok": False,
            "error": extraction.error,
        })
        return 1
    report = check_failure_routing_xrefs(extraction.payload)
    _print_json({"stage": "xref", **report.to_dict()})
    return 0 if report.ok else 1


def _cmd_resolve(args: argparse.Namespace) -> int:
    text = _read_input(args.input)
    extraction = extract_envelope(text)
    if not extraction.ok or extraction.payload is None:
        _print_json({
            "stage": "extract",
            "ok": False,
            "error": extraction.error,
        })
        return 1
    resolved = resolve_failure_routing(extraction.payload)
    _print_json({"stage": "resolve", "ok": True, "resolved": resolved})
    return 0


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

    xref = sub.add_parser(
        "xref",
        help=(
            "Extract + check failure_routing step_id references against "
            "capability_graph nodes (P3 #6 producer-side cross-reference)."
        ),
    )
    xref.add_argument("--input", default=None)
    xref.set_defaults(func=_cmd_xref)

    resolve = sub.add_parser(
        "resolve",
        help=(
            "Extract + resolve per-step failure routing by merging "
            "default_action with overrides[]; output one entry per "
            "capability_graph node."
        ),
    )
    resolve.add_argument("--input", default=None)
    resolve.set_defaults(func=_cmd_resolve)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":  # pragma: no cover - CLI entrypoint
    raise SystemExit(main())
