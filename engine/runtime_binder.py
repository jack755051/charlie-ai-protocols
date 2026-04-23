from __future__ import annotations

import json
from pathlib import Path

import yaml

try:
    from .workflow_loader import WorkflowLoader
except ImportError:  # pragma: no cover
    from workflow_loader import WorkflowLoader


class RuntimeBinder:
    """Workflow runtime binder: semantic plan -> binding report / bound phases."""

    DEFAULT_REGISTRY_PATH = ".cap.skills.yaml"
    LEGACY_AGENT_REGISTRY_PATH = ".cap.agents.json"
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
            return self._load_legacy_registry_adapter(registry_path)

        raw = registry_path.read_text(encoding="utf-8")
        if registry_path.suffix == ".json":
            data = json.loads(raw)
        else:
            data = yaml.safe_load(raw)

        if "agents" in data and "skills" not in data:
            return self._adapt_legacy_registry(data, registry_path)

        data["_source_path"] = str(registry_path)
        data["_missing"] = False
        data["_adapter_from_legacy"] = False
        return data

    def bind_capabilities(
        self,
        workflow_ref: str,
        registry_ref: str | None = None,
        semantic_plan: dict | None = None,
    ) -> dict:
        semantic_plan = semantic_plan or self.loader.build_semantic_plan(workflow_ref)
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
            capability_contract = step.get("capability_contract") or {}
            preferred_agent_alias = capability_contract.get("default_agent")
            binding_mode = self._get_binding_mode(step, defaults)
            missing_policy = self._get_missing_policy(step, defaults)
            candidates = self._find_candidates(
                registry,
                capability,
                semantic_plan["version"],
                preferred_agent_alias=preferred_agent_alias,
            )

            selected = candidates[0] if candidates else None
            fallback = self._find_fallback(registry, capability) if binding_mode == "fallback_allowed" else None

            if selected and self._has_execution_metadata(selected):
                resolution_status = "resolved"
                reason = "found compatible skill"
                resolved_steps += 1
                selected_skill_id = selected["skill_id"]
                selected_provider = selected.get("provider")
                selected_agent_alias = selected.get("agent_alias")
                selected_prompt_file = selected.get("prompt_file")
                selected_cli = selected.get("cli")
            elif fallback and self._has_execution_metadata(fallback):
                resolution_status = "fallback_available"
                reason = "no direct skill; generic fallback available"
                fallback_steps += 1
                selected_skill_id = fallback["skill_id"]
                selected_provider = fallback.get("provider")
                selected_agent_alias = fallback.get("agent_alias")
                selected_prompt_file = fallback.get("prompt_file")
                selected_cli = fallback.get("cli")
            elif selected or fallback:
                broken = selected or fallback
                resolution_status = "incompatible"
                reason = "skill found but missing execution metadata (agent_alias / prompt_file / cli)"
                if optional:
                    unresolved_optional_steps += 1
                else:
                    unresolved_required_steps += 1
                selected_skill_id = broken.get("skill_id")
                selected_provider = broken.get("provider")
                selected_agent_alias = broken.get("agent_alias")
                selected_prompt_file = broken.get("prompt_file")
                selected_cli = broken.get("cli")
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
                selected_agent_alias = None
                selected_prompt_file = None
                selected_cli = None

            step_reports.append(
                {
                    "step_id": step["step_id"],
                    "phase": step["phase"],
                    "capability": capability,
                    "optional": optional,
                    "resolution_status": resolution_status,
                    "selected_skill_id": selected_skill_id,
                    "selected_provider": selected_provider,
                    "selected_agent_alias": selected_agent_alias,
                    "selected_prompt_file": selected_prompt_file,
                    "selected_cli": selected_cli,
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
            "adapter_from_legacy": registry.get("_adapter_from_legacy", False),
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

    def build_bound_execution_phases(self, workflow_ref: str, registry_ref: str | None = None) -> dict:
        """
        建立綁定後的 phase plan，供 plan / run 共用。

        此方法會以 semantic plan + binding report 為基礎，輸出真正可執行的 step metadata。
        """
        semantic_plan = self.loader.build_semantic_plan(workflow_ref)
        binding = self.bind_capabilities(workflow_ref, registry_ref, semantic_plan=semantic_plan)
        binding_by_step = {step["step_id"]: step for step in binding["steps"]}

        phases: list[dict] = []
        for phase in semantic_plan["phases"]:
            phase_steps: list[dict] = []
            gate = None
            for step in phase["steps"]:
                step_binding = binding_by_step[step["step_id"]]
                bound_step = {
                    "step_id": step["step_id"],
                    "step_name": step["step_name"],
                    "capability": step["capability"],
                    "needs": step["needs"],
                    "inputs": step["inputs"],
                    "outputs": step["outputs"],
                    "optional": step["optional"],
                    "on_fail": step["on_fail"],
                    "parallel_with": step["parallel_with"],
                    "gate": step["gate"],
                    "on_fail_route": step["on_fail_route"],
                    "record_level": step["record_level"],
                    "resolution_status": step_binding["resolution_status"],
                    "skill_id": step_binding["selected_skill_id"],
                    "provider": step_binding["selected_provider"],
                    "agent_alias": step_binding["selected_agent_alias"],
                    "prompt_file": step_binding["selected_prompt_file"],
                    "cli": step_binding["selected_cli"],
                    "binding_mode": step_binding["binding_mode"],
                    "missing_policy": step_binding["missing_policy"],
                }
                phase_steps.append(bound_step)
                if step["gate"]:
                    gate = step["gate"]

            phase_item = {
                "phase": phase["phase"],
                "steps": phase_steps,
            }
            if gate:
                phase_item["gate"] = gate
            phases.append(phase_item)

        standby_steps = []
        route_targets = {
            route["route_to"]
            for step in semantic_plan["steps"]
            for route in step.get("on_fail_route", [])
        }
        for step in semantic_plan["steps"]:
            if step["step_id"] in route_targets and step["optional"] and not step["needs"]:
                step_binding = binding_by_step[step["step_id"]]
                standby_steps.append(
                    {
                        "step_id": step["step_id"],
                        "step_name": step["step_name"],
                        "capability": step["capability"],
                        "optional": step["optional"],
                        "resolution_status": step_binding["resolution_status"],
                        "skill_id": step_binding["selected_skill_id"],
                        "provider": step_binding["selected_provider"],
                        "agent_alias": step_binding["selected_agent_alias"],
                        "prompt_file": step_binding["selected_prompt_file"],
                        "cli": step_binding["selected_cli"],
                    }
                )

        return {
            "workflow_id": semantic_plan["workflow_id"],
            "version": semantic_plan["version"],
            "name": semantic_plan["name"],
            "summary": semantic_plan["summary"],
            "source_path": semantic_plan["source_path"],
            "governance": semantic_plan.get("governance", {}),
            "binding": binding,
            "phases": phases,
            "standby_steps": standby_steps,
        }

    def _load_legacy_registry_adapter(self, missing_registry_path: Path) -> dict:
        legacy_path = self.base_dir / self.LEGACY_AGENT_REGISTRY_PATH
        if not legacy_path.exists():
            return {
                "schema_version": 1,
                "default_provider": "builtin",
                "binding_defaults": {
                    "binding_mode": self.DEFAULT_BINDING_MODE,
                    "missing_policy": self.DEFAULT_MISSING_POLICY,
                },
                "skills": [],
                "_source_path": str(missing_registry_path),
                "_missing": True,
                "_adapter_from_legacy": False,
            }

        data = json.loads(legacy_path.read_text(encoding="utf-8"))
        return self._adapt_legacy_registry(data, legacy_path)

    def _adapt_legacy_registry(self, data: dict, legacy_path: Path) -> dict:
        skills = []
        for alias, meta in data.get("agents", {}).items():
            skills.append(
                {
                    "skill_id": f"legacy-{alias}",
                    "provider": meta.get("provider", data.get("default_provider", "builtin")),
                    "enabled": True,
                    "priority": 100,
                    "compatible_workflow_versions": [1, 2],
                    "provided_capabilities": self._capabilities_for_alias(alias),
                    "fallback_roles": self._fallback_roles_for_alias(alias),
                    "agent_alias": alias,
                    "prompt_file": meta.get("prompt_file"),
                    "cli": meta.get("cli", data.get("default_cli", "codex")),
                }
            )

        return {
            "schema_version": 1,
            "default_provider": data.get("default_provider", "builtin"),
            "binding_defaults": {
                "binding_mode": self.DEFAULT_BINDING_MODE,
                "missing_policy": self.DEFAULT_MISSING_POLICY,
            },
            "skills": skills,
            "_source_path": str(legacy_path),
            "_missing": False,
            "_adapter_from_legacy": True,
        }

    def _capabilities_for_alias(self, alias: str) -> list[str]:
        capabilities = self.loader.load_capabilities()
        resolved = []
        for capability_name, contract in capabilities.items():
            if contract.get("default_agent") == alias or alias in contract.get("allowed_agents", []):
                resolved.append(capability_name)
        return resolved

    @staticmethod
    def _fallback_roles_for_alias(alias: str) -> list[str]:
        mapping = {
            "supervisor": ["supervisor"],
            "logger": ["logger"],
            "watcher": ["reviewer"],
            "security": ["reviewer"],
            "qa": ["reviewer"],
            "techlead": ["reviewer"],
            "ba": ["reviewer"],
            "analytics": ["reviewer"],
            "troubleshoot": ["reviewer"],
            "sre": ["reviewer"],
            "readme": ["implementer"],
            "frontend": ["implementer"],
            "backend": ["implementer"],
            "devops": ["implementer"],
            "ui": ["implementer"],
            "figma": ["implementer"],
            "dba": ["implementer"],
        }
        return mapping.get(alias, ["implementer"])

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
    def _has_execution_metadata(skill: dict) -> bool:
        return all(
            [
                skill.get("agent_alias"),
                skill.get("prompt_file"),
                skill.get("cli"),
            ]
        )

    @staticmethod
    def _find_candidates(
        registry: dict,
        capability: str,
        workflow_version: int,
        preferred_agent_alias: str | None = None,
    ) -> list[dict]:
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

        return sorted(
            candidates,
            key=lambda item: (
                item.get("agent_alias") == preferred_agent_alias,
                item.get("priority", 100),
            ),
            reverse=True,
        )

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
