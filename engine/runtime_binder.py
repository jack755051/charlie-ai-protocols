from __future__ import annotations

import json
from pathlib import Path

import yaml

try:
    from .workflow_loader import WorkflowLoader
except ImportError:  # pragma: no cover
    from workflow_loader import WorkflowLoader


class RuntimeBinder:
    """Draft binder: semantic plan -> skill binding report."""

    DEFAULT_REGISTRY_PATH = ".cap.skills.yaml"
    DEFAULT_BINDING_MODE = "strict"
    DEFAULT_MISSING_POLICY = "halt"
    GENERIC_FALLBACK_PREFIX = "generic-"

    def __init__(self, base_dir: Path | None = None):
        self.base_dir = Path(base_dir) if base_dir else Path(__file__).resolve().parents[1]
        self.loader = WorkflowLoader(self.base_dir)

    def load_skill_registry(self, registry_ref: str | None = None) -> dict:
        registry_path = Path(registry_ref) if registry_ref else self.base_dir / self.DEFAULT_REGISTRY_PATH
        if not registry_path.is_absolute():
            registry_path = self.base_dir / registry_path

        if not registry_path.exists():
            return {
                "schema_version": 1,
                "default_provider": "builtin",
                "binding_defaults": {
                    "binding_mode": self.DEFAULT_BINDING_MODE,
                    "missing_policy": self.DEFAULT_MISSING_POLICY,
                },
                "skills": [],
                "_source_path": str(registry_path),
                "_missing": True,
            }

        raw = registry_path.read_text(encoding="utf-8")
        if registry_path.suffix == ".json":
            data = json.loads(raw)
        else:
            data = yaml.safe_load(raw)

        data["_source_path"] = str(registry_path)
        data["_missing"] = False
        return data

    def bind_capabilities(self, workflow_ref: str, registry_ref: str | None = None) -> dict:
        semantic_plan = self.loader.build_semantic_plan(workflow_ref)
        registry = self.load_skill_registry(registry_ref)
        defaults = registry.get("binding_defaults", {})

        step_reports: list[dict] = []
        resolved_steps = 0
        fallback_steps = 0
        unresolved_required_steps = 0
        unresolved_optional_steps = 0

        for step in semantic_plan["steps"]:
            capability = step["capability"]
            optional = step["optional"]
            binding_mode = self._get_binding_mode(step, defaults)
            missing_policy = self._get_missing_policy(step, defaults)
            candidates = self._find_candidates(registry, capability, semantic_plan["version"])

            selected = candidates[0] if candidates else None
            fallback = self._find_fallback(registry, capability) if binding_mode == "fallback_allowed" else None

            if selected:
                resolution_status = "resolved"
                reason = "found compatible skill"
                resolved_steps += 1
                selected_skill_id = selected["skill_id"]
                selected_provider = selected.get("provider")
            elif fallback:
                resolution_status = "fallback_available"
                reason = "no direct skill; generic fallback available"
                fallback_steps += 1
                selected_skill_id = fallback["skill_id"]
                selected_provider = fallback.get("provider")
            else:
                if optional:
                    resolution_status = "optional_unresolved"
                    unresolved_optional_steps += 1
                else:
                    resolution_status = "required_unresolved"
                    unresolved_required_steps += 1
                reason = "no compatible skill found in registry"
                selected_skill_id = None
                selected_provider = None

            step_reports.append(
                {
                    "step_id": step["step_id"],
                    "phase": step["phase"],
                    "capability": capability,
                    "optional": optional,
                    "resolution_status": resolution_status,
                    "selected_skill_id": selected_skill_id,
                    "selected_provider": selected_provider,
                    "binding_mode": binding_mode,
                    "missing_policy": missing_policy,
                    "reason": reason,
                    "candidate_skill_ids": [candidate["skill_id"] for candidate in candidates],
                }
            )

        binding_status = self._resolve_binding_status(
            unresolved_required_steps=unresolved_required_steps,
            fallback_steps=fallback_steps,
            unresolved_optional_steps=unresolved_optional_steps,
        )

        return {
            "workflow_id": semantic_plan["workflow_id"],
            "workflow_version": semantic_plan["version"],
            "binding_status": binding_status,
            "registry_source_path": registry.get("_source_path"),
            "registry_missing": registry.get("_missing", False),
            "contract_missing_steps": semantic_plan["contract_missing_steps"],
            "summary": {
                "total_steps": len(semantic_plan["steps"]),
                "resolved_steps": resolved_steps,
                "fallback_steps": fallback_steps,
                "unresolved_required_steps": unresolved_required_steps,
                "unresolved_optional_steps": unresolved_optional_steps,
            },
            "steps": step_reports,
        }

    @staticmethod
    def _get_binding_mode(step: dict, defaults: dict) -> str:
        capability_contract = step.get("capability_contract") or {}
        return capability_contract.get(
            "binding_mode",
            defaults.get("binding_mode", RuntimeBinder.DEFAULT_BINDING_MODE),
        )

    @staticmethod
    def _get_missing_policy(step: dict, defaults: dict) -> str:
        capability_contract = step.get("capability_contract") or {}
        return capability_contract.get(
            "missing_policy",
            defaults.get("missing_policy", RuntimeBinder.DEFAULT_MISSING_POLICY),
        )

    @staticmethod
    def _resolve_binding_status(
        *,
        unresolved_required_steps: int,
        fallback_steps: int,
        unresolved_optional_steps: int,
    ) -> str:
        if unresolved_required_steps > 0:
            return "blocked"
        if fallback_steps > 0 or unresolved_optional_steps > 0:
            return "degraded"
        return "ready"

    @staticmethod
    def _find_candidates(registry: dict, capability: str, workflow_version: int) -> list[dict]:
        candidates = []
        for skill in registry.get("skills", []):
            if not skill.get("enabled", True):
                continue
            if capability not in skill.get("provided_capabilities", []):
                continue

            compatible_versions = skill.get("compatible_workflow_versions", [])
            if compatible_versions and workflow_version not in compatible_versions:
                continue

            candidates.append(skill)

        return sorted(candidates, key=lambda item: item.get("priority", 100), reverse=True)

    def _find_fallback(self, registry: dict, capability: str) -> dict | None:
        capability_family = self._infer_fallback_role(capability)
        for skill in registry.get("skills", []):
            if not skill.get("enabled", True):
                continue
            if capability_family in skill.get("fallback_roles", []):
                return skill
            if skill.get("skill_id", "").startswith(self.GENERIC_FALLBACK_PREFIX) and capability_family in skill.get("skill_id", ""):
                return skill
        return None

    @staticmethod
    def _infer_fallback_role(capability: str) -> str:
        if capability.endswith("_audit"):
            return "reviewer"
        if capability.endswith("_testing") or capability.endswith("_specification"):
            return "reviewer"
        if capability in {"technical_logging"}:
            return "logger"
        if capability in {"prd_generation", "workflow_orchestration"}:
            return "supervisor"
        return "implementer"
