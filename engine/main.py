import os

from crewai import Crew, Process, Task
from dotenv import load_dotenv

from factory import AgentFactory
from workflow_loader import WorkflowLoader

load_dotenv()


def print_workflow_plan(plan):
    print("\n🧭 Workflow Execution Plan")
    print("-------------------------------------------------------")
    print(f"ID: {plan['workflow_id']}")
    print(f"Name: {plan['name']}")
    print(f"Source: {plan['source_path']}")
    print(f"Summary: {plan['summary']}")
    print("\nSteps:")
    for index, step in enumerate(plan["steps"], start=1):
        print(
            f"{index}. [{step['step_id']}] {step['step_name']} "
            f"=> capability={step['capability']} / agent={step['agent_alias']}"
        )
        if step["needs"]:
            print(f"   needs: {', '.join(step['needs'])}")
        if step["outputs"]:
            print(f"   outputs: {', '.join(step['outputs'])}")


def main():
    if not os.getenv("OPENAI_API_KEY"):
        raise EnvironmentError("缺少 OPENAI_API_KEY，請先在專案根目錄建立 .env。")

    # 1. 喚醒 13 人團隊
    factory = AgentFactory()
    team = factory.build_team()
    
    # 防呆檢查
    if "SUPERVISOR" not in team:
        print("❌ 找不到 SUPERVISOR (PM) 配置，請檢查 prompts 目錄下的 01-supervisor-agent.md。")
        return

    pm_agent = team["SUPERVISOR"]

    # 2. 接收人類(你)的真實需求
    print("\n=======================================================")
    print("🤖 歡迎來到 AI 軟體開發工廠 (13-Agent Architecture)")
    print("=======================================================\n")
    user_input = input("👉 請輸入你的開發需求 (例如: 幫我寫一個電商購物車 API，包含 Redis 快取)：\n> ")

    workflow_ref = input(
        "👉 若要載入 workflow，請輸入檔名或路徑（直接 Enter 跳過，例如 `readme-to-devops.yaml`）：\n> "
    ).strip()

    workflow_plan = None
    if workflow_ref:
        loader = WorkflowLoader()
        workflow_plan = loader.build_execution_plan(workflow_ref)
        print_workflow_plan(workflow_plan)

    workflow_context = ""
    if workflow_plan:
        lines = [
            "",
            "請以以下 workflow execution plan 作為編排依據：",
            f"- workflow_id: {workflow_plan['workflow_id']}",
            f"- summary: {workflow_plan['summary']}",
            "- step plan:",
        ]
        for step in workflow_plan["steps"]:
            lines.append(
                f"  - {step['step_id']}: capability={step['capability']}, "
                f"agent_alias={step['agent_alias']}, needs={step['needs']}, outputs={step['outputs']}"
            )
        workflow_context = "\n".join(lines)

    # 3. 建立「初始啟動任務」，並直接指派給 PM (01)
    kickoff_task = Task(
        description=f"""
        人類使用者的原始需求：{user_input}
        {workflow_context}

        請嚴格根據你的 `01-supervisor-agent.md` 規範執行：
        1. 進行需求拆解，產出具備技術細節的 PRD 摘要。
        2. 若 workflow execution plan 已提供，依該 plan 的 capability、step 順序與產物要求進行編排。
        3. 若無 workflow，參考 `schemas/workflows/feature-delivery.yaml` 作為預設流程。
        4. 編排決策依據 `schemas/capabilities.yaml` 與 `schemas/handoff-ticket.schema.yaml`。
        5. 正式文件請寫入 `../docs/` 對應目錄；執行期 log、trace、草稿與報告請優先寫入 CAP 本機儲存區（例如 `~/.cap/projects/<project_id>/`）。
        """,
        expected_output="完成整個流水線開發，確保 docs 中有正式規格，且 CAP 本機儲存區保留必要的 trace 與報告。",
        agent=pm_agent
    )

    # 4. 建立 CrewAI 工作小組
    # 把所有喚醒的 Agent 丟進去，PM 在遇到需要發包時，就會從這個池子裡找人
    software_crew = Crew(
        agents=list(team.values()),
        tasks=[kickoff_task],
        process=Process.sequential, # 以 PM 的任務為起點開始依序執行
        verbose=True
    )

    # 5. 放手讓 AI 開始工作！
    print("\n🚀 專案正式啟動！已將指揮權交接給 01-PM...")
    print("-------------------------------------------------------")
    result = software_crew.kickoff()

    print("\n=======================================================")
    print("🎉 專案開發結束！PM 的最終結案報告：")
    print(result.raw)

if __name__ == "__main__":
    main()
