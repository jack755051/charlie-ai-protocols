# Capability Contracts (Draft v1)

> 本文件定義 workflow 可引用的 capability 與其最小契約，目的是讓 workflow 綁定能力，而不是綁定特定 agent implementation。

## 1. 設計原則

- capability 是流程語意，不是 prompt 檔名
- 一個 capability 可以對應一個或多個 agent
- agent 若要替換，只需維持相同輸入輸出與完成條件
- workflow 只引用 capability 名稱，不重複寫完整契約

## 2. 建議欄位

每個 capability 建議至少定義：

| 欄位 | 說明 |
|---|---|
| `name` | 能力名稱 |
| `default_agent` | 預設實作 agent |
| `allowed_agents` | 可替代的 agent 清單 |
| `inputs` | 所需輸入 |
| `outputs` | 預期產物 |
| `done_when` | 完成條件 |
| `handoff_schema` | 交接時應帶的結構 |

## 3. Capability Drafts

### 3.1 `readme_normalization`

- `default_agent`: `101-readme-agent`
- `allowed_agents`:
  - `101-readme-agent`
- `inputs`:
  - repo 現況
  - README 或 manifest 來源檔
  - README 治理規範
- `outputs`:
  - `repo_manifest`
  - `repo_summary`
- `done_when`:
  - README 或 manifest 已依治理規則補齊
  - 命令、入口點、介面欄位可在 repo 中找到證據
- `handoff_schema`:
  - `repo_type`
  - `readme_mode`
  - `files_changed`
  - `unresolved_fields`
  - `validation_notes`

### 3.2 `technical_review`

- `default_agent`: `02-techlead-agent`
- `allowed_agents`:
  - `02-techlead-agent`
  - `01-supervisor-agent`
- `inputs`:
  - `repo_manifest`
  - `repo_summary`
- `outputs`:
  - `delivery_ready_note`
- `done_when`:
  - 已確認交付資訊完整度
  - 已指出缺漏與風險
- `handoff_schema`:
  - `decision`
  - `known_risks`
  - `missing_inputs`
  - `next_recommended_capability`

### 3.3 `devops_delivery`

- `default_agent`: `06-devops-agent`
- `allowed_agents`:
  - `06-devops-agent`
  - `11-sre-agent`
- `inputs`:
  - `repo_manifest`
  - `repo_summary`
  - `delivery_ready_note`
- `outputs`:
  - `ci_config`
  - `deploy_spec`
- `done_when`:
  - 已提出最小交付基線
  - 已說明缺少的 infra 或 secrets 條件
- `handoff_schema`:
  - `output_paths`
  - `deploy_dependencies`
  - `blockers`
  - `next_steps`

### 3.4 `technical_logging`

- `default_agent`: `99-logger-agent`
- `allowed_agents`:
  - `99-logger-agent`
- `inputs`:
  - `repo_manifest`
  - `ci_config`
  - `deploy_spec`
- `outputs`:
  - `workflow_report`
- `done_when`:
  - 已產出可追溯的流程摘要
  - 已標示本次 workflow 產物與狀態
- `handoff_schema`:
  - `workflow_id`
  - `step_status`
  - `artifacts`
  - `followups`

## 4. 下一步

- 後續可把 capability registry 從 Markdown 移到 YAML 或 JSON
- `.cap.agents.json` 可擴充 `capabilities` 欄位，承接 `capability -> agent` 映射
- engine 實作時，應以 capability contract 驗證 step 產物，而不是只看 agent 名稱
