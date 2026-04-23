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
- `*.yaml`
  - 各具體 workflow 模板

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

## 6. Workflow List

### `readme-to-devops.yaml`

- 用途：先完成 repo intake / README 治理，再交由 DevOps 建立交付基線
- 適用情境：新 repo onboarding、README 治理、交付前基線整理
- 主要步驟：
  - `readme_normalization`
  - `technical_review`（可選）
  - `devops_delivery`
  - `technical_logging`（可選）

### `feature-delivery.yaml`

- 用途：完整功能開發流水線
- 適用情境：從需求、分析設計、實作、品質門禁到部署歸檔的一般開發流程
- 主要步驟：
  - PRD / Tech Plan / BA / DBA-API / UI / Analytics
  - Frontend / Backend
  - Watcher + Security gate
  - QA / Troubleshoot / SRE / DevOps / Logger

### `small-tool-planning.yaml`

- 用途：非正式小工具開發前置流程，先產出可交接規格，不直接進入實作
- 適用情境：side project、小工具、技術方向未定、想先整理需求與規格再決定是否開發
- 主要步驟：
  - PRD / Tech Plan / BA / DBA-API / UI
  - Watcher 規格一致性 gate
  - Logger 歸檔
- 刻意不包含：
  - Frontend implementation (`04`)
  - DevOps delivery (`06`)
  - QA execution (`07`)

### `version-control-private.yaml`

- 用途：私人專案的版本控制流程
- 適用情境：個人 repo、side project、portfolio repo
- 主要步驟：
  - `readme_normalization`
  - `version_control_commit`

### `version-control-company.yaml`

- 用途：公司專案的最小版本控制流程
- 適用情境：公司既有 repo、只需整理 commit 的場景
- 主要步驟：
  - `version_control_commit`

### `workflow-smoke-test.yaml`

- 用途：測試 `cap workflow` 工具鏈是否正常
- 適用情境：驗證 list / show / plan / run、phase 拆分與 capability binding
- 主要步驟：
  - `readme_normalization`
  - `version_control_commit`

## 7. 使用建議

- 如果你是逐步手動操作：直接用 `$skill` 呼叫單一 agent
- 如果你要固定順序、可重複交付：選擇對應 workflow
- 如果目前 schema 尚未支援條件分支，優先拆成兩條明確 workflow，而不是在單一檔案裡混入情境判斷

## 8. 對應檔案

- workflow schema：`schemas/workflows/workflow-schema.md`
- capability 契約：`schemas/capabilities.yaml`
- agent binding：`.cap.agents.json`
