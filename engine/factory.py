from pathlib import Path

from crewai import Agent

class AgentFactory:
    def __init__(self, prompts_dir=None):
        base_dir = Path(__file__).resolve().parents[1]
        self.prompts_dir = Path(prompts_dir) if prompts_dir else base_dir / "docs" / "agent-skills"
        self.agents = {}  # 用來存放整個團隊

    def build_team(self):
        print("⚙️  啟動 AI 代理工廠，正在載入大腦配置...")

        # 確保路徑存在
        if not self.prompts_dir.exists():
            raise FileNotFoundError(f"找不到路徑: {self.prompts_dir}")

        for file_path in sorted(self.prompts_dir.glob("*.md")):
            if file_path.name != "README.md":
                # 1. 讀取 .md 檔案內容 (注入靈魂)
                with file_path.open("r", encoding="utf-8") as f:
                    markdown_content = f.read()

                # 2. 從檔名解析出角色名稱 (例如: "01-supervisor-agent.md" -> "SUPERVISOR")
                parts = file_path.name.split("-")
                if len(parts) >= 2:
                    role_key = parts[1].upper()

                    # 3. 動態建立 CrewAI Agent
                    # 只有 SUPERVISOR (PM) 具備把任務發包給別人的權力
                    is_manager = (role_key == "SUPERVISOR")

                    agent = Agent(
                        role=f"{role_key} Expert",
                        goal="嚴格執行你的核心職責，絕對遵守 Markdown 規範，確保產出符合最高工業標準。",
                        backstory=markdown_content,  # 將整份 Markdown 塞入作為他的最高指導原則
                        verbose=True,  # 在終端機顯示他的思考過程
                        allow_delegation=is_manager
                    )

                    # 4. 登錄員工名冊
                    self.agents[role_key] = agent
                    print(f"✅ 成功喚醒: {role_key} ({file_path.name})")

        return self.agents
