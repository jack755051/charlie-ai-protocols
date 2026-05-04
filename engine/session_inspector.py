"""Session inspector — read-only queries against the agent-sessions.json ledger.

Powers ``cap session inspect`` so users and downstream agents can audit
prompt snapshots, lifecycle states, parent / root chains, provider /
exit codes, and artifact paths without grepping JSON by hand. Read-only
by design: no ledger mutation paths live here.

Default scan walks ``<CAP_HOME or ~/.cap>/projects/*/reports/workflows/*/*/agent-sessions.json``;
``--sessions-path`` overrides for hermetic tests and explicit single-file
inspection.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Iterable

# Ledger location convention from cap-paths.sh + cap-workflow-exec.sh:
#   <CAP_HOME or ~/.cap>/projects/<id>/reports/workflows/<workflow_id>/<run_label>/agent-sessions.json
DEFAULT_SCAN_GLOB = "*/reports/workflows/*/*/agent-sessions.json"


def _cap_projects_root() -> Path:
    home = os.environ.get("CAP_HOME")
    if home:
        return Path(home) / "projects"
    return Path.home() / ".cap" / "projects"


def _iter_sessions_files(sessions_path: str | None) -> Iterable[Path]:
    if sessions_path:
        p = Path(sessions_path)
        if p.is_file():
            yield p
        return
    root = _cap_projects_root()
    if not root.is_dir():
        return
    yield from sorted(root.glob(DEFAULT_SCAN_GLOB))


def _load_sessions(path: Path) -> list[dict]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    return data.get("sessions") or []


def find_sessions(
    *,
    session_id: str | None = None,
    run_id: str | None = None,
    workflow_id: str | None = None,
    step_id: str | None = None,
    sessions_path: str | None = None,
) -> list[dict]:
    """Return sessions matching every non-None filter (AND semantics).

    Each returned dict gains a ``_source_path`` entry pointing at the
    ledger file it was read from, so downstream tools can locate the
    on-disk record (e.g. for follow-up cat / less / archive ops).
    """
    matches: list[dict] = []
    for path in _iter_sessions_files(sessions_path):
        for session in _load_sessions(path):
            if session_id is not None and session.get("session_id") != session_id:
                continue
            if run_id is not None and session.get("run_id") != run_id:
                continue
            if workflow_id is not None and session.get("workflow_id") != workflow_id:
                continue
            if step_id is not None and session.get("step_id") != step_id:
                continue
            annotated = dict(session)
            annotated["_source_path"] = str(path)
            matches.append(annotated)
    return matches


def render_session_text(session: dict) -> str:
    """Human-readable single-session rendering for the default text mode."""
    lines: list[str] = []
    lines.append(f"session_id: {session.get('session_id', '-')}")
    lines.append(f"  lifecycle: {session.get('lifecycle', '-')}")
    lines.append(f"  result: {session.get('result', '-')}")
    lines.append(f"  step_id: {session.get('step_id', '-')}")
    lines.append(f"  run_id: {session.get('run_id', '-')}")
    lines.append(f"  workflow_id: {session.get('workflow_id', '-')}")
    lines.append(f"  capability: {session.get('capability', '-')}")
    provider = session.get("provider", "-")
    provider_cli = session.get("provider_cli", "-")
    lines.append(f"  provider: {provider} (cli={provider_cli})")
    lines.append(f"  executor: {session.get('executor', '-')}")
    lines.append(f"  duration_seconds: {session.get('duration_seconds', '-')}")
    lines.append(f"  exit_code: {session.get('exit_code', '-')}")

    lines.append("relations:")
    lines.append(f"  parent_session_id: {session.get('parent_session_id', '-')}")
    lines.append(f"  root_session_id: {session.get('root_session_id', '-')}")
    lines.append(f"  spawn_reason: {session.get('spawn_reason', '-')}")

    lines.append("prompt_snapshot:")
    lines.append(f"  prompt_hash: {session.get('prompt_hash', '-')}")
    lines.append(f"  prompt_snapshot_path: {session.get('prompt_snapshot_path', '-')}")
    lines.append(f"  prompt_size_bytes: {session.get('prompt_size_bytes', '-')}")

    outputs = session.get("outputs") or []
    lines.append("outputs:")
    if outputs:
        for o in outputs:
            promoted = o.get("promoted", False)
            lines.append(
                f"  - {o.get('artifact', '-')} @ {o.get('path', '-')} (promoted={promoted})"
            )
    else:
        lines.append("  (none)")

    if session.get("failure_reason"):
        lines.append(f"failure_reason: {session['failure_reason']}")

    source = session.get("_source_path")
    if source:
        lines.append(f"source_ledger: {source}")
    return "\n".join(lines)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="cap session inspect",
        description="Inspect CAP agent session ledger entries (read-only).",
    )
    parser.add_argument(
        "session_id",
        nargs="?",
        default=None,
        help="Exact session_id to look up; omit to use --run-id / --workflow-id / --step-id filters.",
    )
    parser.add_argument("--run-id", default=None, help="Filter by run_id.")
    parser.add_argument("--workflow-id", default=None, help="Filter by workflow_id.")
    parser.add_argument("--step-id", default=None, help="Filter by step_id.")
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit JSON envelope {ok, count, sessions[]} for machine consumers.",
    )
    parser.add_argument(
        "--sessions-path",
        default=None,
        help="Read from a specific agent-sessions.json file (overrides default scan).",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    if not any((args.session_id, args.run_id, args.workflow_id, args.step_id)):
        parser.error(
            "must provide a session_id positional or one of --run-id / --workflow-id / --step-id"
        )

    matches = find_sessions(
        session_id=args.session_id,
        run_id=args.run_id,
        workflow_id=args.workflow_id,
        step_id=args.step_id,
        sessions_path=args.sessions_path,
    )

    if not matches:
        query = {
            "session_id": args.session_id,
            "run_id": args.run_id,
            "workflow_id": args.workflow_id,
            "step_id": args.step_id,
        }
        query = {k: v for k, v in query.items() if v is not None}
        print(
            json.dumps(
                {"ok": False, "error": "session_not_found", "query": query},
                ensure_ascii=False,
            )
        )
        return 1

    if args.json:
        print(
            json.dumps(
                {"ok": True, "count": len(matches), "sessions": matches},
                ensure_ascii=False,
            )
        )
        return 0

    for index, session in enumerate(matches):
        if index > 0:
            print()
            print("-" * 60)
            print()
        print(render_session_text(session))
    return 0


if __name__ == "__main__":
    sys.exit(main())
