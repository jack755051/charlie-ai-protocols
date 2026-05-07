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
    from .project_skills_snapshot import (
        compute_snapshot as project_compute_snapshot,
    )
    from .workflow_yaml_snapshot import (
        compute_snapshot as workflow_yaml_compute_snapshot,
    )
    from .constitution_snapshot import (
        compute_snapshot as constitution_compute_snapshot,
    )
    from .capability_schema_snapshot import (
        compute_snapshot as capability_schema_compute_snapshot,
    )
except ImportError:  # pragma: no cover
    from agent_skills_snapshot import compute_snapshot, compute_summary  # type: ignore[no-redef]
    from project_skills_snapshot import (  # type: ignore[no-redef]
        compute_snapshot as project_compute_snapshot,
    )
    from workflow_yaml_snapshot import (  # type: ignore[no-redef]
        compute_snapshot as workflow_yaml_compute_snapshot,
    )
    from constitution_snapshot import (  # type: ignore[no-redef]
        compute_snapshot as constitution_compute_snapshot,
    )
    from capability_schema_snapshot import (  # type: ignore[no-redef]
        compute_snapshot as capability_schema_compute_snapshot,
    )


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
    project_skills_current: dict | None = None,
    project_root: Path | None = None,
    verified_at: datetime | None = None,
) -> dict:
    """Compute a replay-verdict envelope for ``run_dir``.

    H2 widening: emits a structured ``drift_details.project_skill_diff``
    object body when ``baseline_observed`` is non-null (per design memo
    §5). Aggregates top-level verdict from builtin × project axes via
    worst-non-neutral rule (design memo §4); ``unverifiable_axis`` stays
    neutral so a single missing axis does not regress the other axis's
    verdict.

    Parameters
    ----------
    run_dir:
        Filesystem path to the run output directory.
    current_snapshot:
        Pre-computed current builtin snapshot. ``None`` triggers
        :func:`compute_snapshot`. Tests inject this for determinism.
    agent_skills_dir:
        Forwarded to :func:`compute_snapshot` when ``current_snapshot``
        is ``None``.
    project_skills_current:
        Pre-computed current project layer snapshot (H2). ``None``
        triggers :func:`project_compute_snapshot`. Tests inject this.
    project_root:
        Forwarded to :func:`project_compute_snapshot` when
        ``project_skills_current`` is ``None``.
    verified_at:
        Override for the ``verified_at`` field. Tests use this to keep
        envelopes byte-stable.
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

    # Compute current builtin snapshot regardless — surfaced even on
    # unverifiable so the consumer sees current state for context.
    if current_snapshot is None:
        current_snapshot = compute_snapshot(agent_skills_dir=agent_skills_dir)
    current_summary = compute_summary(current_snapshot)

    # ── unverifiable branch ──
    # Per design memo §5: when no agent_skills_baseline exists, the H1
    # contract is not applicable. project_skill_diff stays null
    # (distinct from the "object with axis_verdict=unverifiable_axis"
    # case which only fires when baseline_observed is non-null but
    # project_skill_baseline is missing).
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

    # ── builtin axis ──
    builtin_axis_verdict, builtin_drift = _compute_builtin_axis(
        envelope, observed_full, current_snapshot
    )

    # ── project axis ──
    if project_skills_current is None:
        project_skills_current = project_compute_snapshot(project_root=project_root)
    project_axis = _compute_project_axis(envelope, project_skills_current)

    # ── H3 #3 three new whole-file axes ──
    workflow_yaml_axis = _compute_workflow_yaml_axis(envelope)
    constitution_axis = _compute_constitution_axis(
        envelope, project_root=project_root
    )
    capability_schema_axis = _compute_capability_schema_axis(envelope)

    # ── verdict aggregation (5 axes, worst non-neutral) ──
    verdict = _aggregate_axes(
        builtin_axis_verdict,
        project_axis["axis_verdict"],
        workflow_yaml_axis["axis_verdict"],
        constitution_axis["axis_verdict"],
        capability_schema_axis["axis_verdict"],
    )
    reason = _compose_reason(
        verdict,
        builtin_drift,
        project_axis,
        workflow_yaml_axis=workflow_yaml_axis,
        constitution_axis=constitution_axis,
        capability_schema_axis=capability_schema_axis,
    )

    drift_details = {
        **builtin_drift,
        "workflow_yaml_diff": workflow_yaml_axis,
        "constitution_diff": constitution_axis,
        "capability_schema_diff": capability_schema_axis,
        "project_skill_diff": project_axis,
    }

    return _build_envelope(
        run_id=run_id,
        verified_iso=verified_iso,
        verdict=verdict,
        reason=reason,
        baseline_observed=observed_summary,
        baseline_current=current_summary,
        drift_details=drift_details,
    )


def _compute_builtin_axis(
    envelope: dict, observed_full: dict, current_snapshot: dict
) -> tuple[str, dict]:
    """Return (builtin_axis_verdict, builtin_drift_dict).

    Builtin drift dict is the H1-shape subset of drift_details
    (prompt_files_* + *_match flags). Axis verdict is one of
    ``replayable`` / ``drifted_compatible`` / ``drifted_incompatible``.
    Returns ``replayable`` for the byte-perfect match path so callers
    can compose it with the project axis without special-casing.
    """
    sessions = envelope.get("sessions") or []
    prompt_files_used = _extract_prompt_files_used(sessions)

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

    drift = {
        "prompt_files_used": prompt_files_used,
        "prompt_files_changed": prompt_files_changed,
        "prompt_files_removed": prompt_files_removed,
        "dir_hash_match": dir_hash_match,
        "cap_version_match": cap_version_match,
        "git_commit_match": git_commit_match,
    }

    if prompt_files_changed or prompt_files_removed:
        return VERDICT_DRIFTED_INCOMPATIBLE, drift
    if not dir_hash_match:
        return VERDICT_DRIFTED_COMPATIBLE, drift
    return VERDICT_REPLAYABLE, drift


def _compute_project_axis(envelope: dict, current_snapshot: dict) -> dict:
    """Return drift_details.project_skill_diff body (H2 #4).

    Output shape conforms to ``schemas/replay-verdict.schema.yaml``
    ``drift_details.project_skill_diff`` widening. Always emits an
    object body when called (the null-projection branch is handled
    by the caller for pre-A0 #4 runs).

    Behaviour matrix (design memo §7.2):

    * ``project_skill_baseline`` + ``binding_summary`` both present →
      ``was_recorded=True``; full per-skill drift attribution.
    * ``project_skill_baseline`` only → coarse drift via dir_hash
      comparison; ``axis_verdict`` is at most ``drifted_compatible``
      (cannot say ``drifted_incompatible`` without selection data).
    * Neither present → ``was_recorded=False``;
      ``axis_verdict=unverifiable_axis``.
    """
    observed = envelope.get("project_skill_baseline") or None
    binding_summary = envelope.get("binding_summary") or None

    current_dir_hash = current_snapshot.get("dir_hash")
    current_present = bool(current_snapshot.get("project_dir_present"))
    current_skills_by_id = current_snapshot.get("skills_by_id") or {}

    if observed is None:
        return {
            "was_recorded": False,
            "axis_verdict": "unverifiable_axis",
            "project_dir_present_observed": None,
            "project_dir_present_current": current_present,
            "dir_hash_observed": None,
            "dir_hash_current": current_dir_hash if current_present else None,
            "skills_used": [],
            "skills_changed": [],
            "skills_removed": [],
            "skills_added_masked": [],
            "reason": "project_skill_baseline absent on envelope",
        }

    observed_dir_hash = observed.get("dir_hash")
    observed_present = bool(observed.get("project_dir_present"))
    observed_skills_by_id = observed.get("skills_by_id") or {}

    if binding_summary is None:
        # Coarse drift only — cannot pinpoint skills_used.
        if observed_dir_hash == current_dir_hash:
            axis_verdict = "replayable"
            reason = "project skill snapshot dir_hash matches current"
        else:
            axis_verdict = "drifted_compatible"
            reason = (
                "project skill dir_hash differs but binding_summary missing; "
                "cannot determine whether the run's skills were affected"
            )
        return {
            "was_recorded": False,
            "axis_verdict": axis_verdict,
            "project_dir_present_observed": observed_present,
            "project_dir_present_current": current_present,
            "dir_hash_observed": observed_dir_hash,
            "dir_hash_current": current_dir_hash if current_present else None,
            "skills_used": [],
            "skills_changed": [],
            "skills_removed": [],
            "skills_added_masked": [],
            "reason": reason,
        }

    # Full path: was_recorded=True
    project_steps = [
        step
        for step in (binding_summary.get("steps") or [])
        if isinstance(step, dict)
        and isinstance(step.get("skill_source"), dict)
        and step["skill_source"].get("source_layer") == "project"
        and step.get("selected_skill_id")
    ]
    skills_used = sorted({s["selected_skill_id"] for s in project_steps})

    skills_changed: list[str] = []
    skills_removed: list[str] = []
    # H2 v1: skills_added_masked stays empty (would require running
    # _apply_override_contract against current registry to detect new
    # masks; out of scope per design memo §10 deferred row).
    skills_added_masked: list[str] = []

    for sid in skills_used:
        observed_entry = observed_skills_by_id.get(sid)
        current_entry = current_skills_by_id.get(sid)
        if current_entry is None:
            skills_removed.append(sid)
        elif observed_entry and observed_entry.get("hash") != current_entry.get("hash"):
            skills_changed.append(sid)

    if skills_changed or skills_removed or skills_added_masked:
        axis_verdict = "drifted_incompatible"
        parts: list[str] = []
        if skills_changed:
            parts.append("skills_changed=" + ", ".join(skills_changed))
        if skills_removed:
            parts.append("skills_removed=" + ", ".join(skills_removed))
        reason = "; ".join(parts) or "project skill drift detected"
    elif observed_dir_hash != current_dir_hash:
        axis_verdict = "drifted_compatible"
        reason = "project dir_hash differs but skills_used unaffected"
    else:
        axis_verdict = "replayable"
        reason = "project skill snapshot matches current byte-for-byte"

    return {
        "was_recorded": True,
        "axis_verdict": axis_verdict,
        "project_dir_present_observed": observed_present,
        "project_dir_present_current": current_present,
        "dir_hash_observed": observed_dir_hash,
        "dir_hash_current": current_dir_hash,
        "skills_used": skills_used,
        "skills_changed": sorted(skills_changed),
        "skills_removed": sorted(skills_removed),
        "skills_added_masked": skills_added_masked,
        "reason": reason,
    }


_AXIS_SEVERITY = {
    VERDICT_REPLAYABLE: 0,
    VERDICT_DRIFTED_COMPATIBLE: 1,
    VERDICT_DRIFTED_INCOMPATIBLE: 2,
}
_AXIS_SEVERITY_INV = {v: k for k, v in _AXIS_SEVERITY.items()}


def _aggregate_axes(*axis_verdicts: str) -> str:
    """Worst-non-neutral aggregation across N axes (H3 #3 widened from 2).

    ``unverifiable_axis`` is treated as neutral (omitted from the worst
    selection). When every axis is neutral, the top-level verdict is
    ``unverifiable``. Variadic so H3 can pass 5 axes (builtin / project /
    workflow_yaml / constitution / capability_schema) without changing
    callers from the H2 dual-axis era; existing two-arg call sites in
    tests still work because Python accepts 2 positional args as varargs.
    """
    candidates = [
        _AXIS_SEVERITY[v] for v in axis_verdicts if v in _AXIS_SEVERITY
    ]
    if not candidates:
        return VERDICT_UNVERIFIABLE
    return _AXIS_SEVERITY_INV[max(candidates)]


def _compute_workflow_yaml_axis(envelope: dict) -> dict:
    """Return drift_details.workflow_yaml_diff body (H3 #3).

    Whole-file hash only per design memo §5.1. Output shape conforms to
    schemas/replay-verdict.schema.yaml workflow_yaml_diff. Three branches:

    * No baseline → ``axis_verdict=unverifiable_axis``,
      ``was_recorded=False``.
    * Baseline + workflow file still resolvable + hash matches →
      ``replayable``.
    * Baseline + (file missing OR hash differs) →
      ``drifted_compatible``. Drifted_incompatible is NEVER emitted
      for this axis (precision limit).
    """
    observed = envelope.get("workflow_yaml_baseline") or None
    if observed is None:
        return {
            "was_recorded": False,
            "axis_verdict": "unverifiable_axis",
            "workflow_id": None,
            "workflow_path": None,
            "source_layer": None,
            "workflow_present_observed": None,
            "workflow_present_current": False,
            "content_hash_observed": None,
            "content_hash_current": None,
            "reason": "workflow_yaml_baseline absent on envelope",
        }

    workflow_path_str = observed.get("workflow_path")
    workflow_present_observed = bool(observed.get("workflow_present"))
    content_hash_observed = observed.get("content_hash")

    if workflow_path_str:
        current = workflow_yaml_compute_snapshot(
            workflow_path=Path(workflow_path_str),
            workflow_id=observed.get("workflow_id"),
            source_layer=observed.get("source_layer"),
        )
    else:
        current = {"workflow_present": False, "content_hash": None}

    workflow_present_current = bool(current.get("workflow_present"))
    content_hash_current = current.get("content_hash")

    if (
        workflow_present_observed
        and workflow_present_current
        and content_hash_observed
        and content_hash_observed == content_hash_current
    ):
        axis_verdict = "replayable"
        reason = "workflow YAML content_hash matches current"
    elif not workflow_present_current and workflow_present_observed:
        axis_verdict = "drifted_compatible"
        reason = "workflow YAML missing at expected path"
    else:
        axis_verdict = "drifted_compatible"
        reason = "workflow YAML content_hash differs"

    return {
        "was_recorded": True,
        "axis_verdict": axis_verdict,
        "workflow_id": observed.get("workflow_id"),
        "workflow_path": workflow_path_str,
        "source_layer": observed.get("source_layer"),
        "workflow_present_observed": workflow_present_observed,
        "workflow_present_current": workflow_present_current,
        "content_hash_observed": content_hash_observed,
        "content_hash_current": content_hash_current,
        "reason": reason,
    }


def _compute_constitution_axis(
    envelope: dict, *, project_root: Path | None = None
) -> dict:
    """Return drift_details.constitution_diff body (H3 #3, whole-file hash)."""
    observed = envelope.get("constitution_baseline") or None
    current = constitution_compute_snapshot(project_root=project_root)
    constitution_present_current = bool(current.get("constitution_present"))
    content_hash_current = current.get("content_hash")
    constitution_path_current = current.get("constitution_path")

    if observed is None:
        return {
            "was_recorded": False,
            "axis_verdict": "unverifiable_axis",
            "constitution_path": constitution_path_current,
            "constitution_present_observed": None,
            "constitution_present_current": constitution_present_current,
            "content_hash_observed": None,
            "content_hash_current": content_hash_current,
            "reason": "constitution_baseline absent on envelope",
        }

    constitution_present_observed = bool(observed.get("constitution_present"))
    content_hash_observed = observed.get("content_hash")

    if (
        constitution_present_observed == constitution_present_current
        and content_hash_observed == content_hash_current
    ):
        axis_verdict = "replayable"
        reason = "constitution content_hash matches current"
    else:
        axis_verdict = "drifted_compatible"
        if constitution_present_observed and not constitution_present_current:
            reason = "constitution removed since the run"
        elif not constitution_present_observed and constitution_present_current:
            reason = "constitution added since the run"
        else:
            reason = "constitution content_hash differs"

    return {
        "was_recorded": True,
        "axis_verdict": axis_verdict,
        "constitution_path": observed.get("constitution_path") or constitution_path_current,
        "constitution_present_observed": constitution_present_observed,
        "constitution_present_current": constitution_present_current,
        "content_hash_observed": content_hash_observed,
        "content_hash_current": content_hash_current,
        "reason": reason,
    }


def _compute_capability_schema_axis(
    envelope: dict, *, cap_root: Path | None = None
) -> dict:
    """Return drift_details.capability_schema_diff body (H3 #3, whole-file hash)."""
    observed = envelope.get("capability_schema_baseline") or None
    current = capability_schema_compute_snapshot(cap_root=cap_root)
    schema_present_current = bool(current.get("schema_present"))
    content_hash_current = current.get("content_hash")
    schema_path_current = current.get("schema_path")

    if observed is None:
        return {
            "was_recorded": False,
            "axis_verdict": "unverifiable_axis",
            "schema_path": schema_path_current,
            "schema_present_observed": None,
            "schema_present_current": schema_present_current,
            "content_hash_observed": None,
            "content_hash_current": content_hash_current,
            "reason": "capability_schema_baseline absent on envelope",
        }

    schema_present_observed = bool(observed.get("schema_present"))
    content_hash_observed = observed.get("content_hash")

    if (
        schema_present_observed == schema_present_current
        and content_hash_observed == content_hash_current
    ):
        axis_verdict = "replayable"
        reason = "capability schema content_hash matches current"
    else:
        axis_verdict = "drifted_compatible"
        reason = "capability schema content_hash differs"

    return {
        "was_recorded": True,
        "axis_verdict": axis_verdict,
        "schema_path": observed.get("schema_path") or schema_path_current,
        "schema_present_observed": schema_present_observed,
        "schema_present_current": schema_present_current,
        "content_hash_observed": content_hash_observed,
        "content_hash_current": content_hash_current,
        "reason": reason,
    }


def _compose_reason(
    verdict: str,
    builtin_drift: dict,
    project_axis: dict,
    *,
    workflow_yaml_axis: dict | None = None,
    constitution_axis: dict | None = None,
    capability_schema_axis: dict | None = None,
) -> str:
    """Build the top-level human-readable reason string.

    Mentions the dominant axis(es) so the caller can read why the
    aggregate verdict landed where it did. Keeps single-line format.
    H3 #3: extended to mention the three new whole-file axes. Each
    H3 axis can only contribute "drifted_compatible" reason text
    (whole-file hash precision limit); incompatible reasons stay
    sourced from builtin / project axes only.
    """
    if verdict == VERDICT_REPLAYABLE:
        return "stored baseline matches current baseline byte-for-byte"

    parts: list[str] = []
    bc = builtin_drift.get("prompt_files_changed") or []
    br = builtin_drift.get("prompt_files_removed") or []
    if bc:
        parts.append("prompt_files_changed=" + ", ".join(bc))
    if br:
        parts.append("prompt_files_removed=" + ", ".join(br))

    pc = project_axis.get("skills_changed") or []
    pr = project_axis.get("skills_removed") or []
    pm = project_axis.get("skills_added_masked") or []
    if pc:
        parts.append("project_skills_changed=" + ", ".join(pc))
    if pr:
        parts.append("project_skills_removed=" + ", ".join(pr))
    if pm:
        parts.append("project_skills_masked=" + ", ".join(pm))

    # H3 axes — whole-file hash, surface compatible drift only.
    if (
        workflow_yaml_axis
        and workflow_yaml_axis.get("axis_verdict") == VERDICT_DRIFTED_COMPATIBLE
    ):
        parts.append("workflow_yaml content_hash differs")
    if (
        constitution_axis
        and constitution_axis.get("axis_verdict") == VERDICT_DRIFTED_COMPATIBLE
    ):
        parts.append("constitution content_hash differs")
    if (
        capability_schema_axis
        and capability_schema_axis.get("axis_verdict") == VERDICT_DRIFTED_COMPATIBLE
    ):
        parts.append("capability_schema content_hash differs")

    if not parts:
        # drifted_compatible without specific file pinpoints (e.g.,
        # builtin dir_hash differs but no used files affected).
        if not builtin_drift.get("dir_hash_match"):
            parts.append("builtin dir_hash differs but no used files affected")
        if (
            project_axis.get("axis_verdict") == VERDICT_DRIFTED_COMPATIBLE
            and project_axis.get("dir_hash_observed")
            != project_axis.get("dir_hash_current")
        ):
            parts.append("project dir_hash differs but skills_used unaffected")

    return "; ".join(parts) or verdict


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
    """Mirror the agent-sessions envelope ``agent_skills_baseline`` (H1).

    Per H1 design memo §4.2, the mirror is a convenience copy of the
    envelope's ``agent_skills_baseline`` so external tooling can stat
    one small file instead of parsing the whole sessions ledger. The
    envelope remains the SSOT; the mirror is only written when the
    envelope had a baseline (verdicts ``unverifiable`` / ``not_found``
    write nothing).

    Idempotent: when the existing mirror already encodes identical
    bytes, the file is left untouched. Returns the mirror path or
    ``None`` when no baseline existed to mirror.
    """
    return _write_mirror(run_dir, observed_baseline, "agent-skills.json")


def write_project_skill_mirror(run_dir: Path, observed_baseline: dict | None) -> Path | None:
    """Mirror the envelope's ``project_skill_baseline`` (H2 #4).

    Parallel to :func:`write_snapshot_mirror`: writes
    ``<run_dir>/snapshots/project-skills.json`` when the envelope had
    a project layer baseline. Skips when absent (no observed state to
    mirror; the verifier separately surfaces the current snapshot in
    ``drift_details.project_skill_diff``).
    """
    return _write_mirror(run_dir, observed_baseline, "project-skills.json")


def write_binding_summary_mirror(run_dir: Path, summary: dict | None) -> Path | None:
    """Mirror the envelope's ``binding_summary`` (H2 #4).

    Writes ``<run_dir>/snapshots/binding-summary.json`` so external
    tooling can read the per-step ``[step_id, selected_skill_id,
    skill_source]`` projection without parsing the agent-sessions
    ledger. Skips when summary is missing.
    """
    return _write_mirror(run_dir, summary, "binding-summary.json")


def write_workflow_yaml_mirror(run_dir: Path, baseline: dict | None) -> Path | None:
    """Mirror envelope's ``workflow_yaml_baseline`` (H3 #4)."""
    return _write_mirror(run_dir, baseline, "workflow-yaml.json")


def write_constitution_mirror(run_dir: Path, baseline: dict | None) -> Path | None:
    """Mirror envelope's ``constitution_baseline`` (H3 #4)."""
    return _write_mirror(run_dir, baseline, "constitution.json")


def write_capability_schema_mirror(run_dir: Path, baseline: dict | None) -> Path | None:
    """Mirror envelope's ``capability_schema_baseline`` (H3 #4)."""
    return _write_mirror(run_dir, baseline, "capability-schema.json")


def _write_mirror(run_dir: Path, payload: dict | None, filename: str) -> Path | None:
    if not payload:
        return None
    run_dir = Path(run_dir)
    snapshot_dir = run_dir / "snapshots"
    snapshot_dir.mkdir(parents=True, exist_ok=True)
    mirror_path = snapshot_dir / filename
    if mirror_path.is_file():
        try:
            existing = json.loads(mirror_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            existing = None
        if existing == payload:
            return mirror_path
    mirror_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
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
            sessions_envelope = _read_sessions_envelope(args.run_dir)
            if sessions_envelope is not None:
                write_snapshot_mirror(
                    args.run_dir,
                    sessions_envelope.get("agent_skills_baseline"),
                )
                write_project_skill_mirror(
                    args.run_dir,
                    sessions_envelope.get("project_skill_baseline"),
                )
                write_binding_summary_mirror(
                    args.run_dir,
                    sessions_envelope.get("binding_summary"),
                )
                write_workflow_yaml_mirror(
                    args.run_dir,
                    sessions_envelope.get("workflow_yaml_baseline"),
                )
                write_constitution_mirror(
                    args.run_dir,
                    sessions_envelope.get("constitution_baseline"),
                )
                write_capability_schema_mirror(
                    args.run_dir,
                    sessions_envelope.get("capability_schema_baseline"),
                )
        print(json.dumps(envelope, ensure_ascii=False, indent=2))
        return verdict_to_exit_code(envelope["verdict"])

    return EXIT_INTERNAL_ERROR


def _read_sessions_envelope(run_dir: Path) -> dict | None:
    """Re-read the full agent-sessions envelope so mirror writers see the
    canonical (observed-side) project_skill_baseline + binding_summary
    in addition to agent_skills_baseline.

    Mirror files deliberately hold the full snapshot (per-file hashes,
    skills_by_id maps) rather than the compact projections that
    ``baseline_observed`` carries; this helper grabs them from the
    SSOT envelope. Returns ``None`` when the ledger is missing /
    unreadable so callers can skip mirror creation cleanly.
    """
    sessions_path = run_dir / "agent-sessions.json"
    if not sessions_path.is_file():
        return None
    try:
        return json.loads(sessions_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def _read_observed_full(run_dir: Path) -> dict | None:
    """Backward-compat shim: returns the agent_skills_baseline only.

    Retained because external callers / tests in tests/scripts/ may
    still import this name. New code should use
    :func:`_read_sessions_envelope` and pull whichever field it needs.
    """
    envelope = _read_sessions_envelope(run_dir)
    if envelope is None:
        return None
    return envelope.get("agent_skills_baseline") or None


if __name__ == "__main__":
    raise SystemExit(_cli(sys.argv[1:]))
