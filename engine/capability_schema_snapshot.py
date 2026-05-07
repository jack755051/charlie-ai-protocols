"""Capability schema snapshot for replay drift detection (H3 #2).

Captures whole-file hash of ``<cap_root>/schemas/capabilities.yaml``
so the H3 verifier can flag drift if the capability contract changes
between run and verify time. Per design memo §5.3 (Cost-Aware minimal
scope), only whole-file hash; per-capability hash deferred to H4+.

Module is parallel to ``engine/workflow_yaml_snapshot.py`` and
``engine/constitution_snapshot.py``: pure helpers + argparse CLI.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path


_DEFAULT_CAP_SCHEMA_RELPATH = "schemas/capabilities.yaml"


def _utcnow_iso() -> str:
    return datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _hash_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _default_cap_root() -> Path:
    """Resolve cap-protocols repo root.

    Mirrors ``engine/agent_skills_snapshot.py:_default_cap_root``:
    ``CAP_ROOT`` env var first, else ``Path(__file__).parents[1]``
    (engine/ → repo root).
    """
    override = os.environ.get("CAP_ROOT")
    if override:
        return Path(override).expanduser()
    return Path(__file__).resolve().parents[1]


def compute_snapshot(
    *,
    cap_root: Path | None = None,
    computed_at: datetime | None = None,
) -> dict:
    """Compute whole-file snapshot of capabilities.yaml.

    Returns dict matching design memo §5.3 with:
      ``schema_path`` / ``schema_present`` /
      ``content_hash`` / ``computed_at`` / ``schema_version``.

    When the schema file does not exist (corrupted install, sandbox
    without cap-protocols vendored), returns ``schema_present=False``
    + ``content_hash=None`` so audit can flag the missing baseline
    rather than crashing.
    """
    cap_root = (cap_root or _default_cap_root()).resolve()
    schema_path = cap_root / _DEFAULT_CAP_SCHEMA_RELPATH
    iso = (
        computed_at.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        if computed_at
        else _utcnow_iso()
    )

    if schema_path.is_file():
        return {
            "schema_version": 1,
            "schema_path": str(schema_path),
            "schema_present": True,
            "content_hash": f"sha256:{_hash_file(schema_path)}",
            "computed_at": iso,
        }
    return {
        "schema_version": 1,
        "schema_path": str(schema_path),
        "schema_present": False,
        "content_hash": None,
        "computed_at": iso,
    }


def attach_to_envelope(envelope: dict, *, snapshot: dict) -> dict:
    """Idempotently embed ``capability_schema_baseline`` into envelope."""
    if envelope.get("capability_schema_baseline"):
        return envelope
    envelope["capability_schema_baseline"] = snapshot
    return envelope


def _cli(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="capability_schema_snapshot",
        description="Whole-file snapshot of <cap_root>/schemas/capabilities.yaml for replay drift detection.",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_snap = sub.add_parser("snapshot", help="Print full snapshot JSON.")
    p_snap.add_argument("--cap-root", type=Path, default=None)

    p_attach = sub.add_parser(
        "attach",
        help="Embed capability_schema_baseline into envelope JSON file (idempotent).",
    )
    p_attach.add_argument("envelope_path", type=Path)
    p_attach.add_argument("--cap-root", type=Path, default=None)

    args = parser.parse_args(argv)

    if args.cmd == "snapshot":
        snap = compute_snapshot(cap_root=args.cap_root)
        print(json.dumps(snap, ensure_ascii=False, indent=2))
        return 0

    if args.cmd == "attach":
        if not args.envelope_path.is_file():
            print(f"error: envelope file does not exist: {args.envelope_path}", file=sys.stderr)
            return 2
        envelope = json.loads(args.envelope_path.read_text(encoding="utf-8"))
        snap = compute_snapshot(cap_root=args.cap_root)
        attach_to_envelope(envelope, snapshot=snap)
        args.envelope_path.write_text(
            json.dumps(envelope, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        print(f"attached capability_schema_baseline to {args.envelope_path}")
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(_cli(sys.argv[1:]))
