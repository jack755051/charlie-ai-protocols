"""project_doctor — Read-only diagnostic for ``cap project doctor`` (P1 #7).

Translates every :class:`engine.storage_health.HealthIssueKind` into a
concrete remediation step. The doctor is **read-only by design** (per
the P1 #7 brief): it surfaces what is wrong and tells the user what to
run next, but never mutates project state. ``--fix`` is accepted as a
forward-compatible flag and currently emits "not implemented" guidance,
keeping the surface area stable for a future P1 #7 follow-up.

Exit-code policy mirrors :mod:`engine.storage_health`:

    41 — schema-class issues (malformed / forward-incompat / drift)
    53 — origin collision
     1 — generic error (missing storage / unwritable / missing ledger)
     0 — only warnings or no issues
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

# Reuse storage_health primitives — never duplicate health logic in this module.
try:
    from engine.storage_health import (  # type: ignore[import-not-found]
        HealthIssueKind,
        HealthStatus,
        StorageHealthReport,
        run_health_check,
    )
except ModuleNotFoundError:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from storage_health import (  # type: ignore[no-redef]
        HealthIssueKind,
        HealthStatus,
        StorageHealthReport,
        run_health_check,
    )


# Per-issue remediation guidance. Each entry is a list of concrete
# remediation hints — kept short so the JSON / YAML envelope stays machine
# parseable, and ordered so the most likely fix appears first.
#
# Rules of thumb when adding new entries:
#   - State the action the user should take, not the underlying mechanism.
#   - Reference real CLI commands (`cap project init`, `cap-paths.sh ensure`)
#     so the user can copy-paste.
#   - Never recommend an action the doctor itself does not perform read-only.
#   - Never assert that a future P1 #7 --fix path will handle it; that path
#     is intentionally out of scope.
REMEDIATIONS: dict[HealthIssueKind, list[str]] = {
    HealthIssueKind.MISSING_STORAGE_ROOT: [
        "Run `cap project init` (or `cap-paths.sh ensure` directly) inside this project root to create the storage directory.",
        "If the project_id was never resolvable, set CAP_PROJECT_ID_OVERRIDE or write `.cap.project.yaml` with a stable id first.",
    ],
    HealthIssueKind.UNWRITABLE_STORAGE: [
        "Check filesystem permissions on the project_store path; the storage directory must be writable by the current user.",
        "If the storage was relocated or copied between users, run `chown -R $(whoami) <project_store>` to restore ownership.",
    ],
    HealthIssueKind.MISSING_DIRECTORY: [
        "Run `cap-paths.sh ensure` (or `cap project init --force`) to recreate the missing required subdirectories.",
        "ensure is idempotent and only writes the ledger's last_resolved_at, so it is safe to re-run.",
    ],
    HealthIssueKind.MISSING_LEDGER: [
        "Run `cap-paths.sh ensure` (or `cap project init --force`) to write a fresh v2 identity ledger.",
        "Do NOT hand-write the ledger; cap-paths is the single producer per policies/cap-storage-metadata.md §1.",
    ],
    HealthIssueKind.MALFORMED_LEDGER: [
        "Inspect the ledger for the JSON parse failure surfaced in the health-check detail; back it up if the contents look salvageable.",
        "Once backed up, delete the ledger and run `cap-paths.sh ensure` to rewrite a clean v2 ledger.",
        "Hand-editing the ledger is not supported; cap-paths is the single producer.",
    ],
    HealthIssueKind.FORWARD_INCOMPAT_LEDGER: [
        "The ledger was written by a newer CAP build than the one currently in use; upgrade CAP to the latest release.",
        "If the storage was inherited from an older project copy, archive it (e.g. `mv <project_store> <project_store>.bak`) and re-run `cap project init` to rebuild from this build.",
        "Never silently downgrade the ledger; forward-incompat halt is intentional per policies/cap-storage-metadata.md §3.2.",
    ],
    HealthIssueKind.LEDGER_SCHEMA_DRIFT: [
        "Required fields or enum values are missing/invalid; back up the ledger and run `cap-paths.sh ensure` to rewrite a clean v2 ledger.",
        "If the ledger was edited by hand, restore it from version control or recreate it via `cap project init --force`.",
    ],
    HealthIssueKind.LEDGER_ORIGIN_MISMATCH: [
        "The ledger was created from a different filesystem path; this is a project_id collision.",
        "Resolve by either changing project_id in `.cap.project.yaml` (or `CAP_PROJECT_ID_OVERRIDE`) so the new origin gets its own storage,",
        "or remove the colliding storage at `<project_store>` if you intend to repoint the existing project_id at this checkout.",
    ],
    HealthIssueKind.LEGACY_LEDGER_PENDING_MIGRATION: [
        "Run `cap-paths.sh ensure` to auto-migrate the v1 ledger to v2 (immutable created_at / origin_path / project_id / resolved_mode are preserved).",
        "Migration is one-way; once on v2 the ledger cannot be downgraded.",
    ],
    HealthIssueKind.CAP_VERSION_MISMATCH: [
        "The ledger was written by a different CAP version than `repo.manifest.yaml` declares; this is governance drift, not a runtime error.",
        "If the manifest is authoritative, run `cap-paths.sh ensure` after upgrading CAP to align the ledger's cap_version on next migration.",
        "If the manifest is wrong, bump `repo.manifest.yaml` cap_version in the repo and re-commit.",
    ],
    HealthIssueKind.STALE_STORAGE: [
        "The storage has not been touched by a workflow run for an extended period; consider archiving or rebuilding it.",
        "If this project is still active, simply re-running any `cap workflow run` updates last_resolved_at on the next ensure.",
        "Adjust the staleness threshold via `cap project doctor --stale-days N` to match your team's usage cadence.",
    ],
    HealthIssueKind.UNKNOWN_LEDGER_FIELD: [
        "Unknown top-level fields in the ledger likely indicate a future schema field; verify by running `cap version` and checking policies/cap-storage-metadata.md.",
        "Safe to ignore if the field name matches a documented future addition; otherwise, back up and re-run `cap-paths.sh ensure`.",
    ],
}


@dataclass
class DoctorIssue:
    kind: str
    severity: str
    message: str
    detail: dict[str, Any]
    remediation: list[str]

    def to_dict(self) -> dict[str, Any]:
        return {
            "kind": self.kind,
            "severity": self.severity,
            "message": self.message,
            "detail": self.detail,
            "remediation": self.remediation,
        }


@dataclass
class DoctorReport:
    project_id: str
    project_root: str
    project_store: str
    ledger_path: str
    cap_home: str
    manifest_cap_version: str | None
    overall_status: str
    summary: dict[str, int]
    issues: list[DoctorIssue]
    fix_requested: bool
    fix_applied: bool
    fix_notes: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "subcommand": "doctor",
            "project_id": self.project_id,
            "project_root": self.project_root,
            "project_store": self.project_store,
            "ledger_path": self.ledger_path,
            "cap_home": self.cap_home,
            "manifest_cap_version": self.manifest_cap_version,
            "overall_status": self.overall_status,
            "summary": self.summary,
            "issues": [i.to_dict() for i in self.issues],
            "fix_requested": self.fix_requested,
            "fix_applied": self.fix_applied,
            "fix_notes": self.fix_notes,
        }

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), indent=2, ensure_ascii=False)

    def to_yaml(self) -> str:
        return yaml.safe_dump(self.to_dict(), sort_keys=False, allow_unicode=True)

    def exit_code(self) -> int:
        kinds = {issue.kind for issue in self.issues}
        schema_class = {
            HealthIssueKind.MALFORMED_LEDGER.value,
            HealthIssueKind.FORWARD_INCOMPAT_LEDGER.value,
            HealthIssueKind.LEDGER_SCHEMA_DRIFT.value,
        }
        if kinds & schema_class:
            return 41
        if HealthIssueKind.LEDGER_ORIGIN_MISMATCH.value in kinds:
            return 53
        if self.overall_status == HealthStatus.ERROR.value:
            return 1
        return 0


# ─────────────────────────────────────────────────────────
# Builder
# ─────────────────────────────────────────────────────────


def _remediation_for(kind_value: str) -> list[str]:
    try:
        kind = HealthIssueKind(kind_value)
    except ValueError:
        return [
            f"Unknown HealthIssueKind={kind_value!r}; check engine/storage_health.py for new kinds and update REMEDIATIONS.",
        ]
    return REMEDIATIONS.get(kind, [
        f"No remediation defined for {kind_value!r}; this is a doctor coverage gap. "
        "Update engine/project_doctor.py REMEDIATIONS.",
    ])


def build_doctor_report(
    project_root: Path,
    *,
    cap_home: Path | None = None,
    project_id_override: str | None = None,
    stale_days: int | None = None,
    fix_requested: bool = False,
) -> DoctorReport:
    """Run the health check and decorate every issue with remediation guidance."""
    health_kwargs: dict[str, Any] = {
        "project_root": project_root,
        "cap_home": cap_home,
        "project_id_override": project_id_override,
    }
    if stale_days is not None:
        health_kwargs["stale_days"] = stale_days

    health: StorageHealthReport = run_health_check(**health_kwargs)

    decorated: list[DoctorIssue] = []
    for issue in health.issues:
        decorated.append(
            DoctorIssue(
                kind=issue.kind.value,
                severity=issue.severity.value,
                message=issue.message,
                detail=issue.detail,
                remediation=_remediation_for(issue.kind.value),
            )
        )

    fix_notes: list[str] = []
    if fix_requested:
        # P1 #7 brief: keep --fix as a documented forward-compat flag, but
        # do NOT auto-mutate state. Surface a clear message instead so the
        # user knows the doctor is intentionally read-only.
        fix_notes.append(
            "--fix is reserved for a future iteration of P1 #7; "
            "doctor currently runs read-only and never mutates project state. "
            "Apply the listed remediation steps manually."
        )

    return DoctorReport(
        project_id=health.project_id,
        project_root=health.project_root,
        project_store=health.project_store,
        ledger_path=health.ledger_path,
        cap_home=health.cap_home,
        manifest_cap_version=health.manifest_cap_version,
        overall_status=health.overall_status.value,
        summary=health.summary,
        issues=decorated,
        fix_requested=fix_requested,
        fix_applied=False,
        fix_notes=fix_notes,
    )


# ─────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────


def _format_text(report: DoctorReport) -> str:
    lines = [
        f"project_id={report.project_id}",
        f"project_root={report.project_root}",
        f"project_store={report.project_store}",
        f"ledger_path={report.ledger_path}",
        f"cap_home={report.cap_home}",
        f"manifest_cap_version={report.manifest_cap_version or '<none>'}",
        f"overall_status={report.overall_status}",
        f"summary={report.summary}",
        f"fix_requested={report.fix_requested}",
        f"fix_applied={report.fix_applied}",
    ]
    if report.fix_notes:
        lines.append("fix_notes:")
        for note in report.fix_notes:
            lines.append(f"  - {note}")
    if not report.issues:
        lines.append("issues: <none>")
    else:
        lines.append("issues:")
        for issue in report.issues:
            lines.append(f"  - [{issue.severity}] {issue.kind}: {issue.message}")
            if issue.detail:
                lines.append("    detail:")
                for k, v in issue.detail.items():
                    lines.append(f"      {k}: {v}")
            if issue.remediation:
                lines.append("    remediation:")
                for step in issue.remediation:
                    lines.append(f"      - {step}")
    return "\n".join(lines) + "\n"


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="cap project doctor",
        description="Read-only diagnostic with remediation suggestions (P1 #7).",
    )
    parser.add_argument(
        "--project-root",
        type=Path,
        default=Path.cwd(),
        help="Repo root to inspect (default: $PWD).",
    )
    parser.add_argument(
        "--cap-home",
        type=Path,
        default=None,
        help="Override CAP_HOME (default: $CAP_HOME or ~/.cap).",
    )
    parser.add_argument(
        "--project-id",
        type=str,
        default=None,
        help="Override resolved project_id; bypasses the resolver.",
    )
    parser.add_argument(
        "--stale-days",
        type=int,
        default=None,
        help="Staleness threshold in days; defaults to storage_health default.",
    )
    parser.add_argument(
        "--format",
        choices=("text", "json", "yaml"),
        default="text",
        help="Output format (default: text).",
    )
    parser.add_argument(
        "--fix",
        action="store_true",
        help="Reserved for a future iteration of P1 #7. The doctor remains "
        "read-only; setting this flag emits guidance only, never auto-mutates state.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    report = build_doctor_report(
        project_root=args.project_root.resolve(),
        cap_home=args.cap_home.resolve() if args.cap_home else None,
        project_id_override=args.project_id,
        stale_days=args.stale_days,
        fix_requested=args.fix,
    )

    if args.format == "json":
        sys.stdout.write(report.to_json() + "\n")
    elif args.format == "yaml":
        sys.stdout.write(report.to_yaml())
    else:
        sys.stdout.write(_format_text(report))

    return report.exit_code()


if __name__ == "__main__":
    sys.exit(main())
