"""P10 #2 promote candidate producer.

Pure read-only inspector that turns a workflow-result dict (P7 builder
output, **before** ``promote_candidates`` is set) into the
``promote_candidates[]`` list that ``schemas/workflow-result.schema.yaml``
expects. Replaces the P0/P7-era hard-coded ``[]`` placeholder.

Authoritative spec: ``policies/runtime-promote.md`` §5 (producer
contract). Key invariants:

* **Three artifact types** (policy §2 / §5.2 enum, v0.25.7+):
  ``project_constitution``, ``compiled_workflow``, and
  ``spec_artifact``. Run-only artifacts (runtime-state.json /
  agent-sessions.json / route-history.jsonl / step raw logs) and
  binding reports are intentionally excluded.
* **``final_state == "completed"`` required for compiled_workflow
  and spec_artifact** (policy §5.3). A failed / blocked / cancelled
  run's outputs must NOT be promoted, because they are the
  artifacts under which the failure occurred.
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

import json
import os
import re
from pathlib import Path
from typing import Any, Optional


# v0.25.7 spec_artifact mapping (policy §3.3). Maps the runtime-state
# artifact name (key) to a (target_subdir, target_filename_template)
# tuple. The template uses ``{module}`` which the producer fills with
# task_id (slug) → project_id (slug) → "module" literal fallback.
_SPEC_ARTIFACT_TARGET_MAP: dict[str, tuple[str, str]] = {
    "prd_document": ("docs/architecture", "{module}_PRD_v1.md"),
    "tech_plan_document": ("docs/architecture", "{module}_TechPlan_v1.md"),
    "ba_spec": ("docs/architecture", "{module}_BA_v1.md"),
    "schema_ssot": ("docs/architecture/database", "{module}_schema_v1.md"),
    "api_contract": ("docs/architecture", "{module}_API_v1.md"),
    "ui_spec": ("docs/design", "{module}_UI_v1.md"),
}

# Same slug rules as engine/project_context_loader.py:_sanitize_project_id
# so module names land in the same character class consumers expect.
_SLUG_PATTERN = re.compile(r"[^a-z0-9._-]+")
_SLUG_TRIM = re.compile(r"^-+|-+$")
_SLUG_DEDUP = re.compile(r"-+")


def _slug_module_name(raw: str) -> str:
    """Sanitize a string for use in spec_artifact target filenames."""
    lowered = (raw or "").strip().lower()
    replaced = _SLUG_PATTERN.sub("-", lowered)
    trimmed = _SLUG_TRIM.sub("", replaced)
    deduped = _SLUG_DEDUP.sub("-", trimmed)
    return deduped or "module"


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

    # v0.25.7 spec_artifact detection (policy §3.3 + §5.3). Only fires
    # for project-spec-pipeline + final_state=completed; per-artifact
    # validated-state filter inside the helper. Order: project_constitution
    # first (head-of-list contract), compiled_workflow next, then
    # spec_artifact entries in mapping-table order so consumers that
    # take .head[] still get the most-promote-critical type first.
    spec_candidates = _detect_spec_artifact_candidates(
        run_result, project_storage, project_root_path
    )
    candidates.extend(spec_candidates)

    return candidates


def detect_constitution_candidate_for_task(
    task_id: Optional[str],
    *,
    project_storage: Path,
    project_root: Path,
    source_layer: Optional[str] = None,
) -> Optional[dict[str, Any]]:
    """Build a project_constitution candidate dict for ``task_id`` or ``None``.

    Public API used by both ``produce_candidates`` (P10 #2.2 producer
    path) and ``promote_resolver.resolve_promote`` (P10 #3 inspect
    path). Pure read-only path-existence check; no file content is
    parsed. ``None`` is returned when:

    * ``task_id`` is empty / falsy.
    * ``<project_storage>/constitutions/<task_id>/`` does not exist.
    * No ``constitution.{yaml,yml,json}`` is present in that dir.

    ``source_layer`` is informational; pass through whatever P9
    layer marker the caller has (often ``None`` for runtime
    artifacts that did not flow through the layered resolver).
    """
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
        "source_layer": source_layer,
        "source_revision": task_id,
    }


def detect_compiled_workflow_candidate_for(
    workflow_id: Optional[str],
    final_state: Optional[str],
    *,
    project_storage: Path,
    project_root: Path,
    source_layer: Optional[str] = None,
    require_completed: bool = True,
) -> Optional[dict[str, Any]]:
    """Build a compiled_workflow candidate dict for ``workflow_id`` or ``None``.

    Public API used by both ``produce_candidates`` (P10 #2.2 producer
    path, ``require_completed=True``) and ``promote_resolver.resolve_promote``
    (P10 #3 inspect path, may pass ``require_completed=False`` so
    ``cap promote inspect`` can still describe the on-disk snapshot
    when the user is investigating). Pure read-only path-existence
    check; the ``final_state`` gate fires when ``require_completed``
    is true so callers that need the policy §5.3 safety check (no
    failed-run promotes) opt in explicitly.

    ``None`` is returned when:

    * ``workflow_id`` is empty / falsy.
    * ``require_completed`` and ``final_state != "completed"``.
    * ``<project_storage>/compiled-workflows/<workflow_id>/`` does
      not exist or contains no ``.json`` / ``.yaml`` / ``.yml`` files.
    """
    if not workflow_id:
        return None
    if require_completed and final_state != "completed":
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

    if require_completed:
        reason = (
            f"workflow '{workflow_id}' completed without failures; "
            "compiled workflow snapshot is ready to promote to project SSOT"
        )
    else:
        reason = (
            f"compiled workflow snapshot exists for '{workflow_id}' "
            f"(final_state={final_state or 'unknown'}); promote is gated by "
            "policy §5.3 — failed / blocked / cancelled runs cannot be promoted"
        )

    return {
        "source_path": str(latest.resolve()),
        "target_path": str(target_path.resolve()),
        "artifact_type": "compiled_workflow",
        "reason": reason,
        "validation_schema": "schemas/compiled-workflow.schema.yaml",
        "source_layer": source_layer,
        "source_revision": latest.stem,
    }


# ─────────────────────────────────────────────────────────────────────────
# Backward-compat thin wrappers for the producer (run_result-shaped input).
# ─────────────────────────────────────────────────────────────────────────


def _detect_constitution_candidate(
    run_result: dict,
    project_storage: Path,
    project_root: Path,
) -> Optional[dict[str, Any]]:
    return detect_constitution_candidate_for_task(
        run_result.get("task_id"),
        project_storage=project_storage,
        project_root=project_root,
        source_layer=run_result.get("source_layer"),
    )


def _detect_compiled_workflow_candidate(
    run_result: dict,
    project_storage: Path,
    project_root: Path,
) -> Optional[dict[str, Any]]:
    return detect_compiled_workflow_candidate_for(
        run_result.get("workflow_id"),
        run_result.get("final_state"),
        project_storage=project_storage,
        project_root=project_root,
        source_layer=run_result.get("source_layer"),
        require_completed=True,
    )


def _detect_spec_artifact_candidates(
    run_result: dict,
    project_storage: Path,
    project_root: Path,
) -> list[dict[str, Any]]:
    """Build spec_artifact candidates for a completed spec pipeline run.

    v0.25.7 — policy §3.3 + §5.3. Fires only when:

    * ``run_result.workflow_id == "project-spec-pipeline"``,
    * ``run_result.final_state == "completed"``,
    * ``<project_storage>/reports/workflows/project-spec-pipeline/<run_id>/runtime-state.json``
      exists.

    Reads the run's runtime-state.json once and walks the
    ``_SPEC_ARTIFACT_TARGET_MAP`` keys; for each artifact whose
    ``source_step`` reached ``execution_state == "validated"`` and
    whose ``path`` exists on disk, emits one candidate with the
    canonical target derived from the mapping table.

    Returns an empty list (not ``None``) when the run is not a spec
    pipeline run, did not complete, or produced no validated spec
    artifacts. Caller (``produce_candidates``) extends its candidate
    list with the result so a missing spec pipeline silently no-emits
    instead of raising.

    No content parsing (policy §5.4 boundary): only existence checks
    + ``execution_state`` filter. Schema validation deferred to the
    post-apply gate (policy §6.1; spec_artifact runs file-existence +
    non-empty there because spec markdown has no JSON schema).
    """
    if (run_result or {}).get("workflow_id") != "project-spec-pipeline":
        return []
    if (run_result or {}).get("final_state") != "completed":
        return []

    run_id = run_result.get("run_id")
    if not run_id:
        return []

    runtime_state_path = (
        project_storage
        / "reports"
        / "workflows"
        / "project-spec-pipeline"
        / run_id
        / "runtime-state.json"
    )
    if not runtime_state_path.is_file():
        return []

    try:
        state = json.loads(runtime_state_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return []

    artifacts = (state.get("artifacts") or {}) if isinstance(state, dict) else {}
    steps = (state.get("steps") or {}) if isinstance(state, dict) else {}

    # Module name precedence: task_id → project_id → "module" fallback.
    module_raw = (
        run_result.get("task_id")
        or run_result.get("project_id")
        or "module"
    )
    module_name = _slug_module_name(str(module_raw))

    candidates: list[dict[str, Any]] = []
    for artifact_name, (target_subdir, filename_template) in _SPEC_ARTIFACT_TARGET_MAP.items():
        entry = artifacts.get(artifact_name)
        if not isinstance(entry, dict):
            continue

        source_path_raw = entry.get("path")
        if not source_path_raw:
            continue
        source_path = Path(source_path_raw)
        if not source_path.is_file():
            # Source on disk is the canonical existence check; if the
            # artifact registry pointed at a path that no longer
            # exists (rare; pruned run dir), silently skip per policy.
            continue

        source_step = entry.get("source_step")
        source_step_state = (steps.get(source_step) or {}).get("execution_state")
        if source_step_state != "validated":
            continue

        target_filename = filename_template.format(module=module_name)
        target_path = project_root / target_subdir / target_filename

        candidates.append(
            {
                "source_path": str(source_path.resolve()),
                "target_path": str(target_path.resolve()),
                "artifact_type": "spec_artifact",
                "reason": (
                    f"project-spec-pipeline run produced {artifact_name}; ready to "
                    f"promote to repo SSOT under {target_subdir}/"
                ),
                "validation_schema": None,
                "source_layer": run_result.get("source_layer"),
                "source_revision": run_id,
            }
        )

    return candidates


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
