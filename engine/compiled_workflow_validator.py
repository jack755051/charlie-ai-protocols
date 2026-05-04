"""Schema validation helper for compiled workflows.

Single source of truth for ``schemas/compiled-workflow.schema.yaml``
validation called from inside the Python compile path
(``engine/task_scoped_compiler.py``) and the CLI entry
(``engine/workflow_cli.py::cmd_compile_json``).

Mirrors the loader convention in ``engine/step_runtime.py::validate_constitution``:

* Prefer ``jsonschema.Draft202012Validator`` when the package is
  installed; otherwise delegate to ``step_runtime.validate_jsonschema_fallback``
  so degraded environments still get a recursive (nested) verdict that
  matches what ``validate-jsonschema`` produces from the shell side.
* Schema YAML is loaded once per process and cached in-module —
  callers can pass ``schema_path`` to override (used by tests).
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

try:
    from .step_runtime import validate_jsonschema_fallback
except ImportError:  # pragma: no cover
    from step_runtime import validate_jsonschema_fallback  # type: ignore[no-redef]

DEFAULT_SCHEMA_PATH = (
    Path(__file__).resolve().parents[1] / "schemas" / "compiled-workflow.schema.yaml"
)


class CompiledWorkflowSchemaError(Exception):
    """Raised when a compiled workflow fails ``compiled-workflow.schema.yaml``.

    The ``stage`` attribute records which validation point caught it so
    callers (CLI, tests, future runtime hooks) can branch deterministically
    on producer (``post_build``) vs. transform (``post_unresolved_policy``)
    failures without re-parsing the message.
    """

    def __init__(self, message: str, *, stage: str, errors: list[str]) -> None:
        super().__init__(message)
        self.stage = stage
        self.errors = list(errors)


@dataclass(frozen=True)
class CompiledWorkflowVerdict:
    ok: bool
    errors: list[str]
    stage: str


_SCHEMA_CACHE: dict[str, Any] = {}


def _load_schema(schema_path: Path | None = None) -> dict:
    path = Path(schema_path) if schema_path is not None else DEFAULT_SCHEMA_PATH
    cache_key = str(path.resolve())
    cached = _SCHEMA_CACHE.get(cache_key)
    if cached is not None:
        return cached

    try:
        import yaml  # type: ignore[import]
    except ImportError as exc:
        raise CompiledWorkflowSchemaError(
            "pyyaml is required to load compiled-workflow schema",
            stage="loader",
            errors=[f"pyyaml import failed: {exc}"],
        )

    if not path.is_file():
        raise CompiledWorkflowSchemaError(
            f"compiled-workflow schema not found: {path}",
            stage="loader",
            errors=[f"schema file not found: {path}"],
        )

    with path.open("r", encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}

    _SCHEMA_CACHE[cache_key] = data
    return data


def validate_compiled_workflow(
    data: dict,
    *,
    stage: str,
    schema_path: Path | None = None,
) -> CompiledWorkflowVerdict:
    """Return a verdict; never raises on schema failures.

    ``stage`` labels where in the compile pipeline the validation fired
    (``post_build`` / ``post_unresolved_policy`` / ``cli_compile_json`` etc.)
    so downstream consumers can route on producer- vs. transform-stage
    failures.
    """
    schema = _load_schema(schema_path)
    errors: list[str] = []

    try:
        from jsonschema import Draft202012Validator  # type: ignore[import]

        validator = Draft202012Validator(schema)
        for err in sorted(
            validator.iter_errors(data), key=lambda e: list(e.absolute_path)
        ):
            loc = "/".join(str(p) for p in err.absolute_path) or "<root>"
            errors.append(f"{loc}: {err.message}")
    except ImportError:
        errors.extend(validate_jsonschema_fallback(data, schema))

    return CompiledWorkflowVerdict(ok=not errors, errors=errors, stage=stage)


def ensure_valid_compiled_workflow(
    data: dict,
    *,
    stage: str,
    schema_path: Path | None = None,
) -> None:
    """Raise ``CompiledWorkflowSchemaError`` if the data fails the schema gate."""
    verdict = validate_compiled_workflow(data, stage=stage, schema_path=schema_path)
    if verdict.ok:
        return
    head = "; ".join(verdict.errors[:5])
    raise CompiledWorkflowSchemaError(
        f"compiled workflow failed schema validation at stage '{stage}': {head}",
        stage=stage,
        errors=verdict.errors,
    )


