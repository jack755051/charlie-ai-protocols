這是一份根據您實際的目錄結構（包含 `docs/agent-skills` 11 人團隊設定、`engine` CrewAI 執行緒以及 `workspace` 產出區），並融合我們先前討論的「前台 PM (OpenClaw) + 後台執行團隊 (CrewAI)」混合架構概念，為您重新改寫的最外部 `README.md`。

這份改寫版本分為 **「架構介紹」** 與 **「操作使用」** 兩大核心，確保能精準反映您目前的系統設計：

***

# Charlie's AI Protocols

> 這裡是 Charlie 的 AI 多代理協作系統與開發規則中控台 (AI-driven Workflow Standards)。
> 本 Repo 收錄了跨語言通用的開發紀律、各職能 AI Agent 的核心人設 (Prompt/Context)，以及基於 CrewAI 的執行引擎。透過標準化 AI 的上下文，確保 AI 產出的架構與程式碼能高度對齊團隊的開發哲學與安全標準。

## 🏛 架構介紹 (Architecture Overview)

本系統採用 **「最高決策者 (PM) 與 專業開發團隊 (Crew)」** 的分離架構。最外圍可由 OpenClaw 或其他對話介面作為總 PM 釐清需求，確認後透過本 Repo 的底層引擎 (`engine`) 喚醒 11 人的 AI 團隊進行非同步協作與開發。

### 📂 目錄結構與職責劃分

系統依據職責與運行階段，切分為以下核心目錄：

#### 1. 🧠 代理技能庫 (`docs/agent-skills/`)
這裡是整個 AI 團隊的大腦與人設儲存區，所有 Agent 在實作前皆須讀取對應的 Markdown 檔案：
*   **管理與監控組**：`01-supervisor-agent.md` (主控/PM)、`90-watcher-agent.md` (監控者)、`99-logger-agent.md` (紀錄員)。
*   **核心開發組**：`02-sa-standard.md` (架構師)、`03-ui-standard.md` (UI 設計)、`04-frontend-standard.md` (前端)、`05-backend-standard.md` (後端)。
*   **維運與品質組**：`06-devops-standard.md`、`07-qa-standard.md`、`08-security-standard.md`、`11-sre-optimization-standard.md`。
*   **策略擴充 (`strategies/`)**：針對特定技術棧的詳細實作策略（如 `frontend-nextjs.md`、`backend-dotnet.md`、`qa-playwright.md` 等）。

#### 2. ⚙️ 核心引擎 (`engine/`)
驅動 11 人 AI 團隊實際運作的 Python 執行緒：
*   `factory.py`: 負責讀取 `docs/agent-skills/` 中的 Markdown 檔案，動態生成 CrewAI 的代理物件與指派任務。
*   `main.py`: 系統啟動點，負責實例化 `AgentFactory` 並一次喚醒整個開發團隊執行專案。
*   `requirements.txt`: 定義了系統依賴，包含 `crewai`、`langchain-openai` 與 `python-dotenv`。

#### 3. 📁 實體工作區 (`workspace/`)
AI 團隊的專屬沙盒與產出目錄，嚴格隔離不同階段的產出物：
*   `architecture/`: 存放 SA 架構師規劃的系統文件與資料庫 Schema (`database/`)。
*   `design/`: 存放 UI/UX 設計與規格標註。
*   `history/`: Logger Agent 專用的日誌存放區，紀錄所有溝通與除錯歷程。

---

## 🚀 操作使用 (Getting Started & Operation)

### 步驟一：環境準備與依賴安裝
請確認您的宿主機（如 Mac mini）已安裝 Python 3.10+ 環境，接著安裝 CrewAI 核心引擎的依賴套件：

```bash
# 進入專案目錄
cd charlie-ai-protocols

# 安裝 CrewAI, LangChain 與相關套件
pip install -r engine/requirements.txt
```

### 步驟二：設定環境變數 (API Keys)
為了系統安全性，請勿將金鑰寫死在程式碼中。我們使用 `python-dotenv` 進行管理：
在專案根目錄建立 `.env` 檔案，並填入您的 LLM 授權碼（預設為 OpenAI，亦可抽換為 Claude/Gemini）：
```env
OPENAI_API_KEY="your-openai-api-key-here"
```

### 步驟三：自動初始化專案大腦 (Auto-Initialization)
當您準備開始一個新專案（或新任務）時，使用內建的腳本將基礎規則與特定技術策略進行綁定。

在專案根目錄執行：
```bash
# 針對特定技術棧初始化 AI 的上下文策略
# 例如：指定前端使用 Next.js，後端使用 .NET
bash init-ai.sh frontend-nextjs
bash init-ai.sh backend-dotnet
```
*(執行後，系統會將 `docs/agent-skills/strategies/` 中的特定設定匯入給對應的 AI 代理。)*

### 步驟四：喚醒 AI 團隊執行開發 (Run the Crew)
您可以直接透過終端機啟動引擎，或者透過最外層的 OpenClaw PM Agent 呼叫 Terminal Tools 來觸發此腳本：

```bash
python engine/main.py
```
**執行流程說明：**
1.  **載入設定**：`factory.py` 將會讀取所有的 Agent 核心協議與策略檔。
2.  **團隊成軍**：`main.py` 會透過 `AgentFactory.build_team()` 喚醒 11 位專職 Agent。
3.  **協作與審查**：各 Agent 將遵循嚴格的依賴關係工作（例如 Frontend 必須等待 SA 產出架構圖），最後由 Watcher 與 Security 審查並將最終成果歸檔至 `workspace/` 資料夾中。