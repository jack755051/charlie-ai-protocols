# Provider Parity Fresh E2E Runbook (v0.21.5 → v0.22.0 baseline gate)

> 本文件是 v0.21.5 closeout 後、v0.22.0 啟動前的 fresh provider parity 驗收 runbook。對應 `docs/cap/MISSING-IMPLEMENTATION-CHECKLIST.md` Release Gate 中「fresh Claude + Codex provider parity full run」與「建議執行順序步驟 2」。
>
> v0.21.5 是用「既有 run + 新版 checker 重跑」驗證，**沒跑過 fresh run**。在 P0（runtime contracts）動 schema 前，必須跑 fresh e2e 確認三件 fix（`1425fa9` / `55038dd` / `2492913`）在新跑的 Claude + Codex 真實執行下無 regression。
>
> 通用 parity e2e checklist 見 [PROVIDER-PARITY-E2E.md](PROVIDER-PARITY-E2E.md)。本文件只列 v0.21.5 特定的執行步驟、預期觀察、與通過條件。

---

## 1. 為什麼必須跑 fresh e2e

| 問題 | 既有 run 重跑能否回答？ | Fresh run 才能回答的事 |
|---|---|---|
| `1425fa9` cap-paths runtime resolver 是否在新 run 中正確解析 project_id？ | ❌ 既有 run 的 project_id 是舊跑出來的；replay checker 不會重新觸發 resolver | ✓ |
| `55038dd` nested fence stripping 是否在 supervisor 真的產出 nested fence 時正確 strip？ | ❌ 既有 run 已經被舊 strip 邏輯處理過 | ✓ |
| `2492913` parity-check §4.2 nonempty vs present-only 是否在 supervisor 真的寫 `non_goals: []` 時 PASS？ | ⚠️ 部分 — 既有 run replay 確認 checker 行為，但沒驗證 supervisor 實際產出 `[]` 時整個 pipeline 不退化 | ✓ |
| 三件 fix 互相之間有無干擾？ | ❌ replay 不會觸發三條程式路徑互動 | ✓ |
| Provider 行為自 v0.21.4 以來有無 drift？（claude-cli / codex-cli 升級、prompt 擾動） | ❌ replay 不會碰 provider | ✓ |

**結論**：fresh e2e 是 P0 啟動前的非可選 baseline。

---

## 2. 環境前置

| 條件 | 必要性 | 驗證指令 |
|---|---|---|
| `cap` CLI 已安裝且在 PATH | 必須 | `cap --version` 應回傳版本（v0.21.5+）|
| `claude` CLI 已登入 | 必須 | `claude --version` 應有輸出，且能跑 `claude` 進入 session |
| `codex` CLI 已登入 | 必須 | `codex --version` 應有輸出 |
| 在 `charlie-ai-protocols` repo 根目錄 | 必須 | `pwd` 應為 `/home/<user>/projects/charlie-ai-protocols` 或對應路徑 |
| `git status` 乾淨 | 強烈建議 | run dir 預設寫到 `~/.cap/projects/charlie-ai-protocols/...`，但 cwd 不乾淨會干擾 repro |
| 當前 commit 在 `v0.21.5` tag 或之後 | 必須 | `git log -1 --oneline` 應為 `v0.21.5` 或更新 |

---

## 3. 執行步驟

### 3.1 Claude 路徑

```bash
cd /home/jack755051/projects/charlie-ai-protocols
cap workflow run \
  --cli claude \
  --no-design \
  project-spec-pipeline \
  "針對 token monitor 產出最小規格，不實作"
```

預期：
- duration：約 1100–1400s（v0.21.3 baseline 1217s）
- final_state：`completed`
- step：**16/16 completed, 0 failed**

記下 run_id 與 run dir 路徑（cap 會印出來）。

### 3.2 Codex 路徑

```bash
cd /home/jack755051/projects/charlie-ai-protocols
cap workflow run \
  --cli codex \
  --no-design \
  project-spec-pipeline \
  "針對 token monitor 產出最小規格，不實作"
```

預期：
- duration：約 1100–1400s（v0.21.3 baseline 1254s）
- final_state：`completed`
- step：**16/16 completed, 0 failed**

記下 run_id 與 run dir 路徑。

### 3.3 同 prompt 確認

兩次 run 必須使用**完全相同的 prompt 字串**。若有任何字元差異（包含半形 / 全形空白、引號），結果不可比對。

---

## 4. Parity check 驗收

對每條 run dir 跑 parity check：

```bash
bash scripts/workflows/provider-parity-check.sh \
  --run-dir <run_dir> \
  --task-id <task_id> \
  --project-id charlie-ai-protocols \
  --workflow project-spec-pipeline
```

`<task_id>` 從 run dir 內的 `runtime-state.json` 或 `~/.cap/projects/charlie-ai-protocols/constitutions/<task_id>.json` 讀。

### 通過條件

| 項目 | 期望 | 對應 v0.21.5 fix |
|---|---|---|
| Claude parity check | **43 PASS / 0 FAIL** | 整體 |
| Codex parity check | **43 PASS / 0 FAIL** | 整體 |
| Type B Task Constitution `non_goals` | PASS（即使是 `[]`）| `2492913` parity-check §4.2 split |
| Run dir 與 constitution / handoff 同一 project_id | 都在 `~/.cap/projects/charlie-ai-protocols/` 下，無雙路徑 | `1425fa9` cap-paths SSOT |
| `runtime-state.json` 顯示 task constitution 已 persisted（無 nested fence parse halt） | PASS | `55038dd` nested fence strip |

### 任何 FAIL 的處置

- **歸因順序**：先比對 v0.21.5 三件 fix 的觸發點 → 再排除 provider drift（claude-cli / codex-cli 版本變化）→ 最後才考慮新 regression
- **若 Claude 與 Codex 都在同一 check 點 FAIL**：高機率是 v0.21.5 fix 沒覆蓋的 case，歸 v0.21.5 hotfix
- **若只有一邊 FAIL**：高機率是 provider-specific 行為，歸 v0.21.6+ 對齊
- **若 FAIL 與 v0.21.5 三件 fix 無關**：屬其他 latent bug，記到 PROVIDER-PARITY-FINDINGS-v0.21.X.md 新檔

---

## 5. 通過後動作

1. **記錄結果**：把兩次 run_id、duration、parity-check 結果摘要寫進 `docs/cap/RELEASE-NOTES.md` v0.21.6 條目（或 v0.21.5 補記）
2. **勾掉 Release Gate**：在 `docs/cap/MISSING-IMPLEMENTATION-CHECKLIST.md` Release Gate 把 fresh provider e2e 那條從 `[ ]` 改 `[x]`，並寫 commit ref
3. **歸檔 runbook**：本文件可移到 `docs/cap/archived/` 或在 v0.22.0 啟動後刪除（不再需要）
4. **啟動 P0**：runtime contracts 7 個 schema 開始

---

## 6. 失敗時的處置

若 fresh e2e 揭露 v0.21.5 漏洞，**禁止直接進入 P0**。流程：

1. 凍結 P0 啟動
2. 在 `charlie-ai-protocols` 開 v0.21.6 hotfix branch
3. 修補後重跑 fresh e2e
4. 通過後再啟動 P0

這條跟 `MISSING-IMPLEMENTATION-CHECKLIST.md` 的「建議執行順序」鎖死：基線未過，不開主軸。

---

## 7. 預估時間成本

| 階段 | 時間 |
|---|---|
| Claude run | 約 20 分鐘 |
| Codex run | 約 20 分鐘 |
| Parity check（兩條）| 約 1 分鐘 |
| 結果記錄 + Release Gate 勾選 | 約 5 分鐘 |
| **總計** | **約 45–50 分鐘**（兩條 run 可並行則減半，但要分開 run dir 與 task_id 避免互相寫入） |
