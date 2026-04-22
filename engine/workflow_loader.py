import json
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
            "steps": plan,
        }

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
