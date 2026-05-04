# CAP Missing Implementation Checklist

更新日期：2026-05-04（P4 #1-#9 compile-pipeline policy gates 落地，#5 deferred、#8 為語意 alignment doc）

本清單承接 `TODOLIST.md` 與 `docs/cap/IMPLEMENTATION-ROADMAP.md` 的「尚未完成」項目，整理成可執行的工程工作清單。原則是先補 runtime contract 與 validator，再補 runner、orchestration、session、gate 與 promote/publish 閉環。

> **v0.21.6 baseline**：本清單以 `v0.21.6` tag 為起點。R3（雙 project_id 解析）由 v0.21.5 `1425fa9` 收斂；nested task constitution JSON fence 由 v0.21.5 `55038dd` 處理；`non_goals=[]` 於 parity-check §4.2 拆 nonempty vs present-only 後合法（v0.21.5 `2492913`）；v0.21.6 完成 P0a 6 個 schema-class executor exit 41 對齊與 fresh provider parity baseline 驗證（Claude / Codex 各 16/16 / 43 PASS / 0 FAIL）。詳見 `docs/cap/RELEASE-NOTES.md`、`docs/cap/PROVIDER-PARITY-FRESH-E2E-V0.21.5.md` 與 `docs/cap/PROVIDER-PARITY-FINDINGS-v0.21.2.md`。

進度標記規則：

- `partial`：已有局部 case 或輔助工具落地，但尚未滿足該項完整驗收。
- `foundation`：已補上前置基礎，後續仍需完成主要功能。
- 未標記者視為尚未開始或目前文件中沒有可對齊的落地證據。

## Phase ↔ P 編號對照

`TODOLIST.md` 與 `docs/cap/IMPLEMENTATION-ROADMAP.md` 使用「Phase」作為產品路線階段；本清單使用「P」作為工程執行批次。兩者不是同一個序列，對照如下：

| Product Phase | Engineering Batch | Scope |
|---|---|---|
| Phase 1 | P0 | Runtime Contracts |
| Phase 2 | P1 | Project Storage and Identity |
| Phase 3 | P2 | Project Constitution Runner |
| Phase 4 | P3 | Supervisor Structured Orchestration |
| Phase 5 | P4 | Compiled Workflow and Binding Pipeline |
| Phase 6 | P5 | AgentSessionRunner |
| Phase 7 | P6 | Artifact, Handoff and Validation |
| Phase 8 | P7 | Result Report and Run Archive |
| Phase 9 | P8 | Governance Gates |
| Phase 10 | P9 | Repo-specific Source Resolver |
| Phase 11 | P10 | Detached Runtime and Promote / Publish |

歷史 commit / release note 中的 `P0`–`P10` 依上表解讀；不要把 Phase 編號與 P 編號混用為同一序列。

## P0：先補齊 Runtime Contracts

- [x] 定義 `schemas/capability-graph.schema.yaml`
  - 交付物：capability graph JSON Schema
  - 驗收：schema 可驗證 nodes / edges / required / depends_on / reason
  - 進度：done in `v0.22.0` (in-progress)；schema 採「implicit edge via depends_on」設計，對齊 `engine/task_scoped_compiler.py:build_capability_graph` 既有 producer 行為；新增 `tests/scripts/test-capability-graph-schema.sh` 覆蓋 2 positive（minimal / realistic full-spec）+ 6 negative（missing top-level、missing node field、bad enum、empty nodes、bad depends_on type、bad schema_version）共 8 cases。納入 `smoke-per-stage.sh`：升為 16 step / **16 passed / 0 failed / 0 skipped**。

- [x] 定義 `schemas/compiled-workflow.schema.yaml`
  - 交付物：compiled workflow JSON Schema
  - 驗收：schema 可驗證 workflow_id / run_id / steps / dependencies / executor / inputs / outputs
  - 進度：done in `v0.22.0` (in-progress)；schema 對齊 `engine/task_scoped_compiler.py:build_candidate_workflow` 既有 producer 行為（workflow_id / version / name / summary / owner / triggers / governance / steps 8 個頂層欄位 + step 13 個必填欄位）。**SSOT 邊界裁定**：`run_id` 屬 workflow-result.schema（P0 #5），`executor` 屬 binding-report.schema（P0 #3），不重複宣告於本 schema 以避免 SSOT 衝突。`steps[].needs` 維持為 `capability_graph.depends_on` 的 alias（既有 RuntimeBinder 約定）。新增 `tests/scripts/test-compiled-workflow-schema.sh` 覆蓋 2 positive + 7 negative 共 9 cases，wire 進 `smoke-per-stage.sh`：升為 17 step / **17 passed / 0 failed / 0 skipped**。

- [x] 定義 `schemas/binding-report.schema.yaml`
  - 交付物：binding report JSON Schema
  - 驗收：schema 可驗證 resolved / unresolved / fallback / provider_cli / source_priority
  - 進度：done in `v0.22.0` (in-progress)；schema 對齊 `engine/runtime_binder.py:bind_semantic_plan` 既有 producer 行為。Acceptance 對應：resolved/unresolved/fallback → `step.resolution_status` enum 6 值 + `summary` 5 個聚合計數；provider_cli → `step.selected_cli`（nullable string）；source_priority → `registry_source_path` + `adapter_from_legacy` + `project_context.binding_policy`。**SSOT 邊界裁定**：`executor` 不開頂層欄位，executor 類型由 `selected_provider`（"builtin" 為 shell；其他為 AI）+ `selected_skill_id`（"builtin-shell" 為 shell）組合**隱式**表達；避免與 compiled-workflow 既有 step.executor input 重複宣告造成 SSOT 衝突。Nullable 欄位採 `type: [string, "null"]`（jsonschema 4.x Draft202012Validator 支援）表達「未解析」分支。新增 `tests/scripts/test-binding-report-schema.sh` 覆蓋 2 positive + 8 negative 共 10 cases，wire 進 `smoke-per-stage.sh`：升為 18 step / **18 passed / 0 failed / 0 skipped**。

- [x] 定義 `schemas/supervisor-orchestration.schema.yaml`（contract done; producer pending P3）
  - 交付物：Supervisor structured output JSON Schema
  - 驗收：schema 覆蓋 task_constitution / capability_graph / governance / compile_hints
  - 進度：done as **forward contract** in `v0.22.0` (in-progress)；schema 涵蓋 envelope 9 個必填頂層欄位 + governance 4 個必填 sub-field + compile_hints optional sub-field 集合。**範圍邊界**：本 schema 只驗證 envelope 結構與 nested object presence；nested artifact 內部欄位（task_constitution / capability_graph）由 sibling schema（`task-constitution.schema.yaml` / `capability-graph.schema.yaml`）負責，避免重複宣告造成 SSOT 衝突。**Producer 狀態**：尚無 runtime producer 滿足此 envelope —— `engine/task_scoped_compiler.py:compile_task` 是 task-scoped 內部結果聚合，**不是** supervisor 對外 envelope；P3 SupervisorOrchestrator 才是目標 producer，留到 P3 cycle 實作。Acceptance 對應：本輪只接到 schema parse + fixture validation；runtime hook 由 P3 接。新增 `tests/scripts/test-supervisor-orchestration-schema.sh` 覆蓋 2 positive + 8 negative 共 10 cases，wire 進 `smoke-per-stage.sh`：升為 19 step / **19 passed / 0 failed / 0 skipped**。

- [x] 定義 `schemas/workflow-result.schema.yaml`（contract done; full result builder pending P7）
  - 交付物：workflow result JSON Schema
  - 驗收：schema 可驗證 run status、step results、artifacts、failures、promote candidates
  - 進度：done as **normalized contract** in `v0.22.0` (in-progress)；schema 為 machine-readable 一次 workflow run 的 normalized result，aggregate 目前散落於 `runtime-state.json` / `run-summary.md` / `agent-sessions.json` / `workflow.log` 四個 source 的資訊。**範圍邊界**：本 schema 是 contract，不是現有 producer 1:1 投影；現有 `cap-workflow-exec.sh` 寫上述 4 個 source artifact，但未 emit 滿足本 contract 的單一 `workflow-result.json`。**Producer 狀態**：P7 result report builder 才實作 producer，會把四個 source aggregate 為單一 artifact；`result.md` 是本 contract 的 human-readable projection（同樣由 P7 owner）。Acceptance 對應：run status → `final_state` (5 enum) + `final_result` (4 enum)；step results → `steps[].status` (5 enum) + execution_state / duration / paths / failure object；artifacts → `artifacts[]` with name/path/producer/promoted；failures → `failures[]` with step_id/reason/route_back_to；promote candidates → `promote_candidates[]` with target_repo_path。新增 `tests/scripts/test-workflow-result-schema.sh` 覆蓋 2 positive + 8 negative 共 10 cases，wire 進 `smoke-per-stage.sh`：升為 20 step / **20 passed / 0 failed / 0 skipped**。

- [x] 定義 `schemas/gate-result.schema.yaml`
  - 交付物：governance gate result JSON Schema
  - 驗收：schema 可驗證 gate type、checkpoint、pass/fail、risk、route_back_to
  - 進度：done as **forward contract** in `v0.22.0` (in-progress)；schema 為 P8 governance gate runner（Watcher / Security / QA / Logger）對外的 per-gate decision envelope，補齊 supervise → run → gate triad 的最後一塊。**範圍邊界**：本 schema 是 contract，不是現有 producer 1:1 投影；目前 workflow 中的 gate 只是普通 sub-agent step，輸出走 stdout / Type D handoff text，沒有 machine-readable PASS / FAIL / risk / route_back_to 結構。**Producer 狀態**：P8 watcher / security / qa / logger checkpoint runner 才是直接 producer，並由 P8 gate result validation 在 cap-workflow-exec.sh 收 workflow_result 前先驗 gate output；P8 fail-route handling 與 enforce halt-on-risk 直接消費 `result` (4 enum) / `risk_level` (5 enum) / `fail_routing.action` (5 enum) 三欄位，不再讀自由文字。Acceptance 對應：gate type → `gate_type` (4 enum) + `gate_subtype` 自由文字；checkpoint → `checkpoint`；pass/fail → `result` (pass / fail / warn / blocked)；risk → `risk_level` (critical / high / medium / low / none)；route_back_to → `fail_routing.{action, route_back_to_step, reason}`。Findings shape 採最低約束（severity / category / description required，metrics 內容刻意 free-form 以保留領域演進空間）。新增 `tests/scripts/test-gate-result-schema.sh` 覆蓋 2 positive + 8 negative 共 10 cases，wire 進 `smoke-per-stage.sh`：升為 21 step / **21 passed / 0 failed / 0 skipped**。

- [x] 新增 schema parse / validation smoke tests
  - 交付物：集中測試入口或納入 `scripts/workflows/smoke-per-stage.sh`
  - 驗收：所有新增 schema 有 positive / negative fixture
  - 進度：done in `v0.22.0` (in-progress)；`provider-parity-check.sh` §4.2 已拆分 nonempty vs present-only 驗證語意（`v0.21.5` `2492913`）。P0 六個 schema 全綠：capability-graph 8 cases、compiled-workflow 9 cases、binding-report 10 cases、supervisor-orchestration 10 cases（forward contract）、workflow-result 10 cases（normalized contract）、gate-result 10 cases（forward contract）全進 `smoke-per-stage.sh`（21/21）。本項可結案；後續若新增 schema 須延續 2 positive + 多 negative 的 fixture pattern。

## P0a：Schema-Class Executors Exit Code 政策 ✓ resolved in v0.21.6

> 承接 v0.21.3 把 `persist-task-constitution.sh` 從 exit 40 改為 exit 41 的拆分（`schema_validation_failed` 與 `git_operation_failed` 分流），把同類 executor 的 exit code 語意統一。詳見 `docs/cap/PROVIDER-PARITY-FINDINGS-v0.21.2.md` deferred 段。

- [x] 建立 `policies/workflow-executor-exit-codes.md` SSOT
  - 交付物：exit code 政策文件
  - 驗收：明列每個 exit code 對應的 condition（如 `40 → git_operation_failed` / `41 → schema_validation_failed` / 其他保留碼），且涵蓋所有 schema-class executor
  - 進度：done in `v0.21.6`；新增 row 41 `schema_validation_failed` 與 Script Classification 段，明列 vc-class（`vc-scan` / `vc-apply`）vs schema-class（7 支腳本）。

- [x] 對齊 `validate-constitution` / `emit-handoff-ticket` / `ingest-design-source` / `bootstrap-constitution-defaults` / `persist-constitution` / `load-constitution-reconcile-inputs` 採用 exit 41
  - 交付物：6 個 shell executor 的 exit code 修正
  - 驗收：`cap-workflow-exec.sh:shell_exit_condition` 對應到正確分類，schema 失敗不再被誤分類為 git op 失敗
  - 進度：done in `v0.21.6`；6 個 executor 的 `fail_with` 從 exit 40 改為 exit 41 並對齊 `condition: schema_validation_failed`；同步修補 `persist-constitution.sh:152` grep 條件以接受新舊兩種 condition 字串作為 backward compatibility。

- [x] 補對應測試
  - 交付物：`tests/scripts/` 為各 executor 補 exit code 案例
  - 驗收：每個 executor 至少一個 schema-fail 案例命中 exit 41，且 `smoke-per-stage.sh` 不退化
  - 進度：done in `v0.21.6`；新增 4 個 exit-code 專屬測試（`test-validate-constitution-exit-code.sh` / `test-bootstrap-constitution-defaults-exit-code.sh` / `test-persist-constitution-exit-code.sh` / `test-load-constitution-reconcile-inputs-exit-code.sh`），更新 `test-emit-handoff-ticket.sh` / `test-design-source-ingest.sh` 既有斷言為 41；`smoke-per-stage.sh` 升為 15 step / **15 passed / 0 failed / 0 skipped**。

## P1：Project Storage and Identity

- [x] 支援非 git folder 的 project id 策略
  - 交付物：project id resolver fallback
  - 驗收：無 git repo 時仍能產生穩定 project id
  - 進度：done in `v0.22.0` (in-progress)；`scripts/cap-paths.sh:resolve_project_identity` 與 `engine/project_context_loader.py:_resolve_project_id` 同步走 strict resolution chain（override → `.cap.project.yaml` → git basename），非 git 目錄無 identity 來源時 shell 端 exit 52、Python 端 raise `ProjectIdResolutionError`；提供 `CAP_ALLOW_BASENAME_FALLBACK=1` 作為 legacy escape hatch（仍寫 ledger 與 stderr warning，避免黑洞 storage）。新 exit code 52 `project_id_unresolvable` 已併入 `policies/workflow-executor-exit-codes.md`。

- [x] 處理 project id collision
  - 交付物：collision detection 與 disambiguation 規則
  - 驗收：同名資料夾不會共用同一個 `~/.cap/projects/<project_id>/`
  - 進度：done in `v0.22.0` (in-progress)；每個 project 第一次落地時於 `~/.cap/projects/<id>/.identity.json` 建立 inline ledger（`schema_version` / `project_id` / `resolved_mode` / `origin_path` / `created_at`），後續 resolve 比對 `origin_path`：mismatch 時 shell 端 exit 53、Python 端 raise `ProjectIdCollisionError`，stderr 列出 recorded vs current origin 與三條解法。新 exit code 53 `project_id_collision` 已併入 `policies/workflow-executor-exit-codes.md`。`.identity.json` 暫不獨立 schema 化，等 P1 #3 storage version metadata 一起 SSOT 設計。新增 `tests/scripts/test-project-id-resolver.sh` 覆蓋 8 cases / 25 assertions（git happy path、config override 各情境、strict halt、legacy fallback ledger、first-time idempotence、collision halt），wire 進 `smoke-per-stage.sh`：升為 22 step / **22 passed / 0 failed / 0 skipped**。

- [x] 記錄 storage version / migration metadata
  - 交付物：project storage metadata file
  - 驗收：`cap paths` 或 project status 可讀出 version / created_at / migrated_at
  - 進度：done in `v0.22.0` (in-progress)；新增 `schemas/identity-ledger.schema.yaml`（v2 normalized contract，6 required + nullable optional + `previous_versions[]`）作為 storage metadata SSOT，搭配 `policies/cap-storage-metadata.md` 規範 schema versioning 政策、`cap_version` 來源（`repo.manifest.yaml` top-level 唯一）、`last_resolved_at` 只在 `ensure` 寫入、forward-incompat halt（exit 41）等治理鐵則。`scripts/cap-paths.sh:write_or_migrate_ledger` 與 `engine/project_context_loader.py:_verify_or_write_ledger` lock-step 升級為 v2 producer，三狀態（fresh / v1→v2 migrate / v2 re-entry）對齊；新增 `ProjectIdLedgerSchemaError` 對應 shell 端 exit 41。`repo.manifest.yaml` 補上 `cap_version: v0.22.0-rc1` 作為 SSOT 起點。新增 `tests/scripts/test-identity-ledger-schema.sh` 覆蓋 2 positive + 9 negative 共 11 cases；既有 `tests/scripts/test-project-id-resolver.sh` 擴充至 12 cases / **47 assertions**（補 v2 fresh ledger / v1→v2 migration / forward-incompat halt / read-only 不更新 / cap_version 來源 4 個新 case）。`policies/workflow-executor-exit-codes.md` identity 章節補一條設計裁定，明示 ledger schema fail 走 exit 41 不開新 code。`smoke-per-stage.sh` 升為 23 step / **23 passed / 0 failed / 0 skipped**。同時補修 `scripts/cap-paths.sh` 與 `tests/scripts/test-project-id-resolver.sh` 的 git index +x 位元（P1 #2 commit `1acda13` 遺漏，導致 persist-task-constitution.sh 走 fallback path 出現 cascade fail）。

- [x] 實作 storage health check
  - 交付物：health check routine
  - 驗收：可偵測缺目錄、壞 metadata、不可寫 storage
  - 進度：done in `v0.22.0` (in-progress)；新增 `engine/storage_health.py` 作為 read-only diagnostic core（`StorageHealthChecker` + `run_health_check`），`HealthIssueKind` 12 種分類涵蓋 missing_storage_root / unwritable_storage / missing_directory / missing_ledger / malformed_ledger / forward_incompat_ledger / ledger_schema_drift / ledger_origin_mismatch / legacy_ledger_pending_migration / cap_version_mismatch / stale_storage / unknown_ledger_field。Exit code 對齊 `policies/workflow-executor-exit-codes.md`：schema-class issue→41、collision→53、generic error→1、warning-only→0。**Read-only 鐵則**：嚴禁寫 ledger（特別是 `last_resolved_at`），避免污染 P1 #4/#7 與 P10 promote 的「實際使用 vs 工具掃描」訊號。新增 `scripts/cap-storage-health.sh` 薄 wrapper（`--format text|json|yaml` + `--strict`），底層直接呼叫 Python core。新增 `tests/scripts/test-storage-health.sh` 覆蓋 10 cases + 1 conditional unwritable case（root 環境跳過），共 26 assertions，wire 進 `smoke-per-stage.sh`：升為 24 step / **24 passed / 0 failed / 0 skipped**。`policies/cap-storage-metadata.md` §6 補上 P1 #4 落地狀態與後續 #5/#6/#7/P10 規劃，明示 read-only 鐵則。

- [x] 新增 `cap project status`
  - 交付物：CLI command
  - 驗收：顯示 project id、storage path、constitution status、latest run
  - 進度：done in `v0.22.0` (in-progress)；新增 `engine/project_status.py` 作為 read-only summary builder（重用 `engine/storage_health.run_health_check`，**禁止重做 health 判斷**），對外 `cap project status` 由 `scripts/cap-project.sh` 分派；輸出欄位：`project_id` / `project_root` / `project_store` / `ledger_path` / `cap_home` / `manifest_cap_version` / `ledger_snapshot` / `constitutions[]` / `constitution_count` / `latest_run` / 嵌套 `health{}`，`--format text|json|yaml` 三種輸出皆支援。Exit code 對齊 storage-health：schema-class issue→41、collision→53、generic error→1、warning-only→0。新增 `tests/scripts/test-project-status.sh` 8 cases / 21 assertions（healthy / ledger snapshot / 多 constitution / latest run mtime 排序 / json+yaml round-trip / malformed→41 / collision→53）；wire 進 `smoke-per-stage.sh`：升為 26 step / **26 passed / 0 failed / 0 skipped**。

- [x] 新增 `cap project init`
  - 交付物：CLI command
  - 驗收：可初始化 `.cap.project.yaml` 與 local storage
  - 進度：done in `v0.22.0` (in-progress)；新增 `scripts/cap-project.sh` 作為 `cap project` subcommand 統一入口（init / status / doctor 三 subcommand 預留），cap-entry.sh `project)` case 路由。Init 純 shell：`--project-id` / `--force` / `--format` / `--project-root` flag；先寫 `.cap.project.yaml`（已存在預設 halt，`--force` 走 in-place rewrite 保留無關 keys），再委派 `scripts/cap-paths.sh ensure` 建 storage + ledger（**重用 P1 #3 v2 producer，不重做 ledger 邏輯**）。Identity-class exit code（41/52/53）一律 propagate verbatim，下游自動化可正確分流。新增 `tests/scripts/test-project-init.sh` 10 cases / 33 assertions（git happy / non-git+--project-id / 缺 id halt / 既存 halt / --force preserve unrelated keys / --force replace id / json+yaml / collision halt 走 cap-paths 53）；wire 進 `smoke-per-stage.sh`：升為 25 step / **25 passed / 0 failed / 0 skipped**。

- [x] 新增 `cap project doctor`
  - 交付物：CLI command
  - 驗收：可輸出修復建議與 exit code
  - 進度：done in `v0.22.0` (in-progress)；新增 `engine/project_doctor.py`（**read-only by design**，per P1 #7 brief：`--fix` 接受但不自動修復，僅輸出 `fix_notes` guidance，留待後續 iteration）；`REMEDIATIONS` 字典覆蓋全部 12 種 `HealthIssueKind`（每種至少 2 條具體 remediation step，引用真實 CLI 命令如 `cap project init` / `cap-paths.sh ensure`）。Exit code 對齊 storage-health：schema-class→41、collision→53、generic error→1、warning-only→0。新增 `tests/scripts/test-project-doctor.sh` 10 cases / 31 assertions（healthy / missing storage root / missing subdir / missing ledger / malformed→41 / forward-incompat→41 / origin mismatch→53 / legacy v1→0 warning / json round-trip / --fix read-only contract）；wire 進 `smoke-per-stage.sh`：升為 27 step / **27 passed / 0 failed / 0 skipped**。`scripts/cap-entry.sh` 補 `cap project doctor` 進 `[Project]` 區塊；`policies/cap-storage-metadata.md` §6 重構為「6.1 P1 #4 落地 / 6.2 P1 #5/#6/#7 已落地 / 6.3 後續規劃」三段，明示 doctor read-only 鐵則與 `--fix` 後續 iteration 邊界。

## P2：Project Constitution Runner

- [x] 拆清 Project Constitution 與 Task Constitution 語意
  - 交付物：CLI / docs / workflow naming 調整
  - 驗收：`constitution / compile / run-task / run` 差異清楚可查
  - 進度：boundary 與 5-surface 分流定於 P2 #1 commit `01cc993`（`docs/cap/CONSTITUTION-BOUNDARY.md`）；CLI 落地於 P2 #6 commit `0314663` — 新增 `scripts/cap-task.sh` 與 `cap task constitution` 入口（透過 `scripts/cap-entry.sh task)` 路由），舊 `cap workflow constitution` 加 deprecation warning 且行為與 exit code 不變，`CAP_DEPRECATION_SILENT=1` 可抑制；`cap workflow compile` / `cap workflow run-task` 命名合理，依 boundary memo §4.1 KEEP 標記**不動**。`cap task plan / compile / run` 已在 `cap-task.sh` usage 中標為 (planned) 並回 exit 2，避免使用者誤以為已實作。文件對照表於 P2 #7 commit (current branch) 落地：`docs/cap/ARCHITECTURE.md` 新增「🪪 Constitution Command Boundary」章節（概述 + mini 對照表 + link 回 boundary memo §5 作為 SSOT），`cap-entry.sh [Task]` block 加一行邊界 hint 指向該章節，避免在 entry help 重複完整對照表。

- [ ] 調整 `schemas/workflows/project-constitution.yaml` 輸出契約
  - 交付物：workflow output contract
  - 驗收：明確產出 Markdown 與 JSON artifact

- [x] 實作 Project Constitution validator
  - 交付物：validator command 或 `engine/step_runtime.py` subcommand
  - 驗收：通過 `schemas/project-constitution.schema.yaml` 才能 promote
  - 進度：done in P2 #2-b commit `4e8c753`。`engine/project_constitution_runner.py:_run_jsonschema` 對齊 `engine/step_runtime.py:validate_constitution` 的 Draft 2020-12 行為（含 fallback required-only 模式），所有 runner 入口都會跑驗證；validation 失敗時 `validation.json` 會記錄 `status="failed"` 並使 CLI exit 1。

- [x] 實作 agent output JSON extraction
  - 交付物：Markdown / fenced JSON extraction routine
  - 驗收：可處理純 JSON、fenced JSON、Markdown 中嵌 JSON
  - 進度：done in P2 #2-b commit `4e8c753`。`engine/project_constitution_runner.py:_extract_constitution_json` 對齊 `scripts/workflows/validate-constitution.sh` 的 fence 規則（先抓 `<<<CONSTITUTION_JSON_BEGIN/END>>>`，再 fallback 單一 ```json``` block）。Task Constitution 端的 nested-fence 處理仍由 `v0.21.5` (`55038dd`) 的 `persist-task-constitution.sh` 負責，與本 routine 各司其職。

- [x] 實作 Project Constitution snapshot storage
  - 交付物：`~/.cap/projects/<project_id>/constitutions/project/<stamp>/`
  - 驗收：保存 `.md`、`.json`、`validation.json`、`source-prompt.txt`
  - 進度：done in P2 #2-b commit `4e8c753`。`engine/project_constitution_runner.py:_write_artifacts` 一律寫四件套；schema fail 時仍寫入但 `validation.json` 標記 `status="failed"`（依 P2 #2-b Q2 = A 的 doctor 可觀測性裁示）。

- [ ] 實作 constitution snapshot versioning
  - 交付物：snapshot index 或 metadata
  - 驗收：可列出、比對、回溯不同版本

- [x] 新增 `cap project constitution "<prompt>"`
  - 交付物：CLI command
  - 驗收：能跑 project constitution workflow 並保存 snapshot
  - 進度：done in P2 #2-b commits `d127efd` (CLI skeleton) + `4e8c753` (workflow wrap + 四件套寫入)。`scripts/cap-project.sh constitution` dispatcher 已通；prompt-mode subprocess wrap 已實作；P2 #8 commit (current branch) 補 deterministic e2e（`engine/project_constitution_runner.py:_invoke_workflow` 加 `CAP_PROJECT_CONSTITUTION_WORKFLOW_STUB` env seam + `tests/e2e/fixtures/project-constitution-stub.sh` 4 mode + `tests/e2e/test-cap-project-constitution-prompt.sh` 4 cases / 36 assertions），無 AI / 無 network 跑通 happy / missing-fence / invalid-schema / nonzero-exit 全部失敗路徑。

- [x] 新增 `cap project constitution --dry-run`
  - 交付物：dry-run mode
  - 驗收：產生 draft 與 validation，不寫回 repo
  - 進度：done in P2 #2-b commit `4e8c753`。`--dry-run` 走 `plan()` 純值計算路徑，不觸發 disk write，亦不會呼叫 workflow；smoke `tests/scripts/test-cap-project-constitution.sh` Case 1 覆蓋。

- [x] 新增 `cap project constitution --from-file`
  - 交付物：file input mode
  - 驗收：可從指定 prompt / draft 檔案產生 snapshot
  - 進度：done in P2 #2-b commit `4e8c753`。同時收 JSON / YAML（依 Q3 = A 先試 JSON、fallback YAML，並 normalize 成 JSON 寫入 snapshot）；smoke Case 2-3 覆蓋 happy path、Case 4 覆蓋 schema 失敗仍寫四件套、Case 5-8 覆蓋邊界錯誤。

- [x] 新增 `cap project constitution --promote`
  - 交付物：promote mode
  - 驗收：只有 valid snapshot 可寫回 `.cap.constitution.yaml` 或指定目標
  - 進度：done in P2 #5 commit (current branch)。`engine/project_constitution_runner.py:_run_promote` 在寫入前永遠重跑 jsonschema（P2 #5 Q3 = A：不信任 snapshot 內 `validation.json`），失敗時 repo SSOT 完全不動；既有 `.cap.constitution.yaml` 在覆寫前先複製成 `.cap.constitution.yaml.backup-<TIMESTAMP>`（P2 #5 Q2 = B：對齊 `scripts/workflows/persist-constitution.sh:296`）。`--promote STAMP` 強制顯式指定（P2 #5 Q1 = A），`--latest` 為獨立便利旗標、不會自動套用。本 commit 故意只寫 `.cap.constitution.yaml`，不寫 `docs/cap/constitution.md`（依 P2 #1 §4.5 與本輪 ratification 邊界，markdown 副本留待專屬 `--write-markdown` 旗標）。

> **P2 closeout (P2 #8, current branch)**：CLI / runtime / docs / smoke gate 已對齊。`cap project constitution` 與 `cap task constitution` 兩條 CLI 落地、`--from-file` / `--promote` / `--latest` 全 wire；prompt-mode 走 `CAP_PROJECT_CONSTITUTION_WORKFLOW_STUB` deterministic stub e2e（4 cases / 36 assertions）、alias 等價走 stdout byte-equal + canonical JSON parity e2e（9 assertions）；`scripts/workflows/smoke-per-stage.sh` 升為 31 step / **31 passed / 0 failed / 0 skipped**。仍開放：constitution snapshot versioning、Project Constitution workflow YAML 輸出契約調整（Markdown + JSON 直接 emit，不需 runner 自抽）— 兩項屬於 P2 後續加值，不阻擋 P3 開工。

## P3：Supervisor Structured Orchestration

> **P3 #1 boundary memo (current branch)**：`docs/cap/SUPERVISOR-ORCHESTRATION-BOUNDARY.md` 鎖定 supervisor envelope 與 5 個鄰居（Task Constitution / Capability Graph / Compiled Workflow / Handoff Ticket Type C / Handoff Summary Type D）在 producer / schema / consumer / validation / storage 5 surface 的分流。三件拍板：(Q1=A) producer 是 supervisor sub-agent，envelope JSON 走 `<<<SUPERVISOR_ORCHESTRATION_BEGIN/END>>>` fence；(Q2=A) storage 走 `~/.cap/projects/<id>/orchestrations/<stamp>/` four-part snapshot，與 P2 對稱；(Q3=A) `failure_routing` 補入 envelope schema 為 required。
>
> **P3 #2 schema tightening (current branch)**：`schemas/supervisor-orchestration.schema.yaml` 加 `failure_routing` block（`default_action` enum 對齊 `handoff-ticket.schema.yaml`、`default_route_back_to_step` / `default_max_retries` 條件欄位、`overrides[]` per-step override array），`tests/scripts/test-supervisor-orchestration-schema.sh` 從 10 cases 擴到 15 cases / **15 passed / 0 failed**。Schema 仍是 envelope-only validation；producer / runtime hook / storage writer 留 P3 #3-#4-#5 處理。
>
> **P3 #3 producer 規範 + envelope helper (current branch)**：`agent-skills/01-supervisor-agent.md` §3.8 補 producer 規範（強制 fence、11 required field 對應指引、drift rule、failure_routing / governance 推導指引、self-check）；`engine/supervisor_envelope.py` 純 helper（`extract_envelope` / `validate_envelope` / `check_envelope_drift` + argparse CLI），對齊 `engine/project_constitution_runner.py:_run_jsonschema` 的 Draft 2020-12 + fallback 模板。Helper 嚴格 pure function，不接 runtime hook、不寫 storage；agent skill 只補 producer 規範不寫 orchestration logic（依 `.claude/rules/agent-skills.md`）。`tests/scripts/test-supervisor-envelope-helper.sh` 15 cases / **35 passed / 0 failed**，接入 smoke-per-stage 為 case 30。Runtime ingestion hook + storage writer 留 P3 #4 / #5 處理。
>
> **P3 #4 runtime validation hook (current branch)**：新增 `scripts/workflows/validate-supervisor-envelope.sh` schema-class shell executor 與 `schemas/capabilities.yaml` `supervisor_envelope_validation` capability。Executor 從 `CAP_WORKFLOW_INPUT_CONTEXT` 取 envelope artifact，委派 `engine.supervisor_envelope` extract / validate / drift 三階段，任一 stage `ok=false` 都收斂為 exit 41 `schema_validation_failed`（對齊 `policies/workflow-executor-exit-codes.md` 與 P0a 6 個既有 schema-class executor）；reason 分四類（`missing_envelope_artifact` / `envelope_extraction_failed` / `schema_validation_failed` / `envelope_drift_detected`）。`tests/scripts/test-validate-supervisor-envelope-exit-code.sh` 5 cases / **17 passed / 0 failed**（happy + 4 failure classes），接入 smoke-per-stage 為 case 31。範圍嚴格守住：executor + capability 落地但**不**接到任何 workflow YAML，不寫 storage，留 P3 #5 整合 compile/bind 時才 wire。
>
> **P3 #5 boundary memo + #5-a storage writer (current branch)**：`docs/cap/ORCHESTRATION-STORAGE-BOUNDARY.md` 鎖定 storage layout / four-part snapshot writer interface / `compile_task` envelope-driven vs legacy reconstruct transition / legacy compatibility（拍板 Q1/Q2/Q3 = A/A/A）。`engine/orchestration_snapshot.py` 純 helper module 落地 storage writer：`write_snapshot(...)` 寫 `<cap_home>/projects/<id>/orchestrations/<stamp>/` 四件套（envelope.json / envelope.md / validation.json / source-prompt.txt），與 P2 對稱；validation 失敗仍落地（Q1=A），CLI exit 41 對齊 P3 #4 schema-class 規範；Markdown 採 placeholder（P3 #7 升級）。`tests/scripts/test-orchestration-snapshot.sh` 7 cases / **53 passed / 0 failed**（happy + 三條 failure path + edge cases + pure helper invocation），接入 smoke-per-stage 為 case 32。範圍嚴格守住：不改 `compile_task` / `runtime_binder` / workflow YAML / failure routing dispatch；5-b / 5-c 留下輪。
>
> **P3 #5-b compile/bind transition (current branch)**：`engine/task_scoped_compiler.py` 新增 `compile_task_from_envelope(envelope, registry_ref=None)` 與 exception class `CompileFromEnvelopeError`，與既有 `compile_task(source_request, registry_ref)` 並行；envelope-driven path 入口跑 `engine.supervisor_envelope.validate_envelope` + `check_envelope_drift` gate；hybrid merge（deterministic baseline + envelope dict-spread override）讓 step 3-5 內部硬依賴（risk_profile / unresolved_policy）有 baseline，envelope 主導 task_id / goal / goal_stage 等 authoritative 欄位。Output 多 `compile_hints_applied` 純記錄（envelope.compile_hints round-trip）；binder 簽章 0 改動，hints 翻譯為 binder 行為改動屬於後續工作。`tests/scripts/test-compile-task-from-envelope.sh` 6 cases / **22 passed / 0 failed**（happy + 兩條 raise + legacy compile_task 不受影響 + hint round-trip + 空 hints surface），接入 smoke-per-stage 為 case 33。範圍嚴格守住：不動 legacy `compile_task` 與 `runtime_binder` 簽章、不動 workflow YAML、不做 failure routing dispatch；5-c 留下輪。
>
> **P3 #5-c workflow YAML wire (current branch)**：新增 dedicated `schemas/workflows/supervisor-orchestration.yaml` 單一 step workflow 引用 P3 #4 `supervisor_envelope_validation` capability + executor；`.cap.constitution.yaml` `allowed_capabilities` 補 `supervisor_envelope_validation`（P3 #4 漏補的 binding 必要條目，缺它 binding 永遠 `blocked_by_constitution`）；`scripts/workflows/smoke-per-stage.sh` 加 `run_bind "supervisor-orchestration"` 為 binding case 4，與 project-spec / project-implementation / project-qa pipeline 三條 binding 同模式驗 `binding_status: ready` + `required_unresolved=0`。範圍嚴格守住：不為 P3 #5-a / #5-b 補 capability + shell wrapper；不接到 `project-constitution.yaml` / per-stage pipelines；不做 P3 #6 failure routing dispatch；不打 release tag。完成 P3 #5-c 即收斂整段 P3 #5。
>
> **P3 #6 failure routing resolver + xref (current branch)**：`engine/supervisor_envelope.py` 加兩個 pure helper：`check_failure_routing_xrefs(envelope) -> XrefReport`（偵測三類 dangling step_id：default_route_back_to_step / overrides[].step_id / overrides[].route_back_to_step）與 `resolve_failure_routing(envelope) -> list[dict]`（per-step 對應表 source=default|override 標籤），CLI 加 `xref` / `resolve` subcommand。`engine/task_scoped_compiler.py:compile_task_from_envelope` 入口加 xref gate（與既有 schema validate + drift 並列為三個 entry-gate failure class），output dict 升到 9 key 多 `failure_routing_resolved`。`tests/scripts/test-supervisor-envelope-helper.sh` 24 cases / **61 passed / 0 failed**（+9 P3 #6 cases）；`tests/scripts/test-compile-task-from-envelope.sh` 8 cases / **33 passed / 0 failed**（+2 P3 #6 cases），smoke-per-stage 不動。範圍嚴格守住：純 Python helpers；不動 shell executor / ticket emitter / workflow YAML；runtime dispatcher（halt / retry / route_back / escalate 實際行為）留 P5。
>
> **P3 #7 ARCHITECTURE / cap-entry visibility (current branch)**：`docs/cap/ARCHITECTURE.md` 新增「🎼 Supervisor Orchestration」（envelope flow 圖 + P3 #1-#6 commit 表 + 5 條 module map + 已知未接通清單，明確標記 runtime dispatcher / envelope→ticket / per-stage pipeline 整合 / 5-a 5-b capability 包裝四項仍未接）與「⛽ Runtime Cost & Token Budget Guardrails」（5 條 engineering discipline：reusable helper not one-shot script / shell wrapper not domain logic / workflow YAML 重用既有 capability / smoke 分層 / module map first grep second）兩個獨立章節；`scripts/cap-entry.sh` 加 `[Supervisor Orchestration]` 區塊單行 hint 指向 ARCHITECTURE + boundary memo。範圍嚴格守住：純 docs + entry hint；不動 engine / schemas / scripts / smoke 邏輯；不打 release tag。P3 #8 release gate smoke 留下輪。
>
> **P3 #8 release gate smoke (current branch)**：新增 `tests/e2e/test-supervisor-orchestration-release-gate.sh` 端到端 e2e 串接所有 P3 模組（envelope helpers → snapshot writer → compile from envelope → workflow binding）。**5 cases / 36 passed / 0 failed**：(0) happy 全鏈路通；(1) schema halt 缺 failure_routing → snapshot exit 41 仍寫四件套 / compile raise schema validation；(2) drift halt envelope.task_id≠nested → snapshot exit 41 / compile raise drift；(3) xref halt phantom step_id → snapshot 不擋（非 writer 層責任）/ compile raise xref；(4) `cap workflow bind supervisor-orchestration` 仍 ready。接 smoke-per-stage 為 case 34，與既有 P3 #1-#7 fixtures（cases 17 / 30 / 31 / 32 / 33 + binding case 4）共同構成 P3 release gate；full smoke-per-stage 升至 **37 step / 全綠**。範圍嚴格守住：純 deterministic e2e（無 AI / 無 network）；不動 engine / schemas / capability allowlist；不接 envelope→ticket / runtime dispatcher 行為實作；不打 release tag。**P3 整段（#1-#8）正式收斂**，envelope flow 的 producer / schema / runtime gate / storage / compile entry / failure routing resolver / docs / release gate 全部落地，P4 SupervisorOrchestrator 可從乾淨 baseline 開工。

- [ ] 實作 `SupervisorOrchestrator`
  - 交付物：engine module
  - 驗收：讀取 user prompt、Project Constitution、repo context 後產生 structured output

- [ ] 實作 supervisor prompt builder
  - 交付物：prompt construction routine
  - 驗收：輸入資料來源固定且可測試

- [ ] 實作 structured output parser
  - 交付物：parser
  - 驗收：拒收純自然語言派工

- [ ] 實作 orchestration schema validator
  - 交付物：套用 `schemas/supervisor-orchestration.schema.yaml`
  - 驗收：invalid output 會 halt 或 retry

- [ ] Supervisor 產出 task constitution
  - 交付物：validated task constitution artifact
  - 驗收：符合 `schemas/task-constitution.schema.yaml`

- [ ] Supervisor 產出 capability graph
  - 交付物：validated capability graph artifact
  - 驗收：符合 `schemas/capability-graph.schema.yaml`

- [ ] Supervisor 產出 compiled workflow draft
  - 交付物：compiled workflow draft artifact
  - 驗收：可交給 binding pipeline

- [ ] 保存 orchestration snapshot
  - 交付物：CAP storage snapshot
  - 驗收：每次 task plan / compile / run 可追溯 Supervisor 輸出

> **P3 closeout (P3 #8, current branch)**：P3 整段（#1-#8）正式收斂。Producer 規範 + envelope schema 嚴格 11 required（含 failure_routing）+ runtime validation hook（exit 41）+ four-part snapshot writer（symmetric P2，validation fail 仍寫）+ envelope-driven compile entry（與 legacy 並行，雙路徑共存）+ failure routing resolver / xref helper（pure Python；runtime dispatcher 留 P5）+ minimal binding workflow YAML + ARCHITECTURE module map / guardrails / boundary memo（`SUPERVISOR-ORCHESTRATION-BOUNDARY.md` + `ORCHESTRATION-STORAGE-BOUNDARY.md`）+ 端到端 release gate e2e。`scripts/workflows/smoke-per-stage.sh` **37 step / 全綠 / 0 skipped**。仍開放但不阻擋 P4 / P5：(1) runtime dispatcher（halt / retry / route_back / escalate 真正執行）屬 P5 AgentSessionRunner；(2) envelope→Type C ticket 鏈路打通；(3) per-stage pipeline 與 envelope flow 整合；(4) snapshot writer / compile entry 的 capability + shell wrapper 包裝。

## P4：Compiled Workflow and Binding Pipeline

- [x] 實作 compiled workflow schema validation
  - 交付物：validation hook
  - 驗收：invalid compiled workflow 不會進入 bind / run
  - 進度：done in `feat/compiled-workflow-validation`；新增 `engine/compiled_workflow_validator.py`（`CompiledWorkflowSchemaError` / `validate_compiled_workflow` / `ensure_valid_compiled_workflow`），於 `engine/task_scoped_compiler.py` 的 `compile_task` 與 `compile_task_from_envelope` 各掛兩個驗證點：`post_build`（producer 缺欄位 / 違反 enum / 壞 shape 即時 halt）與 `post_unresolved_policy`（policy transform 後再驗一次，halt 前不會進入 `build_bound_execution_phases_from_workflow`）。Prerequisite fix：`build_candidate_workflow` 補 `schema_version: 1`（先前漏輸出，導致 schema gate 一掛即斷）。`engine/workflow_cli.py:cmd_compile_json` schema fail 時印 deterministic JSON `{"ok": false, "error": "compiled_workflow_schema_error", "stage": "...", "errors": [...]}` 並 exit 1（schema-class exit 41 對齊留 shell executor wrapper）。同步把 `engine/step_runtime.py:validate-jsonschema` 的 fallback 升級為遞迴 nested-aware（required / type / enum / minItems / properties / items），讓無 jsonschema 套件的環境也能完整驗證。新增 `tests/scripts/test-compiled-workflow-validation-hook.sh` 7 cases / **16 passed / 0 failed**（happy / 缺 schema_version / 壞 version enum / 壞 steps shape / transform 破壞 → 不進入 bound phases / envelope 路徑繼承 hook / cmd_compile_json JSON 契約），接入 `smoke-per-stage.sh` 為 P4 #1 gate；`tests/scripts/test-compiled-workflow-schema.sh` 由 4/9 升至 **9/9 passed**。

- [x] 實作 binding report schema validation
  - 交付物：validation hook
  - 驗收：binding report 可被機器驗證
  - 進度：done in `feat/binding-report-validation`；新增 `engine/binding_report_validator.py`（`BindingReportSchemaError` / `validate_binding_report` / `ensure_valid_binding_report`），於 `engine/task_scoped_compiler.py` 的 `compile_task` 與 `compile_task_from_envelope` 在 `bind_semantic_plan` 後掛 `post_bind` 驗證點：binding report schema 失敗即時 halt，不會進入 `apply_unresolved_policy` 或 `build_bound_execution_phases_from_workflow`。Prerequisite fix：`engine/runtime_binder.py:bind_semantic_plan` 補 `schema_version: 1`（producer 先前漏輸出，與 P4 #1 同類型缺欄位 fix）。`engine/workflow_cli.py:cmd_compile_json` 加第二個 except 分支，schema fail 時印 `{"ok": false, "error": "binding_report_schema_error", "stage": "post_bind", "errors": [...]}` 並 exit 1，與 compiled-workflow validator 對稱。新增 `tests/scripts/test-binding-report-validation-hook.sh` 7 cases / **15 passed / 0 failed**（happy / 缺 schema_version / binding_status enum 違反 / summary 缺 nested required / fail 不進入 bound phases / envelope 路徑繼承 hook / cmd_compile_json JSON 契約），接入 `smoke-per-stage.sh` 為 P4 #2 gate。

- [x] 強化 step_runtime validate-jsonschema fallback（pattern + additionalProperties）
  - 交付物：fallback parity with jsonschema package
  - 驗收：identity-ledger 11/11 在無 `pip install jsonschema` 環境也能 pass
  - 進度：done in `feat/binding-report-validation`；`engine/step_runtime.py:_check_against_schema` 補 `pattern`（透過 `re.search`，bad regex 在 schema 內視為 error 而非 crash）與 `additionalProperties: false`（object 額外鍵被 reject；只強制 boolean false 形式，true 與 schema-form 維持 permissive 與 jsonschema 預設一致）。test-identity-ledger-schema 由 9/11 升至 **11/11 passed**；compiled-workflow-schema、binding-report-schema、compiled-workflow-validation-hook、binding-report-validation-hook、compile-task-from-envelope 全綠回歸。

- [x] 強化 compiled workflow normalization
  - 交付物：normalizer
  - 驗收：不同來源 workflow 輸出一致 shape
  - 進度：done in `feat/binding-report-validation`；擴充既有 `engine/workflow_loader.py:normalize_workflow_data`，新增 backward-compatible step alias `depends_on → needs`（只在 `needs` 不存在時補；既有 `needs` 永遠勝出，`depends_on` 保留不刪以相容仍讀 legacy 欄位的下游）。**嚴格不補**任何 compiled-workflow schema 必填欄位（`schema_version` / `version` / `triggers` 等），讓 P4 #1 producer contract 不被偷偷掩蓋。`engine/task_scoped_compiler.py` 兩個 compile path（`compile_task` / `compile_task_from_envelope`）翻轉順序為 `build → normalize → ensure_valid_compiled_workflow(post_build) → bind`，alias 在 schema 驗證前完成。新增 `tests/scripts/test-compiled-workflow-normalization.sh` 4 cases / **8 passed / 0 failed**（canonical needs 不變、depends_on→needs、同時存在以 needs 為準、缺 schema_version 仍 fail schema validation），接入 `smoke-per-stage.sh` 為 P4 #4 gate。

- [ ] 實作 project / shared / builtin / legacy source priority
  - 交付物：source resolver
  - 驗收：binding report 明確記錄命中來源
  - 現況：**deferred / blocked**。目前 runtime 只有 project workflow source 有 producer，shared / builtin / legacy 三個 layer 沒有實際 workflow producer 目錄；`source_priority` 字串只在 supervisor schema 與測試 fixture 出現，runtime 不消費。若現在硬做 4-layer resolver 等於蓋空殼且無 consumer 可驗，且 per-step `source_layer / source_path / candidate_sources / selected_reason` 欄位會打開剛 close 的 P4 #2 binding-report schema 與 fixtures。延後到 shared / builtin / legacy workflow producer 真實落地後再實作；屆時應同步審視 binding-report.schema.yaml 是否新增 optional source-tracking 子物件。

- [x] enforce allowed capabilities
  - 交付物：policy check
  - 驗收：憲法未允許的 capability 會 halt
  - 進度：done in `feat/binding-report-validation`；既有 `engine/runtime_binder.py` 已會把 `binding_policy.allowed_capabilities` 不允許的 step 標記為 `resolution_status='blocked_by_constitution'` 並計入 `unresolved_required_steps`（line 88, 140-173），但這只升到 `binding_status='blocked'` 標籤、過去只有 `main.py:105` 軟認帳。本輪新增 `engine/runtime_binder.py:BindingPolicyError` + `ensure_binding_status_executable(binding, *, stage)`，掛在 `engine/task_scoped_compiler.py` 兩個 compile path 的 `ensure_valid_binding_report` 之後、`apply_unresolved_policy` 之前；blocked 時即時 raise，不會進入 `apply_unresolved_policy` 或 `build_bound_execution_phases_from_workflow`。`engine/workflow_cli.py:cmd_compile_json` 接成 `{"ok": false, "error": "binding_policy_error", "stage": "post_bind_policy", "errors": [...]}`，exit 1。

- [x] enforce allowed workflow source roots
  - 交付物：source root policy check
  - 驗收：未允許來源不能被載入
  - 進度：done in `feat/binding-report-validation`；既有 `engine/runtime_binder.py:_assert_workflow_source_allowed` 已會 raise，但用裸 `ValueError`，CLI 會吐 traceback 不可機器解析。本輪新增 `engine/runtime_binder.py:WorkflowSourcePolicyError(stage='workflow_source_policy')`，把 raise 換成這個自訂類別；**檢查邏輯本身不動**（仍保留 synthetic `<...>` source path 短路、`enforce_allowed_source_roots=False` 短路、空 `allowed_source_roots` 短路、real path 落在任一 allowed root 的子樹內視為合法）。`engine/workflow_cli.py:cmd_compile_json` 加第四個 except 分支：`{"ok": false, "error": "workflow_source_policy_error", "stage": "workflow_source_policy", "errors": [...]}`，exit 1。`tests/scripts/test-workflow-policy-gates.sh` Case 5 / Case 6 覆蓋短路 / 合法 / 違規 / CLI 契約。

- [x] enforce fallback policy
  - 交付物：fallback policy check
  - 驗收：strict / preferred / fallback_allowed 與 missing_policy 的行為在 bind / run 前一致套用
  - 進度：done in `feat/binding-report-validation` 為**語意文件化**（Option B），不改 runtime 行為。釐清現行 `binding_mode` 與 `missing_policy` 的真實語意：(1) `binding_mode='strict'`（`engine/runtime_binder.py:DEFAULT_BINDING_MODE` 與 `_get_binding_mode`）= **fallback 搜尋停用**；若 capability 在 skill registry 有 direct / preferred match，仍照常選用，**只是不主動展開 generic-* fallback 候選**；line 212 的 `self._find_fallback(...) if binding_mode == "fallback_allowed" else None` 是唯一決策點。(2) `binding_mode='fallback_allowed'` = **fallback 搜尋開放**，無 direct match 時會嘗試 `generic-*` 備援。(3) `missing_policy` 字串記入 binding report，由下游 `task_scoped_compiler.apply_unresolved_policy` 與 main.py 的 `binding_status` halt 判斷決定 halt / skip / pending；binder 自身不在 bind 階段拒絕。**未做 rename**（`binding_mode` → `fallback_search_mode`）以避免打開 `binding-report.schema.yaml` / 既有 fixture / supervisor envelope 的連動破壞；rename 留給未來真正需要再現 fallback rejection 行為時再做。Option A（actively reject in strict）與 Option C（新增獨立 `fallback_rejection_policy`）皆評估後延後：A 會改變既有 binding 結果造成 regression，C 會重開剛 close 的 P4 #2 schema 與 fixture。本條視為 alignment doc，**不引入新 runtime 行為**。

- [x] 強化 unresolved handling
  - 交付物：error model 與 report
  - 驗收：required unresolved halt，optional unresolved 可降級
  - 進度：done in `feat/binding-report-validation`；與 P4 #6 共用同一條 `binding_status='blocked'` 路徑。required unresolved step 會推升 `binding_status` 至 `blocked`，新 `ensure_binding_status_executable` halt 在 `compile_task` / `compile_task_from_envelope` 內生效。optional unresolved 維持原本「不推升 binding_status，可降級執行」語意：optional unresolved 只進 `unresolved_optional_steps` 計數，`binding_status` 落在 `degraded`（不算 blocked），不被新 hard halt 影響，下游 `apply_unresolved_policy` 仍按原本 `optional_unresolved → action='skip|fallback'` 處理。新 `tests/scripts/test-workflow-policy-gates.sh` Case 3 覆蓋 required-unresolved → halt + 不進入 bound phases。

- [x] 產出 preflight report
  - 交付物：preflight artifact
  - 驗收：run 前能看到 capability、binding、policy、artifact 風險
  - 進度：done in `feat/binding-report-validation`；新增 `schemas/preflight-report.schema.yaml` v1（8 個必填頂層欄位 `schema_version` / `workflow_id` / `binding_status` / `is_executable` / `gates` / `unresolved_summary` / `warnings` / `blocking_reasons`）+ `engine/preflight_report.py:build_preflight_report(compiled_workflow, binding)` builder。`engine/task_scoped_compiler.py` 兩個 compile path 在所有 validation + policy gate 通過後（`ensure_binding_status_executable` 之後、`build_bound_execution_phases_from_workflow` 之後）建立 preflight，回傳 dict 多一個 `preflight_report` key（legacy compile_task 從 7 鍵升 8 鍵；envelope path 從 9 鍵升 10 鍵；對應的 `tests/scripts/test-compile-task-from-envelope.sh` Case 0 / 3 / 6 key 斷言同步更新）。**範圍邊界**：blocked binding 仍由 P4 #6/#9 的 `BindingPolicyError` 在 `apply_unresolved_policy` 前 halt，preflight 不會被建立；`is_executable: true` 與 `blocking_reasons: []` 是現行架構的常態，contract 保留 `false` / non-empty 給未來部分狀態檢視場景。fallback / optional unresolved 只透過 `warnings` 表達，不影響 `is_executable`。新 `tests/scripts/test-preflight-report.sh` 6 cases / **21 passed / 0 failed**（happy path / envelope path / schema 驗證 / optional unresolved warning / fallback skill warning / blocked-deterministic-halt 不漏 preflight）。

- [x] 強化 dry-run inspection
  - 交付物：dry-run inspection output
  - 驗收：dry-run 可顯示 compiled workflow、binding、policy 與 preflight 判定，不執行任何 step
  - 進度：done in `feat/binding-report-validation`；擴充既有 `engine/workflow_cli.py:cmd_print_compiled_dry_run` 加兩個 optional flag `--preflight-json` / `--binding-json`（沒帶 flag 時行為與舊版完全一致，向後相容；帶 flag 時 render `preflight:` 區塊：workflow_id / binding_status / is_executable / 步驟計數 / 4 條 gate 狀態 / warnings / blocking_reasons，再 render `binding_steps:` 區塊：每個 step 的 capability / selected_provider / selected_skill_id / resolution_status）。`scripts/cap-workflow.sh:run-task --dry-run` 從 `compile_task` 結果再抽 `preflight_report` JSON 並 pass 兩個新 flag 給 renderer。**Dry-run 路徑保持 print-only**：shell 在 print 後直接 `exit 0`，不會進入 binding-status 後續分支或呼叫任何 executor，新 `tests/scripts/test-workflow-dry-run-inspection.sh` Case 4 透過 sandbox 目錄前後檔案計數證實 renderer 不寫入任何 artifact。test 4 cases / **17 passed / 0 failed**（backward-compat 無新 flag / 帶 preflight 渲染 / 帶 binding step detail / print-only 無副作用）。

## P5：AgentSessionRunner

> **Baseline 現況（盤點於 `feat(preflight)` / `feat(workflow)` rc6 closeout 後）**：本段並非從零開工。既有設施：
> - `schemas/agent-session.schema.yaml` v1（18 必填頂層欄位 + lifecycle enum 7 值：`planned / running / completed / failed / blocked / cancelled / recycled`）已落地。
> - `engine/step_runtime.py:upsert_session`（line 645-746）負責寫入 `~/.cap/projects/<id>/reports/workflows/<workflow_id>/<run_label>/agent-sessions.json`，session_id / run_id / workflow_id / step_id / capability / role / provider / provider_cli / executor / lifecycle / inputs / outputs / scratch_paths / started_at / completed_at / failure_reason / duration_seconds 等欄位皆已寫入。
> - **Production executor 在 shell**：`scripts/cap-workflow-exec.sh:1000-1150` 是目前唯一的 step execution 主迴圈（build prompt → spawn provider CLI → capture output → 呼叫 `step_runtime upsert-session`）。`run_step_claude` / `run_step_codex` / `run_shell_step` 為三條 provider dispatch 分支；timeout / stall enforce 也在 shell loop（line 1044 / 1049）。
> - `engine/project_context_loader` / `project_constitution_runner` 內亦有少量 Python 端的 subprocess 呼叫 provider CLI（如 `runner.py:757`），與 shell executor 形成兩條並存的 dispatch 路徑。
>
> **本批（rc6 後 P5 #0-#3）scope 紅線**：
> 1. **不重構** `scripts/cap-workflow-exec.sh`：現行 production execution path 不動，避免打壞 provider dispatch / timeout / stall / temp file / background process 等已能跑的 shell 行為。
> 2. **新增 Python additive layer**：`engine/provider_adapter.py` + `engine/agent_session_runner.py` 作為「未來可程式化呼叫的 deterministic runner」，不取代 shell executor。
> 3. **ShellAdapter 為 Python 端對齊版**：與 shell 的 `run_shell_step` 行為對齊（`subprocess.run` 包裝），目的是測試與未來 migration 用，不替換 shell 路徑。
> 4. **本批不接** Codex / Claude adapter、不做 prompt snapshot / hash、不做 parent / child session relation 寫入、不做 `cap session inspect` CLI。這些屬後續批次。
> 5. **寫 ledger 重用 `step_runtime.upsert_session`**：直接 import 呼叫 Python 函式，不重做 schema 寫入規則。
>
> 換句話說，shell 是 production runner、Python AgentSessionRunner 是 future programmable execution layer，兩者並存且邊界清楚。

- [x] 定義 `ProviderAdapter` interface
  - 交付物：provider adapter contract
  - 驗收：Codex / Claude / Shell 可共用同一 runner 介面
  - 進度：done in `feat/agent-session-baseline`（commit pending push）；新增 `engine/provider_adapter.py` 定義 `ProviderRequest`（session_id / step_id / prompt / timeout_seconds / env / metadata）、`ProviderResult`（status / exit_code / stdout / stderr / duration_seconds / provider_session_id / artifacts / failure_reason）兩個 immutable dataclass，4 個 status 字串常數（`completed` / `failed` / `timeout` / `cancelled`），抽象基底 `ProviderAdapter` 與兩個內建子類 `FakeAdapter`（test 用 deterministic adapter，可吃固定 result 或 callable）/ `ShellAdapter`（subprocess.run 包裝，timeout 走 TimeoutExpired 收斂為 status=timeout 不 raise）。本批刻意**不**接 Codex / Claude，留待後續 P5 cycle；production 仍由 `scripts/cap-workflow-exec.sh` 負責，contract 的價值在於提供 future migration target 與 deterministic test surface。

- [x] 實作 `AgentSessionRunner`
  - 交付物：runner module
  - 驗收：workflow step 不直接綁 provider CLI 細節
  - 進度：done in `feat/agent-session-baseline`（commit pending push）；新增 `engine/agent_session_runner.py:AgentSessionRunner` programmable Python 執行層，提供 `run_step(adapter, request, context) -> RunStepOutcome`：(1) 自動產生 session_id（沒帶就 `sess_<uuid12>`）、(2) 先 upsert 一筆 `lifecycle=running / result=pending` 的 ledger 入口供觀察者看到 in-flight session、(3) 呼叫 adapter，捕捉 adapter 內部例外並轉成 `lifecycle=failed` ledger 紀錄、(4) 把 `ProviderResult.status` 對應到 schema lifecycle enum（`completed→completed`、`failed→failed`、`timeout→failed`、`cancelled→cancelled`）並寫入 terminal ledger entry、(5) 回傳 `RunStepOutcome(session_id, result, lifecycle, failure_reason)` 給呼叫方。**Ledger 寫入 100% 重用** `engine.step_runtime.upsert_session`（直接 import 呼叫），不重做 schema 寫入規則。`SessionContext` dataclass 對齊 upsert_session 的位置參數，呼叫端只需提供工作流上下文。runner 跨呼叫 stateless，可重用同一 instance 服務並行 context。


- [ ] 實作 `CodexAdapter`
  - 交付物：Codex provider adapter
  - 驗收：可捕捉 provider-native session id、stdout、stderr、exit code

- [ ] 實作 `ClaudeAdapter`
  - 交付物：Claude provider adapter
  - 驗收：可捕捉 provider-native session id、stdout、stderr、exit code

- [x] 實作 `ShellAdapter`
  - 交付物：Shell provider adapter
  - 驗收：shell step 與 AI step 同樣進 session ledger
  - 進度：done in `feat/agent-session-baseline`（commit pending push）；`engine/provider_adapter.py:ShellAdapter` 透過 `subprocess.run(["/bin/bash","-c", prompt], capture_output=True, text=True, timeout=...)` 執行；exit_code=0 → `status=completed`，非零 → `status=failed` + `failure_reason='shell command exited <N>'`，`subprocess.TimeoutExpired` → `status=timeout / exit_code=-1 / failure_reason='shell command timed out after <N>s'`。`request.env` 若提供會 merge 到 `os.environ` 之上（不覆蓋整個環境，避免丟失 PATH 等）。透過 `AgentSessionRunner` 與 ShellAdapter 配合，shell step 與 AI step 走同一條 ledger 寫入路徑（`step_runtime.upsert_session`），對 ledger 而言 provider_cli 欄位填 `shell` 即可區分。本批刻意是 **thin wrapper**：不複製 `scripts/cap-workflow-exec.sh:run_shell_step` 的 signal handling / background process / stall watchdog / progress streaming；那些仍由 production shell executor 負責，本 adapter 只服務 deterministic test 與未來 migration contract。新 `tests/scripts/test-agent-session-runner.sh` 10 cases / **35 passed / 0 failed** 涵蓋 FakeAdapter / ShellAdapter happy / fail / stdio capture / timeout / runner ledger / lifecycle mapping / idempotent upsert，接入 `smoke-per-stage.sh` 為 P5 #1-#3 baseline gate。

- [x] 補 prompt snapshot / prompt hash
  - 交付物：session metadata
  - 驗收：每個 session 可回溯實際 prompt
  - 進度：done in `feat(agent-session): store content-addressed prompt snapshots`；`schemas/agent-session.schema.yaml` 加 3 個 optional 欄位 `prompt_hash`（SHA-256 hex）/ `prompt_snapshot_path`（落地路徑）/ `prompt_size_bytes`（UTF-8 byte size）。新增 `engine/agent_session_runner.py:_write_prompt_snapshot` 把 rendered prompt 寫到 `<sessions_dir>/prompts/<sha256[:2]>/<sha256>.txt` content-addressable layout，**多 session 共用同 prompt 內容會自動 dedupe 同一檔**（idempotent，target 已存在不覆寫）；`AgentSessionRunner.run_step` 在第一次 `running` upsert 與後續 terminal upsert 都帶上 snapshot metadata。`engine/step_runtime.py:upsert_session` 加 keyword-only `prompt_hash` / `prompt_snapshot_path` / `prompt_size_bytes` 三參數（皆 optional，向後相容既有 16-positional shell caller，預設 None 時不寫入欄位）。`tests/scripts/test-agent-session-runner.sh` 新增 Case 11/12/13（snapshot 內容驗證 / dedupe / 欄位 type 驗證），擴至 13 cases / **49 passed**。Note：full ledger schema validation 仍因預先存在的 `nullable: true` （OpenAPI 風格、非 JSON-Schema 標準）受到 fallback validator 限制，本批不修；屬獨立 schema hardening 課題。

- [ ] 補 parent / child session relation
  - 交付物：session graph 欄位
  - 驗收：可追蹤 supervisor 與 downstream agent 關係

- [ ] 補 session lifecycle
  - 交付物：created / running / completed / failed / cancelled / recycled 狀態轉移
  - 驗收：workflow 結束後 session 狀態完整閉合

- [ ] 整合 timeout / stall handling
  - 交付物：timeout policy
  - 驗收：卡住的 provider session 不會無限等待

- [ ] 新增 `cap session inspect`
  - 交付物：CLI command
  - 驗收：可查單一 session prompt、status、artifacts、logs

## P6：Artifact, Handoff and Validation

- [ ] 實作 artifact registry
  - 交付物：artifact metadata registry
  - 驗收：每個 artifact 有 name、path、producer、schema、status

- [ ] 實作 artifact lineage
  - 交付物：artifact dependency graph
  - 驗收：可追蹤 artifact 由哪個 step / session 產生

- [ ] 實作 handoff schema validator
  - 交付物：handoff validation hook
  - 驗收：不合法 handoff 不會交給下游

- [ ] 實作 required output check
  - 交付物：output expectation checker
  - 驗收：缺必交付 artifact 時 step failed

- [ ] 實作 JSON extraction / validation
  - 交付物：通用 extraction helper
  - 驗收：AI 輸出的 JSON artifact 能穩定解析與驗證

- [ ] 實作 Markdown required section validation
  - 交付物：Markdown validator
  - 驗收：缺必要章節的 report / handoff 會 fail

- [ ] 實作 capability-specific validators
  - 交付物：validator registry
  - 驗收：不同 capability 可指定專屬驗收規則

- [ ] 實作 route_back_to handling
  - 交付物：route back runtime behavior
  - 驗收：failed gate 可自動回流到指定 step

## P7：Result Report and Run Archive

- [ ] 實作 result report builder
  - 交付物：report builder module
  - 驗收：`result.md` 由結構化 runtime state 產生

- [ ] `result.md` 彙整 constitution、compiled workflow、binding、sessions、artifacts、failures
  - 交付物：完整 result report
  - 驗收：單檔可讀懂 run 結果與失敗原因

- [ ] 明確區分 `runtime-state.json` 與人類可讀 result report
  - 交付物：欄位職責文件與實作
  - 驗收：machine state 不混入敘事，人類報告不作為唯一資料源

- [ ] 補 failure summary
  - 交付物：failure summary section
  - 驗收：包含 failed step、reason、route_back_to、logs pointer

- [ ] 補 promote candidates
  - 交付物：promote candidates section
  - 驗收：標出可回寫 repo 的產物

- [ ] 補 final archive 規則
  - 交付物：Logger handoff / archive policy
  - 驗收：Logger 可接手整理結案摘要

- [ ] 新增 `cap workflow inspect <run-id>`
  - 交付物：CLI command
  - 驗收：可讀取 result、sessions、artifacts、logs pointer

## P8：Governance Gates

- [ ] 實作 watcher checkpoint runner
  - 交付物：watcher gate runtime
  - 驗收：milestone gate 可自動執行

- [ ] 實作 security checkpoint runner
  - 交付物：security gate runtime
  - 驗收：高風險變更可觸發 security review

- [ ] 實作 qa checkpoint runner
  - 交付物：qa gate runtime
  - 驗收：QA gate 可阻擋未驗證輸出

- [ ] 實作 logger milestone runner
  - 交付物：logger archive runtime
  - 驗收：結案摘要可自動生成或派工

- [ ] 實作 gate result validation
  - 交付物：套用 `schemas/gate-result.schema.yaml`
  - 驗收：gate output 可被機器驗證

- [ ] 實作 fail route handling
  - 交付物：failure routing runtime
  - 驗收：gate fail 能 halt 或 route back

- [ ] 支援 rerun failed gate
  - 交付物：CLI 或 runtime control
  - 驗收：可只重跑失敗 gate

- [ ] enforce halt-on-risk
  - 交付物：risk policy enforcement
  - 驗收：高風險未通過 gate 不會繼續執行

## P9：Repo-specific Source Resolver

- [ ] 執行 skills method intake（不阻塞 P0-P10 主線）
  - 交付物：將 `/Users/charlie010583/Desktop/01_private/98_other_skills/skills` 中高價值工程方法改寫為 CAP strategies，而不是直接導入 Claude plugin / slash-command runtime
  - 初始 strategy 清單：
    - `agent-skills/strategies/diagnose-loop.md`
    - `agent-skills/strategies/tdd-vertical-slice.md`
    - `agent-skills/strategies/shared-language-and-adr.md`
    - `agent-skills/strategies/architecture-deepening.md`
    - `agent-skills/strategies/vertical-slice-planning.md`
  - 驗收：現有 agent prompt 明確掛載這些 strategy（troubleshoot / QA / frontend / backend / supervisor / techlead / watcher），且不新增第二套 skill resolver
  - 延後：Codex / Claude 原生 `SKILL.md` export、mapper 擴充、plugin / marketplace 安裝流程留到 builtin / project / shared source resolver 完成後再做

- [ ] 支援 repo-local workflow source roots
  - 交付物：workflow resolver
  - 驗收：project workflow 可覆蓋或擴充 builtin workflow

- [ ] 支援 repo-local skill registry
  - 交付物：skill resolver
  - 驗收：project skill 可被 binding pipeline 使用

- [ ] 明確區分 builtin / project / shared skill source
  - 交付物：source metadata
  - 驗收：binding report 顯示每個 skill 的來源

- [ ] 套用 Project Constitution allowed source roots
  - 交付物：source root enforcement
  - 驗收：未允許來源不會被載入

## P10：Detached Runtime and Promote / Publish

- [ ] 實作 detached / background workflow run
  - 交付物：background run mode
  - 驗收：run 可脫離 foreground 並持續寫入 status

- [ ] 實作 run status polling
  - 交付物：CLI command 或 status endpoint
  - 驗收：可查 detached run 狀態與最近 log

- [ ] 實作 promote candidate selection
  - 交付物：candidate selector
  - 驗收：只允許 validated artifact 進 promote 流程

- [ ] 實作 promote dry-run
  - 交付物：dry-run diff
  - 驗收：可預覽會寫回 repo 的檔案

- [ ] 實作 promote apply
  - 交付物：apply command
  - 驗收：寫回 repo 前保留 audit trail

- [ ] 實作 publish workflow
  - 交付物：publish command 或 workflow
  - 驗收：可把 validated workflow / skill / schema 發布到指定 registry 或 shared source

## 建議執行順序

> **排序原則（v0.21.6 closeout 後）**：先做短鏈低風險的治理債清理（P0a），讓 schema 失敗訊號乾淨；再用 fresh provider e2e 驗證 v0.21.5 三件 fix（`1425fa9` / `55038dd` / `2492913`）在 Claude + Codex fresh run 無 regression，建立 v0.22.0 的乾淨基線；最後才開 P0 主體。基線未確認前不開 P0，避免 P0 做到一半時 provider drift 與新 schema 問題互相干擾、難以歸因。**v0.21.6 baseline 已確認，下一步即 P0**。

1. ✓ ~~**P0a Schema-Class Executors Exit Code 政策**~~ done in `v0.21.6`（`5b31856` / `44011ad`；6 個 executor 對齊 exit 41，policy SSOT 升級，smoke-per-stage 15/15）
2. ✓ ~~**Fresh Claude + Codex provider parity full run**~~ done in `v0.21.6`（Claude `run_20260501192422_033a65f8` 與 Codex `run_20260501234931_27dddbce` 各 16/16 / 43 PASS / 0 FAIL）
3. ✓ ~~**P0 Runtime Contracts**~~ done in `v0.22.0-rc1`（6 個 schema 共 47 fixture cases，smoke 21/21）
4. **P1 Project Storage and Identity** ← **done in v0.22.0**（#1 strict-mode resolver + #2 identity ledger collision + #3 storage version metadata + #4 storage health check core + #5 `cap project status` + #6 `cap project init` + #7 `cap project doctor` 全部落地；smoke 27/27 全綠）
5. P2 Project Constitution Runner
6. P3 Supervisor Structured Orchestration
7. P4 Compiled Workflow and Binding Pipeline
8. P5 AgentSessionRunner
9. P6 Artifact, Handoff and Validation
10. P8 Governance Gates
11. P7 Result Report and Run Archive
12. P9 Repo-specific Source Resolver
13. P10 Detached Runtime and Promote / Publish

## Release Gate

- [ ] 所有新增 schema 都有 positive / negative fixture
- [ ] `scripts/workflows/smoke-per-stage.sh` 通過
- [ ] 至少一條 deterministic e2e 覆蓋 Project Constitution snapshot
- [ ] 至少一條 deterministic e2e 覆蓋 Supervisor structured orchestration
- [ ] 至少一條 deterministic e2e 覆蓋 AgentSessionRunner lifecycle
- [ ] provider parity checker 可驗證最新 run artifact
- [x] fresh Claude + Codex provider parity full run 在 v0.21.5 修補（`1425fa9` / `55038dd` / `2492913`）後重跑無 regression（同建議執行順序步驟 2）—— done in `v0.21.6`：Claude `run_20260501192422_033a65f8`（duration 1363s / 16/16 / parity 43 PASS / 0 FAIL）、Codex `run_20260501234931_27dddbce`（duration 1346s / 16/16 / parity 43 PASS / 0 FAIL），跨 provider duration 差 17s，無 provider-specific regression。runbook：`docs/cap/PROVIDER-PARITY-FRESH-E2E-V0.21.5.md`。
- [ ] README / TODOLIST / IMPLEMENTATION-ROADMAP 連結到本清單
