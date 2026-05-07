"""Compute baseline checksum / version snapshot of agent-skills/.

Produces a deterministic snapshot of the builtin agent-skills directory
so each workflow run can record which baseline it observed. Consumed
by:

* ``agent-sessions.json`` envelope (top-level ``agent_skills_baseline``
  field, written once per run by :func:`attach_to_envelope`).
* ``workflow-result.json`` (compact projection via :func:`compute_summary`,
  defined in ``schemas/workflow-result.schema.yaml`` v0.22.0+).

Spec SSOT: ``policies/agent-skills-baseline.md`` §7. A0 #4 deferred
the per-run snapshot file (``~/.cap/projects/<id>/runs/<run_id>/
agent-skills-snapshot.json``) — the envelope-only path is
canonical for now.

Determinism: ``compute_snapshot`` walks ``agent_skills_dir`` for
``*.md`` files in ``Path.rglob`` order, then sorts by relative path
before hashing so two runs with identical disk content always
produce identical ``dir_hash`` regardless of filesystem ordering.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def _default_agent_skills_dir() -> Path:
    """Resolve the canonical agent-skills/ baseline directory.

    Precedence:

    1. ``CAP_AGENT_SKILLS_DIR`` env var (test injection / non-default
       layouts).
    2. ``<engine_module_parent>/agent-skills`` — the cap-protocols
       repo root layout. ``Path(__file__).parents[1]`` resolves to
       the repo root because ``engine/`` is one level under it.
    """
    override = os.environ.get("CAP_AGENT_SKILLS_DIR")
    if override:
        return Path(override).expanduser()
    return Path(__file__).resolve().parents[1] / "agent-skills"


def _default_cap_root() -> Path:
    """Resolve cap-protocols repo root for repo.manifest.yaml + git lookups."""
    override = os.environ.get("CAP_ROOT")
    if override:
        return Path(override).expanduser()
    return Path(__file__).resolve().parents[1]


def compute_snapshot(
    *,
    agent_skills_dir: Path | None = None,
    cap_root: Path | None = None,
    computed_at: datetime | None = None,
) -> dict:
    """Compute baseline snapshot for an ``agent-skills/`` directory.

    Parameters
    ----------
    agent_skills_dir:
        Directory to hash. Defaults to :func:`_default_agent_skills_dir`.
    cap_root:
        Repo root used for ``repo.manifest.yaml`` + ``git`` lookups.
        Defaults to :func:`_default_cap_root`.
    computed_at:
        Override timestamp (used by tests to keep snapshots
        deterministic). When ``None``, uses ``datetime.now(tz=UTC)``.

    Returns
    -------
    dict with keys:

    * ``cap_version``: from ``repo.manifest.yaml``; ``None`` when
      manifest missing or unreadable.
    * ``git_commit``: ``HEAD`` SHA of cap_root; ``None`` outside git.
    * ``git_dirty``: ``True`` when ``git status --porcelain`` is
      non-empty.
    * ``computed_at``: ISO-8601 UTC timestamp.
    * ``dir_hash``: ``sha256:<hex>`` aggregate of every ``*.md``
      file under ``agent_skills_dir`` (sorted by relative path).
    * ``prompt_files``: ``{relpath: sha256:<hex>}`` per-file hash
      mapping; empty when the directory is empty / missing.
    * ``baseline_root``: absolute path the snapshot was computed
      against.

    Raises
    ------
    FileNotFoundError when ``agent_skills_dir`` does not exist.
    """
    agent_skills_dir = (agent_skills_dir or _default_agent_skills_dir()).resolve()
    cap_root = (cap_root or _default_cap_root()).resolve()

    if not agent_skills_dir.is_dir():
        raise FileNotFoundError(
            f"agent_skills_dir does not exist: {agent_skills_dir}"
        )

    files = sorted(
        (p for p in agent_skills_dir.rglob("*.md") if p.is_file()),
        key=lambda p: str(p.relative_to(agent_skills_dir)),
    )

    file_hashes: dict[str, str] = {}
    aggregator = hashlib.sha256()
    for f in files:
        rel = str(f.relative_to(agent_skills_dir))
        content_hash = hashlib.sha256(f.read_bytes()).hexdigest()
        file_hashes[rel] = f"sha256:{content_hash}"
        aggregator.update(rel.encode("utf-8"))
        aggregator.update(b"\0")
        aggregator.update(content_hash.encode("ascii"))
        aggregator.update(b"\0")
    dir_hash = aggregator.hexdigest()

    cap_version = _read_cap_version(cap_root)
    git_commit, git_dirty = _read_git_info(cap_root)

    if computed_at is None:
        computed_at = datetime.now(tz=timezone.utc)
    elif computed_at.tzinfo is None:
        computed_at = computed_at.replace(tzinfo=timezone.utc)

    return {
        "cap_version": cap_version,
        "git_commit": git_commit,
        "git_dirty": git_dirty,
        "computed_at": computed_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "dir_hash": f"sha256:{dir_hash}",
        "prompt_files": file_hashes,
        "baseline_root": str(agent_skills_dir),
    }


def compute_summary(snapshot: dict) -> dict:
    """Project a compact summary for ``workflow-result.json``.

    Drops the ``prompt_files`` mapping (per-file hashes can balloon
    the result envelope; consumers needing them read the source
    ``agent-sessions.json``); keeps top-level identifiers + a derived
    ``file_count``.
    """
    return {
        "cap_version": snapshot.get("cap_version"),
        "git_commit": snapshot.get("git_commit"),
        "git_dirty": snapshot.get("git_dirty"),
        "dir_hash": snapshot.get("dir_hash"),
        "file_count": len(snapshot.get("prompt_files") or {}),
        "baseline_root": snapshot.get("baseline_root"),
    }


def attach_to_envelope(envelope: dict, *, snapshot: dict | None = None) -> dict:
    """Idempotently embed ``agent_skills_baseline`` into a ledger envelope.

    Computes the snapshot via :func:`compute_snapshot` when none is
    supplied. Returns the envelope unchanged when a baseline is
    already present so re-runs do not overwrite a committed ledger.
    """
    if envelope.get("agent_skills_baseline"):
        return envelope
    if snapshot is None:
        snapshot = compute_snapshot()
    envelope["agent_skills_baseline"] = snapshot
    return envelope


def _read_cap_version(cap_root: Path) -> str | None:
    manifest = cap_root / "repo.manifest.yaml"
    if not manifest.is_file():
        return None
    try:
        for raw_line in manifest.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if line.startswith("cap_version:"):
                value = line.split(":", 1)[1].strip().strip("\"'")
                return value or None
    except OSError:
        return None
    return None


def _read_git_info(cap_root: Path) -> tuple[str | None, bool]:
    """Read HEAD SHA + working-tree dirty flag from ``cap_root``.

    Returns ``(None, False)`` when ``cap_root`` is not a git repo or
    when the ``git`` binary is unavailable; this keeps snapshot
    creation safe inside non-git checkouts (downloaded tarball
    install, sandbox without git).
    """
    try:
        commit_proc = subprocess.run(
            ["git", "-C", str(cap_root), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (subprocess.SubprocessError, FileNotFoundError, OSError):
        return None, False
    if commit_proc.returncode != 0:
        return None, False
    commit_hash = commit_proc.stdout.strip() or None

    try:
        status_proc = subprocess.run(
            ["git", "-C", str(cap_root), "status", "--porcelain"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (subprocess.SubprocessError, FileNotFoundError, OSError):
        return commit_hash, False
    dirty = bool(status_proc.stdout.strip()) if status_proc.returncode == 0 else False
    return commit_hash, dirty


def _cli(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="agent_skills_snapshot",
        description=(
            "Compute baseline checksum of agent-skills/ for run-level snapshot."
        ),
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_snap = sub.add_parser(
        "snapshot",
        help="Print full snapshot JSON to stdout.",
    )
    p_snap.add_argument("--agent-skills-dir", type=Path, default=None)
    p_snap.add_argument("--cap-root", type=Path, default=None)

    p_summary = sub.add_parser(
        "summary",
        help="Print compact summary projection JSON to stdout.",
    )
    p_summary.add_argument("--agent-skills-dir", type=Path, default=None)
    p_summary.add_argument("--cap-root", type=Path, default=None)

    p_attach = sub.add_parser(
        "attach",
        help="Embed agent_skills_baseline into an existing JSON envelope file (idempotent).",
    )
    p_attach.add_argument("envelope_path", type=Path)
    p_attach.add_argument("--agent-skills-dir", type=Path, default=None)
    p_attach.add_argument("--cap-root", type=Path, default=None)

    args = parser.parse_args(argv)

    if args.cmd == "snapshot":
        snap = compute_snapshot(
            agent_skills_dir=args.agent_skills_dir,
            cap_root=args.cap_root,
        )
        print(json.dumps(snap, ensure_ascii=False, indent=2))
        return 0

    if args.cmd == "summary":
        snap = compute_snapshot(
            agent_skills_dir=args.agent_skills_dir,
            cap_root=args.cap_root,
        )
        print(json.dumps(compute_summary(snap), ensure_ascii=False, indent=2))
        return 0

    if args.cmd == "attach":
        path = args.envelope_path
        if not path.is_file():
            print(
                f"error: envelope file does not exist: {path}",
                file=sys.stderr,
            )
            return 2
        envelope = json.loads(path.read_text(encoding="utf-8"))
        snap = compute_snapshot(
            agent_skills_dir=args.agent_skills_dir,
            cap_root=args.cap_root,
        )
        attach_to_envelope(envelope, snapshot=snap)
        path.write_text(
            json.dumps(envelope, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        print(f"attached agent_skills_baseline to {path}")
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(_cli(sys.argv[1:]))
