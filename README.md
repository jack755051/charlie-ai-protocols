# Charlie's AI Protocols (CAP)

> AI 多代理協作系統與開發規則中控台。
> 透過標準化 11 位 AI Agent 的職能人設，結合 CrewAI 執行引擎，實現工業級的軟體開發流水線。

架構設計與設計理念詳見 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

---

## 🤖 Agent 一覽

| 分組 | Agent | `$` 前綴 | 職責 |
|---|---|---|---|
| **管理組** | 01 Supervisor | `$supervisor` | 需求拆解、任務調度、品質門禁 |
| | 90 Watcher | `$watcher` | 橫向稽核、規格交叉驗證 |
| | 99 Logger | `$logger` | 開發日誌、Changelog 紀錄 |
| **開發組** | 02 SA | `$sa` | 系統架構、DB Schema、API 契約 |
| | 03 UI | `$ui` | 設計系統、Design Tokens |
| | 04 Frontend | `$frontend` | Angular / Next.js / Nuxt 實作 |
| | 05 Backend | `$backend` | .NET / NestJS 實作 |
| **維運組** | 06 DevOps | `$devops` | Docker、CI/CD |
| | 07 QA | `$qa` | E2E 測試、壓力測試 |
| | 08 Security | `$security` | 資安審查、Shift-Left |
| | 11 SRE | `$sre` | 效能診斷、可靠性優化 |

---

## 🚀 一鍵安裝

```bash
curl -fsSL https://raw.githubusercontent.com/jack755051/charlie-ai-protocols/main/install.sh | bash
```

安裝完成後，依提示執行：

```bash
source ~/.zshrc
```

從此在終端機的**任何目錄**都能使用 `cap` 指令。

---

## 📋 指令總覽

安裝後執行 `cap help` 即可查看完整清單：

| 指令 | 說明 |
|---|---|
| `cap help` | 列出所有可用指令 |
| `cap list` | 列出 11 個 Agent Skills（編號、檔名、`$` 前綴、角色） |
| `cap setup` | 建立 Python venv 並安裝 CrewAI 依賴（首次執行） |
| `cap sync` | 更新 Agent 定義後，重建本地 `.agents/skills/` symlink |
| `cap install` | 全域安裝至 `~/.claude/`、`~/.agents/`、`~/.codex/` 並註冊 `cap` alias |
| `cap update` | 從 GitHub 拉取最新規則並重新安裝 |
| `cap uninstall` | 移除全域安裝與 `cap` alias |
| `cap run` | 以預設 Next.js 啟動 CrewAI 引擎 |
| `cap run FRAMEWORK=nuxt` | 指定框架啟動（`nextjs` / `angular` / `nuxt`） |

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

> 短名 alias（`qa.md`、`security.md` 等）由 `cap sync` 自動產生，與長名 `*-agent.md` 指向同一個 SSOT。

---

## 🔧 全域安裝細節

`cap install` 一次部署三個 AI 工具的全域設定：

| 工具 | 部署位置 | 作用 |
|---|---|---|
| **Claude Code** | `~/.claude/CLAUDE.md` | 使用 `@` 匯入核心憲法 + Git 工作流 |
| | `~/.claude/rules/` | 11 個 agent symlink，作為背景知識 |
| **OpenAI Codex** | `~/.codex/AGENTS.md` | 全域指令檔 |
| | `~/.agents/skills/` | 22 個 symlink（11 長名 + 11 短名 alias） |
| **Shell** | `~/.zshrc` | `cap` alias → `make -C <CAP路徑>` |

> 開發者建議直接從開發 repo 執行 `make install`；`install.sh` 是給只需消費 protocols 的團隊成員使用。

---

## 📂 目錄結構

```
charlie-ai-protocols/
├── docs/                          # 版控文件區
│   ├── agent-skills/              # Agent System Prompts (SSOT)
│   │   ├── 00-core-protocol.md    #   全域憲法（非 Agent）
│   │   ├── 01-supervisor-agent.md #   主控 PM
│   │   ├── 02 ~ 99-*-agent.md    #   各職能 Agent
│   │   ├── strategies/            #   框架特化策略（非 Agent）
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
│   └── skills/                    #   長名(*-agent.md) + 短名(qa.md) symlink
├── .claude/                       # Claude Code 規則
│   └── rules/                     #   路徑限定規則 (agent-skills, engine)
├── scripts/                       # Shell 腳本
│   ├── init-ai.sh                 #   技術策略初始化
│   └── mapper.sh                  #   Agent Skills symlink 建立
├── install.sh                     # 一鍵安裝腳本（curl | bash）
├── CLAUDE.md                      # Claude Code 專案指令
├── AGENTS.md                      # OpenAI Codex / 通用 AI CLI 指令
├── Makefile                       # 操作入口（cap help）
├── .env.example                   # 環境變數範本
└── .gitignore
```
