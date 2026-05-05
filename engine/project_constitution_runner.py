"""project_constitution_runner — Runner for ``cap project constitution`` (P2 #2).

This module owns the Project Constitution runner introduced in P2 #2 and
landed across two commits:

* **Commit 1** — pure value computation: dataclasses for the request /
  result, ``project_id`` resolution from ``.cap.project.yaml``, canonical
  snapshot directory under
  ``<cap_home>/projects/<id>/constitutions/project/<stamp>/``, fixed
  four-part artifact filenames, and a ``plan()`` entry point that never
  touches disk.
* **Commit 2 (this revision)** — implements ``run()`` end-to-end:
  ``--from-file`` ingestion (JSON or YAML, normalised to JSON), runner-owned
  jsonschema validation against
  ``schemas/project-constitution.schema.yaml``, four-part snapshot write,
  and a subprocess wrap of ``cap workflow run project-constitution`` for
  the prompt path. Failure semantics follow P2 #2-b sub-decision A: when
  validation fails the runner still writes all four artefacts (so doctor /
  status can observe partial state), records ``status: failed`` in
  ``validation.json``, returns a result with ``status="failed"`` and exits
  with code 1. The standalone CLI moves ``--dry-run`` from a hard gate to
  a preview-only flag (it now invokes ``plan()``).

Out of scope, deferred to follow-up commits:

* Promote behaviour (``--promote`` / writing back to ``.cap.constitution.yaml``)
  lands in P2 #5.
* Prompt-mode end-to-end smoke (real workflow + AI agent) is verified
  manually for now and gets an integration test in P2 #8 per the Q1
  ratification.

Design references:

* Boundary memo: ``docs/cap/CONSTITUTION-BOUNDARY.md`` (P2 #1).
* Stamp format: aligned with ``scripts/workflows/persist-constitution.sh``
  which uses ``date -u '+%Y%m%dT%H%M%SZ'`` — sub-decision A in the P2 #2
  ratification. We keep the same shape (``YYYYMMDDTHHMMSSZ``) so an operator
  can correlate runner snapshots with the legacy flat-file snapshots written
  by the workflow step.
* Storage layout: per ``policies/cap-storage-metadata.md`` §1, runtime stores
  under ``~/.cap/projects/<id>/``; the new ``constitutions/project/<stamp>/``
  sub-tree is the P2 #1 §4.5 boundary so Project Constitution snapshots stop
  sharing a flat directory with Task Constitution snapshots.
* Validator parity: jsonschema invocation mirrors
  ``engine.step_runtime.validate_constitution`` (Draft 2020-12 with a
  required-only fallback for degraded environments) so workflow-side and
  runner-side validation produce the same verdict.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Literal

import yaml


# ─────────────────────────────────────────────────────────
# Errors
# ─────────────────────────────────────────────────────────


class ProjectConstitutionRunnerError(Exception):
    """Base class for runner-level failures.

    We deliberately do not subclass ``ValueError`` / ``OSError`` so callers
    can ``except ProjectConstitutionRunnerError`` without accidentally
    swallowing unrelated exceptions from the standard library.
    """


# ─────────────────────────────────────────────────────────
# Pure value helpers
# ─────────────────────────────────────────────────────────


_STAMP_FMT = "%Y%m%dT%H%M%SZ"
_STAMP_RE = re.compile(r"^\d{8}T\d{6}Z$")

# Aligned with cap-paths.sh sanitize_project_id and cap-project.sh init.
_PROJECT_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")


RunMode = Literal["prompt", "from_file", "promote"]
RunStatus = Literal["planned", "ok", "failed"]


def compute_stamp(now: datetime.datetime | None = None) -> str:
    """Return the canonical ``YYYYMMDDTHHMMSSZ`` UTC stamp.

    Mirrors ``scripts/workflows/persist-constitution.sh``'s
    ``date -u '+%Y%m%dT%H%M%SZ'`` so a runner snapshot directory and a
    workflow snapshot file can share the same stamp lexicographically.
    """
    if now is None:
        now = datetime.datetime.now(datetime.timezone.utc)
    if now.tzinfo is None:
        # Treat naive datetimes as UTC; never silently apply local zone.
        now = now.replace(tzinfo=datetime.timezone.utc)
    else:
        now = now.astimezone(datetime.timezone.utc)
    return now.strftime(_STAMP_FMT)


def is_valid_stamp(value: str) -> bool:
    return bool(_STAMP_RE.match(value))


def resolve_cap_home(override: Path | None = None) -> Path:
    """Resolve the CAP storage root.

    Precedence: explicit override > ``CAP_HOME`` env > ``~/.cap``.
    """
    if override is not None:
        return override
    env_home = os.environ.get("CAP_HOME")
    if env_home:
        return Path(env_home)
    return Path.home() / ".cap"


def resolve_project_id(project_root: Path) -> str:
    """Read ``project_id`` from the project config (config namespace aware).

    Resolution order matches ``scripts/cap-paths.sh:read_project_id_from_config``:

      1. ``<project_root>/.cap/project.yaml`` (new namespace, batch 1+)
      2. ``<project_root>/.cap.project.yaml`` (legacy flat-file, still
         honored for backward compatibility)

    Raises ``ProjectConstitutionRunnerError`` if neither file exists or if
    the present file's ``project_id`` field is empty / malformed. We refuse
    to fall back to the directory basename here — the runner's contract
    requires an explicit, persisted project identity (the same contract
    ``cap project init`` enforces).
    """
    new_path = project_root / ".cap" / "project.yaml"
    legacy_path = project_root / ".cap.project.yaml"
    if new_path.is_file():
        config_path = new_path
    elif legacy_path.is_file():
        config_path = legacy_path
    else:
        raise ProjectConstitutionRunnerError(
            f"project config not found at {new_path} or {legacy_path}; "
            "run `cap project init` before invoking the constitution runner."
        )
    try:
        loaded = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        raise ProjectConstitutionRunnerError(
            f"failed to parse {config_path}: {exc}"
        ) from exc
    if not isinstance(loaded, dict):
        raise ProjectConstitutionRunnerError(
            f"{config_path} must be a YAML mapping; got {type(loaded).__name__}"
        )
    project_id = loaded.get("project_id")
    if not isinstance(project_id, str) or not project_id.strip():
        raise ProjectConstitutionRunnerError(
            f"{config_path} is missing a non-empty 'project_id' field"
        )
    project_id = project_id.strip()
    if not _PROJECT_ID_RE.match(project_id):
        raise ProjectConstitutionRunnerError(
            f"project_id {project_id!r} does not match the canonical "
            "[a-z0-9][a-z0-9._-]* shape enforced by cap-paths.sh"
        )
    return project_id


def compute_snapshot_dir(project_id: str, stamp: str, cap_home: Path) -> Path:
    """Return the canonical ``constitutions/project/<stamp>/`` directory.

    Per ``docs/cap/CONSTITUTION-BOUNDARY.md`` §4.5 the new layout is::

        <cap_home>/projects/<project_id>/constitutions/project/<stamp>/

    so Project Constitution snapshots get their own sub-tree distinct from
    legacy task snapshots that still live one level up.
    """
    if not is_valid_stamp(stamp):
        raise ProjectConstitutionRunnerError(
            f"stamp {stamp!r} does not match {_STAMP_FMT!r}"
        )
    return cap_home / "projects" / project_id / "constitutions" / "project" / stamp


# ─────────────────────────────────────────────────────────
# Dataclasses
# ─────────────────────────────────────────────────────────


@dataclass(frozen=True)
class ArtifactPaths:
    """Filesystem layout of the four-part snapshot.

    Filenames are fixed by the P2 brief (`docs/cap/CONSTITUTION-BOUNDARY.md`
    §4.5). The runner never invents extra files in this directory; downstream
    promote / inspection code can rely on this shape.
    """

    snapshot_dir: Path
    markdown: Path
    json: Path
    validation: Path
    source_prompt: Path

    @classmethod
    def under(cls, snapshot_dir: Path) -> "ArtifactPaths":
        return cls(
            snapshot_dir=snapshot_dir,
            markdown=snapshot_dir / "project-constitution.md",
            json=snapshot_dir / "project-constitution.json",
            validation=snapshot_dir / "validation.json",
            source_prompt=snapshot_dir / "source-prompt.txt",
        )

    def to_dict(self) -> dict[str, str]:
        return {
            "snapshot_dir": str(self.snapshot_dir),
            "markdown": str(self.markdown),
            "json": str(self.json),
            "validation": str(self.validation),
            "source_prompt": str(self.source_prompt),
        }


@dataclass(frozen=True)
class ProjectConstitutionRunRequest:
    """Resolved, validated input for a single runner invocation.

    All path-class fields are absolute by construction (see
    :func:`build_request`). Exactly one of ``prompt`` / ``from_file`` is set;
    ``mode`` reflects which.
    """

    mode: RunMode
    project_id: str
    project_root: Path
    cap_home: Path
    stamp: str
    snapshot_dir: Path
    artifacts: ArtifactPaths
    prompt: str | None
    from_file: Path | None
    dry_run: bool

    def to_dict(self) -> dict[str, Any]:
        return {
            "mode": self.mode,
            "project_id": self.project_id,
            "project_root": str(self.project_root),
            "cap_home": str(self.cap_home),
            "stamp": self.stamp,
            "snapshot_dir": str(self.snapshot_dir),
            "artifacts": self.artifacts.to_dict(),
            "prompt_present": self.prompt is not None,
            "from_file": str(self.from_file) if self.from_file else None,
            "dry_run": self.dry_run,
        }


@dataclass
class ProjectConstitutionRunResult:
    """Outcome of a planned or executed run.

    ``status='planned'`` is returned by :func:`plan`; ``ok`` / ``failed``
    by :func:`run`. Per P2 #2 sub-decision A a failed run still writes the
    full four-part snapshot — ``validation.json`` records the failure
    detail and ``written_paths`` lists every artefact that landed on disk
    so doctor / status can surface partial state.
    """

    request: ProjectConstitutionRunRequest
    status: RunStatus
    note: str = ""
    workflow_run_id: str | None = None
    failure_reason: str | None = None
    written_paths: list[str] = field(default_factory=list)
    validation: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "subcommand": "constitution",
            "status": self.status,
            "note": self.note,
            "workflow_run_id": self.workflow_run_id,
            "failure_reason": self.failure_reason,
            "written_paths": list(self.written_paths),
            "validation": dict(self.validation),
            "request": self.request.to_dict(),
        }

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), indent=2, ensure_ascii=False)

    def to_yaml(self) -> str:
        return yaml.safe_dump(self.to_dict(), sort_keys=False, allow_unicode=True)


# ─────────────────────────────────────────────────────────
# Builder
# ─────────────────────────────────────────────────────────


def _resolve_latest_stamp(project_id: str, cap_home: Path) -> str:
    """Pick the lexicographically newest stamp under
    ``<cap_home>/projects/<id>/constitutions/project/``.

    Stamps are zero-padded ``YYYYMMDDTHHMMSSZ`` strings, so lexicographic
    sort agrees with chronological order. Raises if the directory does not
    exist or contains no valid stamps — ``--latest`` is opt-in and we never
    silently fall back.
    """
    parent = cap_home / "projects" / project_id / "constitutions" / "project"
    if not parent.is_dir():
        raise ProjectConstitutionRunnerError(
            f"--latest: no project-constitution snapshot directory at {parent}; "
            "run `cap project constitution --prompt ...` or `--from-file ...` first."
        )
    stamps = sorted(
        p.name for p in parent.iterdir()
        if p.is_dir() and is_valid_stamp(p.name)
    )
    if not stamps:
        raise ProjectConstitutionRunnerError(
            f"--latest: no YYYYMMDDTHHMMSSZ subdirectories under {parent}; "
            "snapshot directory is empty."
        )
    return stamps[-1]


def build_request(
    *,
    project_root: Path,
    prompt: str | None = None,
    from_file: Path | None = None,
    promote: bool = False,
    promote_stamp: str | None = None,
    cap_home: Path | None = None,
    project_id_override: str | None = None,
    stamp: str | None = None,
    dry_run: bool = False,
) -> ProjectConstitutionRunRequest:
    """Resolve every input the runner needs into a frozen request.

    Validates that exactly one of ``prompt`` / ``from_file`` / ``promote``
    is provided. For ``promote`` mode either ``promote_stamp`` (explicit)
    or no stamp at all (resolve via ``_resolve_latest_stamp``) is required;
    the caller layer (CLI) is responsible for translating ``--latest`` into
    ``promote=True, promote_stamp=None``.

    All paths are returned in absolute form so the result is independent
    of subsequent ``chdir`` calls.
    """
    project_root = project_root.resolve()
    if not project_root.is_dir():
        raise ProjectConstitutionRunnerError(
            f"project_root does not exist or is not a directory: {project_root}"
        )

    sources = sum([prompt is not None, from_file is not None, bool(promote)])
    if sources == 0:
        raise ProjectConstitutionRunnerError(
            "exactly one of --prompt / --from-file / --promote / --latest "
            "must be provided"
        )
    if sources > 1:
        raise ProjectConstitutionRunnerError(
            "--prompt / --from-file / --promote are mutually exclusive"
        )

    mode: RunMode
    resolved_from_file: Path | None = None
    if prompt is not None:
        mode = "prompt"
        if not prompt.strip():
            raise ProjectConstitutionRunnerError("--prompt must not be empty")
    elif from_file is not None:
        mode = "from_file"
        resolved_from_file = from_file.resolve()
        if not resolved_from_file.is_file():
            raise ProjectConstitutionRunnerError(
                f"--from-file path does not exist or is not a regular file: "
                f"{resolved_from_file}"
            )
    else:
        mode = "promote"

    if project_id_override is not None:
        if not _PROJECT_ID_RE.match(project_id_override):
            raise ProjectConstitutionRunnerError(
                f"--project-id {project_id_override!r} does not match the "
                "canonical [a-z0-9][a-z0-9._-]* shape"
            )
        project_id = project_id_override
    else:
        project_id = resolve_project_id(project_root)

    cap_home_resolved = resolve_cap_home(cap_home).resolve() \
        if cap_home is not None else resolve_cap_home(None)
    # ``Path.resolve()`` would error on a non-existent CAP_HOME (e.g. fresh
    # machine before any run); we deliberately accept that.
    cap_home_resolved = Path(os.path.abspath(cap_home_resolved))

    if mode == "promote":
        # In promote mode the stamp identifies an *existing* snapshot dir,
        # not a new run. ``--stamp`` from the CLI is irrelevant here; we
        # honour ``promote_stamp`` (explicit) or fall back to latest.
        if promote_stamp is not None:
            if not is_valid_stamp(promote_stamp):
                raise ProjectConstitutionRunnerError(
                    f"--promote stamp {promote_stamp!r} does not match "
                    f"{_STAMP_FMT!r}"
                )
            effective_stamp = promote_stamp
        else:
            effective_stamp = _resolve_latest_stamp(project_id, cap_home_resolved)
    else:
        effective_stamp = stamp if stamp is not None else compute_stamp()
        if not is_valid_stamp(effective_stamp):
            raise ProjectConstitutionRunnerError(
                f"stamp {effective_stamp!r} does not match {_STAMP_FMT!r}"
            )

    snapshot_dir = compute_snapshot_dir(project_id, effective_stamp, cap_home_resolved)
    artifacts = ArtifactPaths.under(snapshot_dir)

    return ProjectConstitutionRunRequest(
        mode=mode,
        project_id=project_id,
        project_root=project_root,
        cap_home=cap_home_resolved,
        stamp=effective_stamp,
        snapshot_dir=snapshot_dir,
        artifacts=artifacts,
        prompt=prompt,
        from_file=resolved_from_file,
        dry_run=dry_run,
    )


# ─────────────────────────────────────────────────────────
# Plan / Run
# ─────────────────────────────────────────────────────────


def plan(request: ProjectConstitutionRunRequest) -> ProjectConstitutionRunResult:
    """Return the planned snapshot layout without touching disk.

    This is the only entry point that has a real implementation in commit 1.
    It is safe to call without ``cap project init`` having been run on a
    fresh machine — paths are computed, not created.
    """
    note_parts = [
        f"mode={request.mode}",
        f"stamp={request.stamp}",
        f"snapshot_dir={request.snapshot_dir}",
    ]
    if request.dry_run:
        note_parts.append("dry_run=true")
    return ProjectConstitutionRunResult(
        request=request,
        status="planned",
        note="; ".join(note_parts),
    )


# ─────────────────────────────────────────────────────────
# Schema location
# ─────────────────────────────────────────────────────────


_REPO_ROOT = Path(__file__).resolve().parent.parent
_DEFAULT_SCHEMA_PATH = _REPO_ROOT / "schemas" / "project-constitution.schema.yaml"
_CAP_WORKFLOW_SH = _REPO_ROOT / "scripts" / "cap-workflow.sh"


def resolve_schema_path(override: Path | None = None) -> Path:
    """Locate ``schemas/project-constitution.schema.yaml``.

    Defaults to the schema bundled with the cap installation that hosts
    this module. Tests can override via ``--schema-path``.
    """
    if override is not None:
        return override
    return _DEFAULT_SCHEMA_PATH


# ─────────────────────────────────────────────────────────
# Validation
# ─────────────────────────────────────────────────────────


@dataclass
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


def _run_jsonschema(payload: Any, schema_path: Path) -> ValidationVerdict:
    """Validate ``payload`` against the schema at ``schema_path``.

    Mirrors ``engine.step_runtime.validate_constitution`` so workflow-side
    and runner-side validation agree on the verdict shape:

    * Schema YAML is loaded with PyYAML.
    * jsonschema 4.x ``Draft202012Validator`` is preferred; when absent we
      fall back to a required-only check so the runner does not blow up
      in degraded environments (matching step_runtime parity).

    Errors are surfaced as ``"<path>: <message>"`` strings sorted by
    absolute path so output is stable across runs.
    """
    if not schema_path.is_file():
        return ValidationVerdict(
            ok=False,
            errors=[f"schema file not found: {schema_path}"],
            schema_path=str(schema_path),
            validator="jsonschema",
        )
    try:
        schema = yaml.safe_load(schema_path.read_text(encoding="utf-8")) or {}
    except (OSError, yaml.YAMLError) as exc:
        return ValidationVerdict(
            ok=False,
            errors=[f"schema YAML parse error: {exc}"],
            schema_path=str(schema_path),
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
        schema_path=str(schema_path),
        validator=which,
    )


# ─────────────────────────────────────────────────────────
# from_file ingestion
# ─────────────────────────────────────────────────────────


def _load_from_file(path: Path) -> dict[str, Any]:
    """Read a Project Constitution payload from disk and normalise to dict.

    Per P2 #2 sub-decision A (Q3) we accept both JSON and YAML by trying
    JSON first (strict mode, surfaces structural errors precisely) and
    falling back to YAML when JSON parsing fails. The normalised dict is
    what we then schema-validate and persist as ``project-constitution.json``
    — so a YAML input is silently re-emitted as JSON inside the snapshot,
    which keeps downstream consumers free of YAML loaders.
    """
    text = path.read_text(encoding="utf-8")

    json_error: str | None = None
    try:
        loaded = json.loads(text)
    except json.JSONDecodeError as exc:
        json_error = str(exc)
        try:
            loaded = yaml.safe_load(text)
        except yaml.YAMLError as yexc:
            raise ProjectConstitutionRunnerError(
                f"--from-file payload is neither valid JSON ({json_error}) "
                f"nor valid YAML ({yexc}): {path}"
            ) from yexc

    if not isinstance(loaded, dict):
        raise ProjectConstitutionRunnerError(
            f"--from-file payload must be a mapping at top level; "
            f"got {type(loaded).__name__} from {path}"
        )
    return loaded


# ─────────────────────────────────────────────────────────
# Markdown rendering
# ─────────────────────────────────────────────────────────


_PLACEHOLDER_NOTICE_PROMPT = (
    "Generated via `cap project constitution --prompt`; the constitution "
    "JSON is canonical (see project-constitution.json)."
)
_PLACEHOLDER_NOTICE_FROM_FILE = (
    "Imported via `cap project constitution --from-file`; the constitution "
    "JSON is canonical (see project-constitution.json)."
)


def _render_placeholder_markdown(payload: dict[str, Any], notice: str) -> str:
    """Render a minimal human-readable markdown view of the constitution.

    Commit 2 ships a placeholder so the four-part snapshot is whole even
    when ``--from-file`` skipped the workflow's own markdown step. P2 #5
    promote will swap this for a richer renderer when we wire markdown
    promotion to ``docs/cap/constitution.md``.
    """
    name = payload.get("name") or payload.get("constitution_id") or "Project Constitution"
    summary = payload.get("summary") or ""
    project_id = payload.get("project_id") or "<unknown>"
    constitution_id = payload.get("constitution_id") or "<unknown>"
    lines = [
        f"# {name}",
        "",
        f"**project_id**: `{project_id}`",
        f"**constitution_id**: `{constitution_id}`",
        "",
    ]
    if summary:
        lines.append(summary)
        lines.append("")
    lines.append(f"> {notice}")
    lines.append("")
    return "\n".join(lines)


# ─────────────────────────────────────────────────────────
# Workflow wrap (prompt mode)
# ─────────────────────────────────────────────────────────


@dataclass
class WorkflowOutcome:
    exit_code: int
    stdout: str
    stderr: str
    run_dir: Path | None
    run_id: str | None
    draft_markdown_path: Path | None


_FENCE_EXPLICIT_BEGIN = re.compile(r"^<<<CONSTITUTION_JSON_BEGIN>>>\s*$", re.MULTILINE)
_FENCE_EXPLICIT_END = re.compile(r"^<<<CONSTITUTION_JSON_END>>>\s*$", re.MULTILINE)
_FENCE_JSON_BLOCK = re.compile(r"```json\s*\n(.*?)```", re.DOTALL)


def _extract_constitution_json(markdown: str) -> str | None:
    """Pull the canonical constitution JSON block out of a draft markdown.

    Mirrors the fence rules in
    ``scripts/workflows/validate-constitution.sh``: prefer the explicit
    ``<<<CONSTITUTION_JSON_BEGIN/END>>>`` pair, fall back to a single
    ```json``` fenced block. Returns the inner text or ``None`` if the
    expected fences are missing.
    """
    begin = list(_FENCE_EXPLICIT_BEGIN.finditer(markdown))
    end = list(_FENCE_EXPLICIT_END.finditer(markdown))
    if len(begin) == 1 and len(end) == 1 and end[0].start() > begin[0].end():
        return markdown[begin[0].end():end[0].start()].strip()
    json_blocks = _FENCE_JSON_BLOCK.findall(markdown)
    if len(json_blocks) == 1:
        return json_blocks[0].strip()
    return None


def _bootstrap_run_dir(cap_home: Path) -> Path:
    """Where the project-constitution workflow writes its run reports.

    The workflow forces ``CAP_PROJECT_ID_OVERRIDE=project-constitution-bootstrap``
    (see scripts/cap-workflow.sh:482-485) so its artefacts always land in
    the bootstrap project — independent of the caller's project_id.
    """
    return cap_home / "projects" / "project-constitution-bootstrap" \
        / "reports" / "workflows" / "project-constitution"


def _find_latest_run_dir(parent: Path) -> Path | None:
    if not parent.is_dir():
        return None
    candidates = [p for p in parent.iterdir() if p.is_dir() and p.name.startswith("run_")]
    if not candidates:
        return None
    candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return candidates[0]


def _find_draft_markdown(run_dir: Path) -> Path | None:
    """Locate the ``draft_constitution`` step output inside a workflow run dir.

    Workflow steps write ``<index>-<step_id>.md``; the index varies because
    bootstrap / normalize / draft / validate / persist are numbered in
    execution order. Glob for ``*-draft_constitution.md`` and pick the
    deterministic match.
    """
    matches = sorted(run_dir.glob("*-draft_constitution.md"))
    return matches[0] if matches else None


def _invoke_workflow(prompt: str, project_root: Path) -> WorkflowOutcome:
    """Run ``cap workflow run project-constitution "<prompt>"`` as a subprocess.

    We deliberately spawn the shell entrypoint instead of importing the
    workflow loader because the workflow has its own
    ``CAP_PROJECT_ID_OVERRIDE`` lifecycle plus AI-agent fan-out that we do
    not want to re-host inside the runner process. The runner only cares
    about the exit code and the run dir produced under
    ``~/.cap/projects/project-constitution-bootstrap/...``.

    Test seam: ``CAP_PROJECT_CONSTITUTION_WORKFLOW_STUB`` may point at a
    deterministic stub script that mimics cap-workflow.sh's contract
    (write ``<idx>-draft_constitution.md`` under the bootstrap project's
    run dir and exit with the desired code). Used by P2 #8 e2e fixtures
    so prompt-mode coverage does not require a real AI agent. The stub
    receives the prompt as ``$1`` and is invoked under the same ``cwd``
    so any ``CAP_HOME`` / ``CAP_STUB_*`` environment overrides apply
    consistently.
    """
    stub_override = os.environ.get("CAP_PROJECT_CONSTITUTION_WORKFLOW_STUB")
    if stub_override:
        stub_path = Path(stub_override)
        if not stub_path.is_file():
            raise ProjectConstitutionRunnerError(
                f"CAP_PROJECT_CONSTITUTION_WORKFLOW_STUB={stub_override} "
                "does not point to a regular file"
            )
        cmd = ["bash", str(stub_path), prompt]
    elif _CAP_WORKFLOW_SH.is_file():
        cmd = ["bash", str(_CAP_WORKFLOW_SH), "run", "project-constitution", prompt]
    else:
        raise ProjectConstitutionRunnerError(
            f"cap-workflow.sh not found at {_CAP_WORKFLOW_SH}; "
            "the runner must be invoked from a cap installation tree."
        )

    proc = subprocess.run(
        cmd,
        cwd=str(project_root),
        capture_output=True,
        text=True,
        check=False,
    )

    cap_home = resolve_cap_home(None)
    run_parent = _bootstrap_run_dir(cap_home)
    run_dir = _find_latest_run_dir(run_parent)
    run_id = run_dir.name if run_dir else None
    draft_md = _find_draft_markdown(run_dir) if run_dir else None

    return WorkflowOutcome(
        exit_code=proc.returncode,
        stdout=proc.stdout,
        stderr=proc.stderr,
        run_dir=run_dir,
        run_id=run_id,
        draft_markdown_path=draft_md,
    )


# ─────────────────────────────────────────────────────────
# Snapshot write
# ─────────────────────────────────────────────────────────


def _write_artifacts(
    request: ProjectConstitutionRunRequest,
    *,
    payload: dict[str, Any] | None,
    markdown: str,
    verdict: ValidationVerdict,
    source_prompt_text: str,
) -> list[str]:
    """Write the four-part snapshot under ``request.snapshot_dir``.

    Per P2 #2-b sub-decision A (Q2), we write **all four** artefacts even
    when ``verdict.ok`` is False so doctor / status can observe partial
    state. ``payload`` may be ``None`` when JSON extraction failed (e.g.
    workflow draft missing canonical fences) — in that case we still
    create a placeholder ``project-constitution.json`` containing only
    the failure context, and ``validation.json`` records why.
    """
    snapshot_dir = request.snapshot_dir
    snapshot_dir.mkdir(parents=True, exist_ok=True)

    written: list[str] = []

    # 1. project-constitution.md
    md_path = request.artifacts.markdown
    md_path.write_text(markdown, encoding="utf-8")
    written.append(str(md_path))

    # 2. project-constitution.json
    json_path = request.artifacts.json
    json_body = payload if payload is not None else {
        "_runner_note": "payload unavailable; see validation.json for why",
    }
    json_path.write_text(
        json.dumps(json_body, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    written.append(str(json_path))

    # 3. validation.json
    validation_path = request.artifacts.validation
    validation_payload: dict[str, Any] = {
        "status": "ok" if verdict.ok else "failed",
        "verdict": verdict.to_dict(),
        "stamp": request.stamp,
    }
    validation_path.write_text(
        json.dumps(validation_payload, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    written.append(str(validation_path))

    # 4. source-prompt.txt
    sp_path = request.artifacts.source_prompt
    sp_path.write_text(source_prompt_text, encoding="utf-8")
    written.append(str(sp_path))

    return written


# ─────────────────────────────────────────────────────────
# run() — end-to-end execution
# ─────────────────────────────────────────────────────────


def _run_from_file(
    request: ProjectConstitutionRunRequest,
    schema_path: Path,
) -> ProjectConstitutionRunResult:
    assert request.from_file is not None
    payload = _load_from_file(request.from_file)
    verdict = _run_jsonschema(payload, schema_path)
    markdown = _render_placeholder_markdown(payload, _PLACEHOLDER_NOTICE_FROM_FILE)
    source_prompt_text = (
        f"Imported via `cap project constitution --from-file` "
        f"from {request.from_file} at {request.stamp}.\n"
        "See project-constitution.json for the canonical content.\n"
    )
    written = _write_artifacts(
        request,
        payload=payload,
        markdown=markdown,
        verdict=verdict,
        source_prompt_text=source_prompt_text,
    )
    return ProjectConstitutionRunResult(
        request=request,
        status="ok" if verdict.ok else "failed",
        note=f"mode=from_file; validation_ok={verdict.ok}",
        failure_reason=None if verdict.ok else "; ".join(verdict.errors[:3]),
        written_paths=written,
        validation=verdict.to_dict(),
    )


def _run_prompt(
    request: ProjectConstitutionRunRequest,
    schema_path: Path,
) -> ProjectConstitutionRunResult:
    assert request.prompt is not None
    outcome = _invoke_workflow(request.prompt, request.project_root)

    payload: dict[str, Any] | None = None
    extraction_error: str | None = None
    if outcome.draft_markdown_path is not None:
        try:
            draft_md_text = outcome.draft_markdown_path.read_text(encoding="utf-8")
        except OSError as exc:
            extraction_error = f"failed to read draft markdown: {exc}"
            draft_md_text = ""
        else:
            json_text = _extract_constitution_json(draft_md_text)
            if json_text is None:
                extraction_error = (
                    "draft markdown lacks the canonical "
                    "<<<CONSTITUTION_JSON_BEGIN/END>>> fence and a single "
                    "```json``` block could not be located"
                )
            else:
                try:
                    payload = json.loads(json_text)
                except json.JSONDecodeError as exc:
                    extraction_error = f"draft constitution JSON parse error: {exc}"
    else:
        extraction_error = (
            "workflow did not produce a draft_constitution markdown "
            "artefact under the run report directory"
        )

    if payload is None:
        verdict = ValidationVerdict(
            ok=False,
            errors=[extraction_error or "unknown extraction failure"],
            schema_path=str(schema_path),
            validator="jsonschema",
        )
        markdown = (
            f"# Project Constitution (extraction failed)\n\n"
            f"> Workflow exit code: {outcome.exit_code}\n"
            f"> Reason: {extraction_error}\n"
        )
    else:
        verdict = _run_jsonschema(payload, schema_path)
        markdown = _render_placeholder_markdown(payload, _PLACEHOLDER_NOTICE_PROMPT)

    source_prompt_text = (
        f"Captured via `cap project constitution --prompt` at {request.stamp}.\n"
        f"workflow_run_id={outcome.run_id or '<missing>'}\n"
        f"workflow_exit_code={outcome.exit_code}\n"
        "----- prompt -----\n"
        f"{request.prompt}\n"
    )
    written = _write_artifacts(
        request,
        payload=payload,
        markdown=markdown,
        verdict=verdict,
        source_prompt_text=source_prompt_text,
    )

    if outcome.exit_code != 0 and verdict.ok:
        # Workflow halted but we somehow still got a valid payload — the
        # runner cannot honour that as success. Coerce to failed and
        # surface the workflow stderr as the failure reason.
        verdict = ValidationVerdict(
            ok=False,
            errors=[
                f"workflow exited with code {outcome.exit_code}",
                outcome.stderr.strip().splitlines()[-1] if outcome.stderr.strip() else "",
            ],
            schema_path=verdict.schema_path,
            validator=verdict.validator,
        )

    return ProjectConstitutionRunResult(
        request=request,
        status="ok" if verdict.ok else "failed",
        note=(
            f"mode=prompt; workflow_exit={outcome.exit_code}; "
            f"validation_ok={verdict.ok}"
        ),
        workflow_run_id=outcome.run_id,
        failure_reason=None if verdict.ok else "; ".join(
            e for e in verdict.errors[:3] if e
        ),
        written_paths=written,
        validation=verdict.to_dict(),
    )


# ─────────────────────────────────────────────────────────
# promote
# ─────────────────────────────────────────────────────────


def _promote_to_repo_ssot(
    project_root: Path,
    payload: dict[str, Any],
    backup_stamp: str,
) -> tuple[Path, Path | None]:
    """Write ``payload`` to ``<project_root>/.cap.constitution.yaml``.

    Mirrors ``scripts/workflows/persist-constitution.sh`` line 296: when
    the target already exists we copy it to
    ``<target>.backup-<backup_stamp>`` *before* overwriting so a botched
    promote can always be rolled back. ``backup_stamp`` is the runner's
    current-time stamp (not the snapshot's) to avoid same-snapshot
    re-promotes shadowing each other's backups.

    Returns ``(target_path, backup_path_or_none)``.
    """
    target = project_root / ".cap.constitution.yaml"
    backup_path: Path | None = None
    if target.exists():
        backup_path = target.parent / f"{target.name}.backup-{backup_stamp}"
        # Use copy2 so we keep the original mtime / permissions in the
        # backup; then truncate-write the new YAML over the original.
        shutil.copy2(target, backup_path)

    yaml_text = yaml.safe_dump(payload, sort_keys=False, allow_unicode=True)
    target.write_text(yaml_text, encoding="utf-8")
    return target, backup_path


def _run_promote(
    request: ProjectConstitutionRunRequest,
    schema_path: Path,
) -> ProjectConstitutionRunResult:
    """Promote a previously-written snapshot into the repo SSOT.

    Hard rules (P2 #5 ratification A/B/A):

    * The snapshot's ``project-constitution.json`` is the single source
      we read; the on-disk ``validation.json`` is *not* trusted (it could
      have been hand-edited). We re-run jsonschema before any disk write
      to the repo.
    * If validation fails we **do not** touch the repo. ``written_paths``
      stays empty and ``status='failed'``; the snapshot dir itself is
      left untouched (we only read from it).
    * If validation passes we copy any existing
      ``.cap.constitution.yaml`` to ``.backup-<TIMESTAMP>`` (current time,
      not the snapshot stamp) before writing the new YAML, matching the
      backup convention in ``scripts/workflows/persist-constitution.sh``.
    """
    snapshot_json = request.artifacts.json
    if not snapshot_json.is_file():
        raise ProjectConstitutionRunnerError(
            f"--promote: snapshot JSON not found at {snapshot_json}; "
            f"check the stamp or run --prompt / --from-file first."
        )

    try:
        payload = json.loads(snapshot_json.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ProjectConstitutionRunnerError(
            f"--promote: failed to parse snapshot JSON at {snapshot_json}: {exc}"
        ) from exc
    if not isinstance(payload, dict):
        raise ProjectConstitutionRunnerError(
            f"--promote: snapshot at {snapshot_json} is not a JSON object "
            f"(got {type(payload).__name__})"
        )

    verdict = _run_jsonschema(payload, schema_path)
    if not verdict.ok:
        # Repo SSOT untouched. The snapshot dir is also untouched — promote
        # only ever reads from it, never writes back.
        return ProjectConstitutionRunResult(
            request=request,
            status="failed",
            note=(
                f"mode=promote; stamp={request.stamp}; "
                "refused to write repo SSOT — validation failed"
            ),
            failure_reason="; ".join(e for e in verdict.errors[:3] if e),
            written_paths=[],
            validation=verdict.to_dict(),
        )

    backup_stamp = compute_stamp()
    target, backup = _promote_to_repo_ssot(
        request.project_root, payload, backup_stamp,
    )
    written = [str(target)]
    if backup is not None:
        written.append(str(backup))

    note_parts = [
        f"mode=promote",
        f"stamp={request.stamp}",
        f"target={target}",
    ]
    if backup is not None:
        note_parts.append(f"backup={backup}")

    return ProjectConstitutionRunResult(
        request=request,
        status="ok",
        note="; ".join(note_parts),
        written_paths=written,
        validation=verdict.to_dict(),
    )


def run(
    request: ProjectConstitutionRunRequest,
    *,
    schema_path: Path | None = None,
) -> ProjectConstitutionRunResult:
    """Execute the runner end-to-end.

    * ``mode='from_file'`` reads / normalises / validates / writes — fully
      deterministic, smoke-covered.
    * ``mode='prompt'`` shells out to ``cap workflow run project-constitution``,
      extracts the constitution JSON from the draft step, validates it
      against the bundled schema, and writes the four-part snapshot.
      Manual verification only at this point; an integration test is
      scheduled for P2 #8.
    * ``mode='promote'`` reads the snapshot's ``project-constitution.json``,
      re-runs jsonschema, and (only on success) writes the YAML form back
      to ``<project_root>/.cap.constitution.yaml`` after backing up any
      pre-existing repo SSOT.

    A failure (validation or extraction) still leaves all four artefacts
    on disk for ``prompt`` / ``from_file`` modes; ``promote`` mode never
    touches the repo SSOT on failure. In every case the result reports
    ``status="failed"`` and the caller is expected to map that to a
    non-zero exit code.
    """
    schema = resolve_schema_path(schema_path)
    if request.mode == "from_file":
        return _run_from_file(request, schema)
    if request.mode == "promote":
        return _run_promote(request, schema)
    return _run_prompt(request, schema)


# ─────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────


def _format_text(result: ProjectConstitutionRunResult) -> str:
    req = result.request
    lines = [
        f"status={result.status}",
        f"mode={req.mode}",
        f"project_id={req.project_id}",
        f"project_root={req.project_root}",
        f"cap_home={req.cap_home}",
        f"stamp={req.stamp}",
        f"snapshot_dir={req.snapshot_dir}",
        "artifacts:",
        f"  markdown={req.artifacts.markdown}",
        f"  json={req.artifacts.json}",
        f"  validation={req.artifacts.validation}",
        f"  source_prompt={req.artifacts.source_prompt}",
        f"dry_run={str(req.dry_run).lower()}",
    ]
    if req.from_file is not None:
        lines.append(f"from_file={req.from_file}")
    if req.prompt is not None:
        # Show only that a prompt is present plus its character count; the
        # full text is preserved by the source_prompt artifact.
        lines.append(f"prompt_chars={len(req.prompt)}")
    if result.workflow_run_id:
        lines.append(f"workflow_run_id={result.workflow_run_id}")
    if result.note:
        lines.append(f"note={result.note}")
    if result.validation:
        lines.append(
            "validation:"
            f" ok={result.validation.get('ok')}"
            f" validator={result.validation.get('validator')}"
        )
        errs = result.validation.get("errors") or []
        if errs:
            lines.append("validation_errors:")
            for e in errs[:10]:
                lines.append(f"  - {e}")
            if len(errs) > 10:
                lines.append(f"  - ... ({len(errs) - 10} more)")
    if result.failure_reason:
        lines.append(f"failure_reason={result.failure_reason}")
    if result.written_paths:
        lines.append("written_paths:")
        for p in result.written_paths:
            lines.append(f"  - {p}")
    return "\n".join(lines) + "\n"


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="cap project constitution",
        description=(
            "Generate or import a Project Constitution snapshot under "
            "<cap_home>/projects/<id>/constitutions/project/<stamp>/. "
            "Pass --dry-run to preview the planned layout without "
            "writing anything."
        ),
    )
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument(
        "--prompt",
        type=str,
        default=None,
        help=(
            "User prompt forwarded to `cap workflow run project-constitution`. "
            "Drives the AI-backed draft path."
        ),
    )
    src.add_argument(
        "--from-file",
        dest="from_file",
        type=Path,
        default=None,
        help=(
            "Pre-drafted Project Constitution JSON or YAML file. Bypasses "
            "the AI draft step; the runner just validates and persists."
        ),
    )
    src.add_argument(
        "--promote",
        type=str,
        default=None,
        metavar="STAMP",
        help=(
            "Promote the four-part snapshot at <STAMP> into "
            "<project_root>/.cap.constitution.yaml. STAMP must be a "
            "YYYYMMDDTHHMMSSZ string identifying an existing snapshot. "
            "Validation is re-run before writing; an existing repo "
            "constitution is backed up to .cap.constitution.yaml.backup-"
            "<TIMESTAMP> first."
        ),
    )
    src.add_argument(
        "--latest",
        action="store_true",
        help=(
            "Promote the most recent snapshot under "
            "<cap_home>/projects/<id>/constitutions/project/. Mutually "
            "exclusive with --prompt / --from-file / --promote; never "
            "applied implicitly."
        ),
    )
    parser.add_argument(
        "--project-root",
        type=Path,
        default=Path.cwd(),
        help="Repo root containing .cap.project.yaml (default: $PWD).",
    )
    parser.add_argument(
        "--cap-home",
        type=Path,
        default=None,
        help="Override CAP_HOME (default: $CAP_HOME or ~/.cap).",
    )
    parser.add_argument(
        "--project-id",
        type=str,
        default=None,
        help="Override the resolved project_id (skips .cap.project.yaml read).",
    )
    parser.add_argument(
        "--stamp",
        type=str,
        default=None,
        help=(
            "Force the snapshot stamp (YYYYMMDDTHHMMSSZ). Useful for tests "
            "and for re-pinning a previously aborted run."
        ),
    )
    parser.add_argument(
        "--schema-path",
        dest="schema_path",
        type=Path,
        default=None,
        help=(
            "Override the JSON Schema file for validation "
            "(default: schemas/project-constitution.schema.yaml)."
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help=(
            "Compute the snapshot layout via plan() without touching disk "
            "or invoking the workflow. Useful for previewing where a real "
            "run would write."
        ),
    )
    parser.add_argument(
        "--format",
        choices=("text", "json", "yaml"),
        default="text",
        help="Output format (default: text).",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)

    # Translate --promote / --latest into build_request kwargs. The
    # mutually-exclusive group already guarantees that at most one source
    # flag is set, so we only need to set the promote arguments.
    promote_flag = bool(args.promote) or bool(args.latest)
    promote_stamp_value: str | None = args.promote if args.promote else None

    try:
        request = build_request(
            project_root=args.project_root,
            prompt=args.prompt,
            from_file=args.from_file,
            promote=promote_flag,
            promote_stamp=promote_stamp_value,
            cap_home=args.cap_home,
            project_id_override=args.project_id,
            stamp=args.stamp,
            dry_run=args.dry_run,
        )
    except ProjectConstitutionRunnerError as exc:
        sys.stderr.write(f"cap project constitution: {exc}\n")
        return 1

    if args.dry_run:
        result = plan(request)
    else:
        try:
            result = run(request, schema_path=args.schema_path)
        except ProjectConstitutionRunnerError as exc:
            sys.stderr.write(f"cap project constitution: {exc}\n")
            return 1

    if args.format == "json":
        sys.stdout.write(result.to_json() + "\n")
    elif args.format == "yaml":
        sys.stdout.write(result.to_yaml())
    else:
        sys.stdout.write(_format_text(result))

    # Per Q2 ratification: validation failure still leaves all four
    # artefacts on disk, but the CLI surfaces the failure as exit 1 so
    # callers (cap-project.sh / CI) can branch on it.
    if result.status == "failed":
        return 1
    return 0


if __name__ == "__main__":  # pragma: no cover - CLI entrypoint
    raise SystemExit(main())
