"""Workflow YAML snapshot for replay drift detection (H3 #2).

Captures a whole-file hash of the workflow YAML used by a run so the
H3 verifier can later flag drift if that file changes between run and
verify time. Per ``docs/cap/H3-DRIFT-EXPANSION-DESIGN.md`` §5.1
(Cost-Aware minimal scope), the snapshot does NOT walk per-step
fields — selection precision is deferred to H4+. Drift detection is
limited to: hash matches → ``replayable``; hash differs / file
missing → ``drifted_compatible``.

Module is parallel to ``engine/agent_skills_snapshot.py`` (A0 #4) and
``engine/project_skills_snapshot.py`` (H2 #2): pure helpers + argparse
CLI exposing ``snapshot`` / ``attach`` subcommands.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


def _utcnow_iso() -> str:
    return datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _hash_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def compute_snapshot(
    *,
    workflow_path: Path,
    workflow_id: str | None = None,
    source_layer: str | None = None,
    computed_at: datetime | None = None,
) -> dict:
    """Compute whole-file snapshot for a single workflow YAML.

    Parameters
    ----------
    workflow_path:
        Absolute path to the workflow file the run used. Required —
        unlike A0 #4 / H2 #2 which discover via cwd, the workflow used
        by a run is identified by the bound plan / runtime-state and
        passed in explicitly.
    workflow_id:
        Optional workflow id from the bound plan. Recorded for
        audit; not used in drift comparison.
    source_layer:
        Optional ``project`` / ``shared`` / ``builtin`` / ``explicit``
        per P9 #4 layered resolver. Recorded for audit.
    computed_at:
        Override for tests; defaults to ``datetime.now(UTC)``.

    Returns
    -------
    dict matching design memo §5.1:
      ``workflow_id`` / ``workflow_path`` / ``source_layer`` /
      ``content_hash`` / ``computed_at`` / ``schema_version``.
      ``workflow_present`` is true when the file existed at
      snapshot time, false when it had been deleted; the latter
      yields ``content_hash=None``.
    """
    workflow_path = Path(workflow_path)
    iso = (
        computed_at.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        if computed_at
        else _utcnow_iso()
    )
    if workflow_path.is_file():
        return {
            "schema_version": 1,
            "workflow_id": workflow_id,
            "workflow_path": str(workflow_path.resolve()),
            "source_layer": source_layer,
            "workflow_present": True,
            "content_hash": f"sha256:{_hash_file(workflow_path)}",
            "computed_at": iso,
        }
    return {
        "schema_version": 1,
        "workflow_id": workflow_id,
        "workflow_path": str(workflow_path),
        "source_layer": source_layer,
        "workflow_present": False,
        "content_hash": None,
        "computed_at": iso,
    }


def attach_to_envelope(envelope: dict, *, snapshot: dict) -> dict:
    """Idempotently embed ``workflow_yaml_baseline`` into a ledger envelope."""
    if envelope.get("workflow_yaml_baseline"):
        return envelope
    envelope["workflow_yaml_baseline"] = snapshot
    return envelope


def _cli(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="workflow_yaml_snapshot",
        description="Compute whole-file snapshot of a workflow YAML for replay drift detection.",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_snap = sub.add_parser("snapshot", help="Print full snapshot JSON.")
    p_snap.add_argument("workflow_path", type=Path)
    p_snap.add_argument("--workflow-id", type=str, default=None)
    p_snap.add_argument("--source-layer", type=str, default=None)

    p_attach = sub.add_parser(
        "attach",
        help="Embed workflow_yaml_baseline into envelope JSON file (idempotent).",
    )
    p_attach.add_argument("envelope_path", type=Path)
    p_attach.add_argument("--workflow-path", type=Path, required=True)
    p_attach.add_argument("--workflow-id", type=str, default=None)
    p_attach.add_argument("--source-layer", type=str, default=None)

    args = parser.parse_args(argv)

    if args.cmd == "snapshot":
        snap = compute_snapshot(
            workflow_path=args.workflow_path,
            workflow_id=args.workflow_id,
            source_layer=args.source_layer,
        )
        print(json.dumps(snap, ensure_ascii=False, indent=2))
        return 0

    if args.cmd == "attach":
        if not args.envelope_path.is_file():
            print(f"error: envelope file does not exist: {args.envelope_path}", file=sys.stderr)
            return 2
        envelope = json.loads(args.envelope_path.read_text(encoding="utf-8"))
        snap = compute_snapshot(
            workflow_path=args.workflow_path,
            workflow_id=args.workflow_id,
            source_layer=args.source_layer,
        )
        attach_to_envelope(envelope, snapshot=snap)
        args.envelope_path.write_text(
            json.dumps(envelope, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        print(f"attached workflow_yaml_baseline to {args.envelope_path}")
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(_cli(sys.argv[1:]))
