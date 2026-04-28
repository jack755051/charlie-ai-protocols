# Workflow Definitions

> 本目錄定義可重複使用的 workflow 模板，用來描述「步驟、依賴、產物、驗收條件」，而不是描述某個 agent 的角色能力。

## 1. 定位

- `agent-skills/`：角色能力與邊界的單一事實來源
- `agent-skills/strategies/`：框架或工具層的戰術規範
- `schemas/workflows/`：跨 agent 的流程模板與 handoff 契約
- `schemas/capabilities.yaml`：capability contract 定義

workflow 的目的，是把固定順序的工作流從 agent prompt 中抽離，避免：

- 流程順序硬編碼到單一 agent
- 更換 agent 時必須重寫流程
- 同一組流程在不同情境下難以複用
- Watcher / Logger 這類橫向監管角色只能靠口頭約定，無法在流程層被強制執行

## 2. 設計原則

- **綁 capability，不綁 implementation**：step 應描述需要的能力，不應直接綁死某個 agent 檔名。
- **agent 可替換**：workflow 只依賴 capability contract；實際由哪個 agent 執行，交給 registry 或 runtime 決定。
- **artifact 導向**：每個 step 應明確定義輸入、輸出與完成條件。
- **governance 顯式化**：workflow 應明確定義 Watcher / Logger 的介入模式與 checkpoint。
- **框架中立**：workflow schema 應可被 CrewAI、自寫 orchestrator 或未來的 graph runtime 解析。

## 3. 檔案結構

- `README.md`
  - 給人類閱讀的 workflow 入口、使用方式與清單
- `workflow-schema.md`
  - 定義 workflow YAML 的最小欄位與語意
- `../schemas/workflows/*.yaml`
  - 各具體 workflow 模板
- `~/.cap/projects/<project_id>/compiled-workflows/`
  - 單次任務由 compiler 動態生成的 compiled workflow bundle
- `~/.cap/projects/<project_id>/constitutions/`
  - task constitution snapshot
- `~/.cap/projects/<project_id>/bindings/`
  - binding report snapshot

## 4. 執行模型

建議由 supervisor 或後續的 orchestration layer 執行以下責任：

1. 載入 workflow 檔案
2. 逐步解析 step 與 `needs`
3. 根據 `capability` 找到對應 agent
4. 驗證產物是否符合 capability contract
5. 失敗時安排 reroute、重試或退回前一步
6. 依 `governance` 設定安排 Watcher / Logger 的 checkpoint 介入
7. 若有正式 handoff ticket，應在派發前以 orchestration 層驗證其不得覆寫 workflow 的 step / capability / phase / checkpoint

## 5. 與 registry 的關係

workflow 不負責決定最終 agent，只負責宣告：

- 這一步要什麼能力
- 需要哪些輸入
- 會產出哪些 artifact

實際綁定關係應由 capability registry 或 runtime 設定提供。

補充：

- repo 內 `schemas/workflows/*.yaml` 是 **模板**
- `cap workflow compile / run-task` 產生的 task-scoped workflow 是 **runtime artifact**
- runtime artifact 應寫入 `.cap`，不應混入主程式 repo

## 6. Active Workflows

目前 repo 只保留收斂後的現役 workflow，避免 runtime 在高耦合模板上持續分散維護成本。

### A. 核心流程

#### `workflow-smoke-test.yaml`

- 用途：測試 `cap workflow` 工具鏈是否正常
- 為何必留：它是 `list / show / plan / run`、phase 拆分、capability binding 的最小回歸基線
- 主要步驟：
  - `readme_normalization`
  - `version_control_commit`

#### `readme-to-devops.yaml`

- 用途：先完成 repo intake / README 治理，再交由 DevOps 建立交付基線
- 為何必留：它代表最小跨角色 workflow，可驗證從治理到交付基線的 handoff 是否成立
- 主要步驟：
  - `readme_normalization`
  - `technical_review`（可選）
  - `devops_delivery`
  - `technical_logging`（可選）

#### `project-constitution.yaml`

- 用途：從一個產品想法或新 repo 方向產生 Project Constitution
- 設計理由：constitution 是後續 task workflow compile、agent session 啟動與 artifact 保存策略的治理基礎；此 workflow 只產生規範，不直接開發 repo
- 主要步驟：
  - `project_constitution` — 產出 Project Constitution Markdown / JSON 與 executor policy

#### `project-constitution-reconcile.yaml`

- 用途：在既有 Project Constitution 基礎上吸收補充 prompt，產出修正版草案，再驗證與覆寫持久化
- 設計理由：初版憲章應保持最小可行 SSOT；補充資訊應透過獨立 reconcile workflow 收斂，避免把待補充資訊直接混進憲法本體
- 主要步驟：
  - `constitution_reconciliation_inputs`
  - `constitution_reconciliation`
  - `constitution_validation`
  - `constitution_persistence`
- 補充輸入範本：`workflows/project-constitution-addendum.example.md`

#### `version-control.yaml`

- 用途：版本控制流程（三段 pipeline + strategy）
- 設計理由：shell 不再猜語意（避免低訊號 subject / 機械模板），AI 不再重跑 git（避免空燒 token）；改為清楚切分 `vc_scan` (shell) → `vc_compose` (AI) → `vc_apply` (shell)，由 `vc_apply` 出口 lint 守住 commit 品質。fast / governed / strict 是策略，不再拆成多份 workflow YAML。
- 主要步驟：
  - `vc_scan` (shell) — 掃描 git 狀態、敏感檔、變更類型，輸出結構化 evidence pack（含 `path_tokens` / `release_intent` / `next_tag_candidate` / `diff_excerpt`）
  - `vc_compose` (AI / devops) — 純語意工作：根據 evidence 產出 commit envelope JSON，禁止重跑 git
  - `vc_apply` (shell) — lint envelope（subject 必含 path token、禁止抽象主動詞、annotation 與 changelog 條目皆過 lint），通過後執行 git ops（commit / 視 release_intent 決定 tag + CHANGELOG amend + push）
- 策略：
  - `fast` — 日常 commit-only，禁止 release / tag / CHANGELOG path
  - `governed` — 一般治理版控，允許依 `release_intent` 執行 release path
  - `strict` — 高治理 / 公司場景，重大或跨模組變更必須說明影響與遷移

### B. 補充流程

#### `project-code-analysis.yaml`

- 用途：針對既有、待維護 repo 進行架構 reverse engineering、風險、熱點與技術債分析，最後產出正式分析報告
- 適用情境：接手陌生專案、進行 codebase audit、盤點重構優先順序、建立閱讀地圖、維護前盤點
- 主要步驟：
  - `analysis_scope`
  - `repo_intake`
  - `architecture_scan`
  - `hotspot_diagnostics`
  - `review_analysis`
  - `archive_report`
- 最低參與 agent：
  - `01-supervisor`
  - `101-readme`
  - `02-techlead`
  - `10-troubleshoot`
  - `99-logger`
- 不包含：
  - `07-qa`
  - `08-security`
- 理由：
  - 這條流程是接手維護中的 repo 分析，不是開發後驗收
  - 目前主線先聚焦架構理解、熱點診斷、技術債與維護風險
  - 若未來要做測試性 / 安全性專項分析，較適合另外拆成 extension workflow，而不是硬塞進主線

## 7. 使用建議

- 如果你是逐步手動操作：直接用 `$skill` 呼叫單一 agent
- 如果你要固定順序、可重複交付：優先從 `version-control.yaml`、`readme-to-devops.yaml` 與 `workflow-smoke-test.yaml` 之間選擇最小可行流程
- 若是日常 commit：走 `cap workflow run --strategy fast version-control "..."`
- 若需要 release / tag / CHANGELOG 同步：走 `cap workflow run --strategy governed version-control "..."`
- 若是公司或高治理場景：走 `cap workflow run --strategy strict version-control "..."`
- `cap workflow run --strategy auto version-control "版本更新"` 會由 runtime selector 自動選擇 strategy
- 不再為 quick / company / private 拆多份 version-control YAML；差異應落在 strategy contract，而不是 workflow 檔名
- 若你想處理的是「最後收尾、核對、補文件、提交與 release」：先強化既有 `version-control` strategy，不要先新增命名模糊的「收斂 workflow」
- 只有在「收斂」本身有獨立產物、獨立驗收條件、且步驟序列明顯不同於版控流程時，才新增新的 workflow，例如 `release-convergence.yaml`

## 8. 對應檔案

- workflow schema：`workflows/workflow-schema.md`
- workflow templates：`schemas/workflows/*.yaml`
- capability 契約：`schemas/capabilities.yaml`
- agent binding：`.cap.agents.json`
