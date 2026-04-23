from __future__ import annotations

import json
from collections import defaultdict, deque
from pathlib import Path

import yaml


class WorkflowLoader:
    def __init__(self, base_dir: Path | None = None):
        self.base_dir = Path(base_dir) if base_dir else Path(__file__).resolve().parents[1]
        self.workflows_dir = self.base_dir / "schemas" / "workflows"
        self.capabilities_path = self.base_dir / "schemas" / "capabilities.yaml"
        self.agents_path = self.base_dir / ".cap.agents.json"

    def load_workflow(self, workflow_ref):
        workflow_path = Path(workflow_ref)
        if not workflow_path.is_absolute():
            workflow_path = self.base_dir / workflow_ref

        if not workflow_path.exists():
            candidate = self.workflows_dir / workflow_ref
            if candidate.exists():
                workflow_path = candidate
            else:
                raise FileNotFoundError(f"找不到 workflow: {workflow_ref}")

        if workflow_path.suffix not in {".yaml", ".yml", ".json"}:
            raise ValueError(f"不支援的 workflow 格式: {workflow_path.suffix}")

        raw = workflow_path.read_text(encoding="utf-8")
        if workflow_path.suffix == ".json":
            data = json.loads(raw)
        else:
            data = yaml.safe_load(raw)

        self._validate_workflow(data, workflow_path)
        data["_source_path"] = str(workflow_path)
        return data

    def load_capabilities(self) -> dict:
        """從 schemas/capabilities.yaml 讀取 capability 契約。"""
        if not self.capabilities_path.exists():
            raise FileNotFoundError(f"找不到 capability 契約: {self.capabilities_path}")
        raw = self.capabilities_path.read_text(encoding="utf-8")
        data = yaml.safe_load(raw)
        return data.get("capabilities", {})

    def load_agents(self) -> dict:
        """從 .cap.agents.json 讀取 agent binding（alias → prompt/provider/cli）。"""
        if not self.agents_path.exists():
            raise FileNotFoundError(f"找不到 agent registry: {self.agents_path}")
        data = json.loads(self.agents_path.read_text(encoding="utf-8"))
        return data.get("agents", {})

    def resolve_step_agent(self, step: dict, capabilities: dict, agents: dict) -> dict:
        capability = step["capability"]
        capability_entry = capabilities.get(capability)
        if not capability_entry:
            raise KeyError(f"capability 尚未在 capabilities.yaml 註冊: {capability}")

        agent_alias = capability_entry["default_agent"]
        agent_entry = agents.get(agent_alias)
        if not agent_entry:
            raise KeyError(f"找不到 capability 對應的 agent alias: {agent_alias}")

        return {
            "alias": agent_alias,
            "prompt_file": agent_entry.get("prompt_file"),
            "provider": agent_entry.get("provider"),
            "cli": agent_entry.get("cli"),
        }

    def build_execution_plan(self, workflow_ref: str) -> dict:
        workflow = self.load_workflow(workflow_ref)
        capabilities = self.load_capabilities()
        agents = self.load_agents()

        plan = []
        for step in workflow["steps"]:
            agent = self.resolve_step_agent(step, capabilities, agents)
            plan.append(
                {
                    "step_id": step["id"],
                    "step_name": step["name"],
                    "capability": step["capability"],
                    "agent_alias": agent["alias"],
                    "prompt_file": agent["prompt_file"],
                    "needs": step.get("needs", []),
                    "inputs": step.get("inputs", []),
                    "outputs": step.get("outputs", []),
                    "optional": step.get("optional", False),
                    "on_fail": step.get("on_fail", "halt"),
                }
            )

        return {
            "workflow_id": workflow["workflow_id"],
            "name": workflow["name"],
            "summary": workflow["summary"],
            "source_path": workflow["_source_path"],
            "governance": workflow.get("governance", {}),
            "steps": plan,
        }

    def build_semantic_plan(self, workflow_ref: str) -> dict:
        """
        建立只依賴 workflow + capability 的 semantic plan。

        這個 plan 不做 agent / skill 綁定，讓 workflow 在 skill 缺失時仍可被載入與審核。
        """
        workflow = self.load_workflow(workflow_ref)
        capabilities = self.load_capabilities()

        steps_by_id: dict[str, dict] = {}
        contract_missing_steps: list[str] = []
        for step in workflow["steps"]:
            capability_name = step["capability"]
            capability_contract = capabilities.get(capability_name)
            if capability_contract is None:
                contract_missing_steps.append(step["id"])

            steps_by_id[step["id"]] = {
                "step_id": step["id"],
                "step_name": step["name"],
                "phase": None,
                "capability": capability_name,
                "capability_contract_found": capability_contract is not None,
                "capability_contract": capability_contract,
                "needs": step.get("needs", []),
                "inputs": step.get("inputs", []),
                "outputs": step.get("outputs", []),
                "done_when": step.get("done_when", []),
                "optional": step.get("optional", False),
                "on_fail": step.get("on_fail", "halt"),
                "parallel_with": step.get("parallel_with", []),
                "gate": step.get("gate"),
                "on_fail_route": step.get("on_fail_route", []),
                "record_level": step.get("record_level"),
                "timeout_seconds": step.get("timeout_seconds"),
                "stall_seconds": step.get("stall_seconds"),
                "stall_action": step.get("stall_action"),
                "input_mode": step.get("input_mode"),
                "output_tier": step.get("output_tier"),
                "continue_reason": step.get("continue_reason"),
            }

        phases = self._compute_phases(steps_by_id)
        for phase in phases:
            for step in phase["steps"]:
                step["phase"] = phase["phase"]

        semantic_steps: list[dict] = []
        for phase in phases:
            semantic_steps.extend(phase["steps"])

        return {
            "workflow_id": workflow["workflow_id"],
            "version": workflow["version"],
            "name": workflow["name"],
            "summary": workflow["summary"],
            "source_path": workflow["_source_path"],
            "governance": workflow.get("governance", {}),
            "contract_missing_steps": contract_missing_steps,
            "phases": phases,
            "steps": semantic_steps,
        }

    # ── Orchestration ──

    def build_execution_phases(self, workflow_ref: str) -> dict:
        """建構分階段執行計畫，包含並行分���、門禁與失敗路由。"""
        workflow = self.load_workflow(workflow_ref)
        capabilities = self.load_capabilities()
        agents = self.load_agents()

        steps_by_id: dict[str, dict] = {}
        for step in workflow["steps"]:
            agent = self.resolve_step_agent(step, capabilities, agents)
            steps_by_id[step["id"]] = {
                "step_id": step["id"],
                "step_name": step["name"],
                "capability": step["capability"],
                "agent_alias": agent["alias"],
                "prompt_file": agent["prompt_file"],
                "needs": step.get("needs", []),
                "inputs": step.get("inputs", []),
                "outputs": step.get("outputs", []),
                "optional": step.get("optional", False),
                "on_fail": step.get("on_fail", "halt"),
                "parallel_with": step.get("parallel_with", []),
                "gate": step.get("gate"),
                "on_fail_route": step.get("on_fail_route", []),
                "record_level": step.get("record_level"),
                "timeout_seconds": step.get("timeout_seconds"),
                "stall_seconds": step.get("stall_seconds"),
                "stall_action": step.get("stall_action"),
                "input_mode": step.get("input_mode"),
                "output_tier": step.get("output_tier"),
                "continue_reason": step.get("continue_reason"),
            }

        fail_routes = self._collect_fail_routes(steps_by_id)

        # Steps referenced only as on_fail_route targets (and optional)
        # are standby — exclude from main phase ordering.
        route_targets: set[str] = set()
        for routes in fail_routes.values():
            for r in routes:
                route_targets.add(r["route_to"])

        standby_ids = {
            sid for sid in route_targets
            if sid in steps_by_id
            and steps_by_id[sid]["optional"]
            and not steps_by_id[sid]["needs"]
        }

        main_steps = {
            sid: s for sid, s in steps_by_id.items() if sid not in standby_ids
        }
        standby_steps = [steps_by_id[sid] for sid in sorted(standby_ids)]

        phases = self._compute_phases(main_steps)
        optional_steps = [
            sid for sid, s in steps_by_id.items() if s["optional"]
        ]

        return {
            "workflow_id": workflow["workflow_id"],
            "version": workflow["version"],
            "name": workflow["name"],
            "summary": workflow["summary"],
            "source_path": workflow["_source_path"],
            "governance": workflow.get("governance", {}),
            "phases": phases,
            "standby_steps": standby_steps,
            "fail_routes": fail_routes,
            "optional_steps": optional_steps,
        }

    def build_step_index(self, workflow_ref: str) -> dict[str, dict]:
        """建立 step 查詢索引，供 handoff / orchestration 驗證使用。"""
        workflow = self.load_workflow(workflow_ref)
        phases_plan = self.build_execution_phases(workflow_ref)
        phase_by_step: dict[str, int] = {}
        for phase in phases_plan["phases"]:
            for step in phase["steps"]:
                phase_by_step[step["step_id"]] = phase["phase"]

        step_index: dict[str, dict] = {}
        governance = workflow.get("governance", {})
        watcher_checkpoints = set(governance.get("watcher_checkpoints", []))
        logger_checkpoints = set(governance.get("logger_checkpoints", []))

        for step in workflow["steps"]:
            step_id = step["id"]
            step_index[step_id] = {
                "step_id": step_id,
                "step_name": step["name"],
                "phase": phase_by_step.get(step_id),
                "capability": step["capability"],
                "needs": step.get("needs", []),
                "done_when": step.get("done_when", []),
                "on_fail": step.get("on_fail", "halt"),
                "on_fail_route": step.get("on_fail_route", []),
                "gate": step.get("gate"),
                "optional": step.get("optional", False),
                "watcher_required": step_id in watcher_checkpoints,
                "logger_required": step_id in logger_checkpoints,
            }

        return step_index

    def validate_handoff_ticket(self, workflow_ref: str, ticket: dict) -> dict:
        """
        驗證 handoff ticket 不得覆寫 workflow 核心約束。

        規則：
        - workflow_id / step_id / phase 必須對齊 workflow
        - target_capability 不得偏離 step capability
        - acceptance_criteria 至少覆蓋 step.done_when
        - handoff 不得弱化 workflow 要求的 watcher/logger checkpoint
        - route_back_to 必須指向 workflow 內存在的 step
        """
        workflow = self.load_workflow(workflow_ref)
        step_index = self.build_step_index(workflow_ref)
        governance = workflow.get("governance", {})
        errors: list[str] = []

        workflow_context = ticket.get("workflow_context", {})
        step_id = workflow_context.get("step_id")
        if not step_id:
            errors.append("handoff 缺少 workflow_context.step_id")
            return {"ok": False, "errors": errors}

        step_contract = step_index.get(step_id)
        if not step_contract:
            errors.append(f"handoff.step_id 不存在於 workflow: {step_id}")
            return {"ok": False, "errors": errors}

        workflow_id = workflow_context.get("workflow_id")
        if workflow_id and workflow_id != workflow["workflow_id"]:
            errors.append(
                f"handoff.workflow_id 與 workflow 不一致: {workflow_id} != {workflow['workflow_id']}"
            )

        phase = workflow_context.get("phase")
        expected_phase = step_contract["phase"]
        if phase is not None and phase != expected_phase:
            errors.append(
                f"handoff.phase 與 workflow step phase 不一致: {phase} != {expected_phase}"
            )

        target_capability = ticket.get("target_capability")
        if target_capability and target_capability != step_contract["capability"]:
            errors.append(
                "handoff.target_capability 不得覆寫 workflow step capability: "
                f"{target_capability} != {step_contract['capability']}"
            )

        acceptance_criteria = ticket.get("acceptance_criteria", [])
        missing_done_when = [
            item for item in step_contract["done_when"] if item not in acceptance_criteria
        ]
        if step_contract["done_when"] and missing_done_when:
            errors.append(
                "handoff.acceptance_criteria 未完整覆蓋 workflow.done_when: "
                f"{missing_done_when}"
            )

        route_back_to = workflow_context.get("route_back_to")
        if route_back_to and route_back_to not in step_index:
            errors.append(
                f"handoff.route_back_to 必須指向 workflow 內存在的 step: {route_back_to}"
            )

        governance_hint = ticket.get("governance", {})
        watcher_required = governance_hint.get("watcher_required")
        logger_required = governance_hint.get("logger_required")
        if step_contract["watcher_required"] and watcher_required is False:
            errors.append(
                f"handoff 不得關閉 workflow 指定的 watcher checkpoint: {step_id}"
            )
        if step_contract["logger_required"] and logger_required is False:
            errors.append(
                f"handoff 不得關閉 workflow 指定的 logger checkpoint: {step_id}"
            )

        record_mode_hint = governance_hint.get("record_mode_hint")
        logger_mode = governance.get("logger_mode")
        if logger_mode == "full_log" and record_mode_hint in {"milestone_log", "final_only"}:
            errors.append(
                "handoff.record_mode_hint 不得弱化 workflow.logger_mode=full_log"
            )
        if logger_mode == "milestone_log" and record_mode_hint == "final_only":
            errors.append(
                "handoff.record_mode_hint 不得弱化 workflow.logger_mode=milestone_log"
            )

        return {
            "ok": not errors,
            "errors": errors,
            "step_contract": step_contract,
        }

    def _compute_phases(self, steps_by_id: dict[str, dict]) -> list[dict]:
        """依 needs 拓撲排序，將可同時執行的 step 歸入同一 phase。"""
        in_degree: dict[str, int] = {sid: 0 for sid in steps_by_id}
        dependents: dict[str, list[str]] = defaultdict(list)

        for sid, step in steps_by_id.items():
            for dep in step["needs"]:
                if dep in steps_by_id:
                    in_degree[sid] += 1
                    dependents[dep].append(sid)

        # Kahn's algorithm — group by depth level
        queue = deque(sid for sid, deg in in_degree.items() if deg == 0)
        phases: list[dict] = []

        while queue:
            batch = sorted(queue)  # deterministic ordering
            queue.clear()

            phase_steps = [steps_by_id[sid] for sid in batch]

            # Detect gate within this phase
            gate = None
            for s in phase_steps:
                if s.get("gate"):
                    gate = s["gate"]
                    break

            phase: dict = {
                "phase": len(phases) + 1,
                "steps": phase_steps,
            }
            if gate:
                phase["gate"] = gate

            phases.append(phase)

            for sid in batch:
                for child in dependents[sid]:
                    in_degree[child] -= 1
                    if in_degree[child] == 0:
                        queue.append(child)

        # Detect cycle
        resolved = sum(len(p["steps"]) for p in phases)
        if resolved < len(steps_by_id):
            unresolved = [sid for sid, deg in in_degree.items() if deg > 0]
            raise ValueError(f"workflow 存在循環依賴: {unresolved}")

        return phases

    @staticmethod
    def _collect_fail_routes(steps_by_id: dict[str, dict]) -> dict[str, list[dict]]:
        """收集所有 step 的條件式失敗路由。"""
        routes: dict[str, list[dict]] = {}
        for sid, step in steps_by_id.items():
            if step["on_fail_route"]:
                routes[sid] = step["on_fail_route"]
        return routes

    def get_fail_route(
        self, fail_routes: dict[str, list[dict]], step_id: str, condition: str
    ) -> str | None:
        """查詢��定 step + condition 的失敗路由目標。"""
        for route in fail_routes.get(step_id, []):
            if route["condition"] == condition:
                return route["route_to"]
        return None

    def _validate_workflow(self, workflow, workflow_path):
        required_top_level = ["workflow_id", "version", "name", "summary", "steps"]
        for field in required_top_level:
            if field not in workflow:
                raise ValueError(f"{workflow_path} 缺少必要欄位: {field}")

        if not isinstance(workflow["steps"], list) or not workflow["steps"]:
            raise ValueError(f"{workflow_path} 的 steps 必須是非空陣列")

        seen_ids = set()
        for step in workflow["steps"]:
            for field in ["id", "name", "capability"]:
                if field not in step:
                    raise ValueError(f"{workflow_path} 的 step 缺少必要欄位: {field}")
            if step["id"] in seen_ids:
                raise ValueError(f"{workflow_path} 出現重複的 step id: {step['id']}")
            seen_ids.add(step["id"])

        governance = workflow.get("governance", {})
        if governance:
            for field in ["watcher_checkpoints", "logger_checkpoints"]:
                for step_id in governance.get(field, []):
                    if step_id not in seen_ids:
                        raise ValueError(
                            f"{workflow_path} 的 governance.{field} 包含不存在的 step id: {step_id}"
                        )
