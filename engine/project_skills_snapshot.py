"""Compute project layer skill snapshot for replay drift detection.

Produces a deterministic snapshot of `<project_root>/.cap/skills.yaml`
plus `<project_root>/.cap/skills/*.{yaml,yml,json}` so each workflow
run can record which project layer skill state it observed. Consumed
by:

* ``agent-sessions.json`` envelope (top-level ``project_skill_baseline``
  field, attached once per run by ``cap-workflow-exec.sh`` post-A0 #4
  via :func:`attach_to_envelope`).
* ``workflow-result.json`` (compact projection — future projection
  surface, parallel to ``agent_skills_baseline``).
* H2 verifier (``engine/replay_verifier.py``) for project axis drift
  detection.

Spec SSOT: ``docs/cap/H2-PROJECT-SKILL-DRIFT-DESIGN.md`` §2 (snapshot
scope) / §6 (per-run snapshot file). Mirrors the structure of
``engine/agent_skills_snapshot.py`` (A0 #4) so the two snapshot
surfaces stay parallel; deviations are documented inline.

H2 v1 scope:

* Includes the flat registry file plus per-skill subdir entries that
  ``RuntimeBinder._resolve_layer_registry`` would actually load. Does
  NOT include the shared layer (``<cap_home>/shared/...``); shared
  drift detection is deferred to H3.
* Does NOT compute the effective merged spec. Two raw-content hashes
  (per-file + aggregate dir_hash) are enough to gate drift; effective
  state is a derived product of builtin × project × `_apply_override_contract`.
* Does NOT walk recursively beyond the documented patterns. Files
  under ``<project_root>/.cap/skills/<sub>/...`` are skipped (the
  layer resolver also only iterates one level deep).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

# Filenames matched by RuntimeBinder._resolve_layer_registry for the flat
# project registry file. We mirror the same precedence (yaml first, then
# yml, then json) so the snapshot picks up whichever one the binder
# would actually read.
_FLAT_REGISTRY_FILENAMES = ("skills.yaml", "skills.yml", "skills.json")
_PER_SKILL_SUFFIXES = {".yaml", ".yml", ".json"}
_PER_SKILL_DIR_NAME = "skills"


def _default_project_root() -> Path:
    """Resolve the project root for project layer skill discovery.

    Precedence (matches ``engine/runtime_binder.py:RuntimeBinder.__init__``):

    1. ``CAP_PROJECT_ROOT`` env var (test injection / non-cwd contexts).
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
    """Compute project layer skill snapshot.

    Parameters
    ----------
    project_root:
        Filesystem path of the project root. Defaults to
        :func:`_default_project_root`.
    computed_at:
        Override timestamp; tests use this to keep snapshots
        byte-stable. Defaults to ``datetime.now(UTC)``.

    Returns
    -------
    dict with keys:

    * ``project_root``: absolute path the snapshot was computed against.
    * ``project_dir_present``: ``True`` when ``<project_root>/.cap/``
      exists. ``False`` allows verifier to distinguish "no project
      layer at all" from "empty project layer".
    * ``flat_registry``: ``{path, hash}`` of the matched flat file or
      ``None`` when none of ``skills.{yaml,yml,json}`` is present.
    * ``per_skill_files``: ``{relpath: hash}`` mapping for every
      ``.cap/skills/*.{yaml,yml,json}``; empty dict when subdir
      missing or empty.
    * ``skills_by_id``: ``{skill_id: {hash, source_path}}``. Hashes
      individual ``skills[*]`` entries by their canonical JSON
      serialisation so per-skill drift can be reported even when
      multiple skills share one flat file.
    * ``dir_hash``: aggregate ``sha256:<hex>`` over the sorted union of
      every contributing file's per-file hash.
    * ``computed_at``: ISO-8601 UTC timestamp.
    """
    project_root = (project_root or _default_project_root()).resolve()
    cap_dir = project_root / ".cap"

    if computed_at is None:
        computed_at = datetime.now(tz=timezone.utc)
    elif computed_at.tzinfo is None:
        computed_at = computed_at.replace(tzinfo=timezone.utc)
    computed_iso = computed_at.strftime("%Y-%m-%dT%H:%M:%SZ")

    if not cap_dir.is_dir():
        return _empty_snapshot(project_root, computed_iso, project_dir_present=False)

    # ── Flat registry discovery ──
    flat_registry: dict | None = None
    flat_path: Path | None = None
    for filename in _FLAT_REGISTRY_FILENAMES:
        candidate = cap_dir / filename
        if candidate.is_file():
            flat_path = candidate
            flat_hash = _hash_file(candidate)
            flat_registry = {
                "path": str(candidate),
                "hash": f"sha256:{flat_hash}",
            }
            break

    # ── Per-skill subdir discovery ──
    per_skill_files: dict[str, str] = {}
    per_skill_dir = cap_dir / _PER_SKILL_DIR_NAME
    per_skill_paths: list[Path] = []
    if per_skill_dir.is_dir():
        for path in sorted(per_skill_dir.iterdir()):
            if path.is_file() and path.suffix in _PER_SKILL_SUFFIXES:
                per_skill_paths.append(path)
                rel = str(path.relative_to(cap_dir))
                per_skill_files[rel] = f"sha256:{_hash_file(path)}"

    # ── skills_by_id index ──
    # Iterate through every contributing source file and extract per-skill
    # entries. Hash each entry by canonical JSON serialisation so verifier
    # can attribute drift down to specific skill_ids.
    skills_by_id: dict[str, dict] = {}
    for source_path in [p for p in (flat_path,) if p] + per_skill_paths:
        try:
            data = _load_yaml_or_json(source_path)
        except (OSError, ValueError):
            continue
        for skill in _iter_skills(data):
            sid = skill.get("skill_id") if isinstance(skill, dict) else None
            if not sid:
                continue
            entry_hash = _hash_canonical_json(skill)
            # First-seen wins (mirrors RuntimeBinder._merge_skill_layers
            # within a single layer; flat file iterates before per-skill).
            if sid not in skills_by_id:
                skills_by_id[sid] = {
                    "hash": f"sha256:{entry_hash}",
                    "source_path": str(source_path),
                }

    # ── Aggregate dir_hash ──
    aggregator = hashlib.sha256()
    parts: list[tuple[str, str]] = []
    if flat_registry:
        parts.append(("__flat__", flat_registry["hash"]))
    for rel, h in sorted(per_skill_files.items()):
        parts.append((rel, h))
    for relpath, h in parts:
        aggregator.update(relpath.encode("utf-8"))
        aggregator.update(b"\0")
        aggregator.update(h.encode("ascii"))
        aggregator.update(b"\0")
    dir_hash = (
        f"sha256:{aggregator.hexdigest()}"
        if parts
        else "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"  # empty
    )

    return {
        "project_root": str(project_root),
        "project_dir_present": True,
        "flat_registry": flat_registry,
        "per_skill_files": per_skill_files,
        "skills_by_id": skills_by_id,
        "dir_hash": dir_hash,
        "computed_at": computed_iso,
    }


def compute_summary(snapshot: dict) -> dict:
    """Compact projection for ``workflow-result.json`` parallel to A0 #4.

    Drops the ``skills_by_id`` map and ``per_skill_files`` map (the
    full snapshot mirror under ``<run_dir>/snapshots/project-skills.json``
    keeps them); preserves top-level identifiers + counts so consumers
    have a first-pass signal.
    """
    skills_by_id = snapshot.get("skills_by_id") or {}
    per_skill_files = snapshot.get("per_skill_files") or {}
    flat_registry = snapshot.get("flat_registry")
    return {
        "project_root": snapshot.get("project_root"),
        "project_dir_present": snapshot.get("project_dir_present", False),
        "flat_registry_path": (flat_registry or {}).get("path"),
        "flat_registry_hash": (flat_registry or {}).get("hash"),
        "per_skill_file_count": len(per_skill_files),
        "skill_count": len(skills_by_id),
        "dir_hash": snapshot.get("dir_hash"),
    }


def attach_to_envelope(envelope: dict, *, snapshot: dict | None = None) -> dict:
    """Idempotently embed ``project_skill_baseline`` into a ledger envelope.

    Mirrors ``engine.agent_skills_snapshot.attach_to_envelope`` semantics:
    when the field is already populated, return the envelope unchanged
    (no overwrite — the original run's observed state is canonical).
    """
    if envelope.get("project_skill_baseline"):
        return envelope
    if snapshot is None:
        snapshot = compute_snapshot()
    envelope["project_skill_baseline"] = snapshot
    return envelope


def _empty_snapshot(
    project_root: Path, computed_iso: str, *, project_dir_present: bool
) -> dict:
    return {
        "project_root": str(project_root),
        "project_dir_present": project_dir_present,
        "flat_registry": None,
        "per_skill_files": {},
        "skills_by_id": {},
        "dir_hash": "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "computed_at": computed_iso,
    }


def _hash_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _hash_canonical_json(obj: object) -> str:
    """Hash a Python value via its canonical JSON serialisation.

    Sort keys so two semantically-equal dicts produce the same hash
    regardless of insertion order. Use ``ensure_ascii=False`` to keep
    Unicode skill metadata stable.
    """
    serialised = json.dumps(
        obj, sort_keys=True, ensure_ascii=False, separators=(",", ":")
    )
    return hashlib.sha256(serialised.encode("utf-8")).hexdigest()


def _iter_skills(data: object):
    """Yield ``skills[*]`` entries from a registry-shaped or single-skill file.

    Three accepted shapes (matches ``RuntimeBinder._resolve_layer_registry``):

    * ``{skills: [...]}``           — multi-skill envelope
    * ``{skill_id: ..., ...}``      — single-skill file
    * Anything else                 — yield nothing
    """
    if not isinstance(data, dict):
        return
    if "skills" in data and isinstance(data["skills"], list):
        for entry in data["skills"]:
            yield entry
        return
    if "skill_id" in data:
        yield data


def _load_yaml_or_json(path: Path):
    raw = path.read_text(encoding="utf-8")
    if path.suffix == ".json":
        return json.loads(raw)
    # Lazy-import yaml so the helper still loads in environments that
    # have no PyYAML (json-only registries still hash correctly).
    import yaml  # type: ignore[import-untyped]
    return yaml.safe_load(raw)


# ─────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────


def _cli(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="project_skills_snapshot",
        description=(
            "Compute project layer skill snapshot under <project_root>/.cap/."
        ),
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_snap = sub.add_parser("snapshot", help="Print full snapshot JSON to stdout.")
    p_snap.add_argument("--project-root", type=Path, default=None)

    p_summary = sub.add_parser(
        "summary", help="Print compact summary projection JSON to stdout."
    )
    p_summary.add_argument("--project-root", type=Path, default=None)

    p_attach = sub.add_parser(
        "attach",
        help=(
            "Embed project_skill_baseline into an existing JSON envelope file "
            "(idempotent — never overwrites)."
        ),
    )
    p_attach.add_argument("envelope_path", type=Path)
    p_attach.add_argument("--project-root", type=Path, default=None)

    args = parser.parse_args(argv)

    if args.cmd == "snapshot":
        snap = compute_snapshot(project_root=args.project_root)
        print(json.dumps(snap, ensure_ascii=False, indent=2))
        return 0

    if args.cmd == "summary":
        snap = compute_snapshot(project_root=args.project_root)
        print(json.dumps(compute_summary(snap), ensure_ascii=False, indent=2))
        return 0

    if args.cmd == "attach":
        path = args.envelope_path
        if not path.is_file():
            print(f"error: envelope file does not exist: {path}", file=sys.stderr)
            return 2
        envelope = json.loads(path.read_text(encoding="utf-8"))
        snap = compute_snapshot(project_root=args.project_root)
        attach_to_envelope(envelope, snapshot=snap)
        path.write_text(
            json.dumps(envelope, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        print(f"attached project_skill_baseline to {path}")
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(_cli(sys.argv[1:]))
