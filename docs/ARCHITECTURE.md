# 架構設計與設計理念

> 本文件說明 Charlie's AI Protocols 的架構決策與設計原則。
> 使用手冊請見 [README.md](../README.md)。

---

## 🎯 核心原則 — 單一事實來源、三消費者

所有 Agent 的定義**只寫一次、存在一處**（`docs/agent-skills/`），透過不同路徑同時服務三個消費者，互不干擾。

```
                    docs/agent-skills/ ← 單一事實來源 (SSOT)
                            │
           ┌────────────────┼────────────────┐
           │                │                │
  長名 (*-agent.md)    @file 引用      短名 (*.md alias)
  07-qa-agent.md       CLAUDE.md        qa.md
           │           .claude/rules/        │
           │                │                │
    factory.py glob    Claude Code      $skill 調用
           │                │                │
  ┌────────┴────────┐  直接讀取 SSOT   AI CLI (Codex/...)
  │   CrewAI 引擎   │  原始檔          BYOCLI 臨時調用
  │  全自動流水線    │
  └─────────────────┘
```

### 三消費者路徑

| 消費者 | 讀取來源 | 機制 | 需要 mapper？ |
|---|---|---|---|
| **CrewAI 引擎** | `docs/agent-skills/*-agent.md` | `factory.py` 直接 glob SSOT 原始檔 | 不需要 |
| **Claude Code** | `docs/agent-skills/*.md` + `.claude/rules/` | `CLAUDE.md` 用 `@` 引用；全域安裝時由 mapper 同步 rules | 僅全域安裝時需要 |
| **Codex / AI CLI** | `.agents/skills/` 同步入口 | `AGENTS.md` 的 `$skill` 映射表 | **需要**（`make sync` 或 `make install`） |

> **`scripts/mapper.sh` 主要負責同步 AI CLI 入口。**
> Codex 會使用 `.agents/skills/`，而 `make install` 也會順便同步 Claude 的 `~/.claude/rules/`。

### 為什麼 Claude Code 和 CrewAI 不需要 mapper？

**Claude Code** 有自己的原生機制：

- `CLAUDE.md` 透過 `@path` 語法直接引用 SSOT 原始檔（如 `@docs/agent-skills/00-core-protocol.md`），不需要 symlink 中介。
- `.claude/rules/*.md` 使用 `paths:` frontmatter 做路徑限定，當你編輯 `docs/agent-skills/` 或 `engine/` 下的檔案時，對應規則會自動載入。

也就是說，**Claude Code 的核心讀取機制不依賴 mapper**；但在 `make install` 的全域安裝情境下，mapper 仍會同步 `~/.claude/rules/`，讓 Claude 在其他 Repo 也能讀到同一套 Agent 規則。

**CrewAI 引擎** 的 `factory.py` 直接 glob `docs/agent-skills/*-agent.md`，在 Python 層完成檔案發現，同樣不依賴 symlink。

因此本地日常開發時，主要是 Codex 等外部 AI CLI 需要透過 mapper 建立 `.agents/skills/`；而全域安裝時，Codex 與 Claude 兩邊都會一起被同步。

---

## 🔗 長名與短名同步入口

`.agents/skills/` 中每個 Agent 都有兩個入口，由 `make sync`（`scripts/mapper.sh`）自動產生。預設會建立 symlink；若目前作業系統或權限不支援，才會 fallback 為 copy：

| 概念 | 命名規則 | 範例 | 消費者 |
|---|---|---|---|
| **長名 (Full Name)** | `{編號}-{角色}-agent.md` | `07-qa-agent.md` | CrewAI `factory.py`（glob `*-agent.md`） |
| **短名 (Alias)** | `{角色}.md`（去除編號與 `-agent`） | `qa.md` | Codex `$qa` 調用 |

在支援 symlink 的環境下，兩者會指向同一個 SSOT 原始檔，修改只需改一處：

```
.agents/skills/
├── 07-qa-agent.md  → ../../docs/agent-skills/07-qa-agent.md  ← factory.py 用
├── qa.md           → ../../docs/agent-skills/07-qa-agent.md  ← Codex $qa 用
└── .gitkeep
```

**為什麼不衝突？** `factory.py` 只 glob `*-agent.md`，短名 `qa.md` 不匹配，天然被排除。

---

## 🌐 雙層 Scope — 本地 vs 全域

Agent 技能可以安裝在兩個層級，Codex 啟動時依序載入並合併：

```
┌──────────────────────────────────────────────────────┐
│  User Scope（全域，跨所有 Repo）                      │
│  ~/.codex/AGENTS.md       ← 全域憲法與技能表          │
│  ~/.agents/skills/        ← 預設絕對路徑 symlink → SSOT│
│                                                      │
│  安裝：make install    移除：make uninstall           │
├──────────────────────────────────────────────────────┤
│  Project Scope（本地，僅限當前 Repo）                  │
│  ./AGENTS.md              ← 專案專屬指令（可覆寫全域）│
│  ./.agents/skills/        ← 預設相對路徑 symlink → SSOT│
│                                                      │
│  安裝：make sync                                     │
└──────────────────────────────────────────────────────┘

載入順序：User Scope → Project Scope（後者覆寫前者）
```

| 比較 | 本地（`make sync`） | 全域（`make install`） |
|---|---|---|
| 目標路徑 | `./.agents/skills/` | `~/.agents/skills/` |
| 預設同步型態 | 相對路徑 symlink | 絕對路徑 symlink |
| 額外產出 | 無 | `~/.codex/AGENTS.md` |
| 作用範圍 | 僅限此 Repo | 電腦上所有 Repo |
| 覆寫機制 | 覆寫全域同名技能 | 被專案層覆寫 |

> 若遇到 Windows Bash / Git Bash 無法建立 symlink 的環境，mapper 會自動改以 copy 同步；若你要強制失敗而不是 fallback，可設定 `CAP_LINK_MODE=symlink`。

### 典型使用情境

- **只用這個 Repo**：`make sync` 即可。
- **跨 Repo 共用大腦**：先 `make install`，新 Repo 無需任何設定就能使用 `$qa`、`$security` 等技能。
- **專案有特殊規則**：在新 Repo 建立自己的 `AGENTS.md`，Codex 會自動合併全域 + 專案層。

---

## 🏛 三層架構 (The 3-Tier Architecture)

系統分為「大腦、引擎、沙盒」三大物理隔離層，確保 AI 在開發過程中不會發生邏輯污染：

### 1. 🧠 代理技能庫 (`docs/agent-skills/`) — 大腦

存放所有 Agent 的 **System Prompts**，是系統的 SSOT。

> Agent 編號是穩定 ID；下表的分組僅描述責任歸屬，不代表實際接手順序。若要理解流水線，請看後面的「典型交付順序」。

| 分組 | Agent | 職責 |
|---|---|---|
| **管理組** | 01 Supervisor, 90 Watcher, 99 Logger | 調度、門禁稽核、日誌紀錄 |
| **開發組** | 02 Tech Lead, 02a BA, 02b DBA/API, 03 UI, 12 Figma, 09 Analytics, 04 Frontend, 05 Backend | 技術評估、業務分析、DB/API 設計、設計資產、分析規格、前後端實作 |
| **維運組** | 08 Security, 07 QA, 10 Troubleshoot, 11 SRE, 06 DevOps | 資安審查、測試驗證、故障診斷、可靠性優化、CI/CD |

- **策略庫 (`strategies/`)**: 存放特定框架與工具的戰術執行細節（如 `frontend-nextjs.md`、`backend-dotnet.md`、`qa-playwright.md`、`lighthouse-audit.md`）。
- **統一入口 (`.agents/skills/`)**: 透過 `scripts/mapper.sh` 建立的同步入口，預設為 symlink，必要時才 fallback 為 copy，讓任何 AI CLI 工具可從固定路徑讀取 Agent 定義。

### 1.1 典型交付順序

| 典型位置 | 穩定 ID | Agent | 說明 |
|---|---|---|---|
| 入口 | 01 | Supervisor | 需求拆解、發派與品質門禁 |
| 1 | 02 | Tech Lead | 技術評估與 TechPlan |
| 2 | 02a | BA | 業務流程與規則邊界 |
| 3 | 02b | DBA/API | Schema SSOT 與 API 契約 |
| 4 | 03 | UI | 第一層設計資產 |
| 5 | 12 | Figma | 第二層設計檔同步 |
| 6 | 09 | Analytics | KPI、埋點、實驗設計 |
| 7 | 04 | Frontend | UI 實作與前端單元測試 |
| 8 | 05 | Backend | API / Domain 實作與後端單元測試 |
| 9 | 90 + 08 | Watcher + Security | 橫向規格稽核與資安掃描 |
| 10 | 07 | QA | 功能驗證與壓力測試 |
| 11 | 10 | Troubleshoot | 根因診斷與修復建議，正式派發回交 01 |
| 12 | 11 | SRE | 效能 / 可靠性深度優化 |
| 13 | 06 | DevOps | 容器化、CI/CD、部署交付 |
| 歸檔 | 99 | Logger | Changelog 與 devlog 紀錄 |

### 2. ⚙️ 核心引擎 (`engine/`) — 肉體

基於 Python 與 CrewAI（>= 1.14，無 LangChain 依賴）的自動化執行緒：

| 檔案 | 職責 |
|---|---|
| `factory.py` | 動態讀取 `*-agent.md`，注入 `00-core-protocol.md` 為共用前言，喚醒 Agent 實例 |
| `main.py` | 接收人類需求，觸發 PM Agent 啟動流水線 |
| `requirements.txt` | 系統依賴（crewai, python-dotenv） |

### 3. 📁 實體工作區 (`workspace/`) — 產出

AI Agent 的唯一工作沙盒（gitignored，透過 `.gitkeep` 保留目錄結構）：

| 目錄 | 產出者 | 內容 |
|---|---|---|
| `history/` | Logger (99) | 開發日誌 (devlog) 與決策紀錄 |
| `src/` | Frontend (04) / Backend (05) | Agent 產出的原始碼 |

### 3.1 規格文件目錄 (`docs/`) — 專案事實來源

專案規格文件不放在 `workspace/`，而是維持在可追蹤的 `docs/` 路徑：

| 目錄 | 產出者 | 內容 |
|---|---|---|
| `docs/architecture/` | Tech Lead (02), BA (02a), DBA/API (02b), Analytics (09) | TechPlan、業務流程、API 規格、Analytics 規格 |
| `docs/architecture/database/` | DBA/API (02b), SRE (11) | 資料庫事實檔案 (Schema SSOT) 與索引維護 |
| `docs/design/` | UI (03) | UI/UX 設計規格與 Design Tokens |

### 4. 🤖 AI CLI 整合層

讓不同 AI 編碼工具都能讀取本專案的規則與 Agent 定義：

| 路徑 | 用途 | 消費者 |
|---|---|---|
| `CLAUDE.md` | 專案指令（`@` 引用核心協議與 Git 規範） | Claude Code |
| `.claude/rules/` | 路徑限定規則（agent-skills、engine） | Claude Code |
| `AGENTS.md` | 專案結構與 Agent 清單 | OpenAI Codex / 通用 AI CLI |
| `.agents/skills/` | 長名 + 短名同步入口，預設 symlink → SSOT | 任何支援該路徑的 AI 工具 |

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
                              PASS ─┤─ FAIL → [10 Troubleshoot] 根因診斷
                                    │                       │
                                    │                       └─→ 效能 / 可靠性議題 → [11 SRE]
                                    │
                                    ▼
                            [09 Analytics] 埋點 / 實驗檢視
                                    │
                                    ▼
                           [06 DevOps] 佈署交付
                                    │
                                    ▼
                          [99 Logger] 歸檔
                          CHANGELOG + devlog
```

- **任一環節 FAIL**：PM 強制產生修復交接單退回原實作 Agent，修復後重新走完整流程。
- **全數 PASS**：Logger 寫入 `CHANGELOG.md` 並存檔至 `workspace/history/`，准予進入下一模組。

---

## 🏗 DDD 整合策略與演進路線 (DDD Integration Strategy)

### 現狀 (v0.2.0)

v0.2.0 將 DDD 戰術模式（Tactical Patterns）注入四個核心 Agent 的規範中，但**不改變既有流水線順序**：

| Agent | 新增規範 |
|---|---|
| **BA (02a)** | Bounded Context 識別、領域語彙表 (Ubiquitous Language)、跨 Context 互動定義 |
| **DBA/API (02b)** | Schema 標示 Aggregate Root / Entity / Value Object；禁止繞過聚合根的寫入 API |
| **Backend (05)** | Aggregate Root 守門、Value Object 不變式、Domain Event 協調 |
| **Watcher (90)** | Bounded Context 邊界、語彙一致性、聚合邊界、Value Object、Domain Event 稽核項目 |

### 刻意保留的設計約束：DTO ↔ Schema 100% 對齊

`02b-dba-api-agent.md` §2.2 與 `05-backend-agent.md` §5 仍強制 API DTO 欄位名稱與資料庫 Schema 完全一致。這與典型 DDD 中三層獨立模型（`API DTO ≠ Domain Model ≠ Persistence Entity`）的解耦精神有所偏離，但屬刻意決策：

1. **機械可驗證性優先**：Watcher (90) 的核心稽核能力建立在「欄位名逐一比對」之上。若解耦為三層獨立模型，Watcher 需判斷語意等價性（如 `userName` ↔ `name` ↔ `user_name`），這對 AI Agent 的容錯率過低。
2. **上下文傳遞成本**：BA → DBA → Backend 的交接鏈中，每一環靠 Markdown 文件傳遞。三層解耦會額外增加一份 Domain Model 規格的交接負擔，提高 Agent 間上下文對齊的失誤機率。

> **設計原則**：在 AI Agent 體系中，機械可驗證性 > 語意靈活性。護欄的價值在於讓自動化稽核可靠運作。

### 演進觸發條件

當實際專案出現以下情境時，可針對性鬆綁，方向為 **CQRS 漸進式引入**——寫入面保持嚴格對齊，讀取面逐步放寬：

| 觸發條件 | 演進動作 |
|---|---|
| API 需回傳跨表聚合資料（DTO 無法 1:1 對應 Schema） | 允許 **Read DTO** 與 Schema 解耦，Write DTO 仍強制對齊 Aggregate Root 命令介面 |
| 前端需要 BFF 層組合 API | 在 02b API 規格中區分 `Command DTO`（強制對齊）與 `Query DTO`（允許投影） |
| 跨模組事件流複雜化，單一 Schema 無法涵蓋 | 引入 Anti-Corruption Layer 規範，Watcher 新增「語意映射表」稽核 |
