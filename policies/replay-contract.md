# CAP Replay Contract Policy (v1.2)

> 本文件定義 `cap replay` 的行為邊界、verdict 語意與 consumer 義務。v1.2 (H3 minimal) 把 v1.1 雙軸擴成 5 軸，新增 workflow YAML / constitution / capability schema 三軸 whole-file hash drift；schema_version 仍為 1（widening）。
> SSOT：`policies/replay-contract.md`（本檔）。
> Schema：[`schemas/replay-verdict.schema.yaml`](../schemas/replay-verdict.schema.yaml)。
> Design rationale：[`docs/cap/REPLAY-CONTRACT-DESIGN.md`](../docs/cap/REPLAY-CONTRACT-DESIGN.md) (H1)、[`docs/cap/H2-PROJECT-SKILL-DRIFT-DESIGN.md`](../docs/cap/H2-PROJECT-SKILL-DRIFT-DESIGN.md) (H2)、[`docs/cap/H3-DRIFT-EXPANSION-DESIGN.md`](../docs/cap/H3-DRIFT-EXPANSION-DESIGN.md) (H3)。
> User guide：[`docs/cap/REPLAY-USER-GUIDE.md`](../docs/cap/REPLAY-USER-GUIDE.md)。

## 1. 範圍與定位

CAP Replay Contract v1.2 回答一個問題：**「給定一個歷史 `run_id`，該 run 對應的 5 軸（builtin agent-skills、project layer skill、workflow YAML、constitution、capability schema）跟當前狀態的差異是否影響 replay 資格？」**

本契約**不**涵蓋：

- 真正重跑 workflow（full replay execution）— 留給 H4+。
- Per-step / per-capability / per-field 精度的 H3 drift detection — H3 minimal 只做 whole-file hash，深度 deferred 到 H4+。
- Shared layer skill drift（`<cap_home>/shared/`）— deferred 到 H4+。
- `--strict-unverifiable` flag — deferred 到 H4+。
- 跨 run 聚合（一次驗證多個 run）— 後續批次。
- Effective merged spec snapshot（合併過 disabled / replaces 後的最終 skill）— 後續更深層批次。

## 2. Verdict 5-state Enum（normative）

| Verdict | 觸發條件 | Consumer 行為建議 |
|---|---|---|
| `replayable` | stored baseline 等於 current baseline（dir_hash 一致 + 所有 prompt_files 對齊） | 可直接 replay（後續 H4+ 提供） |
| `drifted_compatible` | dir_hash 不一致，但該 run 實際使用的 prompt_files 全部對齊 | 仍可 replay；變動的檔案不影響原行為 |
| `drifted_incompatible` | 該 run 使用的某個 prompt_file 內容變動或被刪除 | **不可** replay 為原行為；必須 checkout 對應 commit 或放棄 replay |
| `unverifiable` | stored envelope 沒有 `agent_skills_baseline`（pre-A0 #4 run） | 無法判斷；consumer 自行決定保守處置（預設仍 pass） |
| `not_found` | run_id 對應的 run dir 或 `agent-sessions.json` 缺失 | 該 run 已被 prune 或 run_id 錯誤；不可 replay |

## 3. Drift 偵測範圍（v1.1, dual-axis）

### 3.1 Builtin axis — 主動判斷（影響 verdict）

| 來源 | 偵測方式 |
|---|---|
| `agent-skills/` builtin baseline `dir_hash` | aggregate hash 比對 |
| 該 run 使用的 prompt_files 的 per-file hash | per-file hash 比對 |
| 該 run 使用的 prompt_files 在 current baseline 是否仍存在 | dict key 存在性檢查 |

### 3.2 Project axis — 主動判斷（H2，影響 verdict）

| 來源 | 偵測方式 |
|---|---|
| `<project_root>/.cap/skills.yaml` 整體 dir_hash | aggregate hash 比對（涵蓋 flat + per-skill subdir） |
| 該 run 使用的 project layer skill_id 的 per-skill canonical-JSON hash | binding_summary 過濾 source_layer=project，再對每個 skill_id 比對 hash |
| 該 run 使用的 project skill_id 在當前 registry 是否仍存在 | dict key 存在性檢查 |

### 3.2b H3 axes — 主動判斷（whole-file hash, H3 minimal）

每軸只做 whole-file SHA-256 hash；whole-file hash 不可能輸出 `drifted_incompatible`（無 selection 精度），最多只到 `drifted_compatible`。

| 軸 | 來源 | 偵測方式 |
|---|---|---|
| Workflow YAML | 該 run 用過的單一 workflow 檔（path 從 plan_json source_path 抽） | content_hash 比對 |
| Constitution | `<project_root>/.cap/constitution.yaml` | content_hash 比對 |
| Capability schema | `<cap_root>/schemas/capabilities.yaml` | content_hash 比對 |

### 3.3 Soft signal（記錄但不影響 verdict）

| 來源 | 為什麼不直接降 verdict |
|---|---|
| `cap_version` 變動 | release tag 變動但 `agent-skills/` 沒變，replay 行為仍一致；硬降會造成噪音 |
| `git_commit` 變動 | 同上，可能只是 release commit |
| `git_dirty` 切換 | 不可靠的訊號（暫存檔可能不影響 prompt） |

### 3.4 Verdict 雙軸聚合（normative）

每個軸獨立輸出 axis verdict（`replayable` / `drifted_compatible` / `drifted_incompatible` / `unverifiable_axis`）。Top-level verdict 取**最嚴重的非中立軸**：

- 兩軸都 `replayable` → top-level `replayable`
- 一軸 `replayable` + 一軸 `drifted_compatible` → top-level `drifted_compatible`
- 任一軸 `drifted_incompatible` → top-level `drifted_incompatible`
- 任一軸 `unverifiable_axis` 中立，不影響另一軸的 verdict
- 兩軸都 `unverifiable_axis` → top-level `unverifiable`

### 3.5 Project axis was_recorded 規則（H2）

`drift_details.project_skill_diff.was_recorded`：

- `true`：envelope 同時帶 `project_skill_baseline` AND `binding_summary`（H2 cap-workflow-exec.sh 完整 attach 過）→ 完整 per-skill drift detection。
- `false`：envelope 缺至少一個 → 退化處理：
  - 缺 `binding_summary` 但有 `project_skill_baseline`：dir_hash 不一致 → axis 限制在 `drifted_compatible`（無法 prove `drifted_incompatible`）。
  - 缺 `project_skill_baseline`：axis verdict = `unverifiable_axis`。

### 3.6 `project_skill_diff` null 嚴格條件

僅當 envelope 連 `agent_skills_baseline` 都沒（pre-A0 #4 run、top-level verdict = `unverifiable`）時，`project_skill_diff` 才為 `null`。任何有 builtin baseline 的 run，project_skill_diff 都是 object body（含 was_recorded=false 中立場景）。

## 4. CLI 介面契約

### 4.1 入口

`cap replay verify <run_id_or_run_dir> [--json] [--no-write]`

- 接受 bare run_id（在 `<workflow_report_dir>/*/<run_id>` 下 glob）或絕對 run_dir 路徑（bypass glob）。
- 預設寫 `<run_dir>/replay-verdict.json` 與 `<run_dir>/snapshots/agent-skills.json`；`--no-write` 為 read-only。
- `--json` 印 raw envelope 到 stdout；無此 flag 印人類可讀單行摘要。

### 4.2 Exit code 規範

| Verdict | Exit code | 含義 |
|---|---|---|
| `replayable` | 0 | OK |
| `drifted_compatible` | 0 | warn-but-pass，CI 可進 |
| `unverifiable` | 0 | 不主動視為失敗（H2 可能加 `--strict-unverifiable` 升為 4） |
| `drifted_incompatible` | 4 | block — 對齊 P8 governance gate non-zero pattern |
| `not_found` | 2 | run 不存在 |
| internal error | 1 | 其他錯誤 |

## 5. 持久化規則

### 5.1 `<run_dir>/replay-verdict.json`

- **唯一寫入者**：`cap replay verify` / `engine/replay_verifier.py`。
- **覆寫策略**：覆寫舊檔；verdict 是純函式，不需保留歷史（design memo §5）。
- **Idempotent**：當前 verdict 與 cached 一致 → 不寫（避免無謂 IO）。

### 5.2 `<run_dir>/snapshots/agent-skills.json`

- **唯一寫入者**：`cap replay verify` / `engine/replay_verifier.py`。
- **內容**：與 `agent-sessions.json` envelope 的 `agent_skills_baseline` 欄位 byte-for-byte 一致。
- **角色**：cache / convenience copy。envelope 是 SSOT，mirror 是投影；衝突時以 envelope 為準。
- **Idempotent**：同上。

### 5.3 `<run_dir>/snapshots/project-skills.json`（H2 #4）

- **唯一寫入者**：`cap replay verify`。
- **內容**：envelope `project_skill_baseline` 的 byte-for-byte mirror（含 `skills_by_id` per-skill hash map）。
- **角色**：與 §5.2 對稱，外部工具不必 parse sessions ledger 即可看 project layer 觀察狀態。

### 5.4 `<run_dir>/snapshots/binding-summary.json`（H2 #4）

- **唯一寫入者**：`cap replay verify`。
- **內容**：envelope `binding_summary` 的 mirror（per-step `step_id` / `selected_skill_id` / `skill_source`）。
- **角色**：審計 / 外部 tool 不必透過 plan / binding-report 即可知道該 run 用過哪些 skill_id 與 source_layer。

### 5.5 H3 三軸 mirror（H3 #4）

- `<run_dir>/snapshots/workflow-yaml.json` — envelope `workflow_yaml_baseline` 的 mirror（path / source_layer / content_hash）。
- `<run_dir>/snapshots/constitution.json` — envelope `constitution_baseline` 的 mirror（path / present / content_hash）。
- `<run_dir>/snapshots/capability-schema.json` — envelope `capability_schema_baseline` 的 mirror（path / present / content_hash）。
- 三軸 mirror 規則同 §5.2/§5.3：envelope 是 SSOT，mirror 是 byte-for-byte 投影；衝突時以 envelope 為準。

### 5.6 不允許

- ❌ Consumer 直接編輯 `replay-verdict.json` 或 `snapshots/agent-skills.json`。
- ❌ 用 `replay-verdict.json` 取代 `agent-sessions.json` 作為 baseline 來源（envelope 是 SSOT）。
- ❌ 在 verdict 為 `drifted_incompatible` 時靜默 replay（必須先讓使用者意識到 drift）。

## 6. Backward Compatibility

- **A0 #4 之前的 run**（envelope 沒有 `agent_skills_baseline`）→ verdict 永遠是 `unverifiable`，不嘗試猜測。
- **未掛 H1 之前的 run**（無 `replay-verdict.json` / `snapshots/`）→ 第一次跑 `cap replay verify` 會 lazy 建立。
- **Schema 升版**：`schema_version: 1`；breaking change 才 bump。

## 7. Consumer 義務

凡是接 `replay-verdict.json` 或呼叫 `cap replay verify` 的下游 pipeline（如 promote、archive lifecycle、CI gate）必須：

1. 解析 `verdict` 字串 enum；不要依字面 reason 判斷。
2. 對 `drifted_incompatible` 採行 block 行為（exit non-zero、不繼續 promote、不歸檔為 replayable）。
3. 對 `unverifiable` 不假設「pass」或「fail」；應在 consumer side 自有政策。
4. 不修改 `replay-verdict.json`；若需附加自己的判讀，另寫 sibling 檔。

## 8. 與 A0 #4 baseline snapshot 的關係

| 角色 | A0 #4 | H1 |
|---|---|---|
| **記錄** baseline 是什麼 | ✓（`agent-sessions.json` envelope） | — |
| **比對** baseline 是否漂移 | ✗ | ✓（`replay-verdict.json`） |
| **獨立 per-run snapshot 檔** | deferred | ✓（`snapshots/agent-skills.json`） |
| **CLI 入口** | — | ✓（`cap replay verify`） |

H1 直接消費 A0 #4 寫入的 envelope baseline；不重新計算「該 run 當時的 baseline 是什麼」。

## 9. 後續契約展開（Forward Look）

- **H2 ✓ 已完成**：`drift_details.project_skill_diff` 由 reserved-null 升為 object；新增 `snapshots/project-skills.json` 與 `snapshots/binding-summary.json`；雙軸聚合 normative。
- **H3 ✓ 已完成（minimal scope）**：3 個新 nullable object 欄位 `workflow_yaml_diff` / `constitution_diff` / `capability_schema_diff` 加入 `drift_details`；新增三 mirror 檔；5 軸聚合 normative；whole-file hash 精度（深度 deferred）。
- **H4+**：per-step / per-capability / per-field 精度、shared layer drift、`--strict-unverifiable` flag、full replay execution（真重跑）；可能引入 `cap replay run <run_id>` 與 pinned baseline 模式。
