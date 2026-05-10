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


class SourcePolicyError(Exception):
    """Common base for source-policy halts (workflow / skill).

    P9 #5 introduced this base so callers (engine + CLI) can ``except
    SourcePolicyError`` once and route either ``WorkflowSourcePolicyError``
    or ``SkillSourcePolicyError`` through the same JSON-error
    surface. Subclasses preserve the existing ``stage`` / ``errors``
    keyword constructor contract.
    """

    def __init__(self, message: str, *, stage: str, errors: list[str]) -> None:
        super().__init__(message)
        self.stage = stage
        self.errors = list(errors)


class WorkflowSourcePolicyError(SourcePolicyError):
    """Raised when a workflow's source path is outside the effective allowed roots.

    Replaces the bare ``ValueError`` previously raised by
    ``RuntimeBinder._assert_workflow_source_allowed`` so the CLI can
    surface a deterministic JSON error class instead of a raw
    traceback. P9 #5 promoted the parent class to ``SourcePolicyError``
    without changing the ``__init__`` contract; existing
    ``except WorkflowSourcePolicyError`` callers keep working.
    """

    pass


class SkillSourcePolicyError(SourcePolicyError):
    """Raised when a step's selected skill source path is outside the effective allowed roots.

    Per design memo §7.4 the skill-side gate halts the entire binding
    rather than degrading to a fallback, because a violation indicates
    the project constitution's source isolation has been broken; logging
    a fallback would hide the breach in the binding report.
    """

    pass


class OverrideContractError(Exception):
    """Raised when a skill registry's override contract is internally inconsistent.

    Surface for the v0.22.0+ ``disabled`` / ``replaces`` post-merge
    contract (see ``policies/agent-skills-baseline.md`` §4). Currently
    fires for the ``multiple skills replace the same target`` case;
    other cases (``disabled`` + ``replaces`` on same entry,
    non-existent ``replaces`` target) are tolerated with a documented
    fallback rather than halting.
    """

    def __init__(self, message: str, *, errors: list[str]) -> None:
        super().__init__(message)
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
        # ProjectContextLoader resolves project_id, ledger origin, and
        # constitution path. It must point at the user's project_root
        # (the CWD-derived working repo), NOT base_dir (the cap install
        # directory). When cap is invoked via the global wrapper from
        # outside the install dir, base_dir = ~/.charlie-ai-protocols
        # whose basename collides with any local clone of the dev repo
        # also named "charlie-ai-protocols", and current_origin lands on
        # the install path while the ledger records the actual project
        # path — _verify_or_write_ledger then halts with
        # ProjectIdCollisionError. v0.25.1 fix: feed project_root so
        # project identity always tracks the working repo.
        self.project_context_loader = ProjectContextLoader(self.project_root)

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
        no merge, no source tagging beyond ``_source_path``. The
        v0.22.0+ override contract (``disabled`` / ``replaces``) is
        still applied so a single-file registry exercising the
        contract behaves the same way as a layered merge.
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
        return self._apply_override_contract(data)

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

        v0.22.0+ override-contract polish: when the first-seen entry
        for a ``skill_id`` is a ``disabled: true`` tombstone with no
        ``provided_capabilities`` of its own, the merge copies the
        capability list from the next lower-layer entry that has the
        same id. The tombstone still wins (it's masked), but the audit
        hint at ``_collect_masked_hint`` can now name which capabilities
        the project intentionally hid. Tagged with
        ``_capabilities_inherited_from_underlying`` for traceability.
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
                if not sid:
                    continue
                if sid in merged_skills_by_id:
                    # Underlying layer for the same skill_id. If the
                    # winning tombstone is missing capability info,
                    # inherit from this lower-layer entry so audit can
                    # explain what got masked.
                    existing = merged_skills_by_id[sid]
                    if (
                        existing.get("disabled") is True
                        and not existing.get("provided_capabilities")
                    ):
                        underlying_caps = list(
                            skill.get("provided_capabilities") or []
                        )
                        if underlying_caps:
                            existing["provided_capabilities"] = underlying_caps
                            existing["_capabilities_inherited_from_underlying"] = True
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

        merged = {
            "schema_version": schema_version if schema_version is not None else 1,
            "default_provider": default_provider or "builtin",
            "binding_defaults": merged_defaults,
            "skills": skills_in_order,
            "_source_path": source_paths[0] if source_paths else "",
            "_source_paths": source_paths,
            "_missing": False,
            "_adapter_from_legacy": False,
        }
        return self._apply_override_contract(merged)

    def _apply_override_contract(self, registry: dict) -> dict:
        """Apply v0.22.0+ ``disabled`` / ``replaces`` override contract.

        Spec SSOT: ``policies/agent-skills-baseline.md`` §4. Three
        passes over the merged ``skills`` list, all in-place:

        1. Detect ``replaces`` conflicts. If two or more skills target
           the same ``replaces`` value, raise :class:`OverrideContractError`.
           ``disabled: true`` entries are excluded from this check
           (they cannot replace anything; see Pass 2).
        2. Mark masked entries.

           * ``disabled: true`` → mask self with ``_mask_reason="disabled"``.
             ``disabled`` wins over ``replaces`` on the same entry; if
             both are set the entry is treated as disabled and does
             not produce a replacement effect.
           * ``replaces: <target>`` → mask the target entry (when present
             in the merged registry) with
             ``_mask_reason=f"replaced_by={self.skill_id}"``.

           ``replaces`` against a target absent from the merged registry
           is tolerated (warn-but-accept) so marketplace-style skills
           that haven't been installed yet don't halt binding.
        3. Capability inheritance. For each non-masked replacement
           skill whose own ``provided_capabilities`` is missing or empty,
           inherit the target skill's ``provided_capabilities`` verbatim
           (target lookup uses the merged registry — even if the target
           is now masked, its capability list is still readable).
           Replacements with their own capability list keep it (no merge).

        ``_masked`` / ``_mask_reason`` / ``_capabilities_inherited_from``
        are internal ``_*``-prefixed fields, so they don't surface in
        ``binding-report.schema.yaml`` ``steps[*]`` validation.
        Consumer-facing audit reads them via the binding report's
        ``reason`` text and the merged registry snapshot.
        """
        skills = registry.get("skills", []) or []

        # skill_id → entry index for fast lookup. Skills without
        # skill_id are skipped (the schema requires it but the loader
        # is permissive; they pass through as-is and never get masked).
        skill_by_id: dict[str, dict] = {
            s.get("skill_id"): s for s in skills if s.get("skill_id")
        }

        # ── Pass 1: detect duplicate `replaces` targets ──
        replace_targets: dict[str, list[str]] = {}
        for skill in skills:
            sid = skill.get("skill_id")
            if not sid or skill.get("disabled") is True:
                continue
            target = skill.get("replaces")
            if target:
                replace_targets.setdefault(target, []).append(sid)
        conflicts = {
            target: ids for target, ids in replace_targets.items() if len(ids) > 1
        }
        if conflicts:
            errors = [
                f"skill_id '{target}' is replaced by multiple skills: "
                + ", ".join(sorted(ids))
                for target, ids in sorted(conflicts.items())
            ]
            raise OverrideContractError(
                "skill registry has multiple replacement candidates for the same skill_id",
                errors=errors,
            )

        # ── Pass 2: mark masked entries ──
        for skill in skills:
            sid = skill.get("skill_id")
            if not sid:
                continue
            if skill.get("disabled") is True:
                skill["_masked"] = True
                skill["_mask_reason"] = "disabled"
                continue
            target = skill.get("replaces")
            if target:
                target_skill = skill_by_id.get(target)
                if target_skill is not None:
                    target_skill["_masked"] = True
                    target_skill["_mask_reason"] = f"replaced_by={sid}"
                # else: target absent → tolerate (marketplace not installed)

        # ── Pass 3: capability inheritance ──
        for skill in skills:
            target = skill.get("replaces")
            if not target:
                continue
            if skill.get("_masked"):
                # disabled wins over replaces; no inheritance for self-masked.
                continue
            own = skill.get("provided_capabilities")
            if own:
                continue
            target_skill = skill_by_id.get(target)
            if target_skill is None:
                continue
            inherited = list(target_skill.get("provided_capabilities") or [])
            skill["provided_capabilities"] = inherited
            skill["_capabilities_inherited_from"] = target

        return registry

    @staticmethod
    def _skill_source_metadata(skill: dict | None, *, fallback_when_missing: bool = False) -> dict | None:
        """Extract P9 #4 skill_source metadata from a registry skill dict.

        Skills accumulated by ``_resolve_layer_registry`` carry
        ``_source_layer`` / ``_source_path`` internal tags (P9 #3); this
        helper projects them into the binding-report shape. Skills
        synthesised by the legacy ``agents.json`` adapter or by the
        ``builtin-shell`` branch lack those tags — when
        ``fallback_when_missing`` is true, return a sentinel
        ``{"source_layer": "fallback", "source_path": null}`` so the
        binding report still records *that the selection had no
        navigable registry file*; when false, return ``None`` (used for
        unresolved / blocked branches that have no skill at all).
        """
        if skill is None:
            if fallback_when_missing:
                return {"source_layer": "fallback", "source_path": None}
            return None
        layer = skill.get("_source_layer")
        path = skill.get("_source_path")
        if layer:
            return {"source_layer": layer, "source_path": path}
        return {"source_layer": "fallback", "source_path": None}

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
        # P9 #5 — compute the effective allowed roots once (implicit
        # project + builtin defaults union user-declared) so both the
        # workflow gate (here) and the per-step skill gate (inside the
        # for loop) consult the same set, and the binding report's
        # effective_allowed_roots field reflects the actual policy
        # snapshot used during this bind.
        effective_allowed_roots = self._compute_effective_allowed_roots(project_context)
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
                # P9 #5 — bootstrap-blocked branch picks no skill;
                # gate is a structural no-op but kept here so the
                # invariant "skill gate fires for every step" holds
                # uniformly across all four append sites.
                self._assert_skill_source_allowed(
                    None,
                    step_id=step["step_id"],
                    effective_allowed_roots=effective_allowed_roots,
                )
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
                        # P9 #4 — bootstrap-blocked branch never picked a skill.
                        "skill_source": None,
                        # Phase 5 — bootstrap-blocked branch has no role
                        # and never attaches advisory skills; emit the
                        # canonical empty shape so consumers don't have
                        # to special-case absence.
                        "selected_role": None,
                        "attached_skills": [],
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
                    # P9 #5 — capability-blocked branch picks no skill;
                    # uniform gate call (structural no-op).
                    self._assert_skill_source_allowed(
                        None,
                        step_id=step["step_id"],
                        effective_allowed_roots=effective_allowed_roots,
                    )
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
                            # P9 #4 — capability-blocked branch never picked a skill.
                            "skill_source": None,
                            # Phase 5 — capability-blocked branch has no
                            # role and never attaches.
                            "selected_role": None,
                            "attached_skills": [],
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
                # P9 #4 / #5 — synthetic builtin-shell selection has no
                # real registry file to enforce; the gate call is a
                # structural no-op (skill_source.source_path is None
                # so _assert_skill_source_allowed returns immediately)
                # but kept here for the uniform "every step gets gated"
                # invariant.
                shell_skill_source = self._skill_source_metadata(
                    None, fallback_when_missing=True
                )
                self._assert_skill_source_allowed(
                    shell_skill_source,
                    step_id=step["step_id"],
                    effective_allowed_roots=effective_allowed_roots,
                )
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
                        "skill_source": shell_skill_source,
                        # Phase 5 — shell executor steps run no AI
                        # prompt; selected_role is null and no advisory
                        # skill attachments are mounted (build_step_prompt
                        # in cap-workflow-exec.sh skips attachment
                        # injection for shell executors anyway).
                        "selected_role": None,
                        "attached_skills": [],
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

            # P9 #4 — track which registry skill ended up selected so
            # the binding report can record skill_source. None means
            # no skill was picked at all (unresolved branch).
            chosen_skill: dict | None = None

            if selected and self._has_execution_metadata(selected):
                resolution_status = "resolved"
                reason = "found compatible skill"
                resolved_steps += 1
                selected_skill_id = selected["skill_id"]
                selected_provider = selected.get("provider")
                selected_agent_alias = selected.get("agent_alias")
                selected_prompt_file = selected.get("prompt_file")
                selected_cli = selected.get("cli")
                chosen_skill = selected
            elif fallback and self._has_execution_metadata(fallback):
                resolution_status = "fallback_available"
                reason = "no direct skill; generic fallback available"
                fallback_steps += 1
                selected_skill_id = fallback["skill_id"]
                selected_provider = fallback.get("provider")
                selected_agent_alias = fallback.get("agent_alias")
                selected_prompt_file = fallback.get("prompt_file")
                selected_cli = fallback.get("cli")
                chosen_skill = fallback
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
                chosen_skill = broken
            else:
                if optional:
                    resolution_status = "optional_unresolved"
                    unresolved_optional_steps += 1
                else:
                    resolution_status = "required_unresolved"
                    unresolved_required_steps += 1
                masked_hint = self._collect_masked_hint(registry, capability)
                if masked_hint:
                    reason = f"no compatible skill found in registry; {masked_hint}"
                else:
                    reason = "no compatible skill found in registry"
                selected_skill_id = None
                selected_provider = None
                selected_agent_alias = None
                selected_prompt_file = None
                selected_cli = None

            # P9 #4 — derived from the chosen skill's P9 #3
            # _source_layer / _source_path internal tags; None when
            # no skill was selected (unresolved branches), "fallback"
            # sentinel when the skill exists but lacks layer tags
            # (legacy adapter).
            skill_source = self._skill_source_metadata(chosen_skill)
            # P9 #5 — gate the chosen skill against effective allowed
            # roots before writing the step report. Raises
            # SkillSourcePolicyError on violation; halts the entire
            # binding rather than degrading (memo §7.4).
            self._assert_skill_source_allowed(
                skill_source,
                step_id=step["step_id"],
                effective_allowed_roots=effective_allowed_roots,
                purpose="role",
                skill_id=selected_skill_id,
            )

            # Phase 5 — structured selected_role view + attached
            # advisory skills. selected_role only fills in when the
            # role pick has full execution metadata (prompt_file is
            # the schema-required field); attachment is only computed
            # when the role itself is bound, since an unmounted role
            # has no anchor for the strict-attach contract.
            role_has_metadata = bool(chosen_skill) and self._has_execution_metadata(chosen_skill)
            selected_role_obj = (
                self._build_selected_role(chosen_skill) if role_has_metadata else None
            )
            attached_skills_report: list[dict] = []
            if role_has_metadata:
                attached_pairs = self._find_attached_skills(
                    registry,
                    capability,
                    workflow_version=semantic_plan["version"],
                    selected_role_alias=chosen_skill.get("agent_alias"),
                )
                for attached_skill, attach_reason in attached_pairs:
                    attached_source = self._skill_source_metadata(attached_skill)
                    # Source policy applies to attached skills the
                    # same way as the role: a violation halts the
                    # entire bind (memo §7.4 — never silently drop
                    # the attachment, that hides the breach).
                    self._assert_skill_source_allowed(
                        attached_source,
                        step_id=step["step_id"],
                        effective_allowed_roots=effective_allowed_roots,
                        purpose="attached_skill",
                        skill_id=attached_skill.get("skill_id"),
                    )
                    attached_skills_report.append(
                        self._build_attached_skill_entry(attached_skill, attach_reason)
                    )

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
                    "skill_source": skill_source,
                    "selected_role": selected_role_obj,
                    "attached_skills": attached_skills_report,
                }
            )

        binding_status = self._resolve_binding_status(
            unresolved_required_steps=unresolved_required_steps,
            fallback_steps=fallback_steps,
            unresolved_optional_steps=unresolved_optional_steps,
        )

        # P9 #4 — top-level workflow_source from semantic_plan's
        # source_layer / source_path tags (threaded by P9 #2 through
        # build_semantic_plan_from_workflow). Null when the semantic
        # plan was synthesized inline without a backing file.
        workflow_source_path = semantic_plan.get("source_path")
        workflow_source_layer = semantic_plan.get("source_layer")
        workflow_source: dict | None
        if workflow_source_path and workflow_source_layer:
            workflow_source = {
                "source_layer": workflow_source_layer,
                "source_path": workflow_source_path,
            }
        else:
            workflow_source = None

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
            "workflow_source": workflow_source,
            # P9 #5: snapshot of the effective allowed_source_roots set
            # actually consulted during this bind (implicit project +
            # builtin defaults union user-declared, deduped). Empty
            # list reads as "enforcement disabled".
            "effective_allowed_roots": effective_allowed_roots,
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
                            # H2 #4: propagate skill_source so binding_summary
                            # extractor can identify which skills came from
                            # project layer without re-running bind_semantic_plan.
                            "skill_source": step_binding.get("skill_source"),
                            # Phase 5 — propagate role + attached
                            # advisory skills so flatten_steps and the
                            # shell prompt builder can mount them.
                            # Deferred steps never run, so empty values
                            # here are fine; we still emit for shape
                            # consistency with active steps.
                            "selected_role": step_binding.get("selected_role"),
                            "attached_skills": step_binding.get("attached_skills") or [],
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
                    # H2 #4: propagate skill_source for binding_summary extraction.
                    "skill_source": step_binding.get("skill_source"),
                    # Phase 5 — selected_role mirrors the role pick;
                    # attached_skills carries advisory prompts to
                    # mount after the role prompt at AI execution.
                    "selected_role": step_binding.get("selected_role"),
                    "attached_skills": step_binding.get("attached_skills") or [],
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
                        # H2 #4: propagate skill_source for binding_summary.
                        "skill_source": step_binding.get("skill_source"),
                        # Phase 5 — propagate role + attachments so a
                        # standby step that gets activated later
                        # carries the same shape as the inline plan.
                        "selected_role": step_binding.get("selected_role"),
                        "attached_skills": step_binding.get("attached_skills") or [],
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
        """Halt binding when ``source_path`` is outside effective allowed roots.

        P9 #5 upgraded this hook to consult the **effective** set
        (implicit project + builtin defaults union user-declared
        ``constitution.workflow_policy.allowed_source_roots``) computed
        by :meth:`_compute_effective_allowed_roots`, so the gate stays
        correct after P9 #2 layered resolution started routing some
        workflows through ``<project_root>/.cap/workflows/`` and
        ``<cap_root>/schemas/workflows/`` which a pre-P9 user-declared
        list would not include.
        """
        if not source_path or source_path.startswith("<"):
            return

        effective_roots = self._compute_effective_allowed_roots(project_context)
        if not effective_roots:
            return

        if self._path_is_under_any_root(source_path, effective_roots):
            return

        raise WorkflowSourcePolicyError(
            f"workflow 來源不符合 project constitution 限制: {source_path}",
            stage="workflow_source_policy",
            errors=[
                f"source_path '{source_path}' is not under any of the effective allowed_source_roots: {list(effective_roots)}"
            ],
        )

    def _assert_skill_source_allowed(
        self,
        skill_source: dict | None,
        *,
        step_id: str,
        effective_allowed_roots: list[str],
        purpose: str = "role",
        skill_id: str | None = None,
    ) -> None:
        """Halt binding when a step's selected skill source is outside effective allowed roots.

        Per design memo §7.3 / §7.4 fires after the binder picks a
        skill for ``step_id`` (i.e. after ``_skill_source_metadata``
        returns the report-shaped dict, before ``step_reports.append``).
        Skips when:

        * ``effective_allowed_roots`` is empty — enforcement disabled.
        * ``skill_source`` is ``None`` — no skill was selected
          (resolution_status in {required_unresolved, optional_unresolved,
          blocked_by_constitution}); nothing to enforce.
        * ``skill_source.source_path`` is ``None`` — synthetic
          builtin-shell or legacy-adapter selection; ``source_layer``
          is ``"fallback"`` and there is no real registry file path
          to gate. Memo §7.5: fallback / synthetic selections cannot
          violate source policy because they have no source.

        Otherwise the chosen skill's ``source_path`` is checked the
        same way as the workflow gate; mismatch raises
        :class:`SkillSourcePolicyError` and halts the binding (memo
        §7.4: governance redline beats availability — never degrade
        to fallback to hide the breach).

        ``purpose`` and ``skill_id`` are Phase 5 audit annotations.
        ``purpose`` distinguishes role-side checks (default ``"role"``)
        from attached-skill checks (``"attached_skill"``) so the
        SkillSourcePolicyError message can name the offending pick;
        no behavioural change for pre-Phase 5 callers that omit the
        kwargs.
        """
        if not effective_allowed_roots:
            return
        if skill_source is None:
            return
        source_path = skill_source.get("source_path") if isinstance(skill_source, dict) else None
        if not source_path:
            return

        if self._path_is_under_any_root(source_path, effective_allowed_roots):
            return

        skill_label = f" skill_id='{skill_id}'" if skill_id else ""
        raise SkillSourcePolicyError(
            f"skill 來源不符合 project constitution 限制: step_id={step_id} purpose={purpose}{skill_label} source_path={source_path}",
            stage="skill_source_policy",
            errors=[
                f"step '{step_id}' selected a {purpose} skill"
                + (f" '{skill_id}'" if skill_id else "")
                + f" from '{source_path}' which is not under any of the effective allowed_source_roots: {list(effective_allowed_roots)}"
            ],
        )

    def _compute_effective_allowed_roots(self, project_context: dict) -> list[str]:
        """Compute the effective set of allowed source roots for enforcement.

        Returns an empty list when ``enforce_allowed_source_roots`` is
        ``False`` — both source-policy hooks treat empty as "enforcement
        disabled" and skip. Otherwise the result is, in order:

        1. User-declared ``constitution.workflow_policy.allowed_source_roots``.
        2. Implicit project layer (design memo §3.1.2): the
           ``<project_root>/.cap/{workflows,skills,skills.json}``
           directories — auto-allowed so a project that flips
           ``enforce_allowed_source_roots`` on doesn't accidentally
           block its own ``.cap/`` registry files.
        3. Implicit builtin layer: the
           ``<cap_root>/schemas/workflows`` plus
           ``<cap_root>/.cap/{skills,skills.json}`` paths.

        Shared layer is intentionally **not** in implicit defaults; if
        a user wants the shared registry honored they have to declare
        ``<cap_home>/shared/...`` explicitly in
        ``allowed_source_roots`` (memo §3.1).

        All paths are returned as absolute strings (``Path.resolve()``);
        de-duplicated while preserving priority order so the binding
        report's ``effective_allowed_roots`` field reads cleanly.
        """
        workflow_policy = project_context.get("workflow_policy", {}) or {}
        if not workflow_policy.get("enforce_allowed_source_roots", False):
            return []

        candidates: list[str] = []

        # User-declared first so they read top of the binding report's
        # effective_allowed_roots snapshot.
        for raw in workflow_policy.get("allowed_source_roots", []) or []:
            if not raw:
                continue
            try:
                resolved = Path(raw).expanduser().resolve()
            except (OSError, ValueError):
                continue
            candidates.append(str(resolved))

        # Implicit project + builtin layer paths. Memo §3.1.2 lists
        # ``.cap/skills.json`` literally; in practice the canonical
        # skill registry is ``.cap/skills.yaml`` (per
        # DEFAULT_REGISTRY_PATH_NAMESPACED), so we cover all three
        # extensions plus the per-skill subdir for both layers, and
        # the legacy flat-file at ``<base_dir>/.cap.skills.{yaml,yml,
        # json}`` so unmigrated projects don't get blocked by their
        # own builtin registry.
        skill_filenames = ("skills", "skills.yaml", "skills.yml", "skills.json")

        for sub in ("workflows",) + tuple(f"{name}" for name in skill_filenames):
            candidates.append(str((self.project_root / ".cap" / sub).resolve()))

        candidates.append(str((self.base_dir / "schemas" / "workflows").resolve()))
        for sub in skill_filenames:
            candidates.append(str((self.base_dir / ".cap" / sub).resolve()))

        # Legacy flat-file fallbacks (P0c batch 2.5 dual-path).
        for legacy in (".cap.skills.yaml", ".cap.skills.yml", ".cap.skills.json"):
            candidates.append(str((self.base_dir / legacy).resolve()))

        seen: set[str] = set()
        ordered: list[str] = []
        for path in candidates:
            if path in seen:
                continue
            seen.add(path)
            ordered.append(path)
        return ordered

    def _path_is_under_any_root(self, source_path: str, allowed_roots: list[str]) -> bool:
        """Return True when ``source_path`` is at or under one of the allowed roots.

        Handles relative ``source_path`` (resolved relative to
        ``self.base_dir``), symlink-laden paths (``Path.resolve()``),
        and exact-match equality (a ``source_path`` that *is* a listed
        root counts as inside it).
        """
        source = Path(source_path)
        if not source.is_absolute():
            source = self.base_dir / source
        try:
            source = source.resolve()
        except (OSError, ValueError):
            return False

        for root_ref in allowed_roots:
            root_path = Path(root_ref)
            if not root_path.is_absolute():
                root_path = self.base_dir / root_path
            try:
                root_path = root_path.resolve()
            except (OSError, ValueError):
                continue
            if source == root_path or root_path in source.parents:
                return True
        return False

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
    def _classify_kind(skill: dict) -> str:
        """Classify a registry entry as ``role`` or ``skill``.

        Phase 5 discriminator. Explicit ``kind`` always wins (the
        schema doc has called this out since v0.24.7). When ``kind``
        is missing, fall back to legacy inference: ``agent_alias``
        present → role; absent → skill. The fallback covers builtin
        agent-skills written before v0.24.7 added the field, plus the
        legacy ``agents.json`` adapter shape.
        """
        explicit = skill.get("kind")
        if explicit in ("role", "skill"):
            return explicit
        if skill.get("agent_alias"):
            return "role"
        return "skill"

    @staticmethod
    def _find_candidates(
        registry: dict,
        capability: str,
        workflow_version: int,
        preferred_agent_alias: str | None = None,
    ) -> list[dict]:
        """Role-only executor candidates for a capability.

        Phase 5: a registry entry can only be picked as the executor
        when ``RuntimeBinder._classify_kind`` returns ``"role"``.
        ``kind=skill`` entries (advisory guardrails) are filtered out
        of the executor slot here; ``_find_attached_skills`` selects
        them separately. ``_masked`` / ``enabled`` / capability /
        ``compatible_workflow_versions`` filters preserved verbatim
        from pre-Phase 5 behaviour so legacy registries keep ranking
        the same way.
        """
        candidates = []
        for skill in registry.get("skills", []):
            # v0.22.0+ override contract: masked entries (disabled or
            # replaces-target) cannot be selected. See _apply_override_contract.
            if skill.get("_masked"):
                continue
            if not skill.get("enabled", True):
                continue
            if capability not in skill.get("provided_capabilities", []):
                continue

            # Phase 5 — only kind=role entries are executor candidates.
            # Advisory skills (kind=skill, explicit or legacy-inferred)
            # are routed through _find_attached_skills instead.
            if RuntimeBinder._classify_kind(skill) != "role":
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

    @staticmethod
    def _find_attached_skills(
        registry: dict,
        capability: str,
        *,
        workflow_version: int,
        selected_role_alias: str | None,
    ) -> list[tuple[dict, str]]:
        """Phase 5 strict-attach: list advisory skills to mount on the role.

        Returns ``(skill_dict, attach_reason)`` pairs sorted by
        priority desc then skill_id asc, deduped by ``skill_id``.

        Strict-attach contract (memo §"Decision: strict attachment
        policy (not auto-fan-in)"):

        1. Entry must classify as ``kind=skill`` (explicit; legacy
           inference into skill is also accepted when ``agent_alias``
           is absent — it's the same legacy rule, just inverted).
        2. At least one of the opt-in declarations must match:

           * ``attach_to_capabilities`` contains ``capability``
             (primary contract surface; takes precedence) → reason
             ``attach_to_capabilities``.
           * ``attach_to_roles`` contains ``selected_role_alias``
             (secondary convenience) → reason ``attach_to_roles``.

           When both would match, ``attach_to_capabilities`` wins
           because the workflow's contract surface is the capability
           name, not the executor role.

        3. Standard masking / enabled / version filters apply (same
           as ``_find_candidates``).

        Auto-fan-in over ``provided_capabilities`` was rejected at the
        ADR-style note. ``provided_capabilities`` describes what the
        skill *covers*; ``attach_to_*`` is the explicit opt-in for
        *attaching* to other capabilities / roles. A skill that only
        wants to advertise itself for direct selection (rare today,
        future use case) keeps using ``provided_capabilities`` and
        won't accidentally attach itself to every step that shares a
        capability name.
        """
        seen: set[str] = set()
        matched: list[tuple[dict, str]] = []
        for skill in registry.get("skills", []):
            if skill.get("_masked"):
                continue
            if not skill.get("enabled", True):
                continue
            if RuntimeBinder._classify_kind(skill) != "skill":
                continue

            compatible_versions = skill.get("compatible_workflow_versions", [])
            if compatible_versions and workflow_version not in compatible_versions:
                continue

            attach_caps = skill.get("attach_to_capabilities") or []
            attach_roles = skill.get("attach_to_roles") or []
            if capability in attach_caps:
                attach_reason = "attach_to_capabilities"
            elif selected_role_alias and selected_role_alias in attach_roles:
                attach_reason = "attach_to_roles"
            else:
                continue

            sid = skill.get("skill_id")
            if not sid or sid in seen:
                continue
            seen.add(sid)
            matched.append((skill, attach_reason))

        matched.sort(
            key=lambda pair: (
                -int(pair[0].get("priority", 100) or 100),
                pair[0].get("skill_id") or "",
            )
        )
        return matched

    @staticmethod
    def _build_selected_role(skill: dict | None) -> dict | None:
        """Project a chosen role entry into the binding-report ``selected_role`` shape.

        Returns ``None`` for shell executor selections, unresolved
        branches, and incompatible roles (missing ``prompt_file``).
        The schema requires ``prompt_file`` so emitting a partial
        ``selected_role`` would fail validation; the legacy quartet
        (``selected_skill_id`` / ``selected_agent_alias`` / ``selected_prompt_file``
        / ``selected_cli``) keeps writing in those cases for callers
        that need to surface the partial pick.
        """
        if not skill:
            return None
        prompt_file = skill.get("prompt_file")
        if not prompt_file:
            return None
        kind = skill.get("kind")
        # Phase 5 invariant: this slot only carries roles. Don't
        # propagate "skill" into the report even if a misconfigured
        # entry slipped through (defence in depth — the candidate
        # filter already excludes kind=skill).
        if kind == "skill":
            return None
        return {
            "skill_id": skill.get("skill_id"),
            "agent_alias": skill.get("agent_alias"),
            "provider": skill.get("provider"),
            "prompt_file": prompt_file,
            "cli": skill.get("cli"),
            "kind": kind if kind == "role" else None,
            "skill_source": RuntimeBinder._skill_source_metadata(skill),
        }

    @staticmethod
    def _build_attached_skill_entry(skill: dict, attach_reason: str) -> dict:
        """Project an attached-skill pick into the binding-report items shape."""
        return {
            "skill_id": skill.get("skill_id"),
            "agent_alias": skill.get("agent_alias"),
            "provider": skill.get("provider"),
            "prompt_file": skill.get("prompt_file"),
            "cli": skill.get("cli"),
            "attach_reason": attach_reason,
            "skill_source": RuntimeBinder._skill_source_metadata(skill),
        }

    def _find_fallback(self, registry: dict, capability: str) -> dict | None:
        capability_family = self._infer_fallback_role(capability)
        for skill in registry.get("skills", []):
            # v0.22.0+ override contract: masked entries cannot become
            # fallback either, so a project-level disabled/replaces
            # mask isn't silently bypassed by fallback resolution.
            if skill.get("_masked"):
                continue
            if not skill.get("enabled", True):
                continue
            # Phase 5: fallback must also be a role; advisory skills
            # cannot quietly fill the executor slot via fallback.
            if RuntimeBinder._classify_kind(skill) != "role":
                continue
            if capability_family in skill.get("fallback_roles", []):
                return skill
            if skill.get("skill_id", "").startswith(self.GENERIC_FALLBACK_PREFIX) and capability_family in skill.get("skill_id", ""):
                return skill
        return None

    @staticmethod
    def _collect_masked_hint(registry: dict, capability: str) -> str | None:
        """Return a human-readable hint when masked skills could have served this capability.

        v0.22.0+ override-contract audit aid (see
        ``docs/cap/P9-SOURCE-RESOLVER-DESIGN.md`` §11.1). Scans the
        merged registry for masked entries (``_masked=True``) whose
        ``provided_capabilities`` lists the requested capability, and
        formats their ids + mask reasons. Returns ``None`` when no
        masked entry would have qualified — preserves the existing
        unresolved reason text.

        Tombstones missing their own ``provided_capabilities`` are
        covered because ``_merge_skill_layers`` inherits the underlying
        layer's capability list onto the tombstone before this scan
        runs.
        """
        masked_hits: list[str] = []
        for skill in registry.get("skills", []):
            if not skill.get("_masked"):
                continue
            if capability not in (skill.get("provided_capabilities") or []):
                continue
            sid = skill.get("skill_id") or "<unknown>"
            reason = skill.get("_mask_reason", "masked")
            masked_hits.append(f"'{sid}' ({reason})")
        if not masked_hits:
            return None
        return (
            "target skill_id(s) for this capability are masked: "
            + ", ".join(masked_hits)
        )

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
