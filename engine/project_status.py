"""project_status — Read-only summary for ``cap project status`` (P1 #5).

Combines four signals into one structured report:

1. Project identity (project_id, mode, root, storage path, ledger path).
2. Identity ledger snapshot (schema_version, created_at, last_resolved_at,
   cap_version, previous_versions[]).
3. Constitution snapshots present in the storage (file list + count).
4. Latest workflow run (workflow_id, run_id, mtime).

All health-class judgements are delegated to ``engine.storage_health`` —
this module never re-implements ledger / collision / schema validation.
That keeps producer/consumer policy single-sourced per
``policies/cap-storage-metadata.md`` §6.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
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


@dataclass
class LatestRunInfo:
    workflow_id: str
    run_id: str
    run_path: str
    mtime: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "workflow_id": self.workflow_id,
            "run_id": self.run_id,
            "run_path": self.run_path,
            "mtime": self.mtime,
        }


@dataclass
class ProjectStatusReport:
    project_id: str
    project_root: str
    project_store: str
    ledger_path: str
    cap_home: str
    manifest_cap_version: str | None
    ledger_snapshot: dict[str, Any]
    constitutions: list[str]
    constitution_count: int
    latest_run: LatestRunInfo | None
    health_status: HealthStatus
    health_issue_count: int
    health_summary: dict[str, int]
    health_issues: list[dict[str, Any]]

    def to_dict(self) -> dict[str, Any]:
        return {
            "subcommand": "status",
            "project_id": self.project_id,
            "project_root": self.project_root,
            "project_store": self.project_store,
            "ledger_path": self.ledger_path,
            "cap_home": self.cap_home,
            "manifest_cap_version": self.manifest_cap_version,
            "ledger_snapshot": self.ledger_snapshot,
            "constitutions": self.constitutions,
            "constitution_count": self.constitution_count,
            "latest_run": self.latest_run.to_dict() if self.latest_run else None,
            "health": {
                "status": self.health_status.value,
                "issue_count": self.health_issue_count,
                "summary": self.health_summary,
                "issues": self.health_issues,
            },
        }

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), indent=2, ensure_ascii=False)

    def to_yaml(self) -> str:
        return yaml.safe_dump(self.to_dict(), sort_keys=False, allow_unicode=True)


# ─────────────────────────────────────────────────────────
# Builder
# ─────────────────────────────────────────────────────────


def _read_ledger_snapshot(ledger_path: Path) -> dict[str, Any]:
    """Best-effort ledger read for display only.

    Schema validity is the storage_health module's responsibility; this
    function returns whatever JSON exists so the report can show the user
    what the file actually contains, even when health flags it.
    """
    if not ledger_path.is_file():
        return {}
    try:
        return json.loads(ledger_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def _list_constitutions(constitution_dir: Path) -> list[str]:
    if not constitution_dir.is_dir():
        return []
    return sorted(
        p.name for p in constitution_dir.iterdir() if p.is_file() and not p.name.startswith(".")
    )


def _find_latest_run(workflow_report_dir: Path) -> LatestRunInfo | None:
    """Return the most recently modified run directory under any workflow.

    Layout assumed (matches cap-workflow-exec.sh output):

        <workflow_report_dir>/<workflow_id>/<run_id>/...

    We scan one level deep and pick the run with the largest mtime.
    Returns ``None`` if no run dir exists yet.
    """
    if not workflow_report_dir.is_dir():
        return None

    latest: tuple[float, Path, str] | None = None
    for workflow_dir in workflow_report_dir.iterdir():
        if not workflow_dir.is_dir():
            continue
        for run_dir in workflow_dir.iterdir():
            if not run_dir.is_dir():
                continue
            try:
                mt = run_dir.stat().st_mtime
            except OSError:
                continue
            if latest is None or mt > latest[0]:
                latest = (mt, run_dir, workflow_dir.name)

    if latest is None:
        return None

    mt, run_path, workflow_id = latest
    iso = datetime.datetime.fromtimestamp(mt, tz=datetime.timezone.utc) \
        .strftime("%Y-%m-%dT%H:%M:%SZ")
    return LatestRunInfo(
        workflow_id=workflow_id,
        run_id=run_path.name,
        run_path=str(run_path),
        mtime=iso,
    )


def build_project_status(
    project_root: Path,
    *,
    cap_home: Path | None = None,
    project_id_override: str | None = None,
) -> ProjectStatusReport:
    """Assemble the full status report.

    Identity, paths, and health verdict come from
    ``engine.storage_health.run_health_check``. We only add display-only
    enrichment (ledger snapshot, constitution list, latest run).
    """
    health: StorageHealthReport = run_health_check(
        project_root=project_root,
        cap_home=cap_home,
        project_id_override=project_id_override,
    )

    project_store = Path(health.project_store)
    ledger_path = Path(health.ledger_path)
    constitution_dir = project_store / "constitutions"
    workflow_report_dir = project_store / "reports" / "workflows"

    ledger_snapshot = _read_ledger_snapshot(ledger_path)
    constitutions = _list_constitutions(constitution_dir)
    latest_run = _find_latest_run(workflow_report_dir)

    return ProjectStatusReport(
        project_id=health.project_id,
        project_root=health.project_root,
        project_store=health.project_store,
        ledger_path=health.ledger_path,
        cap_home=health.cap_home,
        manifest_cap_version=health.manifest_cap_version,
        ledger_snapshot=ledger_snapshot,
        constitutions=constitutions,
        constitution_count=len(constitutions),
        latest_run=latest_run,
        health_status=health.overall_status,
        health_issue_count=health.summary.get("total", 0),
        health_summary=health.summary,
        health_issues=[i.to_dict() for i in health.issues],
    )


# ─────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────


def _format_text(report: ProjectStatusReport) -> str:
    lines = [
        f"project_id={report.project_id}",
        f"project_root={report.project_root}",
        f"project_store={report.project_store}",
        f"ledger_path={report.ledger_path}",
        f"cap_home={report.cap_home}",
        f"manifest_cap_version={report.manifest_cap_version or '<none>'}",
    ]
    snap = report.ledger_snapshot
    if snap:
        lines.append(
            "ledger_snapshot:"
            f" schema_version={snap.get('schema_version', '<missing>')}"
            f" created_at={snap.get('created_at', '<missing>')}"
            f" last_resolved_at={snap.get('last_resolved_at', '<missing>')}"
            f" cap_version={snap.get('cap_version') or '<none>'}"
        )
    else:
        lines.append("ledger_snapshot=<unreadable>")
    lines.append(f"constitution_count={report.constitution_count}")
    if report.constitutions:
        for name in report.constitutions:
            lines.append(f"  - {name}")
    if report.latest_run:
        lines.append(
            "latest_run:"
            f" workflow_id={report.latest_run.workflow_id}"
            f" run_id={report.latest_run.run_id}"
            f" mtime={report.latest_run.mtime}"
        )
    else:
        lines.append("latest_run=<none>")
    lines.append(f"health_status={report.health_status.value}")
    lines.append(f"health_summary={report.health_summary}")
    if report.health_issues:
        lines.append("health_issues:")
        for issue in report.health_issues:
            lines.append(f"  - [{issue['severity']}] {issue['kind']}: {issue['message']}")
    return "\n".join(lines) + "\n"


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="cap project status",
        description="Read-only project summary (id, paths, ledger, latest run, health).",
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
        "--format",
        choices=("text", "json", "yaml"),
        default="text",
        help="Output format (default: text).",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    report = build_project_status(
        project_root=args.project_root.resolve(),
        cap_home=args.cap_home.resolve() if args.cap_home else None,
        project_id_override=args.project_id,
    )

    if args.format == "json":
        sys.stdout.write(report.to_json() + "\n")
    elif args.format == "yaml":
        sys.stdout.write(report.to_yaml())
    else:
        sys.stdout.write(_format_text(report))

    # Status is informational; only error-class health issues drive a
    # non-zero exit code (mirrors the diagnostic layer in storage_health).
    if report.health_status is HealthStatus.ERROR:
        # Map to the same exit-code precedence storage_health uses so callers
        # can branch on it consistently. We rebuild the precedence here
        # rather than reaching into storage_health internals.
        kinds = {issue["kind"] for issue in report.health_issues}
        schema_class = {
            HealthIssueKind.MALFORMED_LEDGER.value,
            HealthIssueKind.FORWARD_INCOMPAT_LEDGER.value,
            HealthIssueKind.LEDGER_SCHEMA_DRIFT.value,
        }
        if kinds & schema_class:
            return 41
        if HealthIssueKind.LEDGER_ORIGIN_MISMATCH.value in kinds:
            return 53
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
