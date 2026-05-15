# CAP Runtime Promote Policy (v1.0)

> 本文件定義 CAP 的「runtime artifact promote」規則：哪些跑出來的東西可以從 `~/.cap/projects/<id>/` 升級回 repo SSOT、哪些只能留在 runtime archive、target path 怎麼決定、覆寫 / 備份 / validation / rollback 怎麼處理。所有 P10 #2-#8 子項都以本文件為唯一參考。

## 1. 範圍與職責邊界 (Scope & Boundaries)

- **適用對象**：runtime artifact 從 `~/.cap/projects/<project_id>/` 子樹搬回專案 repo（`<project_root>/` 子樹）的所有路徑。
- **不在此範圍**：
  - `policies/run-archive.md` 已負責 `<run_dir>` 的 lifecycle (active → archived → pruned)，本文件不重複處置 archive 規則。
  - 跨 repo 的「publish」（把 cap-protocols 自己升 npm / GitHub release）不屬於 runtime promote；那是 release pipeline 的事。
  - `cap-promote.sh` 既有的 `<local_rel> <repo_rel>` 直接搬檔模式仍然可用，作為 escape hatch；但**它不是 P10 promote surface 的主要入口**，主入口是 P10 #3-#5 的 typed CLI。
- **本文件與 P7 / P9 的關係**：
  - P7 `workflow-result.json` 的 `promote_candidates[]` 由本 policy 定義的 producer (P10 #2) 填入，schema 既有定義不變。
  - P9 layered resolver 的 `_source_layer` / `_source_path` 是判斷「此 artifact 從哪一層來」的依據，本 policy 用它決定 target path。

## 2. Promote 分類 (Promotable Categories)

CAP runtime artifact 分三類：

| 分類 | 範例 | 預設 promotable | 預設 target |
|---|---|---|---|
| **Project Constitution snapshot** | `<cap_home>/projects/<id>/constitutions/<task_id>/constitution.{json,yaml}` | ✓ | `<project_root>/.cap/constitution.yaml` |
| **Compiled Workflow** | `<cap_home>/projects/<id>/compiled-workflows/<workflow_id>/<timestamp>.json` | ✓（限同 workflow_id） | `<project_root>/.cap/workflows/<workflow_id>.yaml` |
| **Spec artifact**（v0.25.7+） | `<run_dir>/4-prd.md` / `6-tech_plan.md` / `8-ba.md` / `10-dba_api.md` / `10-ui.md` | ✓（限 `project-spec-pipeline` 且 `final_state == "completed"`） | `<project_root>/docs/architecture/` 或 `docs/design/`（見 §3.3） |
| **Run-only artifacts** | `<run_dir>/runtime-state.json` / `agent-sessions.json` / `route-history.jsonl` / `<step_id>.raw.log` | ✗ | — |

> **Run-only 為何不可 promote**：這些是 per-run 軌跡（誰跑了什麼、stdout 截錄、route-back 序列），repo 不該收這類「執行過程」資料。它們屬於 `policies/run-archive.md` 規範的 archive scope，由 Logger 結案 + retention 規則處理。

> **Binding report (`bindings/<workflow_id>/binding-*.json`) 是 grey area**：當前**不在預設 promotable 清單**——binding report 是 layered resolver 在某個 cap_home / constitution 配置下對某 workflow 的解析結果，每次 binding 重算，不該凍結進 repo。若使用者有 audit 需求，建議用 `result.md` 的 `Artifacts` section 留 pointer 到 binding 檔即可。

## 3. Target Path 規則 (Repo Target Mapping)

### 3.1 Project Constitution
- **唯一允許 target**：`<project_root>/.cap/constitution.yaml`（namespaced）。
- **不接受 legacy target**：`.cap.constitution.yaml`（root-level legacy）已由 `cap project migrate-config` 規範 migration 路徑；P10 promote **不寫入 legacy 路徑**，避免雙寫。
- **若 legacy 存在 + namespaced 不存在**：promote 仍寫到 namespaced；legacy 保留作 escape hatch（同 `cap project init` 既有處置）。

### 3.2 Compiled Workflow
- **唯一允許 target**：`<project_root>/.cap/workflows/<workflow_id>.yaml`。
- **檔名硬規則**：必須與 `compiled_workflow.workflow_id` 完全一致（小寫 + kebab-case），副檔名 `.yaml`。
- **不允許 partial override**（**對齊 P9 §4.3**）：promote compiled workflow 必須整檔替換；若使用者只想改某 step，要從 namespaced project workflow 起手手動編輯，不走 promote。

### 3.3 Spec Artifact（v0.25.7+）
- **適用條件**：僅 `project-spec-pipeline` workflow 的 run 且 `final_state == "completed"` 才會被 producer 標記為 candidate。其他 workflow（含 `project-implementation-pipeline` 的 codebase 輸出）不走 promote 流程；codebase 由實作 step 直接寫入 `<project_root>/`。
- **target mapping table**：

  | runtime-state artifact name | repo target |
  |---|---|
  | `prd_document` | `docs/architecture/<module>_PRD_v1.md` |
  | `tech_plan_document` | `docs/architecture/<module>_TechPlan_v1.md` |
  | `ba_spec` | `docs/architecture/<module>_BA_v1.md` |
  | `schema_ssot` | `docs/architecture/database/<module>_schema_v1.md` |
  | `api_contract` | `docs/architecture/<module>_API_v1.md` |
  | `ui_spec` | `docs/design/<module>_UI_v1.md` |

- **`<module>` 解析順序**：`run_result.task_id`（slug 化後）→ `run_result.project_id`（slug 化）→ `"module"` 字面值。Slug 規則同 `engine/project_context_loader.py` 的 `_sanitize_project_id`（lowercase / a–z 0–9 . _ -）。
- **不接受 partial override**：每個 spec_artifact 是整份 markdown 替換；同一 target 多份 candidate（理論上不會發生）以最新 source mtime 為準。
- **不寫到 `.cap/`**：spec_artifact target 永遠在 `docs/` 子樹下，不會與 §3.1 / §3.2 的 `.cap/` namespace 衝突。
- **schema 驗證**：spec_artifact 沒有結構化 schema（純 markdown）。`validation_schema` 一律 `null`，post-apply gate（§6）對此類型走 file-existence + non-empty 的最小檢查，不嘗試 JSON Schema validate。

### 3.4 為什麼只允許這三條 target
- 都是 **可被人類審閱、有穩定 repo 位置** 的 artifact。`.cap/constitution.yaml`、`.cap/workflows/<id>.yaml`、`docs/architecture/<module>_*.md` / `docs/design/<module>_*.md` 各有清楚使用情境。
- Constitution 與 compiled workflow 是 schema-validated；spec markdown 是人類審閱對象。
- 其他 runtime artifact（compiled-workflow + binding 的時間戳版本、agent-sessions、handoff tickets、step raw log）刻意不允許 promote，因為它們是 **execution trail**，凍結進 repo 會讓 git history 變雜訊。

## 4. Overwrite / Backup / Skip 規則 (Conflict Handling)

### 4.1 預設行為（dry-run-first）
- **`cap promote` 預設 dry-run**：列出來源 / 目標 / 預期 diff / 是否需要 backup，不實際寫檔。
- **必須顯式 `--apply`** 才實寫。
- 對齊 v0.22.0-rc11 引入的 `cap project migrate-config --dry-run` 既有節奏。

### 4.2 Overwrite 處理
| 狀態 | 預設動作 |
|---|---|
| target 不存在 | 直接寫入。 |
| target 存在且 byte-equal source | skip（標記 `already_promoted`，exit 0）。 |
| target 存在且內容不同 | **halt** with `conflict`；要求 `--force` 才繼續。 |
| target 存在且 `--force` | 寫入前自動 backup（見 §4.3）。 |

### 4.3 Backup 強制
- **任何 `--force` 寫入必須先寫 backup**：`<target>.bak.<ISO timestamp>`。
- Backup **絕不過自動清除**——使用者主動刪。Promote 流程不負責 backup retention。
- Backup 不在 git 追蹤範圍：promote 後若 backup 落在 git-tracked 目錄，CLI 應印 reminder 提醒使用者把 `.bak.*` 加進 `.gitignore`。

### 4.4 不允許靜默改寫
- Promote 過程中 **絕不**靜默修改任何已存在的檔案；上述 conflict / force / backup 三條缺一不可。
- 違反這條的任何 PR 一律 reject（治理紅線，對齊 P9 §7.4 的精神）。

## 5. Promote Candidate Producer (P10 #2 contract)

### 5.1 Producer 位置
P7 `engine/result_report_builder.py:build_workflow_result` 結尾呼叫**新模組** `engine/promote_candidate_producer.py:produce_candidates(run_result, *, project_root, cap_home) -> list[dict]`。`build_workflow_result` 把回傳值寫入 `result["promote_candidates"]`，取代 P0 寫死的 `[]`。

### 5.2 Candidate 形狀
每個 candidate 是 dict，欄位嚴格對齊 `schemas/workflow-result.schema.yaml` 的 `promote_candidates[].items`：

```yaml
required:
  - source_path        # 絕對路徑，runtime artifact 位置
  - target_path        # 絕對路徑或 repo-relative，repo 預期位置
  - artifact_type      # enum: project_constitution | compiled_workflow | spec_artifact
  - reason             # 一句說明為何此 artifact 是 promote candidate
optional:
  - validation_schema  # 對應 schema 路徑（schema 驗證在 promote-after gate 用；spec_artifact 一律 null）
  - source_layer       # 從 P9 _source_layer 拉出（informational）
  - source_revision    # 若有 hash / timestamp / 版本標記則填入
```

`artifact_type` enum **僅**這三個值。其他類型在當前 v1 一律不產出 candidate；新類型必須先進本 policy §2 表才能加 enum。

### 5.3 Producer 偵測規則
- **Project Constitution**：當 `run_result.task_id` 非 null 且 `<cap_home>/projects/<project_id>/constitutions/<task_id>/constitution.{yaml,json}` 存在 → emit candidate，target=`<project_root>/.cap/constitution.yaml`。
- **Compiled Workflow**：當 `run_result.workflow_id` 非空、`<cap_home>/projects/<project_id>/compiled-workflows/<workflow_id>/` 有檔案，且 `final_state == "completed"` → emit candidate（取最新 timestamp），target=`<project_root>/.cap/workflows/<workflow_id>.yaml`。
  - **`final_state != completed` 不 emit**：fail / blocked / cancelled run 的 compiled workflow 不應被 promote，避免把壞掉的編譯結果搬回 repo。
- **Spec Artifact**（v0.25.7+）：當 `run_result.workflow_id == "project-spec-pipeline"`、`final_state == "completed"`，且 `<cap_home>/projects/<project_id>/reports/workflows/project-spec-pipeline/<run_id>/runtime-state.json` 存在 → 讀其 `artifacts` 表，對 §3.3 mapping table 中每個已 `validated` 的 artifact name emit 一支 candidate，target 依 mapping table 計算。
  - **`final_state != completed` 不 emit**：避免把失敗 run 的 partial 規格搬回 repo。
  - **`source_step` 未 `validated` 不 emit**：partial 輸出（agent halted）不能成為 candidate。
  - **`source_path` 不存在 / 已被刪 不 emit**：靜默 skip 該條，其他正常 candidate 不受影響。
- **找不到對應 source on disk**：靜默不 emit；**不**回報 error，因為「沒 source」是 informational。

### 5.4 Producer 邊界
- **不**讀 schema 內容、**不**驗證 source、**不**讀 binding report、**不**讀 P3 supervisor envelope（同 P9 #4 的 pointer-only 精神）。
- **不**自動執行 promote — 只產候選清單。實際 promote 走 `cap promote <type> --apply`。

## 6. Validation After Promote (P10 #6)

Promote `--apply` 寫入 target 後，**必須**重新 validate promoted artifact，失敗時 rollback。

### 6.1 Validation 規則
| Artifact 類型 | Validation step |
|---|---|
| Project Constitution | `step_runtime.py validate-jsonschema <target> schemas/project-constitution.schema.yaml` |
| Compiled Workflow | `step_runtime.py validate-jsonschema <target> schemas/compiled-workflow.schema.yaml` + `engine/compiled_workflow_validator.py:ensure_valid_compiled_workflow`（同 P4 #1 既有 hook） |
| Spec Artifact (v0.25.7+) | 檔案存在 + non-empty + 副檔名為 `.md`。spec markdown 沒有結構化 schema，不跑 JSON Schema validate；`validation_schema` 永遠 `null`，consumer 看到 `null` 時跳過 schema 驗證但仍跑 file-existence + non-empty 檢查。 |

### 6.2 失敗 rollback 規則
- **Validation fail 必須 rollback**：把 target 還原為 promote 前的內容（如有 backup），或刪除（target 原本不存在）。
- Rollback 後印 deterministic JSON `{"ok": false, "error": "promote_validation_failed", "stage": "post_apply", "errors": [...]}` exit 1。
- **rollback 失敗（罕見：磁碟壞或 target 已被外部寫過）**：不要再嘗試 — 印 `rollback_failed` warning，把現場資料路徑列出，停在當下狀態，由使用者人工介入。

### 6.3 Compile / Bind smoke（選配）
- 對 compiled workflow：promote + validate pass 後，**選配**跑一次 `task_scoped_compiler.compile_task` smoke（不 spawn agent，只跑 compile + bind）；smoke 失敗也 rollback。
- 為什麼選配：smoke 比 schema validate 重，一般使用者不需要每次跑。`--smoke` flag 顯式開啟。

## 7. CLI 介面總覽 (Surface)

P10 #3-#5 給的 CLI 介面：

```text
cap promote inspect <artifact_id>             # P10 #3
cap promote project-constitution <task_id>    # P10 #4
cap promote workflow <workflow_id>            # P10 #5

# Common flags:
--dry-run     # default
--apply       # actually write
--force       # overwrite conflict (forces backup)
--smoke       # run compile/bind smoke after promote (workflow only)
--json        # emit JSON instead of human text
--cap-home    # override CAP_HOME (mainly for tests)
```

### 7.1 inspect 行為（P10 #3）
- 輸入：`<artifact_id>` 解釋為 task_id（找 constitution snapshot）或 workflow_id（找 compiled workflow snapshot）。
- 輸出：
  - source path / target path
  - artifact_type
  - 是否會 conflict（target byte-diff with source）
  - 預期 backup 位置（若會 conflict）
  - validation_schema 與 smoke 計畫
  - source_layer（informational）
- **不**寫檔。`--json` 吐 candidate-shaped dict + 額外的 `conflict` 與 `backup_target` 欄位。

### 7.2 project-constitution 行為（P10 #4）
- 收斂 v0.22 之前 `cap project promote-constitution` / `cap-promote.sh` 的既有能力（若仍存在）到統一 surface。
- target 規則同 §3.1。
- legacy `<root>/.cap.constitution.yaml` 處置：promote 不寫 legacy 路徑；若 legacy 與 namespaced 同時存在，印 warning 提醒走 `cap project migrate-config`。

### 7.3 workflow 行為（P10 #5）
- target 規則同 §3.2。
- partial override 禁令同 P9 §4.3：整檔替換或不 promote。
- promote 後**必須**走 §6 validation；建議搭 `--smoke` 在 CI / 重要升級時開。

## 8. Lifecycle 與 Edge Cases

### 8.1 完整 lifecycle
```text
runtime run produces artifacts
        ↓
result_report_builder.promote_candidates[] populates
        ↓
cap promote inspect <id>      # see what would happen
        ↓
cap promote <type> <id> --dry-run    # human / CI dry pass
        ↓
cap promote <type> <id> --apply [--force] [--smoke]
        ↓
post-apply validation          # halt + rollback on fail
        ↓
target written, success JSON / text
```

### 8.2 跨 run 重複 promote
- 同 `task_id` / `workflow_id` 多次 promote 視為合法（schema-validated artifact 可以被新版覆蓋）。
- byte-equal 直接 skip；diff 走 conflict / force / backup 流程。

### 8.3 Promote 失敗後重試
- Validation rollback 後，repo 回到 promote 前的狀態。使用者可以調整 source（重跑 workflow / 修 constitution）後再次 promote。
- 連續失敗不應殘留垃圾檔；rollback 必須清乾淨除了 `.bak.*` 以外所有中間產物。

### 8.4 `cap promote` 既有 list / generic copy mode
- `cap promote list [drafts|reports|all]` 與 `<local_rel> <repo_rel>` 兩條 generic 模式維持作為 escape hatch（已有測試覆蓋；不撤）。
- 文件清楚標示這兩條**不走** §4-§6 的 backup / validation / rollback 流程；使用者要拿生 escape hatch 自負風險。
- 主要使用者體驗推 typed `cap promote project-constitution` / `cap promote workflow`。

## 9. 治理邊界與 Anti-patterns

- **絕不 promote run-only artifact**：`runtime-state.json` / `agent-sessions.json` / `<step_id>.raw.log` 即使使用者 `--force` 也擋；CLI 直接 reject。
- **絕不靜默 overwrite**：見 §4.4。
- **絕不跳過 validation**：見 §6.1；只有 `--skip-validation` 顯式 flag 才略過，且印 BIG WARNING。**v1 不提供此 flag**；保留為未來逃生口（v1 觀察是否真有需求再加）。
- **絕不 promote pre-merge artifact**：partial workflow / partial constitution snapshot 不允許（同 P9 §4.3）。
- **絕不 chained promote**：promote A 觸發 promote B 的 cascade 不允許；每次 `cap promote` 一個 artifact。

## 10. 與其他 policy 的關係

- **`policies/run-archive.md`**：本文件管 promote (run → repo)，run-archive.md 管 lifecycle (run → archive → prune)；兩者**互不取代**。一個 run 可以同時被 archived 與被 promoted（promote 拷貝出去，archive 不變）。
- **`policies/cap-storage.md`**：本文件依賴其定義的 `<cap_home>/projects/<id>/` 子樹結構。
- **`development-records/archive/docs-cap/P9-SOURCE-RESOLVER-DESIGN.md`**：本文件 §3.1 / §3.2 的 target path 直接對齊 P9 §3 三層 resolver 表的 project 路徑（`<project_root>/.cap/{constitution.yaml,workflows/<id>.yaml}`）。

## 11. 變更紀錄 (Changelog)

- v1.0：初版，覆蓋 P10 #1 deliverable。Promote 分類表、target path 規則、conflict / backup / validation / rollback 規則、CLI surface 邊界、與 P7 / P9 / archive 的銜接全部釘下。後續 P10 #2-#8 實作 commit 必須 cross-reference 本文件對應段落。
