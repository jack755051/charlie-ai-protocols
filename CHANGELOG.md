# Changelog

All notable changes to this project will be documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/). Commit types follow [Conventional Commits](https://www.conventionalcommits.org/) as defined in `docs/policies/git-workflow.md`.

---



## [v0.14.0] - 2026-04-25

### Added
- update workflow workflow assets
## [v0.13.2] - 2026-04-25

### Changed
- update schemas workflow assets
## [v0.13.0] - 2026-04-25

### Added

- 新增 `executor: shell` workflow step metadata、script 白名單與 AI fallback 設定，支援 hybrid executor 流程
- 新增 `docs/policies/workflow-executor-exit-codes.md`，定義 shell executor 與 workflow runtime 的退出碼契約
- 新增 `scripts/workflows/version-control-private.sh` 與 `schemas/workflows/test/version-control-test.yaml`，作為私人版控 quick path 與 hybrid executor fixture

### Changed

- `version-control-private` 升級為 v4，改為 shell quick path 優先，僅在語意不明、混合變更或 git 操作失敗時回流 DevOps AI
- `WorkflowLoader`、`RuntimeBinder`、`step_runtime` 與 `cap-workflow-exec.sh` 同步保留並執行 shell executor / fallback metadata
- workflow 文件與核心協議補齊 shell executor 治理、fallback 與 sensitive risk halt 規則

## [v0.12.0] - 2026-04-24

### Added

- 新增 repo 級 `Project Constitution` 與 skill registry 正式來源：`.cap.constitution.yaml`、`.cap.skills.yaml`
- 新增 `engine/project_context_loader.py`，集中載入 `.cap.project.yaml` 與 `Project Constitution`

### Changed

- `RuntimeBinder` 會套用 `binding_policy.defaults`、限制 `allowed_capabilities`，並驗證 workflow 來源目錄是否符合 constitution
- `TaskScopedWorkflowCompiler` 與 workflow CLI 報表會攜帶 `project_context`，讓 compile / bind / constitution 輸出可追蹤 repo 級治理來源
- `README.md`、`repo.manifest.yaml`、`.cap.project.yaml` 與 `TODOLIST.md` 同步更新，明確區分平台內建資產、repo 正式來源與 runtime workspace

## [v0.11.1] - 2026-04-24

### Changed

- `engine/workflow_cli.py` 追加 workflow binding / constitution / compile 的報表輸出子命令
- `scripts/cap-workflow.sh` 改為直接呼叫 `engine/workflow_cli.py`，移除剩餘 inline Python heredoc

## [v0.10.3] - 2026-04-24

### Fixed

- workflow executor 的 `printf` 修正 ANSI escape codes 未正確渲染的問題

### Changed

- workflow run 終端輸出格式改善，提升可讀性

## [v0.10.2] - 2026-04-24

### Fixed

- CLI 子命令語意釐清：移除歧義的 `cap list`，強制使用 `cap skill list` / `cap workflow list`
- `cap workflow list` 恢復 `wf_` 短 ID 顯示
- `cap workflow ps` 新增 zombie run 偵測，自動標記超時或孤兒 workflow run
- `cap workflow help` 清理未實作的 `-d` flag，補齊 `--cli` 文件
- `RuntimeBinder` 解除 workflow version 3 在 legacy adapter 與 skill registry 的阻斷
- workflow executor 在 step prompt 強制注入文字輸出指引，修正 empty_capture 問題
- 非互動模式輸出要求移入 workflow notes，避免汙染 step contract

### Changed

- `version-control-private` 精簡為單一 step，合併 tag 判定、changelog 同步與 commit/tag 操作

## [v0.10.1] - 2026-04-24

### Changed

- schemas 從 7 份收斂為 3 份現役 schema（`capabilities.yaml`、`skill-registry.schema.yaml`、`task-constitution.schema.yaml`），移除冗餘定義

## [v0.10.0] - 2026-04-24

### Changed

- workflow 產品組合收斂為 `workflow-smoke-test`、`readme-to-devops`、`version-control-private` 與 `version-control-company` 四條現役模板
- `README.md`、workflow 文件與架構說明改為只描述現役 workflow，移除已淘汰模板的正式入口與引用
- supervisor 啟動提示不再在缺少 workflow 時預設套用大型流程，改為先選擇最小可行 workflow

### Removed

- 移除 `schemas/workflows/feature-delivery.yaml`
- 移除 `schemas/workflows/small-tool-planning.yaml`

## [v0.9.0] - 2026-04-24

### Added

- `version-control-private` 新增 `prepare_release_docs` 階段，將 tag 判定與 release 文件同步前移到 commit 之前
- workflow executor 會在 step prompt 中注入 `repo_changes`、`project_context` 與 step contract 摘要，讓 summary 模式可直接消化必要 metadata

### Changed

- `version_control_tag` capability 契約改為區分 commit 前的 release 文件同步與 commit 後的 tag 建立流程
- `RuntimeBinder`、`WorkflowLoader` 與相關文件同步保留 `done_when` / `notes` metadata，改善 workflow handoff 與執行期可追溯性
- README、workflow 文件與 manifest 同步更新 CAP CLI 指令與私人版控流程說明

### Fixed

- `cap-workflow-exec.sh` 在 detached HEAD 狀態下會阻擋 `version_control_commit` / `version_control_tag`，避免在錯誤 ref 上建立 release commit 或 tag
- 修正 workflow intrinsic `commit_scope` 解析，讓 staged file list 可以穩定傳入版本控制 step

## [v0.6.6] - 2026-04-23

### Changed

- 合併本地 `main` 與 `origin/main`，統一本地 workflow 前景執行語意與遠端 workflow run instance 追蹤模型
- `cap workflow run` 保留互動式 prompt 與 `--dry-run`，同時支援 `run_id` 狀態更新與 `inspect` 查詢

### Fixed

- 納入 Windows 開發相容性修正：補齊 LF / EOL 正規化、跨平台 shell 同步與 `.codex` sentinel ignore 調整
- 修正 `cap-workflow-exec.sh` 寫入 workflow status 時與新版 `workflow-runs.json` 結構不相容的問題

## [v0.4.1] - 2026-04-21

### Fixed

- 修正 shell wrapper 安裝行為：在寫入 `cap` / `codex` / `claude` function 前先 `unalias`，避免 zsh 在 `cap update` 後 `source ~/.zshrc` 出現 alias 衝突與 parse error

## [v0.4.0] - 2026-04-21

### Added

- 新增 `101-readme-agent` 選配 Agent，負責 README 標準化、Repo Intake 與文件結構化
- 新增 `readme-governance.md` README 治理規範與 `repo.manifest.example.yaml` Manifest 範本
- 整合 Lighthouse audit 策略至 QA / SRE / Troubleshoot / Supervisor 流水線
- `cap help` 正式化，雙寫 trace（plain text + JSONL）
- 新增 CAP runtime storage（`~/.cap/projects/<project_id>/`）
- 新增 tag-aware release 機制：`cap version`、`cap update [target]`、`cap rollback <tag>`
- 新增 promote 流程：`cap promote list`、`cap promote <src> <dst>`
- 新增 agent registry：`.cap.agents.json`

### Changed

- 預設 trace / report 輸出從 repo 內 `workspace/history` 轉為本機 CAP storage
- 更新 install 與 CLI 文件，對齊 runtime storage、registry 與 release control

### Fixed

- 修正 `101-readme-agent` 預設行為：強制依情境路由（A/B/C），禁止無條件 fallback 到 front matter

## [v0.3.0] - 2026-04-20

### Added

- `cap codex` / `cap claude` trace-aware session wrappers，自動記錄 session ID、執行時間與結果
- 新增 `cap-session.sh` 與 `trace-log.sh`，支援 plain text + JSONL 雙格式 trace

### Changed

- 強化 Frontend Agent (04) 交接與稽核規則：補齊 Analytics 阻斷條件、設計資產對齊、logging handoff 要求
- 釐清 Agent 顯示順序（README 與 agent-skills README）

## [v0.2.1] - 2026-04-20

### Added

- 新增 `10-troubleshoot-agent` 系統故障排查與維護專家，支援五層診斷、根因分類與分流路由
- 新增 `12-figma-agent` 設計同步代理，支援 MCP / import_script 兩種同步模式
- `03-ui-agent` 新增第一階段可維護設計資產輸出（`tokens.json` / `screens.json` / `prototype.html`）
- `ARCHITECTURE.md` 新增 DDD 整合策略與演進路線圖

### Changed

- Supervisor (01) 整合 Troubleshoot 診斷報告的接收與分流路由規則
- 統一 Supervisor / Tech Lead / BA / DBA / SRE / Logger 交接摘要欄位與紀錄模式
- Logger (99) 升級為分級紀錄機制（`trace_only` / `full_log`）
- 釐清 troubleshoot 必須回交 supervisor，而不是直接形成正式派單

### Fixed

- 修正跨平台 shell 同步腳本的相容性問題
- 正規化全 repo 行尾符號（CRLF → LF）

## [v0.2.0] - 2026-04-17

### Added

- 在 BA / DBA / Backend / Watcher 中導入 DDD 戰術模式：Aggregate Root、Value Object、Domain Event
- BA (02a) 新增 Bounded Context 識別與領域語彙鎖定（Ubiquitous Language）
- DBA (02b) 強制標示 Aggregate Root / Entity / Value Object 分類與跨 Aggregate 引用
- Backend (05) 強制 Value Object 不可變建模與 Domain Event 協調機制
- Watcher (90) 新增 DDD 邊界稽核清單（Aggregate Root 守門、語彙一致性、跨 Context 驗證）

## [v0.1.0] - 2026-04-17

### Added

- 新增 `02-techlead-agent` 技術總監角色，負責模組級技術評估與派發建議
- 新增 `09-analytics-agent` 產品數據與實驗分析師（KPI Tree、Event Taxonomy、Funnel Mapping、A/B Test）
- 新增前後端單元測試策略（`unit-test-frontend.md` / `unit-test-backend.md`）
- Watcher (90) 新增開發者單元測試稽核區塊（測試檔存在性、Mock 隔離合規、核心邏輯覆蓋）
- DBA (02b) 新增 DBML / Mermaid 可視化渲染提示（dbdiagram.io / mermaid.live）
- `check-aliases.sh` 腳本驗證 Agent alias 映射正確性

### Changed

- Agent 數量從 11 升至 13（新增 Tech Lead + Analytics）
- 更新所有跨 Agent 引用中的過時 SA 參照為 BA / DBA

### Fixed

- 修正多段 Agent prefix（02a / 02b）的短名 alias 解析
- 修正全部 shell 腳本 CRLF → LF
- 修正 CLAUDE.md / AGENTS.md / rules 中的過時檔名引用
- 修正舊 SA / schema 參照與 agent-skills 文件對齊問題

## [v0.0.2] - 2026-04-17

### Changed

- 將 SA Agent (02) 拆分為 BA 業務分析師 (02a) + DBA/API 架構師 (02b)，分離業務流程分析與資料庫 / API 設計職責
- 核心協議 (00) 新增「協議來源唯讀」規則，禁止 Agent 反向修改 `charlie-ai-protocols` 規則來源檔

## [v0.0.1] - 2026-04-16

### Added

- CAP CLI 整合層：`CLAUDE.md`、`AGENTS.md`、`mapper.sh` 多工具適配（Claude Code / Codex / CrewAI）
- `Makefile` 統一入口：`cap setup` / `cap sync` / `cap install` / `cap list` / `cap run`
- 全域安裝支援：`cap install` 部署至 `~/.agents/skills/`、`~/.claude/` 與 `~/.codex/`
- Claude Code 全域部署（`mapper.sh --global`），自動寫入 `~/.claude/CLAUDE.md` 與 `~/.claude/rules/`
- 短名 alias 機制（`qa.md` → `07-qa-agent.md`）供 `$qa` 指令快速呼叫
- `install.sh` 一鍵安裝腳本 + `cap update` 遠端同步命令
- Shell wrapper 函式（`cap` / `codex` / `claude`）自動注入 `~/.zshrc` 或 `~/.bashrc`
- `docs/policies/git-workflow.md` 版本控制與 PR 規範
- `docs/ARCHITECTURE.md` 架構設計文件

### Changed

- Makefile help 輸出改為顯示 `cap` 前綴，而不是 `make`

### Fixed

- 修正 `ln -sf` 防止重複安裝時的 `File exists` 錯誤

## [v0.0.0-rc] - 2026-04-14

### Changed

- 統一所有 Agent 檔案命名為 `*-agent.md`，供 `factory.py` glob 自動發現
- CrewAI 引擎升級至 v1.14，修正 agent filtering 邏輯
- 移除冗餘 IDE 靜態 prompt 檔案，精簡 repo 結構
- 保留 legacy `workspace/` 目錄結構（via `.gitkeep`）

## [v0.0.0-beta] - 2026-04-13

### Added

- 完成 11 個核心 Agent 定義（01 Supervisor → 99 Logger）
- QA Agent (07) 稽核與測試策略（Playwright POM + k6 Thresholds）
- Security Agent (08) 安全審查工作流（OWASP Top 10、IDOR、Zero Trust）
- SRE Agent (11) 效能與可靠性標準（探針設計、快取防禦、資源配額）
- CrewAI 引擎 bootstrap（`engine/main.py` + `factory.py`）
- Logger (99) 執行軌跡格式定義（Trace Log + Devlog + Changelog 三級機制）
- Frontend 框架策略文件（`frontend-angular.md` / `frontend-nextjs.md` / `frontend-nuxtjs.md`）

## [v0.0.0-alpha] - 2026-04-04

### Added

- 初始化 AI 多代理協作協議架構
- 核心協議 `00-core-protocol.md`（全域憲法：角色認知、溝通協議、工作區禮儀、自我反思迴圈）
- 初始 Agent 文件原型（Supervisor、Frontend、Backend、DevOps、QA、Watcher、Logger）
- `init-ai.sh` 角色分派與框架策略選擇腳本
- 引擎執行規則與自我審查機制
