# Workflow Definitions

> 本目錄定義可重複使用的 workflow 模板，用來描述「步驟、依賴、產物、驗收條件」，而不是描述某個 agent 的角色能力。

## 1. 定位

- `docs/agent-skills/`：角色能力與邊界的單一事實來源
- `docs/agent-skills/strategies/`：框架或工具層的戰術規範
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
- `../../schemas/workflows/*.yaml`
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

#### `version-control-private.yaml`

- 用途：私人專案版本控制治理流程（單一 step）
- 設計理由：當任務包含 release / tag / CHANGELOG / README 同步時，應以單一治理 step 在一次 session 內完成 scan → branch → commit → tag 判定 → CHANGELOG/README → push
- 主要步驟：
  - `version_control_commit` — 一次完成所有版本控制操作

#### `version-control-quick.yaml`

- 用途：私人專案快速版控
- 設計理由：日常「版本更新 / 幫我 commit / 整理這次變更」不該走完整 release 治理鏈；quick path 只做 scan → commit → push
- 主要步驟：
  - `version_control_commit` — 快速完成 scan、commit、push

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

#### `version-control-company.yaml`

- 用途：公司專案的最小版本控制流程
- 適用情境：公司既有 repo、只需整理 commit 的場景
- 保留理由：若產品要同時支援 private/company 兩種版控模式，它是必要分流；若近期只聚焦私人 repo，可暫時降級維護優先度
- 主要步驟：
  - `version_control_commit`

## 7. 使用建議

- 如果你是逐步手動操作：直接用 `$skill` 呼叫單一 agent
- 如果你要固定順序、可重複交付：優先從 `version-control-private.yaml`、`readme-to-devops.yaml` 與 `workflow-smoke-test.yaml` 之間選擇最小可行流程
- 若是日常 commit：優先走 `version-control-quick.yaml`
- 若包含 tag / release / CHANGELOG / README 同步：走 `version-control-private.yaml`
- `cap workflow run --mode auto version-control-private "版本更新"` 會由 runtime selector 自動落到 quick 或 governed 路徑
- 如果目前 schema 尚未支援條件分支，優先拆成兩條明確 workflow，而不是在單一檔案裡混入情境判斷
- 若你想處理的是「最後收尾、核對、補文件、提交與 release」：先強化既有 `version-control-private`，不要先新增命名模糊的「收斂 workflow」
- 只有在「收斂」本身有獨立產物、獨立驗收條件、且步驟序列明顯不同於版控流程時，才新增新的 workflow，例如 `release-convergence.yaml`

## 8. 對應檔案

- workflow schema：`docs/workflows/workflow-schema.md`
- workflow templates：`schemas/workflows/*.yaml`
- capability 契約：`schemas/capabilities.yaml`
- agent binding：`.cap.agents.json`
