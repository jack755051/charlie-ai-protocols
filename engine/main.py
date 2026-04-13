import os
from crewai import Task, Crew, Process
from dotenv import load_dotenv

from factory import AgentFactory

load_dotenv()

def main():
    if not os.getenv("OPENAI_API_KEY"):
        raise EnvironmentError("缺少 OPENAI_API_KEY，請先在專案根目錄建立 .env。")

    # 1. 喚醒 11 人團隊
    factory = AgentFactory()
    team = factory.build_team()
    
    # 防呆檢查
    if "SUPERVISOR" not in team:
        print("❌ 找不到 SUPERVISOR (PM) 配置，請檢查 prompts 目錄下的 01-supervisor-agent.md。")
        return

    pm_agent = team["SUPERVISOR"]

    # 2. 接收人類(你)的真實需求
    print("\n=======================================================")
    print("🤖 歡迎來到 AI 軟體開發工廠 (11-Agent Architecture)")
    print("=======================================================\n")
    user_input = input("👉 請輸入你的開發需求 (例如: 幫我寫一個電商購物車 API，包含 Redis 快取)：\n> ")

    # 3. 建立「初始啟動任務」，並直接指派給 PM (01)
    kickoff_task = Task(
        description=f"""
        人類使用者的原始需求：{user_input}

        請嚴格根據你的 `01-supervisor-agent.md` 規範執行：
        1. 進行需求拆解，產出具備技術細節的 PRD 摘要。
        2. 從你的 Sub-Agents Registry 中，找出正確的 Agent，並發派【任務交接單】給他們 (通常由 SA 開始)。
        3. 強制執行 4.2 品質門禁：當實作完成後，必須交由 WATCHER 與 SECURITY 審查，並由 QA 測試。
        4. 如果有錯誤，產生新的交接單退回重練。
        5. 所有代碼、文件與日誌，請指示 Agent 寫入 `../workspace/` 對應的目錄中。
        """,
        expected_output="完成整個流水線開發，確保 workspace 目錄中包含 SA Spec、schema.md、原始碼與最終日誌。",
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
    print(result)

if __name__ == "__main__":
    main()
