# Charlie's AI Protocols

> AI 多代理協作系統與開發規則中控台。
> 透過標準化 11 位 AI Agent 的職能人設，結合 CrewAI 執行引擎，實現工業級的軟體開發流水線。

---

## 🏛 核心架構 (The 3-Tier Architecture)

系統分為「大腦、引擎、沙盒」三大物理隔離層，確保 AI 在開發過程中不會發生邏輯污染：

### 1. 🧠 代理技能庫 (`docs/agent-skills/`) — 大腦

存放所有 Agent 的 **System Prompts**，是系統的「單一事實來源 (SSOT)」。

| 分組 | Agent | 職責 |
|---|---|---|
| **管理組** | 01 Supervisor, 90 Watcher, 99 Logger | 調度、門禁稽核、日誌紀錄 |
| **開發組** | 02 SA, 03 UI, 04 Frontend, 05 Backend | 架構設計、UI 設計、前後端實作 |
| **維運組** | 06 DevOps, 07 QA, 08 Security, 11 SRE | CI/CD、測試、資安審查、效能優化 |

* **策略庫 (`strategies/`)**: 存放特定框架的戰術執行細節（如 `frontend-nextjs.md`、`backend-dotnet.md`、`qa-playwright.md`）。

### 2. ⚙️ 核心引擎 (`engine/`) — 肉體

基於 Python 與 CrewAI 的自動化執行緒：

| 檔案 | 職責 |
|---|---|
| `factory.py` | 動態讀取 `docs/agent-skills/*.md` 規則，喚醒對應的 Agent 實例 |
| `main.py` | 接收人類需求，觸發 PM Agent 啟動流水線 |
| `requirements.txt` | 系統依賴（crewai, langchain-openai, python-dotenv） |

### 3. 📁 實體工作區 (`workspace/`) — 產出

AI Agent 的唯一工作沙盒，所有程式碼與文件皆產出於此：

| 目錄 | 產出者 | 內容 |
|---|---|---|
| `architecture/` | SA (02) | 系統設計文件與資料庫 Schema |
| `design/` | UI (03) | 視覺規範與 Design Tokens |
| `history/` | Logger (99) | 開發日誌 (devlog) 與決策紀錄 |

---

## 🚀 快速啟動 (Quick Start)

### 1. 環境準備

```bash
# 建議使用 Python 3.10+ 虛擬環境
python -m venv .venv
source .venv/bin/activate

# 安裝 CrewAI 引擎依賴
pip install -r engine/requirements.txt
```

### 2. 設定環境變數

複製範本並填入你的 LLM API Key：

```bash
cp .env.example .env
```

編輯 `.env`，將 `your-openai-api-key-here` 替換為你的真實金鑰：

```env
OPENAI_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxx
```

### 3. 初始化技術策略

使用 `init-ai.sh` 為本次任務鎖定前端框架策略：

```bash
# 可用選項：nextjs | angular | nuxt
bash init-ai.sh nextjs
```

> 執行後，腳本會將對應的 `strategies/frontend-*.md` 掛載為 CrewAI 的 active-strategy，
> 並將 Supervisor 規則注入 OpenClaw 工作區。

### 4. 執行開發任務

若在步驟 3 選擇不自動啟動，可手動喚醒團隊：

```bash
python engine/main.py
```

---

## 🛡 品質門禁機制 (Quality Gates)

本系統內建強制性的多重稽核流程，由 PM (01) 在 `4.2 Quality Gates` 中定義：

```
實作完成 (04/05)
  │
  ├─→ [90 Watcher] 結構稽核 ──┐
  │                            ├─→ 雙方皆 PASS
  └─→ [08 Security] 資安掃描 ─┘
                                    │
                                    ▼
                            [07 QA] E2E + 壓測
                                    │
                              PASS ─┤─ FAIL → [11 SRE] 效能診斷
                                    │
                                    ▼
                          [99 Logger] 歸檔
                          CHANGELOG + devlog
```

* **任一環節 FAIL**：PM 強制產生修復交接單退回原實作 Agent，修復後重新走完整流程。
* **全數 PASS**：Logger 寫入 `CHANGELOG.md` 並存檔至 `workspace/history/`，准予進入下一模組。

---

## 📂 完整目錄結構

```
charlie-ai-protocols/
├── docs/                          # 版控文件區
│   ├── agent-skills/              # Agent System Prompts (SSOT)
│   │   ├── 00-core-protocol.md    #   全域憲法
│   │   ├── 01-supervisor-agent.md #   主控 PM
│   │   ├── 02 ~ 99-*-agent.md    #   各職能 Agent
│   │   ├── strategies/            #   框架特化策略
│   │   └── README.md              #   Agent 架構藍圖與流水線說明
│   ├── policies/                  # 跨工具通用策略 (任何 AI CLI 可直接讀取)
│   │   └── git-workflow.md        #   Git 版本控制與 PR 規範
│   ├── architecture/              # SA 產出的資料庫 Schema 索引
│   │   └── database/
│   └── hardware/                  # 嵌入式 / 硬體相關標準
├── engine/                        # CrewAI 執行引擎
│   ├── factory.py
│   ├── main.py
│   └── requirements.txt
├── workspace/                     # Agent 執行期產出 (gitignored)
│   ├── architecture/              #   SA 規格書與 Schema
│   ├── design/                    #   UI 視覺規範
│   ├── history/                   #   開發日誌 (devlog)
│   ├── src/                       #   Agent 產出的原始碼
│   └── CHANGELOG.md               #   專案變更紀錄
├── init-ai.sh                     # 技術策略初始化腳本
├── .env.example                   # 環境變數範本
└── .gitignore
```
