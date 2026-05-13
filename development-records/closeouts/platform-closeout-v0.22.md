# CAP Platform Closeout — v0.22 (P0–P10)

> **狀態**：v0.22 release candidate series（rc1–rc16）已蓋過 P0–P10 全部 11 個 engineering batch。本文件不是新功能規劃，是 platform-level 收斂：回答「現在 CAP 能做什麼」、「P1-P10 帶來什麼提升」、「還剩哪些肥大與治理債」三件事，並把所有對外的 SSOT (`policies/` / `schemas/` / `docs/cap/`)、commit chain、focused test 索引集中到一處供使用者與後續維護者參考。

## 1. 現在 CAP 到底能做什麼？(Capability Map)

### 1.1 Project Identity & Storage（P1 / Phase 2）

CAP 給每個專案一個穩定身份與本機儲存區：

- **project_id 解析**：從 `<repo>/.cap/project.yaml`（namespaced）或 `.cap.project.yaml`（legacy）讀取，無檔時走 git remote / basename fallback；衝突直接 halt，不允許隱式漂移。
- **本機儲存樹**：`~/.cap/projects/<project_id>/` 含 `constitutions/` / `compiled-workflows/` / `bindings/` / `workspace/` / `traces/` / `logs/` / `drafts/` / `handoffs/` / `reports/` / `cache/` / `sessions/` 11 個固定子目錄；定義在 `policies/cap-storage.md`。
- **Identity ledger**：`<storage>/.identity.json` 防 collision；schema 在 `schemas/identity-ledger.schema.yaml`，由 `engine/project_context_loader.py` 寫入。
- **CLI 入口**：
  - `cap project init` 建立 namespaced project config。
  - `cap project status` / `cap project doctor` 健檢 + `HealthIssueKind` 9 error + 4 warning 分類。
  - `cap project migrate-config [--dry-run] [--force] [--remove-legacy]` 把 legacy `.cap.<name>` 散檔搬到 `.cap/<name>` namespace。

### 1.2 Project Constitution（P2 / Phase 3）

- **長期治理憲章**：`<repo>/.cap/constitution.yaml` 存生命週期 source-of-truth；schema `schemas/project-constitution.schema.yaml` 9 個必填欄位（含 `binding_policy` / `workflow_policy` 兩個 nested object）。
- **CLI**：`cap project constitution` 走 dry-run / from-file / validation / promote 路徑。
- **Schema-class executor exit policy**：政策違規 exit 41（policy `policies/workflow-executor-exit-codes.md`）。

### 1.3 Task Constitution / Compile / Bind（P3–P4 / Phase 4–5）

- **Task constitution**：runtime-side 8 個必填欄位嚴格契約（`schemas/task-constitution.schema.yaml`）+ `<<<TASK_CONSTITUTION_JSON_BEGIN>>>` fence；任務啟動時由 supervisor 寫入 `~/.cap/projects/<id>/constitutions/<task_id>/constitution.{yaml,json}`。
- **Supervisor structured orchestration**：`schemas/supervisor-orchestration.schema.yaml` 11 個必填頂層欄位 + governance / failure_routing / capability_graph / task_constitution 嵌套 body，由 `<<<SUPERVISOR_ORCHESTRATION_BEGIN>>>` fence 顯式包覆。
- **Compiled workflow**：13 個 step required field + governance required block；schema `schemas/compiled-workflow.schema.yaml`；`engine/compiled_workflow_validator.py` 提供 `post_build` + `post_unresolved_policy` 兩個 validation hook。
- **Binding report**：`schemas/binding-report.schema.yaml` 嚴格 contract，`binding_status` 三 enum（`ready / degraded / blocked`）；`engine/runtime_binder.py:bind_semantic_plan` 為唯一 producer，`ensure_binding_status_executable` 把 `blocked` 從 label 升為 halt。
- **CLI**：`cap workflow plan` / `bind` / `compile-task` / `compile-task-from-envelope`。

### 1.4 Workflow Run & Result Archive（P5–P7 / Phase 6–8）

- **Run dir 標準佈局**：`~/.cap/projects/<id>/reports/workflows/<workflow_id>/<run_id>/` 內 `runtime-state.json` + `agent-sessions.json` + `run-summary.md` + `workflow.log` + `route-history.jsonl` + 選用 `<step_id>.{md,raw.log,handoff.md}`。
- **Workflow result builder（P7）**：`engine/result_report_builder.py` aggregate 四個 SSOT source 為 `workflow-result.json`（`schemas/workflow-result.schema.yaml`）；同時 render `result.md` 作為 human-readable projection，schema fail / mv fail 全 fallback 到 legacy hardcoded 模板（不 halt run）。
- **`cap workflow inspect <run-id>`**：三層 resolution（`workflow-result.json` 優先 → builder fallback → legacy status-store）；text 6 sections + `--json` mode。
- **Run archive policy（P7 #6）**：`policies/run-archive.md` 定義 `active 30d → archived 180d → pruned 永久` lifecycle + 就地 `.lifecycle` marker；Logger handoff format 在 `agent-skills/99-logger-agent.md` §2.4。

### 1.5 Governance Gates（P8 / Phase 9）

四種 gate runner，全部消費 `schemas/gate-result.schema.yaml`：

- **Watcher** (`engine/watcher_gate_runner.py`)：milestone 一致性稽核。
- **Security** (`engine/security_gate_runner.py`)：secret / XSS / eval scan。
- **QA** (`engine/qa_gate_runner.py`)：jest / pytest / mocha + coverage threshold。
- **Logger** (`engine/logger_gate_runner.py`)：`workflow-result.json` archive readiness + mode-aware archive-summary。

Consumer 共用 `engine/gate_result_consumer.py` 路由 `result` × `risk_level` × `fail_routing.action` 三 enum 決定 halt / route_back / escalate / retry / defer；`rerun-failed-gate` 提供 versioned rerun audit trail。

### 1.6 Repo-Specific Source Resolver（P9 / Phase 10）

三層 source layered resolver：

- **Workflow resolver** (`engine/workflow_loader.py:_resolve_workflow_path`)：`<project_root>/.cap/workflows/` → `<cap_home>/shared/workflows/` → `<cap_root>/schemas/workflows/`，`source_layer` enum 含 `explicit` 處理絕對路徑。
- **Skill registry merge** (`engine/runtime_binder.py:load_skill_registry`)：同三層 priority project > shared > builtin，`skill_id` first-encountered-wins，`binding_defaults` deep-merge。
- **Binding report source metadata** (`schemas/binding-report.schema.yaml`)：`workflow_source` + 每 step `skill_source` + `effective_allowed_roots` snapshot。
- **Allowed source roots enforcement**：`SourcePolicyError` 共同基底 + `_compute_effective_allowed_roots`（implicit project + builtin defaults ∪ user-declared）+ `_assert_workflow_source_allowed` + `_assert_skill_source_allowed`，違反 halt 不降級。
- **5 個 methodology strategy** (`agent-skills/strategies/{diagnose-loop,tdd-vertical-slice,shared-language-and-adr,architecture-deepening,vertical-slice-planning}.md`) 掛在 7 個 agent skill 上。

### 1.7 Promote Runtime Artifact 回 Repo SSOT（P10 / Phase 11）

完整 typed promote surface：

- **`cap promote inspect <id>`**：read-only 三層 resolver；`conflict_kind` 三 enum (`no_target / identical / diff`)。
- **`cap promote project-constitution <task_id>`**：寫 `<project_root>/.cap/constitution.yaml`（policy §3.1）。
- **`cap promote workflow <workflow_id>`**：寫 `<project_root>/.cap/workflows/<workflow_id>.yaml`（policy §3.2）。
- **共用 flag**：`--apply` (default dry-run) / `--force`（diff 衝突時 backup + 覆蓋）/ `--json`。
- **Backup / validation / rollback**：`<target>.bak.<ISO>` UTC ISO8601 timestamp、schema validation 永遠 always-on、validate fail 自動 rollback（`unlink` for fresh write，`shutil.copy2` from backup for overwrite）。
- **Producer**：`engine/promote_candidate_producer.py:produce_candidates(...)` 取代 P0 hard-coded `[]`，`final_state != "completed"` 不 emit compiled_workflow（policy §5.3）。

## 2. P1–P10 帶來什麼提升？(Before → After Diff)

| 範疇 | Before（無 P1-P10） | After（v0.22 closeout） |
|---|---|---|
| **專案身份** | 人工記憶路徑、手動配 `.cap.*` 散檔 | `cap project init` 寫 `.cap/project.yaml` + identity ledger 防 collision |
| **儲存** | 散落 `workspace/` / `.ai/` / `.agents/`，污染 repo | `~/.cap/projects/<id>/` 11 子樹規範化，policy 治理 |
| **憲章** | prompt 輸出自由文字 | `schemas/project-constitution.schema.yaml` + `task-constitution.schema.yaml` 嚴格 8 / 9 欄位、fence-bounded 顯式 producer |
| **編譯 / 綁定** | agent 即興產 capability mapping | `compiled-workflow.schema.yaml` + `binding-report.schema.yaml` 雙 schema gate，`binding_status` halt 阻擋 unresolved required step |
| **執行結果** | 跑完不知道結果 | `workflow-result.json`（machine artifact）+ `result.md`（human projection）+ `cap workflow inspect <run-id>` 三層 resolution |
| **Run 結案** | runtime artifact 散落，無 lifecycle | `policies/run-archive.md` active → archived → pruned 三段 + Logger §2.4 結案歸檔摘要 contract |
| **品質門禁** | agent 自報 pass | watcher / security / qa / logger 4 個 gate runner，consumer 路由 halt / route_back / escalate / retry / defer |
| **Workflow / skill source** | 只能改 cap-protocols 內建 | project (`.cap/workflows/`) > shared > builtin 三層 resolver，binding report 帶 `source_layer` 審計 |
| **Source 治理** | constitution `allowed_source_roots` 是擺設 | `_assert_workflow_source_allowed` + `_assert_skill_source_allowed` 雙 gate，違反 halt 不降級 |
| **Promote** | 手動 `cp` 不知道有沒有合規 | `cap promote inspect / project-constitution / workflow` typed surface，dry-run / backup / validation / rollback 全鏈 |

**最大的單點轉變**：從「rely on prompt 紀律 + 人工記憶」到「schema 為門禁 + runtime 為審計」。所有跨 agent / 跨 run 的契約都被推到 `schemas/*.yaml`，所有跨 commit / 跨 run 的軌跡都被推到 `~/.cap/projects/<id>/`。憲法、計畫、執行、結果、晉升都有檔可審。

## 3. 還剩哪些肥大與治理債？(Known Debt)

### 3.1 Deferred / 明確未做（不阻塞 P0-P10 closeout）

| 項目 | 範圍 | 文件位置 |
|---|---|---|
| Detached / background workflow run | `cap workflow run -d` / `cap workflow ps` / `cap workflow cancel` | `MISSING-IMPLEMENTATION-CHECKLIST.md` P10「Deferred to a later cycle」 |
| Run status polling | 與 detached run 綁定 | 同上 |
| Publish workflow（cross-repo） | `cap publish` 對外發布到 shared registry | 同上；publish vs promote 是不同問題 |
| `cap promote workflow --smoke` | policy §6.3 compile/bind smoke | P10 #6 進度欄；schema validation 已涵蓋核心 |
| Codex / Claude 原生 SKILL.md export | mapper 擴充 | P9 #1 deferred 段；等 builtin / project / shared resolver 全收後再做 |
| Plugin / marketplace 安裝流程 | 同上 | P9 #1 deferred 段 |
| Shared layer 完整生態 | producer 範本、共用 skills 收編流程 | rc15 release-notes notes 段 |

### 3.2 Backwards-compat / Escape Hatch（保留是設計，不是債）

| 項目 | 為何保留 | 何時可移除 |
|---|---|---|
| `cap promote list` / `cap promote <src> <dst>` generic mode | 早期 ad-hoc reports / drafts 仍有需求 | 等 typed surface 覆蓋率夠高再評估 |
| `<repo>/.cap.<name>` legacy 散檔 dual-path | rc11 / rc12 P0c batch 沒走 `--remove-legacy` | 等使用者社群完成 migration |
| 既有 `cap-promote.sh` 直接 forward CLI | 與 typed surface 並存 | 同 generic mode |
| `validate-jsonschema` 對 YAML target 會 parse 失敗的限制 | step_runtime 早期是 JSON-only contract | 已由 `engine/promote_apply.py:_validate_target_via_step_runtime` 旁路解決，不需動 step_runtime |

### 3.3 文件 / Checklist 重複來源（治理債）

- `TODOLIST.md`（產品 Phase）vs `MISSING-IMPLEMENTATION-CHECKLIST.md`（engineering P）vs `IMPLEMENTATION-ROADMAP.md`（path narrative）三套 checklist 互有重疊；本 closeout 用 cross-reference 收齊但未合併。建議下一輪整理：把 P 編號當主軸、Phase / roadmap 當引用視角，而非 SSOT 重複。
- `policies/runtime-promote.md` §3.1.2 把 `.cap/skills.json` 寫死 — 但 canonical 是 `.cap/skills.yaml`。實作 (`_compute_effective_allowed_roots`) 已修補 `.yaml/.yml/.json` 三 extensions 全收，policy 文件本身仍寫 `.json` 字眼，後續若改 policy v1.1 應對齊。

### 3.4 Smoke Suite 變肥

`scripts/workflows/smoke-per-stage.sh` 現有 40 個 step，跨 P0a–P10。本 P10 closeout 順手 chmod +x 修了 21 個 pre-existing test files，smoke 從 43 pass / 29 fail 提升到 61 pass / 11 fail；剩 11 fail 為 P1 / P2 / P3 / P6 / P8 e2e 環境依賴失敗（cap binary 不在 PATH、project state 殘留、harness 假設），**與 P10 無關**。下一輪 closeout 應由各 phase owner 處理。

### 3.5 P10 Promote 的小 corner

- `make_template_backup_path` 在 inspect 階段用 `<target>.bak.<ISO>` 字面 placeholder，apply 才產真實 timestamp — 兩個階段 backup_path 字串會不同，腳本消費者必須認字面 `<ISO>` 才不會誤判。已在 `docs/cap/PROMOTE-LIFECYCLE.md` §8.1 標明，但屬於 v1 介面便利性的小代價。
- `_rollback_target` 對「target 原本存在但無 backup（理論上不會發生）」branch 是防衛性 return failure；實務上 apply 流程不會走進此分支，但邏輯保留以防未來 refactor 引入 bug。

## 4. Dogfood 驗證鏈

User-suggested 7-step chain to prove the value of P1–P10：

```bash
cap project status                                           # P1 storage + identity
cap project doctor                                           # P1 health check
cap workflow run project-constitution "建立一個測試專案憲章"   # P2-P5 full pipeline
cap workflow inspect <run-id>                                # P7 result inspect
cap promote inspect <task-id>                                # P10 promote read
cap promote project-constitution <task-id> --dry-run         # P10 dry-run
cap promote project-constitution <task-id> --apply           # P10 apply + validate
```

### 4.1 Token-Free Validation（本 closeout 範圍）

不需 AI tokens 的部分由 focused test 嚴格覆蓋：

| Test | 覆蓋鏈條 | Assertions |
|---|---|---|
| `test-project-init.sh` / `test-project-status.sh` / `test-project-doctor.sh` | P1 step 1–2 | identity ledger / storage health |
| `test-cap-workflow-inspect.sh` | step 4 | 三層 resolution + `--json` |
| `test-cap-promote-inspect.sh` | step 5 | resolver / `conflict_kind` enum |
| `test-cap-promote-project-constitution.sh` | step 6–7 | dry-run / apply / backup / validation / rollback |
| `test-cap-promote-workflow.sh` | step 7 變體 | 同上但 artifact_type=compiled_workflow |
| `test-promote-candidate-producer.sh` | producer | `workflow-result.promote_candidates[]` 不再永遠 `[]` |

合計 17 個 P10-rooted suite 共 ~454 assertions（rc15 baseline 327 + P10 vintages）。Focused tests 涵蓋 token-free dogfood 的 step 1, 2, 4, 5, 6, 7。

### 4.2 Step 3 Live Run（user-action）

`cap workflow run project-constitution "..."` 真實呼 AI provider，產生實際 task constitution snapshot。本 closeout **未自動執行**（避免無預期 token 花費）；若使用者要驗 end-to-end，建議流程：

```bash
# 1. 從乾淨的 cwd 起
cd /tmp/cap-dogfood-$(date +%s)
git init && cap project init

# 2. 跑 constitution workflow
cap workflow run project-constitution "建立一個測試專案憲章"
# → 拿到 run-id 與 task-id

# 3. inspect run
cap workflow inspect <run-id>
# → 看 6 sections 是否齊全、final_state=completed、promote_candidates 含 project_constitution

# 4. promote chain
cap promote inspect <task-id>
cap promote project-constitution <task-id>            # default dry-run
cap promote project-constitution <task-id> --apply

# 5. 驗 repo state
ls -la .cap/constitution.yaml
cat .cap/constitution.yaml | head -20
```

### 4.3 受 token cost 限制的補強建議

若有預算跑 live e2e：
- Provider parity（Claude vs Codex 對同一 prompt 各跑一次 task constitution + promote）。
- 跨 final_state 場景：成功 run、失敗 run、超時 run 各一條，驗 producer + apply gate 行為。
- 跨 conflict_kind：no_target / identical / diff 都至少跑一次完整 promote rollback。

## 5. 關鍵 SSOT 索引

### 5.1 Policies（governance contract）

- `policies/cap-storage.md` — runtime tree 結構
- `policies/cap-storage-metadata.md` — health-check / collision 規則
- `policies/run-archive.md` — run lifecycle (active / archived / pruned)
- `policies/runtime-promote.md` — promote 規則 + producer + apply 契約
- `policies/workflow-executor-exit-codes.md` — schema-class executor exit policy
- `policies/handoff-ticket-protocol.md` — Type C ticket
- `policies/cap-execution-model.md` — workflow execution boundary

### 5.2 Schemas（machine-readable contract）

- `schemas/project-constitution.schema.yaml`
- `schemas/task-constitution.schema.yaml`
- `schemas/capability-graph.schema.yaml`
- `schemas/supervisor-orchestration.schema.yaml`
- `schemas/compiled-workflow.schema.yaml`
- `schemas/binding-report.schema.yaml`
- `schemas/workflow-result.schema.yaml`
- `schemas/gate-result.schema.yaml`
- `schemas/identity-ledger.schema.yaml`
- `schemas/handoff-ticket.schema.yaml`
- `schemas/preflight-report.schema.yaml`

### 5.3 Reference Docs（user / architect 視角）

- `docs/cap/PLATFORM-GOAL.md` — 產品目標
- `docs/cap/IMPLEMENTATION-ROADMAP.md` — 14 Phase 路線
- `docs/cap/MISSING-IMPLEMENTATION-CHECKLIST.md` — P 編號工程清單（per-item 進度 SSOT）
- `docs/cap/ARCHITECTURE.md` — runtime module map
- `docs/cap/PROMOTE-LIFECYCLE.md` — 使用者面向 promote 操作指南
- `docs/cap/P9-SOURCE-RESOLVER-DESIGN.md` — P9 design memo (accepted baseline)
- `docs/cap/RELEASE-NOTES.md` — rc 系列 narrative
- `CHANGELOG.md` — Keep a Changelog 標準格式

## 6. v0.22 rc Series 對照

| rc | 主題 | 完成 |
|---|---|---|
| rc1–rc10 | P0 Runtime Contracts → P6 Artifact / Handoff / Validation 主體推進 | 詳見各 rc release notes |
| rc11 | Provider Isolation + CAP Config Namespace migration（P0b + P0c batches 1-2.5） | done |
| rc12 | P0c batch 2.6 — 6 個 P2-tested constitution writers | done |
| rc13 | P7 Result Report and Run Archive | done |
| rc14 | P8 Governance Gates closeout（pure-tag, no release-doc） | done |
| rc15 | P9 Repo-specific Source Resolver | done |
| **rc16** | **P10 Detached Runtime and Promote / Publish + Platform Closeout Review** | **本 tag** |

## 7. 結論：v0.22 是否達標？

**達標**。從「rely on prompt 紀律 + 人工記憶 + agent 自報」走到「schema 為門禁 + runtime 為審計 + promote-validate-rollback 為防線」三段。dogfood chain 7 步中有 6 步可由 token-free focused test 嚴格證明，剩第 3 步的 live AI run 由使用者選擇是否花 token 跑 end-to-end。

**接下來**：本 v0.22 closeout 後，下一個明顯排程是 Phase 12（Background Runtime — `cap workflow run -d` / `ps` / `cancel`）。但**不應**接著上強推；建議先讓 v0.22 的 P0-P10 在使用者真實環境裡跑一段時間，收實際 dogfood 反饋，再開 Phase 12。
