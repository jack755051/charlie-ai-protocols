from __future__ import annotations

import hashlib
import re
from pathlib import Path

try:
    from .runtime_binder import RuntimeBinder
    from .workflow_loader import WorkflowLoader
except ImportError:  # pragma: no cover
    from runtime_binder import RuntimeBinder
    from workflow_loader import WorkflowLoader


class TaskScopedWorkflowCompiler:
    """Compile a task-scoped request into a minimal executable workflow."""

    def __init__(self, base_dir: Path | None = None):
        self.base_dir = Path(base_dir) if base_dir else Path(__file__).resolve().parents[1]
        self.loader = WorkflowLoader(self.base_dir)
        self.binder = RuntimeBinder(self.base_dir)
        self.capabilities = self.loader.load_capabilities()

    def build_task_constitution(self, source_request: str) -> dict:
        request = " ".join(source_request.split())
        lowered = request.lower()
        task_id = "task_" + hashlib.sha1(request.encode("utf-8")).hexdigest()[:10]

        planning_only = any(
            token in request
            for token in ["不要直接實作", "先不要實作", "非正式規劃", "先規劃", "初步規劃", "先評估"]
        )
        explicit_full_spec = any(
            token in request
            for token in ["完整規格", "正式規格", "完整流程", "完整功能", "完整開發"]
        )
        need_ui = any(
            token in lowered
            for token in ["ui", "web", "frontend", "tauri", "desktop", "app", "畫面", "介面", "前端"]
        )
        need_persistence = any(
            token in lowered
            for token in ["db", "database", "sqlite", "postgres", "mysql", "redis", "資料庫", "儲存", "cache"]
        )
        need_api_contract = (
            need_persistence
            or any(
                token in lowered
                for token in ["api", "cli", "integration", "hook", "event", "service", "監測", "監控", "串接", "服務"]
            )
        )
        need_implementation = (
            not planning_only
            and any(
                token in request
                for token in ["實作", "開發", "部署", "測試", "上線", "寫出", "完成功能"]
            )
        )

        unknown_domains = []
        domain_keywords = {
            "rust": ["rust", "tauri", "cargo"],
            "swift": ["swift", "swiftui"],
            "kotlin": ["kotlin", "compose"],
            "go": [" golang", "go ", "gin", "fiber"],
        }
        for domain, tokens in domain_keywords.items():
            if any(token in f" {lowered} " for token in tokens):
                unknown_domains.append(domain)

        if planning_only:
            goal_stage = "informal_planning"
        elif need_implementation:
            goal_stage = "implementation_and_verification"
        elif explicit_full_spec or need_ui or need_api_contract:
            goal_stage = "formal_specification"
        else:
            goal_stage = "informal_planning"

        requested_deliverables = []
        if need_ui:
            requested_deliverables.append("ui_spec")
        if need_api_contract:
            requested_deliverables.append("api_spec")
        if need_persistence:
            requested_deliverables.append("schema_ssot")
        if need_implementation:
            requested_deliverables.append("implementation")

        risk_profile = "unknown" if unknown_domains else ("medium" if need_api_contract or need_ui else "low")
        allowed_fallbacks = ["pending", "re_scope", "manual"]
        if not unknown_domains:
            allowed_fallbacks.insert(0, "fallback")

        required_questions = []
        if not any(token in request for token in ["成功", "目標", "用途", "要做", "希望"]):
            required_questions.append("這次任務最終的成功條件是什麼？")
        if need_ui and not any(token in request for token in ["桌面", "網頁", "CLI", "命令列", "Tauri", "Web"]):
            required_questions.append("這次工具的主要互動模式是桌面 UI、網頁 UI，還是 CLI？")
        if unknown_domains:
            required_questions.append("未知技術領域是否只做規劃 / discovery，而不是直接進入實作？")

        non_goals = []
        if planning_only:
            non_goals.extend(["不直接實作", "不進入部署", "不進入 QA 全鏈"])

        success_criteria = ["產出可執行的下一步建議與最小 workflow"]
        if planning_only:
            success_criteria.append("在不進入實作的前提下，釐清技術方向與風險")
        if explicit_full_spec:
            success_criteria.append("完成進入實作前所需的正式規格")

        constraints = []
        if planning_only:
            constraints.append("本次以規劃與風險釐清為主，不直接進入實作")
        if unknown_domains:
            constraints.append("未知技術領域優先做 summary-first planning / discovery")

        scope = ["task_scoped_workflow_compiler"]
        if "小工具" in request or "tool" in lowered:
            scope.append("small_tool")
        if need_ui:
            scope.append("ui_surface")
        if need_api_contract:
            scope.append("service_contract")

        output_expectations = ["task_constitution", "capability_graph", "compiled_workflow"]
        if goal_stage == "formal_specification":
            output_expectations.append("formal_specs")

        return {
            "task_id": task_id,
            "source_request": request,
            "goal": request,
            "scope": scope,
            "non_goals": non_goals,
            "success_criteria": success_criteria,
            "constraints": constraints,
            "risk_profile": risk_profile,
            "goal_stage": goal_stage,
            "allowed_fallbacks": allowed_fallbacks,
            "stop_conditions": [
                "required capability unresolved without acceptable fallback",
                "required input artifact missing",
                "output validation failed",
                "budget exceeded before core goal is satisfied",
            ],
            "required_questions": required_questions,
            "output_expectations": output_expectations,
            "inferred_context": {
                "project_kind": "small_tool" if ("小工具" in request or "tool" in lowered) else "general_task",
                "need_ui": need_ui,
                "need_persistence": need_persistence,
                "need_api_contract": need_api_contract,
                "planning_only": planning_only,
                "unknown_domains": unknown_domains,
                "requested_deliverables": requested_deliverables,
            },
            "unresolved_policy": {
                "default_action": "fallback" if "fallback" in allowed_fallbacks else "pending",
                "high_risk_action": "pending",
            },
        }

    def build_capability_graph(self, constitution: dict) -> dict:
        ctx = constitution["inferred_context"]
        stage = constitution["goal_stage"]
        explicit_full_spec = "formal_specs" in constitution.get("output_expectations", [])

        nodes: list[dict] = [
            self._node("prd", "prd_generation", required=True, depends_on=[], reason="define goal and scope"),
            self._node(
                "tech_plan",
                "technical_planning",
                required=True,
                depends_on=["prd"],
                reason="select technical direction and identify risks",
            ),
        ]

        if stage in {"formal_specification", "implementation_preparation", "implementation_and_verification"} or explicit_full_spec:
            nodes.append(
                self._node("ba", "business_analysis", required=True, depends_on=["tech_plan"], reason="clarify workflow and edge cases")
            )
            if ctx["need_api_contract"] or ctx["need_persistence"]:
                nodes.append(
                    self._node(
                        "dba_api",
                        "database_api_design",
                        required=True,
                        depends_on=["ba"],
                        reason="materialize data and interface contracts",
                    )
                )
            if ctx["need_ui"]:
                ui_deps = ["ba"]
                if ctx["need_api_contract"] or ctx["need_persistence"]:
                    ui_deps.append("dba_api")
                nodes.append(
                    self._node("ui", "ui_design", required=True, depends_on=ui_deps, reason="define interaction surface")
                )

            audit_deps = [node["step_id"] for node in nodes if node["step_id"] in {"tech_plan", "ba", "dba_api", "ui"}]
            if len(audit_deps) > 1:
                nodes.append(
                    self._node("spec_audit", "tool_spec_audit", required=True, depends_on=audit_deps, reason="validate cross-spec consistency")
                )
            archive_dep = "spec_audit" if any(node["step_id"] == "spec_audit" for node in nodes) else "tech_plan"
            nodes.append(
                self._node("archive", "technical_logging", required=True, depends_on=[archive_dep], reason="archive planning decision chain")
            )
        else:
            nodes.append(
                self._node("archive", "technical_logging", required=True, depends_on=["tech_plan"], reason="archive planning decision chain")
            )

        if stage == "implementation_and_verification":
            if ctx["need_ui"]:
                impl_deps = ["ui"] if any(node["step_id"] == "ui" for node in nodes) else ["tech_plan"]
                nodes.append(
                    self._node("frontend", "frontend_implementation", required=True, depends_on=impl_deps, reason="build user-facing interface")
                )
            if ctx["need_api_contract"] or ctx["need_persistence"] or ctx["unknown_domains"]:
                backend_deps = ["dba_api"] if any(node["step_id"] == "dba_api" for node in nodes) else ["tech_plan"]
                nodes.append(
                    self._node("backend", "backend_implementation", required=True, depends_on=backend_deps, reason="build service logic")
                )
            review_deps = [node["step_id"] for node in nodes if node["step_id"] in {"frontend", "backend"}]
            if review_deps:
                nodes.append(
                    self._node("structure_audit", "code_structure_audit", required=True, depends_on=review_deps, reason="verify implementation against specs")
                )
                nodes.append(
                    self._node("qa", "qa_testing", required=True, depends_on=["structure_audit"], reason="validate behavior before delivery")
                )
                nodes.append(
                    self._node("devops", "devops_delivery", required=True, depends_on=["qa"], reason="prepare runtime delivery baseline")
                )

        return {
            "task_id": constitution["task_id"],
            "goal_stage": stage,
            "nodes": nodes,
        }

    def build_candidate_workflow(self, constitution: dict, capability_graph: dict) -> dict:
        governance = self._compile_governance(constitution, capability_graph)
        steps = [self._compile_step(node, constitution) for node in capability_graph["nodes"]]
        return {
            "workflow_id": f"compiled-{constitution['task_id']}",
            "version": 2,
            "name": f"Compiled Workflow — {constitution['task_id']}",
            "summary": f"Compiled from task constitution: {constitution['goal']}",
            "owner": "supervisor",
            "triggers": ["manual", "compiled"],
            "governance": governance,
            "steps": steps,
        }

    def compile_task(self, source_request: str, registry_ref: str | None = None) -> dict:
        constitution = self.build_task_constitution(source_request)
        capability_graph = self.build_capability_graph(constitution)
        candidate_workflow = self.build_candidate_workflow(constitution, capability_graph)
        candidate_semantic = self.loader.build_semantic_plan_from_workflow(
            self.loader.normalize_workflow_data(candidate_workflow, f"<compiled:{constitution['task_id']}:candidate>")
        )
        binding = self.binder.bind_semantic_plan(candidate_semantic, registry_ref=registry_ref)
        unresolved_policy = self.build_unresolved_policy(constitution, capability_graph, binding)
        compiled_workflow = self.apply_unresolved_policy(candidate_workflow, unresolved_policy)
        plan = self.binder.build_bound_execution_phases_from_workflow(
            compiled_workflow,
            registry_ref=registry_ref,
            source_path=f"<compiled:{constitution['task_id']}>",
        )
        return {
            "task_constitution": constitution,
            "capability_graph": capability_graph,
            "binding": binding,
            "unresolved_policy": unresolved_policy,
            "compiled_workflow": compiled_workflow,
            "plan": plan,
        }

    def build_unresolved_policy(self, constitution: dict, capability_graph: dict, binding: dict) -> dict:
        nodes_by_step = {node["step_id"]: node for node in capability_graph["nodes"]}
        decisions = []
        for step in binding["steps"]:
            node = nodes_by_step.get(step["step_id"], {})
            status = step["resolution_status"]
            action = "execute"
            reason = "resolved"
            if status == "fallback_available":
                if constitution["risk_profile"] in {"high", "unknown"}:
                    action = "pending"
                    reason = "high-risk fallback requires manual confirmation"
                else:
                    action = "fallback"
                    reason = "generic fallback acceptable for current risk profile"
            elif status == "required_unresolved":
                action = "pending"
                reason = "required capability unresolved; must stop before execution"
            elif status == "optional_unresolved":
                action = "skip"
                reason = "optional capability unresolved; safe to skip"
            elif status == "incompatible":
                action = "manual"
                reason = "skill exists but execution metadata is incomplete"
            decisions.append(
                {
                    "step_id": step["step_id"],
                    "capability": step["capability"],
                    "required": bool(node.get("required", not step["optional"])),
                    "resolution_status": status,
                    "action": action,
                    "reason": reason,
                }
            )
        return {
            "task_id": constitution["task_id"],
            "default_action": constitution["unresolved_policy"]["default_action"],
            "decisions": decisions,
        }

    @staticmethod
    def apply_unresolved_policy(workflow_data: dict, unresolved_policy: dict) -> dict:
        decisions = {item["step_id"]: item for item in unresolved_policy["decisions"]}
        compiled = dict(workflow_data)
        compiled["steps"] = []
        for step in workflow_data["steps"]:
            decision = decisions.get(step["id"])
            if decision and decision["action"] == "skip":
                continue
            updated = dict(step)
            if decision:
                updated["continue_reason"] = f"{updated.get('continue_reason', '')} | unresolved_policy={decision['action']}: {decision['reason']}".strip(" |")
            compiled["steps"].append(updated)
        return compiled

    @staticmethod
    def _node(step_id: str, capability: str, *, required: bool, depends_on: list[str], reason: str) -> dict:
        return {
            "step_id": step_id,
            "capability": capability,
            "required": required,
            "depends_on": depends_on,
            "reason": reason,
        }

    def _compile_step(self, node: dict, constitution: dict) -> dict:
        contract = self.capabilities[node["capability"]]
        step = {
            "id": node["step_id"],
            "name": self._humanize_step_name(node["step_id"], node["capability"]),
            "capability": node["capability"],
            "needs": node["depends_on"],
            "inputs": contract.get("inputs", []),
            "outputs": contract.get("outputs", []),
            "done_when": contract.get("done_when", []),
            "optional": not node["required"],
            "on_fail": "halt",
            "record_level": "full_log" if node["capability"] in {"technical_planning", "technical_logging", "tool_spec_audit"} else "trace_only",
            "input_mode": "full" if node["capability"].endswith("_audit") else "summary",
            "output_tier": "planning_artifact" if constitution["goal_stage"] == "informal_planning" else "full_artifact",
            "continue_reason": node["reason"],
        }
        if constitution["goal_stage"] == "informal_planning":
            step["stall_action"] = "warn"
        return step

    @staticmethod
    def _humanize_step_name(step_id: str, capability: str) -> str:
        names = {
            "prd": "Task PRD",
            "tech_plan": "Task Technical Plan",
            "ba": "Business Analysis",
            "dba_api": "Data And Interface Contract",
            "ui": "Interaction Design",
            "spec_audit": "Spec Consistency Audit",
            "archive": "Task Archive",
            "frontend": "Frontend Implementation",
            "backend": "Backend Implementation",
            "structure_audit": "Code Structure Audit",
            "qa": "QA Validation",
            "devops": "Delivery Baseline",
        }
        return names.get(step_id, capability.replace("_", " ").title())

    @staticmethod
    def _compile_governance(constitution: dict, capability_graph: dict) -> dict:
        stage = constitution["goal_stage"]
        step_ids = [node["step_id"] for node in capability_graph["nodes"]]
        governance = {
            "goal_stage": stage,
            "context_mode": "summary_first",
            "halt_on_missing_handoff": True,
        }
        if stage == "informal_planning":
            governance.update(
                {
                    "step_count_budget": 3,
                    "max_primary_phases": 2,
                    "watcher_mode": "final_only",
                    "logger_mode": "milestone_log",
                    "logger_checkpoints": [sid for sid in step_ids if sid in {"prd", "tech_plan", "archive"}],
                }
            )
        else:
            governance.update(
                {
                    "watcher_mode": "milestone_gate",
                    "logger_mode": "milestone_log",
                    "watcher_checkpoints": [sid for sid in step_ids if sid in {"spec_audit", "structure_audit", "qa"}],
                    "logger_checkpoints": [sid for sid in step_ids if sid in {"prd", "tech_plan", "archive", "qa", "devops"}],
                }
            )
        return governance
