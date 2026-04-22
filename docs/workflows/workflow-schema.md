# Workflow Schema (Draft v1)

> 本文件定義 `docs/workflows/*.yaml` 的最小 schema，作為 workflow layer 的第一版契約。

## 1. 目標

workflow schema 用來描述：

- 流程識別
- step 順序
- step 之間的依賴
- step 所需能力
- step 的輸入輸出與完成條件

它**不負責**定義 agent prompt，也**不直接綁定**某個 agent 檔名。

## 2. 頂層欄位

| 欄位 | 型別 | 必填 | 說明 |
|---|---|---|---|
| `workflow_id` | string | yes | workflow 的穩定識別碼，建議 kebab-case |
| `version` | integer | yes | schema 版本，初版固定 `1` |
| `name` | string | yes | 人類可讀名稱 |
| `summary` | string | yes | 一句話描述 workflow 目的 |
| `owner` | string | no | 維護團隊或主要責任角色 |
| `triggers` | string[] | no | 適用情境，例如 `manual`, `repo-intake`, `delivery` |
| `artifacts` | object | no | workflow 級別的共同產物定義 |
| `steps` | array | yes | 流程步驟清單 |

## 3. Step 欄位

每個 step 至少應包含：

| 欄位 | 型別 | 必填 | 說明 |
|---|---|---|---|
| `id` | string | yes | step 識別碼，workflow 內唯一 |
| `name` | string | yes | 人類可讀名稱 |
| `capability` | string | yes | 此步驟所需能力 |
| `needs` | string[] | no | 依賴的前置 step id |
| `inputs` | string[] | no | 需要的 artifact 或上下文名稱 |
| `outputs` | string[] | no | 產出的 artifact 名稱 |
| `done_when` | string[] | no | 完成條件摘要 |
| `optional` | boolean | no | 是否可跳過，預設 `false` |
| `on_fail` | string | no | 失敗後的建議行為，例如 `halt`, `reroute`, `retry` |
| `notes` | string[] | no | 補充說明 |

## 4. 最小範例

```yaml
workflow_id: readme-to-devops
version: 1
name: README To DevOps Delivery
summary: 先完成 repo intake 與 README 治理，再交由 DevOps 建立交付基線
triggers:
  - manual
  - repo-intake
steps:
  - id: normalize_repo
    name: Normalize README And Manifest
    capability: readme_normalization
    outputs:
      - repo_manifest
      - repo_summary
    done_when:
      - README 或 repo.manifest.yaml 已補齊

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

## 5. 設計限制

- `steps` 預設為有序清單，v1 不處理複雜 graph 合流語法
- `needs` 允許表達簡單依賴，但執行器仍應以 step 順序為主
- `done_when` 是給 orchestrator 與 reviewer 的摘要條件，不是可執行程式碼
- v1 不直接嵌入 prompt 內容

## 6. 與 capability contract 的關係

`capability` 的語意與輸入輸出要求，不應散落在 workflow 各處；正式契約應統一維護在：

`docs/policies/capability-contracts.md`

workflow 只需引用 capability 名稱，避免重複定義。

## 7. 與 agent registry 的關係

workflow schema 不處理 `capability -> agent` 的最終綁定。該映射應保留在 capability registry 或 `.cap.agents.json` 的擴充欄位中，避免流程檔綁死 implementation。
