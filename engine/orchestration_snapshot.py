"""orchestration_snapshot — Pure four-part snapshot writer for the Supervisor Orchestration Envelope (P3 #5-a).

This module owns the storage half of the envelope lifecycle: given an
already-validated envelope payload, an already-formed validation report,
and a source prompt, write the four canonical artefacts under
``~/.cap/projects/<project_id>/orchestrations/<stamp>/``.

Per the P3 #5 boundary memo (`docs/cap/ORCHESTRATION-STORAGE-BOUNDARY.md`)
§4.1 / §4.2 ratification (Q1 / Q2 / Q3 = A/A/A):

* **Symmetric to P2** — the four filenames and the parent directory
  shape mirror ``constitutions/project/<stamp>/`` byte-for-byte
  (``envelope.json`` / ``envelope.md`` / ``validation.json`` /
  ``source-prompt.txt``). Stamp format is ``YYYYMMDDTHHMMSSZ``,
  the same shape every other CAP runtime artefact uses.
* **Validation failure still lands the four artefacts** — Q1 = A.
  ``validation.json`` records ``status: "failed"`` plus the full
  verdict / drift detail; the other three artefacts still land on
  disk so doctor / status can observe partial state.
* **Pure writer** — this module never re-runs jsonschema and never
  re-extracts the fence. The caller is expected to feed in the
  ``envelope_payload`` (extracted dict or a ``None`` fallback) and
  the ``validation_report`` it already produced (typically via
  :mod:`engine.supervisor_envelope`). Re-validating here would be a
  dual-write hazard: two validators can disagree across versions.
* **No runtime hook**, **no compile/bind change**, **no workflow YAML
  wiring** — those land in P3 #5-b / #5-c. This commit only adds the
  module + smoke fixture; nobody calls it from a workflow yet.

The standalone CLI (``python -m engine.orchestration_snapshot write``)
glues fence extraction / validation / drift (delegated to
:mod:`engine.supervisor_envelope`) to :func:`write_snapshot`, mirroring
the schema-class executor's exit-41 contract: exit 0 when extraction +
schema + drift all pass; exit 41 when any of them fails — but the
four-part snapshot still lands either way per Q1 = A.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

import yaml


# ─────────────────────────────────────────────────────────
# Errors
# ─────────────────────────────────────────────────────────


class OrchestrationSnapshotError(Exception):
    """Base class for storage-writer-level failures.

    Distinct from ``ProjectConstitutionRunnerError`` so callers can
    distinguish "envelope snapshot writer reported a problem" from
    "Project Constitution runner reported a problem"; the two helpers
    have parallel shapes but separate exception trees keeps the boundary
    memo §4.4 legacy compatibility argument auditable.
    """


# ─────────────────────────────────────────────────────────
# Module constants
# ─────────────────────────────────────────────────────────


_REPO_ROOT = Path(__file__).resolve().parent.parent

_STAMP_FMT = "%Y%m%dT%H%M%SZ"
_STAMP_RE = re.compile(r"^\d{8}T\d{6}Z$")

# Aligned with cap-paths.sh sanitize_project_id and engine/project_constitution_runner.py.
_PROJECT_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")


SnapshotStatus = Literal["ok", "failed"]


def compute_stamp(now: datetime.datetime | None = None) -> str:
    """Return the canonical ``YYYYMMDDTHHMMSSZ`` UTC stamp.

    Same generator semantics as
    :func:`engine.project_constitution_runner.compute_stamp` so an
    envelope snapshot and a project constitution snapshot taken in the
    same second sort consistently across the two storage trees.
    """
    if now is None:
        now = datetime.datetime.now(datetime.timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=datetime.timezone.utc)
    else:
        now = now.astimezone(datetime.timezone.utc)
    return now.strftime(_STAMP_FMT)


def is_valid_stamp(value: str) -> bool:
    return bool(_STAMP_RE.match(value))


def resolve_cap_home(override: Path | None = None) -> Path:
    """Resolve the CAP storage root.

    Precedence: explicit override > ``CAP_HOME`` env > ``~/.cap``.
    Mirrors :func:`engine.project_constitution_runner.resolve_cap_home`.
    """
    if override is not None:
        return override
    env_home = os.environ.get("CAP_HOME")
    if env_home:
        return Path(env_home)
    return Path.home() / ".cap"


def compute_snapshot_dir(project_id: str, stamp: str, cap_home: Path) -> Path:
    """Return the canonical ``orchestrations/<stamp>/`` directory.

    Per `docs/cap/ORCHESTRATION-STORAGE-BOUNDARY.md` §4.1 the layout is::

        <cap_home>/projects/<project_id>/orchestrations/<stamp>/

    deliberately symmetric to P2 ``constitutions/project/<stamp>/`` so
    doctor / status can list both subtrees with the same code path.
    """
    if not _PROJECT_ID_RE.match(project_id):
        raise OrchestrationSnapshotError(
            f"project_id {project_id!r} does not match the canonical "
            "[a-z0-9][a-z0-9._-]* shape enforced by cap-paths.sh"
        )
    if not is_valid_stamp(stamp):
        raise OrchestrationSnapshotError(
            f"stamp {stamp!r} does not match {_STAMP_FMT!r}"
        )
    return cap_home / "projects" / project_id / "orchestrations" / stamp


# ─────────────────────────────────────────────────────────
# Snapshot path layout
# ─────────────────────────────────────────────────────────


@dataclass(frozen=True)
class OrchestrationSnapshotPaths:
    """Filesystem layout of the four-part envelope snapshot.

    Filenames are fixed by the boundary memo §4.1; downstream code
    (doctor / status / promote) can rely on the four names without
    globbing.
    """

    snapshot_dir: Path
    envelope_json: Path
    envelope_md: Path
    validation: Path
    source_prompt: Path

    @classmethod
    def under(cls, snapshot_dir: Path) -> "OrchestrationSnapshotPaths":
        return cls(
            snapshot_dir=snapshot_dir,
            envelope_json=snapshot_dir / "envelope.json",
            envelope_md=snapshot_dir / "envelope.md",
            validation=snapshot_dir / "validation.json",
            source_prompt=snapshot_dir / "source-prompt.txt",
        )

    def to_dict(self) -> dict[str, str]:
        return {
            "snapshot_dir": str(self.snapshot_dir),
            "envelope_json": str(self.envelope_json),
            "envelope_md": str(self.envelope_md),
            "validation": str(self.validation),
            "source_prompt": str(self.source_prompt),
        }


# ─────────────────────────────────────────────────────────
# Markdown placeholder rendering
# ─────────────────────────────────────────────────────────


def _render_placeholder_markdown(
    envelope_payload: dict[str, Any] | None,
    validation_report: dict[str, Any],
) -> str:
    """Render a minimal human-readable markdown view of the envelope.

    Per the boundary memo §4.2, P3 #5-a ships a placeholder so the
    four-part snapshot is whole; P3 #7 docs phase swaps in a richer
    renderer when full ARCHITECTURE / cap-entry visibility lands.

    Both success and failure paths use the same template — the markdown
    just becomes a "this envelope failed validation, see validation.json"
    pointer when ``envelope_payload`` is ``None``.
    """
    status = validation_report.get("status", "unknown")
    if envelope_payload is None:
        return (
            "# Supervisor Orchestration Envelope (extraction failed)\n"
            "\n"
            f"**status**: `{status}`\n"
            "\n"
            "> The supervisor response did not contain a usable envelope payload.\n"
            "> See `validation.json` for the failure detail.\n"
        )

    name = envelope_payload.get("task_id") or "<unknown task>"
    goal = (
        envelope_payload.get("task_constitution", {})
        .get("goal", "<no goal recorded>")
    )
    goal_stage = envelope_payload.get("governance", {}).get(
        "goal_stage", "<unknown stage>"
    )
    failure_default = (
        envelope_payload.get("failure_routing", {}).get("default_action", "<unset>")
    )
    lines = [
        f"# Supervisor Orchestration Envelope `{name}`",
        "",
        f"**status**: `{status}`",
        f"**goal_stage**: `{goal_stage}`",
        f"**failure_routing.default_action**: `{failure_default}`",
        "",
        f"**goal**: {goal}",
        "",
        "> Canonical envelope content lives in `envelope.json`; this markdown",
        "> view is a P3 #5-a placeholder and will be replaced by the richer",
        "> rendering in P3 #7 docs phase.",
        "",
    ]
    return "\n".join(lines)


# ─────────────────────────────────────────────────────────
# Public writer
# ─────────────────────────────────────────────────────────


def write_snapshot(
    *,
    project_id: str,
    cap_home: Path,
    stamp: str,
    envelope_payload: dict[str, Any] | None,
    validation_report: dict[str, Any],
    source_prompt: str,
) -> OrchestrationSnapshotPaths:
    """Write the four-part snapshot under ``orchestrations/<stamp>/``.

    Per Q1 = A, validation failure still lands all four artefacts. The
    caller is responsible for shaping ``validation_report`` (typically
    a dict with at least a ``status`` key set to ``ok`` or ``failed``).
    The writer never re-runs jsonschema; ``envelope_payload`` is
    accepted as ``None`` when fence extraction failed, and the JSON
    file gets a sentinel object pointing at ``validation.json`` for the
    diagnosis instead.

    Returns a frozen :class:`OrchestrationSnapshotPaths` describing
    every path written. Raises :class:`OrchestrationSnapshotError` for
    invariant violations (bad project_id / bad stamp); does **not**
    raise on validation failure — that is encoded in ``validation_report``.
    """
    snapshot_dir = compute_snapshot_dir(project_id, stamp, cap_home)
    snapshot_dir.mkdir(parents=True, exist_ok=True)
    paths = OrchestrationSnapshotPaths.under(snapshot_dir)

    # 1. envelope.json — write the dict verbatim, or a sentinel when the
    # producer failed to emit a parseable payload. The sentinel never
    # collides with a real envelope because real envelopes carry
    # `schema_version` (a required field), and the sentinel does not.
    if envelope_payload is None:
        envelope_body: dict[str, Any] = {
            "_orchestration_snapshot_note": (
                "envelope payload unavailable; see validation.json for the "
                "extraction / schema / drift failure detail"
            ),
        }
    else:
        envelope_body = envelope_payload
    paths.envelope_json.write_text(
        json.dumps(envelope_body, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    # 2. envelope.md — placeholder rendering (richer renderer in P3 #7).
    paths.envelope_md.write_text(
        _render_placeholder_markdown(envelope_payload, validation_report),
        encoding="utf-8",
    )

    # 3. validation.json — verbatim caller-provided report. We do NOT
    # mutate / normalise so a future schema change to validation_report
    # is owned by the producer (engine.supervisor_envelope CLI), not
    # this writer.
    paths.validation.write_text(
        json.dumps(validation_report, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    # 4. source-prompt.txt — verbatim user prompt; the caller controls
    # whether this is the original prompt or a derived placeholder
    # (e.g. when only an envelope artifact is available).
    paths.source_prompt.write_text(source_prompt, encoding="utf-8")

    return paths


# ─────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────


def _build_validation_report(
    *,
    extraction: Any,
    verdict: Any,
    drift: Any,
    stamp: str,
) -> tuple[dict[str, Any], bool]:
    """Compose the canonical ``validation.json`` body from the three stages.

    Returns ``(report_dict, all_ok_flag)``. ``all_ok_flag`` is True iff
    every stage reported ``ok``; the CLI maps that to exit 0 vs 41.
    """
    extract_ok = bool(getattr(extraction, "ok", False))
    verdict_ok = bool(getattr(verdict, "ok", False)) if verdict is not None else None
    drift_ok = bool(getattr(drift, "ok", False)) if drift is not None else None

    all_ok = extract_ok and verdict_ok is True and drift_ok is True
    report: dict[str, Any] = {
        "status": "ok" if all_ok else "failed",
        "stamp": stamp,
        "extraction": {
            "ok": extract_ok,
            "error": getattr(extraction, "error", None) if not extract_ok else None,
        },
        "validation": verdict.to_dict() if verdict is not None else None,
        "drift": drift.to_dict() if drift is not None else None,
    }
    return report, all_ok


def _cmd_write(args: argparse.Namespace) -> int:
    """High-level CLI entry: extract → validate → drift → write.

    Exit 0 when all three stages pass; exit 41 otherwise. Per Q1 = A
    the four-part snapshot is always written, even when extraction or
    validation or drift fails — the caller can inspect
    ``validation.json`` to diagnose without losing the original prompt
    or the (possibly partial) envelope text.
    """
    # Lazy import keeps this module's pure-helper test path independent
    # of supervisor_envelope.py being importable in extreme degraded
    # environments; the CLI does need both, but the smoke for the pure
    # API can hit write_snapshot() directly without spawning the CLI.
    try:
        from engine.supervisor_envelope import (  # type: ignore[import-not-found]
            extract_envelope,
            validate_envelope,
            check_envelope_drift,
        )
    except ModuleNotFoundError:
        sys.path.insert(0, str(_REPO_ROOT))
        from engine.supervisor_envelope import (  # type: ignore[no-redef]
            extract_envelope,
            validate_envelope,
            check_envelope_drift,
        )

    envelope_path = Path(args.envelope_path)
    if not envelope_path.is_file():
        sys.stderr.write(
            f"orchestration_snapshot: envelope artifact not found: {envelope_path}\n"
        )
        return 41

    text = envelope_path.read_text(encoding="utf-8")
    extraction = extract_envelope(text)

    # Validation only runs when extraction yielded a payload; downstream
    # stages that depend on a parsed dict cannot run otherwise.
    if extraction.ok and extraction.payload is not None:
        verdict = validate_envelope(extraction.payload, args.schema_path)
        drift = check_envelope_drift(extraction.payload)
    else:
        verdict = None
        drift = None

    stamp = args.stamp if args.stamp else compute_stamp()
    if not is_valid_stamp(stamp):
        sys.stderr.write(
            f"orchestration_snapshot: stamp {stamp!r} does not match "
            f"{_STAMP_FMT!r}\n"
        )
        return 41

    cap_home = (
        Path(args.cap_home).resolve() if args.cap_home else resolve_cap_home(None)
    )
    cap_home = Path(os.path.abspath(cap_home))

    report, all_ok = _build_validation_report(
        extraction=extraction, verdict=verdict, drift=drift, stamp=stamp,
    )

    # source-prompt.txt: prefer the operator-supplied prompt; fall back
    # to the envelope artifact's raw text so the snapshot still has a
    # trace of what came in even when the operator did not pass --source-prompt.
    if args.source_prompt is not None:
        source_prompt_text = args.source_prompt
    else:
        source_prompt_text = (
            f"Captured from envelope artifact at {envelope_path} (stamp={stamp}).\n"
            "----- artifact contents -----\n"
            f"{text}"
        )

    try:
        paths = write_snapshot(
            project_id=args.project_id,
            cap_home=cap_home,
            stamp=stamp,
            envelope_payload=extraction.payload,
            validation_report=report,
            source_prompt=source_prompt_text,
        )
    except OrchestrationSnapshotError as exc:
        sys.stderr.write(f"orchestration_snapshot: {exc}\n")
        return 41

    out: dict[str, Any] = {
        "status": "ok" if all_ok else "failed",
        "stamp": stamp,
        "snapshot_dir": str(paths.snapshot_dir),
        "written_paths": [
            str(paths.envelope_json),
            str(paths.envelope_md),
            str(paths.validation),
            str(paths.source_prompt),
        ],
        "validation_report_summary": {
            "extraction_ok": report["extraction"]["ok"],
            "validation_ok": (report["validation"] or {}).get("ok"),
            "drift_ok": (report["drift"] or {}).get("ok"),
        },
    }
    sys.stdout.write(json.dumps(out, indent=2, ensure_ascii=False) + "\n")

    # Per Q1 = A the artefacts are always on disk by this point;
    # exit 41 just signals to the caller that downstream consumers
    # must NOT treat this snapshot as a clean envelope.
    return 0 if all_ok else 41


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m engine.orchestration_snapshot",
        description=(
            "Pure four-part snapshot writer for Supervisor Orchestration "
            "Envelope (P3 #5-a). Writes to "
            "<cap_home>/projects/<project_id>/orchestrations/<stamp>/ . "
            "Symmetric to the P2 constitutions/project/<stamp>/ layout."
        ),
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    write = sub.add_parser(
        "write",
        help=(
            "Extract + validate + drift via engine.supervisor_envelope, "
            "then write the four-part snapshot. Exits 41 when any stage "
            "fails (artefacts still land per Q1 = A)."
        ),
    )
    write.add_argument(
        "--envelope-path",
        required=True,
        help="Path to the supervisor response artifact (markdown / text).",
    )
    write.add_argument(
        "--project-id",
        required=True,
        help=(
            "CAP project_id under which to land the snapshot. The writer "
            "is project-agnostic — there is no .cap.project.yaml lookup; "
            "callers wire that up themselves."
        ),
    )
    write.add_argument(
        "--cap-home",
        default=None,
        help="Override CAP_HOME (default: $CAP_HOME or ~/.cap).",
    )
    write.add_argument(
        "--stamp",
        default=None,
        help=(
            "Force the snapshot stamp (YYYYMMDDTHHMMSSZ). Default: "
            "compute_stamp() at invocation time."
        ),
    )
    write.add_argument(
        "--schema-path",
        type=Path,
        default=None,
        help=(
            "Override the JSON Schema used by the validate stage "
            "(default: schemas/supervisor-orchestration.schema.yaml)."
        ),
    )
    write.add_argument(
        "--source-prompt",
        default=None,
        help=(
            "Original user prompt to embed in source-prompt.txt. "
            "Default: a synthetic note plus the envelope artifact's "
            "raw text so the snapshot still records something."
        ),
    )
    write.set_defaults(func=_cmd_write)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":  # pragma: no cover - CLI entrypoint
    raise SystemExit(main())
