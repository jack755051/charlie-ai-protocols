# CAP Run Archive Policy (v1.0)

> 本文件定義 CAP workflow run 的歸檔策略：何時把 run 從「active inspect 範圍」轉入「archived」、archive 應保留哪些 artifact、Logger (99) 在結案時應產出什麼形狀的 handoff，以及 retention / cleanup 的邊界。

## 1. 範圍與職責邊界 (Scope & Boundaries)

- **適用對象**：所有 `cap-workflow-exec.sh` 完成後寫到 `~/.cap/projects/<project_id>/reports/workflows/<workflow_id>/<run_id>/` 的 run。
- **不在此範圍**：
  - `~/.cap/projects/<id>/constitutions/` / `compiled-workflows/` / `bindings/` 由 `policies/cap-storage.md` 負責；archive 不接手這些。
  - 真正的 storage retention（disk 空間、tarball、cold storage）屬於使用者基礎設施決策；本文件只規範 policy contract。
  - GitHub PR / 公開發行的 release notes 由 `git-workflow.md` 與 CHANGELOG 負責。
- **本文件與 P7 builder 的關係**：
  - P7 `result_report_builder` 產出 `workflow-result.json` 是 archive 的 single source of truth machine artifact。
  - P7 `render_result_md` 產出 `result.md` 是同一份資料的 human-readable projection。
  - 本 policy 規定 archive 必須**能繼續被 `cap workflow inspect <run-id>` 消費**（archived run 不應退化成不可 inspect）。

## 2. Run 生命週期狀態 (Lifecycle States)

每個 run_dir 在生命週期內依序經歷三種狀態。狀態必須在 `<run_dir>/.lifecycle` 標記檔（單行 plain text）中明示，缺檔視為 `active`：

- **`active`**：剛跑完或近期跑完。`cap workflow inspect` / `cap workflow ps` 等指令以這層為主要對象。預設保留全部 SSOT 檔（`runtime-state.json` / `agent-sessions.json` / `run-summary.md` / `workflow.log` / `workflow-result.json` / `result.md` 與所有 step output / route-history）。
- **`archived`**：已由 Logger 結案、產出 archive summary、確認 archive contract（§3）落地。`cap workflow inspect` 仍能讀取（resolution 規則不變），但人類消費以 `archive-summary.md` 為入口。
- **`pruned`**：超過 retention（§6）後執行的軟刪除——只保留 archive contract 必要核心檔案，刪除 step output、raw stdout、原始 log 等可重建內容。`pruned` 狀態下 `cap workflow inspect` 仍須能讀出 Run Header / Summary / Failures / Sessions / Artifacts，但 Logs Pointer 可以是 `(pruned)`。

> **狀態轉換不可逆**：`active → archived → pruned` 為單向。誤判要回退時，必須開新 run 重跑，不得偽造 lifecycle 標記。

## 3. Archive 必要核心檔案 (Required Archive Contents)

`archived` 狀態下，run_dir **至少**必須保留以下檔案：

| 檔案 | 來源 | 用途 |
|---|---|---|
| `workflow-result.json` | P7 Phase B producer | machine artifact，schema 驗證入口 |
| `result.md` | P7 `render_result_md` | human-readable projection |
| `archive-summary.md` | Logger (§5) | 結案敘事摘要 + 關鍵決策軌跡 |
| `.lifecycle` | archive 流程 | 標明 `archived` 狀態與時間戳 |

**選用但建議保留**：
- `run-summary.md`：raw run header + Finished section，供降級 inspect 使用。
- `agent-sessions.json`：完整 session ledger，供 P10 promote 與審計使用。
- `runtime-state.json`：raw step-level state，供 builder fallback 使用。
- `workflow.log`：完整 audit trail。
- `route-history.jsonl`（若存在）：route_back 軌跡，異常分析用。

**可在 pruning 階段（§6）刪除**：
- 各 step 的原始 stdout / stderr 截錄 (`<step_id>.raw.log`)。
- 各 step 的 prompt / output 草稿 markdown (`<step_id>.md`、`<step_id>.handoff.md`)。
- 大型臨時檔（dump、debug snapshot）。

## 4. 儲存佈局 (Storage Layout)

Archive 採「**就地標記**」策略，**不**搬移 run_dir：

```
~/.cap/projects/<project_id>/reports/workflows/<workflow_id>/<run_id>/
├── workflow-result.json          # archive 必要
├── result.md                     # archive 必要
├── archive-summary.md            # archive 必要（Logger 產出）
├── .lifecycle                    # archive 必要（單行：archived <ISO timestamp>）
├── run-summary.md                # 強烈建議保留
├── agent-sessions.json           # 強烈建議保留
├── runtime-state.json            # 強烈建議保留
├── workflow.log                  # 強烈建議保留
├── route-history.jsonl           # 若存在則保留
└── …其他 step output / handoff / raw logs (pruning 階段可刪)
```

**選擇就地標記而非搬移**的理由：
- `cap workflow inspect` 的 `_find_run_dir` glob 不必改動，archived 仍可被 resolve。
- 不破壞 `workflow-result.json` 內 `logs.workflow_log` 的絕對路徑。
- 跨 active / archived / pruned 的 inspect 行為一致，降低使用者認知負擔。

`.lifecycle` 檔範例：

```text
archived 2026-05-12T14:32:08Z
```

`pruned` 狀態時則為：

```text
pruned 2026-06-15T03:00:00Z
```

## 5. Logger Handoff Format (`archive-summary.md`)

Logger (99) 接到 archive 任務時，必須產出 `<run_dir>/archive-summary.md`，採固定結構供下游（人類審計、`cap workflow inspect` 延伸消費、未來 P10 promote pipeline）使用。Logger 的 capability-level 規範請對齊 `agent-skills/99-logger-agent.md` §2.4「結案歸檔摘要」。

`archive-summary.md` **必填章節**：

```markdown
# Run Archive Summary

## Run Identity
- run_id: <run_id>
- workflow_id: <workflow_id>
- workflow_name: <name 或 -)
- project_id: <project_id>
- task_id: <task_id 或 null>

## Lifecycle
- started_at: <ISO timestamp>
- finished_at: <ISO timestamp 或 null>
- total_duration_seconds: <integer 或 null>
- final_state: <enum>
- final_result: <enum 或 null>

## Summary Metrics
- total_steps / completed / failed / skipped / blocked

## Critical Events
- 列出 failures[]、route_back 軌跡、Watcher / Security gate 異常、QA 重大發現
- 每條附 step_id、reason、route_back_to 與相關 artifact 路徑
- 若無重大事件，必須明示 `(none)` 而非省略

## Decision Narrative
- 1–5 句敘事，標明本次 run 的目的、結論、與後續行動
- 對齊 `agent-skills/99-logger-agent.md` 「ADR」段的選型紀錄精神
- 嚴禁複製 prompt 或對話內容；只保留決策層摘要

## Artifact Pointers
- workflow_result_json: <絕對路徑>
- result_md: <絕對路徑>
- run_summary_md: <絕對路徑 或 (pruned)>
- agent_sessions_json: <絕對路徑 或 (pruned)>
- workflow_log: <絕對路徑 或 (pruned)>
- promote_candidates: <參考 workflow-result.json 的 promote_candidates[]>
```

**禁令**：
- Logger 不得在 `archive-summary.md` 內偽造未發生的決策、編造額外 commit / PR 資訊。
- 缺少足以撰寫上述章節的證據時（例如 `workflow-result.json` 不存在、Watcher / Security 報告殘缺），Logger 必須回報 `needs_data` 並中止 archive，**不得**用模糊敘述帶過。

## 6. Retention 與 Pruning 規則 (Retention Rules)

預設規則（可由專案層或使用者覆寫，覆寫位置：`~/.cap/projects/<id>/.cap/archive-policy.yaml`，本文件不強制 schema，留待真實使用情境再凝固）：

| 狀態 | 預設保留期 | 條件 |
|---|---|---|
| `active` | 30 天 | 從 `finished_at` 起算；過期後可由 archive 流程轉 `archived`。 |
| `archived` | 180 天 | 從 `.lifecycle` 標記時間起算；過期後可由 prune 流程轉 `pruned`。 |
| `pruned` | 永久（直到使用者手動刪除） | 只剩核心檔，磁碟成本低，預設不主動刪除整個目錄。 |

**Active 留存的「最小保證」**：
- 每個 `workflow_id` 至少保留**最近 1 個** `final_state == "completed"` 的 run，即使超過 30 天，也不主動轉 `archived`。
- 每個 `workflow_id` 至少保留**最近 3 個** run（不論 final_state），以利異常分析。

**Archive / prune 流程觸發**：
- **手動**（v1 預設路徑）：使用者透過 `cap workflow archive <run-id>` / `cap workflow prune <run-id>`（CLI 待實作；本 policy 先行落地，CLI 與本 policy 對齊即可）。
- **批次**（自動化選項）：使用者可自行排程 cron / launchd 按 §6 的天數規則執行。本 policy 不強制 runtime 自動觸發，避免在沒有 user consent 下動到 SSOT。

**Pruning 必須保留**：`workflow-result.json`、`result.md`、`archive-summary.md`、`.lifecycle`。其他可選保留（`runtime-state.json` / `agent-sessions.json` / `run-summary.md` / `workflow.log`）建議保留，但在磁碟壓力下可由使用者自主取捨。

## 7. 可重現性與 Inspect 相容性 (Reproducibility)

- `cap workflow inspect <run-id>` 對三個 lifecycle 狀態都必須能跑通：
  - `active`：依 P7 #7 三層 resolution（json → builder fallback → status-store）。
  - `archived`：與 active 行為一致；額外可在 text view 顯示「lifecycle: archived」提示。
  - `pruned`：`workflow-result.json` 仍在，主路徑不退化；若使用者刪到只剩 `archive-summary.md` 與 `workflow-result.json`，inspect 仍應能渲染 Run Header / Summary / Failures / Artifacts，僅 Logs Pointer 可顯示 `(pruned)`。
- **Pre-P7 runs**：對於沒有 `workflow-result.json` 的舊 run，archive 行為由 Logger 視個案決定——若 builder fallback 能成功 aggregate，就照本 policy 產出 archive-summary 並補出 `workflow-result.json`；若 SSOT 殘缺到 builder 也失敗，則維持「legacy run，未進 archive 流程」現狀，**不**強制改造。
- **Schema drift 防護**：archive 產出的 `workflow-result.json` 必須通過 `schemas/workflow-result.schema.yaml` 驗證；驗證失敗時 archive 流程必須 halt 並標示「needs_data」，不得寫入 `.lifecycle archived` 假裝成功。

## 8. 與其他 policy 的關係 (Interplay with Other Policies)

- **`policies/cap-storage.md`**：本文件聚焦 `reports/workflows/` 子樹的 lifecycle；其他子樹（constitutions / compiled-workflows / bindings 等）的儲存治理仍以 `cap-storage.md` 為準。
- **`policies/handoff-ticket-protocol.md`**：archive 流程不產出 Type C ticket；Logger 直接寫 `archive-summary.md` 即可。但若 archive 任務本身被當作 supervisor-orchestrated step（例如 workflow 結尾顯式呼叫 logger archive capability），則仍須走標準 ticket 協議。
- **`agent-skills/99-logger-agent.md`**：本 policy 規定 archive contract，Logger agent skill 規定產出 capability；兩者必須一致。Logger skill 變動時須回頭檢查本 policy；本 policy 變動時須回頭檢查 Logger skill。

## 9. 變更紀錄 (Changelog)

- v1.0：初版。對齊 P7 Phase A / B / C 完成後的 SSOT；定義 active / archived / pruned 三段 lifecycle、就地標記策略、Logger handoff 必填章節、retention 預設、與 inspect 相容性。
