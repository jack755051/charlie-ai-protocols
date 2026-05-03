"""project_constitution_runner — Plan-only skeleton for ``cap project constitution`` (P2 #2-b commit 1).

This module is the home of the Project Constitution runner introduced in
P2 #2. It is split across two commits:

* **Commit 1 (this file)** — pure value computation. We build the dataclasses
  for the request / result, derive ``project_id`` from ``.cap.project.yaml``,
  compute the canonical snapshot directory at
  ``<cap_home>/projects/<id>/constitutions/project/<stamp>/`` and the four
  artifact paths inside it, and expose a ``plan()`` entry point that returns
  the planned layout without touching disk or invoking the workflow runtime.
  The standalone CLI is gated behind ``--dry-run`` so an accidental invocation
  never half-writes a snapshot.
* **Commit 2 (follow-up)** — wire ``run()`` to subprocess
  ``cap workflow run project-constitution``, copy the produced artefacts into
  the snapshot dir, run the JSON Schema validator from
  ``schemas/project-constitution.schema.yaml``, and add the ``--from-file``
  ingestion path. The dispatcher hook in ``scripts/cap-project.sh`` and the
  smoke tests in ``tests/scripts/`` also land in commit 2.

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
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
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


RunMode = Literal["prompt", "from_file"]
RunStatus = Literal["planned", "not_implemented"]


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
    """Read ``project_id`` from ``<project_root>/.cap.project.yaml``.

    Raises ``ProjectConstitutionRunnerError`` if the config is missing or
    the field is empty / malformed. We refuse to fall back to the directory
    basename here — the runner's contract requires an explicit, persisted
    project identity (the same contract ``cap project init`` enforces).
    """
    config_path = project_root / ".cap.project.yaml"
    if not config_path.is_file():
        raise ProjectConstitutionRunnerError(
            f".cap.project.yaml not found at {config_path}; "
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

    In commit 1 we only return ``status='planned'``. Commit 2 will add
    ``ok`` / ``failed`` once the workflow wrapper and validator land.
    Per sub-decision A in P2 #2 a failed run still yields a populated
    ``artifacts`` block (with ``validation.json`` recording the failure)
    so the doctor command can surface partial state — but that disk write
    is commit 2 territory.
    """

    request: ProjectConstitutionRunRequest
    status: RunStatus
    note: str = ""
    workflow_run_id: str | None = None
    failure_reason: str | None = None
    written_paths: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "subcommand": "constitution",
            "status": self.status,
            "note": self.note,
            "workflow_run_id": self.workflow_run_id,
            "failure_reason": self.failure_reason,
            "written_paths": list(self.written_paths),
            "request": self.request.to_dict(),
        }

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), indent=2, ensure_ascii=False)

    def to_yaml(self) -> str:
        return yaml.safe_dump(self.to_dict(), sort_keys=False, allow_unicode=True)


# ─────────────────────────────────────────────────────────
# Builder
# ─────────────────────────────────────────────────────────


def build_request(
    *,
    project_root: Path,
    prompt: str | None = None,
    from_file: Path | None = None,
    cap_home: Path | None = None,
    project_id_override: str | None = None,
    stamp: str | None = None,
    dry_run: bool = False,
) -> ProjectConstitutionRunRequest:
    """Resolve every input the runner needs into a frozen request.

    Validates that exactly one of ``prompt`` / ``from_file`` is provided.
    All paths are returned in absolute form so the result is independent
    of subsequent ``chdir`` calls.
    """
    project_root = project_root.resolve()
    if not project_root.is_dir():
        raise ProjectConstitutionRunnerError(
            f"project_root does not exist or is not a directory: {project_root}"
        )

    if prompt is None and from_file is None:
        raise ProjectConstitutionRunnerError(
            "either --prompt or --from-file must be provided"
        )
    if prompt is not None and from_file is not None:
        raise ProjectConstitutionRunnerError(
            "--prompt and --from-file are mutually exclusive"
        )

    mode: RunMode
    resolved_from_file: Path | None = None
    if prompt is not None:
        mode = "prompt"
        if not prompt.strip():
            raise ProjectConstitutionRunnerError("--prompt must not be empty")
    else:
        mode = "from_file"
        assert from_file is not None
        resolved_from_file = from_file.resolve()
        if not resolved_from_file.is_file():
            raise ProjectConstitutionRunnerError(
                f"--from-file path does not exist or is not a regular file: "
                f"{resolved_from_file}"
            )

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
    # machine before any run); we deliberately accept that — commit 2 will
    # mkdir on first run, commit 1 just records the intended path.
    cap_home_resolved = Path(os.path.abspath(cap_home_resolved))

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


def run(request: ProjectConstitutionRunRequest) -> ProjectConstitutionRunResult:
    """Execute the runner end-to-end.

    Not implemented in commit 1. The follow-up commit will subprocess
    ``cap workflow run project-constitution`` for ``mode='prompt'``,
    schema-validate the ``mode='from_file'`` payload, write the four-part
    snapshot under ``request.snapshot_dir`` and update
    ``.cap.constitution.yaml`` only when ``--promote`` is added in P2 #5.
    """
    raise NotImplementedError(
        "run() is intentionally unimplemented in P2 #2-b commit 1; "
        "artifact write and schema validation land in the follow-up commit. "
        "Pass --dry-run to inspect the planned layout."
    )


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
        # full text is preserved by the source_prompt artifact (commit 2).
        lines.append(f"prompt_chars={len(req.prompt)}")
    if result.note:
        lines.append(f"note={result.note}")
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
            "Plan-only runner for Project Constitution snapshot layout. "
            "P2 #2-b commit 1 only implements --dry-run; actual run "
            "(workflow wrap + four-part write + jsonschema validation) "
            "lands in the follow-up commit."
        ),
    )
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument(
        "--prompt",
        type=str,
        default=None,
        help="User prompt fed to the project-constitution workflow.",
    )
    src.add_argument(
        "--from-file",
        dest="from_file",
        type=Path,
        default=None,
        help=(
            "Pre-drafted Project Constitution JSON / YAML file. Bypasses "
            "the AI draft step (commit 2)."
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
        "--dry-run",
        action="store_true",
        help=(
            "Required in commit 1. Computes the snapshot layout without "
            "writing anything. Commit 2 will make the default mode an actual "
            "run and keep --dry-run for preview."
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

    # Commit 1 hard-gates execution behind --dry-run so a follow-up branch
    # cannot accidentally take a half-implemented runner into production.
    if not args.dry_run:
        sys.stderr.write(
            "cap project constitution: --dry-run is required in P2 #2-b commit 1; "
            "the actual run path (workflow wrap + four-part write + validator) "
            "lands in the follow-up commit. See "
            "docs/cap/CONSTITUTION-BOUNDARY.md §6 for the P2 split.\n"
        )
        return 2

    try:
        request = build_request(
            project_root=args.project_root,
            prompt=args.prompt,
            from_file=args.from_file,
            cap_home=args.cap_home,
            project_id_override=args.project_id,
            stamp=args.stamp,
            dry_run=args.dry_run,
        )
    except ProjectConstitutionRunnerError as exc:
        sys.stderr.write(f"cap project constitution: {exc}\n")
        return 1

    result = plan(request)

    if args.format == "json":
        sys.stdout.write(result.to_json() + "\n")
    elif args.format == "yaml":
        sys.stdout.write(result.to_yaml())
    else:
        sys.stdout.write(_format_text(result))
    return 0


if __name__ == "__main__":  # pragma: no cover - CLI entrypoint
    raise SystemExit(main())
