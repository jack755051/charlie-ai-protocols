# 架構設計與設計理念

> 本文件說明 Charlie's AI Protocols 的架構決策與設計原則。
>
> **導覽**：使用手冊看 [README.md](../../README.md)；目前實作進度看 [MISSING-IMPLEMENTATION-CHECKLIST.md](MISSING-IMPLEMENTATION-CHECKLIST.md)；其他工程文件入口看 [docs/cap/README.md](README.md)。
>
> **跨模組邊界**：要動 capability、storage layout、執行流程之前，請先讀對應 boundary memo（[CONSTITUTION-BOUNDARY.md](CONSTITUTION-BOUNDARY.md) / [SUPERVISOR-ORCHESTRATION-BOUNDARY.md](SUPERVISOR-ORCHESTRATION-BOUNDARY.md) / [ORCHESTRATION-STORAGE-BOUNDARY.md](ORCHESTRATION-STORAGE-BOUNDARY.md) / [EXECUTION-LAYERING.md](EXECUTION-LAYERING.md)）。本文件涵蓋整體架構，不重複 boundary 細節。

---

## 🎯 核心原則 — 單一事實來源、三消費者

所有 Agent 的定義**只寫一次、存在一處**（`agent-skills/`），透過不同路徑同時服務三個消費者，互不干擾。

```
                    agent-skills/ ← 單一事實來源 (SSOT)
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
| **CrewAI 引擎** | `agent-skills/*-agent.md` | `factory.py` 直接 glob SSOT 原始檔 | 不需要 |
| **Claude Code** | `agent-skills/*.md` + `.claude/rules/` | `CLAUDE.md` 用 `@` 引用；全域安裝時由 mapper 同步 rules | 僅全域安裝時需要 |
| **Codex / AI CLI** | `.agents/skills/` 同步入口 | `AGENTS.md` 的 `$skill` 映射表 | **需要**（`make sync` 或 `make install`） |

> **`scripts/mapper.sh` 主要負責同步 AI CLI 入口。**
> Codex 會使用 `.agents/skills/`，而 `make install` 也會順便同步 Claude 的 `~/.claude/rules/`。

### 為什麼 Claude Code 和 CrewAI 不需要 mapper？

**Claude Code** 有自己的原生機制：

- `CLAUDE.md` 透過 `@path` 語法直接引用 SSOT 原始檔（如 `@agent-skills/00-core-protocol.md`），不需要 symlink 中介。
- `.claude/rules/*.md` 使用 `paths:` frontmatter 做路徑限定，當你編輯 `agent-skills/` 或 `engine/` 下的檔案時，對應規則會自動載入。

也就是說，**Claude Code 的核心讀取機制不依賴 mapper**；但在 `make install` 的全域安裝情境下，mapper 仍會同步 `~/.claude/rules/`，讓 Claude 在其他 Repo 也能讀到同一套 Agent 規則。

**CrewAI 引擎** 的 `factory.py` 直接 glob `agent-skills/*-agent.md`，在 Python 層完成檔案發現，同樣不依賴 symlink。

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
├── 07-qa-agent.md  → ../../agent-skills/07-qa-agent.md  ← factory.py 用
├── qa.md           → ../../agent-skills/07-qa-agent.md  ← Codex $qa 用
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

### 1. 🧠 代理技能庫 (`agent-skills/`) — 大腦

存放所有 Agent 的 **System Prompts**，是系統的 SSOT。

> Agent 完整清單與典型交付順序見 [README.md](../../README.md#-agent-一覽)。
> 流水線步驟定義見 [workflows/README.md](../../workflows/README.md) 與 `schemas/workflows/` 現役模板。

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
| `reports/` | Workflow executor, Logger (99), QA (07), Analytics (09) | workflow artifacts、handoff、runtime-state、agent-sessions、result report、devlog、Lighthouse、Analytics、稽核報告 |
| `drafts/` | 各 Agent | 中間草稿與一次性交付 |
| `handoffs/` | Supervisor (01), Troubleshoot (10) | 任務交接單、修復建議單 |
| `sessions/` | CLI / 未來 GUI / OpenClaw | 執行 session state |

### 3.1 說明文件目錄 (`docs/`) — 平台文件

CAP repo 的 `docs/` 保留平台級說明文件，不再承載 agent prompt、治理 policy 或 workflow 說明。這些可被 runtime 或 agent 直接消費的資產已提升到 repo 根目錄：

| 目錄 | 產出者 | 內容 |
|---|---|---|
| `docs/cap/` | CAP 維護者 | 平台架構、目標、roadmap、執行分層與 skill runtime 說明 |
| `agent-skills/` | CAP runtime / agent | 角色 prompt 與策略規範 |
| `policies/` | CAP runtime / agent | 跨工具治理規則 |
| `workflows/` | CAP 維護者 / agent | workflow 人讀說明與 memo |

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

### 3.3 方法論接入層（外部技能包）

CAP 的核心不是某一套特定方法論，而是能把不同方法論收斂到同一套治理模型與 runtime。

這表示：

- 外部方法論包可以被引入，但應映射成 CAP 的 `capability` / `workflow` / `policy`，而不是直接取代既有角色與 binding 結構
- `superpowers` 這類套件比較適合被當作「功能導向 workflow pack」：例如 brainstorming、planning、execution、review、TDD
- CAP 內部的 `agent-skills/` 仍維持角色與職責 SSOT；功能層由 `schemas/capabilities.yaml` 與 `schemas/workflows/` 承擔
- 若要接入外部方法論，優先新增對應 workflow / capability，再由 roadmap 決定是否提供專用命令入口

這種設計的好處是：

1. 保留 CAP 的憲章、binding 與 runtime storage 一致性
2. 不破壞既有角色與能力契約
3. 外部方法論可以逐步接入，不必一次性重構核心

### 3.4 說明文件命名準則

核心說明文件優先採大寫檔名，以便區分正式架構文件與一般流程文件：

- `docs/cap/ARCHITECTURE.md`
- `docs/cap/IMPLEMENTATION-ROADMAP.md`
- `docs/cap/PLATFORM-GOAL.md`
- `docs/cap/SKILL-RUNTIME-ARCHITECTURE.md`

`agent-skills/`、`policies/` 與 `workflows/` 不是純說明文件，因此不再放入 `docs/`。它們可維持語義化小寫檔名，因為這些路徑會被 scripts、CLAUDE/Codex 入口、workflow 註解與 policy 引用。

---

## 📋 Registry 與 Capability 職責分工

系統的機器可讀契約分為四層，各司其職：

| 檔案 | 職責 | Runtime 讀取者 |
|---|---|---|
| `schemas/capabilities.yaml` | Capability 契約 SSOT：語意描述、預設 agent、允許 agent、inputs/outputs、完成條件 | `workflow_loader.py`、`runtime_binder.py` |
| `schemas/project-constitution.schema.yaml` | repo 長期治理憲法的最小結構 | Project Constitution runner / future validator |
| `schemas/task-constitution.schema.yaml` | task-scoped workflow compiler 的任務憲法結構 | `task_scoped_compiler.py` |
| `schemas/agent-session.schema.yaml` | 一次性 CAP agent session 的 runtime ledger 結構 | `step_runtime.py`、`cap-workflow-exec.sh` |
| `.cap.skills.yaml` | workflow binding 的優先輸入：capability → skill / agent_alias / prompt_file / cli / fallback policy | `runtime_binder.py` |
| `.cap.agents.json` | agent alias 相容層：alias → prompt_file / provider / cli；`.cap.skills.yaml` 缺席時由 legacy adapter 轉接 | `runtime_binder.py`、`cap-registry.sh` |
| `schemas/workflows/*.yaml` | 流程編排模板：step 順序、依賴、失敗路由、品質門禁 | `workflow_loader.py`、`runtime_binder.py` |
| Handoff Ticket 欄位 | 交接單欄位語意參考（見本文「Handoff Ticket 欄位參考」段落） | Agent prompts（引用） |

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
  - `schemas/skill-registry.schema.yaml`（v2，含原 manifest 欄位）
  - skill marketplace 與 LangGraph backend

> 品質門禁與 phase 定義以 `schemas/workflows/` 現役模板為準；目前主要收斂在 `version-control.yaml`、`readme-to-devops.yaml` 與 `workflow-smoke-test.yaml`。

### Handoff Ticket 欄位參考

Handoff ticket（Type C 派工單）是 supervisor 派工給單一 sub-agent step 的結構化工作單。**自 v0.19.x 起已由 deterministic shell executor `scripts/workflows/emit-handoff-ticket.sh` 實例化**，落地於 `~/.cap/projects/<id>/handoffs/<step_id>.ticket.json`；engine `step_runtime` 自動 ticket emission hook 與 sub-agent 端的 ticket consumption end-to-end 仍待完整 e2e 驗證。權威結構契約見 `schemas/handoff-ticket.schema.yaml`（v0.19.x 重新升級為一級 SSOT，不再是概念參考）。核心欄位：

| 欄位 | 說明 |
|---|---|
| `ticket_id` | `<task_id>-<step_id>-<seq>` 格式；同 step 重跑時 seq 遞增 |
| `task_id` / `step_id` | 對應 task constitution 與 execution_plan 條目 |
| `target_capability` | 此任務所需的 capability |
| `task_objective` | 精確描述任務範圍 |
| `rules_to_load` | 應掛載的 agent-skills、core_protocol、strategies、policies 路徑 |
| `context_payload` | 含 project_constitution_path、task_constitution_path、上游 handoff summaries（summary-first）、必要時的 upstream full artifacts |
| `acceptance_criteria` | 完成條件（映射自 capability done_when + step 補強） |
| `output_expectations` | 含 primary_artifacts 與 handoff_summary_path（Type D 落地點） |
| `governance` | watcher / security / logger 介入要求 |
| `failure_routing` | on_fail / route_back_to_step / max_retries |
| `created_at` / `created_by` | bookkeeping |

> 派工流程：supervisor 透過 `01-supervisor-agent.md` §3.6「Type C Handoff Ticket 發行協議」組裝 ticket → `scripts/workflows/emit-handoff-ticket.sh` 寫入磁碟 → sub-agent 依 `policies/handoff-ticket-protocol.md` 讀 ticket、執行、寫出 Type D handoff summary（路徑見 ticket 的 `output_expectations.handoff_summary_path`）。

---

## ⚙️ Executor Watchdog

`cap-workflow-exec.sh` 的監控機制，防止 step 卡死或無限消耗 token。

### 已實作功能

| 功能 | 說明 |
|---|---|
| Spinner 即時預覽 | 顯示最新輸出行、接收位元數、section 進度 |
| 硬性 timeout | step 超過上限自動 kill（預設 600s） |
| 靜默偵測 (stall) | 輸出檔連續 N 秒無新增內容視為疑似卡住（預設 120s） |
| Artifact 持久化 | 每個 step 的完整輸出保存到 CAP storage |
| Runtime state | `runtime-state.json` 追蹤每個 step 的 execution_state |

### 環境變數

| 變數 | 預設 | 說明 |
|---|---|---|
| `CAP_WORKFLOW_STEP_TIMEOUT_SECONDS` | `600` | 全域 step 硬性上限 |
| `CAP_WORKFLOW_STEP_STALL_SECONDS` | `120` | 全域 step 靜默上限 |
| `CAP_WORKFLOW_STALL_ACTION` | `warn` | 靜默達上限時 `warn` 或 `kill` |

### 職責邊界

| 層級 | 負責什麼 | 由誰執行 |
|---|---|---|
| 即時預覽 + timeout + stall | process 存活監控 | `cap-workflow-exec.sh` |
| 產出品質檢查 | 結果正確性稽核 | Watcher (90) governance checkpoint |

> Watcher 是事後稽核者，不做即時 process 監控。

---

## 🔧 Task-Scoped Workflow Compiler

從一句話需求動態產生最小可執行 workflow，而非先選固定模板再硬跑。

### 執行流程

```
一句話需求 → Task Constitution → Capability Graph → Skill Binding
→ Unresolved Policy → Compiled Workflow → Execution
```

### 核心物件

| 物件 | 說明 | 儲存位置 |
|---|---|---|
| Task Constitution | 任務目標、範圍、非目標、成功條件、風險 | `~/.cap/.../constitutions/` |
| Capability Graph | 從憲法推導的能力依賴圖 | 編譯中間產物 |
| Binding Report | capability → skill 綁定結果（ready/degraded/blocked） | `~/.cap/.../bindings/` |
| Compiled Workflow | 本次真正要跑的最小 workflow | `~/.cap/.../compiled-workflows/` |

### CLI 指令

```bash
cap task constitution "用 Tauri 做個小工具"          # 只產出任務憲章（取代 cap workflow constitution）
cap workflow compile "用 Tauri 做個小工具"           # 編譯最小 workflow
cap workflow run-task "用 Tauri 做個小工具"          # 編譯並執行
cap workflow run-task --dry-run "用 Tauri 做個小工具" # 只顯示編譯結果
```

> ⚠️ `cap workflow constitution` 自 P2 #6 起 **deprecated**，行為與 exit code 不變但會在 stderr emit `[deprecated]` 提示；新代碼一律改用 `cap task constitution`。可設 `CAP_DEPRECATION_SILENT=1` 抑制過渡期警告。

### 與固定 workflow 的關係

- **固定 workflow**（`schemas/workflows/*.yaml`）：團隊已知流程、高重複性工作
- **Compiled workflow**：新需求、不確定是否需要完整流程、skill 可用性變動

兩者雙軌並存，不互相取代。

---

## 🪪 Constitution Command Boundary

CAP 在 v0.21+ 將 "constitution" 一詞的雙語意拆清：

- **Project Constitution** — repo 級長期治理憲章。命令家族：`cap project constitution ...`。落地在 `<repo>/.cap.constitution.yaml`（SSOT）+ `~/.cap/projects/<id>/constitutions/project/<stamp>/` 4 件套 snapshot。
- **Task Constitution** — 單次任務憲章。命令家族：`cap task constitution`（正式名稱）/ `cap workflow constitution`（deprecated alias）。落地在 `~/.cap/projects/<id>/constitutions/constitution-<stamp>.json`（不寫 repo）。

兩者 schema、storage 層、capability 都已分流；唯一的歷史包袱是 CLI 命名（`cap workflow constitution` 字面像 project 但實際 task）。P2 #6 已透過 alias + deprecation 收斂這條線。

### Mini 對照表

| Command | 屬於 | 用途 | 是否寫 repo SSOT |
|---|---|---|---|
| `cap project constitution --prompt` / `--from-file` | Project | 產出或匯入 4 件套 snapshot | ✗（需 `--promote`）|
| `cap project constitution --promote STAMP` / `--latest` | Project | 把 valid snapshot 寫回 `.cap.constitution.yaml` | ✓（覆寫前自動備份）|
| `cap task constitution "<prompt>"` | Task | 產出任務憲章 JSON | ✗ |
| `cap workflow constitution "<prompt>"` ⚠️ deprecated | Task | 同上；保留行為但 emit deprecation warning | ✗ |
| `cap workflow compile "<prompt>"` | Task | 任務憲章 + capability graph + compiled workflow + binding | ✗ |
| `cap workflow run-task "<prompt>"` | Task | compile + 執行 | ✗（除非 workflow step 寫）|

完整 6-command mapping、5-surface（CLI / workflow / capability / schema / storage）邊界與 storage layout 規則，以 [`docs/cap/CONSTITUTION-BOUNDARY.md`](./CONSTITUTION-BOUNDARY.md) §5（差異對照表）與 §4.5（storage layout）為單一事實來源。本章節故意不複製完整內容，避免雙寫漂移。

### 命令選擇 cheat sheet

- 設專案長期治理規則 → `cap project constitution`
- 把單一 prompt 拆解成任務憲章草稿 → `cap task constitution`（不要再用 `cap workflow constitution`）
- 把 prompt 變成可跑的 workflow → `cap workflow run-task`
- 跑既有 fixed workflow → `cap workflow run <id>`

---

## 🎼 Supervisor Orchestration

P3 系列把 supervisor 對單一 prompt 的「整體結構化決策」固化成 Supervisor Orchestration Envelope，並沿著 producer → schema → runtime gate → snapshot → compile 的鏈路把 envelope 接進 CAP 的執行基礎建設。**目前已落地的是 envelope flow 的「驗證 + 結構化資料路由」半邊；runtime dispatcher（step 失敗時實際 halt / retry / route_back / escalate）尚未接通**，屬 P5 AgentSessionRunner 範疇 — 不要把現況讀成「supervisor 能控制 runtime 的 retry 策略」。

### Envelope flow 現況

```text
supervisor sub-agent  →  envelope JSON (fence-wrapped)
                               │
                               ▼
                  validate-supervisor-envelope.sh  (schema-class executor, exit 41 on fail)
                               │
                               ▼
                  engine.supervisor_envelope helpers
                  ├─ extract_envelope            (fence parse)
                  ├─ validate_envelope           (jsonschema + drift baseline)
                  ├─ check_envelope_drift        (envelope vs task_constitution)
                  ├─ check_failure_routing_xrefs (failure_routing → graph node id)
                  └─ resolve_failure_routing     (per-step routing 對應表)
                               │
            ┌──────────────────┴──────────────────┐
            ▼                                     ▼
  engine.orchestration_snapshot           engine.task_scoped_compiler
  └─ write_snapshot                       └─ compile_task_from_envelope
     four-part on disk                       envelope-driven compile path
     (envelope.json / .md /                  + failure_routing_resolved
      validation.json / source-prompt.txt)   + compile_hints_applied
                                                │
                                                ▼
                               ⚠ runtime dispatcher (P5 territory, NOT yet wired)
                                  - actual halt / retry / route_back / escalate
                                  - per-step ticket failure_routing injection
                                  - workflow YAML wiring beyond the minimal
                                    supervisor-orchestration.yaml binding test
```

### P3 已落地的 commit 一覽

| 階段 | 內容 | 主要 commit |
|---|---|---|
| P3 #1 | Boundary memo（5-surface 切分）| `e81a203` (`docs/cap/SUPERVISOR-ORCHESTRATION-BOUNDARY.md`) |
| P3 #2 | Schema tightening（envelope `failure_routing` required） | `619e913` |
| P3 #3 | Producer 規範（`agent-skills/01-supervisor-agent.md` §3.8）+ envelope helpers | `4bf13a0` |
| P3 #4 | Runtime validation hook（schema-class shell executor + capability） | `d7e5358` |
| P3 #5 boundary memo | Storage / compile-bind transition 邊界 | `4e3b4b1` (`docs/cap/ORCHESTRATION-STORAGE-BOUNDARY.md`) |
| P3 #5-a | Storage writer（four-part snapshot 模組）| `0adc2da` |
| P3 #5-b | Compile entry（`compile_task_from_envelope`） | `79bfc88` |
| P3 #5-c | Workflow YAML wire（minimal binding test） | `6acb9a8` |
| P3 #6 | Failure routing resolver + xref + compile entry gate | `e9b5b05` |

### Module map（agent 查 repo 時先看這裡，不要全 repo grep）

| Path | 職責 |
|---|---|
| [`engine/supervisor_envelope.py`](../../engine/supervisor_envelope.py) | Envelope helpers：`extract_envelope` / `validate_envelope` / `check_envelope_drift` / `check_failure_routing_xrefs` / `resolve_failure_routing` + CLI（`extract` / `validate` / `drift` / `xref` / `resolve` 五 subcommand）。Pure helpers，無 I/O 副作用以外的 disk write，是 envelope 操作的 SSOT |
| [`engine/orchestration_snapshot.py`](../../engine/orchestration_snapshot.py) | Four-part snapshot writer：`write_snapshot` 寫 `~/.cap/projects/<id>/orchestrations/<stamp>/` 下 `envelope.json` / `envelope.md` / `validation.json` / `source-prompt.txt`，validation fail 仍落地（doctor / status 觀察 partial state） |
| [`engine/task_scoped_compiler.py`](../../engine/task_scoped_compiler.py) | 雙路徑 compile：legacy `compile_task(source_request)` 永久保留 + 新 `compile_task_from_envelope(envelope)`（入口跑 schema validate + drift + xref 三 gate；output dict 9 keys 含 `failure_routing_resolved` / `compile_hints_applied`） |
| [`scripts/workflows/validate-supervisor-envelope.sh`](../../scripts/workflows/validate-supervisor-envelope.sh) | Schema-class executor wrapper，委派 `engine.supervisor_envelope` 三 stage（extract / validate / drift），任一失敗 exit 41（對齊 `policies/workflow-executor-exit-codes.md` schema-class 政策）。**Pure thin wrapper — 不重寫 Python domain logic** |
| [`schemas/workflows/supervisor-orchestration.yaml`](../../schemas/workflows/supervisor-orchestration.yaml) | Minimal binding workflow：單一 step `validate_supervisor_envelope` 引用 `supervisor_envelope_validation` capability。P3 #5-c 的 wiring smoke 對象 — 不接 storage / compile / failure routing dispatch，那是後續 cycle 的範圍 |

### 已知未接通（避免誤讀）

- **Runtime dispatcher 行為**（halt / retry / route_back_to / escalate_user 在 step 真正失敗時被執行）尚未接 — P5 AgentSessionRunner 範疇。
- **Envelope → Type C ticket 鏈路** 尚未連通：`emit-handoff-ticket.sh` 不讀 envelope.failure_routing；envelope 解析出來的 routing 資訊還沒有 producer 把它注入 ticket。
- **Per-stage pipeline 整合**：既有 `project-spec-pipeline` / `project-implementation-pipeline` / `project-qa-pipeline` 不引用 envelope flow；它們繼續走 task constitution + handoff ticket 老路。
- **Snapshot writer + compile entry 的 capability 包裝**：兩個模組目前是 standalone Python helpers，沒有 capability registration、沒有 shell executor，因此不能被 workflow YAML 直接引用。

完整 boundary 細節在 [`docs/cap/SUPERVISOR-ORCHESTRATION-BOUNDARY.md`](./SUPERVISOR-ORCHESTRATION-BOUNDARY.md) 與 [`docs/cap/ORCHESTRATION-STORAGE-BOUNDARY.md`](./ORCHESTRATION-STORAGE-BOUNDARY.md)；本章節故意只摘要 + 引用，避免雙寫漂移。

---

## ⛽ Runtime Cost & Token Budget Guardrails

CAP 的多層 helper / executor / workflow 結構容易誘發「重複實作」（同一條邏輯在 Python helper、shell executor、workflow YAML 各寫一份）與「掃描成本浪費」（agent 第一刀就全 repo grep 找入口）。下列 5 條紀律是 P3 收斂後的 engineering discipline，所有後續 cycle（包含 Codex / Claude / 任何 sub-agent）都應遵守：

1. **Reusable core helper, not one-shot script** — 新增 Python module 必須是 reusable core helper（被多個 caller import / CLI / executor 共用），不能為單一 workflow case 新增一次性 script。同一條邏輯出現在第二處時，先抽 helper 再寫第二個 caller。
2. **Shell executor as wrapper only** — `scripts/workflows/*.sh` 是 thin wrapper，職責是接 `CAP_WORKFLOW_INPUT_CONTEXT` 與處理 exit code（per `policies/workflow-executor-exit-codes.md`），**不重寫** Python domain logic。如果 shell 要做的事超過 input parsing + subprocess invocation + exit-code mapping，應該抽 Python helper。
3. **Workflow YAML 重用 capability / executor** — 新 workflow 優先引用既有 capability 與 executor，不為單一 case 新增 capability。引入新 capability 必須在 `schemas/capabilities.yaml` 註冊，並在 `.cap.constitution.yaml` `allowed_capabilities` 列入（缺第二步會永遠 `blocked_by_constitution`）。
4. **Smoke 分層**：每個 commit 跑 focused fixture（該 commit 改的部分），**只在收斂點 / release gate 跑** `scripts/workflows/smoke-per-stage.sh` full smoke（避免 commit 級別反覆跑全 36 step）。Full smoke 用於 phase closeout、release tag 前、或跨多 module 改動的最終確認。
5. **Module map first, grep second** — agent 查 repo 時先看本檔的 module map（前一章節）以及目標 phase 的 boundary memo（如 `docs/cap/CONSTITUTION-BOUNDARY.md` / `docs/cap/SUPERVISOR-ORCHESTRATION-BOUNDARY.md` / `docs/cap/ORCHESTRATION-STORAGE-BOUNDARY.md`），確認入口模組 / 既有 capability 後再開 grep；避免從 0 重新探索 repo 結構。

違反這 5 條的 commit 會增加 token / 維護成本，且容易讓「同一邏輯三處實作」變成隱性技術債。Watcher / Logger 在 milestone gate 應審視這條 discipline，PR review 也應引用本章節作為簡要審視 checklist。

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
