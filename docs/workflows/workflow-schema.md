# Workflow Schema (v2 base, with extensions through v6)

> 本文件定義 `schemas/workflows/*.yaml` 的 schema 契約。
> v2 是核心欄位定義；v3-v6 為向後相容的擴充版本，僅引入新欄位或新 fallback 條件，未破壞既有結構。

## 1. 目標

workflow schema 用來描述：

- 流程識別
- step 順序與依賴
- step 所需能力 (capability)
- step 的輸入輸出與完成條件
- 品質門禁與失敗路由

它**不負責**定義 agent prompt，也**不直接綁定**某個 agent 檔名。

## 2. 頂層欄位

| 欄位 | 型別 | 必填 | 說明 |
|---|---|---|---|
| `workflow_id` | string | yes | workflow 的穩定識別碼，建議 kebab-case |
| `version` | integer | yes | schema 版本（目前範圍 `1` 至 `6`，見 §3.4 演進說明） |
| `name` | string | yes | 人類可讀名稱 |
| `summary` | string | yes | 一句話描述 workflow 目的 |
| `owner` | string | no | 維護團隊或主要責任角色 |
| `triggers` | string[] | no | 適用情境，例如 `manual`, `repo-intake`, `delivery` |
| `artifacts` | object | no | workflow 級別的共同產物定義 |
| `governance` | object | no | Watcher / Logger 的治理模式與 checkpoint 定義 |
| `steps` | array | yes | 流程步驟清單 |

### 2.1 `governance` 欄位

| 欄位 | 型別 | 必填 | 說明 |
|---|---|---|---|
| `watcher_mode` | string | no | `always_on`, `milestone_gate`, `final_only`, `off` |
| `logger_mode` | string | no | `full_log`, `milestone_log`, `final_only`, `off` |
| `watcher_checkpoints` | string[] | no | 必須由 Watcher 介入的 step id 清單 |
| `logger_checkpoints` | string[] | no | 必須由 Logger 留痕的 step id 清單 |
| `halt_on_missing_handoff` | boolean | no | 缺少正式交接單時是否阻斷往下執行 |
| `goal_stage` | string | no | workflow 預設目標階段，例如 `informal_planning`, `formal_specification` |
| `context_mode` | string | no | 預設上下文傳遞模式，例如 `summary_first` |
| `step_count_budget` | integer | no | workflow 預設主線步數上限，用於治理 phase 膨脹 |
| `max_primary_phases` | integer | no | 預設主線最多放行的 phase 數；超出部分應轉為 standby / opt-in |

## 3. Step 欄位

### 3.1 v1 欄位（向後相容）

| 欄位 | 型別 | 必填 | 說明 |
|---|---|---|---|
| `id` | string | yes | step 識別碼，workflow 內唯一 |
| `name` | string | yes | 人類可讀名稱 |
| `capability` | string | yes | 此步驟所需能力（對應 `schemas/capabilities.yaml`） |
| `needs` | string[] | no | 依賴的前置 step id |
| `inputs` | string[] | no | 需要的 artifact 或上下文名稱 |
| `outputs` | string[] | no | 產出的 artifact 名稱 |
| `done_when` | string[] | no | 完成條件摘要 |
| `optional` | boolean | no | 是否可跳過，預設 `false` |
| `on_fail` | string | no | 失敗後的建議行為：`halt`, `reroute`, `retry` |
| `notes` | string[] | no | 補充說明 |

### 3.2 v2 新增欄位

| 欄位 | 型別 | 必填 | 說明 |
|---|---|---|---|
| `parallel_with` | string[] | no | 可同時執行的 step id（例如 watcher + security） |
| `gate` | object | no | 品質門禁定義 |
| `gate.type` | string | no | `all_pass`（全數通過才放行）或 `any_pass` |
| `gate.partner` | string | no | 門禁夥伴 step id（與 `parallel_with` 搭配） |
| `on_fail_route` | array | no | 條件式失敗路由 |
| `on_fail_route[].condition` | string | no | 失敗條件標籤（如 `LH_PERF_FAIL`, `SRE_TRIGGER`） |
| `on_fail_route[].route_to` | string | no | 目標 step id |
| `record_level` | string | no | 此步驟的紀錄層級：`trace_only` 或 `full_log` |
| `timeout_seconds` | integer | no | 此 step 的硬性執行上限；未設定時由 executor 預設值決定 |
| `stall_seconds` | integer | no | 此 step 的靜默上限；若輸出檔連續 N 秒無新增內容，executor 可視為卡住並中止 |
| `stall_action` | string | no | 靜默達上限時的處置：`warn` 或 `kill`；預設 `warn`，避免誤殺正常但暫無串流輸出的 AI CLI |
| `input_mode` | string | no | 預設下游讀取模式：`summary` 或 `full` |
| `output_tier` | string | no | 輸出層級，例如 `planning_artifact`, `full_artifact`, `handoff_summary` |
| `continue_reason` | string | no | 此 step 在主線中繼續執行的理由；供 runtime 治理與審計使用 |
| `executor` | string | no | step 執行器：`ai`（預設）或 `shell` |
| `script` | string | no | `executor: shell` 時必填；必須引用 repo 內白名單 script，例如 `scripts/workflows/*.sh` |
| `fallback` | object | no | shell step 失敗或語意不明時的回流設定 |
| `fallback.executor` | string | no | fallback 執行器，目前支援 `ai` |
| `fallback.when` | string[] | no | 允許 fallback 的條件，例如 `ambiguous_change_type`, `mixed_change_type`, `git_operation_failed` |

### 3.3 Skill 相容性欄位（用於 binding）

| 欄位 | 型別 | 必填 | 說明 |
|---|---|---|---|
| `compatible_workflow_versions` | integer[] | n/a | 不在 workflow yaml 內，但 `.cap.skills.yaml` 內的 skill entry 必須宣告它能服務哪些 workflow 版本，否則 RuntimeBinder 會 fallback 到其他 skill |

### 3.4 版本演進說明

| 版本 | 主要變動 | 範例 workflow |
|---|---|---|
| v1 | 基礎欄位（id / name / capability / needs / inputs / outputs / done_when） | `readme-to-devops.yaml` |
| v2 | 新增 `parallel_with` / `gate` / `on_fail_route` / `record_level` | （見 §4.2 範例） |
| v3 | 引入 `input_mode` / `output_tier` / `continue_reason` / `goal_stage` / `step_count_budget` 等治理欄位 | `project-code-analysis.yaml` |
| v4 | 引入 `executor: shell` / `script` / `fallback` 三欄位，支援 hybrid AI + shell 流程；首版 hybrid 採取 shell quick path 優先、ambiguous 時回流 AI 的單 step 設計 | 已被 v6 取代的早期版本控制 workflow |
| v5 | shell executor 強化：要求 commit subject 來自 git diff 訊號（不得用固定模板）、加入 low_signal_subject 等 fallback 條件 | （已被 v6 取代） |
| v6 | 多 step pipeline 拆分：`vc_scan(shell) → vc_compose(ai) → vc_apply(shell)`，shell 只做掃描與守門，AI 只負責語意，apply 階段對 envelope 做出口 lint | 已收斂為 `version-control.yaml` |
| v7 | 將 version-control 的 quick / governed / company 差異收斂為 `strategies`，單一 workflow 透過 `--strategy fast|governed|strict|auto` 調整治理強度 | `version-control.yaml` |

新版本只擴充欄位、不破壞舊 yaml；舊 v1 / v2 yaml 仍可被 RuntimeBinder 載入並執行。

### 3.5 shell executor exit code contract

`executor: shell` 的退出碼語意統一由 `docs/policies/workflow-executor-exit-codes.md` 定義。核心契約如下：

| Code | Condition | Executor 行為 |
|---:|---|---|
| `0` | `success` | 登記 artifact，繼續下一步 |
| `10` | `no_changes` | 視為成功 no-op |
| `20` | `ambiguous_change_type` | 若 `fallback.when` 允許，交給 AI；否則 halt |
| `21` | `mixed_change_type` | 若 `fallback.when` 允許，交給 AI 拆 commit 或選主要 type；否則 halt |
| `30` | `policy_blocked` | 預設 halt；只有明確允許才 fallback |
| `40` | `git_operation_failed` | 若 `fallback.when` 允許，交給 AI 診斷或重試；否則 halt |
| `50` | `sensitive_file_risk` | 直接 halt，不得 fallback |

## 4. 範例

### 4.1 v1 最小範例

```yaml
workflow_id: readme-to-devops
version: 1
name: README To DevOps Delivery
summary: 先完成 repo intake 與 README 治理，再交由 DevOps 建立交付基線
governance:
  watcher_mode: final_only
  logger_mode: milestone_log
  watcher_checkpoints: [setup_delivery]
  logger_checkpoints: [normalize_repo, setup_delivery, archive_result]
  halt_on_missing_handoff: true
steps:
  - id: normalize_repo
    name: Normalize README And Manifest
    capability: readme_normalization
    outputs:
      - repo_manifest
      - repo_summary

  - id: setup_delivery
    name: Prepare Delivery Baseline
    capability: devops_delivery
    needs:
      - normalize_repo
    inputs:
      - repo_manifest
    outputs:
      - ci_config
      - deploy_spec
```

### 4.2 v2 品質門禁範例

```yaml
- id: structure_audit
  name: Code Structure Audit
  capability: code_structure_audit
  needs: [frontend, backend]
  outputs: [audit_report]
  on_fail: reroute
  parallel_with: [security_audit]
  gate:
    type: all_pass
    partner: security_audit

- id: qa
  name: QA Testing
  capability: qa_testing
  needs: [structure_audit, security_audit]
  on_fail: reroute
  on_fail_route:
    - condition: SRE_TRIGGER
      route_to: sre
    - condition: LH_PERF_FAIL
      route_to: sre
    - condition: LH_A11Y_FAIL
      route_to: frontend
  record_level: full_log
```

## 5. 設計限制

- `steps` 預設為有序清單；`parallel_with` 允許標記可同時執行的 step
- `needs` 表達依賴；執行器應結合 `needs` 與 `parallel_with` 決定排程
- `done_when` 是給 orchestrator 與 reviewer 的摘要條件，不是可執行程式碼
- Workflow 不嵌入 prompt 內容
- `governance.*_checkpoints` 內的 step id 必須存在於同一個 workflow

## 6. 與 capability contract 的關係

`capability` 的語意與輸入輸出要求統一維護在：

`schemas/capabilities.yaml`

workflow 只需引用 capability 名稱，避免重複定義。

## 7. 與 agent registry 的關係

workflow schema 不處理 `capability -> agent` 的最終綁定。

目前正式 runtime 由 `RuntimeBinder` 負責：

- 優先讀取 `.cap.skills.yaml`，解析 `capability -> skill / agent_alias / prompt_file / cli`
- 若 `.cap.skills.yaml` 缺席，透過 `.cap.agents.json` legacy adapter 維持相容
- `schemas/capabilities.yaml` 的 `default_agent` 是預設偏好，不是 workflow 對 agent 檔案的直接依賴
