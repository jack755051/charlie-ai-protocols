# H2 Project Skill Drift — Design Memo (accepted baseline)

> 本文件是 H2 #2-#6 的設計 baseline。`H2 #1`（即本 memo）為 doc-only，記錄 H2 整段在 commit 前的裁定；後續 H2 #2-#6 實作必須 cross-reference 本 memo 對應段落。
>
> 範圍：把 H1 留下的 `replay-verdict.drift_details.project_skill_diff` reserved-null forward contract 升為實際 drift detection。給定一個歷史 `run_id`，**雙軸**判斷：(a) builtin agent-skills 是否漂移（H1 既有）、(b) project layer skill 是否漂移（H2 新增）。
> 非範圍：workflow YAML drift、capability schema drift、constitution drift、real replay execution、evaluation suite — 全部繼續 deferred 到 H3 / H4+。

## 1. 目標（Goals）

1. **雙軸 drift 判斷**：給定 run_id，同時看 builtin baseline 與 project layer skill state 是否影響 replay 資格。
2. **Project skill 範圍精確**：覆蓋 `<project_root>/.cap/skills.yaml` 與 `<project_root>/.cap/skills/*.{yaml,yml,json}`（per-skill 檔），與 `RuntimeBinder._resolve_layer_registry` 的讀取範圍對齊。
3. **使用者實際使用的 project skill 才會影響 verdict**：對齊 H1 對 prompt_files_used 的精準度設計，靠 binding summary 知道哪些 project skill 被該 run 用過。
4. **Verdict 仍是單一 5-state enum**：consumer 機器解析不需學新 enum；雙軸結果取最嚴重者作為 verdict，細節在 `drift_details.project_skill_diff`。
5. **不破既有**：H1 既有 envelope（`agent_skills_baseline` 但無 project skill 資料）走部分 verdict；pre-A0 #4 envelope（連 builtin baseline 都沒有）仍是 `unverifiable`。
6. **Schema 不 bump**：H1 已預留 `project_skill_diff: object | null` forward contract；H2 把 null 變 object body 是 widening，不是 breaking。

## 2. Snapshot 範圍（Q1 = B）

`<project_root>/.cap/skills.yaml`（flat）+ `<project_root>/.cap/skills/*.{yaml,yml,json}`（per-skill）。

**不**做 effective spec（合併過 `disabled` / `replaces` 後的最終 skill）：

- effective spec 要重跑 `engine/runtime_binder.py:_apply_override_contract`，scope 過大。
- 兩個檔內容 hash 已足夠標示「project layer 是否 byte-for-byte 不變」；effective state 是衍生產物，由 builtin + project layer 內容決定。

> Snapshot 不讀 shared layer (`<cap_home>/shared/skills.yaml`) — shared layer 是 cross-project 個人習慣，treat as 環境設定，不歸 run-level snapshot 管。

## 3. Selection 範圍（Q2 = B — Binding Summary）

### 3.1 為什麼需要 binding summary

H1 用 `agent-sessions.json sessions[].prompt_file` 來識別 builtin baseline 中該 run 用過的 prompt files。但 `prompt_file` 是 path（如 `agent-skills/04-frontend-agent.md`），不是 `skill_id`，無法判斷該 prompt 來自哪個 layer（builtin / project / shared）。

精準的 project skill drift 要回答「該 run 用的某個 skill 是 project layer override，且該 override 內容變了」。沒有 skill_id + source_layer 對映，verifier 只能粗略判斷「project skill 整體是否變動」，無法分 incompatible / compatible。

### 3.2 Binding Summary 結構

每次 run 在 `agent-sessions.json` envelope 加新欄位 `binding_summary`（與 `agent_skills_baseline` 並列，不嵌入 sessions ledger）：

```json
{
  "binding_summary": {
    "schema_version": 1,
    "captured_at": "2026-05-07T01:23:45Z",
    "steps": [
      {
        "step_id": "draft_frontend_impl",
        "selected_skill_id": "builtin-frontend",
        "skill_source": {"source_layer": "builtin", "source_path": "..."}
      },
      {
        "step_id": "audit_security",
        "selected_skill_id": "my-security-custom",
        "skill_source": {"source_layer": "project", "source_path": "/.../proj/.cap/skills.yaml"}
      }
    ]
  }
}
```

只記四欄：`step_id` / `selected_skill_id` / `skill_source.source_layer` / `skill_source.source_path` — `runtime_binder.bind_semantic_plan` 已產出完整 binding report，這是它的精簡投影。

> 完整 binding report 已存於 `<run_dir>/binding-report.json`（另一條 deferred surface）；本欄位只是讓 verifier 不必跨 artifact 解析。

### 3.3 Runtime attach 時機

`cap-workflow-exec.sh` 在 binding report 落地後（`run-binding-report.json` 寫完）順手把摘要 attach 進 `agent-sessions.json` envelope。對齊 A0 #4 baseline attach 的 best-effort 模式：失敗只 warn 不 halt。

### 3.4 Selection 規則（verifier）

對於該 run 用過的每個 step：
- 如果 `skill_source.source_layer == "project"` → 該 `selected_skill_id` 是 project skill 的「used」候選。
- 對 used 候選逐一比對 stored snapshot vs current snapshot 中該 `skill_id` 的 hash。

## 4. Verdict 雙軸聚合（Q3 = A，single verdict 取最嚴重）

### 4.1 雙軸 builtin × project 結果交叉表

| Builtin axis | Project axis | 聚合 verdict |
|---|---|---|
| replayable | replayable | replayable |
| replayable | drifted_compatible | drifted_compatible |
| replayable | drifted_incompatible | drifted_incompatible |
| drifted_compatible | replayable | drifted_compatible |
| drifted_compatible | drifted_compatible | drifted_compatible |
| drifted_compatible | drifted_incompatible | drifted_incompatible |
| drifted_incompatible | * | drifted_incompatible |
| any | unverifiable_axis (僅該軸不可判) | 取另一軸結果（不全域降級） |
| unverifiable_axis | unverifiable_axis | unverifiable |
| any | not_found | not_found（envelope 異常層級） |

### 4.2 為什麼單軸 unverifiable_axis 不全域降為 unverifiable

H1 既有 run（有 `agent_skills_baseline` 但無 `project_skill_baseline` / 無 binding_summary）的 builtin axis 是可判斷的。如果單軸缺資料就把整體 verdict 降為 unverifiable，會讓 H1 的 verdict 在 H2 實作後反而退化 — 對既有 run 無端造成 noise。

設計上：每個 axis 各自輸出 `replayable` / `drifted_compatible` / `drifted_incompatible` / `unverifiable_axis`，聚合時 unverifiable_axis 視為 neutral，不影響 verdict 由另一軸決定。

只有當**所有軸都是 unverifiable_axis** 時，整體 verdict 才是 `unverifiable`。

### 4.3 Project axis 的 5 個內部狀態

| Axis verdict | 條件 |
|---|---|
| `replayable` | `was_recorded=true` + observed.dir_hash 等於 current.dir_hash + skills_used 全部對齊 |
| `drifted_compatible` | `was_recorded=true` + dir_hash 不一致但 skills_used 全部對齊 |
| `drifted_incompatible` | `was_recorded=true` + skills_used 中至少一個 hash 變動或被 mask 撤銷 / 移除 |
| `unverifiable_axis` | `was_recorded=false`（envelope 沒 project_skill_baseline 或 binding_summary） |
| `replayable` (special: no project layer) | `was_recorded=true` + project layer 整個不存在（observed 與 current 都無檔，dir_hash 為 sha256:empty） |

注意 `unverifiable_axis` **只**寫進 `drift_details.project_skill_diff.axis_verdict`，不會直接出現在頂層 `verdict` enum（仍然是 H1 的 5-state）。

## 5. Schema 升版（Q4 = A，schema_version 留 1）

H1 的 `replay-verdict.schema.yaml` `drift_details.project_skill_diff` 已是 `[object, "null"]`。H2 把 object body 寫實：

```yaml
drift_details:
  project_skill_diff:
    type: [object, "null"]
    description: |
      H2 fills this from reserved-null forward contract (H1 v1) to a
      structured object body. v0.22.0+ rules:
        * H2 runs (cap-workflow-exec.sh post-attach):
            object with was_recorded=true and full drift breakdown.
        * Pre-H2 runs verified after H2 lands:
            object with was_recorded=false; axis_verdict=unverifiable_axis;
            current state still surfaced for reader reference.
        * Pre-A0 #4 runs (no agent_skills_baseline at all):
            stays null (consumer interprets as "H1 contract not yet
            applicable for this run").
    properties:
      was_recorded:
        type: boolean
      axis_verdict:
        type: string
        enum: [replayable, drifted_compatible, drifted_incompatible, unverifiable_axis]
      project_dir_present_observed:
        type: [boolean, "null"]
      project_dir_present_current:
        type: boolean
      dir_hash_observed:
        type: [string, "null"]
      dir_hash_current:
        type: string
      skills_used:
        type: array
        items: {type: string}
        description: |
          Distinct project layer skill_ids used by this run, derived
          from binding_summary.steps[*].selected_skill_id where
          skill_source.source_layer == "project". Empty when
          binding_summary missing or no project layer steps.
      skills_changed:
        type: array
        items: {type: string}
      skills_removed:
        type: array
        items: {type: string}
      skills_added_masked:
        type: array
        items: {type: string}
        description: |
          skill_ids that the original run could see but are now masked
          (disabled: true / replaces target) in current registry.
          These are subset of skills_used; treated as drifted_incompatible.
      reason:
        type: [string, "null"]
```

這是純 widening：原本 nullable object 仍合法（H1 producer 寫 null），H2 producer 寫 full body，schema 都接受。`schema_version: 1` 不變。

## 6. Per-Run Snapshot 檔擴展（與 design memo §4.1 對齊）

H1 已經在 `<run_dir>/snapshots/` 預留 subdir。H2 加：

```
<run_dir>/snapshots/
├── agent-skills.json        ← H1（builtin baseline mirror）
├── project-skills.json      ← H2 新加（project layer mirror）
└── binding-summary.json     ← H2 新加（binding summary mirror）
```

`project-skills.json` 是 envelope `project_skill_baseline` 的 byte-for-byte mirror；`binding-summary.json` 是 envelope `binding_summary` 的 mirror。同 H1，envelope 是 SSOT，mirror 是投影。

## 7. Runtime Hook + Lazy Backfill（Q5 = C）

### 7.1 Runtime attach（primary path）

`cap-workflow-exec.sh` 在 run-start 時序：
1. 建 `agent-sessions.json` envelope（既有）
2. **A0 #4**：attach `agent_skills_baseline`（既有）
3. **H2 新增**：attach `project_skill_baseline`（best-effort，project layer 不存在時寫 empty object 標 `project_dir_present=false`）
4. 跑完每個 step 的 binding 後 → 寫 `runtime-state.json`（既有）
5. **H2 新增**：所有 step binding 完成後，把 binding_summary attach 進 envelope（best-effort）

### 7.2 Verifier lazy 補

當 `cap replay verify <run_id>` 跑時：

| Envelope 狀態 | Verifier 行為 |
|---|---|
| 有 `project_skill_baseline` + `binding_summary` | 完整 H2 drift detection |
| 有 `project_skill_baseline` 但無 `binding_summary` | snapshot 算 dir_hash 變動，但 `skills_used=[]`；axis verdict 退化為 `drifted_compatible` 或 `replayable`（無法判 incompatible，conservatively 不報 incompatible） |
| 無 `project_skill_baseline` | axis_verdict = `unverifiable_axis`；`drift_details.project_skill_diff.was_recorded=false`；envelope 不被 verifier 修改（不 lazy 寫，因為 observed side 無法回推） |
| 連 `agent_skills_baseline` 也沒（pre-A0 #4） | H1 既有：top-level verdict = `unverifiable`；project_skill_diff 仍是 null（forward contract 維持） |

`<run_dir>/snapshots/project-skills.json` 寫入規則：
- 有 envelope baseline → mirror 寫該 baseline（與 H1 對稱）
- 無 envelope baseline → 不寫（mirror 不偽造）

> 「盡量補」的範圍：snapshot 檔系（兩個 mirror）盡量補；envelope 內欄位**不**lazy 補（avoid silent state mutation）。

### 7.3 為什麼不 lazy 補 envelope

A0 #4 `agent_skills_snapshot.attach_to_envelope` 是 idempotent 但會寫；那是 runtime-attach 時序的一部分。H2 verifier 不修改 envelope，因為：
- envelope 是 run-time 觀察結果的 SSOT；verify-time 補資料會混淆「這是 run 當時的 state」與「這是 verify 當時的 state」。
- 如果使用者要重 stamp，明確跑 `python engine/project_skills_snapshot.py attach <sessions_path>`，與 A0 #4 既有 CLI 對稱。

## 8. CLI 介面（沿用 H1）

`cap replay verify <run_id>` 介面不變。新增的雙軸資訊全部走 verdict envelope 的 `drift_details` 欄位，consumer 想看 project axis 自行讀 `drift_details.project_skill_diff.axis_verdict`。

人類可讀 summary 多印一行 project axis 狀態（當 `was_recorded=true`）：

```
cap replay: drifted_incompatible — /Users/.../run_xxx
  reason: prompt_files_changed=04-frontend-agent.md; project_skills_changed=my-frontend-react18
  builtin:  drifted_incompatible (1 prompt changed)
  project:  drifted_incompatible (1 skill changed)
  verdict file:    /Users/.../run_xxx/replay-verdict.json
  snapshot mirror: /Users/.../run_xxx/snapshots/agent-skills.json
                   /Users/.../run_xxx/snapshots/project-skills.json
```

## 9. Deferred 維持

| 項目 | Defer 給 |
|---|---|
| Workflow YAML drift（該 run 用過的 workflow 檔被改） | H3 |
| Capability schema drift | H3 |
| Constitution drift（allowed_capabilities / workflow_policy） | H3 |
| Shared layer skill drift | H3 (and shared registry policy) |
| Effective spec snapshot（合併過 disabled/replaces 的最終 skill） | 後續 deeper batch |
| Full replay execution（真重跑） | H4+ |

## 10. Acceptance Checklist（H2 整段）

- [ ] **H2 #1** — 本 memo（doc-only）作為 H2 #2-#6 baseline。
- [ ] **H2 #2** — `engine/project_skills_snapshot.py` + CLI + unit test。
- [ ] **H2 #3** — `replay-verdict.schema.yaml` `project_skill_diff` 從 null 升 object；schema test fixture 加 H2 cases。
- [ ] **H2 #4** — `cap-workflow-exec.sh` runtime attach（project skill baseline + binding summary）；`engine/replay_verifier.py` 雙軸聚合；`<run_dir>/snapshots/project-skills.json` + `binding-summary.json` mirror。
- [ ] **H2 #5** — verifier dual-axis tests（4 個聚合場景）+ shell wrapper e2e drift simulation。
- [ ] **H2 #6** — `policies/replay-contract.md` 升版、`docs/cap/REPLAY-USER-GUIDE.md` 補 project drift 場景、`development-records/closeouts/h2-closeout.md`、TODOLIST 章節。

## 11. Implementation Sequencing

對齊使用者的 commit-granularity rule（doc → contract → runtime → harness → tests → docs）：

1. **H2 #1**（commit）— 本 memo。
2. **H2 #2**（commit）— `engine/project_skills_snapshot.py` + Python-side test。
3. **H2 #3**（commit）— schema + schema fixture test。
4. **H2 #4**（commit）— `cap-workflow-exec.sh` hook + verifier dual-axis 聚合 + binding_summary attach。
5. **H2 #5**（commit）— integration tests（dual-axis verifier + shell e2e）。
6. **H2 #6**（commit）— policies / user guide / closeout / TODOLIST。

每個 sub-item 一個 commit，每個帶 focused test 或 doc-only 變動，全綠後 push。

## 12. Design Decisions Locked

- **Q1 = B**：snapshot 涵蓋 `.cap/skills.yaml + .cap/skills/*`，不做 effective spec。
- **Q2 = B**：靠 binding summary attach 做 selection，envelope 多 `binding_summary` 欄位。
- **Q3 = A**：single verdict enum；雙軸取最嚴重，細節在 `project_skill_diff`。
- **Q4 = A**：schema_version 留 1，是 widening。
- **Q5 = C**：runtime attach primary，verifier 不 lazy 補 envelope（只補 mirror 檔）；單軸 unverifiable_axis 不全域降級為 unverifiable。
- **Shared layer 不在 H2 範圍**：跨 project 個人習慣不歸 run-level snapshot 管。
- **Project_skill_diff null 條件鎖死**：只在 envelope 連 `agent_skills_baseline` 都沒（pre-A0 #4）時為 null，其他情況都是 object body（含 `was_recorded=false` 的場景）。
- **Verifier 不修改 envelope**：避免「run-time 觀察 vs verify-time 觀察」混淆；補 envelope 走獨立 CLI（同 A0 #4 attach 模式）。
