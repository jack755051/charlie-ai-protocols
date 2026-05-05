"""migrate_config — Move legacy CAP config dotfiles into the .cap/ namespace.

P0c CAP Config Namespace Migration — batch 2 (producer side; batch 1 already
landed read compat in scripts/cap-paths.sh + 3 Python readers, see
docs/cap/ARCHITECTURE.md §Config vs Runtime Storage Boundary).

The migration is **copy + keep**: legacy files at the repo root are copied to
``<project_root>/.cap/<name>`` and the originals are preserved. Callers must
explicitly opt in to the destructive ``--remove-legacy`` flag after they have
verified the new files load correctly. ``--dry-run`` shows the plan without
writing anything; ``--force`` allows overwriting an existing target file.

The four legacy → new mappings:

  .cap.project.yaml       → .cap/project.yaml
  .cap.constitution.yaml  → .cap/constitution.yaml
  .cap.skills.yaml        → .cap/skills.yaml
  .cap.agents.json        → .cap/agents.json

Per-file action verdict (see ``Action`` enum):

  skip_no_legacy     — legacy file absent; nothing to do.
  copy               — legacy present, target absent; will copy.
  already_migrated   — legacy + target both present with identical bytes;
                       idempotent re-run, no write.
  conflict           — legacy + target diverge; refuse unless --force.

Exit codes (read by scripts/cap-project.sh):

  0  — success, dry-run, nothing to migrate, or every entry already_migrated.
  1  — at least one conflict and --force not set.

Design boundary:
  * Pure module — no engine imports. Callers (cap-project.sh) decide when to
    invoke; the helper does not look up project_id, never touches
    ~/.cap/projects/, never re-reads the resolver. It is **only** about
    repo-root file moves so batch 3 (this repo's own migration) reuses the
    same producer.
  * Idempotent — re-running the same plan with no changes leaves disk untouched.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any


# Order matters for human-readable output (project / constitution come first
# because they are read more often by other CAP modules; skills / agents are
# optional registries).
LEGACY_TO_NEW: tuple[tuple[str, str, str], ...] = (
    ("project",      ".cap.project.yaml",      ".cap/project.yaml"),
    ("constitution", ".cap.constitution.yaml", ".cap/constitution.yaml"),
    ("skills",       ".cap.skills.yaml",       ".cap/skills.yaml"),
    ("agents",       ".cap.agents.json",       ".cap/agents.json"),
)


class Action(str, Enum):
    """Per-entry verdict produced by :func:`plan_migration`."""

    SKIP_NO_LEGACY = "skip_no_legacy"
    COPY = "copy"
    ALREADY_MIGRATED = "already_migrated"
    CONFLICT = "conflict"


@dataclass(frozen=True)
class PlanEntry:
    """Single-file migration verdict.

    ``legacy_path`` and ``target_path`` are stored relative to the project root
    (using forward slashes) so the same plan serializes identically across
    operating systems and is easy to diff in test fixtures.
    """

    name: str
    legacy_path: str
    target_path: str
    action: Action
    legacy_present: bool
    target_present: bool


@dataclass(frozen=True)
class MigrationPlan:
    """Result of :func:`plan_migration`. Use :func:`needs_action` to decide
    whether to call :func:`apply_migration`."""

    project_root: str
    entries: tuple[PlanEntry, ...]


@dataclass(frozen=True)
class ApplyEntry:
    """Per-entry post-apply outcome.

    ``copied`` reflects whether bytes were written (a no-op
    ``already_migrated`` entry returns ``copied=False``); ``legacy_removed``
    is only true when ``--remove-legacy`` was set and the source was removed
    after a successful copy.
    """

    name: str
    legacy_path: str
    target_path: str
    action: Action
    copied: bool
    legacy_removed: bool
    error: str | None = None


@dataclass(frozen=True)
class MigrationResult:
    project_root: str
    entries: tuple[ApplyEntry, ...]
    conflicts: tuple[str, ...] = field(default_factory=tuple)


def plan_migration(project_root: Path) -> MigrationPlan:
    """Compute a per-file verdict for the project root.

    Pure: never writes, never raises. Callers can render the plan via
    :func:`format_plan` (text), :func:`plan_to_dict` (json/yaml).
    """
    entries: list[PlanEntry] = []
    for name, legacy_rel, target_rel in LEGACY_TO_NEW:
        legacy_abs = project_root / legacy_rel
        target_abs = project_root / target_rel
        legacy_present = legacy_abs.is_file()
        target_present = target_abs.is_file()

        if not legacy_present:
            action = Action.SKIP_NO_LEGACY
        elif not target_present:
            action = Action.COPY
        elif _files_identical(legacy_abs, target_abs):
            action = Action.ALREADY_MIGRATED
        else:
            action = Action.CONFLICT

        entries.append(
            PlanEntry(
                name=name,
                legacy_path=legacy_rel,
                target_path=target_rel,
                action=action,
                legacy_present=legacy_present,
                target_present=target_present,
            )
        )
    return MigrationPlan(project_root=str(project_root), entries=tuple(entries))


def needs_action(plan: MigrationPlan) -> bool:
    """True when the plan would write to disk (any COPY or CONFLICT entry).

    ``ALREADY_MIGRATED`` and ``SKIP_NO_LEGACY`` do not require action.
    """
    return any(
        entry.action in (Action.COPY, Action.CONFLICT) for entry in plan.entries
    )


def apply_migration(
    plan: MigrationPlan,
    *,
    force: bool = False,
    remove_legacy: bool = False,
) -> MigrationResult:
    """Materialize the plan on disk.

    ``force=False`` (default): refuse to write when the entry's action is
    ``CONFLICT`` — the corresponding ``ApplyEntry`` records ``copied=False``
    and the file name is appended to ``MigrationResult.conflicts``.

    ``remove_legacy=True``: delete the legacy file after a successful copy
    (or after confirming an idempotent ``already_migrated`` state). Never
    deletes when copy itself failed.
    """
    project_root = Path(plan.project_root)
    applied: list[ApplyEntry] = []
    conflicts: list[str] = []

    for entry in plan.entries:
        legacy_abs = project_root / entry.legacy_path
        target_abs = project_root / entry.target_path
        copied = False
        legacy_removed = False
        error: str | None = None

        if entry.action == Action.SKIP_NO_LEGACY:
            applied.append(_apply_entry(entry, copied, legacy_removed, error))
            continue

        if entry.action == Action.CONFLICT and not force:
            conflicts.append(entry.name)
            applied.append(_apply_entry(entry, copied, legacy_removed, error))
            continue

        if entry.action in (Action.COPY, Action.CONFLICT):
            try:
                target_abs.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(legacy_abs, target_abs)
                copied = True
            except OSError as exc:
                error = f"copy failed: {exc}"
                applied.append(_apply_entry(entry, copied, legacy_removed, error))
                continue

        if remove_legacy and (copied or entry.action == Action.ALREADY_MIGRATED):
            try:
                legacy_abs.unlink()
                legacy_removed = True
            except OSError as exc:
                error = f"legacy unlink failed: {exc}"

        applied.append(_apply_entry(entry, copied, legacy_removed, error))

    return MigrationResult(
        project_root=str(project_root),
        entries=tuple(applied),
        conflicts=tuple(conflicts),
    )


def plan_to_dict(plan: MigrationPlan) -> dict[str, Any]:
    return {
        "project_root": plan.project_root,
        "entries": [
            {
                "name": e.name,
                "legacy_path": e.legacy_path,
                "target_path": e.target_path,
                "action": e.action.value,
                "legacy_present": e.legacy_present,
                "target_present": e.target_present,
            }
            for e in plan.entries
        ],
    }


def result_to_dict(result: MigrationResult) -> dict[str, Any]:
    return {
        "project_root": result.project_root,
        "conflicts": list(result.conflicts),
        "entries": [
            {
                "name": e.name,
                "legacy_path": e.legacy_path,
                "target_path": e.target_path,
                "action": e.action.value,
                "copied": e.copied,
                "legacy_removed": e.legacy_removed,
                "error": e.error,
            }
            for e in result.entries
        ],
    }


def format_plan(plan: MigrationPlan) -> str:
    """Human-readable plan for ``--dry-run`` output."""
    lines: list[str] = [
        f"migration plan for {plan.project_root}",
        "",
    ]
    for entry in plan.entries:
        lines.append(
            f"  {entry.name:<13} [{entry.action.value:<16}] "
            f"{entry.legacy_path}  ->  {entry.target_path}"
        )
    if not needs_action(plan):
        lines.append("")
        lines.append("nothing to migrate (all entries skip_no_legacy or already_migrated).")
    else:
        copy_n = sum(1 for e in plan.entries if e.action == Action.COPY)
        conflict_n = sum(1 for e in plan.entries if e.action == Action.CONFLICT)
        lines.append("")
        lines.append(
            f"summary: {copy_n} copy, {conflict_n} conflict "
            f"(use --force to overwrite, --remove-legacy to delete sources)."
        )
    return "\n".join(lines)


def format_result(result: MigrationResult, *, remove_legacy: bool) -> str:
    """Human-readable post-apply summary for the default text format."""
    lines: list[str] = [f"migration result for {result.project_root}", ""]
    for entry in result.entries:
        flag = "OK" if (entry.copied or entry.action == Action.ALREADY_MIGRATED) else "  "
        if entry.error:
            flag = "FAIL"
        elif entry.action == Action.CONFLICT and not entry.copied:
            flag = "BLOCK"
        elif entry.action == Action.SKIP_NO_LEGACY:
            flag = "SKIP"
        bits = [
            f"  [{flag:<5}] {entry.name:<13} {entry.legacy_path}  ->  {entry.target_path}"
        ]
        details: list[str] = []
        if entry.copied:
            details.append("copied")
        if remove_legacy and entry.legacy_removed:
            details.append("legacy_removed")
        if entry.error:
            details.append(f"error={entry.error}")
        if details:
            bits.append(f"  ({', '.join(details)})")
        lines.append("".join(bits))
    if result.conflicts:
        lines.append("")
        lines.append(
            f"refused: conflicting target file(s) for {', '.join(result.conflicts)}; "
            "re-run with --force to overwrite."
        )
    return "\n".join(lines)


# ─────────────────────────────────────────────────────────
# Internal helpers
# ─────────────────────────────────────────────────────────

def _files_identical(a: Path, b: Path) -> bool:
    try:
        return a.read_bytes() == b.read_bytes()
    except OSError:
        return False


def _apply_entry(
    entry: PlanEntry, copied: bool, legacy_removed: bool, error: str | None
) -> ApplyEntry:
    return ApplyEntry(
        name=entry.name,
        legacy_path=entry.legacy_path,
        target_path=entry.target_path,
        action=entry.action,
        copied=copied,
        legacy_removed=legacy_removed,
        error=error,
    )


# ─────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────

def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="cap project migrate-config",
        description=(
            "Copy legacy .cap.* dotfiles at the repo root into the .cap/ "
            "namespace introduced in P0c batch 1. Defaults to non-destructive "
            "copy; legacy files are kept until --remove-legacy is passed."
        ),
    )
    parser.add_argument(
        "--project-root",
        default=".",
        help="Project root containing the legacy .cap.* files (default: $PWD).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show the migration plan without writing anything.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite an existing .cap/<name> when its content differs from the legacy file.",
    )
    parser.add_argument(
        "--remove-legacy",
        action="store_true",
        help=(
            "Delete the legacy .cap.<name> source after a successful copy "
            "(or after confirming an already-migrated entry). "
            "Recommended only after the new path is verified."
        ),
    )
    parser.add_argument(
        "--format",
        choices=("text", "json", "yaml"),
        default="text",
        help="Output format (default: text).",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    project_root = Path(args.project_root).resolve()

    plan = plan_migration(project_root)

    if args.dry_run:
        _emit(plan_to_dict(plan), format_plan(plan), args.format)
        return 0

    result = apply_migration(
        plan, force=args.force, remove_legacy=args.remove_legacy
    )

    _emit(
        result_to_dict(result),
        format_result(result, remove_legacy=args.remove_legacy),
        args.format,
    )

    return 1 if result.conflicts else 0


def _emit(payload: dict[str, Any], text: str, fmt: str) -> None:
    if fmt == "json":
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return
    if fmt == "yaml":
        try:
            import yaml  # type: ignore[import]
        except ImportError:
            print(json.dumps(payload, ensure_ascii=False, indent=2))
            return
        print(yaml.safe_dump(payload, sort_keys=False, allow_unicode=True), end="")
        return
    print(text)


if __name__ == "__main__":
    sys.exit(main())
