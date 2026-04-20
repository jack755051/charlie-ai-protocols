# Charlie's AI Protocols (CAP)

> AI 多代理協作系統與開發規則中控台。
> 透過標準化多位 AI Agent 的職能人設，結合 CrewAI 執行引擎，實現工業級的軟體開發流水線。

架構設計與設計理念詳見 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

---

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

---

## 🚀 一鍵安裝

```bash
curl -fsSL https://raw.githubusercontent.com/jack755051/charlie-ai-protocols/main/install.sh | bash
```

安裝完成後，依提示執行：

```bash
source <你的 shell 設定檔>
```

例如 macOS `zsh` 多半是 `source ~/.zshrc`，而 Bash / Git Bash 常見為 `source ~/.bash_profile` 或 `source ~/.bashrc`。

從此在終端機的**任何目錄**都能使用 `cap` 指令。

若採用預設安裝設定，`codex` 與 `claude` 也會被註冊成 CAP shell wrapper，保留原本的啟動習慣，同時自動寫入 `workspace/history/trace-YYYY-MM.log`。
同時也會同步寫入結構化的 `workspace/history/trace-YYYY-MM.jsonl`，方便後續統計與分析。

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
| `cap update` | 從 GitHub 拉取最新規則並重新安裝 |
| `cap uninstall` | 移除全域安裝與 CAP shell wrapper |
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
完成後切換為 $logger，將稽核結果寫入 workspace/history/audit-log.md。
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

> `10 Troubleshoot` 專注在「快速找出根因與建議路由」；正式的修復派發與品質門禁仍由 `01 Supervisor` 接手。

> 短名 alias（`qa.md`、`security.md` 等）由 `cap sync` 自動產生，與長名 `*-agent.md` 指向同一個 SSOT。

若你希望保留直接輸入 `codex` / `claude` 的習慣，同時自動留下 session trace，建議使用 CAP 安裝時寫入的 shell wrapper。若需要明確指定單一 agent，可改用：

```bash
cap agent frontend "幫我檢查 auth module"
cap agent qa "幫我補 E2E"
cap agent troubleshoot "根據這段 log 找 root cause"
```

目前 trace 會雙寫為：
- `workspace/history/trace-YYYY-MM.log`：人類可直接閱讀的單行紀錄
- `workspace/history/trace-YYYY-MM.jsonl`：供後續統計、Dashboard 或其他自動化流程消費的結構化紀錄

---

## 🔧 全域安裝細節

`cap install` 一次部署三個 AI 工具的全域設定：

| 工具 | 部署位置 | 作用 |
|---|---|---|
| **Claude Code** | `~/.claude/CLAUDE.md` | 使用 `@` 匯入核心憲法 + Git 工作流 |
| | `~/.claude/rules/` | 所有 `*-agent.md` 同步入口，預設 symlink，不支援時自動 fallback 為 copy |
| **OpenAI Codex** | `~/.codex/AGENTS.md` | 全域指令檔 |
| | `~/.agents/skills/` | 長名 + 短名同步入口，預設 symlink，不支援時自動 fallback 為 copy |
| **Shell** | 自動偵測 `~/.zshrc` / `~/.bash_profile` / `~/.bashrc` / `~/.profile` | `cap` / `codex` / `claude` shell wrapper → CAP scripts |

> 開發者建議直接從開發 repo 執行 `make install`；`install.sh` 是給只需消費 protocols 的團隊成員使用。
>
> 補充：Codex 的 `~/.agents/skills/` 與 Claude 的 `~/.claude/rules/` 兩邊都採同一策略，都是「預設 symlink，失敗才 fallback 為 copy」。
> 若要強制要求 symlink，可用 `CAP_LINK_MODE=symlink bash scripts/mapper.sh --global`。
> 若不想包住原生 `codex` / `claude` 指令，可在安裝時設定 `CAP_WRAP_NATIVE_CLI=0`。

---

## 📂 目錄結構

```
charlie-ai-protocols/
├── docs/                          # 版控文件區
│   ├── agent-skills/              # Agent System Prompts (SSOT)
│   │   ├── 00-core-protocol.md    #   全域憲法（非 Agent）
│   │   ├── 01-supervisor-agent.md #   主控 PM
│   │   ├── 02 ~ 99-*-agent.md    #   各職能 Agent
│   │   ├── archive/               #   封存的舊版 Agent（如 02-sa-agent.md）
│   │   ├── strategies/            #   框架與工具策略（非 Agent，如 Playwright / k6 / Lighthouse）
│   │   └── README.md              #   Agent 架構藍圖與流水線說明
│   ├── policies/                  # 跨工具通用策略
│   │   └── git-workflow.md        #   Git 版本控制與 PR 規範
│   └── ARCHITECTURE.md            # 架構設計與設計理念
├── engine/                        # CrewAI 執行引擎
│   ├── factory.py
│   ├── main.py
│   └── requirements.txt
├── workspace/                     # Agent 執行期產出 (gitignored)
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
├── Makefile                       # 操作入口（cap help）
├── .env.example                   # 環境變數範本
└── .gitignore
```
