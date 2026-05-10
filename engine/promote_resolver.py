"""P10 #3 promote resolver — read-only data layer for ``cap promote inspect``.

Pure inspector that takes an artifact id (task_id or workflow_id) plus
project + cap_home context and returns a fully-populated
``ResolvedPromote`` describing what would happen if the user ran the
matching ``cap promote project-constitution`` / ``cap promote workflow``.

Authoritative spec: ``policies/runtime-promote.md`` §7.1 (inspect
output) plus §4 (overwrite / backup / skip rules) — the resolver
implements those rules as pure data so #3 (inspect) can render them
and #4 (apply) can act on the same dataclass without re-deriving.

Responsibility boundary (memo-stage agreement with the user):

* **Resolver owns**: candidate lookup, target_path computation,
  conflict_kind classification, backup_path template generation,
  validation_schema lookup. Returns pure data — no I/O beyond stat
  / open-for-byte-compare.
* **inspect (#3) owns**: rendering the resolver's data as text or
  JSON. Never writes.
* **apply (#4) owns**: write / backup / validate / rollback. Consumes
  the same dataclass; does not poke resolver internals.

The resolver re-uses the typed detectors exposed by
``promote_candidate_producer.detect_constitution_candidate_for_task``
and ``detect_compiled_workflow_candidate_for`` so the producer (P10
#2.2) and the resolver (P10 #3) share the same candidate-shape
contract.
"""
from __future__ import annotations

import filecmp
import os
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from engine.promote_candidate_producer import (
    detect_compiled_workflow_candidate_for,
    detect_constitution_candidate_for_task,
    detect_spec_artifact_candidate_for_name,
)


# Conflict classification per policy §4.2:
#
# * ``no_target`` — target file does not exist. ``cap promote --apply``
#   will write fresh, no backup needed.
# * ``identical`` — target exists and is byte-equal to source. Apply
#   short-circuits with ``already_promoted`` (exit 0); no backup, no
#   validation re-run.
# * ``diff`` — target exists but differs from source. Apply halts at
#   ``conflict`` unless ``--force`` is passed; ``--force`` triggers a
#   timestamped backup before overwriting.
CONFLICT_NO_TARGET = "no_target"
CONFLICT_IDENTICAL = "identical"
CONFLICT_DIFF = "diff"

# Inspect-time backup path template. The resolver does NOT generate a
# real timestamp because each apply run produces a unique one; instead
# the placeholder ``<ISO>`` makes the template explicit so the user
# understands the actual filename varies per apply.
BACKUP_TEMPLATE_SUFFIX = ".bak.<ISO>"


@dataclass(frozen=True)
class ResolvedPromote:
    """Pure data shape consumed by inspect (#3) and apply (#4).

    Mirrors the schema-shape candidate (P10 #2.1 contract) plus the
    on-disk state needed to decide what would happen on apply.
    """

    candidate: dict[str, Any]  # P10 #2.1 schema-shape candidate dict
    target_exists: bool
    conflict_kind: str  # CONFLICT_NO_TARGET | CONFLICT_IDENTICAL | CONFLICT_DIFF
    backup_path: Optional[str]  # template path; only set when conflict_kind == 'diff'
    backup_required: bool  # True iff apply --force would write a backup
    validation_schema: Optional[str]
    smoke_plan: dict[str, Any] = field(default_factory=dict)


def resolve_promote(
    artifact_id: str,
    *,
    project_id: Optional[str] = None,
    project_root: Optional[Path | str] = None,
    cap_home: Optional[Path | str] = None,
) -> Optional[ResolvedPromote]:
    """Resolve ``artifact_id`` to a ``ResolvedPromote`` or ``None``.

    Lookup order: try ``artifact_id`` as a task_id (constitution
    snapshot), then as a workflow_id (compiled workflow snapshot).
    First match wins; both miss → ``None``.

    Args:
        artifact_id: task_id or workflow_id; resolver tries both
            interpretations.
        project_id: optional override; default resolves via
            ``ProjectContextLoader`` against ``project_root``.
        project_root: precedence kwarg > ``CAP_PROJECT_ROOT`` env >
            ``Path.cwd()`` (matches P9 / P10 #2.2 convention).
        cap_home: precedence kwarg > ``CAP_HOME`` env > ``~/.cap``.

    Inspect-only: never writes. The compiled_workflow detector is
    invoked with ``require_completed=False`` so an in-progress or
    failed run's snapshot is still describable; the actual policy
    §5.3 gate (no failed-run promotes) fires in apply (#4), where it
    can react with a halt + JSON error.
    """
    project_root_path = _resolve_project_root(project_root)
    cap_home_path = _resolve_cap_home(cap_home)
    resolved_project_id = project_id or _resolve_project_id(project_root_path)
    if not resolved_project_id or resolved_project_id == "unknown":
        return None

    project_storage = cap_home_path / "projects" / resolved_project_id

    # 1) Try as task_id (constitution snapshot).
    constitution = detect_constitution_candidate_for_task(
        artifact_id,
        project_storage=project_storage,
        project_root=project_root_path,
    )
    if constitution is not None:
        return _build_resolved(constitution)

    # 2) Try as workflow_id (compiled workflow snapshot, no
    # final_state gate at inspect time per the docstring).
    compiled = detect_compiled_workflow_candidate_for(
        artifact_id,
        None,
        project_storage=project_storage,
        project_root=project_root_path,
        require_completed=False,
    )
    if compiled is not None:
        return _build_resolved(compiled)

    # 3) v0.25.7 — try as spec_artifact name (one of the six policy
    # §3.3 mapping keys: prd_document / tech_plan_document / ba_spec /
    # schema_ssot / api_contract / ui_spec). Latest validated
    # project-spec-pipeline run wins; same candidate shape as the
    # producer's _detect_spec_artifact_candidates so inspect output
    # and result.md's promote_candidates section agree byte-for-byte.
    spec = detect_spec_artifact_candidate_for_name(
        artifact_id,
        project_storage=project_storage,
        project_root=project_root_path,
    )
    if spec is not None:
        return _build_resolved(spec)

    return None


def _build_resolved(candidate: dict[str, Any]) -> ResolvedPromote:
    """Enrich a schema-shape candidate dict with on-disk conflict state."""
    target_path_str = candidate.get("target_path") or ""
    source_path_str = candidate.get("source_path") or ""
    target_path = Path(target_path_str)
    source_path = Path(source_path_str)

    target_exists = target_path.is_file()
    if not target_exists:
        conflict_kind = CONFLICT_NO_TARGET
    elif _files_byte_equal(source_path, target_path):
        conflict_kind = CONFLICT_IDENTICAL
    else:
        conflict_kind = CONFLICT_DIFF

    backup_path: Optional[str]
    if conflict_kind == CONFLICT_DIFF:
        backup_path = f"{target_path_str}{BACKUP_TEMPLATE_SUFFIX}"
        backup_required = True
    else:
        backup_path = None
        backup_required = False

    validation_schema = candidate.get("validation_schema")
    smoke_plan = _build_smoke_plan(candidate.get("artifact_type"), validation_schema)

    return ResolvedPromote(
        candidate=candidate,
        target_exists=target_exists,
        conflict_kind=conflict_kind,
        backup_path=backup_path,
        backup_required=backup_required,
        validation_schema=validation_schema,
        smoke_plan=smoke_plan,
    )


def _build_smoke_plan(artifact_type: Optional[str], validation_schema: Optional[str]) -> dict[str, Any]:
    """Describe the validation steps apply (#4) will run after writing.

    Schema validation always runs (policy §6.1). Compile/bind smoke is
    optional, opt-in via ``cap promote workflow --smoke`` per policy
    §6.3; inspect surfaces it as a plan entry so the user knows the
    flag exists.
    """
    plan: dict[str, Any] = {
        "schema_validate": {
            "enabled": validation_schema is not None,
            "schema_path": validation_schema,
        }
    }
    if artifact_type == "compiled_workflow":
        plan["compile_bind_smoke"] = {
            "enabled": False,
            "opt_in_flag": "--smoke",
            "note": (
                "compile + bind smoke runs against the promoted workflow "
                "without spawning agents; opt-in via --smoke at apply time"
            ),
        }
    return plan


def _files_byte_equal(a: Path, b: Path) -> bool:
    """Best-effort byte-level equality check.

    Wraps ``filecmp.cmp(shallow=False)`` so the inspect output's
    ``identical`` classification reflects actual contents rather than
    just stat metadata. Returns ``False`` on any I/O error so a
    permission glitch on either path falls into the safe ``diff``
    branch (forcing the user through the conflict path).
    """
    try:
        return filecmp.cmp(str(a), str(b), shallow=False)
    except OSError:
        return False


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


def _resolve_project_id(project_root: Path) -> Optional[str]:
    """Best-effort project_id resolution mirroring ProjectContextLoader.

    Prefer ``CAP_PROJECT_ID_OVERRIDE`` so test harnesses can pin an id;
    otherwise read ``<project_root>/.cap/project.yaml`` (namespaced)
    or ``<project_root>/.cap.project.yaml`` (legacy). When neither
    yields a project_id, return ``None`` and the caller's
    ``resolve_promote`` will short-circuit to ``None`` — same as the
    producer's ``project_id == "unknown"`` branch.
    """
    override = os.environ.get("CAP_PROJECT_ID_OVERRIDE")
    if override:
        return override

    for candidate in (project_root / ".cap" / "project.yaml", project_root / ".cap.project.yaml"):
        if not candidate.is_file():
            continue
        try:
            import yaml  # local import keeps module import cheap

            data = yaml.safe_load(candidate.read_text(encoding="utf-8")) or {}
        except Exception:  # noqa: BLE001 — best-effort fallback chain
            continue
        if isinstance(data, dict):
            project_id = data.get("project_id")
            if isinstance(project_id, str) and project_id:
                return project_id
    return None


def make_template_backup_path(target_path: Path | str, *, timestamp: Optional[datetime] = None) -> str:
    """Generate the actual ``<target>.bak.<ISO>`` path apply (#4) will write.

    Lives in the resolver module so #4 reuses the same naming
    convention without re-deriving the template. ``timestamp``
    defaults to UTC now; tests can pin it for deterministic
    assertions.
    """
    ts = (timestamp or datetime.now(timezone.utc)).strftime("%Y%m%dT%H%M%SZ")
    return f"{target_path}.bak.{ts}"
