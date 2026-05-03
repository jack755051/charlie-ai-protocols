# Supervisor Structured Orchestration Boundary (P3 #1)

> **Scope**: P3 第一塊基石。在動 schema tightening / producer 實作 / runtime validation hook 之前先把 Supervisor structured orchestration envelope 與既有的 5 個鄰居（Task Constitution / Capability Graph / Compiled Workflow / Handoff Ticket Type C / Handoff Summary Type D）在 5 個 surface（Producer / Schema / Consumer / Validation / Storage）的分流寫清楚，後續 P3 子任務都以本 memo 為錨。
>
> **Status**: design memo — proposes the canonical boundary; does not change runtime code in this commit.
>
> **Reviewers**: 使用者最終裁決 §4「Proposed Boundary」是否拍板，再進 P3 #2（schema tightening）。
>
> **Tagging baseline**: 本 memo 起草於 `v0.22.0-rc3` tag 之上（P2 closeout 完成）。

## 1. Why This Memo Exists

CAP 在 v0.19.x → v0.22.0-rc3 期間累積了**五個**結構化 artifact，但**沒有單一 SSOT 把它們綁在一起**：

- `Task Constitution` — 任務語意憲章（goal / scope / success_criteria / execution_plan），由 `engine/task_scoped_compiler.build_task_constitution` 或 supervisor draft 產出。
- `Capability Graph` — 任務需要的 capability 依賴拓撲，由 `engine/task_scoped_compiler.compile_task` 內部 `_build_capability_graph` 推導。
- `Compiled Workflow` — 真正要跑的最小 workflow envelope（含 plan / binding），由 `compile_task` 組裝。
- `Handoff Ticket (Type C)` — 派工合約，每個 sub-agent step 由 `scripts/workflows/emit-handoff-ticket.sh` 寫入 `~/.cap/projects/<id>/handoffs/<step>.ticket.json`。
- `Handoff Summary (Type D)` — sub-agent 完工後的回報，由 sub-agent 自己依 `policies/handoff-ticket-protocol.md` §4 五段結構寫入 `output_expectations.handoff_summary_path`。

**現況**：這 5 個 artifact 各自有 schema 與 producer / consumer，但**沒有「supervisor 對單一 prompt 的整體結構化決策」這個上層封裝**。Supervisor 目前對外輸出**自由文字**（chain-of-thought + 派工敘述），下游必須靠各自的 shell / Python helper 解析重建這 5 個 artifact。這帶來三個問題：

1. **Producer 不一致**：`task_scoped_compiler` 純 deterministic（SHA-1 + token matching）能產 task_constitution / capability_graph / compiled_workflow；但 supervisor sub-agent（Claude / Codex spawn-out）對同一個 prompt 可以產出**不同形狀**，因為沒有 envelope schema 統一拘束。
2. **Consumer 必須猜 shape**：runtime binder、handoff emitter、watcher / logger 等 consumer 拿到的不是單一 envelope，而是 5 個分散 artifact 的零散讀取，consumer 對 supervisor「決策意圖」沒有 single source of truth。
3. **Validation 散落**：每個下游 step 各自跑各自 schema（task-constitution / capability-graph 等），沒有「envelope 進入 runtime 即驗」的 gate，schema_validation_failed 偵測點落得太晚。

`schemas/supervisor-orchestration.schema.yaml`（P0 #4 forward contract，commit `82ad424`）已經畫出這個 envelope 的形狀（9 個 required 頂層欄位 + nested governance），但**沒有 producer / 沒有 runtime validation / 沒有 storage 層**。P3 的任務就是把這 forward contract 變成 active contract。

**為什麼這是阻塞 P3**：P3 #2 要評估 schema 是否需要補欄位、P3 #3 要實作 producer、P3 #4 要在 runtime hook validation、P3 #5 要把 envelope 連到 compiled workflow / binding。若不先把 envelope 與 5 個鄰居的 nesting / consumer / storage 邊界拆清楚，P3 #2-#8 會在實作時跟 P0 #4 forward contract、`task_scoped_compiler` 既有行為、handoff-ticket-protocol §4 等多份規範撞牆。

## 2. Current State Survey

### 2.1 Producer Surface（最不清晰）

| Artifact | 現有 producer | Producer kind |
|---|---|---|
| Task Constitution | `engine/task_scoped_compiler.build_task_constitution` (deterministic) | Pure function (SHA-1 + token match) |
| Task Constitution | Supervisor draft via `agent-skills/01-supervisor-agent.md` §2.5 strict schema | AI sub-agent |
| Capability Graph | `engine/task_scoped_compiler._build_capability_graph` | Pure function |
| Compiled Workflow | `engine/task_scoped_compiler.compile_task` | Pure function |
| Handoff Ticket (Type C) | `scripts/workflows/emit-handoff-ticket.sh` | Shell executor |
| Handoff Summary (Type D) | Sub-agent (Claude / Codex / shell) | Mixed |
| **Supervisor Orchestration Envelope** | **NONE** | **forward contract only** |

**觀察**：envelope 是唯一的「supervisor 自身對外結構化 output」；其他 5 個 artifact 要嘛是 deterministic 函式產出（不需 AI 決策）、要嘛是下游 shell 從上游 artifact 萃取（不是 supervisor 親手寫）。Envelope 的 producer 拍板**是整個 P3 的核心問題**。

### 2.2 Schema Surface（已就位，可能需要補強）

| Schema | Status | 用途 |
|---|---|---|
| `schemas/task-constitution.schema.yaml` | active | Task Constitution body validation |
| `schemas/capability-graph.schema.yaml` | active | Capability Graph node + edge validation |
| `schemas/compiled-workflow.schema.yaml` | active | Compiled Workflow envelope validation |
| `schemas/binding-report.schema.yaml` | active | RuntimeBinder report validation |
| `schemas/handoff-ticket.schema.yaml` | active | Type C ticket validation |
| `schemas/supervisor-orchestration.schema.yaml` | **forward contract** (P0 #4, no producer yet) | Envelope shape validation |

**觀察**：envelope schema header 明文寫「envelope-only validation；nested artifact 由 sibling schema 各自驗」。這個分層已合理，P3 #2 評估時應**保留分層原則**，僅在「routing / failure_routing / step status enum」等領域補欄位，避免在 envelope schema 內遞迴 enforce nested。

### 2.3 Consumer Surface（envelope 沒有 consumer，下游讀分散 artifact）

| Consumer | 目前讀什麼 | Envelope 落地後應讀什麼 |
|---|---|---|
| Compile pipeline (compile_task) | task_constitution + capability_graph (內部建構) | envelope.task_constitution + envelope.capability_graph |
| Runtime Binder | compiled_workflow.binding | envelope → 觸發 compile → binding (envelope 是上游) |
| Handoff emitter (emit-handoff-ticket.sh) | step ledger + 上游 handoff summary | envelope.governance + envelope-derived per-step ticket |
| Watcher (90) / Logger (99) | watcher_mode / logger_mode 散落在 workflow YAML | envelope.governance.watcher_mode / .logger_mode (single source) |
| Doctor / Status | `constitutions/` directory listing | + `orchestrations/<stamp>/` (見 §4.5) |

**觀察**：envelope 落地後，consumer 不需要重新解析 supervisor 自由文字，只要讀 envelope 與其引用的 sibling artifact。這把 supervisor → compile → bind → execute 鏈路上游從「自由文字 + 多份散落 artifact」收斂為「單一 envelope + 引用」。

### 2.4 Validation Surface（最大缺口）

目前各 schema 各自被 producer / consumer 在不同 step 各自驗：

- `task-constitution.schema.yaml` 由 `scripts/workflows/persist-task-constitution.sh` 與 `engine/step_runtime.py:validate_constitution` 雙重驗。
- `capability-graph.schema.yaml` 由 `engine/step_runtime.py:validate-jsonschema` generic alias 觸發。
- `handoff-ticket.schema.yaml` 由 `scripts/workflows/emit-handoff-ticket.sh` 寫入前驗。

但 envelope 落地時**沒有 runtime gate**驗 envelope 自身結構。一個壞 envelope（缺 governance、task_id 與 task_constitution.task_id drift、compile_hints 欄位 typo）會被 consumer 一個一個踩到才報錯，schema_validation_failed 偵測點落得太晚（exit 41 但難以追溯到 supervisor）。

P3 #4 要解這個：在 envelope 從 producer 到 consumer 之間插一個 runtime validation hook，與 P0a 的 schema_validation_failed (exit 41) 類別對齊。

### 2.5 Storage Surface（不存在）

P2 把 Project Constitution 的 storage 從 `constitutions/<stamp>.json` 平面檔升級到 `constitutions/project/<stamp>/` 四件套（per `docs/cap/CONSTITUTION-BOUNDARY.md` §4.5）。Task Constitution 仍在 `constitutions/constitution-<stamp>.json` 平面檔（read-only legacy，依 P2 #1 §4.5 不強制 migration）。

**Envelope 目前無 storage 路徑**：

```text
~/.cap/projects/<project_id>/
├── constitutions/
│   ├── project/<stamp>/                        # P2 four-part snapshot
│   ├── constitution-<stamp>.json               # legacy task constitution flat file
│   └── <task_id>/                              # task_scoped_compiler grouped by task
├── compiled-workflows/<stamp>.json
├── bindings/<stamp>.json
├── handoffs/<step_id>.ticket.json              # Type C
├── reports/workflows/<wf>/<run_id>/            # workflow run artefacts
└── (no orchestrations/ subtree)                # ← envelope has no home yet
```

P3 #5 / #8 將需要 envelope snapshot 落地的位置（doctor / status 要能觀察、release-gate smoke 要能驗）。

## 3. The Real Problem in One Line

> **5 個既有 artifact 各自有 schema 與 producer，但 supervisor 的「整體結構化決策」沒有 envelope SSOT；下游 consumer 必須猜 shape、validation 散落、storage 缺 home。**

P0 #4 的 schema 已畫好藍圖，P3 把 producer / runtime validation / storage / consumer routing 全部接上。

## 4. Proposed Boundary（P3 #1 拍板對象）

### 4.1 Producer Surface

**唯一正式 producer**：supervisor sub-agent（透過 `agent-skills/01-supervisor-agent.md` 行為書），當 conductor 在 Mode C constitution-driven execution（per `policies/constitution-driven-execution.md` §1.3）下被 spawn 出來時，必須產出**符合 supervisor-orchestration.schema.yaml 的 envelope JSON** 包裹在 fence 內（與 task constitution / project constitution 同樣的 fence convention）。

**Producer 鐵則**：

| 規則 | 說明 |
|---|---|
| 單一 producer | envelope 只能由 supervisor sub-agent 產出；deterministic compiler (`task_scoped_compiler`) **不**寫 envelope，只貢獻 envelope.task_constitution / .capability_graph 兩個子物件的內容 |
| Fence 規範 | envelope JSON 必須包在 `<<<SUPERVISOR_ORCHESTRATION_BEGIN>>> ... <<<SUPERVISOR_ORCHESTRATION_END>>>` 顯式 fence 內，與 task constitution 的 `<<<TASK_CONSTITUTION_JSON_BEGIN/END>>>` 對稱 |
| Drift 拒收 | producer 必須讓 `envelope.task_id == envelope.task_constitution.task_id` 與 `envelope.source_request == envelope.task_constitution.source_request`；P3 #4 runtime hook 偵測 drift 直接 halt |
| supervisor_role 鎖定 | `supervisor_role` 永遠等於 `"01-Supervisor"`（schema enum 已硬鎖）；如未來新增 multi-supervisor，先 bump schema_version |

**禁止**：

- runtime wrapper 把 supervisor 自由文字 post-process 成 envelope（會喪失 supervisor 自主性、且容易產出與 supervisor 真實意圖偏離的 envelope）。
- deterministic compiler 直接 emit envelope（compiler 是「輔助手」，不是「決策者」）。
- 多 supervisor 並行（保持 supervisor_role 鎖定，避免責任分散）。

### 4.2 Schema Surface

**保留現有 schema 分層**：envelope schema 只驗 envelope shape，nested artifact body 由 sibling schema 各自驗。P3 #2 評估時**僅**考慮以下補強候選：

| 補強候選 | 必要性 | 備註 |
|---|---|---|
| `failure_routing` block | 高 — P3 #6 需要 | supervisor 對 step 失敗時的 halt / route_back / retry / escalate 政策 |
| `step_status_enum` for handoff state | 中 | 是否在 envelope 直接帶 step 預期狀態（pending / ready / blocked），讓 consumer 預先看 |
| `envelope_id` 獨立 id | 低 — task_id 已足 | 除非未來 supervisor 對同一 task 重產 envelope（reroll），目前 task_id 即 envelope 唯一 id |
| `version` 區分 schema vs envelope | 低 | schema_version 已足；envelope 內容變動由 supervisor 自決，不需 envelope-level version |

**P3 #2 不**改動：required field 集合（9 個已穩定）、supervisor_role enum、governance enum、compile_hints 欄位（這些已是 P0 #4 直接契約，下游已預期）。

### 4.3 Consumer Surface

| Consumer | Envelope 落地後責任 |
|---|---|
| Compile pipeline | 從 envelope 讀 task_constitution + capability_graph 直接餵入 compile_task；不再內部 reconstruct |
| Runtime Binder | 從 envelope.compile_hints 讀 registry_preference / fallback_policy；其他預設沿用 binder 內建邏輯 |
| Handoff emitter | 從 envelope.governance 讀 watcher_mode / logger_mode / context_mode 餵入 ticket 的 governance 段；step-level routing 從 envelope 衍生（P3 #5 mapping） |
| Watcher (90) / Logger (99) | 預設 watcher_mode = governance.watcher_mode、logger_mode = governance.logger_mode；workflow YAML 仍可 override 但 envelope 是當次 run 的 SSOT |
| Doctor / Status | 列出最新 envelope snapshot（與 P2 constitution snapshot 對稱顯示） |

**禁止**：

- consumer 在 envelope 之外再讀 supervisor 自由文字當決策依據（envelope 是唯一 truth；自由文字降為「原 prompt + supervisor 推理紀錄」歸檔用）。
- consumer 自行內插 envelope 缺漏欄位（producer 必須完整、validation 必須擋；consumer 不容忍部分填充）。

### 4.4 Validation Surface

**Runtime gate**：envelope 從 producer 到 consumer 之間插一個 jsonschema validation hook，**與 P2 runner_owned validator 同源邏輯**：

| Hook 點 | 行為 | exit code |
|---|---|---|
| Envelope ingestion (after fence extraction) | 跑 `engine/step_runtime.py validate-jsonschema` against `schemas/supervisor-orchestration.schema.yaml` | exit 41 schema_validation_failed if invalid |
| Drift check (envelope task_id vs envelope.task_constitution.task_id) | runtime 比對 | exit 41 if mismatch |
| Nested validation pass-through | envelope.task_constitution → task-constitution.schema.yaml；envelope.capability_graph → capability-graph.schema.yaml | exit 41 if any nested invalid |

**禁止**：

- consumer 跳過 envelope validation 直接讀（即使 envelope 已落地過 1 次，consumer 第一次讀仍須驗 — 對齊 P2 promote 「永遠重跑 jsonschema」鐵則）。
- 半 valid envelope 流入 compile 或 binder（schema_validation_failed 必須 halt run）。

### 4.5 Storage Surface（**核心變動**）

**新層級結構**（仿 P2 four-part snapshot pattern）：

```text
~/.cap/projects/<project_id>/
├── orchestrations/                                  <-- 新增子層
│   └── <stamp>/                                     <-- 一次 supervisor envelope 落地一個 dir
│       ├── envelope.json                            <-- 完整 envelope（含 task_constitution / capability_graph nested）
│       ├── envelope.md                              <-- 人類可讀摘要（goal + governance + step list）
│       ├── validation.json                          <-- jsonschema 驗證結果（envelope-level + nested pass-through）
│       └── source-prompt.txt                        <-- 原始 user prompt
├── constitutions/...                                <-- P2 既有
├── compiled-workflows/<stamp>.json                  <-- 既有
└── handoffs/<step_id>.ticket.json                   <-- 既有
```

**Migration 策略**：

- 沒有舊資料需要 migrate（envelope 是新概念，第一次 P3 producer 跑就直接寫 `orchestrations/<stamp>/`）。
- task constitution 仍寫到 `constitutions/<task_id>/constitution-<stamp>.json`（既有路徑，無變動）；envelope 內 nested task_constitution 與 disk task constitution 是「同源不同表」（envelope 是 supervisor 提交版本、disk 是後續 persist 版本）。

**Stamp 格式**：沿用 `YYYYMMDDTHHMMSSZ`（與 P2 / persist-constitution.sh 對齊），便於 lexicographic latest 查找與跨 artifact stamp 對齊。

## 5. Envelope vs Neighbours Mapping Table

| Artifact | Schema | Producer | Disk path | Envelope 關係 |
|---|---|---|---|---|
| **Supervisor Orchestration Envelope** | `supervisor-orchestration.schema.yaml` | supervisor sub-agent (P3 producer) | `orchestrations/<stamp>/envelope.json` | **本身**；其他 4 個 artifact 是 envelope 的子物件或下游產物 |
| Task Constitution | `task-constitution.schema.yaml` | supervisor draft 或 `task_scoped_compiler.build_task_constitution` | `constitutions/<task_id>/constitution-<stamp>.json` | envelope.task_constitution 為 nested 子物件；disk 版本為平行歸檔 |
| Capability Graph | `capability-graph.schema.yaml` | `task_scoped_compiler._build_capability_graph` | （目前無單獨 disk 路徑，在 compiled-workflow 內）| envelope.capability_graph 為 nested 子物件 |
| Compiled Workflow | `compiled-workflow.schema.yaml` | `task_scoped_compiler.compile_task` | `compiled-workflows/<stamp>.json` | **下游 consumer 產物**：compile_task 接 envelope → 產 compiled workflow |
| Binding Report | `binding-report.schema.yaml` | `engine/runtime_binder.py` | `bindings/<stamp>.json` | **下游 consumer 產物**：binder 接 compiled workflow + envelope.compile_hints → 產 binding |
| Handoff Ticket (Type C) | `handoff-ticket.schema.yaml` | `scripts/workflows/emit-handoff-ticket.sh` | `handoffs/<step_id>.ticket.json` | **下游 consumer 產物**：emitter 從 envelope per-step 推導 ticket |
| Handoff Summary (Type D) | （markdown 五段結構 per `policies/handoff-ticket-protocol.md` §4） | sub-agent (Claude / Codex / shell) | `handoffs/<step_id>.summary.md`（依 ticket.output_expectations.handoff_summary_path） | **與 envelope 並行**：sub-agent 完工後寫，envelope 是 spawn 前的決策、summary 是完工後的回報 |

**讀法**：縱向看每個 artifact 的責任剖面；envelope 是「supervisor 對單一 prompt 的整體決策 SSOT」，其他 6 個 artifact 不是 envelope 的兄弟，而是 envelope 的「(a) nested 子物件、(b) 下游 consumer 產物、或 (c) 下游 sub-agent 回報」三類角色。

## 6. Implementation Order for P3（建議）

依本 memo 邊界推導出的 P3 子任務順序：

| # | 子任務 | 變動範圍 | 阻塞下一步？ |
|---|---|---|---|
| **P3 #1** | 本 memo（boundary）| docs only | ✓（後續所有任務的錨）|
| P3 #2 | Schema review / contract tightening：評估 `failure_routing` block 是否補入 schema、可選 step_status_enum；新增 positive / negative fixtures | `schemas/supervisor-orchestration.schema.yaml` + `tests/scripts/test-supervisor-orchestration-schema.sh` | 部分（P3 #4 hook 需要 final schema）|
| P3 #3 | Supervisor producer：`agent-skills/01-supervisor-agent.md` §3.x 補 envelope emission 協議；可選 runtime wrapper helper（`engine/supervisor_envelope.py`）做 fence extraction + drift check | agent-skills + 可選 engine module | 是 |
| P3 #4 | Runtime validation hook：在 envelope 從 producer 到 consumer 之間插 jsonschema 驗證 + drift check，失敗 exit 41 | engine/step_runtime.py 或新 helper + 接入點 | 是 |
| P3 #5 | Compiled workflow / binding integration：compile_task 改從 envelope 讀 task_constitution / capability_graph 而非內部 reconstruct；binder 讀 envelope.compile_hints | engine/task_scoped_compiler.py + engine/runtime_binder.py | 是 |
| P3 #6 | Failure routing：envelope schema 加 `failure_routing` 欄位（halt / route_back / retry / escalate）並讓 runtime 依此分派 | schema + step_runtime/runtime_binder | 否 |
| P3 #7 | Docs / CLI visibility：ARCHITECTURE 章節、TODOLIST / CHECKLIST、cap workflow bind/run help 補 envelope 顯示 | docs + scripts | 否 |
| P3 #8 | Release gate smoke：deterministic e2e 覆蓋 valid envelope / invalid schema halt / drift halt / routing decision visible / compile + bind 不破 | tests/e2e + smoke-per-stage.sh | 是（release gate）|

**P3 #1 完成後請使用者拍板邊界**，再進 P3 #2。本 memo 不假設任何 runtime 行為被改寫，僅為設計依據。

## 7. Open Questions（need user decision）

1. **Producer 是 supervisor sub-agent 還是 runtime wrapper？**
   - 選 A：supervisor sub-agent 自身產出 envelope JSON 包在 fence 內（與 task constitution / project constitution 同 convention）；runtime 只負責 fence extraction + validation，不重組 envelope。
   - 選 B：runtime wrapper post-process supervisor 自由文字成 envelope；supervisor 不需認識 schema。
   - **建議 A**：與 P0 #4 schema header 既有定位（「SupervisorOrchestrator 必須產出」）、`agent-skills/01-supervisor-agent.md` §3.6 既有派工協議、P2 同模式（producer 是真正決策者）三方一致；B 會讓 supervisor 失去自主性、且 wrapper 容易產生與 supervisor 真實意圖偏離的 envelope。

2. **Storage 是新建 `orchestrations/<stamp>/` 還是寄居既有路徑？**
   - 選 A：新建獨立子層 `orchestrations/<stamp>/` four-part snapshot（envelope.json / envelope.md / validation.json / source-prompt.txt），與 P2 `constitutions/project/<stamp>/` 對稱。
   - 選 B：寄居 `compiled-workflows/<stamp>/`（envelope 是 compile bundle 的 entry），同 dir 多檔。
   - 選 C：不寫 disk，只在 runtime memory（envelope 寫入即被 consumer 消費）。
   - **建議 A**：與 P2 對稱、可被 doctor / status 觀察、四件套可審計；B 讓 envelope 與 compile 結果耦合難拆；C 失去 audit trail，事後無法 replay supervisor 決策。

3. **envelope schema 是否補 `failure_routing` block（P3 #6 預留）？**
   - 選 A：P3 #2 即補入 schema 為 required；producer 必須在 envelope 內明示每 step 的 on_fail 行為（halt / route_back_to / retry / escalate_user）。
   - 選 B：P3 #2 暫不補，留到 P3 #6 再決定；envelope 先穩定 9 個 required + governance + compile_hints。
   - 選 C：補但設為 optional，producer 可選擇填或不填。
   - **建議 A**：failure_routing 是 supervisor 對 run-time 行為的決策一部分，與 governance.watcher_mode 同等級；不在 envelope 寫死、後續 routing 會散落到各 sub-agent 自行決定，違反「envelope 是 single truth」原則。但若 supervisor 行為書 §3.6 已能完整描述 routing（boundary memo 與 schema 重疊），可改採 B 避免雙寫。

請使用者就這 3 點裁示後再進 P3 #2。

## 8. Cross-References

- 本 memo 的政策依據：`policies/constitution-driven-execution.md` §1.3（Mode C conductor binding）、`policies/handoff-ticket-protocol.md`（Type C / Type D 協議）。
- Storage 路徑契約：`policies/cap-storage-metadata.md` §1（storage location SSOT）。
- 既有 envelope schema：`schemas/supervisor-orchestration.schema.yaml`（P0 #4 commit `82ad424`，10 fixture cases via `tests/scripts/test-supervisor-orchestration-schema.sh`）。
- 既有 nested schema：`schemas/task-constitution.schema.yaml`、`schemas/capability-graph.schema.yaml`。
- 既有 producer（部分 envelope 子物件）：`engine/task_scoped_compiler.py:build_task_constitution` / `compile_task`。
- 既有派工協議：`agent-skills/01-supervisor-agent.md` §3.6 (Type C ticket emission) 與 §2.5 (Task Constitution 嚴格 schema 契約)。
- P2 對等模式（boundary memo → 5-surface → producer / validation / storage 落地）：`docs/cap/CONSTITUTION-BOUNDARY.md`。
- P3 brief：使用者於 v0.22.0-rc3 closeout 後給的 P3 任務清單（含 P3 #1-#8 順序）。
