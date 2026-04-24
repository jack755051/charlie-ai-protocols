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

> 若要看 CAP 下一階段如何從「固定 workflow 執行器」演進到「task-scoped workflow compiler」，請參考 [`TASK-SCOPED-WORKFLOW-COMPILER-DRAFT.md`](./TASK-SCOPED-WORKFLOW-COMPILER-DRAFT.md)。

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

---

## 🏛 三層架構 (The 3-Tier Architecture)

系統分為「大腦、引擎、沙盒」三大物理隔離層，確保 AI 在開發過程中不會發生邏輯污染：

### 1. 🧠 代理技能庫 (`docs/agent-skills/`) — 大腦

存放所有 Agent 的 **System Prompts**，是系統的 SSOT。

> Agent 完整清單與典型交付順序見 [README.md](../README.md#-agent-一覽)。
> 流水線步驟定義見 [`schemas/workflows/feature-delivery.yaml`](../schemas/workflows/feature-delivery.yaml)。

- **策略庫 (`strategies/`)**: 存放特定框架與工具的戰術執行細節（如 `frontend-nextjs.md`、`backend-dotnet.md`、`qa-playwright.md`、`lighthouse-audit.md`）。
- **統一入口 (`.agents/skills/`)**: 透過 `scripts/mapper.sh` 建立的同步入口，預設為 symlink，必要時才 fallback 為 copy，讓任何 AI CLI 工具可從固定路徑讀取 Agent 定義。

### 2. ⚙️ 核心引擎 (`engine/`) — 肉體

基於 Python 與 CrewAI（>= 1.14，無 LangChain 依賴）的自動化執行緒：

| 檔案 | 職責 |
|---|---|
| `factory.py` | 動態讀取 `*-agent.md`，注入 `00-core-protocol.md` 為共用前言，喚醒 Agent 實例 |
| `workflow_loader.py` | 載入 workflow YAML，解析 capability 契約，建構 semantic plan；舊版 agent binding loader 僅作相容保留 |
| `runtime_binder.py` | workflow runtime 的正式 binding 層；將 semantic plan 綁定到 `.cap.skills.yaml` 或 `.cap.agents.json` legacy adapter，輸出 bound execution plan |
| `task_scoped_compiler.py` | 從一句話需求產出 task constitution、capability graph、unresolved policy，並編譯最小 workflow |
| `main.py` | 接收人類需求，觸發 PM Agent 啟動流水線 |
| `requirements.txt` | 系統依賴（crewai, python-dotenv） |

### 3. 📁 本機執行儲存區 (`~/.cap/projects/<project_id>/`) — 預設產出

CAP 預設將執行期資料寫入本機儲存區，而不是 repo 內的暫存資料夾：

| 目錄 | 產出者 | 內容 |
|---|---|---|
| `constitutions/` | `cap workflow constitution / compile / run-task` | task constitution snapshot |
| `compiled-workflows/` | `task_scoped_compiler.py`, `cap workflow compile / run-task` | task-scoped compiled workflow bundle、candidate workflow、bound plan |
| `bindings/` | `RuntimeBinder`, `cap workflow bind / run / run-task` | binding report snapshot 與 registry 決策留痕 |
| `traces/` | CLI Wrapper / Logger (99) | Session trace、jsonl 軌跡、簡要執行紀錄 |
| `reports/` | Logger (99), QA (07), Analytics (09) | devlog、Lighthouse、Analytics、稽核報告 |
| `drafts/` | 各 Agent | 中間草稿與一次性交付 |
| `handoffs/` | Supervisor (01), Troubleshoot (10) | 任務交接單、修復建議單 |
| `sessions/` | CLI / 未來 GUI / OpenClaw | 執行 session state |

### 3.1 規格文件目錄 (`docs/`) — 專案事實來源

專案規格文件不放在本機 CAP storage，而是維持在可追蹤的 `docs/` 路徑：

| 目錄 | 產出者 | 內容 |
|---|---|---|
| `docs/architecture/` | Tech Lead (02), BA (02a), DBA/API (02b), Analytics (09) | TechPlan、業務流程、API 規格、Analytics 規格 |
| `docs/architecture/database/` | DBA/API (02b), SRE (11) | 資料庫事實檔案 (Schema SSOT) 與索引維護 |
| `docs/design/` | UI (03) | UI/UX 設計規格與 Design Tokens |

### 3.2 Template Workflow vs Runtime Workflow

- `schemas/workflows/*.yaml`
  - 只放 **內建模板 workflow**
  - 由 repo 版本控制，作為固定流程範本、fallback 與測試資料
- `~/.cap/projects/<project_id>/compiled-workflows/`
  - 放 **task-scoped compiled workflow**
  - 屬於 runtime 產物，不應回寫到主 repo
- `~/.cap/projects/<project_id>/constitutions/`
  - 放任務憲法快照
- `~/.cap/projects/<project_id>/bindings/`
  - 放 binding snapshot 與 registry 決策紀錄

結論是：主程式 repo 負責模板、schema、driver、engine；單次任務的 execution workspace 應進 `.cap`。

---

## 📋 Registry 與 Capability 職責分工

系統的機器可讀契約分為四層，各司其職：

| 檔案 | 職責 | Runtime 讀取者 |
|---|---|---|
| `schemas/capabilities.yaml` | Capability 契約 SSOT：語意描述、預設 agent、允許 agent、inputs/outputs、完成條件 | `workflow_loader.py`、`runtime_binder.py` |
| `schemas/task-constitution.schema.yaml` | task-scoped workflow compiler 的任務憲法結構 | `task_scoped_compiler.py` |
| `schemas/workflow-run-state.schema.yaml` | executor 執行期 step state / blocked reason 結構 | `cap-workflow-exec.sh` |
| `.cap.skills.yaml` | workflow binding 的優先輸入：capability → skill / agent_alias / prompt_file / cli / fallback policy | `runtime_binder.py` |
| `.cap.agents.json` | agent alias 相容層：alias → prompt_file / provider / cli；`.cap.skills.yaml` 缺席時由 legacy adapter 轉接 | `runtime_binder.py`、`cap-registry.sh` |
| `schemas/workflows/*.yaml` | 流程編排模板：step 順序、依賴、失敗路由、品質門禁 | `workflow_loader.py`、`runtime_binder.py` |
| `schemas/handoff-ticket.schema.yaml` | 任務交接單結構化 schema | Agent prompts（引用） |

### 正式與 Draft 路徑

- **正式 workflow binding / runtime**
  - `runtime_binder.py`
  - `cap workflow plan`
  - `cap workflow bind`
  - `cap workflow run`
  - `cap-workflow-exec.sh` 消費 `RuntimeBinder.build_bound_execution_phases()` 的輸出
- **正式相容層**
  - `.cap.agents.json`
  - legacy adapter（當 `.cap.skills.yaml` 缺席時自動轉接）
- **draft / 下一階段**
  - `.cap.skills.yaml`
  - `schemas/skill-manifest.schema.yaml`
  - `schemas/skill-registry.schema.yaml`
  - `schemas/unresolved-binding.schema.yaml`
  - skill marketplace 與 LangGraph backend

> 品質門禁的完整定義見 [`schemas/workflows/feature-delivery.yaml`](../schemas/workflows/feature-delivery.yaml)。

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
