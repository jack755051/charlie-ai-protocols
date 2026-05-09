# CAP Run Observability Guide

> Status: user-facing operations guide
> Scope: 操作說明 — 什麼時候用 `logs` / `watch` / `inspect`，以及背後的 fallback 規則。
> Planning history（為什麼要做、四個 phase 的 roadmap）見 [`RUN-OBSERVABILITY-MEMO.md`](RUN-OBSERVABILITY-MEMO.md)。

## TL;DR

| 場景 | 用哪個 |
|---|---|
| 想看「整個 run 從頭到尾發生了什麼事」（line-stream） | `cap workflow logs <run-id>` |
| 想跟著還在跑的 run 一起看新 log（類似 docker logs -f） | `cap workflow logs -f <run-id>` |
| 想看「特定 step 的 provider output」 | `cap workflow logs <run-id> --step <step-id>` |
| 想要一個會自動更新的狀態總覽（類似 kubectl get -w） | `cap workflow watch <run-id>` |
| 想要單螢幕 < 15 行的快速狀態檢查 | `cap workflow watch --compact <run-id>` |
| 想要 CI / 腳本可消費的 JSON | `cap workflow watch --json <run-id>` |
| 想要結案後一次看完六區塊詳情 | `cap workflow inspect <run-id>` |
| 想跨 repo / 沙箱觀察別處的 run | 任一指令 + `--cap-home /path/to/.cap` |

所有指令都是 **read-only**，不會觸發 AI 呼叫、不會新增 token 消耗、不會更動 run state。

## Run 目錄佈局

`cap workflow run` 啟動的每個 run 都會在這個固定位置留下檔案：

```text
~/.cap/projects/<project_id>/reports/workflows/<workflow_id>/<run_id>/
  workflow.log              # 整個 run 的 line-stream log（被 logs / watch 讀）
  runtime-state.json        # step 註冊、artifact registry、execution_state（被 inspect / watch 讀）
  agent-sessions.json       # session lifecycle / result / provider 軌跡（被 inspect / watch 讀）
  run-summary.md            # 人類可讀的 run header + steps + finished 區塊
  result.md                 # 結案後的 result report（render_result_md 產出）
  artifact-index.md         # artifact 列表索引
  workflow-result.json      # P7 builder 產出的彙整 JSON（inspect / watch 優先讀這個）
  <phase>-<step_id>.md          # 每個 step 的主要產出（current SSOT）
  <phase>-<step_id>.handoff.md  # 每個 step 的 Type D handoff summary
  <phase>-<step_id>.raw.log     # legacy（April 24 之前的 run 才有）
  prompts/                  # AgentSessionRunner 寫入的 prompt snapshot
```

說明：
- **整體 SSOT**：`workflow-result.json`（P7+ run 才有）。inspect / watch 優先讀這個；不存在就現場 aggregate `runtime-state` + `agent-sessions` + `run-summary`。
- **step output SSOT**：`<phase>-<step_id>.md`，由 `cap-workflow-exec.sh:materialize_step_output` 寫入。
- **raw.log**：曾經是 step stdout 的位元級複本，現已淘汰；只有在 legacy run 上會出現，Phase 3 reader 仍會優先採用以保留可讀性。

## `cap workflow logs <run-id>`（Phase 1）

工作行為類似 `docker logs`：cat 一份 line-stream log。

```bash
cap workflow logs run_20260508105209_84a94755                    # cat workflow.log
cap workflow logs -f run_20260508105209_84a94755                 # tail -f
cap workflow logs run_20260508105209_84a94755 --cap-home /tmp/cap-sandbox/.cap
```

設計：Python 解析 run-id → 算出 log 路徑；bash 用原生 `cat` / `tail -f`。follow 行為由 POSIX 工具提供，不在 Python event loop 裡輪詢。

錯誤訊息：
- `找不到 run_id: <id>` → run_id 不存在於 `<cap_home>/projects/*/reports/workflows/*/`。
- `找不到 workflow.log: <path>` → run dir 在但 `workflow.log` 沒被產生（極少見，通常是 run 在第一個 step 之前就崩潰）。

## `cap workflow logs <run-id> --step <step-id>`（Phase 3）

針對單一 step 的輸出。glob `*-<step-id>.{raw.log,md,handoff.md}` across phases，套 fallback 鏈：

| 優先 | 檔案 | 適用 |
|---|---|---|
| 1 | `<phase>-<step-id>.raw.log` | legacy runs（April 24 之前） |
| 2 | `<phase>-<step-id>.md` | 預設；current SSOT |
| 3 | `<phase>-<step-id>.handoff.md` | 最後 fallback；step 沒落地 .md 時的 Type D summary |
| — | 都沒有 | exit 1 + `找不到 step <id> 的輸出檔（嘗試過 raw.log / md / handoff.md）` |

```bash
cap workflow logs run_xxx --step draft_constitution
cap workflow logs -f run_xxx --step draft_constitution
```

操作者不需要記 phase 編號（`1-` / `2-` 前綴），resolver 自動跨 phase glob；多重命中時取 alphabetic first（與 `_find_run_dir` 一致的決策慣例）。

設計選擇 — 為什麼 fallback 沒包含 raw.log writer 的「補回來」：盤點顯示 raw.log 是 .md 的位元級複本（檔案大小完全一致），是已淘汰的 redundant artifact。Phase 3 純讀取 fallback 即可，不重新加回寫入器。詳細考量見 commit `d253179` 的 message。

## `cap workflow watch <run-id>`（Phase 2 + Phase 4）

Live snapshot of run state，類似 `kubectl get -w`。Python 處理 ANSI 清屏 + interval refresh，bash 只做參數轉發。

### 預設模式（verbose）

七區塊：
1. **# Watch** — workflow_id / run_id / project_id / final_state / final_result / started_at / finished_at / totals
2. **# Steps** — `<step_id>: <execution_state>` 一行一個
3. **# Sessions** — 每個 session 的 step / lifecycle / result / provider
4. **# Artifacts** — count + latest pointer
5. **# Last Log Lines (tail N)** — 預設取 workflow.log 的後 10 行

```bash
cap workflow watch run_xxx                  # tty: 2 秒刷新
cap workflow watch --once run_xxx           # CI / 腳本：一次性
cap workflow watch --json run_xxx           # 給 dashboard 或 jq 消費
cap workflow watch --interval 1 run_xxx     # 自訂刷新間隔
cap workflow watch --tail 20 run_xxx        # 自訂 last log 行數
```

### 簡潔模式（compact，Phase 4）

`--compact` 把畫面壓在 < 15 行，預設 `--tail` 自動降為 1。每個區塊壓成單行 / 單行群：

```text
# Watch (compact)
  watch-wf | run_case1 | success | duration 12s
  totals: total=4 done=4 fail=0 skip=0 block=0
  steps: 1-prd: validated
         2-tech_plan: validated
         3-ba: validated
         4-dba_api: validated
  sessions: 4 (last: completed/success/claude)
  artifacts: 3
  log: [2026-05-08 12:00:12][workflow][success]
```

適合：終端視窗高度有限、想快速確認 run 狀態、不需要每個 session 詳情。

### 行為矩陣

| 旗標 | tty 預設行為 | pipe / redirect 行為 |
|---|---|---|
| 無 | ANSI clear + 2s 刷新 loop（verbose） | 自動 fallback 為 single-shot（避免汙染 log）|
| `--once` | 強制 single-shot（verbose） | 同 tty |
| `--compact` | ANSI clear + 2s 刷新 loop（compact） | 自動 fallback single-shot |
| `--json` | 永遠 single-shot JSON dump | 同 tty（jq pipeline 友善）|

`Ctrl-C` 在 loop 模式下乾淨退出（exit 0）。

## `cap workflow inspect <run-id>`

結案後的完整一次性詳情，**七區塊**（Phase 4 加上 Follow-up）：

1. Run Header — workflow_id / workflow_name / run_id / project_id / started/finished / duration / final_state / final_result
2. Summary — total_steps / completed / failed / skipped / blocked
3. (Inputs — 若有 constitution_dir / compiled_workflow_dir / binding_dir)
4. Failures — 列表，含 reason / detail / route_back_to
5. Sessions — 每個 session 的詳情
6. Artifacts — 列表，含 producer_step_id
7. Logs Pointer — workflow_log 路徑 + 行數
8. **Follow-up**（Phase 4 新增）— 直接列出 `cap workflow logs <run-id>` / `cap workflow watch <run-id>`，方便接著切去 live observation

`--json` 直接 dump `workflow-result.json`（schema 對齊 `schemas/workflow-result.schema.yaml`）。

## 跨 repo / 沙箱觀察：`--cap-home`

所有觀察指令都接受 `--cap-home PATH`，覆寫 `CAP_HOME` env 與預設 `~/.cap`：

```bash
# 觀察另一個 user / 沙箱的 run
cap workflow logs run_xxx --cap-home /tmp/some-other-cap

# 測試環境
cap workflow watch --once run_test --cap-home ./fixture/cap
```

優先順序：`--cap-home` > `CAP_HOME` env > `~/.cap`。

## 不會發生的事

- **不會重跑 provider**：所有指令只讀 run_dir 既存檔案。
- **不會增加 token**：CAP 不會把這些指令解讀為 prompt。
- **不會修改 run state**：純讀取，不寫 runtime-state / sessions / log。
- **不會替你登入或安裝 provider**：observability 跟 provider CLI 完全解耦。

## 相關文件

- [RUN-OBSERVABILITY-MEMO.md](RUN-OBSERVABILITY-MEMO.md) — 為什麼做、四 Phase roadmap
- [ARCHITECTURE.md](ARCHITECTURE.md) — run_dir / workflow_result.json schema、P7 builder
- [SUPERVISOR-ORCHESTRATION-BOUNDARY.md](SUPERVISOR-ORCHESTRATION-BOUNDARY.md) — handoff ticket / agent session 的儲存規則
