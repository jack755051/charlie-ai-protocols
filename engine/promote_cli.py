"""P10 promote CLI Python entry — currently hosts ``cap promote inspect``.

P10 #3 ships ``cmd_inspect`` only. Subsequent P10 sub-items extend
this module:

* P10 #4: ``cmd_project_constitution`` — apply path for constitution
  promotes (consumes ``ResolvedPromote`` from this module + writes /
  validates / rolls back).
* P10 #5: ``cmd_workflow`` — apply path for compiled workflow promotes.

The bash dispatcher at ``scripts/cap-promote.sh`` forwards
``cap promote inspect <id>`` (and later the apply subcommands) here.
The legacy ``cap promote list`` and 2-positional copy mode stay in the
bash side as escape hatches per policy §7.4 / §8.4.
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict
from pathlib import Path
from typing import Optional

# When ``promote_cli.py`` is invoked as a script (``python engine/promote_cli.py``),
# only ``engine/`` is on sys.path; the absolute ``engine.promote_resolver``
# import below would fail. Mirror the workflow_cli pattern of inserting
# the repo root once before the relative-style import so both
# ``python -m engine.promote_cli`` and direct script invocation work.
_REPO_ROOT = Path(__file__).resolve().parent.parent
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from engine.promote_apply import (  # noqa: E402
    ACTION_APPLIED_FORCE_WITH_BACKUP,
    ACTION_APPLIED_FRESH,
    ACTION_APPLIED_IDENTICAL_SKIP,
    ACTION_HALTED_CONFLICT,
    ACTION_HALTED_TYPE_MISMATCH,
    ApplyResult,
    apply_promote,
)
from engine.promote_resolver import (  # noqa: E402
    CONFLICT_DIFF,
    CONFLICT_IDENTICAL,
    CONFLICT_NO_TARGET,
    ResolvedPromote,
    resolve_promote,
)


def cmd_inspect(
    artifact_id: str,
    *,
    output_json: bool,
    project_root: Optional[str],
    cap_home: Optional[str],
    project_id: Optional[str],
) -> None:
    """Implement ``cap promote inspect <artifact_id>`` (P10 #3).

    Pure read-only: never writes to repo or runtime tree. On miss
    exits 1 with a deterministic error JSON / one-line text message;
    on hit prints the rendered ``ResolvedPromote`` and exits 0.
    """
    resolved = resolve_promote(
        artifact_id,
        project_root=project_root,
        cap_home=cap_home,
        project_id=project_id,
    )
    if resolved is None:
        if output_json:
            print(
                json.dumps(
                    {
                        "ok": False,
                        "error": "promote_artifact_not_found",
                        "artifact_id": artifact_id,
                        "message": (
                            "no promote candidate matches this id; tried "
                            "task_id (constitution snapshot) then "
                            "workflow_id (compiled workflow snapshot)"
                        ),
                    },
                    ensure_ascii=False,
                )
            )
        else:
            print(
                f"# Promote Inspect: {artifact_id}\n"
                f"\n"
                f"  No promote candidate matches '{artifact_id}'.\n"
                f"  Tried task_id (constitution) and workflow_id (compiled workflow).",
                file=sys.stdout,
            )
        sys.exit(1)

    if output_json:
        payload = asdict(resolved)
        payload["ok"] = True
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return

    _print_inspect_text(artifact_id, resolved)


def _print_inspect_text(artifact_id: str, resolved: ResolvedPromote) -> None:
    """Render ``ResolvedPromote`` as the policy §7.1 text view.

    Sections in order (mirrors ``cap workflow inspect`` style for
    visual consistency): Run Header / Source / Target / Validation.
    Conflict line uses the resolver's enum verbatim so users see the
    same vocabulary as the JSON contract.
    """
    candidate = resolved.candidate
    print(f"# Promote Inspect: {artifact_id}")
    print()
    print("# Header")
    print(f"  artifact_type:     {candidate.get('artifact_type', '-')}")
    print(f"  reason:            {candidate.get('reason', '-')}")
    if candidate.get("source_layer"):
        print(f"  source_layer:      {candidate['source_layer']}")
    if candidate.get("source_revision"):
        print(f"  source_revision:   {candidate['source_revision']}")

    print()
    print("# Source")
    print(f"  source_path:       {candidate.get('source_path', '-')}")

    print()
    print("# Target")
    print(f"  target_path:       {candidate.get('target_path', '-')}")
    print(f"  target_exists:     {str(resolved.target_exists).lower()}")
    print(f"  conflict:          {resolved.conflict_kind}")
    if resolved.conflict_kind == CONFLICT_NO_TARGET:
        print("  on_apply:          fresh write (no backup needed)")
    elif resolved.conflict_kind == CONFLICT_IDENTICAL:
        print("  on_apply:          short-circuit (already_promoted, no backup)")
    elif resolved.conflict_kind == CONFLICT_DIFF:
        print("  on_apply:          requires --force; --force triggers backup")
        if resolved.backup_path:
            print(f"  backup_path:       {resolved.backup_path}")

    print()
    print("# Validation")
    schema_plan = (resolved.smoke_plan or {}).get("schema_validate") or {}
    print(f"  schema_validate:   {str(schema_plan.get('enabled', False)).lower()}")
    if schema_plan.get("schema_path"):
        print(f"    schema_path:     {schema_plan['schema_path']}")
    smoke = (resolved.smoke_plan or {}).get("compile_bind_smoke")
    if smoke:
        print(
            f"  compile_bind_smoke: opt-in via {smoke.get('opt_in_flag', '--smoke')} "
            "(off by default)"
        )


def cmd_project_constitution(
    task_id: str,
    *,
    apply: bool,
    force: bool,
    output_json: bool,
    project_root: Optional[str],
    cap_home: Optional[str],
    project_id: Optional[str],
) -> None:
    """Implement ``cap promote project-constitution <task_id>`` (P10 #4).

    Default ``--dry-run`` (no flag needed; ``apply=False``). ``--apply``
    enables the write path; ``--force`` enables overwrite-with-backup
    on diff conflict. Always validates the written target against
    ``schemas/project-constitution.schema.yaml`` (policy §6.1) and
    rolls back on validation failure.
    """
    resolved = resolve_promote(
        task_id,
        project_root=project_root,
        cap_home=cap_home,
        project_id=project_id,
    )
    if resolved is None or resolved.candidate.get("artifact_type") != "project_constitution":
        if output_json:
            print(
                json.dumps(
                    {
                        "ok": False,
                        "error": "promote_artifact_not_found",
                        "artifact_type": "project_constitution",
                        "task_id": task_id,
                        "message": (
                            "no project_constitution snapshot matches this task_id; "
                            "make sure a task constitution snapshot exists at "
                            "<cap_home>/projects/<id>/constitutions/<task_id>/"
                        ),
                    },
                    ensure_ascii=False,
                )
            )
        else:
            print(
                f"# Promote project-constitution: {task_id}\n"
                f"\n"
                f"  No project_constitution snapshot matches '{task_id}'.\n"
                f"  Looked under <cap_home>/projects/<id>/constitutions/<task_id>/.",
                file=sys.stdout,
            )
        sys.exit(1)

    result = apply_promote(
        resolved,
        expected_artifact_type="project_constitution",
        dry_run=not apply,
        force=force,
        artifact_id=task_id,
    )

    _emit_apply_result(task_id, result, output_json=output_json)


def _emit_apply_result(artifact_id: str, result: ApplyResult, *, output_json: bool) -> None:
    """Print the ``ApplyResult`` and exit with the right code.

    Exit code mapping:

    * ``ok=True`` (action starts with ``applied_`` / ``dry_run_``) → 0
    * Otherwise (``halted_*`` / ``validation_failed_*`` / type
      mismatch) → 1

    The JSON shape always includes ``ok`` and the action enum so
    consumers can branch deterministically without parsing free text.
    """
    if output_json:
        payload = {
            "ok": result.ok,
            "action": result.action,
            "artifact_id": result.artifact_id,
            "artifact_type": result.artifact_type,
            "source_path": result.source_path,
            "target_path": result.target_path,
            "target_existed_before": result.target_existed_before,
            "backup_path": result.backup_path,
            "validation": result.validation,
            "error": result.error,
            "detail": result.detail,
        }
        if result.extra:
            payload["extra"] = dict(result.extra)
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(_render_apply_text(artifact_id, result))

    if not result.ok:
        sys.exit(1)


def _render_apply_text(artifact_id: str, result: ApplyResult) -> str:
    """Render ``ApplyResult`` as the policy §7 text view.

    Sections: Header / Source / Target / Backup (when applicable) /
    Validation. Action enum prints verbatim so JSON contract and text
    contract use the same vocabulary.
    """
    lines = [
        f"# Promote Apply: {artifact_id}",
        "",
        "# Header",
        f"  artifact_type:        {result.artifact_type or '-'}",
        f"  action:               {result.action}",
        f"  ok:                   {str(result.ok).lower()}",
    ]
    if result.error:
        lines.append(f"  error:                {result.error}")
    if result.detail:
        lines.append(f"  detail:               {result.detail}")

    lines.extend([
        "",
        "# Source",
        f"  source_path:          {result.source_path or '-'}",
        "",
        "# Target",
        f"  target_path:          {result.target_path or '-'}",
        f"  target_existed:       {str(result.target_existed_before).lower()}",
    ])
    if result.backup_path:
        lines.extend([
            "",
            "# Backup",
            f"  backup_path:          {result.backup_path}",
        ])
    if result.validation is not None:
        lines.extend([
            "",
            "# Validation",
            f"  ok:                   {str(result.validation.get('ok', False)).lower()}",
        ])
        errors = result.validation.get("errors") or []
        if errors:
            lines.append("  errors:")
            for err in errors:
                lines.append(f"    - {err}")
    return "\n".join(lines)


def main(argv: Optional[list[str]] = None) -> None:
    parser = argparse.ArgumentParser(prog="cap-promote-cli")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("inspect", help="Inspect a promote candidate by artifact id (read-only)")
    p.add_argument("artifact_id")
    p.add_argument(
        "--json",
        dest="output_json",
        action="store_true",
        help="Emit the resolved promote dict as JSON instead of the text view.",
    )
    p.add_argument(
        "--project-root",
        dest="project_root",
        default=None,
        help="Override CAP_PROJECT_ROOT for the duration of this command.",
    )
    p.add_argument(
        "--cap-home",
        dest="cap_home",
        default=None,
        help="Override CAP_HOME for the duration of this command.",
    )
    p.add_argument(
        "--project-id",
        dest="project_id",
        default=None,
        help="Override the auto-resolved project_id (mainly for tests).",
    )

    p = sub.add_parser(
        "project-constitution",
        help=(
            "Promote a task constitution snapshot to "
            "<project_root>/.cap/constitution.yaml (P10 #4)."
        ),
    )
    p.add_argument("task_id")
    p.add_argument(
        "--apply",
        action="store_true",
        help="Actually write the target. Without this flag the command is dry-run.",
    )
    p.add_argument(
        "--force",
        action="store_true",
        help="When the target exists and differs from source, back up to <target>.bak.<ISO> and overwrite. Without --force, diff conflict halts.",
    )
    p.add_argument("--json", dest="output_json", action="store_true")
    p.add_argument("--project-root", dest="project_root", default=None)
    p.add_argument("--cap-home", dest="cap_home", default=None)
    p.add_argument("--project-id", dest="project_id", default=None)

    args = parser.parse_args(argv)
    if args.cmd == "inspect":
        cmd_inspect(
            args.artifact_id,
            output_json=args.output_json,
            project_root=args.project_root,
            cap_home=args.cap_home,
            project_id=args.project_id,
        )
    elif args.cmd == "project-constitution":
        cmd_project_constitution(
            args.task_id,
            apply=args.apply,
            force=args.force,
            output_json=args.output_json,
            project_root=args.project_root,
            cap_home=args.cap_home,
            project_id=args.project_id,
        )
    else:  # pragma: no cover — argparse already enforces required cmd
        parser.print_help()
        sys.exit(2)


if __name__ == "__main__":
    main()
