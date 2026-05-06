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

    args = parser.parse_args(argv)
    if args.cmd == "inspect":
        cmd_inspect(
            args.artifact_id,
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
