"""Capability-aware artifact validator (P6 #5 + #6 + #7).

Provides a single entry point ``validate_capability_output(capability,
artifact_path)`` that looks up the capability in a small registry and
applies the appropriate validator (JSON schema today; Markdown
required-sections also supported as a mechanism but not registered
to any production capability yet).

Design rules:

* **Reuse, don't reinvent**: JSON schema validation delegates to
  ``engine.step_runtime.validate_jsonschema_fallback`` (the
  rc7-rc9 hardened helper supporting nested required / type / enum /
  pattern / additionalProperties / minItems / properties / items /
  type-union). No alternative schema engine is introduced here.
* **Conservative registry**: ``DEFAULT_RULES`` only includes
  capabilities whose validation rule is genuinely known and stable.
  Capabilities without a rule return ``ValidatorKind="no_validator"``
  (``ok=True``) so callers can treat them as skipped — no false
  positives by guessing rules.
* **Read-only**: never writes the artifact, never modifies registry
  state. Callers (future P6 #4 required-output enforcement, ad-hoc
  diagnostics) decide what to do with the verdict.
* **No hook into cap-workflow-exec.sh**: this batch builds the
  validator layer only. Wiring into the production executor is
  deferred to P6 #4 with an opt-in flag, sticking to the P5 baseline
  red line.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

try:
    from .step_runtime import validate_jsonschema_fallback
except ImportError:  # pragma: no cover
    from step_runtime import validate_jsonschema_fallback  # type: ignore[no-redef]


@dataclass(frozen=True)
class ValidationResult:
    """Outcome of one ``validate_capability_output`` call.

    ``validator_kind`` lets callers branch on the verdict family
    without parsing message strings:
      - ``json_schema``         JSON validated against a schema.
      - ``markdown_sections``   Markdown checked for required headers.
      - ``no_validator``        Capability has no registered rule
                                (treated as ``ok=True``, skipped).
      - ``missing_artifact``    Artifact file absent (``ok=False``).
      - ``unknown_kind``        Registry rule had an unknown ``kind``.
    """

    ok: bool
    capability: str
    artifact_path: str
    validator_kind: str
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


# Registry of known capability → validator rules.
# Keep this list small and only add capabilities whose validation
# contract is genuinely stable. Capabilities not in this map return
# kind="no_validator" — callers must treat that as "skipped", not
# "verified".
DEFAULT_RULES: dict[str, dict[str, Any]] = {
    # P2: persist-task-constitution.sh wraps the supervisor's draft;
    # the schema gate it runs internally is what we mirror here so
    # callers can validate the artifact directly without invoking the
    # shell script.
    "task_constitution_persistence": {
        "kind": "json_schema",
        "schema_path": "schemas/task-constitution.schema.yaml",
        "fence_begin": "<<<TASK_CONSTITUTION_JSON_BEGIN>>>",
        "fence_end": "<<<TASK_CONSTITUTION_JSON_END>>>",
    },
    # The planning step produces the same shape as persistence consumes
    # (it IS the artifact persistence reads). Validating both gives the
    # same verdict against the same schema.
    "task_constitution_planning": {
        "kind": "json_schema",
        "schema_path": "schemas/task-constitution.schema.yaml",
        "fence_begin": "<<<TASK_CONSTITUTION_JSON_BEGIN>>>",
        "fence_end": "<<<TASK_CONSTITUTION_JSON_END>>>",
    },
    # P3: supervisor envelope is fence-bracketed JSON; reuses the
    # supervisor-orchestration.schema.yaml that
    # validate-supervisor-envelope.sh enforces.
    "supervisor_envelope_validation": {
        "kind": "json_schema",
        "schema_path": "schemas/supervisor-orchestration.schema.yaml",
        "fence_begin": "<<<SUPERVISOR_ORCHESTRATION_BEGIN>>>",
        "fence_end": "<<<SUPERVISOR_ORCHESTRATION_END>>>",
    },
}


def extract_json_from_fence(text: str, fence_begin: str, fence_end: str) -> str | None:
    """Return the inner content between fence markers, stripping nested ```json wrappers.

    Mirrors the awk pattern in
    ``scripts/workflows/persist-task-constitution.sh`` (lines 142-149):
    fence markers MUST appear on their own line (line-anchored, optional
    trailing whitespace allowed) so an LLM that quotes the marker inside
    a prose sentence — e.g. ``以 <<<X_BEGIN>>> ... <<<X_END>>> 包裹 JSON``
    — does not get matched as the fence body. Without this anchor the
    non-greedy regex would happily lock onto the prose example and
    return ``...`` as the fence content.

    Also strips a single ```json ... ``` wrapper if the LLM nested one
    inside the outer fence (v0.21.5 nested-fence-strip behaviour).
    Returns ``None`` when no line-anchored fence pair is found.
    """
    pattern = (
        r"(?m)^" + re.escape(fence_begin) + r"[ \t]*$"
        r"\n(.*?)\n"
        r"^" + re.escape(fence_end) + r"[ \t]*$"
    )
    match = re.search(pattern, text, re.DOTALL)
    if not match:
        return None
    inner = match.group(1).strip()
    # Strip a single ```json ... ``` wrapper if the LLM nested one.
    if inner.startswith("```"):
        lines = inner.splitlines()
        if lines and lines[0].lstrip("`").strip().lower() in {"", "json"}:
            lines = lines[1:]
        if lines and lines[-1].strip() == "```":
            lines = lines[:-1]
        inner = "\n".join(lines).strip()
    return inner


def check_markdown_sections(text: str, required: list[str]) -> list[str]:
    """Return required headers that are missing from the markdown text.

    Match is line-equality after stripping (header lines like ``## Foo``
    must appear on their own line; partial matches inside paragraphs do
    not count). Empty ``required`` returns ``[]``.
    """
    if not required:
        return []
    present = {line.strip() for line in text.splitlines() if line.strip()}
    return [header for header in required if header.strip() not in present]


def validate_capability_output(
    capability: str,
    artifact_path: str | Path,
    *,
    rules: dict[str, dict[str, Any]] | None = None,
    repo_root: Path | None = None,
) -> ValidationResult:
    """Validate an artifact against the capability's registered rule.

    No registered rule → ``ok=True``, ``validator_kind="no_validator"``
    (callers should treat as skipped, not as verified).
    Missing artifact file → ``ok=False``, ``validator_kind="missing_artifact"``.
    Otherwise dispatches to the rule's validator and returns its verdict.
    """
    rule_table = rules if rules is not None else DEFAULT_RULES
    rule = rule_table.get(capability)
    if rule is None:
        return ValidationResult(
            ok=True,
            capability=capability,
            artifact_path=str(artifact_path),
            validator_kind="no_validator",
        )

    path = Path(artifact_path)
    if not path.is_file():
        return ValidationResult(
            ok=False,
            capability=capability,
            artifact_path=str(path),
            validator_kind="missing_artifact",
            errors=[f"artifact file not found: {path}"],
        )

    text = path.read_text(encoding="utf-8")
    kind = rule.get("kind")
    if kind == "json_schema":
        return _validate_json_schema_rule(capability, path, text, rule, repo_root)
    if kind == "markdown_sections":
        return _validate_markdown_sections_rule(capability, path, text, rule)
    return ValidationResult(
        ok=False,
        capability=capability,
        artifact_path=str(path),
        validator_kind="unknown_kind",
        errors=[f"unknown validator kind in rule: {kind!r}"],
    )


def _validate_json_schema_rule(
    capability: str,
    path: Path,
    text: str,
    rule: dict[str, Any],
    repo_root: Path | None,
) -> ValidationResult:
    fence_begin = rule.get("fence_begin")
    fence_end = rule.get("fence_end")
    if fence_begin and fence_end:
        json_text = extract_json_from_fence(text, fence_begin, fence_end)
        if json_text is None:
            return ValidationResult(
                ok=False,
                capability=capability,
                artifact_path=str(path),
                validator_kind="json_schema",
                errors=[
                    f"fence markers not found in artifact: "
                    f"{fence_begin} ... {fence_end}"
                ],
            )
    else:
        json_text = text

    try:
        data = json.loads(json_text)
    except json.JSONDecodeError as exc:
        return ValidationResult(
            ok=False,
            capability=capability,
            artifact_path=str(path),
            validator_kind="json_schema",
            errors=[f"PARSE_ERROR: {exc}"],
        )

    schema_rel = rule.get("schema_path")
    if not schema_rel:
        return ValidationResult(
            ok=False,
            capability=capability,
            artifact_path=str(path),
            validator_kind="json_schema",
            errors=["rule has no schema_path"],
        )
    base = repo_root or Path(__file__).resolve().parents[1]
    schema_path = base / schema_rel
    if not schema_path.is_file():
        return ValidationResult(
            ok=False,
            capability=capability,
            artifact_path=str(path),
            validator_kind="json_schema",
            errors=[f"schema file not found: {schema_path}"],
        )

    try:
        import yaml  # type: ignore[import]
    except ImportError:
        return ValidationResult(
            ok=False,
            capability=capability,
            artifact_path=str(path),
            validator_kind="json_schema",
            errors=["pyyaml is required to load capability validator schema"],
        )
    try:
        schema = yaml.safe_load(schema_path.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError as exc:
        return ValidationResult(
            ok=False,
            capability=capability,
            artifact_path=str(path),
            validator_kind="json_schema",
            errors=[f"schema YAML parse error: {exc}"],
        )

    errors = validate_jsonschema_fallback(data, schema)
    return ValidationResult(
        ok=not errors,
        capability=capability,
        artifact_path=str(path),
        validator_kind="json_schema",
        errors=errors,
    )


def _validate_markdown_sections_rule(
    capability: str,
    path: Path,
    text: str,
    rule: dict[str, Any],
) -> ValidationResult:
    required = rule.get("required_sections") or []
    missing = check_markdown_sections(text, required)
    if missing:
        return ValidationResult(
            ok=False,
            capability=capability,
            artifact_path=str(path),
            validator_kind="markdown_sections",
            errors=[f"missing required section: {header}" for header in missing],
        )
    return ValidationResult(
        ok=True,
        capability=capability,
        artifact_path=str(path),
        validator_kind="markdown_sections",
    )
