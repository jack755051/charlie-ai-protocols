"""P10 #4 promote apply primitives.

Reusable apply path: backup / write / validate / rollback. Designed so
both ``cap promote project-constitution`` (P10 #4) and
``cap promote workflow`` (P10 #5) consume the same orchestration —
each typed subcommand only differs by ``expected_artifact_type``.

Authoritative spec: ``policies/runtime-promote.md`` §4 (overwrite /
backup / skip rules) + §6 (post-apply validation + rollback).

Reuses ``promote_resolver.ResolvedPromote`` (P10 #3 read-only data
layer) and ``promote_resolver.make_template_backup_path`` (shared
``<target>.bak.<ISO>`` naming) so resolver, inspect, and apply all
agree on the same conflict_kind enum and backup convention.
"""
from __future__ import annotations

import json
import shutil
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

from engine.promote_resolver import (
    CONFLICT_DIFF,
    CONFLICT_IDENTICAL,
    CONFLICT_NO_TARGET,
    ResolvedPromote,
    make_template_backup_path,
)


# Action enum surfaced via ApplyResult.action. Captures the full
# branch outcome so the CLI / JSON consumer can render or react
# without re-deriving from individual flags.
ACTION_DRY_RUN_NO_TARGET = "dry_run_no_target"
ACTION_DRY_RUN_IDENTICAL = "dry_run_identical"
ACTION_DRY_RUN_CONFLICT = "dry_run_conflict"
ACTION_DRY_RUN_FORCE_OVERWRITE = "dry_run_force_overwrite"

ACTION_APPLIED_FRESH = "applied_fresh"
ACTION_APPLIED_IDENTICAL_SKIP = "applied_identical_skip"
ACTION_APPLIED_FORCE_WITH_BACKUP = "applied_force_with_backup"

ACTION_HALTED_CONFLICT = "halted_conflict"
ACTION_HALTED_TYPE_MISMATCH = "halted_type_mismatch"
ACTION_HALTED_BACKUP_FAILED = "halted_backup_failed"
ACTION_HALTED_WRITE_FAILED = "halted_write_failed"

ACTION_VALIDATION_FAILED_ROLLED_BACK = "validation_failed_rolled_back"
ACTION_VALIDATION_FAILED_ROLLBACK_FAILED = "validation_failed_rollback_failed"


@dataclass(frozen=True)
class ApplyResult:
    """Outcome of one ``apply_promote`` call.

    ``action`` is the only field guaranteed to be set; others may be
    ``None`` depending on which branch fired. The CLI maps
    ``ok = action.startswith("applied_") or action.startswith("dry_run_")``
    when ``error`` is also ``None``.
    """

    action: str
    artifact_id: Optional[str]
    artifact_type: Optional[str]
    source_path: Optional[str]
    target_path: Optional[str]
    target_existed_before: bool
    backup_path: Optional[str]
    validation: Optional[dict[str, Any]]
    error: Optional[str]
    detail: Optional[str]
    extra: dict[str, Any] = field(default_factory=dict)

    @property
    def ok(self) -> bool:
        if self.error is not None:
            return False
        return self.action.startswith(("applied_", "dry_run_"))


def apply_promote(
    resolved: ResolvedPromote,
    *,
    expected_artifact_type: str,
    dry_run: bool,
    force: bool,
    artifact_id: Optional[str] = None,
    cap_root: Optional[Path | str] = None,
) -> ApplyResult:
    """Run the dry-run / apply / validate / rollback flow for one candidate.

    Args:
        resolved: ``ResolvedPromote`` from
            ``promote_resolver.resolve_promote`` — already contains the
            candidate dict, conflict_kind, and validation_schema, so
            this function does not re-run the resolver.
        expected_artifact_type: The CLI subcommand the caller fronted
            (e.g. ``project_constitution`` for ``cap promote
            project-constitution``). If the resolved candidate's
            ``artifact_type`` doesn't match, the caller invoked the
            wrong typed subcommand; halt with
            ``promote_artifact_type_mismatch`` so the user can re-run
            with the right one.
        dry_run: When ``True`` no I/O happens; the returned
            ``ApplyResult`` describes what *would* have happened.
        force: When ``True`` and ``conflict_kind=diff``, the apply
            backs up the existing target (``<target>.bak.<ISO>``)
            before overwriting. ``False`` + diff → halt at
            ``promote_conflict_halt``.
        artifact_id: Pass-through identifier for surfaces (e.g. the
            task_id or workflow_id the user typed); used purely for
            the JSON output's ``artifact_id`` field. ``None``
            falls back to the candidate's ``source_revision``.
        cap_root: Repository root used to resolve a relative
            ``validation_schema`` path. Defaults to the repo
            containing this module.
    """
    candidate = resolved.candidate or {}
    actual_type = candidate.get("artifact_type")

    artifact_id_eff = artifact_id or candidate.get("source_revision")
    source_path_str = candidate.get("source_path") or ""
    target_path_str = candidate.get("target_path") or ""

    if actual_type != expected_artifact_type:
        return ApplyResult(
            action=ACTION_HALTED_TYPE_MISMATCH,
            artifact_id=artifact_id_eff,
            artifact_type=actual_type,
            source_path=source_path_str or None,
            target_path=target_path_str or None,
            target_existed_before=resolved.target_exists,
            backup_path=None,
            validation=None,
            error="promote_artifact_type_mismatch",
            detail=(
                f"resolved artifact_type='{actual_type}' but caller expected "
                f"'{expected_artifact_type}'; use the matching cap promote "
                "subcommand for the artifact type"
            ),
        )

    target_path = Path(target_path_str)
    source_path = Path(source_path_str)

    # ── Dry-run path: describe, no I/O ────────────────────────────

    if dry_run:
        if resolved.conflict_kind == CONFLICT_NO_TARGET:
            action = ACTION_DRY_RUN_NO_TARGET
            detail = "would write a fresh target (no backup needed)"
            backup = None
        elif resolved.conflict_kind == CONFLICT_IDENTICAL:
            action = ACTION_DRY_RUN_IDENTICAL
            detail = "target is byte-equal source; would short-circuit (already_promoted)"
            backup = None
        elif resolved.conflict_kind == CONFLICT_DIFF and not force:
            action = ACTION_DRY_RUN_CONFLICT
            detail = "target differs from source; --apply alone would halt; pass --force to overwrite with backup"
            backup = resolved.backup_path
        else:  # diff + force
            action = ACTION_DRY_RUN_FORCE_OVERWRITE
            detail = "target differs; --apply --force would back up to <target>.bak.<ISO> then overwrite"
            backup = resolved.backup_path
        return ApplyResult(
            action=action,
            artifact_id=artifact_id_eff,
            artifact_type=actual_type,
            source_path=source_path_str,
            target_path=target_path_str,
            target_existed_before=resolved.target_exists,
            backup_path=backup,
            validation=None,
            error=None,
            detail=detail,
        )

    # ── Apply path: identical short-circuit ───────────────────────

    if resolved.conflict_kind == CONFLICT_IDENTICAL:
        return ApplyResult(
            action=ACTION_APPLIED_IDENTICAL_SKIP,
            artifact_id=artifact_id_eff,
            artifact_type=actual_type,
            source_path=source_path_str,
            target_path=target_path_str,
            target_existed_before=True,
            backup_path=None,
            validation=None,
            error=None,
            detail="target byte-equal source; nothing to write",
        )

    # ── Apply path: conflict halt without --force ─────────────────

    if resolved.conflict_kind == CONFLICT_DIFF and not force:
        return ApplyResult(
            action=ACTION_HALTED_CONFLICT,
            artifact_id=artifact_id_eff,
            artifact_type=actual_type,
            source_path=source_path_str,
            target_path=target_path_str,
            target_existed_before=True,
            backup_path=None,
            validation=None,
            error="promote_conflict_halt",
            detail="target exists and differs from source; pass --force to back up and overwrite",
        )

    # ── Apply path: backup (only when diff + force) ───────────────

    backup_path_actual: Optional[str] = None
    if resolved.conflict_kind == CONFLICT_DIFF:
        # Generate a real timestamp now so apply ↔ rollback can
        # reference the same file even if the wall clock has moved
        # since the inspect-time template was rendered.
        backup_path_actual = make_template_backup_path(target_path)
        try:
            shutil.copy2(target_path, backup_path_actual)
        except OSError as exc:
            return ApplyResult(
                action=ACTION_HALTED_BACKUP_FAILED,
                artifact_id=artifact_id_eff,
                artifact_type=actual_type,
                source_path=source_path_str,
                target_path=target_path_str,
                target_existed_before=True,
                backup_path=None,
                validation=None,
                error="promote_backup_failed",
                detail=f"copying {target_path} to {backup_path_actual}: {exc}",
            )

    # ── Apply path: write target ──────────────────────────────────

    target_existed_before = resolved.target_exists
    try:
        target_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_path, target_path)
    except OSError as exc:
        # Write failed; if we made a backup just before, leave it in
        # place — it's how a human would recover.
        return ApplyResult(
            action=ACTION_HALTED_WRITE_FAILED,
            artifact_id=artifact_id_eff,
            artifact_type=actual_type,
            source_path=source_path_str,
            target_path=target_path_str,
            target_existed_before=target_existed_before,
            backup_path=backup_path_actual,
            validation=None,
            error="promote_write_failed",
            detail=f"copying {source_path} to {target_path}: {exc}",
        )

    # ── Apply path: post-write validation ─────────────────────────

    validation_result: Optional[dict[str, Any]] = None
    if resolved.validation_schema:
        validation_result = _validate_target_via_step_runtime(
            target_path, resolved.validation_schema, cap_root=cap_root
        )
        if not validation_result.get("ok", False):
            rollback_ok, rollback_detail = _rollback_target(
                target_path, backup_path_actual, target_existed_before
            )
            if rollback_ok:
                return ApplyResult(
                    action=ACTION_VALIDATION_FAILED_ROLLED_BACK,
                    artifact_id=artifact_id_eff,
                    artifact_type=actual_type,
                    source_path=source_path_str,
                    target_path=target_path_str,
                    target_existed_before=target_existed_before,
                    backup_path=backup_path_actual,
                    validation=validation_result,
                    error="promote_validation_failed",
                    detail="post-apply validation failed; target rolled back to pre-apply state",
                )
            return ApplyResult(
                action=ACTION_VALIDATION_FAILED_ROLLBACK_FAILED,
                artifact_id=artifact_id_eff,
                artifact_type=actual_type,
                source_path=source_path_str,
                target_path=target_path_str,
                target_existed_before=target_existed_before,
                backup_path=backup_path_actual,
                validation=validation_result,
                error="promote_rollback_failed",
                detail=(
                    f"post-apply validation failed AND rollback failed; "
                    f"target may be in inconsistent state — manual recovery required. "
                    f"rollback detail: {rollback_detail}"
                ),
            )

    # ── Apply path: success ───────────────────────────────────────

    action = (
        ACTION_APPLIED_FORCE_WITH_BACKUP if backup_path_actual else ACTION_APPLIED_FRESH
    )
    return ApplyResult(
        action=action,
        artifact_id=artifact_id_eff,
        artifact_type=actual_type,
        source_path=source_path_str,
        target_path=target_path_str,
        target_existed_before=target_existed_before,
        backup_path=backup_path_actual,
        validation=validation_result,
        error=None,
        detail=None,
    )


def _validate_target_via_step_runtime(
    target_path: Path,
    validation_schema: str,
    *,
    cap_root: Optional[Path | str] = None,
) -> dict[str, Any]:
    """Validate ``target_path`` against ``validation_schema``.

    Loads the target with format auto-detection (``.json`` → JSON,
    everything else including ``.yaml`` / ``.yml`` and unsuffixed
    files → YAML, which is a JSON-superset). ``step_runtime.py
    validate-jsonschema`` is JSON-only and would reject YAML targets
    like ``.cap/constitution.yaml``, so this helper does the parse +
    validate inline — the previous subprocess version was the wrong
    contract. Returns the canonical
    ``{"ok": bool, "errors": list[str]}`` shape used elsewhere in
    CAP so consumers cannot distinguish this code path from a
    step_runtime call.

    Validation engine: prefers ``jsonschema.Draft202012Validator``
    when available; falls back to
    ``engine.step_runtime.validate_jsonschema_fallback`` in degraded
    environments. Both paths produce the same ``errors`` shape.
    """
    cap_root_path = (
        Path(cap_root).expanduser().resolve()
        if cap_root is not None
        else Path(__file__).resolve().parent.parent
    )
    schema_path = Path(validation_schema)
    if not schema_path.is_absolute():
        schema_path = cap_root_path / schema_path

    if not target_path.is_file():
        return {
            "ok": False,
            "errors": [f"target file not found: {target_path}"],
        }
    if not schema_path.is_file():
        return {
            "ok": False,
            "errors": [f"schema file not found: {schema_path}"],
        }

    try:
        import yaml  # type: ignore[import]
    except ImportError:
        return {
            "ok": False,
            "errors": ["pyyaml is required for promote validation"],
        }

    try:
        target_text = target_path.read_text(encoding="utf-8")
        if target_path.suffix == ".json":
            data = json.loads(target_text)
        else:
            data = yaml.safe_load(target_text)
    except Exception as exc:  # noqa: BLE001 — surface parse errors as validation failure
        return {
            "ok": False,
            "errors": [
                f"target parse error ({target_path.suffix or 'no-suffix'}): {exc}"
            ],
        }

    try:
        schema = yaml.safe_load(schema_path.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        return {
            "ok": False,
            "errors": [f"schema parse error: {exc}"],
        }

    errors: list[str] = []
    try:
        from jsonschema import Draft202012Validator  # type: ignore[import]

        validator = Draft202012Validator(schema)
        for err in sorted(validator.iter_errors(data), key=lambda e: list(e.absolute_path)):
            loc = "/".join(str(p) for p in err.absolute_path) or "<root>"
            errors.append(f"{loc}: {err.message}")
    except ImportError:
        try:
            from engine.step_runtime import validate_jsonschema_fallback
        except ImportError:  # pragma: no cover — defensive
            return {
                "ok": False,
                "errors": [
                    "neither jsonschema nor engine.step_runtime.validate_jsonschema_fallback is importable"
                ],
            }
        errors.extend(validate_jsonschema_fallback(data, schema))

    return {"ok": not errors, "errors": errors}


def _rollback_target(
    target_path: Path,
    backup_path: Optional[str],
    target_existed_before: bool,
) -> tuple[bool, str]:
    """Restore target to its pre-apply state. Returns ``(ok, detail)``.

    Rollback strategy per policy §6.2:

    * ``target_existed_before=False`` → delete the freshly-written
      target. If delete fails, the target is now an inconsistent
      file the user must clean up manually.
    * ``target_existed_before=True`` AND ``backup_path`` set → copy
      the backup back over the target. Backup file is preserved
      (policy §4.3 — backups never auto-prune).
    * ``target_existed_before=True`` but no ``backup_path`` →
      shouldn't happen in practice (apply only skips backup when
      conflict was no_target), but guard anyway: report failure so
      the caller surfaces it.
    """
    if not target_existed_before:
        try:
            target_path.unlink(missing_ok=True)
            return True, f"deleted freshly-written target {target_path}"
        except OSError as exc:
            return False, f"unlink {target_path} failed: {exc}"

    if not backup_path:
        return (
            False,
            "target existed before but no backup was taken; cannot reconstruct pre-apply state",
        )

    try:
        shutil.copy2(backup_path, target_path)
        return True, f"restored {target_path} from {backup_path}"
    except OSError as exc:
        return False, f"copying backup {backup_path} to {target_path} failed: {exc}"
