# Workflow Definitions

> 本目錄定義可重複使用的 workflow 模板，用來描述「步驟、依賴、產物、驗收條件」，而不是描述某個 agent 的角色能力。

## 1. 定位

- `docs/agent-skills/`：角色能力與邊界的單一事實來源
- `docs/agent-skills/strategies/`：框架或工具層的戰術規範
- `docs/workflows/`：跨 agent 的流程模板與 handoff 契約

workflow 的目的，是把固定順序的工作流從 agent prompt 中抽離，避免：

- 流程順序硬編碼到單一 agent
- 更換 agent 時必須重寫流程
- 同一組流程在不同情境下難以複用

## 2. 設計原則

- **綁 capability，不綁 implementation**：step 應描述需要的能力，不應直接綁死某個 agent 檔名。
- **agent 可替換**：workflow 只依賴 capability contract；實際由哪個 agent 執行，交給 registry 或 runtime 決定。
- **artifact 導向**：每個 step 應明確定義輸入、輸出與完成條件。
- **框架中立**：workflow schema 應可被 CrewAI、自寫 orchestrator 或未來的 graph runtime 解析。

## 3. 檔案結構

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

## 5. 與 registry 的關係

workflow 不負責決定最終 agent，只負責宣告：

- 這一步要什麼能力
- 需要哪些輸入
- 會產出哪些 artifact

實際綁定關係應由 capability registry 或 runtime 設定提供。
