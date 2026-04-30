# Changelog

All notable changes to this project will be documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/). Commit types follow [Conventional Commits](https://www.conventionalcommits.org/) as defined in `policies/git-workflow.md`.

---

## [Unreleased]

### Fixed
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
