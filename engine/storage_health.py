"""storage_health — CAP project storage health-check core (P1 #4).

This module is the single read-only diagnostic layer that callers (CLI
``cap project status`` / ``cap project doctor``, the upcoming P1 #5/#7
commands, and the shell wrapper ``scripts/cap-storage-health.sh``) share.

Contract boundaries
-------------------

- **Read-only**. Health checks MUST NOT touch ``last_resolved_at`` or any
  other ledger field — that signal is owned by ``cap-paths.sh ensure``
  (see ``policies/cap-storage-metadata.md`` §4). Inspection-time writes
  would erase the "actively used by workflow" signal that health checks
  themselves consume.
- **Diagnostic, not enforcing**. The producer-side halts (cap-paths exit
  41 / 52 / 53) stay where they are. This module emits a structured
  report; the caller decides whether to halt, warn, or repair.
- **Schema SSOT alignment**. Required ledger fields and ``resolved_mode``
  enum mirror ``schemas/identity-ledger.schema.yaml`` v2. When the schema
  evolves, update both in lock-step.

Exit-code mapping (used by the shell wrapper / CLI consumers)
-------------------------------------------------------------

- ``0`` — no errors (warnings allowed). Storage usable.
- ``41`` — schema-class issues (malformed / forward-incompat / drift).
- ``53`` — origin-path collision detected on this storage.
- ``1``  — generic error (missing storage dir / unwritable / missing ledger).

The 41/53 codes deliberately match the producer policy in
``policies/workflow-executor-exit-codes.md`` so the same diagnosis on
either side of the producer/consumer boundary maps to the same code.
"""

from __future__ import annotations

import argparse
import datetime
import enum
import json
import os
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

import yaml


# Mirror schemas/identity-ledger.schema.yaml v2.
_LEDGER_SCHEMA_VERSION = 2
_LEDGER_REQUIRED_FIELDS = (
    "schema_version",
    "project_id",
    "resolved_mode",
    "origin_path",
    "created_at",
    "last_resolved_at",
)
_LEDGER_RESOLVED_MODES = (
    "override",
    "config",
    "git_basename",
    "basename_legacy",
)
_LEDGER_OPTIONAL_FIELDS = ("migrated_at", "cap_version", "previous_versions")
_LEDGER_KNOWN_FIELDS = set(_LEDGER_REQUIRED_FIELDS) | set(_LEDGER_OPTIONAL_FIELDS)

# Directories that ``cap-paths ensure`` creates under the project store.
# Only the structural subset that makes storage usable; per-run artifacts
# (e.g. a specific run dir) are not validated here.
_REQUIRED_SUBDIRS = (
    "traces",
    "logs",
    "drafts",
    "handoffs",
    "reports",
    "reports/workflows",
    "constitutions",
    "compiled-workflows",
    "bindings",
    "workspace",
    "cache",
    "sessions",
)

# Storage staleness threshold. Anything older than this triggers a
# warning (not an error) — staleness is a signal that the project may
# need re-init / cleanup, not a failure.
_STALE_DAYS_DEFAULT = 90


class HealthStatus(str, enum.Enum):
    """Aggregate health verdict; ordered by severity."""

    OK = "ok"
    WARNING = "warning"
    ERROR = "error"


class HealthIssueKind(str, enum.Enum):
    """Stable identifiers for each individual finding.

    Categories:
    - error (storage unusable or governance broken):
        missing_storage_root, unwritable_storage, missing_directory,
        missing_ledger, malformed_ledger, ledger_origin_mismatch,
        forward_incompat_ledger, ledger_schema_drift
    - warning (storage usable but worth surfacing):
        legacy_ledger_pending_migration, cap_version_mismatch,
        stale_storage, unknown_ledger_field
    """

    MISSING_STORAGE_ROOT = "missing_storage_root"
    UNWRITABLE_STORAGE = "unwritable_storage"
    MISSING_DIRECTORY = "missing_directory"
    MISSING_LEDGER = "missing_ledger"
    MALFORMED_LEDGER = "malformed_ledger"
    LEDGER_ORIGIN_MISMATCH = "ledger_origin_mismatch"
    FORWARD_INCOMPAT_LEDGER = "forward_incompat_ledger"
    LEDGER_SCHEMA_DRIFT = "ledger_schema_drift"
    LEGACY_LEDGER_PENDING_MIGRATION = "legacy_ledger_pending_migration"
    CAP_VERSION_MISMATCH = "cap_version_mismatch"
    STALE_STORAGE = "stale_storage"
    UNKNOWN_LEDGER_FIELD = "unknown_ledger_field"


# Severity per kind. Anything not in this map defaults to ERROR.
_SEVERITY: dict[HealthIssueKind, HealthStatus] = {
    HealthIssueKind.MISSING_STORAGE_ROOT: HealthStatus.ERROR,
    HealthIssueKind.UNWRITABLE_STORAGE: HealthStatus.ERROR,
    HealthIssueKind.MISSING_DIRECTORY: HealthStatus.ERROR,
    HealthIssueKind.MISSING_LEDGER: HealthStatus.ERROR,
    HealthIssueKind.MALFORMED_LEDGER: HealthStatus.ERROR,
    HealthIssueKind.LEDGER_ORIGIN_MISMATCH: HealthStatus.ERROR,
    HealthIssueKind.FORWARD_INCOMPAT_LEDGER: HealthStatus.ERROR,
    HealthIssueKind.LEDGER_SCHEMA_DRIFT: HealthStatus.ERROR,
    HealthIssueKind.LEGACY_LEDGER_PENDING_MIGRATION: HealthStatus.WARNING,
    HealthIssueKind.CAP_VERSION_MISMATCH: HealthStatus.WARNING,
    HealthIssueKind.STALE_STORAGE: HealthStatus.WARNING,
    HealthIssueKind.UNKNOWN_LEDGER_FIELD: HealthStatus.WARNING,
}


# Schema-class kinds map to exit 41 (matches producer policy in
# policies/workflow-executor-exit-codes.md identity / schema-class section).
_SCHEMA_CLASS_KINDS = frozenset({
    HealthIssueKind.MALFORMED_LEDGER,
    HealthIssueKind.FORWARD_INCOMPAT_LEDGER,
    HealthIssueKind.LEDGER_SCHEMA_DRIFT,
})

# Collision-class maps to exit 53 (matches producer policy).
_COLLISION_KINDS = frozenset({
    HealthIssueKind.LEDGER_ORIGIN_MISMATCH,
})


@dataclass
class HealthIssue:
    kind: HealthIssueKind
    severity: HealthStatus
    message: str
    detail: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "kind": self.kind.value,
            "severity": self.severity.value,
            "message": self.message,
            "detail": self.detail,
        }


@dataclass
class StorageHealthReport:
    project_id: str
    project_root: str
    project_store: str
    ledger_path: str
    cap_home: str
    manifest_cap_version: str | None
    overall_status: HealthStatus
    issues: list[HealthIssue]
    summary: dict[str, int]

    def to_dict(self) -> dict[str, Any]:
        return {
            "project_id": self.project_id,
            "project_root": self.project_root,
            "project_store": self.project_store,
            "ledger_path": self.ledger_path,
            "cap_home": self.cap_home,
            "manifest_cap_version": self.manifest_cap_version,
            "overall_status": self.overall_status.value,
            "issues": [i.to_dict() for i in self.issues],
            "summary": self.summary,
        }

    def to_json(self, *, indent: int = 2) -> str:
        return json.dumps(self.to_dict(), indent=indent, ensure_ascii=False)

    def to_yaml(self) -> str:
        return yaml.safe_dump(self.to_dict(), sort_keys=False, allow_unicode=True)

    def exit_code(self) -> int:
        """Map the most severe issue class to a stable exit code.

        Precedence (most severe first):
            41 — schema-class issues
            53 — collision
             1 — other errors
             0 — only warnings or no issues
        """
        kinds = {issue.kind for issue in self.issues}
        if kinds & _SCHEMA_CLASS_KINDS:
            return 41
        if kinds & _COLLISION_KINDS:
            return 53
        if any(_SEVERITY.get(k, HealthStatus.ERROR) is HealthStatus.ERROR for k in kinds):
            return 1
        return 0


class StorageHealthChecker:
    """Inspect ``~/.cap/projects/<project_id>/`` and produce a report.

    Read-only by contract. ``last_resolved_at`` and other ledger fields
    are never modified — that would erase the diagnostic signal this
    module exists to interpret.
    """

    def __init__(
        self,
        project_id: str,
        project_root: Path,
        project_store: Path,
        cap_home: Path,
        manifest_cap_version: str | None,
        *,
        stale_days: int = _STALE_DAYS_DEFAULT,
        now: datetime.datetime | None = None,
    ):
        self.project_id = project_id
        self.project_root = project_root
        self.project_store = project_store
        self.cap_home = cap_home
        self.manifest_cap_version = manifest_cap_version
        self.stale_days = stale_days
        # Use a tz-aware UTC clock then drop tzinfo so arithmetic stays
        # naive, matching the producer's ``utcnow()``-style ISO strings
        # (see cap-paths.sh / project_context_loader.py).
        self._now = now or datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
        self._issues: list[HealthIssue] = []

    def check(self) -> StorageHealthReport:
        ledger_path = self.project_store / ".identity.json"

        if self._check_storage_root_present():
            self._check_storage_writable()
            self._check_required_subdirs()
            self._check_ledger(ledger_path)

        return self._build_report(ledger_path)

    # ── individual checks ───────────────────────────────────────────────

    def _check_storage_root_present(self) -> bool:
        if not self.project_store.exists():
            self._add(
                HealthIssueKind.MISSING_STORAGE_ROOT,
                f"project storage directory does not exist: {self.project_store}",
                {"project_store": str(self.project_store)},
            )
            return False
        if not self.project_store.is_dir():
            self._add(
                HealthIssueKind.MISSING_STORAGE_ROOT,
                f"project storage path exists but is not a directory: {self.project_store}",
                {"project_store": str(self.project_store)},
            )
            return False
        return True

    def _check_storage_writable(self) -> None:
        # os.access is best-effort but matches the producer's semantics
        # (cap-paths uses mkdir / printf which depend on plain POSIX
        # write perms on the directory entry).
        if not os.access(self.project_store, os.W_OK):
            self._add(
                HealthIssueKind.UNWRITABLE_STORAGE,
                f"project storage is not writable: {self.project_store}",
                {"project_store": str(self.project_store)},
            )

    def _check_required_subdirs(self) -> None:
        missing: list[str] = []
        for rel in _REQUIRED_SUBDIRS:
            target = self.project_store / rel
            if not target.is_dir():
                missing.append(rel)
        if missing:
            self._add(
                HealthIssueKind.MISSING_DIRECTORY,
                f"project storage is missing {len(missing)} required subdirectory(ies)",
                {"missing": missing},
            )

    def _check_ledger(self, ledger_path: Path) -> None:
        if not ledger_path.exists():
            self._add(
                HealthIssueKind.MISSING_LEDGER,
                f"identity ledger missing — run `cap-paths.sh ensure` to initialise: {ledger_path}",
                {"ledger_path": str(ledger_path)},
            )
            return

        try:
            data = json.loads(ledger_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            self._add(
                HealthIssueKind.MALFORMED_LEDGER,
                f"identity ledger is not valid JSON: {exc}",
                {"ledger_path": str(ledger_path), "error": str(exc)},
            )
            return

        if not isinstance(data, dict):
            self._add(
                HealthIssueKind.MALFORMED_LEDGER,
                "identity ledger root must be a JSON object",
                {"ledger_path": str(ledger_path), "got_type": type(data).__name__},
            )
            return

        # Schema-version checks (forward-incompat first; legacy is a warning).
        sv = data.get("schema_version")
        if isinstance(sv, int) and sv > _LEDGER_SCHEMA_VERSION:
            self._add(
                HealthIssueKind.FORWARD_INCOMPAT_LEDGER,
                f"identity ledger schema_version={sv} exceeds supported maximum "
                f"(this build supports <= {_LEDGER_SCHEMA_VERSION})",
                {
                    "ledger_schema_version": sv,
                    "supported_max": _LEDGER_SCHEMA_VERSION,
                },
            )
            # Continue with structural checks anyway — we still want to surface
            # other problems, but origin/required-field validation against the
            # current schema is unreliable. Skip the rest.
            return

        if isinstance(sv, int) and sv < _LEDGER_SCHEMA_VERSION:
            self._add(
                HealthIssueKind.LEGACY_LEDGER_PENDING_MIGRATION,
                f"identity ledger is at schema_version={sv}; "
                f"`cap-paths.sh ensure` will auto-migrate to v{_LEDGER_SCHEMA_VERSION}",
                {
                    "ledger_schema_version": sv,
                    "target_version": _LEDGER_SCHEMA_VERSION,
                },
            )
            # Don't validate v2 required fields against a v1 ledger.
            self._check_origin(data, ledger_path)
            self._check_cap_version(data)
            return

        if sv != _LEDGER_SCHEMA_VERSION:
            self._add(
                HealthIssueKind.LEDGER_SCHEMA_DRIFT,
                f"identity ledger has invalid schema_version (expected integer, got {sv!r})",
                {"got": sv},
            )

        # Required field presence & type guards (light-weight; full
        # JSON-Schema validation lives in schemas/identity-ledger.schema.yaml
        # and the dedicated test-identity-ledger-schema.sh test).
        missing_required = [f for f in _LEDGER_REQUIRED_FIELDS if f not in data]
        if missing_required:
            self._add(
                HealthIssueKind.LEDGER_SCHEMA_DRIFT,
                f"identity ledger missing required field(s): {', '.join(missing_required)}",
                {"missing": missing_required},
            )

        resolved_mode = data.get("resolved_mode")
        if resolved_mode is not None and resolved_mode not in _LEDGER_RESOLVED_MODES:
            self._add(
                HealthIssueKind.LEDGER_SCHEMA_DRIFT,
                f"identity ledger resolved_mode={resolved_mode!r} not in allowed enum",
                {"got": resolved_mode, "allowed": list(_LEDGER_RESOLVED_MODES)},
            )

        unknown = sorted(set(data.keys()) - _LEDGER_KNOWN_FIELDS)
        if unknown:
            self._add(
                HealthIssueKind.UNKNOWN_LEDGER_FIELD,
                f"identity ledger has {len(unknown)} unknown field(s); "
                "ignored by current schema but surface for review",
                {"unknown_fields": unknown},
            )

        self._check_origin(data, ledger_path)
        self._check_cap_version(data)
        self._check_staleness(data)

    def _check_origin(self, data: dict, ledger_path: Path) -> None:
        ledger_origin = data.get("origin_path")
        if not isinstance(ledger_origin, str) or not ledger_origin:
            return
        current_origin = str(self.project_root)
        if ledger_origin != current_origin:
            self._add(
                HealthIssueKind.LEDGER_ORIGIN_MISMATCH,
                "identity ledger origin_path does not match current project_root "
                "— project_id collision suspected",
                {
                    "ledger_origin": ledger_origin,
                    "current_origin": current_origin,
                    "ledger_path": str(ledger_path),
                },
            )

    def _check_cap_version(self, data: dict) -> None:
        ledger_cap_version = data.get("cap_version")
        # Only compare when both sides are non-empty — the manifest may
        # be absent in consumer repos (legitimate null per policy §2).
        if not self.manifest_cap_version or not ledger_cap_version:
            return
        if ledger_cap_version != self.manifest_cap_version:
            self._add(
                HealthIssueKind.CAP_VERSION_MISMATCH,
                "identity ledger cap_version drift from repo.manifest.yaml",
                {
                    "ledger_cap_version": ledger_cap_version,
                    "manifest_cap_version": self.manifest_cap_version,
                },
            )

    def _check_staleness(self, data: dict) -> None:
        last_resolved = data.get("last_resolved_at")
        if not isinstance(last_resolved, str) or not last_resolved:
            return
        try:
            # Accept the trailing-Z UTC form that cap-paths writes.
            normalized = last_resolved.rstrip("Z")
            stamp = datetime.datetime.fromisoformat(normalized)
        except ValueError:
            self._add(
                HealthIssueKind.LEDGER_SCHEMA_DRIFT,
                f"identity ledger last_resolved_at is not ISO-8601: {last_resolved!r}",
                {"got": last_resolved},
            )
            return
        delta = self._now - stamp
        if delta.days >= self.stale_days:
            self._add(
                HealthIssueKind.STALE_STORAGE,
                f"identity ledger last_resolved_at is {delta.days} days old "
                f"(threshold: {self.stale_days})",
                {
                    "last_resolved_at": last_resolved,
                    "age_days": delta.days,
                    "threshold_days": self.stale_days,
                },
            )

    # ── helpers ────────────────────────────────────────────────────────

    def _add(self, kind: HealthIssueKind, message: str, detail: dict[str, Any]) -> None:
        severity = _SEVERITY.get(kind, HealthStatus.ERROR)
        self._issues.append(HealthIssue(kind=kind, severity=severity, message=message, detail=detail))

    def _build_report(self, ledger_path: Path) -> StorageHealthReport:
        if any(i.severity is HealthStatus.ERROR for i in self._issues):
            overall = HealthStatus.ERROR
        elif any(i.severity is HealthStatus.WARNING for i in self._issues):
            overall = HealthStatus.WARNING
        else:
            overall = HealthStatus.OK

        summary = {
            "errors": sum(1 for i in self._issues if i.severity is HealthStatus.ERROR),
            "warnings": sum(1 for i in self._issues if i.severity is HealthStatus.WARNING),
            "total": len(self._issues),
        }

        return StorageHealthReport(
            project_id=self.project_id,
            project_root=str(self.project_root),
            project_store=str(self.project_store),
            ledger_path=str(ledger_path),
            cap_home=str(self.cap_home),
            manifest_cap_version=self.manifest_cap_version,
            overall_status=overall,
            issues=list(self._issues),
            summary=summary,
        )


# ─────────────────────────────────────────────────────────
# Top-level convenience wrapper
# ─────────────────────────────────────────────────────────


def run_health_check(
    project_root: Path,
    *,
    cap_home: Path | None = None,
    project_id_override: str | None = None,
    stale_days: int = _STALE_DAYS_DEFAULT,
    now: datetime.datetime | None = None,
) -> StorageHealthReport:
    """End-to-end health check entry point.

    The producer SSOT for project_id resolution is
    ``engine/project_context_loader.py``; we import it here rather than
    duplicating the chain so any resolver change auto-propagates. We
    explicitly do **not** call ``ProjectContextLoader._verify_or_write_ledger``
    because that is a write path; we only need ``_resolve_project_id``.
    """
    # Local import — both ``import engine.X`` (when run as a package) and
    # ``import X`` (when run as a script with this directory on sys.path)
    # need to work, so try both.
    try:
        from engine.project_context_loader import (  # type: ignore[import-not-found]
            ProjectContextLoader,
            ProjectIdResolutionError,
        )
    except ModuleNotFoundError:
        from project_context_loader import (  # type: ignore[no-redef]
            ProjectContextLoader,
            ProjectIdResolutionError,
        )

    if project_id_override:
        project_id = project_id_override
    else:
        loader = ProjectContextLoader(base_dir=project_root)
        cfg_path = loader.base_dir / loader.DEFAULT_PROJECT_CONFIG
        cfg = loader._load_yaml(cfg_path)  # noqa: SLF001 — intentional reuse
        try:
            project_id, _ = loader._resolve_project_id(cfg)  # noqa: SLF001
        except ProjectIdResolutionError as exc:
            # Surface as a structured report rather than re-raising;
            # health-check callers want a verdict, not an exception.
            stub = StorageHealthChecker(
                project_id="<unresolved>",
                project_root=project_root,
                project_store=Path("<unresolved>"),
                cap_home=cap_home or Path(os.getenv("CAP_HOME") or (Path.home() / ".cap")),
                manifest_cap_version=None,
                stale_days=stale_days,
                now=now,
            )
            stub._add(  # noqa: SLF001
                HealthIssueKind.MISSING_STORAGE_ROOT,
                f"project_id unresolvable: {exc}",
                {"reason": str(exc)},
            )
            return stub._build_report(Path("<unresolved>"))  # noqa: SLF001

    cap_home_resolved = cap_home or Path(os.getenv("CAP_HOME") or (Path.home() / ".cap"))
    project_store = cap_home_resolved / "projects" / project_id

    manifest_cap_version: str | None = None
    manifest_path = project_root / "repo.manifest.yaml"
    if manifest_path.is_file():
        try:
            manifest = yaml.safe_load(manifest_path.read_text(encoding="utf-8")) or {}
        except yaml.YAMLError:
            manifest = {}
        candidate = manifest.get("cap_version") if isinstance(manifest, dict) else None
        if isinstance(candidate, str) and candidate.strip():
            manifest_cap_version = candidate.strip()

    checker = StorageHealthChecker(
        project_id=project_id,
        project_root=project_root,
        project_store=project_store,
        cap_home=cap_home_resolved,
        manifest_cap_version=manifest_cap_version,
        stale_days=stale_days,
        now=now,
    )
    return checker.check()


# ─────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="storage_health",
        description="CAP project storage health check (P1 #4 diagnostic core).",
    )
    parser.add_argument(
        "--project-root",
        type=Path,
        default=Path.cwd(),
        help="Repo root to inspect (default: current working directory).",
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
        default=_STALE_DAYS_DEFAULT,
        help=f"Staleness threshold in days (default: {_STALE_DAYS_DEFAULT}).",
    )
    parser.add_argument(
        "--format",
        choices=("json", "yaml", "text"),
        default="text",
        help="Output format (default: text).",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit non-zero on errors (default already non-zero on errors; set "
        "this flag to also halt on warnings).",
    )
    return parser


def _format_text(report: StorageHealthReport) -> str:
    lines = [
        f"project_id={report.project_id}",
        f"project_root={report.project_root}",
        f"project_store={report.project_store}",
        f"ledger_path={report.ledger_path}",
        f"manifest_cap_version={report.manifest_cap_version or '<none>'}",
        f"overall_status={report.overall_status.value}",
        f"summary={report.summary}",
    ]
    if not report.issues:
        lines.append("issues: <none>")
    else:
        lines.append("issues:")
        for issue in report.issues:
            lines.append(f"  - [{issue.severity.value}] {issue.kind.value}: {issue.message}")
            for k, v in issue.detail.items():
                lines.append(f"      {k}: {v}")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    report = run_health_check(
        project_root=args.project_root.resolve(),
        cap_home=args.cap_home.resolve() if args.cap_home else None,
        project_id_override=args.project_id,
        stale_days=args.stale_days,
    )

    if args.format == "json":
        sys.stdout.write(report.to_json() + "\n")
    elif args.format == "yaml":
        sys.stdout.write(report.to_yaml())
    else:
        sys.stdout.write(_format_text(report))

    code = report.exit_code()
    if code == 0 and args.strict and report.summary.get("warnings", 0) > 0:
        return 1
    return code


if __name__ == "__main__":
    sys.exit(main())
