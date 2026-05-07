# H4 Scope Split — Design Memo (DRAFT)

> **狀態**：H4 design memo doc-only，尚未開實作。本 memo 主要工作是**避免 H4 變成 full replay monster**：把 H1–H3 累積的 deferred items 拆清楚，讓使用者選擇下一個工作批次的範圍邊界。
>
> **強烈建議閱讀**：本 memo 不是單一 batch 的設計提案，而是把 4 個獨立 concern 並列攤開，讓使用者拍板 H4 = 哪個子集 / H5+ = 哪些。
>
> **不在本 memo 範圍**：實作 / schema / engine / runtime — 全部留給 H4 #2 起，依使用者拍板的範圍開工。

## 1. 背景：H1–H3 closeout 累積的 4 個 deferred concern

| 概念 | 來源 | 當前狀態 |
|---|---|---|
| **Per-axis precision** | H3 closeout §5 row 1-3 | H3 三軸只做 whole-file hash，最多到 `drifted_compatible`。若要升 `drifted_incompatible` 需做：workflow per-step hash、capability per-capability hash、constitution per-block hash。 |
| **Shared layer skill drift** | H1 §4 / H2 §4 deferred | `<cap_home>/shared/skills.yaml` 變動偵測。需新 snapshot 模組對齊 P9 #4 source layer 設計。 |
| **`--strict-unverifiable` flag** | H1 §6 + H3 §10 deferred | `cap replay verify` 加旗標把 unverifiable 升 exit 4。約 10–15 行 shell + 1 case。 |
| **Real replay execution** | H1 §10 / H2 §5 / H3 §5 deferred | `cap replay run <run_id>` 真重跑、pinned baseline 模式。**最大的工作**：runtime isolation、provider 重新 spawn、artifact 凍結比對等。 |

附帶 1 個 H3 dogfood 留下的 small UX issue：

| 概念 | 來源 | 當前狀態 |
|---|---|---|
| **`workflow_yaml_baseline.source_layer = None`** | H3 dogfood report | cap-workflow-exec.sh attach hook 沒傳 `--source-layer` 給 `engine/workflow_yaml_snapshot.py attach`。drift 偵測本身不看此欄位（只比 content_hash），但 audit trace 缺一條訊息。修法：5–10 行從 plan_json 抽 source_layer。 |

## 2. 為什麼 H4 不應該是 full replay monster

把 4 個 concern 全塞進 H4 = 大量 commit 數 + scope creep + 高風險。具體成本：

| Concern | 估規模 | 風險 |
|---|---|---|
| Per-axis precision | 6–8 commits（3 軸 × per-X hash + binding_summary 擴 + verifier 改） | 中（牽動 schema 多處 + 需 binding_summary 擴欄位） |
| Shared layer | 2–3 commits（snapshot 模組 + verifier + tests） | 低（已有 P9 layered resolver pattern） |
| `--strict-unverifiable` | 1 commit（CLI flag + test） | 低 |
| Real replay execution | **10–15 commits**（runtime isolation + provider spawn 重做 + artifact freeze + diff renderer + new schemas） | **高**（牽動 P5 AgentSessionRunner / P6 artifact lineage / P10 promote 全部） |

**全做 = 19–27 commits，H1+H2+H3 加總才 17 commits**。Real replay 一個就比之前所有 H 系列加起來大。

直接把 real replay 放進 H4 = scope creep，違反 user 既定的 cost-aware commit 邊界。

## 3. 提議：H4 收斂為 minimal polish + flag

把 H4 限縮到「最便宜、最有立即價值」的子集，留剩餘 concern 給 H5 / H6 / H7。

### 3.1 H4 minimal scope（3 commits 上限）

| Sub | 範圍 | 規模 |
|---|---|---|
| **H4 #1** | 本 memo（doc-only） | doc |
| **H4 #2** | source_layer fix + `--strict-unverifiable` flag + 加 e2e | 1–2 commits / ~50 行 |
| **H4 #3** | docs / closeout（policy v1.3 + user guide §10 + H4-CLOSEOUT + TODOLIST） | doc-only |

> H4 minimal **不**碰 schema、不開新 axis、不擴 binding_summary。Cost ~ H2.5 polish 等級。

### 3.2 H5+ 候選 batch（遞延等使用者真實 pain 出現）

| Batch | 預期內容 | 何時啟動 |
|---|---|---|
| **H5 (Per-axis precision)** | workflow / capability / constitution per-X hash + 升 axis 可輸出 drifted_incompatible | 使用者真的撞到「whole-file hash 假警報太多」時 |
| **H6 (Shared layer)** | `<cap_home>/shared/skills.yaml` 軸 + binding_summary 認 shared source_layer | 使用者開始用 shared registry 時 |
| **H7+ (Real replay)** | `cap replay run <run_id>` 真重跑 + pinned baseline 模式 + artifact diff renderer | 使用者真的要 reproduce 舊 run 時 — 這是大工程，獨立 batch |

> 每個 H5+ batch 都應該 **doc-only** memo 先行（如 H1 #1 / H2 #1 / H3 #1b 模式）等使用者拍板再開實作。

## 4. 為什麼這樣切（vs 全部塞進 H4）

| 切法 | 優點 | 缺點 |
|---|---|---|
| **全 H4 monster (4 concerns 一起)** | 一次到位 | 19–27 commits、real replay 大改動拖累 minimal polish 上線、user pain 不一定全部存在 |
| **本 memo 提案（H4 minimal + H5/H6/H7 split）** | 立即 ship 小 polish、real replay 等真實 pain 才開、每個 batch 獨立 doc-first | 多 H batch 名稱、需要紀律維持「doc-only memo 先行」 |

選後者的關鍵理由：**deferred 不一定是非做不可**。Per-axis precision、shared layer、real replay 三件事都需要明確的 user pain 才值得開；現在沒人喊就先 deferred，避免做白工。

## 5. Open issue：`workflow_yaml_baseline.source_layer = None`

來源：H3 dogfood report。

**現狀**：
```python
# cap-workflow-exec.sh line ~1010
"${PYTHON_BIN}" "${WF_YAML_SNAPSHOT_PY}" attach "${AGENT_SESSIONS_JSON}" \
    --workflow-path "${WF_SOURCE_PATH}" \
    --workflow-id "${WORKFLOW_ID}"
# 沒傳 --source-layer，導致 baseline 中是 None
```

**影響**：
- ✗ Audit trace 缺一條 source_layer 訊息（"this workflow came from project / shared / builtin"）
- ✓ Drift 偵測本身正常（只比 content_hash）
- ✓ Verdict 行為不受影響

**修法選擇**：
- A：在 cap-workflow-exec.sh 從 plan_json 抽 source_layer 後傳 `--source-layer` (~10 行)
- B：在 plan_json 加 source_layer 頂層欄位後 cap-workflow-exec.sh 順手讀（~10 行 + 1 行 schema doc）
- C：deferred 到 H5 per-axis precision 時一起改

**建議 A** for H4 #2：最便宜、修在 attach 來源就解決，不需擴 plan_json schema。

## 6. H4 minimal acceptance checklist（gated on 拍板）

- [ ] **H4 #1** — 本 memo doc-only（本 commit）
- [ ] **H4 #2** — source_layer fix + `--strict-unverifiable` flag + e2e
- [ ] **H4 #3** — policy v1.3 + user guide § 10 + H4-CLOSEOUT + TODOLIST

## 7. 待拍板問題（Q1–Q4）

### Q1 — H4 範圍
- A：本 memo §3.1 提案（minimal polish + flag）
- B：H4 = minimal + shared layer（~5–7 commits）
- C：H4 = minimal + per-axis precision（~9–11 commits）
- D：H4 = full（4 concerns 一起，19–27 commits）

**建議 A**：cost-aware 一致；shared layer / per-axis 都應有真實 pain 再開。

### Q2 — `--strict-unverifiable` 預設行為
- A：預設 OFF（H1+H2+H3 既有行為），使用者主動 opt-in
- B：預設 ON，使用者要寬鬆要主動 opt-out

**建議 A**：避免破壞既有 consumer。

### Q3 — source_layer fix 修法
- A：從 plan_json 抽（cap-workflow-exec.sh 修）
- B：擴 plan_json schema（runtime_binder 也要動）
- C：deferred

**建議 A**：最小變動、不改 schema。

### Q4 — H5+ 是否在 TODOLIST 預先列為 placeholder
- A：在 TODOLIST 加 H5 / H6 / H7 章節作為 placeholder（無 commit ref，標 deferred）
- B：不預先列，等使用者真開 H5 design memo 才加

**建議 A**：給 future 自己 / 使用者一個明確的 H 系列地圖；deferred 條目不會 noise。

## 8. 如果使用者選 D（full H4），預估時程

純參考。**不建議**。

| Phase | 內容 | 規模 |
|---|---|---|
| Per-axis precision (H4a) | 3 軸 per-X hash + binding_summary 擴 capability/executor 欄位 + verifier 改 | 6–8 commits |
| Shared layer (H4b) | 新 shared_skills_snapshot 模組 + verifier 6th axis + tests | 2–3 commits |
| `--strict-unverifiable` (H4c) | flag + e2e | 1 commit |
| source_layer fix (H4d) | cap-workflow-exec.sh 5 行 | 1 commit |
| Real replay execution (H4e) | runtime isolation + provider spawn 重做 + pinned baseline 模式 + diff renderer + 新 schemas | **10–15 commits** |
| Closeout | docs / policy / TODOLIST | 1 commit |

**Total: 21–29 commits**。每個 commit 帶 focused test / doc。Smoke 預期 + 8–12 step。Real replay 部分牽動 P5 / P6 / P10 多個既有模組，風險與 H1+H2+H3 加總相當，可能還大。

> 結論：full H4 = 至少兩個 milestone 等級的工作量。**不建議**。

## 9. Implementation Sequencing（H4 minimal 拍板後）

1. H4 #1（commit）— 本 memo
2. H4 #2（commit）— source_layer fix + `--strict-unverifiable` flag + e2e
3. H4 #3（commit）— docs / closeout

每個 sub-item 一個 commit，doc → runtime → docs。

## 10. 待拍板再開工

請逐題確認 Q1–Q4。如果使用者選 D（full H4），我會回去重新切 H4a–H4e 子項；選 A（本 memo 預設）我直接依 H4 #2 → #3 開工。
