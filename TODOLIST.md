# Workflow Design TODO List

更新日期：2026-04-22

## 目標

把固定流程抽象成可重複使用的 workflow，同時保留 agent 可替換性，避免把流程順序硬編碼進 `docs/agent-skills/*.md`。

## TODO

- [ ] 定義 workflow 與 agent 的分層原則
  - `agent-skills/` 只描述角色能力與邊界
  - `workflows/` 只描述步驟、依賴、條件與產物
  - runtime 負責把 workflow step 綁定到實際 agent

- [ ] 新增 workflow 規格目錄
  - 建立 `docs/workflows/README.md`
  - 建立 `docs/workflows/workflow-schema.md`
  - 明確定義 `workflow_id`、`version`、`steps`、`capability`、`needs`、`outputs`、`optional`

- [ ] 設計 capability contract
  - 為常用能力定義 `inputs`
  - 定義 `outputs`
  - 定義 `done_when`
  - 定義 `handoff_schema`

- [x] 建立 capability 到 agent 的綁定表
  - 例如 `readme_normalization -> 101-readme-agent`
  - 例如 `devops_delivery -> 06-devops-agent`
  - 支援 `default_agent` 與 `allowed_agents`

- [x] 撰寫第一個 workflow 範例
  - `docs/workflows/readme-to-devops.yaml`
  - 以 capability slot 描述，不直接綁死 agent 檔名

- [ ] 定義 supervisor 的新責任
  - 讀取 workflow 定義
  - 依 capability 尋找對應 agent
  - 檢查 step 產物是否符合契約
  - 在失敗時 reroute 或要求重工

- [ ] 決定 workflow artifacts 的正式落點
  - repo 內正式文件放 `docs/`
  - 執行期草稿與報告放 `~/.cap/projects/<project_id>/`
  - legacy 筆記暫放 `workspace/history/`

- [x] 暫不引入 LangChain
  - 先完成 workflow spec
  - 先用現有 `CrewAI + 自家 orchestration` 驗證
  - 只有在 graph、checkpoint、stateful branching 明顯變複雜時再評估 `LangGraph`

- [ ] 補一份 migration note
  - 說明目前 `典型交付順序` 與未來 `workflow definition` 的差異
  - 說明現有 agent prompt 不需要大改，只要補 capability 與 handoff 契約

## 近期建議順序

1. 先出 `workflow-schema.md`
2. 再出 `readme-to-devops.yaml`
3. 再補 capability registry
4. 最後才改 engine 讓 supervisor 能讀 workflow

## 已完成

- [x] 新增 `docs/workflows/README.md`
- [x] 新增 `docs/workflows/workflow-schema.md`
- [x] 新增 `docs/workflows/readme-to-devops.yaml`
- [x] 新增 `docs/policies/capability-contracts.md`
- [x] 擴充 `.cap.agents.json`，加入 `capabilities` mapping
- [x] 新增 `engine/workflow_loader.py`
- [x] 更新 `engine/main.py`，可載入 workflow 並生成 execution plan
- [x] 更新 `engine/requirements.txt`，加入 `PyYAML`
