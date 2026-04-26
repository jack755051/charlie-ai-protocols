from __future__ import annotations

from pathlib import Path

import yaml


class ProjectContextLoader:
    """Load repo-level CAP project config and Project Constitution."""

    DEFAULT_PROJECT_CONFIG = ".cap.project.yaml"
    DEFAULT_PROJECT_CONSTITUTION = ".cap.constitution.yaml"

    def __init__(self, base_dir: Path | None = None):
        self.base_dir = Path(base_dir) if base_dir else Path(__file__).resolve().parents[1]

    def load(self) -> dict:
        project_config_path = self.base_dir / self.DEFAULT_PROJECT_CONFIG
        project_config = self._load_yaml(project_config_path)

        constitution_ref = project_config.get("constitution_file", self.DEFAULT_PROJECT_CONSTITUTION)
        constitution_path = Path(constitution_ref)
        if not constitution_path.is_absolute():
            constitution_path = self.base_dir / constitution_path
        constitution_exists = constitution_path.exists()
        constitution = self._load_yaml(constitution_path)

        return {
            "project_id": project_config.get("project_id", self.base_dir.name),
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
