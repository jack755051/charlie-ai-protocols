"""Constitution snapshot for replay drift detection (H3 #2).

Captures whole-file hash of ``<project_root>/.cap/constitution.yaml``
so the H3 verifier can flag drift if the constitution changes between
run and verify time. Per design memo §5.2 (Cost-Aware minimal scope),
only whole-file hash; per-block hash (allowed_capabilities /
workflow_policy / binding_policy) deferred to H4+.

Module is parallel to ``engine/workflow_yaml_snapshot.py`` and
``engine/agent_skills_snapshot.py``: pure helpers + argparse CLI.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path


_DEFAULT_CONSTITUTION_RELPATH = ".cap/constitution.yaml"


def _utcnow_iso() -> str:
    return datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _hash_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _default_project_root() -> Path:
    """Resolve the project root for constitution discovery.

    Precedence (mirrors ``engine/project_skills_snapshot.py``):

    1. ``CAP_PROJECT_ROOT`` env var.
    2. cwd.
    """
    override = os.environ.get("CAP_PROJECT_ROOT")
    if override:
        return Path(override).expanduser()
    return Path.cwd()


def compute_snapshot(
    *,
    project_root: Path | None = None,
    computed_at: datetime | None = None,
) -> dict:
    """Compute whole-file snapshot of the project constitution.

    Returns dict matching design memo §5.2 with:
      ``constitution_path`` / ``constitution_present`` /
      ``content_hash`` / ``computed_at`` / ``schema_version``.

    When the constitution file does not exist (bootstrap-style runs
    that pre-date constitution creation), returns
    ``constitution_present=False`` + ``content_hash=None`` so audit
    can distinguish "no constitution" from "constitution removed
    later".
    """
    project_root = (project_root or _default_project_root()).resolve()
    constitution_path = project_root / _DEFAULT_CONSTITUTION_RELPATH
    iso = (
        computed_at.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        if computed_at
        else _utcnow_iso()
    )

    if constitution_path.is_file():
        return {
            "schema_version": 1,
            "constitution_path": str(constitution_path),
            "constitution_present": True,
            "content_hash": f"sha256:{_hash_file(constitution_path)}",
            "computed_at": iso,
        }
    return {
        "schema_version": 1,
        "constitution_path": str(constitution_path),
        "constitution_present": False,
        "content_hash": None,
        "computed_at": iso,
    }


def attach_to_envelope(envelope: dict, *, snapshot: dict) -> dict:
    """Idempotently embed ``constitution_baseline`` into envelope."""
    if envelope.get("constitution_baseline"):
        return envelope
    envelope["constitution_baseline"] = snapshot
    return envelope


def _cli(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="constitution_snapshot",
        description="Whole-file snapshot of <project_root>/.cap/constitution.yaml for replay drift detection.",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_snap = sub.add_parser("snapshot", help="Print full snapshot JSON.")
    p_snap.add_argument("--project-root", type=Path, default=None)

    p_attach = sub.add_parser(
        "attach",
        help="Embed constitution_baseline into envelope JSON file (idempotent).",
    )
    p_attach.add_argument("envelope_path", type=Path)
    p_attach.add_argument("--project-root", type=Path, default=None)

    args = parser.parse_args(argv)

    if args.cmd == "snapshot":
        snap = compute_snapshot(project_root=args.project_root)
        print(json.dumps(snap, ensure_ascii=False, indent=2))
        return 0

    if args.cmd == "attach":
        if not args.envelope_path.is_file():
            print(f"error: envelope file does not exist: {args.envelope_path}", file=sys.stderr)
            return 2
        envelope = json.loads(args.envelope_path.read_text(encoding="utf-8"))
        snap = compute_snapshot(project_root=args.project_root)
        attach_to_envelope(envelope, snapshot=snap)
        args.envelope_path.write_text(
            json.dumps(envelope, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        print(f"attached constitution_baseline to {args.envelope_path}")
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(_cli(sys.argv[1:]))
