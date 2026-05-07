# CAP H2 Closeout — Project Skill Drift / Deterministic Input Snapshot v1

> **狀態**：H2 #1–#6 全段於 main 落地（commits `e64cf74` / `3a82dc4` / `cde71c4` / `f8a0ec9` / `f0a2d93` + 本 closeout commit），已 push origin/main。Smoke 80/80 passed。
>
> H2 把 H1 預留的 `project_skill_diff` reserved-null forward contract 升為實際 drift detection；現在 `cap replay verify` 同時看 builtin baseline 與 project layer skill state。

## 1. H2 解決的問題

H1 落地後使用者馬上會問：「我改了專案的 `<project_root>/.cap/skills.yaml`（disabled / replaces / 新 skill），verdict 怎麼還是 replayable？」H1 v1 只判 builtin agent-skills，project layer 完全 invisible — `drift_details.project_skill_diff` 永遠是 null。對於 A0 #2 引入的 `disabled` / `replaces` override 契約特別矛盾：使用者明明用 project skill 客製化了 binding，replay 卻看不到。

H2 把這個 gap 填上。每次 run 完，verdict 帶兩軸結果：builtin axis（H1 既有）＋ project axis（H2 新加），top-level 取最嚴重的非中立軸。

## 2. 六個子項與 commit chain

| Sub-item | 範圍 | Commit | 主要產物 |
|---|---|---|---|
| **H2 #1** | design memo | `e64cf74` | `docs/cap/H2-PROJECT-SKILL-DRIFT-DESIGN.md` |
| **H2 #2** | project skills snapshot module + CLI | `3a82dc4` | `engine/project_skills_snapshot.py` + 21-assertion test |
| **H2 #3** | schema widening | `cde71c4` | `replay-verdict.schema.yaml` `project_skill_diff` 升 object body + 6 case fixture |
| **H2 #4** | runtime hooks + dual-axis verifier + mirrors | `f8a0ec9` | `engine/binding_summary.py`、`runtime_binder.py` propagate skill_source、`replay_verifier.py` dual-axis、`cap-workflow-exec.sh` triple attach、`cap-replay.sh` per-axis output |
| **H2 #5** | dual-axis aggregation tests | `f0a2d93` | 17-assertion focused test 覆蓋 4 個聚合場景 + binding_summary + neutral 路徑 |
| **H2 #6** | docs / closeout | 本 commit | `policies/replay-contract.md` v1.1、`docs/cap/REPLAY-USER-GUIDE.md` 新章節、本 closeout、TODOLIST 章節 |

## 3. SSOT 索引

### 3.1 Policies

| 路徑 | 角色 |
|---|---|
| [`policies/replay-contract.md`](../../policies/replay-contract.md) | v1.1 normative SSOT — dual-axis verdict semantics、was_recorded 規則、null vs object body 嚴格條件 |

### 3.2 Schemas

| 路徑 | 角色 |
|---|---|
| [`schemas/replay-verdict.schema.yaml`](../../schemas/replay-verdict.schema.yaml) | `drift_details.project_skill_diff` 從 H1 reserved-null 升為 fully-typed object body；`schema_version: 1` 不變 |

### 3.3 Engine modules

| 模組 | 角色 |
|---|---|
| [`engine/project_skills_snapshot.py`](../../engine/project_skills_snapshot.py) | project layer skill snapshot：dir_hash + per-skill_id canonical-JSON hash + flat / per-skill 雙形支援 |
| [`engine/binding_summary.py`](../../engine/binding_summary.py) | 從 bound plan 提取 `[step_id, selected_skill_id, skill_source]` 投影 + envelope attach helper |
| [`engine/replay_verifier.py`](../../engine/replay_verifier.py) | `_compute_builtin_axis` + `_compute_project_axis` + `_aggregate_axes` + `_compose_reason`；`write_project_skill_mirror` / `write_binding_summary_mirror` |
| [`engine/runtime_binder.py`](../../engine/runtime_binder.py) | `build_bound_execution_phases_from_semantic` 把 `skill_source` 傳入 bound step / standby / deferred dict |

### 3.4 Shell harness

| 路徑 | 變更 |
|---|---|
| [`scripts/cap-workflow-exec.sh`](../../scripts/cap-workflow-exec.sh) | run-start 多兩個 best-effort attach：project_skill_baseline + binding_summary（與 A0 #4 對稱） |
| [`scripts/cap-replay.sh`](../../scripts/cap-replay.sh) | 人類可讀輸出加 per-axis 兩行；mirror file 列表擴 3 個 |

### 3.5 Tests

| 路徑 | 範圍 |
|---|---|
| [`tests/scripts/test-project-skills-snapshot.sh`](../../tests/scripts/test-project-skills-snapshot.sh) | snapshot module（21 assertions / 9 cases） |
| [`tests/scripts/test-replay-verdict-schema.sh`](../../tests/scripts/test-replay-verdict-schema.sh) | schema fixture（H1 12 + H2 6 = 18 cases） |
| [`tests/scripts/test-replay-verifier-dual-axis.sh`](../../tests/scripts/test-replay-verifier-dual-axis.sh) | 4 聚合場景 + neutral path + binding_summary helper（17 assertions / 8 cases） |

> Smoke：`scripts/workflows/smoke-per-stage.sh` 從 H1 closeout 後的 78 step 升至 **80 step**（+2 H2 step：snapshot + dual-axis），全綠 0 regression。

### 3.6 User-facing docs

| 路徑 | 角色 |
|---|---|
| [`docs/cap/H2-PROJECT-SKILL-DRIFT-DESIGN.md`](H2-PROJECT-SKILL-DRIFT-DESIGN.md) | H2 design memo（rationale / Q1-Q5 locked / aggregation cross-table） |
| [`docs/cap/REPLAY-USER-GUIDE.md`](REPLAY-USER-GUIDE.md) §8 | 使用者導向 H2 章節：dual-axis 範例、was_recorded 三種狀態、pre-H2 run 補救流程 |

## 4. 設計裁定（locked，不再重議）

| 編號 | 內容 |
|---|---|
| Q1 | snapshot 涵蓋 `<project_root>/.cap/skills.yaml + .cap/skills/*.{yaml,yml,json}`，**不**做 effective spec |
| Q2 | binding_summary attach 給 selection 提供 skill_id × source_layer 對映 |
| Q3 | single verdict enum，雙軸取最嚴重；細節在 `project_skill_diff` |
| Q4 | schema_version 留 1（widening forward contract） |
| Q5 | runtime attach primary，verifier 不 lazy 補 envelope（只補 mirror 檔） |

附帶設計拍板：

- **Per-axis `unverifiable_axis` 中立**：單軸缺資料不全域降為 unverifiable；只有兩軸都缺才 top-level unverifiable。避免 H1 既有 run 在 H2 ship 後莫名退化。
- **Project_skill_diff null 嚴格條件**：只在 envelope 連 `agent_skills_baseline` 都沒（pre-A0 #4 run）時才為 null；其他情況都是 object body。
- **`skills_added_masked` H2 v1 留空**：偵測 mask 變化要重跑 `_apply_override_contract`，scope 過大；object body 已經有欄位作為 forward contract，後續 batch 才 populate。
- **Binding summary 從 plan_json 萃取**：不重跑 binding；plan_json 已含 skill_source（H2 #4 順手讓 `runtime_binder.build_bound_execution_phases_from_semantic` 傳入）。
- **Verifier 不修改 envelope**：避免「run-time 觀察 vs verify-time 觀察」混淆；補 envelope 走獨立 CLI（`engine/project_skills_snapshot.py attach`）。

## 5. 沒解決的部分（Deferred to H3 / H4+）

| 項目 | Defer 給 |
|---|---|
| Workflow YAML drift（該 run 用過的 workflow 檔被改） | H3 |
| Capability schema drift（`schemas/capabilities.yaml`） | H3 |
| Constitution drift（`<project_root>/.cap/constitution.yaml` allowed_capabilities / workflow_policy） | H3 |
| Shared layer skill drift（`<cap_home>/shared/skills.yaml`） | H3 |
| `--strict-unverifiable` 旗標把 unverifiable 升為 exit 4 | H3 |
| `snapshots/workflows/<id>.yaml.json` / `capabilities.yaml.json` / `constitution.yaml.json` mirror | H3 |
| Effective merged spec snapshot（合併 disabled / replaces 後最終 skill 形狀） | 後續 deeper batch |
| `skills_added_masked` 真實 populate（偵測 H2 後新增的 mask） | 後續 |
| Full replay execution（真重跑、pinned baseline 模式、`cap replay run`） | H4+ |
| `cap replay diff <run_id>` file-level diff renderer | 後續 |
| `cap replay status` 列出所有 run 的 verdict | 後續 |

## 6. 影響半徑（Backward Compatibility）

- **A0 #4 之前的 run**：envelope 沒 `agent_skills_baseline` → top-level verdict = `unverifiable`，`project_skill_diff` = `null`（H1 行為保留）。
- **H1 既有 run**（有 `agent_skills_baseline` 但無 `project_skill_baseline` / `binding_summary`）：top-level verdict 不變，但 `project_skill_diff` 從 `null` 變 object body（`was_recorded=false`，`axis_verdict=unverifiable_axis`）。Consumer 若 strictly check `is None` 需更新；check `not psd or not psd.get("was_recorded")` 才安全。
- **Schema**：`schema_version: 1` 不變；H1 emitted null 仍 schema-valid。
- **Smoke**：78 (H1 closeout) → 80 (H2)，全綠 0 regression。

## 7. Test Verification

```bash
# Full smoke
bash scripts/workflows/smoke-per-stage.sh
# 預期：Summary: 80 passed, 0 failed, 0 skipped

# H2 個別 fixtures
bash tests/scripts/test-project-skills-snapshot.sh           # H2 #2: 21 assertions
bash tests/scripts/test-replay-verdict-schema.sh             # H2 #3: 18 cases (12 H1 + 6 H2)
bash tests/scripts/test-replay-verifier-dual-axis.sh         # H2 #5: 17 assertions
```

## 8. 後續閱讀順序建議

如果你是第一次看 H2：

1. 先讀 [`docs/cap/REPLAY-USER-GUIDE.md`](REPLAY-USER-GUIDE.md) §8 — 5 分鐘掌握 dual-axis 用法。
2. 再讀 [`policies/replay-contract.md`](../../policies/replay-contract.md) v1.1 — verdict 雙軸聚合 normative + was_recorded 規則。
3. 對 design rationale 有興趣 → [`docs/cap/H2-PROJECT-SKILL-DRIFT-DESIGN.md`](H2-PROJECT-SKILL-DRIFT-DESIGN.md)（Q1-Q5 locked、aggregation cross-table、deferred 列表）。
4. 對下一步（H3 workflow / capability / constitution drift）有興趣 → 等 H3 design memo。
