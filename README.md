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
* **統一入口 (`.agents/skills/`)**: 透過 `scripts/mapper.sh` 建立的 symlink，讓任何 AI CLI 工具可從固定路徑讀取 Agent 定義，SSOT 仍為 `docs/agent-skills/`。

### 2. ⚙️ 核心引擎 (`engine/`) — 肉體

基於 Python 與 CrewAI（>= 1.14，無 LangChain 依賴）的自動化執行緒：

| 檔案 | 職責 |
|---|---|
| `factory.py` | 動態讀取 `docs/agent-skills/*-agent.md`，注入 `00-core-protocol.md` 為共用前言，喚醒 Agent 實例 |
| `main.py` | 接收人類需求，觸發 PM Agent 啟動流水線 |
| `requirements.txt` | 系統依賴（crewai, python-dotenv） |

### 3. 📁 實體工作區 (`workspace/`) — 產出

AI Agent 的唯一工作沙盒（gitignored，透過 `.gitkeep` 保留目錄結構）：

| 目錄 | 產出者 | 內容 |
|---|---|---|
| `architecture/` | SA (02) | 系統設計文件與資料庫 Schema |
| `design/` | UI (03) | 視覺規範與 Design Tokens |
| `history/` | Logger (99) | 開發日誌 (devlog) 與決策紀錄 |
| `src/` | Frontend (04) / Backend (05) | Agent 產出的原始碼 |

### 4. 🤖 AI CLI 整合層

讓不同 AI 編碼工具都能讀取本專案的規則與 Agent 定義：

| 路徑 | 用途 | 消費者 |
|---|---|---|
| `CLAUDE.md` | 專案指令（引用核心協議與 Git 規範） | Claude Code |
| `.claude/rules/` | 路徑限定規則（agent-skills、engine） | Claude Code |
| `AGENTS.md` | 專案結構與 Agent 清單 | OpenAI Codex / 通用 AI CLI |
| `.agents/skills/` | symlink → `docs/agent-skills/*-agent.md` | 任何支援該路徑的 AI 工具 |

---

## 🚀 快速啟動 (Quick Start)

所有操作透過 `Makefile` 作為唯一入口：

### 1. 設定環境變數

複製範本並填入你的 LLM API Key：

```bash
cp .env.example .env
# 編輯 .env，填入 OPENAI_API_KEY
```

### 2. 首次環境初始化

自動建立 Python venv 並安裝 CrewAI 依賴：

```bash
make setup
```

### 3. 同步 Agent 定義

更新 `docs/agent-skills/` 後，重建 `.agents/skills/` symlink：

```bash
make sync
```

### 4. 啟動 CrewAI 引擎

一鍵完成 setup → sync → 初始化策略 → 啟動流水線：

```bash
make run                # 預設使用 nextjs
make run FRAMEWORK=nuxt # 指定框架（nextjs | angular | nuxt）
```

> 完整指令清單：`make help`

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
│   │   ├── 00-core-protocol.md    #   全域憲法（非 Agent）
│   │   ├── 01-supervisor-agent.md #   主控 PM
│   │   ├── 02 ~ 99-*-agent.md    #   各職能 Agent
│   │   ├── strategies/            #   框架特化策略（非 Agent）
│   │   └── README.md              #   Agent 架構藍圖與流水線說明
│   └── policies/                  # 跨工具通用策略
│       └── git-workflow.md        #   Git 版本控制與 PR 規範
├── engine/                        # CrewAI 執行引擎
│   ├── factory.py
│   ├── main.py
│   └── requirements.txt
├── workspace/                     # Agent 執行期產出 (gitignored)
│   ├── architecture/              #   SA 規格書與 Schema
│   ├── design/                    #   UI 視覺規範
│   ├── history/                   #   開發日誌 (devlog)
│   └── src/                       #   Agent 產出的原始碼
├── .agents/                       # AI CLI 工具統一入口
│   └── skills/                    #   symlink → docs/agent-skills/*-agent.md
├── .claude/                       # Claude Code 規則
│   └── rules/                     #   路徑限定規則 (agent-skills, engine)
├── scripts/                       # Shell 腳本
│   ├── init-ai.sh                 #   技術策略初始化
│   └── mapper.sh                  #   Agent Skills symlink 建立
├── CLAUDE.md                      # Claude Code 專案指令
├── AGENTS.md                      # OpenAI Codex / 通用 AI CLI 指令
├── Makefile                       # 唯一操作入口（make help）
├── .env.example                   # 環境變數範本
└── .gitignore
```
