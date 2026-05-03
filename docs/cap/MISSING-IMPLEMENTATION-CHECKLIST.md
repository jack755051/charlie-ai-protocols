# CAP Missing Implementation Checklist

更新日期：2026-05-02（v0.22.0 P1 #1 + #2 + #3 closeout 後）

本清單承接 `TODOLIST.md` 與 `docs/cap/IMPLEMENTATION-ROADMAP.md` 的「尚未完成」項目，整理成可執行的工程工作清單。原則是先補 runtime contract 與 validator，再補 runner、orchestration、session、gate 與 promote/publish 閉環。

> **v0.21.6 baseline**：本清單以 `v0.21.6` tag 為起點。R3（雙 project_id 解析）由 v0.21.5 `1425fa9` 收斂；nested task constitution JSON fence 由 v0.21.5 `55038dd` 處理；`non_goals=[]` 於 parity-check §4.2 拆 nonempty vs present-only 後合法（v0.21.5 `2492913`）；v0.21.6 完成 P0a 6 個 schema-class executor exit 41 對齊與 fresh provider parity baseline 驗證（Claude / Codex 各 16/16 / 43 PASS / 0 FAIL）。詳見 `docs/cap/RELEASE-NOTES.md`、`docs/cap/PROVIDER-PARITY-FRESH-E2E-V0.21.5.md` 與 `docs/cap/PROVIDER-PARITY-FINDINGS-v0.21.2.md`。

進度標記規則：

- `partial`：已有局部 case 或輔助工具落地，但尚未滿足該項完整驗收。
- `foundation`：已補上前置基礎，後續仍需完成主要功能。
- 未標記者視為尚未開始或目前文件中沒有可對齊的落地證據。

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

## P4：Compiled Workflow and Binding Pipeline

- [ ] 實作 compiled workflow schema validation
  - 交付物：validation hook
  - 驗收：invalid compiled workflow 不會進入 bind / run

- [ ] 實作 binding report schema validation
  - 交付物：validation hook
  - 驗收：binding report 可被機器驗證

- [ ] 強化 compiled workflow normalization
  - 交付物：normalizer
  - 驗收：不同來源 workflow 輸出一致 shape

- [ ] 實作 project / shared / builtin / legacy source priority
  - 交付物：source resolver
  - 驗收：binding report 明確記錄命中來源

- [ ] enforce allowed capabilities
  - 交付物：policy check
  - 驗收：憲法未允許的 capability 會 halt

- [ ] enforce allowed workflow source roots
  - 交付物：source root policy check
  - 驗收：未允許來源不能被載入

- [ ] 強化 unresolved handling
  - 交付物：error model 與 report
  - 驗收：required unresolved halt，optional unresolved 可降級

- [ ] 產出 preflight report
  - 交付物：preflight artifact
  - 驗收：run 前能看到 capability、binding、policy、artifact 風險

## P5：AgentSessionRunner

- [ ] 定義 `ProviderAdapter` interface
  - 交付物：provider adapter contract
  - 驗收：Codex / Claude / Shell 可共用同一 runner 介面

- [ ] 實作 `AgentSessionRunner`
  - 交付物：runner module
  - 驗收：workflow step 不直接綁 provider CLI 細節

- [ ] 實作 `CodexAdapter`
  - 交付物：Codex provider adapter
  - 驗收：可捕捉 provider-native session id、stdout、stderr、exit code

- [ ] 實作 `ClaudeAdapter`
  - 交付物：Claude provider adapter
  - 驗收：可捕捉 provider-native session id、stdout、stderr、exit code

- [ ] 實作 `ShellAdapter`
  - 交付物：Shell provider adapter
  - 驗收：shell step 與 AI step 同樣進 session ledger

- [ ] 補 prompt snapshot / prompt hash
  - 交付物：session metadata
  - 驗收：每個 session 可回溯實際 prompt

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
