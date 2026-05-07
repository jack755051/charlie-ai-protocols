"""Replay verdict computer for H1.

Pure-function comparison of a stored run's ``agent_skills_baseline``
against the current builtin baseline. Output conforms to
``schemas/replay-verdict.schema.yaml``.

Spec SSOT: ``docs/cap/REPLAY-CONTRACT-DESIGN.md`` §2 (verdict enum) /
§3 (drift scope) / §6 (interface contract).

H1 v1 scope:

* Drift judgement looks **only** at builtin ``agent-skills/`` (dir_hash
  + per-file hashes). Project layer ``.cap/skills.yaml`` drift is a
  reserved-null forward-contract field (``drift_details.project_skill_diff``)
  that this verifier always emits as ``None`` — H2 will populate it.
* Verifier never invents data: when ``agent-sessions.json`` lacks an
  ``agent_skills_baseline`` envelope field (pre-A0 #4 run), verdict
  is ``unverifiable``; when the run dir or sessions ledger is missing,
  verdict is ``not_found``.
* ``cap_version`` / ``git_commit`` mismatch are recorded as soft
  signals but do not by themselves change the verdict (avoid release
  tag noise).

The verifier is pure — given the same ``run_dir`` content and the
same ``current_snapshot``, it always produces the same verdict.
``verify_run`` does not touch disk by default; the CLI ``--write``
flag is what materialises the snapshot mirror + verdict cache files.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

try:
    from .agent_skills_snapshot import compute_snapshot, compute_summary
except ImportError:  # pragma: no cover
    from agent_skills_snapshot import compute_snapshot, compute_summary  # type: ignore[no-redef]


# Exit codes mapped from verdict (CLI-side; pure verify_run does not exit).
EXIT_OK = 0
EXIT_INTERNAL_ERROR = 1
EXIT_NOT_FOUND = 2
EXIT_DRIFTED_INCOMPATIBLE = 4

VERDICT_REPLAYABLE = "replayable"
VERDICT_DRIFTED_COMPATIBLE = "drifted_compatible"
VERDICT_DRIFTED_INCOMPATIBLE = "drifted_incompatible"
VERDICT_UNVERIFIABLE = "unverifiable"
VERDICT_NOT_FOUND = "not_found"

_AGENT_SKILLS_PREFIX = "agent-skills/"


def verify_run(
    run_dir: Path,
    *,
    current_snapshot: dict | None = None,
    agent_skills_dir: Path | None = None,
    verified_at: datetime | None = None,
) -> dict:
    """Compute a replay-verdict envelope for ``run_dir``.

    Parameters
    ----------
    run_dir:
        Filesystem path to the run output directory (the one containing
        ``agent-sessions.json``).
    current_snapshot:
        Pre-computed current baseline snapshot. When ``None``,
        :func:`compute_snapshot` is invoked. Tests inject this for
        deterministic behaviour.
    agent_skills_dir:
        Forwarded to :func:`compute_snapshot` when ``current_snapshot``
        is ``None``. Ignored when an explicit snapshot is supplied.
    verified_at:
        Override for ``verified_at`` field; tests use this to keep
        envelopes byte-for-byte stable. Defaults to ``datetime.now(UTC)``.

    Returns
    -------
    dict matching ``schemas/replay-verdict.schema.yaml``.
    """
    run_dir = Path(run_dir)
    sessions_path = run_dir / "agent-sessions.json"

    if verified_at is None:
        verified_at = datetime.now(tz=timezone.utc)
    elif verified_at.tzinfo is None:
        verified_at = verified_at.replace(tzinfo=timezone.utc)
    verified_iso = verified_at.strftime("%Y-%m-%dT%H:%M:%SZ")

    run_id = run_dir.name

    # ── not_found branch ──
    if not run_dir.is_dir() or not sessions_path.is_file():
        return _build_envelope(
            run_id=run_id,
            verified_iso=verified_iso,
            verdict=VERDICT_NOT_FOUND,
            reason=f"run directory or agent-sessions.json missing: {run_dir}",
            baseline_observed=None,
            baseline_current=None,
            drift_details=_empty_drift_details(),
        )

    # Load sessions ledger.
    try:
        envelope = json.loads(sessions_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return _build_envelope(
            run_id=run_id,
            verified_iso=verified_iso,
            verdict=VERDICT_NOT_FOUND,
            reason=f"failed to read agent-sessions.json: {exc}",
            baseline_observed=None,
            baseline_current=None,
            drift_details=_empty_drift_details(),
        )

    observed_full = envelope.get("agent_skills_baseline") or None

    # Compute current snapshot regardless of observed presence — caller
    # may want to see what current looks like even when verdict ends up
    # unverifiable.
    if current_snapshot is None:
        current_snapshot = compute_snapshot(agent_skills_dir=agent_skills_dir)
    current_summary = compute_summary(current_snapshot)

    # ── unverifiable branch ──
    if not observed_full:
        return _build_envelope(
            run_id=run_id,
            verified_iso=verified_iso,
            verdict=VERDICT_UNVERIFIABLE,
            reason="agent-sessions.json envelope has no agent_skills_baseline (pre-A0 #4 run)",
            baseline_observed=None,
            baseline_current=current_summary,
            drift_details=_empty_drift_details(),
        )

    observed_summary = compute_summary(observed_full)

    # Extract prompt_files actually used by this run.
    sessions = envelope.get("sessions") or []
    prompt_files_used = _extract_prompt_files_used(sessions)

    # Per-file drift detection scoped to prompt_files_used.
    observed_files = observed_full.get("prompt_files") or {}
    current_files = current_snapshot.get("prompt_files") or {}
    prompt_files_changed: list[str] = []
    prompt_files_removed: list[str] = []
    for pf in prompt_files_used:
        observed_hash = observed_files.get(pf)
        current_hash = current_files.get(pf)
        if current_hash is None:
            prompt_files_removed.append(pf)
        elif observed_hash is not None and observed_hash != current_hash:
            prompt_files_changed.append(pf)

    dir_hash_match = bool(
        observed_full.get("dir_hash")
        and observed_full.get("dir_hash") == current_snapshot.get("dir_hash")
    )
    cap_version_match = (
        observed_full.get("cap_version") == current_snapshot.get("cap_version")
    )
    git_commit_match = (
        observed_full.get("git_commit") == current_snapshot.get("git_commit")
    )

    drift_details = {
        "prompt_files_used": prompt_files_used,
        "prompt_files_changed": prompt_files_changed,
        "prompt_files_removed": prompt_files_removed,
        "dir_hash_match": dir_hash_match,
        "cap_version_match": cap_version_match,
        "git_commit_match": git_commit_match,
        # H1 v1 reserved-null forward contract; H2 will populate.
        "project_skill_diff": None,
    }

    # ── verdict aggregation ──
    if prompt_files_changed or prompt_files_removed:
        verdict = VERDICT_DRIFTED_INCOMPATIBLE
        reason = _format_incompatible_reason(prompt_files_changed, prompt_files_removed)
    elif not dir_hash_match:
        verdict = VERDICT_DRIFTED_COMPATIBLE
        reason = (
            "dir_hash differs but no prompt_files_used were affected; "
            "replay should reproduce original behaviour"
        )
    else:
        verdict = VERDICT_REPLAYABLE
        reason = "stored baseline matches current baseline byte-for-byte"

    return _build_envelope(
        run_id=run_id,
        verified_iso=verified_iso,
        verdict=verdict,
        reason=reason,
        baseline_observed=observed_summary,
        baseline_current=current_summary,
        drift_details=drift_details,
    )


def write_verdict(run_dir: Path, verdict: dict) -> Path:
    """Write the verdict envelope to ``<run_dir>/replay-verdict.json``.

    Idempotent: when the existing file already encodes an identical
    verdict, the file is left untouched (no-op write avoidance). Returns
    the verdict path either way.
    """
    run_dir = Path(run_dir)
    verdict_path = run_dir / "replay-verdict.json"
    if verdict_path.is_file():
        try:
            existing = json.loads(verdict_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            existing = None
        if existing == verdict:
            return verdict_path
    verdict_path.write_text(
        json.dumps(verdict, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return verdict_path


def write_snapshot_mirror(run_dir: Path, observed_baseline: dict | None) -> Path | None:
    """Mirror the agent-sessions envelope baseline to ``<run_dir>/snapshots/agent-skills.json``.

    Per design memo §4.2, the mirror is a convenience copy of the
    envelope's ``agent_skills_baseline`` so external tooling can stat
    one small file instead of parsing the whole sessions ledger. The
    envelope remains the SSOT; the mirror is only written when the
    envelope had a baseline (verdicts ``unverifiable`` / ``not_found``
    write nothing).

    Idempotent: when the existing mirror already encodes identical
    bytes, the file is left untouched. Returns the mirror path or
    ``None`` when no baseline existed to mirror.
    """
    if not observed_baseline:
        return None
    run_dir = Path(run_dir)
    snapshot_dir = run_dir / "snapshots"
    snapshot_dir.mkdir(parents=True, exist_ok=True)
    mirror_path = snapshot_dir / "agent-skills.json"
    if mirror_path.is_file():
        try:
            existing = json.loads(mirror_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            existing = None
        if existing == observed_baseline:
            return mirror_path
    mirror_path.write_text(
        json.dumps(observed_baseline, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return mirror_path


def verdict_to_exit_code(verdict: str) -> int:
    """Map verdict enum to CLI exit code per design memo §6.2."""
    if verdict == VERDICT_DRIFTED_INCOMPATIBLE:
        return EXIT_DRIFTED_INCOMPATIBLE
    if verdict == VERDICT_NOT_FOUND:
        return EXIT_NOT_FOUND
    return EXIT_OK


def _extract_prompt_files_used(sessions: list[dict]) -> list[str]:
    """Distinct prompt_file paths used by this run, normalised.

    * Drops sessions with ``prompt_file`` null (typically shell-only
      executors).
    * Strips the leading ``agent-skills/`` prefix so paths line up with
      the baseline ``prompt_files`` dictionary keys (which are relative
      to the agent-skills directory).
    * Returns a sorted unique list for stable output.
    """
    used: set[str] = set()
    for session in sessions:
        if not isinstance(session, dict):
            continue
        pf = session.get("prompt_file")
        if not pf:
            continue
        if pf.startswith(_AGENT_SKILLS_PREFIX):
            pf = pf[len(_AGENT_SKILLS_PREFIX):]
        used.add(pf)
    return sorted(used)


def _empty_drift_details() -> dict:
    return {
        "prompt_files_used": [],
        "prompt_files_changed": [],
        "prompt_files_removed": [],
        "dir_hash_match": False,
        "cap_version_match": False,
        "git_commit_match": False,
        "project_skill_diff": None,
    }


def _build_envelope(
    *,
    run_id: str,
    verified_iso: str,
    verdict: str,
    reason: str,
    baseline_observed: dict | None,
    baseline_current: dict | None,
    drift_details: dict,
) -> dict:
    return {
        "schema_version": 1,
        "run_id": run_id,
        "verified_at": verified_iso,
        "verdict": verdict,
        "reason": reason,
        "baseline_observed": baseline_observed,
        "baseline_current": baseline_current,
        "drift_details": drift_details,
    }


def _format_incompatible_reason(
    changed: list[str], removed: list[str]
) -> str:
    parts: list[str] = []
    if changed:
        parts.append("prompt_files_changed=" + ", ".join(changed))
    if removed:
        parts.append("prompt_files_removed=" + ", ".join(removed))
    return "; ".join(parts) or "incompatible drift detected"


def _cli(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="replay_verifier",
        description="Compute replay-verdict envelope for a stored CAP run dir.",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_verify = sub.add_parser("verify", help="Verify a single run dir.")
    p_verify.add_argument("run_dir", type=Path)
    p_verify.add_argument(
        "--write",
        action="store_true",
        help=(
            "Persist verdict to <run_dir>/replay-verdict.json and mirror "
            "the observed baseline to <run_dir>/snapshots/agent-skills.json."
        ),
    )
    p_verify.add_argument("--agent-skills-dir", type=Path, default=None)

    args = parser.parse_args(argv)

    if args.cmd == "verify":
        envelope = verify_run(
            args.run_dir,
            agent_skills_dir=args.agent_skills_dir,
        )
        if args.write:
            write_verdict(args.run_dir, envelope)
            write_snapshot_mirror(
                args.run_dir, envelope.get("baseline_observed_full") or _read_observed_full(args.run_dir)
            )
        print(json.dumps(envelope, ensure_ascii=False, indent=2))
        return verdict_to_exit_code(envelope["verdict"])

    return EXIT_INTERNAL_ERROR


def _read_observed_full(run_dir: Path) -> dict | None:
    """Re-read the full observed baseline (with prompt_files) for snapshot mirroring.

    The envelope returned by :func:`verify_run` only carries the compact
    ``baseline_observed`` summary (compute_summary projection). The
    mirror file at ``<run_dir>/snapshots/agent-skills.json`` deliberately
    holds the full snapshot (including per-file hashes) so downstream
    tooling has everything in one place; this helper re-reads the
    sessions ledger to grab it.
    """
    sessions_path = run_dir / "agent-sessions.json"
    if not sessions_path.is_file():
        return None
    try:
        envelope = json.loads(sessions_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return envelope.get("agent_skills_baseline") or None


if __name__ == "__main__":
    raise SystemExit(_cli(sys.argv[1:]))
