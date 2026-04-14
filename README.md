# Charlie's AI Protocols

> AI 多代理協作系統與開發規則中控台。
> 透過標準化 11 位 AI Agent 的職能人設，結合 CrewAI 執行引擎，實現工業級的軟體開發流水線。

架構設計與設計理念詳見 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

---

## 🤖 Agent 一覽

| 分組 | Agent | 職責 |
|---|---|---|
| **管理組** | 01 Supervisor, 90 Watcher, 99 Logger | 調度、門禁稽核、日誌紀錄 |
| **開發組** | 02 SA, 03 UI, 04 Frontend, 05 Backend | 架構設計、UI 設計、前後端實作 |
| **維運組** | 06 DevOps, 07 QA, 08 Security, 11 SRE | CI/CD、測試、資安審查、效能優化 |

---

## 🚀 快速啟動 (Quick Start)

所有操作透過 `Makefile` 作為唯一入口：

### 1. 設定環境變數

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

更新 `docs/agent-skills/` 後，重建 `.agents/skills/` symlink（含長名與短名 alias）：

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

### 5. 全域安裝（選用）

將 Agent 技能註冊至 User Scope，讓任何 Repo 都能直接使用 `$skill`：

```bash
make install    # 安裝至 ~/.agents/skills/ + ~/.codex/AGENTS.md
make uninstall  # 移除全域安裝（不影響本地）
```

> 全域與本地的差異詳見 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

---

## 💡 BYOCLI 模式 — 臨時調用 Agent 技能

在任何支援 `.agents/` 的 AI CLI（如 Codex）中，透過 `$` 前綴臨時調用單一 Agent。
本地（`make sync`）或全域（`make install`）安裝後皆可使用：

```
$qa 請幫我針對這段 API 寫單元測試。
$security 請掃描目前檔案有沒有 SQL Injection 的風險。
```

**組合技**：在同一次 Prompt 中串接多個角色：

```
請使用 $security 檢查登入模組。
完成後切換為 $logger，將稽核結果寫入 workspace/history/audit-log.md。
```

> 短名 alias（`qa.md`、`security.md` 等）由 `make sync` 自動產生，與長名 `*-agent.md` 指向同一個 SSOT。

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
│   ├── architecture/              #   SA 規格書與 Schema
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
├── CLAUDE.md                      # Claude Code 專案指令
├── AGENTS.md                      # OpenAI Codex / 通用 AI CLI 指令
├── Makefile                       # 唯一操作入口（make help）
├── .env.example                   # 環境變數範本
└── .gitignore
```
