from __future__ import annotations

import datetime
import json
import os
import re
import subprocess
from pathlib import Path

import yaml


class ProjectIdResolutionError(RuntimeError):
    """Raised when no stable project_id source is available and the legacy
    basename fallback has not been opted in via CAP_ALLOW_BASENAME_FALLBACK."""


class ProjectIdCollisionError(RuntimeError):
    """Raised when an on-disk identity ledger conflicts with the current
    project_root for the resolved project_id."""


class ProjectIdLedgerSchemaError(RuntimeError):
    """Raised when an on-disk identity ledger is at a schema_version greater
    than this engine build supports (forward-incompat halt). See
    ``policies/cap-storage-metadata.md`` §3.2."""


_LEDGER_SCHEMA_VERSION = 2
_SANITIZE_PATTERN = re.compile(r"[^a-z0-9._-]+")
_SANITIZE_TRIM = re.compile(r"^-+|-+$")
_SANITIZE_DEDUP = re.compile(r"-+")


def _sanitize_project_id(raw: str) -> str:
    lowered = raw.strip().lower()
    replaced = _SANITIZE_PATTERN.sub("-", lowered)
    trimmed = _SANITIZE_TRIM.sub("", replaced)
    return _SANITIZE_DEDUP.sub("-", trimmed)


class ProjectContextLoader:
    """Load repo-level CAP project config and Project Constitution.

    Mirrors `scripts/cap-paths.sh` resolution semantics so engine-side
    callers and shell executors agree on project identity:

    1. ``CAP_PROJECT_ID_OVERRIDE`` env var
    2. ``project_id`` from ``.cap.project.yaml``
    3. ``basename(project_root)`` when inside a git repo
    4. Legacy basename fallback when ``CAP_ALLOW_BASENAME_FALLBACK=1``;
       otherwise raise :class:`ProjectIdResolutionError`.

    After resolution the loader inspects the on-disk identity ledger at
    ``~/.cap/projects/<project_id>/.identity.json``; mismatched origin paths
    raise :class:`ProjectIdCollisionError`. Missing ledgers are written so
    subsequent runs are auditable, including the legacy fallback path.
    """

    DEFAULT_PROJECT_CONFIG = ".cap.project.yaml"
    DEFAULT_PROJECT_CONFIG_NAMESPACED = ".cap/project.yaml"
    DEFAULT_PROJECT_CONSTITUTION = ".cap.constitution.yaml"

    def __init__(self, base_dir: Path | None = None):
        self.base_dir = Path(base_dir) if base_dir else Path(__file__).resolve().parents[1]

    def load(self) -> dict:
        # Config namespace migration (v0.22.x batch 1, read-only compat layer):
        # prefer .cap/project.yaml; fall back to legacy .cap.project.yaml.
        # Same contract as scripts/cap-paths.sh:read_project_id_from_config.
        namespaced_path = self.base_dir / self.DEFAULT_PROJECT_CONFIG_NAMESPACED
        legacy_path = self.base_dir / self.DEFAULT_PROJECT_CONFIG
        if namespaced_path.is_file():
            project_config_path = namespaced_path
        else:
            # Always fall through to the legacy path even when missing — the
            # downstream YAML loader handles "missing → empty config" without
            # raising, preserving the bootstrap-friendly behavior callers rely on.
            project_config_path = legacy_path
        project_config = self._load_yaml(project_config_path)
        project_id, project_id_mode = self._resolve_project_id(project_config)
        self._verify_or_write_ledger(project_id, project_id_mode)

        constitution_ref = project_config.get("constitution_file", self.DEFAULT_PROJECT_CONSTITUTION)
        constitution_path = Path(constitution_ref)
        if not constitution_path.is_absolute():
            constitution_path = self.base_dir / constitution_path
        constitution_exists = constitution_path.exists()
        constitution = self._load_yaml(constitution_path)

        return {
            "project_id": project_id,
            "project_id_mode": project_id_mode,
            "project_name": project_config.get("project_name", self.base_dir.name),
            "project_type": project_config.get("project_type", "application"),
            "project_root": str(self.base_dir),
            "project_config_path": str(project_config_path),
            "project_constitution_path": str(constitution_path),
            "skill_registry_path": str(self._resolve_optional_path(project_config.get("skill_registry"))),
            "workflow_dir": str(self._resolve_optional_path(project_config.get("workflow_dir"))),
            "agent_registry_path": str(self._resolve_optional_path(project_config.get("agent_registry"))),
            "project_config": project_config,
            "project_constitution": constitution,
            "_bootstrap": not constitution_exists,
        }

    def build_runtime_summary(self) -> dict:
        context = self.load()
        constitution = context["project_constitution"]
        return {
            "project_id": context["project_id"],
            "project_id_mode": context["project_id_mode"],
            "project_name": context["project_name"],
            "project_type": context["project_type"],
            "project_root": context["project_root"],
            "project_config_path": context["project_config_path"],
            "project_constitution_path": context["project_constitution_path"],
            "skill_registry_path": context["skill_registry_path"],
            "workflow_dir": context["workflow_dir"],
            "agent_registry_path": context["agent_registry_path"],
            "constitution_id": constitution.get("constitution_id"),
            "constitution_name": constitution.get("name"),
            "constitution_summary": constitution.get("summary"),
            "constitution_inherits": constitution.get("inherits", []),
            "multi_repo_rule": ((constitution.get("multi_repo_model") or {}).get("rule")),
            "generation_pipeline": ((constitution.get("generation_pipeline") or {}).get("order", [])),
            "binding_policy": constitution.get("binding_policy", {}),
            "workflow_policy": constitution.get("workflow_policy", {}),
            "_bootstrap": context["_bootstrap"],
        }

    def _resolve_project_id(self, project_config: dict) -> tuple[str, str]:
        override = os.getenv("CAP_PROJECT_ID_OVERRIDE", "").strip()
        if override:
            return _sanitize_project_id(override), "override"

        configured = project_config.get("project_id")
        if isinstance(configured, str) and configured.strip():
            return _sanitize_project_id(configured), "config"

        if self._is_inside_git_repo():
            return _sanitize_project_id(self.base_dir.name), "git_basename"

        if os.getenv("CAP_ALLOW_BASENAME_FALLBACK", "0") == "1":
            return _sanitize_project_id(self.base_dir.name), "basename_legacy"

        raise ProjectIdResolutionError(
            "cannot resolve a stable project_id: "
            f"base_dir={self.base_dir} is not inside a git repository, "
            "no .cap.project.yaml, no CAP_PROJECT_ID_OVERRIDE; "
            "set one of these or export CAP_ALLOW_BASENAME_FALLBACK=1 (legacy)."
        )

    def _is_inside_git_repo(self) -> bool:
        try:
            result = subprocess.run(
                ["git", "-C", str(self.base_dir), "rev-parse", "--is-inside-work-tree"],
                capture_output=True,
                check=False,
            )
        except FileNotFoundError:
            return False
        return result.returncode == 0

    def _read_cap_version_from_manifest(self) -> str | None:
        """Read repo.manifest.yaml top-level ``cap_version``. SSOT for CAP
        release/version metadata (see ``policies/cap-storage-metadata.md`` §2).
        Never falls back to ``git describe`` or other dynamic state. Returns
        ``None`` when the manifest is absent or the field is missing/empty."""
        manifest_path = self.base_dir / "repo.manifest.yaml"
        manifest = self._load_yaml(manifest_path)
        value = manifest.get("cap_version")
        if isinstance(value, str) and value.strip():
            return value.strip()
        return None

    def _verify_or_write_ledger(self, project_id: str, project_id_mode: str) -> None:
        """Verify, migrate, or first-time-write the identity ledger.

        Mirrors ``scripts/cap-paths.sh:verify_ledger_or_halt`` +
        ``write_or_migrate_ledger``. Forward-incompat ledgers raise
        :class:`ProjectIdLedgerSchemaError`; mismatched origins raise
        :class:`ProjectIdCollisionError`. v1 ledgers are auto-migrated to v2
        on landing here (engine-side first-touch is treated as ensure).
        """
        cap_home = Path(os.getenv("CAP_HOME") or (Path.home() / ".cap"))
        project_store = cap_home / "projects" / project_id
        ledger_file = project_store / ".identity.json"
        current_origin = str(self.base_dir)
        now_iso = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")

        if ledger_file.exists():
            try:
                ledger = json.loads(ledger_file.read_text("utf-8"))
            except (OSError, json.JSONDecodeError):
                ledger = {}

            if isinstance(ledger, dict):
                ledger_sv = ledger.get("schema_version")
                if isinstance(ledger_sv, int) and ledger_sv > _LEDGER_SCHEMA_VERSION:
                    raise ProjectIdLedgerSchemaError(
                        f"identity ledger has unsupported schema_version={ledger_sv} "
                        f"(this engine supports schema_version <= {_LEDGER_SCHEMA_VERSION}); "
                        f"ledger at {ledger_file}; upgrade CAP or remove the storage and re-init."
                    )

                ledger_origin = ledger.get("origin_path")
                if ledger_origin and ledger_origin != current_origin:
                    raise ProjectIdCollisionError(
                        f"project_id collision: project_id={project_id} "
                        f"recorded ledger_origin={ledger_origin} (at {ledger_file}) "
                        f"differs from current_origin={current_origin}; "
                        "set a unique project_id in .cap.project.yaml, export "
                        "CAP_PROJECT_ID_OVERRIDE, or remove the colliding storage."
                    )

                # v1 → v2 migration: preserve immutable fields, append history.
                if isinstance(ledger_sv, int) and ledger_sv < _LEDGER_SCHEMA_VERSION:
                    previous = ledger.get("previous_versions") or []
                    if not isinstance(previous, list):
                        previous = []
                    previous.append({
                        "schema_version": ledger_sv,
                        "migrated_to_at": now_iso,
                    })
                    ledger["schema_version"] = _LEDGER_SCHEMA_VERSION
                    ledger["last_resolved_at"] = now_iso
                    ledger["migrated_at"] = now_iso
                    ledger["previous_versions"] = previous
                    if "cap_version" not in ledger:
                        ledger["cap_version"] = self._read_cap_version_from_manifest()
                    self._persist_ledger(ledger_file, ledger)
            return

        # First-time landing: persist a fresh v2 ledger so subsequent calls
        # (including the legacy fallback path) are auditable.
        try:
            project_store.mkdir(parents=True, exist_ok=True)
        except OSError:
            return

        payload = {
            "schema_version": _LEDGER_SCHEMA_VERSION,
            "project_id": project_id,
            "resolved_mode": project_id_mode,
            "origin_path": current_origin,
            "created_at": now_iso,
            "last_resolved_at": now_iso,
            "migrated_at": None,
            "cap_version": self._read_cap_version_from_manifest(),
            "previous_versions": [],
        }
        self._persist_ledger(ledger_file, payload)

    @staticmethod
    def _persist_ledger(ledger_file: Path, payload: dict) -> None:
        try:
            with ledger_file.open("w", encoding="utf-8") as fh:
                json.dump(payload, fh, indent=2, ensure_ascii=False)
                fh.write("\n")
        except OSError:
            # Best-effort: ledger writes are advisory. Engine still proceeds.
            return

    def _resolve_optional_path(self, raw_path: str | None) -> str | None:
        if not raw_path:
            return None
        path = Path(raw_path)
        if not path.is_absolute():
            path = self.base_dir / path
        return str(path)

    @staticmethod
    def _load_yaml(path: Path) -> dict:
        if not path.exists():
            return {}
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
