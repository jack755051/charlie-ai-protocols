from pathlib import Path

from crewai import Agent

class AgentFactory:
    def __init__(self, prompts_dir=None):
        base_dir = Path(__file__).resolve().parents[1]
        self.prompts_dir = Path(prompts_dir) if prompts_dir else base_dir / "docs" / "agent-skills"
        self.agents = {}  # 用來存放整個團隊

    # 全域憲法檔名 — 不會被實例化為 Agent，而是作為所有 Agent 的共享前置知識
    CORE_PROTOCOL = "00-core-protocol.md"

    def build_team(self):
        print("⚙️  啟動 AI 代理工廠，正在載入大腦配置...")

        if not self.prompts_dir.exists():
            raise FileNotFoundError(f"找不到路徑: {self.prompts_dir}")

        # 1. 先載入全域憲法，作為所有 Agent 共享的前置背景知識
        core_path = self.prompts_dir / self.CORE_PROTOCOL
        core_preamble = ""
        if core_path.exists():
            core_preamble = core_path.read_text(encoding="utf-8")
            print(f"📜 已載入全域憲法: {self.CORE_PROTOCOL}")

        # 2. 遍歷其餘 .md 檔案，逐一實例化 Agent
        for file_path in sorted(self.prompts_dir.glob("*-agent.md")):

            markdown_content = file_path.read_text(encoding="utf-8")

            # 從檔名解析角色名稱 (例如: "01-supervisor-agent.md" -> "SUPERVISOR")
            parts = file_path.stem.split("-")
            if len(parts) < 2:
                continue
            role_key = parts[1].upper()

            # 將全域憲法 + 個人規範合併為完整 backstory
            backstory = f"{core_preamble}\n\n---\n\n{markdown_content}" if core_preamble else markdown_content

            # 只有 SUPERVISOR (PM) 具備把任務發包給別人的權力
            agent = Agent(
                role=f"{role_key} Expert",
                goal="嚴格執行你的核心職責，絕對遵守 Markdown 規範，確保產出符合最高工業標準。",
                backstory=backstory,
                verbose=True,
                allow_delegation=(role_key == "SUPERVISOR"),
            )

            self.agents[role_key] = agent
            print(f"✅ 成功喚醒: {role_key} ({file_path.name})")

        return self.agents
