# Harness Observation Log

> 用途：H 系列暫停期間（2026-05-07 起）追蹤 H5 / H6 / H7+ 的 gating condition 是否被真實 run 觸發。**只記錄不開發**。
>
> 啟動條件對照：
>
> | Batch | Gating signal | 連續觀察建議 |
> |---|---|---|
> | **H5** per-axis precision | whole-file hash 假警報太多（H3 軸 drifted_compatible 但實質沒影響 run） | ≥ 3 次 false positive 才提啟動 |
> | **H6** shared layer drift | 開始使用 `<cap_home>/shared/skills.yaml` | 1 次 real usage 就值得啟動 |
> | **H7+** real replay execution | 真的需要重跑舊 run | 1 次 real reproduce 需求就值得啟動 |
>
> SSOT：本檔。每次重要 workflow run 後手動補一筆。
> 相關文件：[`h4-closeout.md`](../closeouts/h4-closeout.md) §5、[`policies/replay-contract.md`](../../policies/replay-contract.md) §9。

## 1. 欄位模板（給後續 run 填）

每跑一次重要 workflow run，建議在 §3 表格末尾加一筆。欄位定義如下：

| 欄位 | 內容 | 取值 |
|---|---|---|
| `Date` | 跑 verify 的日期（不是 run 啟動日期） | `YYYY-MM-DD` |
| `Run ID` | `<run_dir>` basename | `run_YYYYMMDDhhmmss_<hex>` |
| `Workflow` | workflow_id | 例：`project-constitution` |
| `Top` | top-level verdict | `replayable` / `drifted_compatible` / `drifted_incompatible` / `unverifiable` / `not_found` |
| `Builtin` | builtin agent-skills axis_verdict | `R` (replayable) / `C` (drifted_compatible) / `I` (drifted_incompatible) / `?` (unverifiable_axis) / `—` (legacy null) |
| `Project` | project layer skill axis_verdict | 同上 |
| `Workflow ax` | workflow YAML axis_verdict | 同上（H3 軸最多到 C） |
| `Const` | constitution axis_verdict | 同上 |
| `CapSch` | capability schema axis_verdict | 同上 |
| `H5?` | 觀察到 whole-file hash 假警報？（H3 軸報 drifted_compatible 但實質與 run 行為無關） | `yes` / `no` / `n/a`（沒有 H3 baselines） |
| `H6?` | 此 run 用過 shared layer skill？ | `yes` / `no` |
| `H7?` | 是否嘗試真重跑此 run？ | `yes` / `no` |
| `Action` | 後續處置 | `none` / `H4.x polish` / `open H5 memo` / `open H6 memo` / `open H7 memo` |
| `Notes` | 一行備註（drift 細節、blocking 原因、debug 觀察） | free text |

> 軸狀態縮寫使用 R / C / I / ? / — 避免表格過寬。完整 axis_verdict 字串以 verdict 檔為準。
>
> `H5?` 判斷準則：`Workflow ax` / `Const` / `CapSch` 任一為 `C`，但人工檢查實質沒影響該 run（單純 noise）→ `yes`；如果 `C` 確實反映該 run 受影響的變動 → `no`；如果三軸都是 `?` → `n/a`。

## 2. 跑 verify 的標準命令

```bash
# 一般驗證
cap replay verify <run_id>

# 嚴格模式（compliance / archived-run audit）
cap replay verify <run_id> --strict-unverifiable

# 機器消費（CI / 自動化）
cap replay verify <run_id> --json
```

抓 verdict 詳情：

```bash
python3 -c "
import json
d = json.load(open('<run_dir>/replay-verdict.json'))
dd = d['drift_details']
print('top:', d['verdict'])
print('builtin:', 'I' if dd['prompt_files_changed'] or dd['prompt_files_removed'] else ('C' if not dd['dir_hash_match'] else 'R'))
for k, label in [('project_skill_diff','project'),('workflow_yaml_diff','wf'),('constitution_diff','const'),('capability_schema_diff','capsch')]:
    body = dd.get(k)
    if not body:
        print(f'{label}: —')
        continue
    av = body.get('axis_verdict','?')
    print(f'{label}:', {'replayable':'R','drifted_compatible':'C','drifted_incompatible':'I','unverifiable_axis':'?'}.get(av, av))
"
```

## 3. Run Log

| Date | Run ID | Workflow | Top | Builtin | Project | Workflow ax | Const | CapSch | H5? | H6? | H7? | Action | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-05-07 | run_20260507112239_a0ac0a0c | project-constitution | replayable | R | R | ? → R* | ? → R* | ? → R* | n/a | no | no | none | H2 dogfood. Run was created before H3 #4 hooks landed; three H3 axes initially `?` (unverifiable_axis). Manually attached H3 baselines via CLI during H3 dogfood, then re-verified — all axes flipped to R. AI step `validate_constitution` halted on AI flake, unrelated to harness. *post-H3-attach |
| 2026-05-07 | run_20260507141420_0276c8d7 | project-constitution | replayable | R | R | R | R | R | no | no | no | none | H3 dogfood (fresh run with H3 #4 runtime hooks active). All 6 attach hooks fired (workflow.log lines confirm). 6 mirror files written to `<run_dir>/snapshots/`. workflow_yaml_baseline.source_layer recorded as `None` — fixed in H4 #2; this run pre-dates the fix. AI step halted on validate_constitution (same AI flake as H2 dogfood, unrelated). |

## 4. Promotion Decision Recipe

每次填完一筆 row 後，按下列規則判斷是否需要啟動 H5/H6/H7：

### 4.1 H5 signal — whole-file hash 假警報

統計過去 10 個 row 中 `H5? = yes` 的次數：

- < 3：不啟動 H5。繼續觀察。
- 3–5：寫一筆 H4.x patch idea 到 `Notes`，但仍不啟動 H5。
- > 5：啟動 H5 design memo（doc-only 先行）。

### 4.2 H6 signal — shared registry 使用

只要任一 row 出現 `H6? = yes`，就值得啟動 H6 design memo（doc-only 先行）。Shared layer 一旦真實使用，verifier 不認 shared 軸會立刻變成 audit 缺口，不需要累計。

### 4.3 H7+ signal — replay 重跑需求

只要任一 row 出現 `H7? = yes`，啟動 H7 design memo。Real replay 是大工程，但需求一旦出現就要先 doc 化 scope。

### 4.4 沒有任何 signal 持續 ≥ 14 天

如果觀察期 14 天後三類 signal 都是空的，可以決定：

- 把 observation period 延長 14 天；或
- 把 H5/H6/H7 placeholder 標為「indefinitely deferred」並在 closeout doc 加註；或
- 收工 — 認為 H1-H4 已足夠，CAP H 系列正式進入 maintenance-only。

## 5. 不要做的事

- 不要因為「應該觀察到什麼」就刻意造 drift 來填 row（例如修改 agent-skills 然後跑 verify）。Row 只記錄**真實**使用觀察。
- 不要根據單一 row 啟動 H5/H6/H7（除 H6/H7 是 1-shot trigger）。
- 不要把這份 log 當成 dashboard — 只是 ratchet 紀錄，幫助 future-self 證明 gating condition 是否被滿足。
- 不要在這份 log 裡記任何 prompt 內容、AI 回應、機敏資料。只填 verdict 結構與一行 notes。
