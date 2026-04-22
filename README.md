# Charlie's AI Protocols (CAP)

> 工業級 AI 多代理協作框架與 CLI 工具。
> 定義 17 位專職 AI Agent 的角色邊界、交接協議與品質門禁，搭配 CrewAI 執行引擎、Shell CLI（`cap`）與雙寫 Trace 機制，讓 AI 與工程團隊在同一套契約下穩定協作。

![Python](https://img.shields.io/badge/Python-3.10+-3776AB?logo=python&logoColor=white)
![CrewAI](https://img.shields.io/badge/CrewAI-1.14+-000000)
![Shell](https://img.shields.io/badge/Shell-Bash%2FZsh-4EAA25?logo=gnubash&logoColor=white)
![Agents](https://img.shields.io/badge/Agents-17-blueviolet)
![Status](https://img.shields.io/badge/status-active-22c55e)

---

## Purpose

CAP 解決的核心問題：**當多位 AI Agent 同時參與軟體開發流水線時，如何確保角色分工清晰、交接不掉鏈、品質門禁不被繞過。**

- 為 PM / Tech Lead / BA / DBA / UI / Frontend / Backend / DevOps / QA / Security / SRE / Analytics 等角色定義標準化系統提示與交付格式。
- 提供 CLI 工具（`cap`）實現一鍵安裝、Agent 調用、session tracing 與版本管理。
- 作為個人作品集的代表作之一，展示 AI 協作工程化的整體設計能力。

## Scope

涵蓋：

- 17 位 Agent 的 System Prompt（`docs/agent-skills/*-agent.md`）。
- 全域憲法與跨工具策略（`docs/agent-skills/00-core-protocol.md`、`docs/policies/`）。
- 10 套框架與工具策略（Angular / Next.js / Nuxt.js / .NET / NestJS / Playwright / k6 / Lighthouse / Unit Test）。
- CrewAI 執行引擎（`engine/`）。
- Shell CLI 工具鏈（`scripts/`、`Makefile`、`install.sh`）。
- 三消費者架構：同一份 SSOT 同時供 CrewAI、Claude Code（`@import`）、OpenAI Codex（`$prefix`）使用。

不涵蓋：

- 具體業務專案的原始碼（由各專案 repo 承載）。
- Agent 執行期間的本機 runtime storage（`~/.cap/`，不納入版控）。

## Architecture

架構設計與設計理念詳見 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

```
┌──────────────────────────────────────────────┐
│  SSOT: docs/agent-skills/*-agent.md          │
│         + 00-core-protocol.md (constitution) │
│         + strategies/ (framework tactics)     │
└───────┬──────────┬──────────┬────────────────┘
        │          │          │
        ▼          ▼          ▼
   ┌─────────┐ ┌────────┐ ┌────────┐
   │ CrewAI  │ │ Claude │ │ Codex  │
   │ factory │ │  Code  │ │ $prefix│
   │  .py    │ │ @import│ │ invoke │
   └─────────┘ └────────┘ └────────┘
        │          │          │
        └──────────┴──────────┘
                   │
                   ▼
        ┌─────────────────┐
        │  ~/.cap/         │
        │  traces / drafts │
        │  / reports       │
        └─────────────────┘
```

## 🤖 Agent 一覽

> Agent 編號是穩定識別 ID，不完全等於流水線先後順序。實際接手關係請以本節的「典型位置」理解，尤其是 `03 UI → 12 Figma → 09 Analytics → 04 Frontend / 05 Backend`。

| 類型 | 典型位置 | 穩定 ID | `$` 前綴 | 職責 |
|---|---|---|---|---|
| **治理** | 全流程入口 | 01 Supervisor | `$supervisor` | 需求拆解、任務調度、品質門禁 |
| **交付** | 1 | 02 Tech Lead | `$techlead` | 技術評估、架構細化、派發建議 |
| | 2 | 02a BA | `$ba` | 業務流程分析、邏輯邊界定義 |
| | 3 | 02b DBA/API | `$dba` | DB Schema SSOT、API 介面契約 |
| | 4 | 03 UI | `$ui` | 設計系統、第一層設計資產 |
| | 5 | 12 Figma Sync | `$figma` | 同步設計資產到 Figma |
| | 6 | 09 Analytics | `$analytics` | KPI、埋點、A/B Test |
| | 7 | 04 Frontend | `$frontend` | Angular / Next.js / Nuxt 實作 |
| | 8 | 05 Backend | `$backend` | .NET / NestJS 實作 |
| **門禁 / 維運** | 9 | 90 Watcher | `$watcher` | 橫向稽核、規格交叉驗證 |
| | 10 | 08 Security | `$security` | 資安審查、Shift-Left |
| | 11 | 07 QA | `$qa` | E2E 測試、壓力測試 |
| | 12 | 10 Troubleshoot | `$troubleshoot` | 全棧故障排查、根因診斷、修復建議 |
| | 13 | 11 SRE | `$sre` | 效能診斷、可靠性優化 |
| | 14 | 06 DevOps | `$devops` | Docker、CI/CD |
| **收尾** | 歸檔 | 99 Logger | `$logger` | 開發日誌、Changelog 紀錄 |
| **選配 / 輔助** | 非主流水線 | 101 README | `$readme` | README 標準化、Repo Intake、文件結構化 |

---

## 🚀 一鍵安裝

```bash
curl -fsSL https://raw.githubusercontent.com/jack755051/charlie-ai-protocols/main/install.sh | bash
```

若要指定版本安裝：

```bash
curl -fsSL https://raw.githubusercontent.com/jack755051/charlie-ai-protocols/main/install.sh | CAP_VERSION=v0.4.0 bash
```

安裝完成後，依提示執行：

```bash
source <你的 shell 設定檔>
```

例如 macOS `zsh` 多半是 `source ~/.zshrc`，而 Bash / Git Bash 常見為 `source ~/.bash_profile` 或 `source ~/.bashrc`。

從此在終端機的**任何目錄**都能使用 `cap` 指令。

若採用預設安裝設定，`codex` 與 `claude` 也會被註冊成 CAP shell wrapper，保留原本的啟動習慣，同時自動寫入本機 CAP 儲存區 `~/.cap/projects/<project_id>/traces/trace-YYYY-MM.log`。
同時也會同步寫入結構化的 `~/.cap/projects/<project_id>/traces/trace-YYYY-MM.jsonl`，方便後續統計與分析。

---

## 📋 指令總覽

安裝後執行 `cap help` 即可查看完整清單：

| 指令 | 說明 |
|---|---|
| `cap help` | 列出所有可用指令 |
| `cap list` | 列出所有 Agent Skills（編號、檔名、`$` 前綴、角色） |
| `cap setup` | 建立 Python venv 並安裝 CrewAI 依賴（首次執行） |
| `cap sync` | 更新 Agent 定義後，重建本地 `.agents/skills/` symlink；若環境不支援則自動 fallback 為 copy |
| `cap install` | 全域安裝至 `~/.claude/`、`~/.agents/`、`~/.codex/` 並註冊 CAP shell wrapper |
| `cap version` | 顯示目前安裝版本、ref 與最新 release tag |
| `cap update [target]` | 更新到 `latest` / `main` / 指定 tag 或 branch |
| `cap rollback <tag>` | 回退到指定 release tag |
| `cap uninstall` | 移除全域安裝與 CAP shell wrapper |
| `cap paths` | 顯示目前專案對應的 CAP 本機儲存路徑 |
| `cap registry` | 顯示目前 agent registry 設定 |
| `cap promote list` | 列出本機 drafts / reports |
| `cap promote <src> <dst>` | 將本機產物升級到 repo 正式路徑 |
| `cap run` | 以預設 Next.js 啟動 CrewAI 引擎 |
| `cap run FRAMEWORK=nuxt` | 指定框架啟動（`nextjs` / `angular` / `nuxt`） |
| `cap codex [ARGS...]` | 透過 wrapper 啟動 Codex，並自動寫入 session trace |
| `cap claude [ARGS...]` | 透過 wrapper 啟動 Claude，並自動寫入 session trace |
| `cap agent <agent> [prompt]` | 以指定 agent 啟動互動 session，並自動寫入 trace |

---

## ⚡ 快速啟動 CrewAI 引擎

### 1. 設定環境變數

```bash
cp .env.example .env
# 編輯 .env，填入 OPENAI_API_KEY
```

### 2. 首次初始化 + 啟動

```bash
cap setup              # 建立 venv + 安裝依賴
cap run                # 預設 nextjs
cap run FRAMEWORK=nuxt # 指定框架
```

---

## 💡 BYOCLI 模式 — 臨時調用 Agent 技能

在任何支援 `.agents/` 的 AI CLI（如 OpenAI Codex）中，透過 `$` 前綴臨時調用單一 Agent：

```
$qa 請幫我針對這段 API 寫單元測試。
$security 請掃描目前檔案有沒有 SQL Injection 的風險。
```

**組合技**：在同一次 Prompt 中串接多個角色：

```
請使用 $security 檢查登入模組。
完成後切換為 $logger，將稽核結果寫入 `~/.cap/projects/<project_id>/reports/audit-log.md`。
```

若要把第一層設計資產同步到 Figma：

```
請先使用 $ui 產出 UI Spec、tokens.json、screens.json 與 prototype.html。
完成後切換為 $figma，同步到指定 Figma 檔案或頁面。
```

若要快速做維護診斷，可直接先叫出 Troubleshoot：

```
$troubleshoot 根據這段 error log 幫我找出問題關鍵點，輸出故障診斷報告，並說明接下來應交由哪個角色處理。
```

若要統一 README 供排程自動讀取，可直接呼叫：

```
$readme 請幫我把這個 repo 的 README 正規化成可機器解析格式。
```

> `10 Troubleshoot` 專注在「快速找出根因與建議路由」；正式的修復派發與品質門禁仍由 `01 Supervisor` 接手。

> 短名 alias（`qa.md`、`security.md` 等）由 `cap sync` 自動產生，與長名 `*-agent.md` 指向同一個 SSOT。

若你希望保留直接輸入 `codex` / `claude` 的習慣，同時自動留下 session trace，建議使用 CAP 安裝時寫入的 shell wrapper。若需要明確指定單一 agent，可改用：

```bash
cap agent frontend "幫我檢查 auth module"
cap agent qa "幫我補 E2E"
cap agent troubleshoot "根據這段 log 找 root cause"
```

目前 trace 會雙寫為：
- `~/.cap/projects/<project_id>/traces/trace-YYYY-MM.log`：人類可直接閱讀的單行紀錄
- `~/.cap/projects/<project_id>/traces/trace-YYYY-MM.jsonl`：供後續統計、Dashboard 或其他自動化流程消費的結構化紀錄

正式交付若要從本機 storage 升級進 repo，可使用：

```bash
cap promote list
cap promote reports/audit-log.md docs/reports/audit-log.md
```

---

## 🔧 全域安裝細節

`cap install` 一次部署三個 AI 工具的全域設定：

| 工具 | 部署位置 | 作用 |
|---|---|---|
| **Claude Code** | `~/.claude/CLAUDE.md` | 使用 `@` 匯入核心憲法 + Git 工作流 |
| | `~/.claude/rules/` | 所有 `*-agent.md` 同步入口，預設 symlink，不支援時自動 fallback 為 copy |
| **OpenAI Codex** | `~/.codex/AGENTS.md` | 全域指令檔 |
| | `~/.agents/skills/` | 長名 + 短名同步入口，預設 symlink，不支援時自動 fallback 為 copy |
| **CAP Runtime Storage** | `~/.cap/projects/<project_id>/` | 本機 traces、logs、drafts、reports、sessions |
| **Shell** | 自動偵測 `~/.zshrc` / `~/.bash_profile` / `~/.bashrc` / `~/.profile` | `cap` / `codex` / `claude` shell wrapper → CAP scripts |

> 開發者建議直接從開發 repo 執行 `make install`；`install.sh` 是給只需消費 protocols 的團隊成員使用。
>
> 補充：Codex 的 `~/.agents/skills/` 與 Claude 的 `~/.claude/rules/` 兩邊都採同一策略，都是「預設 symlink，失敗才 fallback 為 copy」。
> 若要強制要求 symlink，可用 `CAP_LINK_MODE=symlink bash scripts/mapper.sh --global`。
> 若不想包住原生 `codex` / `claude` 指令，可在安裝時設定 `CAP_WRAP_NATIVE_CLI=0`。
> 版本策略上，`cap update` 預設更新到最新 release tag；若要追 `main`，請明確使用 `cap update main`。

---

## 📂 目錄結構

```
charlie-ai-protocols/
├── docs/                          # 版控文件區
│   ├── agent-skills/              # Agent System Prompts (SSOT)
│   │   ├── 00-core-protocol.md    #   全域憲法（非 Agent）
│   │   ├── 01-supervisor-agent.md #   主控 PM
│   │   ├── 02 ~ 99-*-agent.md    #   核心職能 Agent
│   │   ├── 101-*-agent.md        #   選配 / 輔助 Agent
│   │   ├── archive/               #   封存的舊版 Agent（如 02-sa-agent.md）
│   │   ├── strategies/            #   框架與工具策略（非 Agent，如 Playwright / k6 / Lighthouse）
│   │   └── README.md              #   Agent 架構藍圖與流水線說明
│   ├── policies/                  # 跨工具通用策略
│   │   ├── git-workflow.md        #   Git 版本控制與 PR 規範
│   │   ├── cap-storage.md         #   CAP 本機儲存架構與三層儲存模型
│   │   ├── agent-registry.md      #   Agent registry 與 backend 替換入口
│   │   ├── readme-governance.md   #   README / repo.manifest.yaml 治理規範
│   │   └── repo.manifest.example.yaml #   Manifest 範本
│   └── ARCHITECTURE.md            # 架構設計與設計理念
├── schemas/                       # 機器可讀契約
│   ├── workflows/                 #   Workflow 模板（步驟、依賴、產物定義）
│   ├── capabilities.yaml          #   Capability contract 定義
│   └── handoff-ticket.schema.yaml #   任務交接單結構化 schema
├── engine/                        # CrewAI 執行引擎
│   ├── factory.py
│   ├── main.py
│   └── requirements.txt
├── workspace/                     # 舊版 single-user sandbox（legacy）
│   ├── architecture/              #   BA/API 規格書與 Schema
│   ├── design/                    #   UI 視覺規範
│   ├── history/                   #   開發日誌 (devlog)
│   └── src/                       #   Agent 產出的原始碼
├── .agents/                       # AI CLI 工具統一入口
│   └── skills/                    #   長名(*-agent.md) + 短名(qa.md) 同步入口，預設 symlink
├── .claude/                       # Claude Code 規則
│   └── rules/                     #   路徑限定規則 (agent-skills, engine)
├── scripts/                       # Shell 腳本
│   ├── init-ai.sh                 #   技術策略初始化
│   └── mapper.sh                  #   Agent Skills 同步入口建立（預設 symlink）
├── install.sh                     # 一鍵安裝腳本（curl | bash）
├── CLAUDE.md                      # Claude Code 專案指令
├── AGENTS.md                      # OpenAI Codex / 通用 AI CLI 指令
├── .cap.project.yaml              # 專案識別設定（決定 project_id 與本機 storage 對應）
├── .cap.agents.json               # Agent registry（alias -> provider / prompt / cli）
├── Makefile                       # 操作入口（cap help）
├── .env.example                   # 環境變數範本
├── repo.manifest.yaml             # 機器可解析的專案 metadata
└── .gitignore
```

## Dependencies

**Runtime**

- Python `>= 3.10`
- CrewAI `>= 1.14`（無 LangChain 依賴）
- `python-dotenv`
- Bash / Zsh（CLI 工具鏈）
- GNU Make（`cap` 指令入口）

**消費端（選用）**

- [Claude Code](https://claude.com/claude-code)：透過 `@import` 掛載 Agent Skills
- [OpenAI Codex](https://openai.com/codex)：透過 `$prefix` 調用 Agent Skills

**支援的目標框架（由 `strategies/` 定義）**

- Frontend：Angular / Next.js / Nuxt.js
- Backend：C# .NET / NestJS
- Testing：Playwright / k6 / Lighthouse
- Unit Test：Frontend / Backend 各一套策略

## Notes

- **版本**：目前最新 release 為 `v0.4.1`。使用 `cap version` 查看、`cap update` 更新。
- **三消費者架構**：同一份 `docs/agent-skills/` 是唯一 SSOT，CrewAI 的 `factory.py`、Claude Code 的 `@import`、Codex 的 `$prefix` 三端共用，避免多份口徑。
- **Trace 雙寫**：所有 session 同時寫入 `.log`（人類閱讀）與 `.jsonl`（機器消費），存放於 `~/.cap/projects/<project_id>/traces/`。
- **Symlink 策略**：`cap sync` / `cap install` 預設建立 symlink；若環境不支援則自動 fallback 為 copy。
- **歷史遺留命名**：各 Agent 文件中如有 `resquest` 等刻意保留的歷史拼寫，請沿用不得擅自修正。

## License

UNLICENSED — Portfolio 專用，保留一切權利。

## Links

- Portfolio: <https://jack755051.github.io/charlie_portfolio_frontend/portfolio>
