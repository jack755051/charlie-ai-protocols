from __future__ import annotations

import json
import os
from pathlib import Path

import yaml

try:
    from .project_context_loader import ProjectContextLoader
    from .workflow_loader import WorkflowLoader
except ImportError:  # pragma: no cover
    from project_context_loader import ProjectContextLoader
    from workflow_loader import WorkflowLoader


class BindingPolicyError(Exception):
    """Raised when a binding report cannot be safely executed.

    Surfaces the soft halt the binding report has carried since P4 #2
    (binding_status enum: ready / degraded / blocked) as a deterministic
    exception, so downstream consumers cannot accidentally advance past
    unresolved required capabilities or constitution-blocked steps. The
    ``stage`` attribute records where the gate fired so callers can
    branch on producer- vs. transform-stage failures uniformly with
    the validator helpers.
    """

    def __init__(self, message: str, *, stage: str, errors: list[str]) -> None:
        super().__init__(message)
        self.stage = stage
        self.errors = list(errors)


class WorkflowSourcePolicyError(Exception):
    """Raised when a workflow's source path is outside the constitution's allowed roots.

    Replaces the bare ``ValueError`` previously raised by
    ``RuntimeBinder._assert_workflow_source_allowed`` so the CLI can
    surface a deterministic JSON error class instead of a raw
    traceback. The actual policy decision (which roots are allowed,
    whether enforcement is on) is unchanged; this is purely an
    error-class promotion plus CLI-level handling.
    """

    def __init__(self, message: str, *, stage: str, errors: list[str]) -> None:
        super().__init__(message)
        self.stage = stage
        self.errors = list(errors)


def ensure_binding_status_executable(
    binding: dict, *, stage: str = "post_bind_policy"
) -> None:
    """Raise ``BindingPolicyError`` when ``binding_status == 'blocked'``.

    A binding is considered non-executable when at least one required
    step has unresolved capability binding (``required_unresolved``,
    ``incompatible``) or is blocked by the project constitution
    (``blocked_by_constitution``). The aggregate status is computed
    by ``RuntimeBinder._resolve_binding_status``; this helper just
    promotes ``"blocked"`` from a label into a halt.
    """
    status = binding.get("binding_status")
    if status != "blocked":
        return
    summary = binding.get("summary") or {}
    blocked_steps = [
        step.get("step_id", "<unknown>")
        for step in (binding.get("steps") or [])
        if step.get("resolution_status")
        in {"required_unresolved", "blocked_by_constitution", "incompatible"}
    ]
    errors = [
        "binding_status='blocked' with "
        f"{summary.get('unresolved_required_steps', 0)} unresolved required step(s)"
    ]
    if blocked_steps:
        errors.append("blocked steps: " + ", ".join(blocked_steps))
    raise BindingPolicyError(
        "binding cannot proceed at stage "
        f"'{stage}': blocked by constitution / unresolved required capabilities",
        stage=stage,
        errors=errors,
    )


class RuntimeBinder:
    """Workflow runtime binder: semantic plan -> binding report / bound phases."""

    # P0c batch 2.5 reader dual-path: prefer .cap/<name> namespace, fall back
    # to legacy .cap.<name> flat-file. Constants below name both forms so
    # _resolve_skill_registry_path / _load_legacy_registry_adapter can apply
    # the same precedence (new wins) without duplicating the logic.
    DEFAULT_REGISTRY_PATH_NAMESPACED = ".cap/skills.yaml"
    DEFAULT_REGISTRY_PATH = ".cap.skills.yaml"
    LEGACY_AGENT_REGISTRY_PATH_NAMESPACED = ".cap/agents.json"
    LEGACY_AGENT_REGISTRY_PATH = ".cap.agents.json"
    # P9 #3 layered skill registry inputs. Each layer can supply skills
    # via either a flat registry file (LAYER_REGISTRY_FILENAMES) or a
    # per-skill dir under LAYER_PER_SKILL_DIR_NAME. Per-skill files may
    # be either a single skill dict (with ``skill_id`` at top level) or
    # a multi-skill envelope (with a ``skills`` list); both shapes are
    # accepted so the user picks whichever fits their layout.
    LAYER_REGISTRY_FILENAMES = ("skills.yaml", "skills.yml", "skills.json")
    LAYER_PER_SKILL_DIR_NAME = "skills"
    DEFAULT_BINDING_MODE = "strict"
    DEFAULT_MISSING_POLICY = "halt"
    GENERIC_FALLBACK_PREFIX = "generic-"
    BOOTSTRAP_WORKFLOW_ID = "project-constitution"
    BOOTSTRAP_ALLOWED_CAPABILITIES = {
        "bootstrap_platform_defaults",
        "constitution_validation",
        "constitution_persistence",
    }

    def __init__(
        self,
        base_dir: Path | None = None,
        *,
        project_root: Path | None = None,
        cap_home: Path | None = None,
    ):
        explicit_base_dir = base_dir is not None
        self.base_dir = Path(base_dir) if base_dir else Path(__file__).resolve().parents[1]

        # P9 #3 — same layer root precedence as WorkflowLoader (P9 #2):
        # explicit kwarg > env (CAP_PROJECT_ROOT / CAP_HOME) > if an
        # explicit base_dir was provided, treat that as the whole
        # universe (project_root / cap_home both default to base_dir
        # so existing test harnesses that only stub base_dir keep
        # observing a single-file world); otherwise fall back to cwd
        # / ~/.cap. Resolved to absolute paths so layer-membership
        # checks (Path.samefile / Path.relative_to) work without
        # surprises on symlink-laden sandboxes.
        if project_root is not None:
            self.project_root = Path(project_root).expanduser().resolve()
        elif os.environ.get("CAP_PROJECT_ROOT"):
            self.project_root = Path(os.environ["CAP_PROJECT_ROOT"]).expanduser().resolve()
        elif explicit_base_dir:
            self.project_root = self.base_dir.resolve()
        else:
            self.project_root = Path.cwd().resolve()

        if cap_home is not None:
            self.cap_home = Path(cap_home).expanduser().resolve()
        elif os.environ.get("CAP_HOME"):
            self.cap_home = Path(os.environ["CAP_HOME"]).expanduser().resolve()
        elif explicit_base_dir:
            self.cap_home = self.base_dir.resolve()
        else:
            self.cap_home = (Path.home() / ".cap").resolve()

        # WorkflowLoader (P9 #2) shares the same layer roots so a
        # binding pipeline driven by RuntimeBinder gets coherent
        # workflow + skill resolution.
        self.loader = WorkflowLoader(
            self.base_dir,
            project_root=self.project_root,
            cap_home=self.cap_home,
        )
        self.project_context_loader = ProjectContextLoader(self.base_dir)

    def load_skill_registry(self, registry_ref: str | None = None) -> dict:
        """Load the skill registry.

        Two paths:

        * **Explicit ``registry_ref``** — single-file load, no merge.
          Behaviour preserved for callers that point at a specific
          file (e.g., test harnesses, ad-hoc audits).
        * **No ref (default)** — P9 #3 layered merge. Loads
          ``builtin`` (``<base_dir>/.cap/skills.yaml`` with legacy
          ``.cap.skills.yaml`` fallback), ``shared``
          (``<cap_home>/shared/skills.yaml`` plus per-skill
          ``shared/skills/*.{yaml,yml,json}``), and ``project``
          (``<project_root>/.cap/skills.yaml`` plus per-skill
          ``.cap/skills/*.{yaml,yml,json}``); merges the three with
          priority ``project > shared > builtin``.

        ``project_root == base_dir`` (cap-protocols itself) collapses
        the project layer into builtin to avoid double-loading the
        same physical file (memo §3, ``Path.samefile`` rule).

        When all three layers come up empty, falls through to the
        existing legacy-agent-registry adapter so behaviour is
        identical to pre-P9 #3 for projects that never adopted the
        ``.cap/skills.yaml`` shape.
        """
        if registry_ref:
            registry_path = Path(registry_ref)
            if not registry_path.is_absolute():
                registry_path = self.base_dir / registry_path
            return self._load_single_registry(registry_path)

        return self._load_layered_skill_registry()

    def _load_single_registry(self, registry_path: Path) -> dict:
        """Single-file registry load (preserves the pre-P9 #3 behaviour).

        Used by the explicit ``registry_ref`` path so callers that
        point at one file get the same contract they always had —
        no merge, no source tagging beyond ``_source_path``.
        """
        if not registry_path.exists():
            return self._load_legacy_registry_adapter(registry_path)

        raw = registry_path.read_text(encoding="utf-8")
        if registry_path.suffix == ".json":
            data = json.loads(raw)
        else:
            data = yaml.safe_load(raw)

        if isinstance(data, dict) and "agents" in data and "skills" not in data:
            return self._adapt_legacy_registry(data, registry_path)

        if not isinstance(data, dict):
            data = {}

        data["_source_path"] = str(registry_path)
        data["_missing"] = False
        data["_adapter_from_legacy"] = False
        return data

    def _load_layered_skill_registry(self) -> dict:
        """Load and merge the three layers (project / shared / builtin).

        Per memo §5: skills merged by ``skill_id`` with first-seen
        winning; ``binding_defaults`` deep-merged with project keys
        winning; ``default_provider`` / ``schema_version`` taken from
        the highest-priority layer that emits them.
        """
        builtin_dir = self.base_dir / ".cap"
        shared_dir = self.cap_home / "shared"
        project_dir = self.project_root / ".cap"

        # Self-mode detection: when project_root == base_dir, the
        # project layer's <project_root>/.cap/skills.yaml IS the
        # same physical file as builtin's <base_dir>/.cap/skills.yaml.
        # Skip the project layer to avoid double-loading the same
        # registry (per memo §3 Path.samefile rule). samefile raises
        # if either path doesn't exist; treat raise as "not same".
        project_is_builtin = False
        try:
            if project_dir.exists() and builtin_dir.exists():
                project_is_builtin = project_dir.samefile(builtin_dir)
        except OSError:
            project_is_builtin = False

        builtin_layer = self._resolve_layer_registry("builtin", builtin_dir)
        shared_layer = self._resolve_layer_registry("shared", shared_dir)
        project_layer = (
            None
            if project_is_builtin
            else self._resolve_layer_registry("project", project_dir)
        )

        layers_in_priority = [
            layer for layer in (project_layer, shared_layer, builtin_layer)
            if layer is not None
        ]

        # All three layers empty → preserve the legacy fallback adapter
        # path (covers projects without any .cap/skills.yaml form).
        if not layers_in_priority:
            return self._load_legacy_registry_adapter(
                self.base_dir / self.DEFAULT_REGISTRY_PATH_NAMESPACED
            )

        return self._merge_skill_layers(layers_in_priority)

    def _resolve_layer_registry(self, layer_name: str, layer_dir: Path) -> dict | None:
        """Read one layer's skill data. Returns ``None`` when nothing found.

        Each layer can supply skills via either form:

        * Flat registry file at ``<layer_dir>/skills.{yaml,yml,json}``.
          Standard envelope with ``skills[]`` / ``binding_defaults`` /
          ``default_provider`` / ``schema_version``. Legacy
          ``agents.json``-shaped files are auto-adapted.
        * Per-skill directory at ``<layer_dir>/skills/`` containing
          ``*.{yaml,yml,json}``. Each file is either a single skill
          dict (top-level ``skill_id``) or a multi-skill envelope.

        For the ``builtin`` layer specifically, also consults the
        legacy flat file at ``<base_dir>/.cap.skills.yaml`` when
        nothing is found under ``.cap/`` so projects that never
        migrated to the namespaced layout keep working.

        Each accumulated skill is tagged with ``_source_layer`` and
        ``_source_path`` so the merge can record provenance.
        """
        flat_file: Path | None = None
        if layer_dir.is_dir():
            for filename in self.LAYER_REGISTRY_FILENAMES:
                candidate = layer_dir / filename
                if candidate.is_file():
                    flat_file = candidate
                    break

        per_skill_files: list[Path] = []
        per_skill_dir = layer_dir / self.LAYER_PER_SKILL_DIR_NAME
        if per_skill_dir.is_dir():
            for path in sorted(per_skill_dir.iterdir()):
                if path.is_file() and path.suffix in {".yaml", ".yml", ".json"}:
                    per_skill_files.append(path)

        # builtin-only legacy fallback at base_dir/.cap.skills.yaml.
        if (
            layer_name == "builtin"
            and flat_file is None
            and not per_skill_files
        ):
            legacy_flat = self.base_dir / self.DEFAULT_REGISTRY_PATH
            if legacy_flat.is_file():
                flat_file = legacy_flat

        if flat_file is None and not per_skill_files:
            return None

        skills_acc: list[dict] = []
        binding_defaults: dict = {}
        default_provider: str | None = None
        schema_version: int | None = None
        source_paths: list[str] = []

        if flat_file is not None:
            data = self._read_yaml_or_json(flat_file)
            if isinstance(data, dict):
                source_paths.append(str(flat_file))
                if "agents" in data and "skills" not in data:
                    data = self._adapt_legacy_registry(data, flat_file)
                schema_version = data.get("schema_version", schema_version)
                default_provider = data.get("default_provider", default_provider)
                binding_defaults = dict(data.get("binding_defaults", {}) or {})
                for skill in data.get("skills", []) or []:
                    if isinstance(skill, dict):
                        sk = dict(skill)
                        sk["_source_layer"] = layer_name
                        sk["_source_path"] = str(flat_file)
                        skills_acc.append(sk)

        for path in per_skill_files:
            data = self._read_yaml_or_json(path)
            if not isinstance(data, dict):
                continue
            source_paths.append(str(path))
            if "skill_id" in data and "skills" not in data:
                # Single-skill file shape.
                sk = dict(data)
                sk["_source_layer"] = layer_name
                sk["_source_path"] = str(path)
                skills_acc.append(sk)
            else:
                # Multi-skill envelope shape; pull skills[] only — flat
                # file already owns binding_defaults / default_provider
                # / schema_version aggregation.
                for skill in data.get("skills", []) or []:
                    if isinstance(skill, dict):
                        sk = dict(skill)
                        sk["_source_layer"] = layer_name
                        sk["_source_path"] = str(path)
                        skills_acc.append(sk)

        if not skills_acc and not source_paths:
            return None

        return {
            "layer": layer_name,
            "source_paths": source_paths,
            "skills": skills_acc,
            "binding_defaults": binding_defaults,
            "default_provider": default_provider,
            "schema_version": schema_version,
        }

    def _merge_skill_layers(self, layers: list[dict]) -> dict:
        """Merge layers in priority order (highest first).

        * ``skills``: dedupe by ``skill_id``; first-seen wins. Skills
          retain their per-entry ``_source_layer`` / ``_source_path``
          tags so a future binding-report consumer (P9 #4) can trace
          provenance.
        * ``binding_defaults``: deep merge; project keys beat shared
          beat builtin at every nesting level.
        * ``default_provider`` / ``schema_version``: first-seen non-None.
        """
        merged_skills_by_id: dict[str, dict] = {}
        skills_in_order: list[dict] = []
        merged_defaults: dict = {}
        default_provider: str | None = None
        schema_version: int | None = None
        source_paths: list[str] = []

        for layer in layers:
            for skill in layer["skills"]:
                sid = skill.get("skill_id")
                if not sid or sid in merged_skills_by_id:
                    continue
                merged_skills_by_id[sid] = skill
                skills_in_order.append(skill)
            merged_defaults = self._deep_merge(merged_defaults, layer["binding_defaults"])
            if default_provider is None and layer.get("default_provider"):
                default_provider = layer["default_provider"]
            if schema_version is None and layer.get("schema_version") is not None:
                schema_version = layer["schema_version"]
            source_paths.extend(layer["source_paths"])

        if not merged_defaults:
            merged_defaults = {
                "binding_mode": self.DEFAULT_BINDING_MODE,
                "missing_policy": self.DEFAULT_MISSING_POLICY,
            }

        return {
            "schema_version": schema_version if schema_version is not None else 1,
            "default_provider": default_provider or "builtin",
            "binding_defaults": merged_defaults,
            "skills": skills_in_order,
            "_source_path": source_paths[0] if source_paths else "",
            "_source_paths": source_paths,
            "_missing": False,
            "_adapter_from_legacy": False,
        }

    @staticmethod
    def _read_yaml_or_json(path: Path):
        raw = path.read_text(encoding="utf-8")
        try:
            if path.suffix == ".json":
                return json.loads(raw)
            return yaml.safe_load(raw)
        except (json.JSONDecodeError, yaml.YAMLError):
            return None

    @staticmethod
    def _deep_merge(higher: dict, lower: dict) -> dict:
        """Recursive dict merge. Keys from ``higher`` win at every level.

        Non-dict values from ``higher`` always replace ``lower``'s
        value at the same key (including replacing a dict with a
        scalar or vice versa — the higher-priority layer is the
        authority on shape too). Lists are NOT element-wise merged;
        ``higher``'s list replaces ``lower``'s entirely so a project
        layer can simply override a builtin list without surprises.
        """
        out = dict(lower)
        for key, value in higher.items():
            if isinstance(value, dict) and isinstance(out.get(key), dict):
                out[key] = RuntimeBinder._deep_merge(value, out[key])
            else:
                out[key] = value
        return out

    def bind_capabilities(
        self,
        workflow_ref: str,
        registry_ref: str | None = None,
        semantic_plan: dict | None = None,
    ) -> dict:
        semantic_plan = semantic_plan or self.loader.build_semantic_plan(workflow_ref)
        return self.bind_semantic_plan(semantic_plan, registry_ref=registry_ref)

    def bind_semantic_plan(self, semantic_plan: dict, registry_ref: str | None = None) -> dict:
        """Bind semantic plan to skill registry, return binding report.

        Return structure (formerly unresolved-binding.schema.yaml):
            workflow_id: str
            workflow_version: int
            binding_status: ready | degraded | blocked
            summary: {total_steps, resolved_steps, fallback_steps,
                      unresolved_required_steps, unresolved_optional_steps}
            steps: [{step_id, phase, capability, optional,
                     resolution_status (resolved | fallback_available |
                       required_unresolved | optional_unresolved | incompatible),
                     selected_skill_id, selected_provider, selected_agent_alias,
                     selected_prompt_file, selected_cli,
                     binding_mode, missing_policy, reason}]
        """
        registry = self.load_skill_registry(registry_ref)
        project_context = self.project_context_loader.build_runtime_summary()
        constitution_binding_policy = project_context.get("binding_policy", {}) or {}
        defaults = dict(registry.get("binding_defaults", {}))
        defaults.update(constitution_binding_policy.get("defaults", {}))
        allowed_capabilities = set(constitution_binding_policy.get("allowed_capabilities", []) or [])
        bootstrap_mode = bool(project_context.get("_bootstrap", False))
        bootstrap_workflow = semantic_plan.get("workflow_id") == self.BOOTSTRAP_WORKFLOW_ID
        self._assert_workflow_source_allowed(semantic_plan.get("source_path"), project_context)

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
            executor = step.get("executor", "ai")
            binding_mode = self._get_binding_mode(step, defaults)
            missing_policy = self._get_missing_policy(step, defaults)

            if bootstrap_mode and not bootstrap_workflow:
                resolution_status = "blocked_by_constitution"
                reason = "project constitution is missing; run project-constitution workflow first"
                selected_skill_id = None
                selected_provider = None
                selected_agent_alias = None
                selected_prompt_file = None
                selected_cli = None
                if optional:
                    unresolved_optional_steps += 1
                else:
                    unresolved_required_steps += 1
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
                        "candidate_skill_ids": [],
                    }
                )
                continue

            if allowed_capabilities and capability not in allowed_capabilities:
                if bootstrap_workflow and capability in self.BOOTSTRAP_ALLOWED_CAPABILITIES:
                    pass
                else:
                    resolution_status = "blocked_by_constitution"
                    reason = "capability is not allowed by project constitution"
                    selected_skill_id = None
                    selected_provider = None
                    selected_agent_alias = None
                    selected_prompt_file = None
                    selected_cli = None
                    if optional:
                        unresolved_optional_steps += 1
                    else:
                        unresolved_required_steps += 1
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
                            "candidate_skill_ids": [],
                        }
                    )
                    continue

            if executor == "shell":
                resolution_status = "resolved"
                reason = "shell executor resolved directly"
                resolved_steps += 1
                selected_skill_id = "builtin-shell"
                selected_provider = "builtin"
                selected_agent_alias = "shell"
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
                        "candidate_skill_ids": [],
                    }
                )
                continue

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
            "schema_version": 1,
            "workflow_id": semantic_plan["workflow_id"],
            "workflow_version": semantic_plan["version"],
            "binding_status": binding_status,
            "registry_source_path": registry.get("_source_path"),
            "project_context": project_context,
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
        return self.build_bound_execution_phases_from_semantic(semantic_plan, registry_ref=registry_ref)

    def build_bound_execution_phases_from_semantic(
        self,
        semantic_plan: dict,
        registry_ref: str | None = None,
    ) -> dict:
        """從已存在的 semantic plan 建立 bound execution phases。"""
        binding = self.bind_semantic_plan(semantic_plan, registry_ref=registry_ref)
        binding_by_step = {step["step_id"]: step for step in binding["steps"]}
        governance = semantic_plan.get("governance", {})
        phase_limit = self._governance_phase_limit(semantic_plan)
        goal_stage = governance.get("goal_stage")

        phases: list[dict] = []
        deferred_steps: list[dict] = []
        for phase in semantic_plan["phases"]:
            if phase_limit is not None and phase["phase"] > phase_limit:
                for step in phase["steps"]:
                    step_binding = binding_by_step[step["step_id"]]
                    deferred_steps.append(
                        {
                            "step_id": step["step_id"],
                            "step_name": step["step_name"],
                            "capability": step["capability"],
                            "optional": True,
                            "done_when": step.get("done_when", []),
                            "notes": step.get("notes", []),
                            "executor": step.get("executor", "ai"),
                            "script": step.get("script"),
                            "fallback": step.get("fallback"),
                            "resolution_status": "optional_unresolved",
                            "skill_id": step_binding["selected_skill_id"],
                            "provider": step_binding["selected_provider"],
                            "agent_alias": step_binding["selected_agent_alias"],
                            "prompt_file": step_binding["selected_prompt_file"],
                            "cli": step_binding["selected_cli"],
                            "input_mode": self._resolve_input_mode(step, governance),
                            "output_tier": self._resolve_output_tier(step, governance),
                            "continue_reason": step.get("continue_reason")
                            or "requires explicit opt-in beyond default workflow scope",
                            "budget_state": "deferred_by_constitution",
                            "governance_reason": (
                                f"goal_stage={goal_stage} limited to first {phase_limit} phase(s)"
                            ),
                        }
                    )
                continue
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
                    "done_when": step.get("done_when", []),
                    "notes": step.get("notes", []),
                    "optional": step["optional"],
                    "on_fail": step["on_fail"],
                    "executor": step.get("executor", "ai"),
                    "script": step.get("script"),
                    "fallback": step.get("fallback"),
                    "parallel_with": step["parallel_with"],
                    "gate": step["gate"],
                    "on_fail_route": step["on_fail_route"],
                    "record_level": step["record_level"],
                    "timeout_seconds": step.get("timeout_seconds"),
                    "stall_seconds": step.get("stall_seconds"),
                    "stall_action": step.get("stall_action"),
                    "resolution_status": step_binding["resolution_status"],
                    "skill_id": step_binding["selected_skill_id"],
                    "provider": step_binding["selected_provider"],
                    "agent_alias": step_binding["selected_agent_alias"],
                    "prompt_file": step_binding["selected_prompt_file"],
                    "cli": step_binding["selected_cli"],
                    "binding_mode": step_binding["binding_mode"],
                    "missing_policy": step_binding["missing_policy"],
                    "input_mode": self._resolve_input_mode(step, governance),
                    "output_tier": self._resolve_output_tier(step, governance),
                    "continue_reason": step.get("continue_reason")
                    or self._default_continue_reason(step, phase_limit),
                    "budget_state": self._resolve_budget_state(step, phase_limit),
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
                        "done_when": step.get("done_when", []),
                        "notes": step.get("notes", []),
                        "executor": step.get("executor", "ai"),
                        "script": step.get("script"),
                        "fallback": step.get("fallback"),
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
            "governance_runtime": {
                "goal_stage": goal_stage,
                "phase_limit": phase_limit,
                "deferred_steps": [step["step_id"] for step in deferred_steps],
            },
            "binding": binding,
            "phases": phases,
            "standby_steps": standby_steps + deferred_steps,
        }

    def build_bound_execution_phases_from_workflow(
        self,
        workflow_data: dict,
        registry_ref: str | None = None,
        source_path: str = "<compiled>",
    ) -> dict:
        """從 inline workflow data 建立 semantic / bound execution plan。"""
        workflow = self.loader.normalize_workflow_data(workflow_data, source_path)
        semantic_plan = self.loader.build_semantic_plan_from_workflow(workflow)
        return self.build_bound_execution_phases_from_semantic(semantic_plan, registry_ref=registry_ref)

    @staticmethod
    def _governance_phase_limit(semantic_plan: dict) -> int | None:
        governance = semantic_plan.get("governance", {})
        goal_stage = governance.get("goal_stage")
        if semantic_plan.get("workflow_id") == RuntimeBinder.BOOTSTRAP_WORKFLOW_ID:
            return None
        if goal_stage == "informal_planning":
            raw = governance.get("max_primary_phases", 2)
            if isinstance(raw, int) and raw > 0:
                return raw
            return 2
        return None

    @staticmethod
    def _resolve_input_mode(step: dict, governance: dict) -> str:
        if step.get("input_mode"):
            return step["input_mode"]
        if step["capability"].endswith("_audit"):
            return "full"
        return governance.get("context_mode", "summary_first").replace("_first", "")

    @staticmethod
    def _resolve_output_tier(step: dict, governance: dict) -> str:
        if step.get("output_tier"):
            return step["output_tier"]
        goal_stage = governance.get("goal_stage")
        if goal_stage == "informal_planning":
            return "planning_artifact"
        return "full_artifact"

    @staticmethod
    def _default_continue_reason(step: dict, phase_limit: int | None) -> str:
        if phase_limit is not None and step["phase"] <= phase_limit:
            return "within default workflow scope"
        return "required by declared workflow dependency"

    @staticmethod
    def _resolve_budget_state(step: dict, phase_limit: int | None) -> str:
        if phase_limit is not None and step["phase"] > phase_limit:
            return "deferred_by_budget"
        return "within_budget"

    def _load_legacy_registry_adapter(self, missing_registry_path: Path) -> dict:
        # P0c batch 2.5 dual-path for legacy agents.json: namespaced new path
        # is consulted first; fall back to the legacy flat-file. The class
        # name still says "legacy" because it's the legacy AGENT-binding
        # adapter (translates .cap.agents.json into the modern skill
        # registry shape) — distinct from "legacy path" here.
        namespaced_agents = self.base_dir / self.LEGACY_AGENT_REGISTRY_PATH_NAMESPACED
        legacy_agents = self.base_dir / self.LEGACY_AGENT_REGISTRY_PATH
        legacy_path = namespaced_agents if namespaced_agents.is_file() else legacy_agents
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
                    "compatible_workflow_versions": [],
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

    def _assert_workflow_source_allowed(self, source_path: str | None, project_context: dict) -> None:
        if not source_path or source_path.startswith("<"):
            return

        workflow_policy = project_context.get("workflow_policy", {}) or {}
        if not workflow_policy.get("enforce_allowed_source_roots", False):
            return

        allowed_roots = workflow_policy.get("allowed_source_roots", []) or []
        if not allowed_roots:
            return

        source = Path(source_path)
        if not source.is_absolute():
            source = self.base_dir / source
        source = source.resolve()

        for root_ref in allowed_roots:
            root_path = Path(root_ref)
            if not root_path.is_absolute():
                root_path = self.base_dir / root_path
            root_path = root_path.resolve()
            if source == root_path or root_path in source.parents:
                return

        raise WorkflowSourcePolicyError(
            f"workflow 來源不符合 project constitution 限制: {source_path}",
            stage="workflow_source_policy",
            errors=[
                f"source_path '{source_path}' is not under any of the configured allowed_source_roots: {list(allowed_roots)}"
            ],
        )

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
