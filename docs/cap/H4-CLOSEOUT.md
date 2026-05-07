# CAP H4 Closeout — Minimal Polish (Cost-Aware)

> **狀態**：H4 #1–#3 全段於 main 落地（commits `b60ce3d` / `f157e79` + 本 closeout commit），已 push origin/main。Smoke 81/81 passed。
>
> H4 嚴守 minimal scope：只做 `source_layer` audit fix + `--strict-unverifiable` opt-in flag。Per-axis precision、shared layer drift、real replay execution 全部 deferred 到 H5+ placeholder，**不進 H4 production**。

## 1. H4 解決的問題

H3 closeout 後留下兩個 small concern：

1. **`workflow_yaml_baseline.source_layer = None`**（H3 dogfood report）— cap-workflow-exec.sh attach hook 沒從 plan_json 抽 source_layer，envelope 中該欄位永遠 null。drift 偵測本身正常，但 audit trace 缺一條訊息。
2. **`--strict-unverifiable` flag**（H1+H2+H3 共同 deferred）— compliance / archived-run audit 場景需要把 top-level unverifiable 升 exit 4。

H4 一次解決這兩件。**沒做的事比做的事更重要** — H4 design memo 明確把 per-axis precision、shared layer、real replay execution 切到 H5/H6/H7+ 獨立 batch，避免 H4 變成 19–27 commit 的怪物。

## 2. 三個子項與 commit chain

| Sub-item | 範圍 | Commit | 主要產物 |
|---|---|---|---|
| **H4 #1** | design memo (DRAFT, scope split) | `b60ce3d` | `docs/cap/H4-SCOPE-SPLIT-DESIGN.md` |
| **H4 #2** | source_layer fix + `--strict-unverifiable` flag + e2e | `f157e79` | `cap-workflow-exec.sh` plan_json source_layer 抽取、`cap-replay.sh` flag、9 個新 e2e assertions |
| **H4 #3** | policy v1.3 + user guide §10 + closeout + TODOLIST | 本 commit | `policies/replay-contract.md` v1.3、`docs/cap/REPLAY-USER-GUIDE.md` §10、本 closeout、TODOLIST H4 章節 + H5/H6/H7 placeholder |

## 3. SSOT 索引

### 3.1 Policies

| 路徑 | 角色 |
|---|---|
| [`policies/replay-contract.md`](../../policies/replay-contract.md) | v1.3 normative SSOT — `--strict-unverifiable` opt-in 規則、forward look 列出 H5/H6/H7 候選 |

### 3.2 Schemas

無變動。H4 minimal 不擴 schema。schema_version 留 1。

### 3.3 Engine modules

無新模組。`engine/workflow_yaml_snapshot.py` 既有的 `--source-layer` flag 在 H3 #2 已存在，H4 只是讓 cap-workflow-exec.sh 真的傳這個值。

### 3.4 Shell harness

| 路徑 | 變更 |
|---|---|
| [`scripts/cap-workflow-exec.sh`](../../scripts/cap-workflow-exec.sh) | `WF_PLAN_META` 一次抽 (`source_path`, `source_layer`)；attach 呼叫條件性附加 `--source-layer` |
| [`scripts/cap-replay.sh`](../../scripts/cap-replay.sh) | 加 `--strict-unverifiable` 解析；escalation 在 `--json` 分支前套用，escalation trail 印一行人類可讀提示 |

### 3.5 Tests

| 路徑 | 範圍 |
|---|---|
| [`tests/e2e/test-cap-replay-verify.sh`](../../tests/e2e/test-cap-replay-verify.sh) | case 10 (4 sub-cases × strict on/off × verdict in {unverifiable, replayable} × text/JSON) + case 11 (2 sub-cases: snapshot CLI 接 `--source-layer` + bash-equivalent extraction)，總 e2e 從 35 升至 44 assertions |

> Smoke：`scripts/workflows/smoke-per-stage.sh` 維持 **81 step**（H4 不加新 smoke step；既有 e2e fixture 內部擴張），全綠 0 regression。

### 3.6 User-facing docs

| 路徑 | 角色 |
|---|---|
| [`docs/cap/H4-SCOPE-SPLIT-DESIGN.md`](H4-SCOPE-SPLIT-DESIGN.md) | H4 design memo (DRAFT) — Q1–Q4 locked = A，full-H4 worst-case 列在 §8 供未來參考 |
| [`docs/cap/REPLAY-USER-GUIDE.md`](REPLAY-USER-GUIDE.md) §10 | 使用者導向 H4 章節：`--strict-unverifiable` 場景、單軸 unverifiable_axis 不被升級的設計理由 |

## 4. 設計裁定（locked, Q1–Q4 = A）

| 編號 | 內容 |
|---|---|
| Q1 | H4 範圍 = minimal polish + flag；shared layer / per-axis / real replay 全 deferred |
| Q2 | `--strict-unverifiable` 預設 OFF（不破既有 consumer） |
| Q3 | source_layer fix = cap-workflow-exec.sh 從 plan_json 抽（不擴 schema） |
| Q4 | TODOLIST 預先列 H5 / H6 / H7 placeholder（給未來明確地圖） |

附帶設計拍板：

- **單軸 `unverifiable_axis` 不被 strict 升級**：保留 H1+H2+H3 既定的 axis-level neutral 規則。新加 axis（H3 三軸）對舊 envelope 必然是 unverifiable_axis；如果 strict 也升這個，舊 H1/H2 envelope 跑 strict 會莫名 fail。Top-level `unverifiable` 才是真正「無法判斷」狀態，那時升 exit 4 才有意義。
- **Real replay execution 留 H7+ 獨立 batch**：估 10–15 commits，牽動 P5 AgentSessionRunner / P6 artifact lineage / P10 promote 多模組；放進 H4 違反 cost-aware 規範。

## 5. 沒解決的部分（Deferred to H5+ — 已在 TODOLIST 預先列為 placeholder）

| Batch | 預期內容 | Gating condition |
|---|---|---|
| **H5** | per-axis precision — workflow per-step hash / capability per-capability hash / constitution per-block hash；binding_summary 擴 capability 欄位；H3 三軸升可輸出 `drifted_incompatible` | 使用者真的撞到 whole-file hash 假警報太多 |
| **H6** | shared layer skill drift — `<cap_home>/shared/skills.yaml` 軸；新 snapshot 模組對齊 P9 #4 layered resolver | 使用者真的開始用 shared registry |
| **H7+** | real replay execution — `cap replay run <run_id>` 真重跑、pinned baseline 模式、artifact diff renderer、新 schemas | 使用者真的要 reproduce 舊 run |

每個 H5+ batch 都應該 **doc-only memo 先行**（如 H1 #1 / H2 #1 / H3 #1b / H4 #1 模式），等使用者拍板再開實作。

## 6. 影響半徑（Backward Compatibility）

- **預設行為不變**：`cap replay verify` 沒帶 flag 時行為與 H3 closeout 完全一致。
- **H1/H2/H3 既有 envelope**：source_layer fix 只影響 H4+ 之後的 fresh run，舊 envelope `workflow_yaml_baseline.source_layer` 仍是 None，不影響 verdict。
- **`--strict-unverifiable` 不影響非 unverifiable verdict**：replayable / drifted_compatible / drifted_incompatible / not_found 一律不升級。
- **Schema_version 留 1**：所有現有 verdict 檔仍 schema-valid。
- **Smoke**：80 (H2) → 81 (H3) → **81 (H4)**，全綠 0 regression。

## 7. Test Verification

```bash
# Full smoke
bash scripts/workflows/smoke-per-stage.sh
# 預期：Summary: 81 passed, 0 failed, 0 skipped

# H4 個別 fixtures（已在既有 fixture 內擴）
bash tests/e2e/test-cap-replay-verify.sh
# 預期：Summary: 44 passed, 0 failed
#   (H1+H2.5+H3 既有 35 + H4 case 10/11 新 9 assertions)
```

## 8. 後續閱讀順序建議

1. 先讀 [`docs/cap/REPLAY-USER-GUIDE.md`](REPLAY-USER-GUIDE.md) §10 — 5 分鐘掌握 `--strict-unverifiable` 用法。
2. 再讀 [`policies/replay-contract.md`](../../policies/replay-contract.md) v1.3 — exit code mapping + forward look。
3. 對 design rationale 有興趣 → [`docs/cap/H4-SCOPE-SPLIT-DESIGN.md`](H4-SCOPE-SPLIT-DESIGN.md)（Q1–Q4 locked、為什麼 H4 不該做 real replay 的 §8 worst-case）。
4. 對下一步（H5 per-axis / H6 shared / H7 real replay）有興趣 → 等對應 design memo 開啟。
