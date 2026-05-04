# Changelog

All notable changes to this project will be documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/). Commit types follow [Conventional Commits](https://www.conventionalcommits.org/) as defined in `policies/git-workflow.md`.

---

## [v0.22.0-rc9] - 2026-05-04

> Release candidate — collect 4 observability commits since v0.22.0-rc8 into a clean checkpoint covering docs index + session cost analyzer + production-shell prompt snapshot wiring + workflow-exec failure detail wiring. **Untouched**: workflow / supervisor / dispatch behaviour. All metadata + docs + analysis surfaces; no execution semantics change. Smoke升至 48 step / 48 passed / 0 failed.

### Added

- **docs/cap/README.md docs index** (`52a1c65`)：5 段索引（入口導覽 / boundaries / reference / quality reports / 新增規則）讓讀者依需求查文件，避免每次掃整個 `docs/cap/`。`ARCHITECTURE.md` 開頭加 navigation banner 點向 README / CHECKLIST / boundaries memos。**未搬檔、未刪文件**，第一輪 conservative consolidation。
- **`engine/session_cost_analyzer.py` + `cap session analyze`** (`1c65da9`)：read-only token / time analyzer。`cap session analyze [--top N] [--json] [--run-id <id>] [--workflow-id <id>] [--sessions-path <path>]`。報告欄位：total_sessions / total_duration_seconds / lifecycle_counts / by_provider[] / by_capability[] / largest_prompts[] (top N by size) / duplicate_prompts[] (hash 重複 ≥2，cache 候選) / longest_sessions[] / failures{ total, timeout (P5 #9 prefix 子集), by_capability }。`scripts/cap-session.sh` 加 `analyze` 分流，`scripts/cap-entry.sh` 加 help 行。`tests/scripts/test-cap-session-analyze.sh` 11 cases / 43 passed。
- **shell executor prompt snapshot wiring** (`d5de760`)：把 P5 #6 prompt snapshot contract 從 Python additive layer 擴到 production shell executor。新 helper `write_prompt_snapshot()` 計算 SHA-256 寫 content-addressed snapshot 到 `<WORKFLOW_OUTPUT_DIR>/prompts/<sha256[:2]>/<sha256>.txt`（與 Python 端 `_write_prompt_snapshot` 共用同 layout）。`register_agent_session()` 加 3 個 optional 位置參數，兩個 upsert 呼叫點都帶上。`engine/step_runtime.py:upsert-session` CLI 加 `--prompt-hash` / `--prompt-snapshot-path` / `--prompt-size-bytes` 三個 optional flags。**驗證**：`cap workflow run workflow-smoke-test` 後 `cap session analyze` 立即看到 `largest_prompts` 不再為空（commit_changes 2929B、normalize_repo 2360B）。`tests/scripts/test-shell-prompt-snapshot.sh` 8 cases / 21 passed。
- **workflow.log + ledger failure detail extraction** (`6999594`)：新 helper `extract_step_failure_detail(artifact_path)` 解析 shell executor 透過 `fail_with()` emit 的 `reason:` / `detail:` 行，回傳 `reason=<reason>;detail=<d1>|<d2>` 緊湊格式。Wire 進 `artifact_reported_failure` + catch-all classified-error 兩個 log 寫入點 + terminal `register_agent_session` 的 `SESSION_FAILURE_REASON` build。對 4 件 token-monitor 歷史 failure（1 件 `PARSE_ERROR:Extra data` + 3 件 `MISSING_REQUIRED` 變體）全部成功抽取，未來新 failure 走過此 wiring 後 `cap session inspect` `failure_reason` 直接就是「failed: reason=validation_failed;detail=MISSING_REQUIRED:goal,success_criteria」而非僅「failed」。Pre-artifact 失敗路徑（write_failed / TIMEOUT / STALL / output_validation_failed）刻意不動。`tests/scripts/test-step-failure-detail.sh` 6 cases / 6 passed。

### Notes

- **未動執行行為**：所有 4 顆 commit 均為 metadata + 文件 + 分析工具；prompt 內容 / provider dispatch / timeout / stall / schema validation 邏輯完全不變。
- **未做** P5 #9 stall handling（仍 deferred 待 streaming adapter consumer 出現）。
- **未做** task_constitution_persistence failure 的修復（#3 repair hint / #4 JSON-after-JSON strip / #5 supervisor self-check）；本輪只做 failure logging 收緊，這些行為改動等新 failure 數據累積後再決定。
- **第一輪收斂效果**：(a) 文件入口統一、root README 53% slim；(b) token/time hotspot 立刻可觀測；(c) production run 補齊 prompt metadata，cache 候選分析有資料；(d) failure 不再被 generic tag 污染。
- 本 tag 為 release candidate，仍未取代 `v0.22.0` 正式版。是「P5 + observability 收斂完整 / P6 Artifact, Handoff and Validation 可開工」的乾淨基線。

### Verified

- `scripts/workflows/smoke-per-stage.sh` 從 v0.22.0-rc8 baseline 45 step 升至 **48 step / 48 passed / 0 failed / 0 skipped**：新增 `cap session analyze (token/time)` + `shell executor prompt snapshot wiring` + `step failure detail extractor` 三個 gate。
- 跨 hook test 全綠：cap-session-analyze 43/43、shell-prompt-snapshot 21/21、step-failure-detail 6/6、agent-session-runner 75/75、cap-session-inspect 32/32、provider-adapters 44/44、preflight-report 21/21、workflow-policy-gates 19/19、compiled-workflow-validation-hook 16/16、binding-report-validation-hook 15/15、compile-task-from-envelope 33/33。
- **End-to-end real-data 驗證**：跑 `cap workflow run workflow-smoke-test` production workflow 後，新 session 完整寫入 `prompt_hash` (64-char sha256) + `prompt_snapshot_path` (matches `<run_dir>/prompts/<hash[:2]>/<hash>.txt`) + `prompt_size_bytes` (與 disk file size 一致)；`cap session analyze --top 10` 立即顯示 largest_prompts hot list。

## [v0.22.0-rc8] - 2026-05-04

> Release candidate — close P5「AgentSessionRunner」整段除 #9 stall handling deferred 外的最後三條（#10 cap session inspect + #3 CodexAdapter + #4 ClaudeAdapter）。本 tag 不取代 `v0.22.0` 正式版；**未動** `scripts/cap-workflow-exec.sh` production executor，所有新 adapter / inspector 都是 additive Python layer。stall handling 待真有 streaming provider adapter consumer 時再做（目前 Codex / Claude / Shell adapter 都是 blocking subprocess.run）。

### Added

- **P5 #10 cap session inspect** (`19a7603`)：新增 `engine/session_inspector.py`（read-only），公開 `find_sessions(...)` / `render_session_text(...)` 兩個 helper 與 argparse-driven `main()`。CLI surface：`cap session inspect <session_id> [--json] [--sessions-path <path>]`，亦支援 `--run-id` / `--workflow-id` / `--step-id` 三種 filter；missing session 走 deterministic JSON error `{"ok": false, "error": "session_not_found", ...}` exit 1。Default scan walks `<CAP_HOME or ~/.cap>/projects/*/reports/workflows/*/*/agent-sessions.json`。**顯示欄位完整**：lifecycle / result / step / run / workflow / capability / provider (cli=...) / executor / duration / exit_code / parent_session_id / root_session_id / spawn_reason / prompt_hash / prompt_snapshot_path / prompt_size_bytes / outputs / failure_reason / source ledger trailer。`scripts/cap-session.sh` 加 `inspect` 分流，`scripts/cap-entry.sh` 加 `cap session ...` route + help。`tests/scripts/test-cap-session-inspect.sh` 9 cases / 32 passed。
- **P5 #3 CodexAdapter** (`6e5b9f6`)：新增 `engine.provider_adapter.CodexAdapter` 鏡射 `scripts/cap-workflow-exec.sh:run_step_codex` 語意：呼叫 `codex exec [--skip-git-repo-check] <prompt>`，stdout 走新 helper `_strip_codex_preamble`（Python 重寫 awk line-for-line：取最後一段 `assistant`/`codex` marker 之後內容，無 marker fallback raw stdout）。stderr 獨立捕捉。新 helper `_resolve_provider_binary("codex", "CAP_CODEX_BIN")`：env override → PATH lookup → 缺 binary 不 raise 回 deterministic failed result。`subprocess.FileNotFoundError` / `PermissionError` / `TimeoutExpired` 全部收斂為 `ProviderResult`，timeout 對齊 P5 #9 prefix。Constructor `skip_git_repo_check=True` 預設 on。`provider_session_id` 暫無（Codex CLI 未暴露穩定 native session id）。
- **P5 #4 ClaudeAdapter** (`e081da6`)：新增 `engine.provider_adapter.ClaudeAdapter` 鏡射 `scripts/cap-workflow-exec.sh:run_step_claude` 語意：呼叫 `claude -p <prompt>`，stdout / stderr 獨立捕捉。**無 preamble strip**：Claude `-p` 模式直接吐 assistant 回覆，不帶 banner / transcript（與 Codex 不同）。Binary resolution 重用 P5 #3 的 `_resolve_provider_binary("claude", "CAP_CLAUDE_BIN")`；缺 binary / FileNotFoundError / PermissionError / timeout 全部與 CodexAdapter 對齊（同一套 contract）。`tests/scripts/test-provider-adapters.sh` 共 15 cases / 44 passed（Codex 25 + Claude 19），全部用 fake bash binary 驅動。

### Notes

- **P5 整段範圍**：#1/#2/#3/#4/#5/#6/#7/#8/#9/#10 共 10 條完成；P5 #9 stall handling 維持 deferred 待 streaming provider adapter 真有 consumer 時再做（目前 Codex / Claude / Shell adapter 都是 blocking subprocess.run）。
- **未動 production executor**：`scripts/cap-workflow-exec.sh` 從 P5 baseline 起未被動到，仍是 production step execution path。所有新 Python adapter / runner / inspector 都是 additive layer，contract 對齊但不取代。
- **Provider-native session id 暫無**：Codex / Claude CLI 都未在 stdout 暴露穩定 native session id，`provider_session_id` 欄位維持 `None`，等真有需要再接（會是後續 P5 / P7 cycle 的事）。
- 本 tag 為 release candidate，仍未取代 `v0.22.0` 正式版。是「P5 closeout / P6 Artifact, Handoff and Validation 可開工」的乾淨基線。

### Verified

- `scripts/workflows/smoke-per-stage.sh` 從 v0.22.0-rc7 baseline 43 step 升至 **45 step / 45 passed / 0 failed / 0 skipped**：新增 `cap session inspect (P5 #10)` 與 `provider adapters (P5 #3 codex + #4 claude)` 兩個 gate。
- 跨 hook test 全綠：provider-adapters 44/44、cap-session-inspect 32/32、agent-session-runner 75/75、preflight-report 21/21、workflow-policy-gates 19/19、compiled-workflow-validation-hook 16/16、binding-report-validation-hook 15/15、compile-task-from-envelope 33/33。

## [v0.22.0-rc7] - 2026-05-04

> Release candidate — open P5「AgentSessionRunner」段並落地 runner baseline 共 7 條（#1/#2/#5/#6/#7/#8/#9）。本 tag 不取代 `v0.22.0` 正式版；**未動** `scripts/cap-workflow-exec.sh` production executor，所有新 enforcement 透過 opt-in keyword flag 切入既有 `step_runtime.upsert_session`，shell legacy 行為完全保留。P5 #3 CodexAdapter / #4 ClaudeAdapter / #10 cap session inspect 仍待做；P5 #9 stall handling 標 deferred 到 streaming adapter 落地後一併實作。

### Added

- **P5 #1+#2+#5 ProviderAdapter / AgentSessionRunner / ShellAdapter** (`52bdf76`)：新增 `engine/provider_adapter.py`（`ProviderRequest` / `ProviderResult` immutable dataclass + 4 status 字串常數 + `ProviderAdapter` ABC + `FakeAdapter` deterministic test adapter + `ShellAdapter` `subprocess.run` 包裝，TimeoutExpired 收斂為 `status=timeout/exit_code=-1` 不 raise）+ `engine/agent_session_runner.py:AgentSessionRunner.run_step(adapter, request, context) -> RunStepOutcome`（自動產生 session_id / 預先 upsert running ledger / 呼叫 adapter / 捕捉例外為 failed / map status 到 lifecycle / 寫 terminal ledger）。Ledger 寫入 100% 重用 `step_runtime.upsert_session`，不重做 schema 寫入規則。`tests/scripts/test-agent-session-runner.sh` 10 cases / 35 passed。
- **P5 #6 prompt snapshot / hash** (`d171e92`)：`schemas/agent-session.schema.yaml` 加 3 optional 欄位 `prompt_hash` / `prompt_snapshot_path` / `prompt_size_bytes`；`engine/agent_session_runner.py:_write_prompt_snapshot` 把 rendered prompt 寫到 `<sessions_dir>/prompts/<sha256[:2]>/<sha256>.txt` content-addressable layout，多 session 共用同 prompt 內容自動 dedupe；`upsert_session` 加同名 keyword-only 三參數。test 擴至 13 cases / 49 passed。
- **P5 #7 parent / child / root session relation** (`04eb463`)：schema 加 2 optional 欄位 `root_session_id` / `spawn_reason`（`parent_session_id` schema 已存在但先前從未 populate，本批正式啟用）；`SessionContext` 加 `parent_session_id` / `spawn_reason`；新 helper `_derive_root_session_id` 透過 ledger 查 parent 的 `root_session_id` 並繼承（無 parent 時 root = self；parent 不在 ledger 時保守 fallback root = parent_session_id 而非 hard fail）；`upsert_session` 加同名 keyword-only 三參數。test 擴至 16 cases / 60 passed。
- **P5 #8 lifecycle state-machine** (`d1a5682`)：新增 `engine/step_runtime.py:LifecycleTransitionError` + 模組層 `_LIFECYCLE_TRANSITIONS` 狀態機表；`upsert_session` 加 keyword-only `enforce_transition: bool = False`（預設 False 保留 shell legacy 行為），`AgentSessionRunner` 對所有 upsert 呼叫傳 `True`。允許表（保守）：first write 接受 `planned / running / failed / cancelled / blocked`；`planned → running / failed / cancelled`；`running → completed / failed / cancelled / recycled / blocked`；`blocked → running / failed / cancelled`；terminal 狀態（completed / failed / cancelled / recycled）只接受 idempotent 重寫（X → X），不可復活。明確拒絕：`completed → running` / `failed → completed` / `cancelled → completed`。test 擴至 20 cases / 68 passed。

### Changed

- **P5 #9 timeout failure standardization** (`027cafa`)：ShellAdapter timeout `failure_reason` 標準化前綴 `timeout: shell command exceeded <N>s`（先前為 `shell command timed out after <N>s`）；`AgentSessionRunner.run_step` 對任何 status=timeout 的 result 強制把 `failure_reason` 補上 `timeout:` 前綴（adapter 忘記時也保證 prefix），CLI / dry-run / log consumer 可直接 pattern-match 不再 re-check status；timeout 透過既有 `_STATUS_TO_LIFECYCLE` map 對應到 ledger `lifecycle=failed`。test 擴至 23 cases / 75 passed。

### Notes

- **P5 #0 baseline 文件對齊** (`ef16abc`)：`docs/cap/MISSING-IMPLEMENTATION-CHECKLIST.md` P5 段加入 baseline 現況（既有 schema / ledger writer / cap-workflow-exec.sh production executor）與 5 條紅線 scope memo（不重構 cap-workflow-exec.sh / 新 Python additive layer / ShellAdapter mirror shell / 不接 Codex/Claude / ledger 重用 step_runtime.upsert_session）。
- **P5 #9 stall handling deferred**：stall 監測「process 多久沒新 output」只對會 stream output 的 AI provider 有意義，ShellAdapter 是 blocking subprocess.run 不適用；待 Codex / Claude adapter 落地後再設計 streaming watcher。
- **P5 #3 CodexAdapter / #4 ClaudeAdapter / #10 cap session inspect 仍待做**：P5 #10 建議優先（無需 token，可立即讓 prompt snapshot / lifecycle 等資料對人/agent 可觀測）。
- 本 tag 為 release candidate，仍未取代 `v0.22.0` 正式版。

### Verified

- `scripts/workflows/smoke-per-stage.sh` 從 v0.22.0-rc6 baseline 42 step 升至 **43 step / 43 passed / 0 failed / 0 skipped**：新增 `agent-session-runner baseline (P5 #1-#3)` gate（P5 #6/#7/#8/#9 沿用同一 test fixture 擴充，未新增獨立 smoke gate）。
- 跨 hook test 全綠：agent-session-runner 75/75（從 35 擴至 23 cases）、preflight-report 21/21、workflow-dry-run-inspection 17/17、workflow-policy-gates 19/19、compiled-workflow-validation-hook 16/16、binding-report-validation-hook 15/15、compile-task-from-envelope 33/33。

## [v0.22.0-rc6] - 2026-05-04

> Release candidate — close P4「Compiled Workflow and Binding Pipeline」整段除 #5 deferred 外的最後兩條（#10 preflight report + #11 dry-run inspection）。本 tag 不取代 `v0.22.0` 正式版；P4 #5 維持 deferred non-blocking 待 shared / builtin / legacy workflow producer 真實落地。

### Added

- **P4 #10 preflight report** (`cdba5d6`)：新增 `schemas/preflight-report.schema.yaml` v1（8 個必填頂層欄位 `schema_version` / `workflow_id` / `binding_status` / `is_executable` / `gates` / `unresolved_summary` / `warnings` / `blocking_reasons`；binding_status enum 故意只允許 `ready|degraded` —— blocked 由 P4 #6/#9 在更前面 halt） + `engine/preflight_report.py:build_preflight_report(compiled_workflow, binding)` builder。`engine/task_scoped_compiler.py` 兩個 compile path 在所有 validation + policy gate 通過後建立 preflight，回傳 dict 多一個 `preflight_report` key（legacy 7→8 keys、envelope 9→10 keys）。fallback skill 與 optional unresolved 走 `warnings`；blocking_reasons 在現行架構恆為空，contract 預留給未來 partial-state 檢視場景。`tests/scripts/test-preflight-report.sh` 6 cases / 21 passed（happy / envelope / schema 驗證 / optional unresolved warning / fallback skill warning / blocked-deterministic-halt 不漏 preflight）。`tests/scripts/test-compile-task-from-envelope.sh` Case 0 / 3 / 6 key 斷言同步更新。
- **P4 #11 dry-run inspection** (`1411286`)：擴充 `engine/workflow_cli.py:cmd_print_compiled_dry_run` 加 `--preflight-json` / `--binding-json` 兩個 optional flag（向後相容，沒帶 flag 行為與舊版一致）。帶 flag 時 render `preflight:` 區塊（workflow_id / binding_status / is_executable / 步驟計數 / 4 條 gate 狀態 / warnings / blocking_reasons）與 `binding_steps:` 區塊（每 step capability / selected_provider / selected_skill_id / resolution_status）。`scripts/cap-workflow.sh:run-task --dry-run` 從 compile 結果再抽 `preflight_report` JSON 並 pass 兩個新 flag 給 renderer；shell 在 print 後直接 `exit 0`，**不**進入 binding-status 後續分支或呼叫任何 executor。`tests/scripts/test-workflow-dry-run-inspection.sh` 4 cases / 17 passed（backward-compat / preflight 渲染 / binding step detail / sandbox 前後檔案計數證明 print-only 無 execution side-effect）。

### Notes

- P4 整段除 #5 deferred 外全部完成：#1/#2/#3/#4/#6/#7/#8/#9/#10/#11 共 10 條 close。
- P4 #5（project / shared / builtin / legacy source priority resolver）維持 deferred non-blocking。目前 runtime 只有 project workflow source 有 producer，其餘三層尚無實際 producer 與 consumer，硬做會變空殼且需重開 P4 #2 binding-report schema / fixture。將於 multi-source workflow producer 真實落地後再實作。
- 本 tag 為 release candidate，仍未取代 `v0.22.0` 正式版。是「P4 closeout / P5 AgentSessionRunner 可開工」的乾淨基線。

### Verified

- `scripts/workflows/smoke-per-stage.sh` 從 v0.22.0-rc5 baseline 40 step 升至 **42 step / 42 passed / 0 failed / 0 skipped**：新增 P4 #10 preflight report gate + P4 #11 workflow dry-run inspection gate。
- 跨 hook test 全綠：preflight-report 21/21、workflow-dry-run-inspection 17/17、workflow-policy-gates 19/19、compiled-workflow-normalization 8/8、compiled-workflow-validation-hook 16/16、binding-report-validation-hook 15/15、compile-task-from-envelope 33/33（preflight key 斷言更新後）。

## [v0.22.0-rc5] - 2026-05-04

> Release candidate — P4 validation + policy gate checkpoint。本 tag 不取代 `v0.22.0` 正式版，亦不算 P4 整段 closeout（P4 #10/#11 仍待做、P4 #5 deferred non-blocking）。

### Added

- **P4 #1 compiled workflow validation hook** (`2d29d28`)：新增 `engine/compiled_workflow_validator.py`（`CompiledWorkflowSchemaError` / `validate_compiled_workflow` / `ensure_valid_compiled_workflow`）；於 `engine/task_scoped_compiler.py` 兩個 compile path 各掛 `post_build` + `post_unresolved_policy` 雙驗證點；CLI `cmd_compile_json` schema fail 時印 `{"ok": false, "error": "compiled_workflow_schema_error", "stage": "...", "errors": [...]}` 並 exit 1。Prerequisite fix：`build_candidate_workflow` 補 `schema_version: 1`。`tests/scripts/test-compiled-workflow-validation-hook.sh` 7 cases / 16 passed。
- **P4 #2 binding report validation hook** (`877d0b4`)：新增 `engine/binding_report_validator.py`，在 `bind_semantic_plan` 後掛 `post_bind` 驗證點；CLI 加第二個 except 分支 `binding_report_schema_error`。Prerequisite fix：`engine/runtime_binder.py:bind_semantic_plan` 補 `schema_version: 1`。`tests/scripts/test-binding-report-validation-hook.sh` 7 cases / 15 passed。
- **P4 #4 compiled workflow normalization** (`ae0f983`)：擴充 `engine/workflow_loader.py:normalize_workflow_data` 加 backward-compatible step alias `depends_on → needs`（既有 `needs` 勝出，`depends_on` 保留）；嚴格不補 schema 必填欄位。`task_scoped_compiler` 兩個 compile path 翻轉順序為 `build → normalize → validate → bind`。`tests/scripts/test-compiled-workflow-normalization.sh` 4 cases / 8 passed。
- **P4 #6/#9 binding policy hard halt** (`8ec1e57`)：新增 `engine/runtime_binder.py:BindingPolicyError` + `ensure_binding_status_executable`，在 `compile_task` / `compile_task_from_envelope` 內把 `binding_status='blocked'` 升級為硬 halt；CLI 加第三個 except 分支 `binding_policy_error`。disallowed required capability 與 required-unresolved 兩條都會在 `apply_unresolved_policy` 之前 halt，optional unresolved 維持 `degraded`。
- **P4 #7 typed source policy error** (`3384ee2`)：新增 `engine/runtime_binder.py:WorkflowSourcePolicyError`，`_assert_workflow_source_allowed` 改 raise 自訂 class；CLI 加第四個 except 分支 `workflow_source_policy_error`。檢查邏輯本身不動。
- **P4 #6-#9 共同測試** (`8ec1e57` / `3384ee2`)：`tests/scripts/test-workflow-policy-gates.sh` 6 cases / 19 passed 覆蓋 4 條 policy gate 與 4 個 CLI deterministic JSON 契約。

### Changed

- **P4 #3 jsonschema fallback hardening** (`daa262b` / `45fe723` / `256a00f`)：把 `engine/step_runtime.py:validate_constitution` 的 inline lightweight checker 抽成 module-level `validate_jsonschema_fallback` 並升級為遞迴 nested-aware；分三段補 union type（`["string","null"]`）、pattern（regex via `re.search`）、`additionalProperties: false`。`engine/compiled_workflow_validator.py` 與 `engine/binding_report_validator.py` 透過 import 共用同一 helper。`test-compiled-workflow-schema.sh` 4/9→9/9、`test-binding-report-schema.sh` 5/10→10/10、`test-identity-ledger-schema.sh` 8/11→11/11。
- **cap-release UX** (`413443b` / `9faac41` / `fe91fc2`)：`scripts/cap-release.sh` 加 ASCII logo 與 Features/Bug fixes/Documentation/Other changes 分組摘要（scope 欄位對齊 omz update 風格）；`fetch_remote` 拆 branch metadata vs tags metadata，加 `CAP_FORCE_TAG_SYNC`，`cap version` fetch fail 時 fallback 到 local cache 並顯示 `Remote metadata: fresh|skipped|local cache`；README 補 `cap update latest`。
- **P4 #8 fallback search policy 語意文件化** (`9d1b8f2`)：純 alignment doc，不改 runtime。釐清 `binding_mode='strict'` = fallback 搜尋停用而非 fallback rejection；rename 與行為變更皆延後以避免重開 P4 #2 schema / fixture。

### Notes

- **P4 #5 deferred non-blocking** (`4254c19`)：`docs/cap/MISSING-IMPLEMENTATION-CHECKLIST.md` 把 P4 #5 source priority resolver 標記為 deferred / blocked；目前 runtime 只有 project workflow source 有 producer，shared / builtin / legacy 三層尚無實際 producer 與 consumer，硬做會變空殼且需重開 P4 #2 binding-report schema / fixture。
- **`TODOLIST.md` Phase ↔ P 編號對照** (`fb0a6db`)：補對照表釐清產品路線「Phase 1-11」vs 工程批次「P0-P10」並非同一序列；歷史 commit / release note 中的 P 編號依此對照解讀。
- **P4 #10/#11 待做**：preflight report 與強化 dry-run inspection 仍未實作，是 P4 整段 closeout 前的剩餘工作。
- 本 tag 為 release candidate，仍未取代 `v0.22.0` 正式版，亦不算 P4 整段 closeout。

### Verified

- `scripts/workflows/smoke-per-stage.sh` 從 v0.22.0-rc4 baseline 升至 **40 step / 40 passed / 0 failed / 0 skipped**：新增 P4 #1 / P4 #2 / P4 #4 / P4 #6-#9 共四條 hook gate。
- 跨 schema fixture suite 全綠：compiled-workflow 9/9、binding-report 10/10、identity-ledger 11/11、capability-graph 8/8、gate-result 10/10、supervisor-orchestration 10/10、workflow-result 10/10。
- 跨 hook test 全綠：compiled-workflow-validation-hook 16/16、binding-report-validation-hook 15/15、compiled-workflow-normalization 8/8、workflow-policy-gates 19/19、compile-task-from-envelope 33/33。

## [v0.22.0-rc2] - 2026-05-03

> Release candidate — close P1「Project Storage and Identity」整段 7 個 milestone（#1–#7）。本 tag 不取代 `v0.22.0` 正式版，僅標示 P1 整段落地的乾淨節點。

### Added

- **P1 #1 cap-paths strict-mode resolver** (`1acda13`)：`scripts/cap-paths.sh:resolve_project_identity` + `engine/project_context_loader.py:_resolve_project_id` 同步 strict resolution chain（override → `.cap.project.yaml` → git basename），非 git 目錄無 identity 來源時 shell 端 exit 52、Python 端 `ProjectIdResolutionError`；`CAP_ALLOW_BASENAME_FALLBACK=1` 為 legacy escape hatch。
- **P1 #2 identity ledger collision detection** (`1acda13`)：每個 project 第一次落地時於 `~/.cap/projects/<id>/.identity.json` 建立 inline ledger，後續 resolve 比對 `origin_path`；mismatch 時 shell 端 exit 53、Python 端 `ProjectIdCollisionError`。
- **P1 #3 storage version metadata SSOT** (`02a60c0`)：`schemas/identity-ledger.schema.yaml` v2 normalized contract（6 required + nullable optional + `previous_versions[]`）+ `policies/cap-storage-metadata.md` 政策 SSOT。cap-paths.sh 與 project_context_loader.py lock-step v1→v2 auto-migrate。Ledger 記錄 `schema_version` / `created_at` / `last_resolved_at` / `migrated_at` / `cap_version` / `previous_versions[]`。`repo.manifest.yaml` 補 top-level `cap_version: v0.22.0-rc1` 作為 SSOT 起點。11 schema fixture cases + 47 resolver assertions。
- **P1 #4 storage health-check core** (`0f27324`)：新增 `engine/storage_health.py` 作為 read-only diagnostic core（`StorageHealthChecker` + `run_health_check`）。12 種 `HealthIssueKind` 涵蓋 missing storage root / unwritable storage / missing directory / missing ledger / malformed ledger / forward-incompat ledger / ledger schema drift / ledger origin mismatch / legacy v1 / cap_version mismatch / staleness / unknown field。Exit code 對齊 `policies/workflow-executor-exit-codes.md`：schema-class→41、collision→53、generic error→1、warning-only→0。**Read-only 嚴禁寫 ledger** 是治理鐵則（避免污染 `last_resolved_at` 訊號）。新增 `scripts/cap-storage-health.sh` 薄 wrapper（`--format text|json|yaml` + `--strict`）。`tests/scripts/test-storage-health.sh` 10 cases + 1 conditional / 26 assertions。
- **P1 #6 `cap project init`** (`982ca90`)：新增 `scripts/cap-project.sh` 作為 `cap project` subcommand 統一入口（init / status / doctor 三 subcommand），`scripts/cap-entry.sh` `project)` case 路由 + `[Project]` help 區塊。Init 純 shell：`--project-id` / `--force` / `--format` / `--project-root` flag。既存 `.cap.project.yaml` 預設 halt，`--force` 走 in-place rewrite 保留無關 keys。委派 `scripts/cap-paths.sh ensure` 建 storage + ledger，**重用 P1 #3 v2 producer 不重做 ledger 邏輯**。Identity-class exit code（41/52/53）verbatim propagate。`tests/scripts/test-project-init.sh` 10 cases / 33 assertions。
- **P1 #5 `cap project status`** (`f0eebc0`)：新增 `engine/project_status.py` 作為 read-only summary builder（重用 `engine/storage_health.run_health_check`，**禁止重做 health 判斷**）。輸出 project_id / 路徑 / ledger snapshot / `constitutions[]` / `latest_run`（mtime 排序選最新跨 workflow） / 嵌套 `health{}`。`--format text|json|yaml`。Exit code 對齊 storage-health。`tests/scripts/test-project-status.sh` 8 cases / 21 assertions。
- **P1 #7 `cap project doctor`** (`a9174bc`)：新增 `engine/project_doctor.py`，**read-only by design**——`--fix` flag accepted but never auto-mutates state（schema-class / collision findings 永遠 read-only，避免破壞治理 artefact）。`REMEDIATIONS` 字典覆蓋全部 12 種 `HealthIssueKind`，每條 remediation 引用真實 CLI 命令（`cap project init` / `cap-paths.sh ensure` 等）。Exit code 對齊 storage-health。`tests/scripts/test-project-doctor.sh` 10 cases / 31 assertions。

### Changed

- `policies/cap-storage-metadata.md` §6 重構為三段：6.1（P1 #4 health-check 落地）/ 6.2（P1 #5/#6/#7 落地）/ 6.3（後續規劃含 P10 promote 與 deferred `--fix` 自動修復）。明示 schema-class 與 collision findings 永遠 read-only 的鐵則。
- `policies/workflow-executor-exit-codes.md` identity-class executor 區段補 `scripts/cap-project.sh`（v0.22.0-rc2 起）。
- `docs/cap/IMPLEMENTATION-ROADMAP.md` Phase 2 全部 7 條 ticked，並注記 `cap project paths` 並未獨立實作（既有 `cap paths` 已涵蓋此行為）。

### Verified

- `scripts/workflows/smoke-per-stage.sh` 從 23 step（v0.22.0-rc1 baseline）升至 27 step：新增 storage-health-check core gate（P1 #4）+ cap project init / status / doctor 三 gate（P1 #5/#6/#7）。本 repo smoke：**27 passed / 0 failed / 0 skipped**。
- CLI happy path：`cap project init` → `cap project status` → `cap project doctor` 三步序列在 hermetic CAP_HOME 下全部 exit 0、JSON envelope 正確 parse、`overall_status=ok`。

### Notes

- 本 tag 為 release candidate，仍未取代 `v0.22.0` 正式版。後續 P2（Project Constitution Runner）開工後再評估是否升 stable。
- `0f27324` / `982ca90` 兩筆新增 .sh 檔在初次 `git add` 時 index mode 為 100644（`core.filemode=false` 環境下 `git add` 不會自動帶入 +x，與 v0.21.6 `d0d0a64` 同一坑），事後以 `git update-index --chmod=+x` 補回 100755（`762c7d5`）。後續 P1 #5/#6/#7 三筆 commit 已在 commit 前主動 `git update-index --chmod=+x` 預設 100755，避免再踩。

## [v0.21.4] - 2026-05-01

### Fixed
- `scripts/workflows/provider-parity-check.sh` §4.5 修 false positive：當 `.cap.constitution.yaml` 沒有宣告 `design_source` block（DESIGN_TYPE=""）但 `docs/design/` 存在時，先前的邏輯硬查 `source-summary.md` / `source-tree.txt` / `design-source.yaml` / `.source-hash.txt` 4 個 ingest sentinel，把 UI agent（03-ui-agent.md §4）合法寫入的 `<module>_UI_v*.md` / `_tokens_v*.json` / `_screens_v*.json` / `_prototype_v*.html` 4 個交付物誤判為 4 個 missing FAIL；現在合併 `none|""` 為同一條 lenient PASS 分支：沒宣告 design_source 就不該期待 ingest 跑、dir 內容是 UI agent 或更早跑的副產物，視為 PASS with note。codex spec-pipeline parity 從 41 PASS / 5 FAIL 收斂為 **42 PASS / 1 FAIL**（與 claude 一致），剩下 1 FAIL 為 supervisor 寫 `non_goals=[]`（已 deferred）。

### Changed
- `agent-skills/03-ui-agent.md` §4 加硬性「必須實際寫檔」規範：claude UI step 在 v0.21.3 cross-provider parity run 觀察到只在 stdout / handoff_summary 用 code block 或 diff 列出資產內容、寫「建議落地 / 待後續決定 / 未寫入」等占位語意取代真實寫檔；新規條款明確禁止此模式，要求以實際檔案系統寫入動作建立 4 個必交付資產，且 §5 handoff_output `output_paths` 條目必須對應**已實際寫入**的檔案路徑、不接受占位。

## [v0.21.3] - 2026-05-01

### Fixed
- `engine/step_runtime.py` `validate_inputs` 抽 `_try_resolve` helper 並新增 `optional_inputs` 欄位處理：required 缺漏仍 block；optional 缺漏 silently skip 並讓 shell 自決 graceful no-op，descriptor 帶 `optional: True` 標記。對齊 spec yaml 早已承諾的 graceful 行為（如 `ingest_design_source` 在 design_source 缺漏 / type=none 時應走 no-op）。
- `schemas/workflows/project-spec-pipeline.yaml` 把 `design_source` 從 `inputs` 移到 `optional_inputs` 共三個 step：`ingest_design_source`（shell graceful no-op 主場景）、`prd`（無設計稿時仍能產 PRD）、`ui`（no-design baseline）。
- `scripts/cap-workflow-exec.sh` 新增 `record_blocked_step` helper 並 wire 入 6 個 block 路徑（required_unresolved / unsupported_executor / missing_agent / invalid_shell_script / missing_input_artifact / detached_head），blocked step 現在會寫 `workflow.log` entry 與 `run-summary.md ## Steps` 區塊；治理層不再對 block 失明。先前以為 `cap workflow run` 撞 step_failed 仍 exit 0 是觀察者 background command shell 結構誤導（`...; echo "EXIT_CODE=$?"`），實際 `EXIT_CODE` 已自 v0.19.x 起正確反映 `final_state`。
- `scripts/workflows/persist-task-constitution.sh:normalize_task_constitution_json` 補兩條漂移收斂：(1) `risk_profile` object form（如 `{"level":"medium","key_risks":[...]}`）coerce 為 schema enum string `low|medium|high|unknown`，sub-fields 丟棄（仍保存於 supervisor draft markdown）；(2) `non_goals` 缺漏 / null / 字串強制 coerce 為 `array<string>`。`fail_with` 從 `exit 40` 改為 `exit 41`，`cap-workflow-exec.sh:shell_exit_condition` 新增 `41 → schema_validation_failed` mapping，跟 vc-apply 的 `40 → git_operation_failed` 拆開，治理層可區分 Type B drift 與 git 操作失敗。

### Added
- `tests/scripts/test-persist-task-constitution.sh` 新增 Case 7（risk_profile object form → schema enum string）與 Case 8（missing non_goals → `[]`），unit smoke 從 18/18 升為 22/22。`smoke-per-stage.sh` 整體 136 → 140 assertions，10 step 全綠。
- `docs/cap/PROVIDER-PARITY-FINDINGS-v0.21.2.md` 新增 baseline → resolution 治理紀錄，凍結 2026-05-01 v0.21.2 跑 claude `project-spec-pipeline` 撞 phase 3 `ingest_design_source` blocked 的觀察與根因（R1 規格 vs runtime 偏差、R2 治理信號斷裂、R3 雙 project_id 解析、R4 schema drift）；R1/R2/R4 closeout 摘要 + cross-provider e2e 結果 + deferred 清單。

### Verified
- E2E claude `project-spec-pipeline` 重跑（self-hosting `charlie-ai-protocols`，run_id `run_20260501020621_b27b155f`）：v0.21.2 baseline 3/16 step_failed 推到 16/16 completed；duration 1217s；provider-parity-check 22 PASS / 16 FAIL → **42 PASS / 1 FAIL**（剩 1 FAIL 為 supervisor draft 寫 `non_goals: []` 觸發 §4.2 嚴格判定，標 deferred）。
- E2E codex `project-spec-pipeline` cross-provider 驗證（run_id `run_20260501023353_ce13c11d`）：16/16 completed、duration 1254s；provider-parity-check 41 PASS / 5 FAIL（4 FAIL 為 §4.5 工具盲點對 codex UI step 寫的 `docs/design/<module>_*` 4 個交付物誤判為缺 ingest sentinel；1 FAIL 與 claude 同源於 `non_goals=[]`）；無 provider-specific regression。

### Deferred (next round)
- R3 雙 project_id 解析：cwd 解析的 cap_home_project_id vs supervisor 草寫的 task_constitution.project_id 仍可能分裂兩個 cap home（本批 closeout 跑 supervisor 對齊沒觸發，但 system-level identity resolver 未統一）。
- supervisor `non_goals=[]` 處置方向：(a) 強化 `agent-skills/01-supervisor-agent.md` §2.5 prompt「至少 1 條」；(b) 調寬 `provider-parity-check.sh` §4.2 接受空陣列。
- `provider-parity-check.sh` §4.5 false positive：對 UI agent 交付物（`<module>_UI_v*.md` / `<module>_tokens_v*.json` 等）誤報為缺 ingest sentinel；應加白名單或拆「ingest 期望」與「整體 docs/design 期望」兩套檢查。
- Provider divergence on docs/design/ writeback：claude UI step 在 handoff 寫「本次未寫入，待後續專案決定」**不**寫實檔；codex UI step 真寫；應對齊 03-ui-agent.md §4「必交付清單」強制寫檔。
- 其他 schema-class executors exit code：`validate-constitution` / `emit-handoff-ticket` / `ingest-design-source` / `bootstrap-constitution-defaults` / `persist-constitution` / `load-constitution-reconcile-inputs` 仍用 exit 40，可漸進改 41 完整覆蓋。

## [v0.21.2] - 2026-04-30

### Fixed
- `scripts/workflows/provider-parity-check.sh` 修兩個影響 release-gate 結果的 checker bug：(1) §4.6 spec layer artifact pattern `_archive` 帶底線是錯的，cap workflow run 實際寫的是 `<phase>-archive.md`（無底線），改為 `archive` 後既有成功 run 不再被誤標 FAIL；(2) §4.5 design source 區段原本當 `docs/design/` 不存在時靜默略過，遮蔽了「憲法宣告 `design_source.type: local_design_package` 但 `ingest_design_source` 沒跑」的真實缺漏；現在從 cwd 的 `.cap.constitution.yaml` 讀 `design_source.type`，依 type 分流：`none` 或無宣告 + 無 `docs/design` 視為 PASS no-op、`none` 但有 dir 視為 PASS with note、非 none 但無 dir 視為 FAIL、非 none 且有 dir 走 per-file 檢查。修復後對 token-monitor 兩個歷史 run 驗證行為符合預期：成功 run 報 40 PASS / 3 真實 FAIL（pre-v0.21.1 schema 缺欄位 + pre-v0.21.0 缺 ingest 產物）、halted run 正確抓到 3 個 banned aliases（task_summary / user_intent_excerpt / scope）展示工具在 release-gate 上的真實價值。

## [v0.21.1] - 2026-04-30

### Added
- `agent-skills/01-supervisor-agent.md` 新增 §2.5「Task Constitution 嚴格 Schema 契約 (v0.21.1+)」：明確列出 task_constitution_planning 必須輸出的 8 個固定頂層欄位（task_id / project_id / source_request / goal / goal_stage / success_criteria / non_goals / execution_plan）+ execution_plan entry 必填的 step_id / capability，**列出每個欄位禁止改用的別名**（task_summary、task_goal、user_intent_excerpt、scope.out_of_scope、target_capability 等），並聲明 v0.22.0+ 將逐步移除 persist normalizer 的 alias fan-in；needs_data + halt 是資訊不足時的正確逃生路徑，不應依賴別名繞過。
- `docs/cap/DESIGN-SOURCE-RUNTIME.md` 新增 design source 運行時 SSOT 文件：四層模型（registry / constitution / docs/design summary / raw fallback）+ 三段式解析鏈 + 6 條不變式 + workflow 接觸點對照表 + 測試覆蓋摘要 + migration & deprecation 計畫；把 v0.20.0–v0.21.0 散落在 schema / capability / workflow / agent-skill / shell / 測試的規則收成一份權威藍圖。
- `docs/cap/PROVIDER-PARITY-E2E.md` 新增 provider parity 驗收 checklist：minimum + extended 受測組合、跑法、4.1-4.7 七個分類共 30+ checklist 項、失敗診斷對照表、release gate 規範；把 Codex / Claude 真實 e2e 從人工觀察變為可重跑、可審計、可比對的正式程序。
- `scripts/workflows/provider-parity-check.sh` 新增 artifact-only 驗收工具（不呼叫 AI）：依 `--run-dir` / `--task-id` / `--project-id` 自動驗 4.1-4.6，含 Type B 8 欄位嚴格檢查 + 別名偵測（task_summary / user_intent_excerpt / scope）、Type C 每張 ticket schema validation、Type D summary 存在性、design source 三件式 + sentinel；exit code 0/1/2 區分通過 / 缺漏 / 誤用旗標。

### Changed
- `schemas/workflows/project-spec-pipeline.yaml` `draft_task_constitution` step done_when：把「execution_plan 中每個 step 已指定 step_id / target_capability」改為嚴格 schema 描述（8 個固定頂層欄位 + entry 必含 step_id / capability，禁用 target_capability 等別名），指向 supervisor §2.5 為權威定義。
- `schemas/capabilities.yaml` `task_constitution_planning` capability done_when 同步加入 v0.21.1+ 嚴格 schema 條目，讓任何未來 workflow 引用此 capability 都繼承同一份契約。

## [v0.21.0] - 2026-04-30

### Added
- `scripts/workflows/ingest-design-source.sh` 新增 deterministic ingest 腳本：把 `constitution.design_source` 指向的 raw package 收斂為 `docs/design/source-summary.md` + `source-tree.txt` + `design-source.yaml` 三個 artifacts 與 `.source-hash.txt` sentinel；採 SHA-256 over (relative-path + content) 計算 hash，cache hit 時跳過 rebuild 維持 mtime 不變；`design_source.type: none` / 缺 block + 空 fallback 視為 graceful no-op 不寫檔；source_path 宣告但磁碟缺失則 halt（exit 40）。共享 `engine/step_runtime.py` `_design_source_path` 三段式解析（constitution → design_root + package → legacy `~/.cap/designs/<project_id>`）。
- `schemas/capabilities.yaml` 新增 `design_source_ingest` capability（shell-only）：`default_agent: shell` / `allowed_agents: [shell]`，inputs `project_constitution` + `design_source`，outputs `design_source_summary` / `design_source_tree` / `design_source_metadata`；done_when 含 hash 計算、cache hit 行為、no-op 與 halt 條件。`.cap.constitution.yaml` 自宿主憲法 allowed_capabilities 同步加入。
- `schemas/workflows/project-spec-pipeline.yaml` 插入 `ingest_design_source` 為新一級 step（spec pipeline 從 15 步升至 16 步）：依賴 `persist_task_constitution`、平行於 prd / tech_plan / ba / dba_api 跑、由 `emit_ui_ticket` 與 `ui` 顯式 needs 銜接，確保 UI step 啟動前 summary 已落地；artifacts 區補三個新名稱、logger_checkpoints 加入該 step。
- `tests/scripts/test-design-source-ingest.sh` 新增 6 cases / 21 assertions 涵蓋 hash-cache 全生命週期：no_design_source / type=none no-op / 真實 source rebuilt 三件式 + 64-char hash sentinel / 重跑 cached（mtime 不變、hash 相同）/ 修改 source 觸發 rebuild + 新 hash / source_path 缺失 halt exit 40；用 `mktemp -d` sandbox + subshell run_ingest 避免 cd leak 與 exit code masking。

### Changed
- `schemas/handoff-ticket.schema.yaml` `context_payload.design_assets_pointer` 描述更新：明示 v0.20.0+ 應由 supervisor 從 `constitution.design_source.source_path` 抄寫；legacy `~/.cap/designs/<project_id>/` 僅作為 runtime fallback；不再硬編 project_id 等於 design package 的隱式假設。
- `schemas/workflows/project-spec-pipeline.yaml` UI step done_when 改為「**優先**對齊 `docs/design/source-summary.md`」（v0.21.0 summary-first），raw package 解析降為 fallback；notes 詳述 summary-first 規範、cache 機制（`.source-hash.txt` sentinel）、與 ingest 共享的三段式解析鏈。
- `scripts/workflows/smoke-per-stage.sh` 從 9 step 擴為 10 step，加入 design-source ingest smoke；本 repo 環境下從「9/9、115 assertions」升為「10/10、136 assertions」全綠。

## [v0.20.1] - 2026-04-30

### Added
- `scripts/cap-workflow.sh` 把 `--design-package <name>` 旗標完整接通：宣告 `DESIGN_PACKAGE` slot、case 解析、forwarding 至 `DESIGN_AUGMENT_ARGS`、usage 行同步加入該旗標；補完 v0.20.0 只在 engine `engine/design_prompt.py` 加旗標但 wrapper 沒接的斷層。
- `scripts/cap-entry.sh` 主用法區塊加 `cap workflow run --design-package <name>` 一行範例（標 v0.20.0+ 推薦），legacy `--design-source local-design --design-path` 寫法保留作為相容路徑。
- `tests/scripts/test-cap-workflow-design-package-forwarding.sh` 新增 wrapper 層 forwarding smoke（4 cases / 5 assertions）：sandbox HOME 雙 package + 攔截 python3 invocation log，驗 (1) usage 列出 `--design-package`、(2) wrapper 不報 unknown option、(3) `--design-package pkg-a` 確實傳到 `design_prompt.py augment` argv、(4) 換 pkg-b 不會 hard-code。

### Changed
- `schemas/workflows/project-constitution.yaml` `draft_constitution` notes 區塊更新：多 package 選擇優先推薦 `--design-package <name>`（v0.20.0+），legacy `--design-path ~/.cap/designs/<name>` 並列保留；新增一條 note 明示 supervisor 必須把 design ritual block 落地為 `design_source` 五欄結構（type / design_root / package / source_path / mode），下游不再從 project_id 推導。
- `schemas/workflows/project-spec-pipeline.yaml` UI step 的 done_when 與 notes 改用 `constitution.design_source.source_path` 為主要解析點；明示 `engine/step_runtime.py` `_design_source_path` 三段式解析（constitution → design_root+package → legacy `~/.cap/designs/<project_id>`）；移除「`<project_id>` 等於 design package」的隱式假設。
- `tests/e2e/fixtures/token-monitor-minimal/.cap.constitution.yaml` 新增 `design_source: type: none`，讓 fixture 本身遵守 v0.20.0+ 的「每份憲法應顯式記錄 design_source」規範，並作為 type none 場景的 copy-ready 範例。
- `scripts/workflows/smoke-per-stage.sh` 從 8 step 擴為 9 step，加入 `test-cap-workflow-design-package-forwarding.sh`；本 repo 現況 9/9、115 assertions 全綠。
- 外部專案 `token-monitor/.cap.constitution.yaml`（非 git repo，無 commit）已手動補 `design_source` block 為 `local_design_package` + `package: token-monitor` + `source_path: ~/.cap/designs/token-monitor`，作為實際專案 migration 範例；其他既有專案的批次 reconcile / migration workflow 仍 deferred。

## [v0.20.0] - 2026-04-30

### Added
- `engine/design_prompt.py` 把 `~/.cap/designs/` 從「以 project_id 自動 1:1 推導」升級為**多 package registry**：新增 `_list_design_packages` 列出全部子目錄、`_prompt_for_design_package` 在 TTY 互動模式下要求使用者選擇、`_resolve_design_package_by_name` 處理 `--design-package <name>` 顯式選擇；多 package 非互動環境會 halt 並列出可選 package；單一 package 維持自動選擇行為。新增 `--design-package` argparse 旗標。
- `schemas/project-constitution.schema.yaml` 新增 optional `design_source` block：top-level object 含 type enum（`none` / `local_design_package` / `claude_design` / `figma_mcp` / `figma_import_script`）+ `design_root` / `package` / `source_path` / `mode` / `figma_target` / `script_path` 屬性；憲法不再依賴 `<project_id>` 與 `<package_name>` 等價的隱式假設，明示記錄選定的 design source。Legacy 憲法（沒有此 block）維持有效，runtime 視為 `type: none`。
- `scripts/workflows/bootstrap-constitution-defaults.sh` 在 bootstrap markdown 新增 design_source 章節，附三個範例（單一 local package、none、figma_mcp）+ 一段說明「~/.cap/designs/ 是 registry，憲法應顯式記錄選定 package」，引導 supervisor 在 draft constitution step 落地正確的 design_source block。
- `engine/step_runtime.py` 新增 `_read_constitution_design_source` helper + 升級 `_design_source_path`：解析順序改為「constitution.design_source.source_path → design_root + package join → legacy `~/.cap/designs/<project_id>` fallback」，讓 runtime 從憲法讀來源而不是猜 project_id；type none 與缺 yaml lib 的 degraded 場景皆 graceful fallback。
- `schemas/design-source-templates.yaml` 的 local-design 模板新增 `design_package_name: {design_package}` 欄位 + 完整的 design_source YAML 區塊（供 supervisor 直接複製進 constitution JSON 草稿）。
- `engine/design_prompt.py` cmd_augment 在 `selected == "local-design"` 時計算 `fields["design_package"]`：若 path 落在 `~/.cap/designs/<pkg>/...` 取首段為 package；否則取目錄名 fallback。
- `tests/scripts/test-design-source-resolution.sh` 新增 9 case / 15 assertion 涵蓋 design source 解析全鏈：A 空 registry / B 單 package 自動選 / C 多 package 非互動 fallback / D `--design-package <name>` 顯式選 / E 不存在 package 報錯 / F constitution.source_path 直讀 / G type none fallback / H design_root + package join / I 無 constitution fallback。HOME 重導到 mktemp 沙箱不污染真實 `~/.cap/designs/`。
- `tests/scripts/test-persist-task-constitution.sh` 新增 Case 6 / 5 assertion 驗 normalize 把 `task_summary → goal`、`user_intent_excerpt → source_request`、`target_capability → capability` 的別名展開（重現 2026-04-30 cap workflow run 觀察到的 supervisor draft 形狀）。

### Changed
- `scripts/workflows/smoke-per-stage.sh` 從 7 step 擴為 8 step：在 unit smoke 與 e2e 之間插入 `tests/scripts/test-design-source-resolution.sh`；本 repo 環境下從「7/7、90+ assertions」升為「8/8、110 assertions」全綠。
- `~/.cap/designs/` 的 project_id 自動推導路徑保留為 **legacy fallback**（仍為 `_design_source_path` 的最後一條路徑），但**新專案應透過 `design_source` block 明示記錄**；commit `e720201`（user/linter 修補）已對 persist-task-constitution.sh 的 normalize 主流程串接 `task_summary` 等別名，配合本 release 的測試覆蓋確保不再回歸。

## [v0.19.6] - 2026-04-30

### Added
- `tests/e2e/fixtures/token-monitor-minimal/` 新增最小 CAP 專案 fixture（`.cap.constitution.yaml` + `.cap.project.yaml` + README），repo 追蹤確保 e2e 測試跨環境可重跑；`binding_policy.allowed_capabilities` 涵蓋 v0.19.x 全部新 capability（task_constitution_planning / task_constitution_persistence / handoff_ticket_emit）+ project-spec-pipeline 全部 AI 步驟所需 capability。
- `tests/e2e/test-project-spec-pipeline-deterministic.sh` 新增「persist + emit 鏈」deterministic e2e（4 stages / 40 assertions）：模擬 task_constitution_draft 後依序跑 persist-task-constitution.sh → emit-handoff-ticket.sh × 6（prd / tech_plan / ba / dba_api / ui / spec_audit）→ 重跑 emit_prd 驗 seq 遞增 1→2 + 舊 ticket 保留；用 `mktemp -d` 隔離 sandbox，零 AI 依賴可在 CI 跑。
- `scripts/workflows/fake-sub-agent.sh` 新增 deterministic sub-agent 模擬器：讀 `CAP_HANDOFF_TICKET_PATH`（或第一個位置參數），對 ticket 跑 `engine/step_runtime.py validate-jsonschema`，依 `output_expectations.handoff_summary_path` 寫出符合 `policies/handoff-ticket-protocol.md` §4 的 Type D summary（YAML frontmatter + task_summary / key_decisions / downstream_notes / risks_carried_forward / halt_signals_raised 五段）；env hook `CAP_FAKE_RESULT=failure` + `CAP_FAKE_HALT_SIGNAL` 切換到 simulated failure 仍寫 Type D 但記 `result: 失敗`；exit 碼 0/1/2/3/4/5 分別對應成功 / 模擬失敗 / ticket 不可讀 / schema 驗證失敗 / 缺 handoff_summary_path / 寫入失敗。
- `tests/e2e/test-ticket-consumption.sh` 新增 ticket consumption e2e（4 cases / 22 assertions）：成功路徑驗證 Type D 落地與五段 body 結構齊全 + ticket bytes 經 sha256 比對「未被 consumption 修改」（read-only 契約）；失敗路徑驗 result=失敗 與 halt signal；malformed ticket 驗 schema 驗證 halt（exit 3）；缺 env 驗 exit 2。
- `tests/e2e/README.md` 新增說明 e2e 三層測試金字塔（unit smoke / deterministic e2e / real AI e2e）的範圍、跑法、與不取代真實 `cap workflow run` 的明確聲明。
- `scripts/workflows/smoke-per-stage.sh` 整合兩個新 e2e 測試為 step 6 / step 7，與既有 3 條 binding + 2 條 unit smoke 合計 7 個 step；本 repo 環境下 7/7 PASS。

### Changed
- `tests/scripts/README.md` 同步更新「一鍵跑全部 smoke」段落為 7 個 step（v0.19.6 整合 e2e）。

## [v0.19.5] - 2026-04-30

### Fixed
- `scripts/workflows/smoke-per-stage.sh` 修正在沒安裝 `cap` alias 的環境下 binding 階段全部 graceful skip 的問題：(1) 加入 in-repo fallback — cap 不在 PATH 時改用 `${REPO_ROOT}/scripts/cap-workflow.sh`（用 `bash <file>` 呼叫，不依賴 executable bit）；(2) bind 結果判定改用 canonical `binding_status: ready` 信號 + `required_unresolved=0` 雙重確認，不再被 `summary:` 行裡 `required_unresolved=0` 的 key 名誤觸發 FAIL；(3) 報頭印出 bind invoker 解析結果（cap_path / cap_workflow_sh / unavailable）使可追溯；本 repo 環境下從先前的「2 passed, 0 failed, 3 skipped」變為「5 passed, 0 failed, 0 skipped」。

### Deferred (explicitly carried to future cycle)
- **e2e 真實 `cap workflow run` 端到端**（清單 #2）：`bind ready` + `plan ok` + `executor smoke 28/28` 已就緒，但完整 AI workflow 執行（spawn sub-agent → 寫 Type D → downstream 消費）必須在有 cap CLI + AI runtime 的使用者環境跑；scaffolding 在無 runtime 環境無法驗證，刻意不加偽落地。
- **sub-agent ticket consumption 真實 e2e**（清單 #3）：同上，必須在 runtime 環境驗證。
- **runtime governance 自動 enforce**（清單 #4）：route_back / gate fail / retry 的自動回流目前仍靠 workflow YAML 的 `failure_routing` + 文件協議；engine `step_runtime.py` 自動觸發改寫風險高，明確 deferred。

## [v0.19.4] - 2026-04-30

### Added
- `scripts/workflows/smoke-per-stage.sh` 新增單一指令的 per-stage workflow smoke 入口：依序跑 `cap workflow bind project-spec-pipeline` / `project-implementation-pipeline` / `project-qa-pipeline` 三條 binding 檢查，再跑 `tests/scripts/test-persist-task-constitution.sh` / `test-emit-handoff-ticket.sh` 兩個 fixture 套件；cap CLI 不在 PATH 時 binding 檢查會 graceful skip 並標 WARN（fixture 仍會跑），讓本 wrapper 可在沒有 cap installer 的 CI 環境作為 hermetic gate；退出碼 0 = 全 PASS（含 skipped）、非 0 = 至少一項 FAIL；`tests/scripts/README.md` 同步補上一鍵跑入口說明。
- `engine/step_runtime.py` 新增 `validate-jsonschema` subcommand：對 `validate-constitution` 的 generic 別名，接 `<json_path> <schema_path>` 兩參數委派同一個 jsonschema validator function（Draft202012Validator + 無 jsonschema lib 的 manual fallback），讓任何 JSON-Schema 風格的 schema 都能被驗證；不影響 `validate-constitution` 既有行為，純 additive。
- `scripts/workflows/persist-task-constitution.sh` 在 pretty-print 之後接入 `validate-jsonschema` 全域 schema 驗證：minimal 結構驗證做 fast-fail，schema 驗證捕捉前者看不到的 type / enum / nested shape 問題；schema 驗證失敗即 `fail_with schema_validation_failed` halt。
- `scripts/workflows/emit-handoff-ticket.sh` 在 ticket 寫入後接入 `validate-jsonschema` 全域 schema 驗證：inline pre-write field-presence assertion + post-write full schema validation 雙層保護；schema 驗證失敗即 halt（ticket 已落地不刪除作為 audit trail）。

### Changed
- `schemas/task-constitution.schema.yaml` 從 legacy `fields:` 風格轉為 JSON-Schema 標準（`required: [...]` array + `properties: {...}`），對齊 `schemas/project-constitution.schema.yaml` 的單一 schema 慣例；補入 `execution_plan` array-of-object 結構（含 step_id / capability / needs / on_fail / route_back_to / timeout_seconds 等）與 `governance` 物件結構（含 watcher_mode enum、watcher_checkpoints、logger_mode enum、budget_sub_agent_sessions），讓 schema 真實反映 v0.19.x 引入的 task constitution 內容。`source_request` 從 required 移除（既有 token-monitor 等 historic fixture 沒有此欄位；標註為 recommended，未來收緊需走 breaking change + migration plan）。
- `schemas/handoff-ticket.schema.yaml` 從 legacy `fields:` 風格轉為 JSON-Schema 標準；保留所有 12 個 top-level required fields 與 nested required（context_payload.{project_constitution_path, task_constitution_path}、output_expectations.{primary_artifacts, handoff_summary_path}、failure_routing.on_fail）；array-of-object 改用 JSON-Schema 標準 `items: {type: object, properties: {...}}` 寫法，可被 jsonschema 標準驗證器直接消費。

### Fixed
- `docs/cap/SKILL-RUNTIME-ARCHITECTURE.md` 既有「draft（尚未實作）」清單把已落地的 `dispatch 前自動 materialize handoff ticket` 移出，改置入新增的「v0.19.x 已部分實作」分類並註記哪部分還缺（engine `step_runtime` 自動 hook 仍 deferred）。
- `docs/cap/IMPLEMENTATION-ROADMAP.md` Phase 0 的「主要缺口」清單為三項加上 v0.19.x 進度註記：(1) Project Constitution runner — task-scoped runner 已部分落地；(2) Supervisor structured orchestration — per-stage workflow + Type C ticket + cross-agent policy 已落地；(3) Artifact validation / governance gates — schema validation 已強化；其餘 5 項維持原狀。讓 roadmap 反映實際進度，避免誤判已完成事項。
- `docs/cap/ARCHITECTURE.md` 「Handoff Ticket 欄位參考」章節更新兩處過時敘述：(1) 原文寫「engine 尚未實例化」，改為「自 v0.19.x 起已由 `scripts/workflows/emit-handoff-ticket.sh` 實例化；engine `step_runtime` 自動 ticket emission hook 與 sub-agent 端的 ticket consumption end-to-end 仍待完整 e2e 驗證」，誠實反映目前狀態；(2) 原文寫「`schemas/handoff-ticket.schema.yaml` 已於 v0.10.1 降級為概念參考」，改為「v0.19.x 重新升級為一級 SSOT，不再是概念參考」；連帶補完 ticket 欄位表（從 8 欄擴為 11 欄，新增 `ticket_id` / `output_expectations` / `failure_routing` / `created_at,created_by` 等實際存在的欄位），並補上一句派工流程概覽指向 supervisor §3.6 + emit-handoff-ticket.sh + handoff-ticket-protocol.md 的閉環。

## [v0.19.3] - 2026-04-30

### Fixed
- `scripts/workflows/emit-handoff-ticket.sh` 修正 target_step_id 自動推導誤觸發的 edge case：當 `CAP_TARGET_STEP_ID` 與 `CAP_WORKFLOW_STEP_ID` 都未設定時，`step_id` 會落到本地預設值 `emit_handoff_ticket`，剛好符合 `emit_*_ticket` pattern 而被誤推導成 `target_step_id=handoff`，遮蔽了「使用者忘了設 env」這個錯誤；改為顯式檢查 `CAP_WORKFLOW_STEP_ID` 是否被設定（不是預設 fallback）才允許 derive，並直接以 `CAP_WORKFLOW_STEP_ID` 為 derive 來源；smoke test `test-emit-handoff-ticket.sh` 從 14/15 變回 15/15 PASS（Case 3 「missing target_step_id env」正確回報 `missing_target_step_id` 而非誤導性的 `step_not_in_execution_plan`）。

## [v0.19.2] - 2026-04-29

### Changed
- `agent-skills/01-supervisor-agent.md` §3.7「Mode C Conductor 綁定的協議落地」對齊 commit `d157c76` 的 workflow init 拆步：把舊的「init_task」step 名稱改為「`draft_task_constitution`，後接 deterministic shell `persist_task_constitution`」，並補新一段「RuntimeBinder 與 step_runtime 的責任邊界」明示 runtime 只執行不決策、ticket 是派工 SSOT；本變更使 §3.7 與 `policies/constitution-driven-execution.md` §1.3、`policies/handoff-ticket-protocol.md` 三檔對 conductor binding 的描述完全一致。
- `scripts/workflows/emit-handoff-ticket.sh` 新增從 `CAP_WORKFLOW_STEP_ID` 自動 derive `target_step_id` 的 fallback：當該 step 命名為 `emit_<step>_ticket` 模式時，腳本自動把 `<step>` 抽出作為 target，免於每個 emit step 都得在 workflow YAML 注入 env var；明示 env var `CAP_TARGET_STEP_ID` 仍優先（顯式覆蓋 implicit derive）。
- `schemas/workflows/project-spec-pipeline.yaml` / `project-implementation-pipeline.yaml` / `project-qa-pipeline.yaml` 三條 workflow 在每個 sub-agent step 前插入 `emit_<step>_ticket` 顯式 shell step（採 A 方案——cap CLI 觀察性最佳、無需動 engine）：spec-pipeline 從 9 → 15 步（補 emit_prd / emit_tech_plan / emit_ba / emit_dba_api / emit_ui / emit_spec_audit）、implementation-pipeline 從 9 → 15 步（補 emit_frontend / emit_backend / emit_qa_testing / emit_security_audit / emit_devops_packaging / emit_impl_audit）、qa-pipeline 從 6 → 9 步（補 emit_qa_testing / emit_security_audit / emit_qa_audit）；每個 emit step 有獨立 needs 銜接上游、產出 handoff_ticket artifact、有結構驗證 done_when 與 halt-on-fail；archive 由 supervisor in-line 不需 ticket 故不插 emit；`logger_checkpoints` 不含 emit step 以免 milestone log 過於密集。本變更讓 ticket emission 成為 dispatch 流程的可觀察一級事件而非工具，cap CLI 跑 workflow 時可看到每個派工點都有對應 ticket 落地。

### Added
- `tests/scripts/` 新增 deterministic executor 的 fixture smoke 測試套件：`test-persist-task-constitution.sh`（5 cases / 13 assertions：happy path + malformed JSON + missing required + invalid goal_stage + invalid execution_plan entry）+ `test-emit-handoff-ticket.sh`（4 cases / 15 assertions：happy path + seq 遞增 1→2→3 且舊 ticket 保留 + missing target_step_id + step 不在 execution_plan）+ README 說明範圍與執行方式；測試使用 `mktemp -d` 隔離 sandbox 自動清理，無需外部測試框架，純 bash + python3 即可運行；本批為 cap CLI 整合測試（cap workflow bind / plan）之外的單元層補強，封住兩個 shell executor 的 regression 風險面。
- `scripts/workflows/persist-task-constitution.sh` 強化 task constitution 結構驗證：除既有 required field + goal_stage enum 外，新增 `execution_plan` 結構檢查（必須是非空 array，每個 entry 含 step_id + capability）、`governance` 必須為 object（如有）；validation rc 5 = invalid execution_plan、rc 6 = invalid governance；honest 註解明標為 minimal structural validation 而非 full JSON Schema。
- `scripts/workflows/emit-handoff-ticket.sh` 新增 ticket 寫入前的 post-build 結構驗證：對齊 `schemas/handoff-ticket.schema.yaml` 的 12 個 top-level required fields（ticket_id / task_id / step_id / created_at / created_by / target_capability / task_objective / rules_to_load / context_payload / acceptance_criteria / output_expectations / failure_routing）+ `context_payload.{project_constitution_path, task_constitution_path}` + `output_expectations.{primary_artifacts, handoff_summary_path}` + `failure_routing.on_fail` 的存在性檢查；validation 失敗於寫檔前 halt（rc 4-7 對應不同層級缺失），避免產出結構不完整的 ticket 流入下游。

### Fixed
- `scripts/workflows/persist-task-constitution.sh` 修四個影響執行的真實 bug：(1) Python f-string 內含 `\",\".join(...)` 的反斜線轉義在 Python <3.12 為 SyntaxError，改抽到區域變數 `missing_list = ",".join(missing)` 再 format；(2) 同函式另一處 `f"{data[\"project_id\"]}"` 同樣 invalid，改先 `project_id = data["project_id"]` 再 f-string；(3) 主流程的 `1>&3` 重導向但 FD 3 從未開啟導致 shell 直接 fail，改用 `mktemp` + `2>${tmp_err}` 捕捉 stderr 再讀；(4) 多處 `printf '- name=...'` 與 `printf 'condition: ...'` 改加 `--` 前綴避免某些 shell 把 `-` 開頭的 format 視為選項。本批修復後腳本經 smoke test 通過：valid task constitution draft 進入後 exit 0，產出 pretty-printed JSON 於 `~/.cap/projects/<id>/constitutions/<task_id>.json`。

### Changed (binding fix carryover)
- `.cap.constitution.yaml`（自宿主憲法）`binding_policy.allowed_capabilities` 補上 `task_constitution_persistence`（v0.19.1 新增 capability 但漏接到 allowed_capabilities，導致使用 shell-bound persist step 的 workflow 仍會被 `blocked_by_constitution` 擋下）。

## [v0.19.1] - 2026-04-29

### Added
- `scripts/workflows/persist-task-constitution.sh` 新增 deterministic shell：把 supervisor 在 `draft_task_constitution` step 草擬的 Task Constitution JSON 從 `<<<TASK_CONSTITUTION_JSON_BEGIN>>>` fence 抓出，做最小 schema 驗證（required 欄位 / goal_stage enum），寫入 `~/.cap/projects/<project_id>/constitutions/<task_id>.json`；驗證或寫入失敗即 exit 40 halt 整個 task，不允許 AI fallback；對齊既有 `persist-constitution.sh` 的 fence / 退出碼 / pretty-print 慣例。
- `scripts/workflows/emit-handoff-ticket.sh` 新增 deterministic shell：依 task constitution 中 `execution_plan[target_step_id]` 條目展開單一 step 的 Type C handoff ticket（依 `schemas/handoff-ticket.schema.yaml`），落地至 `~/.cap/projects/<project_id>/handoffs/<step_id>.ticket.json`；同 step 重跑時檔名 seq 自動遞增（`<step_id>-2.ticket.json` / `<step_id>-3.ticket.json` ...），舊 ticket 保留作為審計痕跡；ticket 含 ticket_id / target_capability / rules_to_load / context_payload / acceptance_criteria / output_expectations / governance / failure_routing / budget_slot 等完整欄位。
- `schemas/capabilities.yaml` 新增 `task_constitution_persistence` capability（shell-bound）：與 `task_constitution_planning`（AI-bound 草擬）配對為 draft → persist 兩段式流程，對齊既有 `project_constitution` ↔ `constitution_persistence` 的設計模式。
- `policies/handoff-ticket-protocol.md` 新增跨 sub-agent 通用協議：定義所有非 supervisor sub-agent（02-TechLead 起到 99-Logger）在 workflow / spawn 模式下如何讀 Type C ticket、如何寫 Type D summary、如何處理失敗與 halt；明示「ticket 是統一派工載體，不取代各 agent skill 的 core mission」、「summary-first 預設，audit 類 step 才允許載 full artifact」、「ticket 結構錯誤時 halt 不修補 ticket 本身」等違規訊號。本政策搭配 `schemas/handoff-ticket.schema.yaml` 與 `01-supervisor-agent.md` §3.6 形成完整的派工側 + 接收側協議閉環。

### Changed
- `schemas/workflows/project-spec-pipeline.yaml` / `project-implementation-pipeline.yaml` / `project-qa-pipeline.yaml` 三條 workflow 的 `init_task` step 拆為 `draft_task_constitution`（executor: ai，capability: task_constitution_planning）+ `persist_task_constitution`（executor: shell，capability: task_constitution_persistence，script: scripts/workflows/persist-task-constitution.sh），每條 pipeline step 數各 +1（spec/impl 從 8 變 9，qa 從 5 變 6）；下游 step 的 `needs:` 全數改指向 `persist_task_constitution`，artifacts 區補 `task_constitution_draft`，logger_checkpoints 同步更新；目的是讓 init step 由純 AI 改為「AI 草擬 + 確定性持久化」兩段式，避免 AI 直接寫 runtime 路徑造成不可重現。
- `schemas/capabilities.yaml` 的 `handoff_ticket_emit` 的 binding 從 `default_agent: supervisor` 改為 `default_agent: shell`，`allowed_agents: [shell, supervisor]`：補完上一輪只宣告 supervisor 角色但沒有 shell 實作的缺口；後續 workflow 可顯式以 `executor: shell` + `script: scripts/workflows/emit-handoff-ticket.sh` 顯式 emit ticket，supervisor 在 ad-hoc 派工時仍可作為內部例行行為（per `01-supervisor-agent.md` §3.6）。
- `agent-skills/00-core-protocol.md` 在 §5.3「交接產出格式」末段加入引用：在 cap workflow / spawn 模式下，所有非 supervisor sub-agent 必須額外遵守 `policies/handoff-ticket-protocol.md`，依 ticket 的 `output_expectations.handoff_summary_path` 寫入 Type D 摘要、依 `acceptance_criteria` 自我驗收、依 `failure_routing` 回報失敗。

### Fixed
- `.cap.skills.yaml` 在 `builtin-supervisor.provided_capabilities` 補上 `task_constitution_planning` 與 `handoff_ticket_emit` 兩條 v0.19.0 新增的 capability：v0.19.0 把 capability 寫進 `schemas/capabilities.yaml` 卻忘了同步綁到 supervisor skill，導致 RuntimeBinder 解析這兩條 capability 時找不到對應 skill；此修復使 `project-spec-pipeline` / `project-implementation-pipeline` / `project-qa-pipeline` 三條 workflow 的 `init_task` step 不再卡 binding。
- `.cap.constitution.yaml`（自宿主憲法）在 `binding_policy.allowed_capabilities` 補上同兩條 capability：v0.19.0 後 protocols repo 自身若 dogfood 跑新 per-stage workflow 會被自宿主憲法擋下（`blocked_by_constitution`）；此修復讓 protocols repo 自己也能 dogfood 三條新 workflow。注意：此修復僅針對既有 repo；新專案透過 `project-constitution.yaml` workflow bootstrap 出的憲法會自動含這兩條 capability（因 `scripts/workflows/bootstrap-constitution-defaults.sh` 動態從 `schemas/capabilities.yaml` 抽取 allowed_capabilities）。

## [v0.19.0] - 2026-04-29

### Added
- `schemas/handoff-ticket.schema.yaml` 新增 Type C 派工單契約：定義 supervisor 派工給單一 step sub-agent 的「工作單」結構，覆蓋 ticket_id / target_capability / rules_to_load / context_payload（含 summary-first 與 full-artifact 雙路徑）/ acceptance_criteria / output_expectations / governance / failure_routing 等欄位，使派工痕跡從 Agent prompt 字串提升為磁碟上可審計、可重跑、跨 runtime 共用的檔案，落地路徑為 `~/.cap/projects/<id>/handoffs/<step_id>.ticket.json`。
- `schemas/capabilities.yaml` 新增 `task_constitution_planning` capability：明文化「由 supervisor 讀 Project Constitution 與使用者意圖，產出 Task Constitution（Type B）+ execution_plan」這個動作為一級 capability，作為 spec / implementation / qa 等 per-stage workflow 的固定第一步，提供 cap CLI 穩定的工作清單顯示與計時。
- `schemas/workflows/project-spec-pipeline.yaml` 新增 per-stage workflow（goal_stage: formal_specification）：把 Mode C 中 supervisor 的派工迴圈固化為 8 個確定性 step（init_task → prd → tech_plan → ba → dba_api ∥ ui → spec_audit → archive），覆蓋從專案憲法到完整可實作規格層的全部產出（5 份規格 + 6 份設計資產 + 2 份 watcher gate report + task archive）；watcher milestone gate 設於 tech_plan 與 spec_audit 兩處，dba_api 與 ui 平行展開，archive 由 supervisor in-line 執行不消耗 sub-agent budget。
- `schemas/workflows/project-implementation-pipeline.yaml` 新增 per-stage workflow（goal_stage: implementation_and_verification）：把規格層產出推進到可部署實作層的 8 個確定性 step（init_task → frontend ∥ backend → qa_testing ∥ security_audit → devops_packaging → impl_audit → archive），覆蓋 frontend / backend codebase + 單元測試 + QA 自動化套件（API 整合 / Playwright E2E / k6 perf / Lighthouse）+ 安全稽核 + 部署產物 + 終局 watcher gate；hard-依賴 spec-pipeline 11 個正式產出，缺任一即拒絕啟動；watcher milestone gate 設於 frontend / backend / impl_audit 三處，frontend ∥ backend 與 qa ∥ security 兩組各自平行；qa 或 security 觸發 FAIL 時 route_back_to 對應實作 step，CRITICAL/HIGH 安全漏洞必修不得進 devops_packaging。
- `schemas/workflows/project-qa-pipeline.yaml` 新增 per-stage workflow（goal_stage: implementation_and_verification 的驗證子集）：作為獨立 QA 與安全稽核循環的 5 個確定性 step（init_task → qa_testing ∥ security_audit → qa_audit → archive），與 implementation-pipeline 內嵌的 qa step 互補（後者是「實作完當下立即驗證」，本 workflow 是「實作後任何時間獨立重跑」）；典型場景包含 regression 驗證、定期 Lighthouse / 性能 / 安全 baseline、依賴升級後的安全稽核、release 前最後一道 cross-cutting 驗證；新增 verification_scope 參數可裁減為 regression / lighthouse_only / security_only / full_suite；QA 或 Security 找到問題不 route_back_to 實作 step（實作不在本 workflow 內），改為 escalate_user 讓使用者決定下一步路徑。
- `schemas/capabilities.yaml` 新增 `handoff_ticket_emit` capability：完成 Type C 派工單顯化的執行端契約。每個 sub-agent step 派工前，supervisor（或對應 deterministic 步驟）依 task constitution 的 execution_plan 條目展開單一 step 的 handoff ticket（落地至 `~/.cap/projects/<id>/handoffs/<step_id>.ticket.json`），給 RuntimeBinder 與 sub-agent 共讀；確立「ticket 必須在 spawn 之前落地」「重跑時 seq 遞增舊 ticket 保留」「context_payload 預設 summary-first」三條鐵則。與 `task_constitution_planning`（產 Type B）一起，補齊 spec / implementation / qa per-stage workflow 把 supervisor 派工迴圈完全顯化所需的最後一塊 capability 拼圖。

### Changed
- `agent-skills/01-supervisor-agent.md` 補齊 §3.2 / §3.6 / §3.7：§3.2 把派工協議的交接單欄位對齊 `schemas/handoff-ticket.schema.yaml`（Type C），明示 ticket 落地路徑與必填欄位；§3.6 新增「Type C Handoff Ticket 發行協議」章節，定義五條鐵則（落地優先於 spawn / 重跑 seq 遞增舊 ticket 保留 / context_payload summary-first 預設 / acceptance_criteria 對齊 done_when / failure_routing 不留空）；§3.7 新增「Mode C Conductor 綁定的協議落地」章節，明示 `policies/constitution-driven-execution.md` §1.3 的 binding rule 透過協議層三件事（workflow `owner: supervisor` / `task_constitution_planning` 的 default_agent / 本 agent skill §3 派工協議）自然落地，不需新 engine 程式碼，是 declarative 而非 imperative。
- `policies/constitution-driven-execution.md` 新增 §1.3「Mode C Conductor Binding」並連動更新 §2.1 與 §7：當專案根目錄存在 `.cap.constitution.yaml` 時，Mode C 的 conductor 由 cap runtime 改綁定至 01-Supervisor，由其依憲法守護跨 step 的長期 governance、避免 scope drift；無 project constitution 的 ad-hoc 任務憲章維持 cap runtime 主控，sub-agent prompt 模板、token 成本模型與跨 runtime 適配規則皆不變。

## [v0.18.1] - 2026-04-28

### Added
- `engine/design_prompt.py` 新增 `local-design` 設計來源類型、`--design-path PATH` 旗標與 `DEFAULT_DESIGNS_DIR = "~/.cap/designs"` 常數：planning workflow 在 TTY 反問階段可直接吃使用者放在本機 `~/.cap/designs/` 的設計稿 package，並由 `_resolve_default_design_package` / `_format_design_tree` / `_local_design_exists` 等輔助函式把目錄樹整理給 supervisor 觀看。互動模式下直接 Enter 即採用預設路徑，避免每次重打。
- `schemas/design-source-templates.yaml` 補上 `local-design` 儀式句模板、`design_path` required 欄位與對應 detection patterns，使 `design-source` 四類 SSOT 完整涵蓋 `none / local-design / claude-design / figma-mcp / figma-import-script`。

### Changed
- `install.sh` 在 `[2/4] 建立 CAP 本機儲存區` 步驟同時 mkdir `${CAP_HOME}/projects` 與 `${CAP_HOME}/designs`，與 `engine/design_prompt.py` 中只讀不建的 `DEFAULT_DESIGNS_DIR` 形成完整契約 — 建立由 install path 負責、消費由 prompt path 負責；老使用者跑 `cap update` 切到 v0.18.1 即會自動取得新目錄，不需重新 `cap init`，也不需手動 `mkdir`。

## [v0.18.0] - 2026-04-28

### Added
- 新增 `prompt_outline_normalize` capability：把使用者自由 prompt 拆成 scalar / array / object / Markdown 四向分流，作為憲章 / reconcile workflow 的前置防呆 step，避免 supervisor 在 draft 階段把多目標壓進 type:string 欄位導致 schema halt。
- `schemas/workflows/project-constitution.yaml` 與 `project-constitution-reconcile.yaml` 在 draft / reconcile 之前插入 `normalize_outline` step，draft / reconcile 改吃 `normalized_outline` + `schema_alignment_notes`。
- `agent-skills/01-supervisor-agent.md` 新增 Step 2.4「Prompt Outline Normalize 方法論」，定義 schema-aware 四向分流原則、north-star 濃縮規則、`needs_data` 標記紀律。
- `cap workflow run` 新增設計來源互動補強：`--design-source TYPE`、`--design-url`、`--design-figma-target`、`--design-script`、`--no-design` 旗標，以及在 TTY 環境下的反問機制（規劃型 workflow 限定）。
- 新增 `schemas/design-source-templates.yaml` SSOT 與 `engine/design_prompt.py` CLI helper：定義 `claude-design` / `figma-mcp` / `figma-import-script` / `none` 四種來源的儀式句模板與 detection patterns，供 CLI 拼裝 prompt 時用。

### Changed
- 將 `agent-skills/`、`policies/` 與 `workflows/` 從 `docs/` 拆出為 repo 根目錄的一級來源，讓 `docs/` 回歸 CAP 平台說明文件；同步更新 mapper、workflow executor、alias check、release scan、Claude/Codex 入口與 repo manifest 讀新一級路徑。
- `.cap.skills.yaml` 把 `prompt_outline_normalize` 註冊進 `builtin-supervisor.provided_capabilities`，讓 `normalize_outline` step 在 binding 階段直接 resolved 到 supervisor，不再 fallback 到 dba。
- `.cap.constitution.yaml` 把 `prompt_outline_normalize` 補進 `binding_policy.allowed_capabilities`，讓 bootstrap repo 自身也能通過新 workflow 的 preflight。
- `agent-skills/00-core-protocol.md` 與 `03-ui-agent.md` 同步 handoff / protocol-source 文件路徑引用，對齊新一級結構。

### Fixed
- `schemas/workflows/project-constitution.yaml` 在 `draft_constitution` step 加入 `project_goal` scalar guard：done_when 與 notes 明確要求 scalar 欄位（name / summary / project_goal）必須是單一字串，多層次目標應分流到 `summary` / `constraints` / `stop_conditions` / Markdown，避免再次踩到 `project_goal: expected type 'string', got 'dict'` 的 schema halt；同時把 supervisor 推理 timeout 從 180s 提到 300s，吸收長 prompt 的自然推理時間。
- `engine/design_prompt.py` 新增 `/dev/tty` fallback：cap-workflow.sh 用 pipe 餵 prompt 時 `sys.stdin.isatty()` 為 False，導致使用者在真實 terminal 反問機制被誤跳過；改由 `_open_tty` 取得 `/dev/tty` 讀寫 handle，互動 read 與訊息 write 都優先走 tty，CI / sandbox 等 `/dev/tty` 不可用環境仍 fallback 到既有非互動路徑。

## [v0.17.1] - 2026-04-27

### Added
- `scripts/workflows/persist-constitution.sh` 新增 `CAP_CONSTITUTION_DRY_RUN=1` 模式：覆寫前先輸出 unified diff 並 exit 0，不寫入 repo SSOT，提供 reconcile 前的事前審視能力。
- 覆寫路徑強制備份：執行覆寫前自動把既有 `.cap.constitution.yaml` 複製為 `.cap.constitution.yaml.backup-<TIMESTAMP>`，提供基本回滾路徑。

### Changed
- `schemas/workflows/project-constitution-reconcile.yaml` 的 persist step 顯化覆寫 contract：`notes` 明確列出 `CAP_CONSTITUTION_OVERWRITE` 注入機制、backup 行為與 dry-run 用法，讓 Watcher 與閱讀者能直接從 workflow 看懂行為。
- `project-constitution-reconcile` 的治理升級：`watcher_mode` 由 `final_only` 改為 `milestone_gate`，`watcher_checkpoints` 加入 `validate_constitution` 與 `persist_reconciled_constitution`，避免 SSOT 覆寫操作只有單一 checkpoint。
- 統一領域語彙：跨 workflow / capability / shell / 文件將原本混用的 `supplemental prompt` 與 `additional prompt` 統一為 `addendum`，並重命名 `load-constitution-reconcile-inputs.sh` 內的對應函式與輸出鍵（`addendum_source`）。

## [v0.17.0] - 2026-04-27

### Added
- 新增 `project-constitution-reconcile` workflow，用來吸收 addendum 後一次性重構既有 Project Constitution，避免把 addendum 直接寫進憲法本體。
- 新增 `constitution_reconciliation_inputs` 與 `constitution_reconciliation` capability，分別負責補充輸入整理與 AI 收斂草案。
- 新增 `workflows/project-constitution-addendum.example.md` 作為 addendum 的人工輸入範本。

### Changed
- `engine/runtime_binder.py` 新增 bootstrap override 路由，讓 project-constitution workflow 在 `.cap.constitution.yaml` 缺席時走專屬 bootstrap 路徑，避免無 SSOT 時誤觸常規 binding policy。
- `scripts/workflows/persist-constitution.sh` 與 `validate-constitution.sh` 強化覆寫保存與 schema 驗證流程，支援 reconcile 後的覆寫式持久化。

## [v0.16.0] - 2026-04-27

### Added
- Added input_mode: full to the vc_apply step in schemas/workflows/version-control.yaml so vc-scan handoff data can flow into the apply stage.
- Added policies/constitution-driven-execution.md to define the Mode C execution protocol and its planning and agent orchestration rules.
- Restored executable permissions on scripts/workflows/bootstrap-constitution-defaults.sh, persist-constitution.sh, validate-constitution.sh, and vc-scan.sh so the workflow helpers remain runnable.

### Changed
- 將版本控制模板收斂為單一 `version-control` workflow，原 quick / governed / company 差異改由 `strategy` contract 表達。
- `cap workflow run` 新增 `--strategy fast|governed|strict|auto` 語意；舊版 workflow 名稱僅作相容 alias。

## [v0.15.0] - 2026-04-26

### Added
- project-constitution workflow v3: 4-step bootstrap pipeline (bootstrap, draft, validate, persist) producing schema-valid .cap.constitution.yaml from a user prompt
- validate-constitution subcommand in engine/step_runtime.py with jsonschema validation and degraded required-field fallback
- three shell-bound capabilities in schemas/capabilities.yaml: bootstrap_platform_defaults, constitution_validation, constitution_persistence
- scripts/workflows/bootstrap-constitution-defaults.sh, validate-constitution.sh, persist-constitution.sh shell steps with explicit fence contract and runtime snapshot writer
- _bootstrap flag in engine/project_context_loader.py to signal an absent .cap.constitution.yaml, enabling deterministic bootstrap detection

## [v0.13.5] - 2026-04-26

### Changed
- 版本控制 workflow 改為 vc_scan(shell) → vc_compose(AI) → vc_apply(shell) 三段 pipeline，shell 不再猜 commit 語意、AI 不再重跑 git。
- vc-apply.sh 出口 lint 守門：subject 必須引用至少一個 changed path token（如 vc-scan、agent-skills、workflows），禁用 enforce / sync / refine / unify / streamline / consolidate / clarify / harden / strengthen / establish / introduce / govern / finalize / polish / adjust / tweak / optimize / enhance 等抽象主動詞，update / improve / refactor 後必須接具體名詞。
- vc-apply.sh 強制 annotation 採 `<tag> — <summary>` 格式，summary 也必須引用 path token；compose 擅自宣告 perform_release=true 但 scan release_intent=false 時直接 halt。
- 06-devops-agent.md §1.1 重寫為 vc_compose 工作規範：禁止重跑 git、必須讀 evidence pack、產出符合 envelope schema 的 JSON。
- 刪除舊版單檔版本控制 shell executor（401 行 grep 規則樹），改由 vc-scan.sh + vc-apply.sh 取代。
- 保留 cap release-check / cap version（原 v0.15.0 工作項）作為發版 sanity 工具，未來在 vc-apply 之外的 release 流程引用。
## [v0.13.4] - 2026-04-26

### Changed
- update docs workflow assets
## [v0.13.3] - 2026-04-25

### Added

- 版本控制 workflow 明確發版時改由 DevOps AI fallback 進行 diff 語意審查，避免 shell 自動產生機械式 commit message 與 release notes

### Changed

- 更新 DevOps agent 版本控制規範，要求 release fallback 先掃描 `git status`、`git diff --stat` 與 `git diff`，再同步 `CHANGELOG.md` / `README.md`、建立 annotated tag 並依 upstream 推送
- 調整私人版控 shell executor：偵測到明確 release / tag / CHANGELOG / README 意圖時只回報掃描證據與建議 tag，交由 AI fallback 完成發版語意判讀

## [v0.13.2] - 2026-04-25

### Changed
- update schemas workflow assets
## [v0.13.0] - 2026-04-25

### Added

- 新增 `executor: shell` workflow step metadata、script 白名單與 AI fallback 設定，支援 hybrid executor 流程
- 新增 `policies/workflow-executor-exit-codes.md`，定義 shell executor 與 workflow runtime 的退出碼契約
- 新增早期版本控制 shell executor 與 `schemas/workflows/test/version-control-test.yaml`，作為私人版控 quick path 與 hybrid executor fixture

### Changed

- 版本控制 workflow 升級為 v4，改為 shell quick path 優先，僅在語意不明、混合變更或 git 操作失敗時回流 DevOps AI
- `WorkflowLoader`、`RuntimeBinder`、`step_runtime` 與 `cap-workflow-exec.sh` 同步保留並執行 shell executor / fallback metadata
- workflow 文件與核心協議補齊 shell executor 治理、fallback 與 sensitive risk halt 規則

## [v0.12.0] - 2026-04-24

### Added

- 新增 repo 級 `Project Constitution` 與 skill registry 正式來源：`.cap.constitution.yaml`、`.cap.skills.yaml`
- 新增 `engine/project_context_loader.py`，集中載入 `.cap.project.yaml` 與 `Project Constitution`

### Changed

- `RuntimeBinder` 會套用 `binding_policy.defaults`、限制 `allowed_capabilities`，並驗證 workflow 來源目錄是否符合 constitution
- `TaskScopedWorkflowCompiler` 與 workflow CLI 報表會攜帶 `project_context`，讓 compile / bind / constitution 輸出可追蹤 repo 級治理來源
- `README.md`、`repo.manifest.yaml`、`.cap.project.yaml` 與 `TODOLIST.md` 同步更新，明確區分平台內建資產、repo 正式來源與 runtime workspace

## [v0.11.1] - 2026-04-24

### Changed

- `engine/workflow_cli.py` 追加 workflow binding / constitution / compile 的報表輸出子命令
- `scripts/cap-workflow.sh` 改為直接呼叫 `engine/workflow_cli.py`，移除剩餘 inline Python heredoc

## [v0.10.3] - 2026-04-24

### Fixed

- workflow executor 的 `printf` 修正 ANSI escape codes 未正確渲染的問題

### Changed

- workflow run 終端輸出格式改善，提升可讀性

## [v0.10.2] - 2026-04-24

### Fixed

- CLI 子命令語意釐清：移除歧義的 `cap list`，強制使用 `cap skill list` / `cap workflow list`
- `cap workflow list` 恢復 `wf_` 短 ID 顯示
- `cap workflow ps` 新增 zombie run 偵測，自動標記超時或孤兒 workflow run
- `cap workflow help` 清理未實作的 `-d` flag，補齊 `--cli` 文件
- `RuntimeBinder` 解除 workflow version 3 在 legacy adapter 與 skill registry 的阻斷
- workflow executor 在 step prompt 強制注入文字輸出指引，修正 empty_capture 問題
- 非互動模式輸出要求移入 workflow notes，避免汙染 step contract

### Changed

- 版本控制 workflow 精簡為單一 step，合併 tag 判定、changelog 同步與 commit/tag 操作

## [v0.10.1] - 2026-04-24

### Changed

- schemas 從 7 份收斂為 3 份現役 schema（`capabilities.yaml`、`skill-registry.schema.yaml`、`task-constitution.schema.yaml`），移除冗餘定義

## [v0.10.0] - 2026-04-24

### Changed

- workflow 產品組合收斂為 `workflow-smoke-test`、`readme-to-devops` 與版本控制相關現役模板
- `README.md`、workflow 文件與架構說明改為只描述現役 workflow，移除已淘汰模板的正式入口與引用
- supervisor 啟動提示不再在缺少 workflow 時預設套用大型流程，改為先選擇最小可行 workflow

### Removed

- 移除 `schemas/workflows/feature-delivery.yaml`
- 移除 `schemas/workflows/small-tool-planning.yaml`

## [v0.9.0] - 2026-04-24

### Added

- 版本控制 workflow 新增 `prepare_release_docs` 階段，將 tag 判定與 release 文件同步前移到 commit 之前
- workflow executor 會在 step prompt 中注入 `repo_changes`、`project_context` 與 step contract 摘要，讓 summary 模式可直接消化必要 metadata

### Changed

- `version_control_tag` capability 契約改為區分 commit 前的 release 文件同步與 commit 後的 tag 建立流程
- `RuntimeBinder`、`WorkflowLoader` 與相關文件同步保留 `done_when` / `notes` metadata，改善 workflow handoff 與執行期可追溯性
- README、workflow 文件與 manifest 同步更新 CAP CLI 指令與私人版控流程說明

### Fixed

- `cap-workflow-exec.sh` 在 detached HEAD 狀態下會阻擋 `version_control_commit` / `version_control_tag`，避免在錯誤 ref 上建立 release commit 或 tag
- 修正 workflow intrinsic `commit_scope` 解析，讓 staged file list 可以穩定傳入版本控制 step

## [v0.6.6] - 2026-04-23

### Changed

- 合併本地 `main` 與 `origin/main`，統一本地 workflow 前景執行語意與遠端 workflow run instance 追蹤模型
- `cap workflow run` 保留互動式 prompt 與 `--dry-run`，同時支援 `run_id` 狀態更新與 `inspect` 查詢

### Fixed

- 納入 Windows 開發相容性修正：補齊 LF / EOL 正規化、跨平台 shell 同步與 `.codex` sentinel ignore 調整
- 修正 `cap-workflow-exec.sh` 寫入 workflow status 時與新版 `workflow-runs.json` 結構不相容的問題

## [v0.4.1] - 2026-04-21

### Fixed

- 修正 shell wrapper 安裝行為：在寫入 `cap` / `codex` / `claude` function 前先 `unalias`，避免 zsh 在 `cap update` 後 `source ~/.zshrc` 出現 alias 衝突與 parse error

## [v0.4.0] - 2026-04-21

### Added

- 新增 `101-readme-agent` 選配 Agent，負責 README 標準化、Repo Intake 與文件結構化
- 新增 `readme-governance.md` README 治理規範與 `repo.manifest.example.yaml` Manifest 範本
- 整合 Lighthouse audit 策略至 QA / SRE / Troubleshoot / Supervisor 流水線
- `cap help` 正式化，雙寫 trace（plain text + JSONL）
- 新增 CAP runtime storage（`~/.cap/projects/<project_id>/`）
- 新增 tag-aware release 機制：`cap version`、`cap update [target]`、`cap rollback <tag>`
- 新增 promote 流程：`cap promote list`、`cap promote <src> <dst>`
- 新增 agent registry：`.cap.agents.json`

### Changed

- 預設 trace / report 輸出從 repo 內 `workspace/history` 轉為本機 CAP storage
- 更新 install 與 CLI 文件，對齊 runtime storage、registry 與 release control

### Fixed

- 修正 `101-readme-agent` 預設行為：強制依情境路由（A/B/C），禁止無條件 fallback 到 front matter

## [v0.3.0] - 2026-04-20

### Added

- `cap codex` / `cap claude` trace-aware session wrappers，自動記錄 session ID、執行時間與結果
- 新增 `cap-session.sh` 與 `trace-log.sh`，支援 plain text + JSONL 雙格式 trace

### Changed

- 強化 Frontend Agent (04) 交接與稽核規則：補齊 Analytics 阻斷條件、設計資產對齊、logging handoff 要求
- 釐清 Agent 顯示順序（README 與 agent-skills README）

## [v0.2.1] - 2026-04-20

### Added

- 新增 `10-troubleshoot-agent` 系統故障排查與維護專家，支援五層診斷、根因分類與分流路由
- 新增 `12-figma-agent` 設計同步代理，支援 MCP / import_script 兩種同步模式
- `03-ui-agent` 新增第一階段可維護設計資產輸出（`tokens.json` / `screens.json` / `prototype.html`）
- `ARCHITECTURE.md` 新增 DDD 整合策略與演進路線圖

### Changed

- Supervisor (01) 整合 Troubleshoot 診斷報告的接收與分流路由規則
- 統一 Supervisor / Tech Lead / BA / DBA / SRE / Logger 交接摘要欄位與紀錄模式
- Logger (99) 升級為分級紀錄機制（`trace_only` / `full_log`）
- 釐清 troubleshoot 必須回交 supervisor，而不是直接形成正式派單

### Fixed

- 修正跨平台 shell 同步腳本的相容性問題
- 正規化全 repo 行尾符號（CRLF → LF）

## [v0.2.0] - 2026-04-17

### Added

- 在 BA / DBA / Backend / Watcher 中導入 DDD 戰術模式：Aggregate Root、Value Object、Domain Event
- BA (02a) 新增 Bounded Context 識別與領域語彙鎖定（Ubiquitous Language）
- DBA (02b) 強制標示 Aggregate Root / Entity / Value Object 分類與跨 Aggregate 引用
- Backend (05) 強制 Value Object 不可變建模與 Domain Event 協調機制
- Watcher (90) 新增 DDD 邊界稽核清單（Aggregate Root 守門、語彙一致性、跨 Context 驗證）

## [v0.1.0] - 2026-04-17

### Added

- 新增 `02-techlead-agent` 技術總監角色，負責模組級技術評估與派發建議
- 新增 `09-analytics-agent` 產品數據與實驗分析師（KPI Tree、Event Taxonomy、Funnel Mapping、A/B Test）
- 新增前後端單元測試策略（`unit-test-frontend.md` / `unit-test-backend.md`）
- Watcher (90) 新增開發者單元測試稽核區塊（測試檔存在性、Mock 隔離合規、核心邏輯覆蓋）
- DBA (02b) 新增 DBML / Mermaid 可視化渲染提示（dbdiagram.io / mermaid.live）
- `check-aliases.sh` 腳本驗證 Agent alias 映射正確性

### Changed

- Agent 數量從 11 升至 13（新增 Tech Lead + Analytics）
- 更新所有跨 Agent 引用中的過時 SA 參照為 BA / DBA

### Fixed

- 修正多段 Agent prefix（02a / 02b）的短名 alias 解析
- 修正全部 shell 腳本 CRLF → LF
- 修正 CLAUDE.md / AGENTS.md / rules 中的過時檔名引用
- 修正舊 SA / schema 參照與 agent-skills 文件對齊問題

## [v0.0.2] - 2026-04-17

### Changed

- 將 SA Agent (02) 拆分為 BA 業務分析師 (02a) + DBA/API 架構師 (02b)，分離業務流程分析與資料庫 / API 設計職責
- 核心協議 (00) 新增「協議來源唯讀」規則，禁止 Agent 反向修改 `charlie-ai-protocols` 規則來源檔

## [v0.0.1] - 2026-04-16

### Added

- CAP CLI 整合層：`CLAUDE.md`、`AGENTS.md`、`mapper.sh` 多工具適配（Claude Code / Codex / CrewAI）
- `Makefile` 統一入口：`cap setup` / `cap sync` / `cap install` / `cap list` / `cap run`
- 全域安裝支援：`cap install` 部署至 `~/.agents/skills/`、`~/.claude/` 與 `~/.codex/`
- Claude Code 全域部署（`mapper.sh --global`），自動寫入 `~/.claude/CLAUDE.md` 與 `~/.claude/rules/`
- 短名 alias 機制（`qa.md` → `07-qa-agent.md`）供 `$qa` 指令快速呼叫
- `install.sh` 一鍵安裝腳本 + `cap update` 遠端同步命令
- Shell wrapper 函式（`cap` / `codex` / `claude`）自動注入 `~/.zshrc` 或 `~/.bashrc`
- `policies/git-workflow.md` 版本控制與 PR 規範
- `docs/ARCHITECTURE.md` 架構設計文件

### Changed

- Makefile help 輸出改為顯示 `cap` 前綴，而不是 `make`

### Fixed

- 修正 `ln -sf` 防止重複安裝時的 `File exists` 錯誤

## [v0.0.0-rc] - 2026-04-14

### Changed

- 統一所有 Agent 檔案命名為 `*-agent.md`，供 `factory.py` glob 自動發現
- CrewAI 引擎升級至 v1.14，修正 agent filtering 邏輯
- 移除冗餘 IDE 靜態 prompt 檔案，精簡 repo 結構
- 保留 legacy `workspace/` 目錄結構（via `.gitkeep`）

## [v0.0.0-beta] - 2026-04-13

### Added

- 完成 11 個核心 Agent 定義（01 Supervisor → 99 Logger）
- QA Agent (07) 稽核與測試策略（Playwright POM + k6 Thresholds）
- Security Agent (08) 安全審查工作流（OWASP Top 10、IDOR、Zero Trust）
- SRE Agent (11) 效能與可靠性標準（探針設計、快取防禦、資源配額）
- CrewAI 引擎 bootstrap（`engine/main.py` + `factory.py`）
- Logger (99) 執行軌跡格式定義（Trace Log + Devlog + Changelog 三級機制）
- Frontend 框架策略文件（`frontend-angular.md` / `frontend-nextjs.md` / `frontend-nuxtjs.md`）

## [v0.0.0-alpha] - 2026-04-04

### Added

- 初始化 AI 多代理協作協議架構
- 核心協議 `00-core-protocol.md`（全域憲法：角色認知、溝通協議、工作區禮儀、自我反思迴圈）
- 初始 Agent 文件原型（Supervisor、Frontend、Backend、DevOps、QA、Watcher、Logger）
- `init-ai.sh` 角色分派與框架策略選擇腳本
- 引擎執行規則與自我審查機制
