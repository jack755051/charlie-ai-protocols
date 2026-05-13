# Component Feedback Widget Dogfood Log — 2026-05-13

> Status: live dogfood log.
> Subject: `~/Desktop/01_private/cap-test/component-feedback-widget`.
> Goal: exercise CAP project-constitution and follow-on component repo workflows against a reusable feedback widget component.

## Target Constitution

The intended project constitution should preserve these inputs:

- `project_id`: `component-feedback-widget`
- repo type: Component Repo, not a full product
- primary stack: Next.js 14, C#/.NET 8, PostgreSQL 16, Docker Compose
- frontend adapter: shadcn-ui + Tailwind CSS + Lucide
- backend core: `IFeedbackStore`
- default storage: `InMemoryFeedbackStore`
- PostgreSQL scope: integration-runtime only
- explicit exclusion: do not add Redis
- all ports and endpoints must be env/config driven, not hardcoded
- component template contract: component-core, component-frontend (`frontend-core`, `frontend-ui`), component-backend, component-demo, integration-runtime; async-runtime optional but unused

## Failure Log

| # | Time | Command / phase | Symptom | Root Cause | Status / Follow-up |
|---:|---|---|---|---|---|
| 1 | 2026-05-13 09:05–09:10 Asia/Taipei | `cap workflow run --cli claude project-constitution ...` pre-run / binding | `cap-paths: project_id collision detected`, resolved id was `project-constitution-bootstrap`, ledger origin was `charlie-ai-protocols`, current origin was `component-feedback-widget` | `scripts/cap-workflow.sh` forced `CAP_PROJECT_ID_OVERRIDE=project-constitution-bootstrap` for every `project-constitution` run when no explicit override was present. That made real dogfood repos collide with a historical bootstrap ledger instead of using their own git basename / config id. | Fixed locally in `scripts/cap-workflow.sh`: only fall back to bootstrap id when `cap-paths get project_id` exits 52. Added regression to `tests/scripts/test-cap-workflow-static-outside-project.sh`. |
| 2 | 2026-05-13 09:19 Asia/Taipei | Phase 2 `normalize_outline` | Claude step was killed after 241s with `step exceeded the hard execution limit of 240s` | Workflow step timeout is too tight for long component-constitution prompts under Claude. This is a runtime tuning / workflow contract issue, not a project_id or constitution-content issue. | Open follow-up: raise `normalize_outline.timeout_seconds` for `project-constitution`, or run dogfood with `CAP_WORKFLOW_STEP_TIMEOUT_SECONDS=600` until the workflow default is tuned. |
| 3 | 2026-05-13 10:51 Asia/Taipei | `project-implementation-pipeline` / `run_20260513105154_6eec0c36` phase 1 `draft_task_constitution` | The run produced only `1-draft_task_constitution.md` and its handoff, did not create `persist_task_constitution` output, and did not persist `component-feedback-widget-impl-2026-05-13.json`. `runtime-state.json` stayed empty. | The AI handoff used localized result text (`- **result**: 成功`). `engine/step_runtime.py parse-step-result` returns `state=unknown` for this artifact because it only accepts the machine-readable result contract outside JSON/code fences. This blocks the pipeline before downstream shell persistence. The missing final failure log is a separate observability gap. | Fix needed: enforce/normalize AI handoff result to `result: success` (English enum) or teach `parse-step-result` to accept localized/markdown-bold result labels. Also make workflow logs record the hard-fail path before halt. |
| 4 | 2026-05-13 11:03 Asia/Taipei | `project-implementation-pipeline` / `run_20260513110312_2052b7a8` phase 2 `persist_task_constitution` | Phase 1 passed after 228s, but phase 2 halted after 1s with `reason: schema_validation_failed`. No task constitution was persisted. | The drafted Task Constitution JSON used invalid `execution_plan[*].on_fail` values such as `route_back_to:step_03_backend_impl` and `route_back_to:step_04_frontend_impl`. `schemas/task-constitution.schema.yaml` only allows `on_fail` enum values `halt`, `route_back_to`, `retry`, `escalate_user`; the target step must be expressed separately as `route_back_to`. Secondary observability issue: workflow-result fallback still emitted `sessions/1/result: 'failed' is not one of ['success', 'failure', 'partial', None]`. | Fix needed: strengthen `task_constitution_planning` prompt/validator examples so route-back is emitted as `on_fail: route_back_to` + `route_back_to: <step_id>`, and add regression for persist rejecting/normalizing compound on_fail values. Also fix workflow-result enum drift from `failed` to `failure`. |
| 5 | 2026-05-13 11:49 Asia/Taipei | `project-implementation-pipeline` / `run_20260513114937_febc776f` phase 3 `emit_backend_ticket` | Phase 1 and phase 2 passed, but phase 3 halted immediately with `ERROR:step_not_in_execution_plan:backend`. | The persisted Task Constitution used dynamic vertical-slice step ids (`step_02_backend_module`, `step_03_frontend_core`, etc.) while the fixed workflow runtime derives target ids from `emit_<step>_ticket`, e.g. `backend` and `frontend`. `emit-handoff-ticket.sh` requires `execution_plan[].step_id == backend`, so it could not find a matching entry. This exposes a contract gap: Task Constitution is being treated as a free orchestration DSL, but `project-implementation-pipeline` is a fixed workflow graph. | Fixed locally after this run: `persist-task-constitution.sh` canonicalizes implementation plans to fixed workflow step ids (`frontend`, `backend`, `qa_testing`, `security_audit`, `devops_packaging`, `impl_audit`, `archive`) and merges dynamic same-capability details into those entries. Added regression Case 12 and verified replay of this run's draft can emit `backend.ticket.json`. |
| 6 | 2026-05-13 14:50 Asia/Taipei | `project-implementation-pipeline` / `run_20260513145013_e529c48a` phase 4 `backend` | Phases 1-3 passed and backend produced artifacts under the run output, including `code/backend/Feedback/...`, but the workflow did not proceed to `frontend`. The run has no `result.md` / `workflow-result.json`, no `4-frontend.md`, and `agent-sessions.json` leaves backend as `lifecycle=running`, `result=pending`. | `4-backend.md` emitted `result: success` inside a fenced YAML block. `engine/step_runtime.py parse-step-result` intentionally ignores result lines inside JSON/code fences and returns `state=unknown`, `reason=no result: line found outside JSON / code fences`. This is a CAP result-contract / materialization bug plus an observability gap: the runner did not leave a clear final failure record for the halted backend step. | Fix needed: enforce or normalize the final machine-readable result marker outside fenced blocks, or safely extract the final YAML handoff result before classification. Add regression using the `4-backend.md` shape. Also ensure unknown-result hard-fail updates workflow log and session state instead of leaving `running/pending`. |
| 7 | 2026-05-13 16:26 Asia/Taipei | `project-implementation-pipeline` / `run_20260513162647_dc50c1a5` phase 1 `draft_task_constitution` | Phase 1 wrote `1-draft_task_constitution.md` and a valid-looking handoff, but runtime did not advance to `persist_task_constitution`. `runtime-state.json` remained empty and workflow log only recorded `action:start`. | The handoff result line was emitted as ``- `result`: success``. The parser accepted bold labels (`**result**`) and plain labels, but did not accept markdown-backticked labels, so `parse-step-result` returned `state=unknown`. This is another CAP result-contract tolerance bug plus the same missing final failure-state observability gap. | Fixed locally after this run: `engine/ai_step_result_parser.py` now accepts backticks around the `result` label, and `tests/scripts/test-ai-step-result-parser.sh` adds `3j-backticked-label`. |

## Performance Observations

| # | Time | Run | Result | Observed Cost | Dogfood Finding | Follow-up |
|---:|---|---|---|---|---|---|
| 1 | 2026-05-13 10:04 Asia/Taipei | `project-constitution` / `run_20260513100402_3e05ca3b` | success, 5/5 phases | 183s | Constitution generation succeeded, but even the smallest component-repo bootstrap requires multiple AI phases. This is acceptable for governance quality, but too expensive as the default path for a simple reusable component. | Add a lightweight component constitution path or cached template bootstrap path that avoids full multi-agent expansion when the prompt maps cleanly to a known component template. |
| 2 | 2026-05-13 10:13 Asia/Taipei | `project-spec-pipeline` / `run_20260513101332_d9a8da60` | success, 16/16 effective steps reported under 13 phases | 1743s; roughly half of a 5x-max Claude usage budget by user observation | Full spec pipeline is too heavy for a simple component. The 11 required upstream artifacts make sense for product-scale work, but they create excessive wall time and token burn for small component repos. | Introduce a component fast path: collapse BA/schema/API/UI/spec audit into a deterministic template-driven package where possible, and reserve full spec pipeline for novel or ambiguous systems. |

## Historical Findings To Fold Into Fix Plan

These findings came from earlier dogfood attempts and should remain in the same repair stream instead of being treated as separate ad hoc issues.

| # | Finding | Classification | Current Status | Fix Track |
|---:|---|---|---|---|
| 1 | Constitution content quality was correct: `project_id: component-feedback-widget`; summary captured Component Repo, Next.js 14, .NET 8, PostgreSQL 16, shadcn-ui, `IFeedbackStore`, no Redis; constraints were complete. | Positive control | Keep as baseline | Use this as the regression target: CAP should preserve constitution quality while reducing token/time cost and avoiding downstream contract failures. |
| 2 | `cap-paths.sh` climbs to git top-level when cwd is inside a git repo and can ignore a subdirectory `.cap.project.yaml`, causing confusing project-id collision behavior. | CAP correctness / path-resolution bug | Still open as broader path quirk; separate forced-bootstrap collision was fixed in `3e1dd2e`. | Add issue/fix for nearest-project-config precedence or explicit subproject mode; include regression with nested `.cap.project.yaml`. |
| 3 | `run_step_claude` argv ordering bug: `claude -p --allowed-tools "..." "<prompt>"` on Claude 2.1.138 can swallow the positional prompt; stdin feeding is the correct path. | CAP provider adapter bug | Fixed previously | Keep regression coverage around stdin prompt delivery for Claude steps. |
| 4 | Workflow result enum drift: runtime/fallback emits `result: failed`, but schema expects `failure`, causing fallback log / workflow-result schema validation failure. | CAP observability/schema bug | Still open; reproduced again in implementation run `run_20260513110312_2052b7a8`. | Normalize runtime session result to `failure` or update schema consistently; add workflow-result schema regression. |
| 5 | No automatic extraction/alignment from user prompt into mkdir / project id override / target repo setup; user has to manually align prompt, directory, and overrides. | CAP onboarding / UX bug | Open | Add prompt-to-project bootstrap helper or preflight suggestion that derives project id and detects mismatch before workflow run. |
| 6 | Terminal long-paste line wrapping / continuation slicing is a user terminal paste-mode issue, not CAP correctness, but it amplifies dogfood friction. | Environment / UX friction | Open as documentation/preflight note | Document safer input paths: prompt file, `--prompt-file`, heredoc-safe wrapper, or CAP-managed prompt capture. |

## Immediate Workarounds

For the next dogfood attempt, use a higher per-step timeout:

```bash
CAP_WORKFLOW_STEP_TIMEOUT_SECONDS=600 \
cap workflow run --no-design --cli claude project-constitution "<prompt>"
```

If a run leaves partial local output in the dogfood repo, remove only the failed runtime residue after checking it:

```bash
rm -rf project-constitution/
```

## CAP Fixes Already Version-Controlled

Committed and pushed in `3e1dd2e` (`fix(workflow): patch cap-workflow dogfood identity collision`):

- `scripts/cap-workflow.sh`
  - Stops forcing the bootstrap project id for `project-constitution` inside real git repos.
- `tests/scripts/test-cap-workflow-static-outside-project.sh`
  - Reproduces a colliding bootstrap ledger and asserts a dogfood git repo uses its own project id.

## Current CAP Fixes Not Yet Version-Controlled

- `engine/ai_step_result_parser.py`
  - Accepts markdown-bold result labels such as `- **result**: 成功`, which occurred in `project-implementation-pipeline` run `run_20260513105154_6eec0c36`.
  - The old parser returned `state=unknown`; after the fix the same artifact returns `state=success`, `raw_value=成功`.
  - Accepts `result: success` inside a final fenced YAML handoff block after `## 交接摘要` / `## Handoff Summary` when no outside-fence result line exists, fixing run `run_20260513145013_e529c48a` phase 4 `backend`.
- `agent-skills/01-supervisor-agent.md`
  - Replaces the stale supervisor handoff example `result: [成功 | 失敗 | 待確認]` with the machine-readable contract `result: success` / `failed` / `blocked` / `needs_data`.
- `agent-skills/00-core-protocol.md`
  - Documents the preferred outside-fence `result:` line and the YAML handoff compatibility fallback.
- `docs/cap/AI-STEP-RESULT-CONTRACT.md`
  - Documents the YAML handoff compatibility fallback while preserving generic JSON/code fence isolation.
- `tests/scripts/test-ai-step-result-parser.sh`
  - Adds regression coverage for `- **result**: 成功`.
  - Adds regression coverage for fenced YAML handoff fallback and non-handoff YAML fence isolation.
- `scripts/workflows/persist-task-constitution.sh`
  - Canonicalizes implementation-stage dynamic execution plans to the fixed `project-implementation-pipeline` runtime step ids so `emit_backend_ticket` / `emit_frontend_ticket` can resolve their target entries.
- `schemas/workflows/project-implementation-pipeline.yaml`
  - Documents that Task Constitution `execution_plan.step_id` must use the workflow's fixed ids, not arbitrary vertical-slice ids.
- `tests/scripts/test-persist-task-constitution.sh`
  - Adds regression Case 12 for dynamic implementation step ids canonicalizing to fixed workflow ids.

Validation already run:

```text
bash tests/scripts/test-ai-step-result-parser.sh
# ai-step-result-parser: 41 passed, 0 failed

bash tests/scripts/test-ai-step-result-workflow-integration.sh
# ai-step-result-workflow-integration: 8 passed, 0 failed

bash tests/scripts/test-persist-task-constitution.sh
# Summary: 39 passed, 0 failed

bash tests/scripts/test-emit-handoff-ticket.sh
# Summary: 19 passed, 0 failed

Replay against run_20260513114937_febc776f/1-draft_task_constitution.md
# persist_task_constitution: condition ok
# emit_backend_ticket: condition ok, backend.ticket.json emitted
```

## Dogfood Policy

Every failed attempt on this repo should append one row to `Failure Log` before retrying. Include:

- timestamp
- command or phase
- observable symptom
- suspected root cause
- whether it is user environment, provider behavior, workflow tuning, or CAP correctness bug
- workaround or required fix
