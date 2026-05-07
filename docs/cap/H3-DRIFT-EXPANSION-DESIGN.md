# H3 Drift Expansion — Design Memo (ACCEPTED, Cost-Aware Minimal)

> **狀態**：H3 #1 design memo locked。Q1–Q6 all answered (=A) per cost-aware constraint。後續 H3 #2–#5 實作必須 cross-reference 本 memo 對應段落。
>
> 範圍：把 `cap replay verify` 從 H1+H2 雙軸（builtin agent-skills × project layer skill）擴張到 5 軸 — 加入 workflow YAML、constitution、capability schema（三軸全部 whole-file hash）。
> 非範圍（per Cost-Aware lock-down）：per-step / per-capability / per-field hash、shared layer skill、real replay execution、`--strict-unverifiable` flag、binding_summary 擴欄位、effective merged spec snapshot — 全部 deferred 到 H4+。

## 1. H3 解決的問題

H1 + H2 已能回答：「該 run 用過的 builtin prompt 與 project skill 有沒有變？」但對其他 inputs 還是盲的：

- **Workflow YAML**：使用者改了該 run 用過的 workflow 檔，verdict 沒反應。
- **Constitution**：`<project_root>/.cap/constitution.yaml` 變了（allowed_capabilities / workflow_policy / binding_policy），verdict 沒反應。
- **Capability schema**：`<cap_root>/schemas/capabilities.yaml` 變了（default_agent / allowed_agents），verdict 沒反應。

H3 minimal 把這三個 input axis 補上，**但只做 whole-file hash**：

- Hash 一致 → axis_verdict = `replayable`
- Hash 不一致 → axis_verdict = `drifted_compatible`（**不可能** drifted_incompatible，因為沒做 selection 精度）
- 無 baseline → axis_verdict = `unverifiable_axis`（中立）

精度的代價：whole-file hash 不知道變動是否影響該 run，conservatively 只報 compatible drift。Caller 看到 drifted_compatible 時要自己 inspect 改了什麼。這是 Cost-Aware 的明確 trade-off。

## 2. 軸總覽（5 軸完整版）

| 軸 | 來源 | 落地批次 | 精度 |
|---|---|---|---|
| Builtin agent-skills | `<cap_root>/agent-skills/*.md` | A0 #4 + H1 | per-file hash + selection precision |
| Project layer skills | `<project_root>/.cap/skills.yaml` + `.cap/skills/*` | H2 | per-skill hash + selection precision |
| **Workflow YAML** | 該 run 用過的 `<workflow_id>.yaml` 一個檔 | H3 | whole-file hash only |
| **Constitution** | `<project_root>/.cap/constitution.yaml` | H3 | whole-file hash only |
| **Capability schema** | `<cap_root>/schemas/capabilities.yaml` | H3 | whole-file hash only |

## 3. 設計目標

1. **Cost-Aware**：每軸 attach 成本 = 1 file read + 1 SHA-256，攤入 run-start overhead 應 < 30ms。
2. **Symmetric snapshot pattern**：每軸 `engine/<axis>_snapshot.py` 模組對齊 A0 #4 / H2 #2（`compute_snapshot` / `attach_to_envelope` + argparse CLI），但內容極小。
3. **Verifier 多軸聚合**：`_aggregate_axes` 從 2 軸擴成 5 軸，仍取最嚴重非中立軸；`unverifiable_axis` 中立規則維持。
4. **Schema 不 bump**（Q6）：`drift_details` 加 3 個新 nullable object 欄位，`schema_version: 1` 不變。
5. **不破既有**：H1 / H2 既有 envelope 缺新軸 → 三軸全 `unverifiable_axis`，top-level verdict 不變。

## 4. Sub-item 切分（5 commits 目標，per cost-aware lock-down）

| Sub | 範圍 | 規模 |
|---|---|---|
| **H3 #1b** | 本 memo locked（doc-only，narrow scope） | 小 |
| **H3 #2** | `engine/workflow_yaml_snapshot.py` + `engine/constitution_snapshot.py` + `engine/capability_schema_snapshot.py` 三模組 + 共用 helper + combined unit test | 中 |
| **H3 #3** | `replay-verdict.schema.yaml` widening（3 新 nullable 欄位） + verifier multi-axis aggregation + schema fixture upgrade | 中 |
| **H3 #4** | `cap-workflow-exec.sh` 3 attach hooks + `cap-replay.sh` per-axis output + e2e multi-axis case | 中 |
| **H3 #5** | policy v1.2 + user guide + H3-CLOSEOUT + TODOLIST | 小 |

> 估規模：約 H1 + H2 加總的 **35–40%**（whole-file hash 排除了 selection 邏輯與 binding_summary 擴展，每個 snapshot module 規模僅 50–80 行）。

## 5. 軸 Snapshot 結構（normative）

### 5.1 Workflow YAML axis

```yaml
workflow_yaml_baseline:
  schema_version: 1
  workflow_id: project-spec-pipeline
  workflow_path: /abs/path/to/used.yaml
  source_layer: project | shared | builtin | explicit  # 沿用 P9 #4
  content_hash: sha256:<hex>
  computed_at: 2026-05-07T...Z
```

Drift 偵測（whole-file hash only）：
- `content_hash` 一致 → `replayable`
- `content_hash` 不一致（同一 path 仍存在）→ `drifted_compatible`
- workflow file 不存在於當前 path → `drifted_compatible`（標 reason="workflow file missing at expected path"）
- 無 `workflow_yaml_baseline` → `unverifiable_axis`

### 5.2 Constitution axis

```yaml
constitution_baseline:
  schema_version: 1
  constitution_path: /abs/path/to/.cap/constitution.yaml
  constitution_present: true | false
  content_hash: sha256:<hex>  # null when constitution_present=false
  computed_at: ...
```

Drift 偵測（whole-file hash only，無 per-block）：
- `content_hash` 一致 → `replayable`
- `content_hash` 不一致 / 文件被刪 / 文件被新建 → `drifted_compatible`
- 無 baseline → `unverifiable_axis`

### 5.3 Capability schema axis

```yaml
capability_schema_baseline:
  schema_version: 1
  schema_path: /abs/path/to/schemas/capabilities.yaml
  content_hash: sha256:<hex>
  computed_at: ...
```

Drift 偵測（whole-file hash only，無 per-capability）：
- 規則同 §5.2

## 6. Verdict 多軸聚合（5 軸）

擴 H2 既有 `_aggregate_axes` 接受 N 個 axis verdicts：

```python
_AXIS_SEVERITY = {VERDICT_REPLAYABLE: 0, VERDICT_DRIFTED_COMPATIBLE: 1, VERDICT_DRIFTED_INCOMPATIBLE: 2}

def _aggregate_axes(*axis_verdicts: str) -> str:
    candidates = [_AXIS_SEVERITY[v] for v in axis_verdicts if v in _AXIS_SEVERITY]
    if not candidates:
        return VERDICT_UNVERIFIABLE
    return _AXIS_SEVERITY_INV[max(candidates)]
```

每個 axis_verdict 仍是 H1+H2 既有的 `replayable / drifted_compatible / drifted_incompatible / unverifiable_axis`；H3 三軸只能輸出前兩 + `unverifiable_axis`，但 aggregator 不需特殊化（whole-file 軸的 incompatible 永遠不會被 emit）。

## 7. CLI 介面（沿用 H2 + H2.5，不加新 flag）

`cap replay verify <run_id> [--json] [--no-write] [--project-id <id>]` — 介面不變。新軸進 `drift_details`，consumer 自行讀。

人類可讀 summary 多 3 行：

```
cap replay: drifted_compatible — /Users/.../run_xxx
  reason: builtin replayable; project replayable; workflow drifted_compatible (whole-file hash differs)
  builtin:    replayable
  project:    replayable
  workflow:   drifted_compatible (content_hash differs)
  constitution: replayable
  capability_schema: replayable
  verdict file:    /Users/.../run_xxx/replay-verdict.json
  snapshot mirror: /Users/.../run_xxx/snapshots/agent-skills.json
                   /Users/.../run_xxx/snapshots/project-skills.json
                   /Users/.../run_xxx/snapshots/binding-summary.json
                   /Users/.../run_xxx/snapshots/workflow-yaml.json
                   /Users/.../run_xxx/snapshots/constitution.json
                   /Users/.../run_xxx/snapshots/capability-schema.json
```

## 8. Locked Design Decisions（Q1–Q6 = A）

- **Q1 = A**：workflow YAML axis 只 hash 該 run 用過的**那一個** workflow 檔；不做 dependent workflow / dir-wide aggregate。
- **Q2 = A**：capability schema 全檔 hash；**不**做 per-capability hash（成本不夠低不會做、低就 inline）。
- **Q3 = A**：binding_summary 不擴欄位；保持 H2 既有 `step_id / selected_skill_id / skill_source`。
- **Q4 = A**：constitution 整檔 hash；不做 per-block (allowed_capabilities / workflow_policy / binding_policy) 拆分。
- **Q5 = A**：shared layer skill drift **deferred** 到 H4+；H3 不碰 `<cap_home>/shared/`。
- **Q6 = A**：`schema_version` 留 1，widening forward contract。

附帶設計拍板：

- **Whole-file hash 不可能輸出 drifted_incompatible**：精度上 H3 三軸最多到 drifted_compatible；caller 看到後自己決定要不要更深 inspect。這是顯式接受的精度損失，避免 H3 變太大。
- **`--strict-unverifiable` flag deferred**：使用者沒明確要求；不為 H3 minimal 的核心；deferred 到 H4。
- **Verifier 不修改 envelope**：與 H2 一致。
- **每軸 snapshot 模組結構對稱 A0 #4 / H2 #2**：維持「`compute_snapshot` / `attach_to_envelope` / argparse CLI」三件套。

## 9. 影響半徑（Backward Compatibility）

- **H1 既有 run**：envelope 沒新軸 → 三軸全 `unverifiable_axis`，top-level verdict 不變。
- **H2 既有 run**：同上，三軸全 `unverifiable_axis`。
- **新 H3 run**：cap-workflow-exec.sh 補 attach 新軸 → 完整 5-axis 判斷（每軸最多 drifted_compatible 精度）。
- **Schema_version 留 1**：所有現有 verdict 檔仍 schema-valid。
- **Smoke**：H3 預期不破 H1+H2 既有 80 step，新增 ~2 step（H3 #2 snapshot test、H3 #4 multi-axis e2e 擴）。

## 10. Deferred 維持

| 項目 | Defer 給 |
|---|---|
| Per-step workflow hash（區分 used vs unused steps） | H4+（如真有需求） |
| Per-capability schema hash | H4+ |
| Per-block constitution hash（allowed_capabilities / workflow_policy / binding_policy 拆） | H4+ |
| Shared layer skill drift（`<cap_home>/shared/`） | H4+ |
| `--strict-unverifiable` flag | H4+ |
| `binding_summary` 擴欄位（每 step 加 capability / executor） | H4+ |
| Real replay execution（真重跑） | H4+ |
| Effective merged spec snapshot | H4+ |
| Workflow `needs` cross-workflow drift（若未來引入） | 視需要 |

## 11. Acceptance Checklist

- [x] **H3 #1b** — 本 memo locked（本 commit）
- [ ] **H3 #2** — 3 個 snapshot 模組 + combined test
- [ ] **H3 #3** — schema widening + verifier multi-axis aggregation + fixture upgrade
- [ ] **H3 #4** — runtime hooks + cap-replay output + e2e
- [ ] **H3 #5** — docs / closeout

## 12. Implementation Sequencing

每個 sub-item 一個 commit，doc → snapshot → schema/verifier → runtime/e2e → closeout 順序：

1. H3 #1b（commit）— 本 memo lock
2. H3 #2（commit）— 3 snapshot modules
3. H3 #3（commit）— schema widening + verifier multi-axis
4. H3 #4（commit）— runtime hooks + cap-replay output + e2e
5. H3 #5（commit）— docs / closeout

每個 commit 帶 focused test 或 doc-only 變動，全綠後 push。
