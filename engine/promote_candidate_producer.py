"""P10 #2 promote candidate producer.

Pure read-only inspector that turns a workflow-result dict (P7 builder
output, **before** ``promote_candidates`` is set) into the
``promote_candidates[]`` list that ``schemas/workflow-result.schema.yaml``
expects. Replaces the P0/P7-era hard-coded ``[]`` placeholder.

Authoritative spec: ``policies/runtime-promote.md`` §5 (producer
contract). Key invariants:

* **Two artifact types only** (policy §2 / §5.2 enum):
  ``project_constitution`` and ``compiled_workflow``. Run-only
  artifacts (runtime-state.json / agent-sessions.json /
  route-history.jsonl / step raw logs) and binding reports are
  intentionally excluded.
* **``final_state == "completed"`` required for compiled_workflow**
  (policy §5.3). A failed / blocked / cancelled run's compiled
  workflow must NOT be promoted, because it is the artifact under
  which the failure occurred.
* **Missing source on disk → silent no-emit** (policy §5.3). The
  producer never raises on missing files; informational scans only.
* **No content parsing** (policy §5.4). Only path existence checks;
  the producer never reads schema, constitution, or workflow file
  contents. Validation happens later in the post-apply gate
  (policy §6).
* **No P3 supervisor envelope reads** (policy §5.4). Producer is
  layer-aware via P9 source_layer when the run_result carries it,
  but it does not parse new SSOT.

Each emitted candidate strictly matches the schema's required field
set: ``source_path`` / ``target_path`` / ``artifact_type`` /
``reason``, plus best-effort optional ``validation_schema`` /
``source_layer`` / ``source_revision``.
"""
from __future__ import annotations

import os
from pathlib import Path
from typing import Any, Optional


def produce_candidates(
    run_result: dict,
    *,
    project_root: Optional[Path | str] = None,
    cap_home: Optional[Path | str] = None,
) -> list[dict[str, Any]]:
    """Build ``workflow-result.json:promote_candidates[]`` for ``run_result``.

    Args:
        run_result: Partial workflow-result dict (everything except
            ``promote_candidates`` itself). Producer reads
            ``project_id`` / ``task_id`` / ``workflow_id`` /
            ``final_state``; missing fields are treated as "not
            promotable, silently".
        project_root: Repo root the candidates would land in.
            Precedence: explicit kwarg > ``CAP_PROJECT_ROOT`` env >
            ``Path.cwd()``. Mirrors the P9 ``WorkflowLoader`` /
            ``RuntimeBinder`` resolution so the same env var honors
            both layers.
        cap_home: Runtime storage root. Precedence: explicit kwarg >
            ``CAP_HOME`` env > ``~/.cap``. Same convention as
            ``cap workflow inspect``'s ``--cap-home`` flag and the
            ``CAP_HOME`` env consumed across CAP scripts.

    Returns:
        A list of candidate dicts (possibly empty). Order is
        deterministic: project_constitution first, then
        compiled_workflow, so consumers that just take the head
        get a predictable type.
    """
    cap_home_path = _resolve_cap_home(cap_home)
    project_root_path = _resolve_project_root(project_root)

    project_id = (run_result or {}).get("project_id")
    if not project_id or project_id == "unknown":
        # Without a stable project_id we cannot route artifacts back to
        # the runtime tree at <cap_home>/projects/<id>/, and the
        # cap-paths runtime resolver also rejects "unknown" (see
        # engine/project_context_loader.py). Silently no-emit.
        return []

    project_storage = cap_home_path / "projects" / project_id
    candidates: list[dict[str, Any]] = []

    constitution_candidate = _detect_constitution_candidate(
        run_result, project_storage, project_root_path
    )
    if constitution_candidate is not None:
        candidates.append(constitution_candidate)

    workflow_candidate = _detect_compiled_workflow_candidate(
        run_result, project_storage, project_root_path
    )
    if workflow_candidate is not None:
        candidates.append(workflow_candidate)

    return candidates


def _detect_constitution_candidate(
    run_result: dict,
    project_storage: Path,
    project_root: Path,
) -> Optional[dict[str, Any]]:
    """Return a project_constitution candidate or ``None``.

    Per policy §5.3: emitted when ``run_result.task_id`` is non-null
    and ``<cap_home>/projects/<project_id>/constitutions/<task_id>/
    constitution.{yaml,yml,json}`` exists on disk. The constitution
    file is the runtime snapshot the supervisor wrote at task setup;
    promoting it copies that snapshot into the repo as the new
    project SSOT.
    """
    task_id = run_result.get("task_id")
    if not task_id:
        return None

    constitution_dir = project_storage / "constitutions" / task_id
    if not constitution_dir.is_dir():
        return None

    # Prefer ``constitution.yaml`` then yml then json so a project that
    # has multiple formats lying around (rare, but possible during
    # mid-migration) gets a deterministic pick. First hit wins.
    source_path: Optional[Path] = None
    for ext in ("yaml", "yml", "json"):
        candidate = constitution_dir / f"constitution.{ext}"
        if candidate.is_file():
            source_path = candidate
            break

    if source_path is None:
        return None

    target_path = project_root / ".cap" / "constitution.yaml"

    return {
        "source_path": str(source_path.resolve()),
        "target_path": str(target_path.resolve()),
        "artifact_type": "project_constitution",
        "reason": (
            f"task constitution snapshot for task '{task_id}' is on disk "
            "and ready to promote to the project SSOT"
        ),
        "validation_schema": "schemas/project-constitution.schema.yaml",
        "source_layer": run_result.get("source_layer"),
        "source_revision": task_id,
    }


def _detect_compiled_workflow_candidate(
    run_result: dict,
    project_storage: Path,
    project_root: Path,
) -> Optional[dict[str, Any]]:
    """Return a compiled_workflow candidate or ``None``.

    Per policy §5.3: emitted only when ``final_state == "completed"``
    AND ``<cap_home>/projects/<project_id>/compiled-workflows/
    <workflow_id>/`` contains at least one ``.json`` / ``.yaml`` /
    ``.yml`` snapshot. The most-recent file (by mtime, with filename
    as tiebreaker) is chosen so a workflow that has been recompiled
    multiple times during one task surfaces only its latest snapshot.

    Failed / blocked / cancelled runs are intentionally skipped:
    promoting the compiled workflow under which an execution failed
    would freeze a known-bad artifact into the repo.
    """
    workflow_id = run_result.get("workflow_id")
    final_state = run_result.get("final_state")
    if not workflow_id or final_state != "completed":
        return None

    cw_dir = project_storage / "compiled-workflows" / workflow_id
    if not cw_dir.is_dir():
        return None

    snapshots: list[Path] = []
    for entry in cw_dir.iterdir():
        if entry.is_file() and entry.suffix in {".json", ".yaml", ".yml"}:
            snapshots.append(entry)
    if not snapshots:
        return None

    # mtime descending; fall back to filename (descending) for
    # filesystems with stale mtime resolution.
    snapshots.sort(
        key=lambda p: (p.stat().st_mtime, p.name),
        reverse=True,
    )
    latest = snapshots[0]

    target_path = project_root / ".cap" / "workflows" / f"{workflow_id}.yaml"

    return {
        "source_path": str(latest.resolve()),
        "target_path": str(target_path.resolve()),
        "artifact_type": "compiled_workflow",
        "reason": (
            f"workflow '{workflow_id}' completed without failures; "
            "compiled workflow snapshot is ready to promote to project SSOT"
        ),
        "validation_schema": "schemas/compiled-workflow.schema.yaml",
        "source_layer": run_result.get("source_layer"),
        "source_revision": latest.stem,
    }


def _resolve_cap_home(cap_home: Optional[Path | str]) -> Path:
    if cap_home is not None:
        return Path(cap_home).expanduser().resolve()
    env = os.environ.get("CAP_HOME")
    if env:
        return Path(env).expanduser().resolve()
    return (Path.home() / ".cap").resolve()


def _resolve_project_root(project_root: Optional[Path | str]) -> Path:
    if project_root is not None:
        return Path(project_root).expanduser().resolve()
    env = os.environ.get("CAP_PROJECT_ROOT")
    if env:
        return Path(env).expanduser().resolve()
    return Path.cwd().resolve()
