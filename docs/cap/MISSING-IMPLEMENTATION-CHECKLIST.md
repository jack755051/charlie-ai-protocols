# CAP Missing Implementation Checklist

更新日期：2026-05-02（v0.21.6 closeout 後）

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

- [ ] 定義 `schemas/binding-report.schema.yaml`
  - 交付物：binding report JSON Schema
  - 驗收：schema 可驗證 resolved / unresolved / fallback / provider_cli / source_priority

- [ ] 定義 `schemas/supervisor-orchestration.schema.yaml`
  - 交付物：Supervisor structured output JSON Schema
  - 驗收：schema 覆蓋 task_constitution / capability_graph / governance / compile_hints

- [ ] 定義 `schemas/workflow-result.schema.yaml`
  - 交付物：workflow result JSON Schema
  - 驗收：schema 可驗證 run status、step results、artifacts、failures、promote candidates

- [ ] 定義 `schemas/gate-result.schema.yaml`
  - 交付物：governance gate result JSON Schema
  - 驗收：schema 可驗證 gate type、checkpoint、pass/fail、risk、route_back_to

- [ ] 新增 schema parse / validation smoke tests
  - 交付物：集中測試入口或納入 `scripts/workflows/smoke-per-stage.sh`
  - 驗收：所有新增 schema 有 positive / negative fixture
  - 進度：partial in `v0.21.5` (`2492913`) + `v0.22.0` (in-progress, P0 #1–#2)；`provider-parity-check.sh` §4.2 已拆分 nonempty vs present-only 驗證語意；capability-graph schema 配 8 cases inline-fixture smoke test、compiled-workflow schema 配 9 cases，皆進 `smoke-per-stage.sh`（17/17）。仍缺 binding-report / supervisor-orchestration / workflow-result / gate-result 4 個 schema 的 positive / negative fixture。本項在 P0 全部 6 個 schema 落地後可結案。

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

- [ ] 支援非 git folder 的 project id 策略
  - 交付物：project id resolver fallback
  - 驗收：無 git repo 時仍能產生穩定 project id
  - 進度：foundation in `v0.21.5` (`1425fa9`)；task project identity 已對齊 cap-paths runtime resolver，建立 project id SSOT 前置條件。仍缺非 git folder fallback 實作與測試。

- [ ] 處理 project id collision
  - 交付物：collision detection 與 disambiguation 規則
  - 驗收：同名資料夾不會共用同一個 `~/.cap/projects/<project_id>/`
  - 進度：foundation in `v0.21.5` (`1425fa9`)；cap-paths 作為 identity SSOT 可支撐後續 collision detection。仍缺 collision 偵測、命名策略與 migration 行為。

- [ ] 記錄 storage version / migration metadata
  - 交付物：project storage metadata file
  - 驗收：`cap paths` 或 project status 可讀出 version / created_at / migrated_at

- [ ] 實作 storage health check
  - 交付物：health check routine
  - 驗收：可偵測缺目錄、壞 metadata、不可寫 storage

- [ ] 新增 `cap project status`
  - 交付物：CLI command
  - 驗收：顯示 project id、storage path、constitution status、latest run

- [ ] 新增 `cap project init`
  - 交付物：CLI command
  - 驗收：可初始化 `.cap.project.yaml` 與 local storage

- [ ] 新增 `cap project doctor`
  - 交付物：CLI command
  - 驗收：可輸出修復建議與 exit code

## P2：Project Constitution Runner

- [ ] 拆清 Project Constitution 與 Task Constitution 語意
  - 交付物：CLI / docs / workflow naming 調整
  - 驗收：`constitution / compile / run-task / run` 差異清楚可查

- [ ] 調整 `schemas/workflows/project-constitution.yaml` 輸出契約
  - 交付物：workflow output contract
  - 驗收：明確產出 Markdown 與 JSON artifact

- [ ] 實作 Project Constitution validator
  - 交付物：validator command 或 `engine/step_runtime.py` subcommand
  - 驗收：通過 `schemas/project-constitution.schema.yaml` 才能 promote

- [ ] 實作 agent output JSON extraction
  - 交付物：Markdown / fenced JSON extraction routine
  - 驗收：可處理純 JSON、fenced JSON、Markdown 中嵌 JSON
  - 進度：partial in `v0.21.5` (`55038dd`)；`persist-task-constitution.sh` 已處理 `<<<TASK_CONSTITUTION_JSON_BEGIN>>>` fence 內再包一層 ```json nested fence 的 case。仍缺 Project Constitution runner 使用的通用 extraction routine，並需覆蓋純 JSON、一般 fenced JSON、Markdown 中嵌 JSON。

- [ ] 實作 Project Constitution snapshot storage
  - 交付物：`~/.cap/projects/<project_id>/constitutions/project/<stamp>/`
  - 驗收：保存 `.md`、`.json`、`validation.json`、`source-prompt.txt`

- [ ] 實作 constitution snapshot versioning
  - 交付物：snapshot index 或 metadata
  - 驗收：可列出、比對、回溯不同版本

- [ ] 新增 `cap project constitution "<prompt>"`
  - 交付物：CLI command
  - 驗收：能跑 project constitution workflow 並保存 snapshot

- [ ] 新增 `cap project constitution --dry-run`
  - 交付物：dry-run mode
  - 驗收：產生 draft 與 validation，不寫回 repo

- [ ] 新增 `cap project constitution --from-file`
  - 交付物：file input mode
  - 驗收：可從指定 prompt / draft 檔案產生 snapshot

- [ ] 新增 `cap project constitution --promote`
  - 交付物：promote mode
  - 驗收：只有 valid snapshot 可寫回 `.cap.constitution.yaml` 或指定目標

## P3：Supervisor Structured Orchestration

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
3. **P0 Runtime Contracts** ← **next**（v0.22.0 主軸，7 個 schema；牽動後續 P2/P3/P4/P7/P8，現在基線已乾淨可啟動）
4. P1 Project Storage and Identity
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
