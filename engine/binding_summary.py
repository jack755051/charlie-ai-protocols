"""Binding summary helper for replay drift detection (H2 #4).

Extracts a compact per-step ``[{step_id, selected_skill_id, skill_source}]``
projection from a bound execution plan JSON and idempotently embeds it
into the ``agent-sessions.json`` envelope as ``binding_summary``. The
H2 verifier (``engine/replay_verifier.py``) reads this field to
identify which project-layer skills the run actually used so per-skill
drift can be reported with selection precision.

Spec SSOT: ``docs/cap/H2-PROJECT-SKILL-DRIFT-DESIGN.md`` §3 (binding
summary structure & runtime attach timing).

Module is parallel to ``engine/agent_skills_snapshot.py`` (A0 #4) and
``engine/project_skills_snapshot.py`` (H2 #2): pure helpers + argparse
CLI exposing ``extract`` / ``attach`` subcommands. Failures during
extraction (malformed plan, missing fields) raise; the cap-workflow-exec
caller wraps invocation in best-effort logging so a non-fatal failure
warns but does not halt the run.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


def extract_from_plan(plan: dict, *, captured_at: datetime | None = None) -> dict:
    """Build a binding_summary envelope from a bound execution plan dict.

    Walks every step under ``plan.phases[*].steps`` plus
    ``plan.standby_steps``. Steps without a ``selected_skill_id``
    (unresolved / blocked / optional skipped) are still recorded so
    consumers see the full run shape; ``skill_source`` may be null for
    those steps.

    Returns a dict matching the structure documented in the H2 design
    memo §3.2:

    ```
    {
      "schema_version": 1,
      "captured_at": "<iso>",
      "steps": [
        {"step_id": ..., "selected_skill_id": ..., "skill_source": {...}},
        ...
      ]
    }
    ```
    """
    if captured_at is None:
        captured_at = datetime.now(tz=timezone.utc)
    elif captured_at.tzinfo is None:
        captured_at = captured_at.replace(tzinfo=timezone.utc)

    steps: list[dict] = []
    seen_step_ids: set[str] = set()

    def _record(step: dict) -> None:
        sid = step.get("step_id")
        if not sid or sid in seen_step_ids:
            return
        seen_step_ids.add(sid)
        steps.append(
            {
                "step_id": sid,
                "selected_skill_id": step.get("skill_id"),
                "skill_source": step.get("skill_source"),
            }
        )

    for phase in plan.get("phases", []) or []:
        for step in phase.get("steps", []) or []:
            _record(step)

    for step in plan.get("standby_steps", []) or []:
        _record(step)

    return {
        "schema_version": 1,
        "captured_at": captured_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "steps": steps,
    }


def attach_to_envelope(envelope: dict, *, summary: dict) -> dict:
    """Idempotently embed ``binding_summary`` into a ledger envelope.

    Mirrors ``agent_skills_snapshot.attach_to_envelope`` semantics: when
    the field is already populated, return the envelope unchanged. The
    original run's observation is canonical; verify-time reattach must
    not overwrite history.
    """
    if envelope.get("binding_summary"):
        return envelope
    envelope["binding_summary"] = summary
    return envelope


# ─────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────


def _cli(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="binding_summary",
        description=(
            "Extract / attach binding_summary projection for H2 replay "
            "drift detection."
        ),
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_extract = sub.add_parser(
        "extract",
        help="Extract binding_summary JSON from a bound plan file (stdout).",
    )
    p_extract.add_argument("plan_path", type=Path)

    p_attach = sub.add_parser(
        "attach",
        help=(
            "Read plan JSON, extract binding_summary, embed into the given "
            "envelope file (idempotent)."
        ),
    )
    p_attach.add_argument("envelope_path", type=Path)
    p_attach.add_argument("--plan-path", type=Path, required=True)

    args = parser.parse_args(argv)

    if args.cmd == "extract":
        if not args.plan_path.is_file():
            print(
                f"error: plan file does not exist: {args.plan_path}",
                file=sys.stderr,
            )
            return 2
        plan = json.loads(args.plan_path.read_text(encoding="utf-8"))
        summary = extract_from_plan(plan)
        print(json.dumps(summary, ensure_ascii=False, indent=2))
        return 0

    if args.cmd == "attach":
        if not args.envelope_path.is_file():
            print(
                f"error: envelope file does not exist: {args.envelope_path}",
                file=sys.stderr,
            )
            return 2
        if not args.plan_path.is_file():
            print(
                f"error: plan file does not exist: {args.plan_path}",
                file=sys.stderr,
            )
            return 2
        plan = json.loads(args.plan_path.read_text(encoding="utf-8"))
        summary = extract_from_plan(plan)
        envelope = json.loads(args.envelope_path.read_text(encoding="utf-8"))
        attach_to_envelope(envelope, summary=summary)
        args.envelope_path.write_text(
            json.dumps(envelope, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        print(f"attached binding_summary to {args.envelope_path}")
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(_cli(sys.argv[1:]))
