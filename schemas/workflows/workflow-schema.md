# Workflow Schema (v2)

> 本文件定義 `schemas/workflows/*.yaml` 的 schema 契約。

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
| `version` | integer | yes | schema 版本（`1` 或 `2`） |
| `name` | string | yes | 人類可讀名稱 |
| `summary` | string | yes | 一句話描述 workflow 目的 |
| `owner` | string | no | 維護團隊或主要責任角色 |
| `triggers` | string[] | no | 適用情境，例如 `manual`, `repo-intake`, `delivery` |
| `artifacts` | object | no | workflow 級別的共同產物定義 |
| `steps` | array | yes | 流程步驟清單 |

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

## 4. 範例

### 4.1 v1 最小範例

```yaml
workflow_id: readme-to-devops
version: 1
name: README To DevOps Delivery
summary: 先完成 repo intake 與 README 治理，再交由 DevOps 建立交付基線
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

## 6. 與 capability contract 的關係

`capability` 的語意與輸入輸出要求統一維護在：

`schemas/capabilities.yaml`

workflow 只需引用 capability 名稱，避免重複定義。

## 7. 與 agent registry 的關係

workflow schema 不處理 `capability -> agent` 的最終綁定。該映射保留在 `.cap.agents.json` 的 `capabilities` 欄位中。
