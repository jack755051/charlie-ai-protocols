# H3 Drift Expansion — Design Memo (DRAFT)

> **狀態**：H3 #1 design memo doc-only。本 memo 提出設計方向 + Q1-Qn 設計裁定請使用者拍板。**未動 runtime / schema / engine 任何 production code**；ratification 後再實作 H3 #2 起。
>
> 範圍：把 `cap replay verify` 從 H1+H2 雙軸（builtin agent-skills × project layer skill）擴張到多軸 drift detection — 加入 workflow YAML / capability schema / constitution / shared layer skill。
> 非範圍：real replay execution（H4+ 才碰）、evaluation suite（不歸 H 系列）。

## 1. H3 解決的問題

H1 + H2 已能回答：「該 run 用過的 builtin prompt 與 project skill 有沒有變？」但對其他 inputs 還是盲的：

- **Workflow YAML drift**：使用者改了 `<workflow_id>.yaml`（step 順序、capability 換、新增 / 拿掉 step），verdict 沒反應。
- **Capability schema drift**：`schemas/capabilities.yaml` 改了某個 capability 的 default_agent / allowed_agents，binding 結果可能不同，verdict 沒反應。
- **Constitution drift**：`<project_root>/.cap/constitution.yaml` 的 `allowed_capabilities` / `workflow_policy.enforce_allowed_source_roots` 變了，binding gate 結果不同，verdict 沒反應。
- **Shared layer drift**：`<cap_home>/shared/skills.yaml` 的 skill 變了（在 enforce_allowed_source_roots=true 且使用者顯式 allow shared 路徑時），verdict 沒反應。

H3 把這些 input axis 補上。哲學上對齊 A0 #4 "input baseline → drift detection" 模式：每個影響 binding/execution 結果的 input artifact 都要 snapshot + verify。

## 2. 軸總覽（H1 + H2 + H3 完整版）

| 軸 | 來源 | 落地批次 | 狀態 |
|---|---|---|---|
| Builtin agent-skills | `<cap_root>/agent-skills/*.md` | A0 #4 + H1 | ✓ 已實作 |
| Project layer skills | `<project_root>/.cap/skills.yaml` + `.cap/skills/*` | H2 | ✓ 已實作 |
| **Workflow YAML** | `<used_workflow_path>` | H3 | 本 memo |
| **Capability schema** | `<cap_root>/schemas/capabilities.yaml` | H3 | 本 memo |
| **Constitution** | `<project_root>/.cap/constitution.yaml` | H3 | 本 memo |
| **Shared layer skills** | `<cap_home>/shared/skills.yaml` 等 | H3 | 本 memo |

## 3. 設計目標（Goals）

1. **Symmetric snapshot pattern**：每個新軸都有 `engine/<axis>_snapshot.py` 模組，與 A0 #4 / H2 模式對稱（`compute_snapshot` / `compute_summary` / `attach_to_envelope` + argparse CLI）。
2. **Verifier 雙軸 → 多軸聚合**：`_aggregate_axes` 從 2 個 axis 擴成 N 個 axis，仍取最嚴重非中立軸；單軸 `unverifiable_axis` 中立規則保持。
3. **Schema 不 bump**：H3 把 H1 schema 已隱含的 forward contract（`drift_details` 為 open object）填入新欄位；schema_version 留 1。
4. **Runtime attach 為主，verifier 不 lazy 補 envelope**：與 H2 一致，每軸由 `cap-workflow-exec.sh` 在 run-start attach。
5. **不破既有**：H1 / H2 已存在的 envelope 即使沒新軸，verdict 行為維持。新軸缺資料走 `unverifiable_axis` 中立。

## 4. 子項提議（doc → snapshot module → schema → runtime hook → verifier → tests → docs）

| Sub | 範圍 | 規模 |
|---|---|---|
| **H3 #1** | 本 memo（doc-only） | doc |
| **H3 #2** | `engine/workflow_yaml_snapshot.py` 模組 + CLI + unit test | 中 |
| **H3 #3** | `engine/capability_schema_snapshot.py` 模組 + CLI + unit test | 中 |
| **H3 #4** | `engine/constitution_snapshot.py` 模組 + CLI + unit test | 中 |
| **H3 #5** | `engine/shared_skills_snapshot.py` 模組 + CLI + unit test（Q5 待拍板） | 中 |
| **H3 #6** | schema widening — `drift_details` 加 4 個新 axis 欄位 + schema test | 小 |
| **H3 #7** | `cap-workflow-exec.sh` 加 4 個 attach hook + verifier 多軸聚合 + mirror 寫入 | 大 |
| **H3 #8** | `--strict-unverifiable` flag（H1 + H2 共同 deferred）| 小 |
| **H3 #9** | dual/multi-axis aggregation tests + e2e | 中 |
| **H3 #10** | docs / closeout：policy v1.2、user guide、H3-CLOSEOUT、TODOLIST | 小 |

> Q5 若使用者拍板「shared layer 不入 H3」則 H3 #5 移除，9 → 8 sub-items。
> Q4 若 schema 決定 bump 為 schema_version=2 則 H3 #6 多寫舊版相容測試，規模 += 中。

## 5. 各軸 Snapshot 結構提議（normative）

### 5.1 Workflow YAML axis

```yaml
workflow_yaml_baseline:
  schema_version: 1
  workflow_id: project-spec-pipeline
  workflow_path: /abs/path/to/used.yaml
  source_layer: project | shared | builtin | explicit  # 沿用 P9 #4 概念
  content_hash: sha256:<hex>                            # 整個 YAML 檔
  step_hashes:                                           # per-step canonical-JSON hash
    "draft_spec": sha256:...
    "spec_audit": sha256:...
  computed_at: 2026-05-07T...Z
```

Drift 偵測：
- `content_hash` 不一致 → 整體 drift
- 用過的 step 的 `step_hashes` entry 變動 / 移除 → axis_verdict=drifted_incompatible
- 整體 hash 變但 used steps 都對齊 → drifted_compatible
- 該 run 用過 `binding_summary.steps[*].step_id`，從這抽取 used steps

### 5.2 Capability schema axis

```yaml
capability_schema_baseline:
  schema_version: 1
  schema_path: /abs/path/to/schemas/capabilities.yaml
  content_hash: sha256:<hex>
  capability_hashes:                                     # per-capability canonical-JSON hash
    "frontend_implementation": sha256:...
    "watcher_audit": sha256:...
  computed_at: ...
```

Drift 偵測：
- 該 run 用過的 capability 從 `binding_summary.steps[*]` 抽（每個 step 都有 capability，但 binding_summary v1 schema 沒記！）
- **Q3 焦點**：要不要在 H3 把 capability 加進 binding_summary？或從 plan_json 取？

### 5.3 Constitution axis

```yaml
constitution_baseline:
  schema_version: 1
  constitution_path: /abs/path/to/.cap/constitution.yaml
  content_hash: sha256:<hex>
  fields_hash:
    allowed_capabilities: sha256:...
    workflow_policy: sha256:...
    binding_policy: sha256:...
  computed_at: ...
```

Drift 偵測：
- `allowed_capabilities` 內容變動 + 該 run 用過的 capability 仍在 → compatible
- 該 run 用過的 capability 不再在 `allowed_capabilities` 中 → incompatible
- `workflow_policy.enforce_allowed_source_roots` 切換 → 通常 incompatible（會改 binding gate 行為）

### 5.4 Shared layer skill axis（Q5 待拍板）

結構與 H2 project_skill_baseline 完全對稱，只是 path 從 `<project_root>/.cap` 換成 `<cap_home>/shared`。

## 6. Verifier 多軸聚合更新

擴 `_aggregate_axes` 從 2 軸 → N 軸：

```python
_AXIS_SEVERITY = {VERDICT_REPLAYABLE: 0, VERDICT_DRIFTED_COMPATIBLE: 1, VERDICT_DRIFTED_INCOMPATIBLE: 2}

def _aggregate_axes(*axis_verdicts: str) -> str:
    candidates = [_AXIS_SEVERITY[v] for v in axis_verdicts if v in _AXIS_SEVERITY]
    if not candidates:
        return VERDICT_UNVERIFIABLE
    return _AXIS_SEVERITY_INV[max(candidates)]
```

`_compose_reason` 也擴成多軸 — 列出每個非中立軸的具體 drift 原因。

## 7. CLI 介面（沿用 H2 + H2.5）

```bash
cap replay verify <run_id> [--json] [--no-write] [--project-id <id>] [--strict-unverifiable]
```

`--strict-unverifiable`（H3 #8）：把任何 axis 的 unverifiable_axis 升級為 top-level `unverifiable` + exit 4。預設 OFF（保持 H1+H2 既有行為）。

人類可讀輸出每個 axis 一行：

```
cap replay: drifted_incompatible — /Users/.../run_xxx
  reason: workflow_steps_changed=draft_spec; capability_default_changed=frontend_implementation
  builtin:    replayable
  project:    replayable
  workflow:   drifted_incompatible (1 used step changed)
  capability: drifted_incompatible (1 used capability changed)
  constitution: replayable
  shared:     unverifiable_axis (no shared layer recorded)
  ...
```

## 8. 待拍板 Q1-Q6

### Q1 — Workflow YAML axis 範圍
- A：只 hash 該 run 用過的**那一個** workflow 檔（從 `binding_summary.workflow_id` / `runtime-state.json` 反查 path）
- B：A + 該 workflow 透過 `needs` 引用的**所有 dependent workflow 檔**（如有）
- C：B + 整個 `<workflows_dir>` aggregate hash 作為 soft signal

**建議 A**：範圍最小、語意最清楚；workflow 之間目前沒有 ref / include 機制，不需要 B；C 是 noise。

### Q2 — Capability schema axis 是否分 per-capability hash
- A：只記整檔 `content_hash`；任何變動都 → drifted_compatible（無從判 incompatible）
- B：per-capability hash + 從 binding_summary 抽該 run 用過的 capabilities → 精準判 incompatible
- C：B + 偵測 `default_agent` / `allowed_agents` 欄位特定變動

**建議 B**：與 H2 per-skill_id hash 對稱；要 B 就需要把 capability 加進 binding_summary（見 Q3）。

### Q3 — binding_summary 是否擴欄位
- A：保持 H2 既有（step_id / selected_skill_id / skill_source）
- B：每 step 加 `capability`（從 plan_json 已有的欄位抽）
- C：B + 加 `executor`（ai/shell）以利 H3 後續細分

**建議 B**：Q2 的 B 路徑需要這個資料；executor 目前沒人問，留 deferred。

### Q4 — Constitution axis 是否分 per-field hash
- A：只整檔 hash
- B：A + per-field hash（allowed_capabilities / workflow_policy / binding_policy 三大區塊各自 hash）
- C：B + 對 `allowed_capabilities` 做 set diff（specific added / removed）

**建議 B**：B 已足夠分 incompatible（capability 被移除 → 該 run 用過該 capability → incompatible）；C 過度精細，現階段沒明確需求。

### Q5 — Shared layer skill axis 是否在 H3 範圍內
- A：H3 不做 shared layer drift（沿用 H2 deferred 邏輯，等真實 shared registry 用例出現再開 H4）
- B：H3 做 shared layer drift（為一致性，所有 skill source 都覆蓋）

**建議 A**：shared layer 是個人本機跨 project 設定，沒有真實 dogfood 用例；做 B 會讓 H3 範圍變大，增加 1 個 sub-item 與 1 軸 schema 欄位。如果之後真有人開始用 shared，再開 H4。

### Q6 — Schema bump 策略
- A：`schema_version` 留 1，把新軸欄位加進現有 `drift_details`
- B：bump 到 `schema_version: 2`，新欄位 required；舊版仍 schema-valid
- C：把 schema 拆成 `replay-verdict-v1.schema.yaml` + `replay-verdict-v2.schema.yaml`

**建議 A**：與 H2 #3 widening 邏輯對稱；新欄位設為 optional `[object, "null"]`，舊 verifier emit null 仍 valid。Schema description 在 H3 落地時再強化說明 v0.22.0+ runtime 何時 emit object body。

## 9. 影響半徑（Backward Compatibility）

- **H1 既有 run**：envelope 沒新軸 → 4 個新 axis 都 `unverifiable_axis`，top-level verdict 不變。
- **H2 既有 run**：同上，新軸都 `unverifiable_axis`。
- **新 H3 run**：cap-workflow-exec.sh 補 attach 新軸 → 完整 multi-axis 判斷。
- **Schema_version 不 bump（Q6=A）**：所有現有 verdict 檔案仍 schema-valid。
- **`--strict-unverifiable` 預設 OFF**：H1/H2 user 跑 cap replay 行為不變。

## 10. Deferred 維持

| 項目 | Defer 給 |
|---|---|
| Real replay execution（真重跑） | H4+ |
| Effective merged spec snapshot | H4+ |
| Evaluation suite 比對 | 不歸 H 系列 |
| `cap replay diff <run_id>` file-level diff renderer | 後續 |
| `cap replay status` 列出所有 run 的 verdict | 後續 |
| H4 `cap replay run <run_id>` pinned baseline 模式 | H4+ |
| Workflow `needs` cross-workflow drift（若未來 workflow 有 include 機制） | 視需要 |

## 11. Acceptance Checklist（H3 整段，gated on Q1-Q6 拍板）

- [ ] **H3 #1** — 本 memo（doc-only baseline）
- [ ] **H3 #2** — workflow YAML snapshot module + test
- [ ] **H3 #3** — capability schema snapshot module + test
- [ ] **H3 #4** — constitution snapshot module + test
- [ ] **H3 #5** — shared layer skill snapshot（若 Q5=B）
- [ ] **H3 #6** — schema widening + fixture upgrade
- [ ] **H3 #7** — runtime hooks + verifier multi-axis + mirrors
- [ ] **H3 #8** — `--strict-unverifiable` flag
- [ ] **H3 #9** — multi-axis aggregation tests + e2e
- [ ] **H3 #10** — policy / user guide / closeout / TODOLIST

## 12. Implementation Sequencing（拍板後）

對齊既有 commit-granularity rule（doc → snapshot modules → schema → runtime → tests → docs）：

1. H3 #1（commit）— 本 memo
2. H3 #2 / #3 / #4 [/#5]（各 commit）— snapshot modules（可平行，但建議分 commit）
3. H3 #6（commit）— schema widening
4. H3 #7（commit）— runtime hooks + verifier multi-axis（最大 commit，可拆 #7a / #7b）
5. H3 #8（commit）— `--strict-unverifiable` flag
6. H3 #9（commit）— integration tests
7. H3 #10（commit）— docs / closeout

預估規模：8–10 commits、約 H1 + H2 加總的 60% 工作量（每軸 snapshot 模式已驗證、verifier aggregation 已通用化、schema 已 widening-friendly）。

## 13. 需使用者拍板再開工

請逐題確認 Q1–Q6。如需調整 sub-item 拆分（例如把 #2/#3/#4 合併為單一 commit）也請說明。**未拍板前不動任何 production code**；本 memo 是 H3 唯一的 doc-only 落地。
