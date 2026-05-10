# Changelog

All notable changes to this project will be documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/). Commit types follow [Conventional Commits](https://www.conventionalcommits.org/) as defined in `policies/git-workflow.md`.

---

## [v0.26.0] - 2026-05-10

> Minor release — **Round 1 of the bug #12 fix series ("Honest Workflow Result")**, surfaced by the 2026-05-10 component-repo dogfood Phase F. Pre-v0.26.0, `cap-workflow-exec.sh` graded any AI step that exited 0 with non-empty stdout as `ok`, which meant a Phase D run whose AI agents universally self-reported `blocked_read_only` / `FAIL_BLOCKED_*` / `needs_data` inside their markdown bodies still rolled up to `final_state=completed / 15/15 PASS`. The runtime hallucinated success against a run that produced no actual implementation code. v0.26.0 closes the perception gap: a structured AI step result contract, a parser that normalizes the four canonical states, and a workflow runtime gate that halts on anything other than `success`.
>
> The Round 1 scope is deliberate: **fix the runtime's perception of step outcome**, leaving the AI write contract (where agents are allowed to land code, how the harness sandbox is configured) for Round 2. After v0.26.0 lands, Phase D-style runs will correctly halt at the first AI step that hits the read-only sandbox instead of completing as a phantom success.

### Added

- `docs/cap/AI-STEP-RESULT-CONTRACT.md` (new): normative spec for the `result:` line every AI sub-agent step must emit. Defines the four normalized states (`success` / `failed` / `blocked` / `needs_data`), the alias table (case-insensitive, substring-tolerant for the `blocked_*` / `FAIL_BLOCKED*` family), the line-level grammar (ASCII or fullwidth colon, optional bullet, optional bold/backticks, trailing comment ignored), the fence-isolation rules (`result:` inside `<<<...JSON...>>>` or ```` ``` ```` blocks is ignored), the `unknown` → `failed` fallback, and the per-state workflow runtime behaviour table.
- `engine/ai_step_result_parser.py` (new): pure read-only parser. Walks step output line-by-line tracking fence depth so JSON / code-fence `result:` keys don't pollute the lookup; **last occurrence wins** so AI agents that quote upstream `result:` values in reasoning sections don't disturb the trailing handoff summary; normalizes raw values to one of the five enum states.
- `engine/step_runtime.py parse-step-result <step_output_path>` subcommand: shell-friendly key=value emission (`state=` / `raw_value=` / `line_number=` / `reason=`) for `cap-workflow-exec.sh` consumption. Exits 0 even on `unknown` so the shell can branch on value rather than rc.
- `scripts/cap-workflow-exec.sh AI_RESULT_HARD_FAIL` branch: post-step parser hook firing only when `effective_executor == ai` and the validator branch hasn't already hard-failed. Non-success states convert to a hard failure with `record_blocked_step` + `register_step_runtime_state blocked` + `SHOULD_HALT=1` (when the step is non-optional). Defence-in-depth gate on the success block: now requires both `VALIDATOR_HARD_FAIL == 0` AND `AI_RESULT_HARD_FAIL == 0`.
- `agent-skills/00-core-protocol.md` §5.3.1 (new sub-section): locks the `result:` enum at the global protocol layer so every agent inherits the contract without per-agent edits. Documents the four allowed values + alias table, the fence rules, the discipline against false-positive `success` reporting, and pointers at the parser / CLI / workflow integration / regression test paths.
- `tests/scripts/test-ai-step-result-parser.sh` (new, 40 cases): end-to-end coverage of the contract — primary spellings (4), alias normalization across all four states (16 sub-cases), line-level grammar (8 sub-cases including ASCII/fullwidth colons, dash/star bullets, bold markers, backticked values, trailing comments), last-occurrence wins, three fence-isolation cases (JSON fence, constitution fence, fenced-then-real outside), three failure modes (no result line, unparseable value, missing file), four CLI integration assertions.
- `tests/scripts/test-ai-step-result-workflow-integration.sh` (new, 8 cases): structural lint that the parser is wired into `cap-workflow-exec.sh` — counts `AI_RESULT_HARD_FAIL` references, confirms the success block requires both hard-fail flags to be 0 (defence-in-depth gate), exercises the parser against a fixture mirroring the 4-backend.md `blocked_read_only` shape from the dogfood + a Phase D `FAIL_BLOCKED_*` shape, locks the AI-only branch (gate fires only when `effective_executor=ai`).
- `scripts/workflows/smoke-layer.sh` runtime suite: append both new fixtures.

### Verified

- `test-ai-step-result-parser.sh` **40 / 40** PASS.
- `test-ai-step-result-workflow-integration.sh` **8 / 8** PASS.
- smoke-layer contracts **7 / 7**, runtime **19 / 19** (17 prior + 2 new), promote **6 / 6** PASS.
- Reverse-validation: re-running the parser against the actual Phase D dogfood run dir fixtures (`run_20260510163740_9bea7f25/4-backend.md`, `4-frontend.md`, `6-qa_testing.md`, etc.) returns `state=blocked` for every step that self-reported `blocked_read_only` / `FAIL_BLOCKED_*` — matching the closeout's bug #12 ledger row exactly.

### Boundary

- **Round 1 only** of the v0.26.x series. The AI write contract (Round 2) is **not** in this release. After v0.26.0, an AI step that hits a read-only sandbox will correctly report `blocked` and halt the workflow; it still won't produce code. The "where can AI write" question is the next design item.
- One behavioural change: workflows that previously rolled up to `final_state=completed` despite AI self-reports of failure will now correctly roll up to `final_state=failed`. This is the **fix** to bug #12, not a regression. Pre-fix runs whose AI agents emitted clean `result: success` keep working unchanged.
- `unknown` values (any string outside the alias table) normalize to the `failed` state. Agents that emit non-conforming `result:` values today will surface as failures after upgrade — this is intentional per the contract's "unknown is failed" rule. Migration: agents emitting non-aliased values must update to one of the four normalized values; the alias table is permissive enough that most existing runs (which emit `success` / `成功` / `ok`) need no changes.
- Phase 5 role/skill attachment from v0.25.0 unchanged. Phase 6 builtin promotion still deferred. v0.26.x Round 2 (AI write contract) and Round 3 (Phase D / F / E re-validation) remain to come.

---

## [v0.25.9] - 2026-05-10

> Patch release — **bug #11**, surfaced finishing the component-repo dogfood. After v0.25.7 + v0.25.8 wired the typed `cap promote inspect <spec_artifact_name>` surface, the user's natural follow-up was the legacy `cap promote <src> <dst>` escape hatch (the typed `--apply` path for spec_artifact remains deferred). The escape hatch silently copied artifacts into the cap install dir (`~/.charlie-ai-protocols/<repo_rel>`) instead of the user's working repo — same path-resolution bug family as v0.25.1 (RuntimeBinder), v0.25.2 (workflow_cli), v0.25.4 (persist-constitution.sh). Caught **after** the producer / resolver layers already shipped because no test exercised the legacy branch from outside the cap install dir.

### Fixed

- `scripts/cap-promote.sh` legacy `<src> <dst>` branch (line 105 pre-fix): `target_path` now resolves via `cap-paths.sh get project_root` instead of CAP_ROOT (the cap install directory). Halts with a helpful Chinese message when project_root cannot be resolved (no .cap/project.yaml at the cwd) rather than silently picking CAP_ROOT and polluting it.

### Added

- `tests/scripts/test-cap-promote-legacy-target-path.sh` (new, 9 cases): regression for the v0.25.9 contract. Cases 1a/1b/1c — reports/-rooted source promotes into project_root, file actually exists at the expected path, CAP_ROOT not polluted. Cases 2a/2b — drafts/-rooted source uses the same project_root resolution, no CAP_ROOT pollution. Cases 3a/3b — absolute repo_rel halts with non-zero exit + helpful Chinese message (existing ensure_relative_path guard). Cases 4a/4b — structural lint: source no longer contains `target_path="${CAP_ROOT}/${repo_rel}"`; source contains exactly one `target_path="${project_root}/${repo_rel}"` form so a future refactor reverting to the bare CAP_ROOT join fails the test immediately.
- `scripts/workflows/smoke-layer.sh` promote suite: append the new fixture.

### Verified

- `test-cap-promote-legacy-target-path.sh` **9 / 9** PASS.
- smoke-layer promote **6 / 6** PASS — existing inspect / project-constitution / workflow promote fixtures regression-clean.
- Manual dogfood: `cap promote reports/workflows/project-spec-pipeline/run_xxx/4-prd.md docs/architecture/foo_PRD_v1.md` from cap-test/component-next-dotnet-stt/ now lands at `<project_root>/docs/architecture/foo_PRD_v1.md` instead of `~/.charlie-ai-protocols/docs/architecture/foo_PRD_v1.md`.

### Boundary

- One-line behaviour change in shell. No schema bump, no policy update (the policy never specified that the legacy escape hatch should write to CAP_ROOT — it was a bug in the implementation).
- Pre-existing typed `cap promote inspect` / `cap promote project-constitution` / `cap promote workflow` surfaces are unaffected (they already used proper project_root resolution).
- Phase 5 role/skill attachment from v0.25.0 unchanged. Phase 6 builtin promotion still deferred. Typed `cap promote spec-artifact <name> --apply` remains a deferred follow-up.

---

## [v0.25.8] - 2026-05-10

> Patch release — **resolver-side wiring for v0.25.7 spec_artifact**. The producer-side fix in v0.25.7 made `workflow-result.json:promote_candidates` non-empty, but `cap promote inspect <artifact_name>` still answered "No promote candidate matches" because `engine/promote_resolver.py` only knew the two pre-existing artifact types. v0.25.8 adds the third lookup branch so inspect can resolve spec_artifact candidates by name, with the same target-path computation the producer uses.

### Added

- `engine/promote_candidate_producer.py detect_spec_artifact_candidate_for_name(artifact_name, *, project_storage, project_root)`: inspect-side helper mirroring `detect_constitution_candidate_for_task` / `detect_compiled_workflow_candidate_for`. Walks `<project_storage>/reports/workflows/project-spec-pipeline/run_*/runtime-state.json` (latest run wins by lexical max on the timestamped run id), filters to entries whose `source_step.execution_state == "validated"` and whose `source_path` exists on disk, returns one candidate dict matching the producer's shape contract. Module name slug derives from runtime-state's `task_id` (when present) → project_storage basename — same fallback chain as the producer so inspect and producer outputs agree byte-for-byte.
- `engine/promote_resolver.py resolve_promote`: third lookup branch — after task_id (constitution) and workflow_id (compiled workflow) miss, try `artifact_id` as a spec_artifact name (one of the six policy §3.3 mapping keys: `prd_document` / `tech_plan_document` / `ba_spec` / `schema_ssot` / `api_contract` / `ui_spec`). Lookup remains read-only with the same `_build_resolved` enrichment for conflict / backup / validation classification.
- `tests/scripts/test-promote-candidate-producer-spec-artifact.sh` Cases 7a–7c (3) + 8a–8b (2): regression for the v0.25.8 contract. 7a confirms the inspect-side helper returns a `spec_artifact` candidate. 7b locks the project_id-basename fallback when runtime-state.json has no `task_id`. 7c locks the unknown-name → None negative case. 8a runs `resolve_promote("ba_spec")` end-to-end and confirms the wired branch returns a `ResolvedPromote` with the right `artifact_type`. 8b confirms the resolved target uses the project_id-basename fallback consistently.

### Verified

- `test-promote-candidate-producer-spec-artifact.sh` **21 / 21** PASS (16 prior + 5 new for the resolver-wiring contract).
- smoke-layer promote **5 / 5** PASS — existing 32 cap-promote-inspect cases keep passing under the resolver extension.

### Boundary

- Two read-only helpers added; no schema bump, no CLI surface change beyond `cap promote inspect <spec_artifact_name>` now returning a real result instead of the "No promote candidate matches" fallback.
- `cap promote --apply` for `spec_artifact` is **not** wired in this release. The user-facing apply path uses the legacy `cap promote <local_rel> <repo_rel>` escape hatch (see policies/runtime-promote.md §1 footer); a typed `cap promote spec-artifact <name> --apply` command remains a deferred follow-up. Inspect surface is enough to close bug #6 / #8's "no signal" symptom.
- Phase 5 role/skill attachment from v0.25.0 unchanged. Phase 6 builtin promotion still deferred.

---

## [v0.25.7] - 2026-05-10

> Patch release — **dogfood follow-up to v0.25.6**, closing bug #6 / #8 (the auto-promote bridge between project-spec-pipeline outputs and the project repo's `docs/`). After v0.25.6 unblocked Phase D end-to-end, the dogfood baseline still required **manual mirroring** of `<run_dir>/4-prd.md` etc. into `docs/architecture/<module>_PRD_v1.md` for the implementation pipeline's AI step to accept the spec layer as "齊備". Phase C ran fine and produced all 6 spec artifacts under `<run_dir>/`, but `workflow-result.json:promote_candidates: count 0` because the v0.25.6 producer only knew about `project_constitution` and `compiled_workflow`. There was no signal to either users or downstream consumers that anything was promotable.
>
> Fix: **`spec_artifact` is now a third promote artifact_type**. The producer auto-emits one candidate per validated spec output with the canonical `docs/` target derived from policy §3.3's mapping table. `cap promote inspect` will now show real candidates after a spec pipeline run, and the existing `cap promote --apply` surface can write them to repo. Implementation pipelines still pick up spec artifacts from `<run_dir>/` via the v0.25.4/v0.25.6 cross-pipeline resolvers — promote is the additional path for landing them in git, not a runtime requirement.

### Added

- `engine/promote_candidate_producer.py` — new `_detect_spec_artifact_candidates` helper. Fires only when `workflow_id == "project-spec-pipeline" AND final_state == "completed"`. Reads the run's `runtime-state.json`, walks the canonical `_SPEC_ARTIFACT_TARGET_MAP` (`prd_document` / `tech_plan_document` / `ba_spec` / `schema_ssot` / `api_contract` / `ui_spec`), filters to entries whose `source_step.execution_state == "validated"` and whose `source_path` exists on disk, emits one candidate each with the policy §3.3 target (`docs/architecture/<module>_PRD_v1.md`, `docs/architecture/database/<module>_schema_v1.md`, `docs/design/<module>_UI_v1.md`, etc.). Module name slug precedence: `task_id` → `project_id` → `"module"` literal fallback. Slug rules mirror `_sanitize_project_id` (lowercase / a–z 0–9 . _ -).
- `_slug_module_name(raw)` private helper: kebab-case slug for filename composition; same character class as `engine/project_context_loader.py`.
- `tests/scripts/test-promote-candidate-producer-spec-artifact.sh` (new, 16 cases): regression for the v0.25.7 contract. Cases 1a–1j cover the 6-artifact happy path (correct count, correct target paths for each artifact name, source absolute, source_revision tagged with run_id, validation_schema=null per policy §6.1). Case 2 confirms non-spec workflows do not emit spec candidates. Case 3 confirms failed spec runs emit zero. Case 4 confirms blocked source_steps are skipped while validated ones still emit. Case 5 confirms missing-on-disk source paths are silently skipped. Case 6 round-trips a spec_artifact candidate through `validate-jsonschema` against the workflow-result schema to lock the enum extension.
- `scripts/workflows/smoke-layer.sh promote` suite: append the new fixture so smoke-layer / smoke-per-stage cover it automatically.

### Changed

- `schemas/workflow-result.schema.yaml`: extend `promote_candidates[].items.artifact_type` enum from 2 to 3 values — added `spec_artifact`. Field description updated to document the new type's policy contract.
- `policies/runtime-promote.md`: §2 promotable categories table gains a `Spec artifact` row (target = `docs/architecture/` or `docs/design/`, gated to spec-pipeline + completed). §3.3 (new) defines the full mapping table, module-name resolution rule, no-partial-override invariant, and validation note (no JSON schema; file-existence + non-empty + `.md` extension only). §3.4 (was §3.3) updated to reflect three target categories instead of two. §5.2 enum and §5.3 detection rule both updated. §6.1 validation table gains the `Spec Artifact` row pointing at file-existence + non-empty + `.md` extension instead of JSON Schema.

### Verified

- `test-promote-candidate-producer-spec-artifact.sh` **16 / 16** PASS.
- smoke-layer promote **5 / 5** PASS (24 prior + 16 new + 32 + 37 + 32 baseline cases all green).
- smoke-layer contracts **7 / 7**, runtime **17 / 17** PASS — schema enum extension does not regress existing fixtures.
- Manual dogfood: cap-test/component-next-dotnet-stt's prior Phase C run will now emit 6 spec_artifact candidates the next time `cap workflow inspect` re-renders the result, and `cap promote inspect` will surface them (target paths `docs/architecture/happy-path-stt-component-formal-spec_PRD_v1.md` etc.).

### Boundary

- One enum extension + one detector helper. No new CLI surface in this release; existing `cap promote inspect` / legacy `cap promote <src> <dst>` consumers gain coverage automatically. A typed `cap promote workflow <run_id> --spec-artifacts` bulk command remains a deferred follow-up — when concrete dogfood evidence shows manually applying 6 candidates per run becomes friction.
- Implementation pipeline's runtime input resolution is unchanged. Phase D continues to read spec artifacts from `<run_dir>/` via the v0.25.4 `prior_spec_artifacts` resolver and the v0.25.6 named-artifact lookup. Promote is the **path to git**, not a runtime dependency for downstream pipelines.
- Spec markdown has no JSON schema, so `validation_schema = null` for every spec_artifact candidate. Policy §6.1 documents the post-apply gate's behaviour for this type (file existence + non-empty + `.md` extension).
- Phase 5 role/skill attachment from v0.25.0 unchanged. Phase 6 builtin promotion still deferred.

---

## [v0.25.6] - 2026-05-10

> Patch release — **dogfood follow-up to v0.25.5**. After the output_paths normalizer let `persist_task_constitution` succeed, project-implementation-pipeline reached step 4 (`backend`) and immediately blocked with `missing_input_artifact:schema_ssot, api_contract, ba_spec`. The same pattern would repeat at every downstream step (frontend needs `ui_spec` / `ui_design_assets`, qa_testing needs frontend / backend codebases, etc.). The v0.25.4 `prior_spec_artifacts` resolver was umbrella-only; individual artifact names still bounced off `_try_resolve` because the current run's registry had none of them and they are not intrinsic.

### Fixed

- `engine/step_runtime.py validate_inputs._try_resolve` adds a third resolution layer: after registry and intrinsic both fail, scan all prior workflow runs under `${CAP_HOME}/projects/<project_id>/reports/workflows/*/run_*/runtime-state.json` for the named artifact. Latest validated producer wins (lexical max on the timestamped run id). Project-scoped — only the configured project's runs are considered.
- New helper `_resolve_artifact_from_prior_pipelines(artifact, project_id, cap_home)`: implements the cross-pipeline scan; reads each `runtime-state.json` once, picks entries whose `source_step.execution_state == "validated"`, returns the descriptor for the latest run that produced the artifact.

### Added

- `tests/scripts/test-cross-pipeline-named-artifacts.sh` (new, 7 cases): regression for the v0.25.6 contract. Case 1 spec pipeline run produces schema_ssot → backend's input resolves through prior-pipeline lookup. Case 2 latest run wins among multiple spec runs. Case 3 not-validated entries skipped. Case 4 no prior runs → missing (clear error). Case 5 cross-project leak prevented (project_id env scopes the lookup).
- `scripts/workflows/smoke-layer.sh` runtime suite: append the new fixture.

### Verified

- `test-cross-pipeline-named-artifacts.sh` **7 / 7** PASS.
- smoke-layer runtime baseline still green; full suite re-checked after the change.
- Manual dogfood: cap-test/component-next-dotnet-stt expected to advance into frontend / backend / qa / security / devops / impl_audit AI steps after `cap update` to v0.25.6.

### Boundary

- One-function behaviour change in Python. No schema bump, no provider surface change, no new env vars.
- The new resolver runs only when registry + intrinsic both fail. Pre-fix successful resolutions are unaffected.
- `CAP_PROJECT_ID` env var (exported by cap-workflow-exec.sh in v0.25.4) becomes the authoritative project scoping signal for cross-pipeline lookups; falls back to `_read_project_id_from_cwd()` when unset.
- Phase 5 role/skill attachment from v0.25.0 unchanged. Phase 6 builtin promotion still deferred.

---

## [v0.25.5] - 2026-05-10

> Patch release — **dogfood follow-up to v0.25.4**. After bridges #4 / #5 / #7 landed, project-implementation-pipeline could finally start. Step 1 (`draft_task_constitution`) succeeded under codex (170s) and emitted task constitution JSON. Step 2 (`persist_task_constitution`) immediately halted with `schema_validation_failed: execution_plan/0/output_paths/0: '...' is not of type 'object'`. Root cause: `schemas/task-constitution.schema.yaml` mandates `execution_plan[].output_paths.items.type = "object"` but `01-supervisor-agent.md` doesn't specify item shape, so codex / claude both emit string items (the bare path). Phase C (project-spec-pipeline) ran fine because its supervisor draft happened to leave `output_paths` empty.
>
> The schema is right (downstream consumers want richer descriptors), the AI doc is ambiguous, and the AI emits the natural form. Pragmatic resolution: the persist normalizer auto-converts string items to `{"path": "..."}` objects so the strict schema validates while preserving full path information.

### Fixed

- `scripts/workflows/persist-task-constitution.sh normalize_task_constitution_json`: when `execution_plan[].output_paths` is a list, each string item is rewritten as `{"path": "<the string>"}`. Existing object items (with their full key set) pass through unchanged. Empty lists stay empty. Mixed lists (strings + objects) are normalised per-item.

### Added

- `tests/scripts/test-persist-task-constitution-output-paths-norm.sh` (new, 4 cases): exercises the normalizer's `output_paths` pass directly (extracts the function block and evals it in a clean subshell to avoid running the persist script's main flow). Cases: 1) all-string list → all objects; 2) all-object list → unchanged including extra keys; 3) empty list → empty; 4) mixed list → strings normalised, objects preserved.
- `scripts/workflows/smoke-layer.sh` runtime suite: append the new fixture.

### Verified

- `test-persist-task-constitution-output-paths-norm.sh` **4 / 4** PASS.
- smoke-layer runtime baseline still green; full suite re-checked after the change.
- Manual dogfood: cap-test/component-next-dotnet-stt expected to advance past Phase D step 2 after `cap update` to v0.25.5.

### Boundary

- One-function behaviour change in shell. No schema bump (the schema's strict object requirement stays; the normalizer feeds it the right shape).
- Pre-fix runs that produced empty `output_paths` lists (e.g. Phase C's project-spec-pipeline draft) keep validating because the empty-list branch is a no-op under both old and new code.
- Phase 5 role/skill attachment from v0.25.0 unchanged. Phase 6 builtin promotion still deferred.

---

## [v0.25.4] - 2026-05-10

> Patch release — **dogfood follow-up to v0.25.3**, closing the remaining three bugs (#4, #5, #7) discovered while pushing the `cap-test/component-next-dotnet-stt` Component Repo baseline through Phase B (project-constitution) → Phase C (project-spec-pipeline) → Phase D (project-implementation-pipeline). After v0.25.1–v0.25.3, Phase B + Phase C ran end-to-end (16/16 spec artifacts produced) but constitution was persisted to `~/<project_id>/` instead of the user's repo, the next-pipeline run could not see the persisted constitution because the loader only read the legacy flat-file, and Phase D blocked at step 1 because `prior_spec_artifacts` had no resolver at all.

### Fixed

- **bug #4 — persist-constitution.sh writes to wrong project_root**: pre-fix, `TARGET_PROJECT_ROOT` was derived from `CAP_ROOT` (cap install dir) plus a scaffold-style join with `project_id_from_json`, so the constitution silently landed at `~/<project_id>/.cap/constitution.yaml` plus a full skeleton (docs/, schemas/, workspace/, README.md) on every run from outside the install dir. Fix: `scripts/workflows/persist-constitution.sh` now reads `CAP_PROJECT_ROOT` (which `scripts/cap-workflow-exec.sh run_shell_step` exports for every shell step) and writes there directly. Legacy scaffold-derivation path is preserved as a fallback for in-place test harnesses that haven't been updated. `read_current_project_id` likewise switched from CAP_ROOT to CAP_PROJECT_ROOT-rooted `.cap/project.yaml` lookup.
- **bug #5 — ProjectContextLoader namespace mismatch**: pre-fix, `DEFAULT_PROJECT_CONSTITUTION` was the legacy flat-file `.cap.constitution.yaml`, but `persist-constitution.sh` writes the namespaced `.cap/constitution.yaml`, so a project that ran `project-constitution` and then `project-spec-pipeline` from the same repo would have the loader return `_bootstrap=True` and the binder would block every step with "project constitution is missing; run project-constitution workflow first". Fix: `engine/project_context_loader.py` adds `DEFAULT_PROJECT_CONSTITUTION_NAMESPACED` and prefers the namespaced path when no explicit `constitution_file` is set in `project.yaml`. Same dual-path fallback added to `engine/step_runtime.py validate_inputs._try_resolve` for the `project_constitution` intrinsic resolver.
- **bug #7 — `prior_spec_artifacts` had no resolver**: pre-fix, `project-implementation-pipeline.yaml` declared `prior_spec_artifacts` as a required input on its first step but the runtime had no resolver — neither in `_INTRINSIC_ARTIFACTS` nor in the registry — so the workflow blocked at step 1 with `missing_input_artifact:prior_spec_artifacts`. Same gap for `prior_implementation_artifacts` in `project-qa-pipeline.yaml`. Fix: `engine/step_runtime.py _INTRINSIC_ARTIFACTS` adds both names; `_try_resolve` looks them up at `${CAP_HOME}/projects/<project_id>/reports/workflows/<pipeline>/run_*/artifact-index.md` (latest run wins, lexical max on the timestamp prefix), falling back to `result.md` if `artifact-index.md` is missing on older runs. `_read_project_id_from_cwd` helper supports the resolver when `CAP_PROJECT_ID` env is not set.

### Added

- `scripts/cap-workflow-exec.sh run_shell_step`: now threads `CAP_PROJECT_ROOT`, `CAP_PROJECT_ID`, and `CAP_HOME` into every shell step's environment so the workflow steps see the same project identity the binder resolved upstream. Pre-fix shell steps had to reconstruct project_root from `CAP_ROOT`, which is the cap install dir.
- `tests/scripts/test-cross-pipeline-bridges.sh` (new, 14 cases): combined regression for #4 + #5 + #7. Bug #5 cases 5a–5d (namespaced loaded, constitution_id read, path resolves, explicit project.yaml override still wins). Bug #7 cases 7a–7f (latest run wins lexical max, source_step tagged `__prior_pipeline__`, missing when no prior run exists, mirror behaviour for `prior_implementation_artifacts`). Bug #4 cases 4a–4d (repo_target under CAP_PROJECT_ROOT, project_root reported verbatim, legacy scaffold path NOT polluted, correct path written). Sandbox sets `CAP_HOME` to a tmp dir.
- `scripts/workflows/smoke-layer.sh` runtime suite: append the new fixture.

### Verified

- `test-cross-pipeline-bridges.sh` **14 / 14** PASS.
- smoke-layer contracts **7 / 7**, runtime **15 / 15** (14 prior + 1 new), project **8 / 8** PASS.
- Manual dogfood: cap-test/component-next-dotnet-stt baseline expected to advance through Phase D + Phase E + cap promote inspect after `cap update` to v0.25.4 (Phase B + C already validated under v0.25.3).

### Boundary

- Three behavioural changes in shell + Python. No schema bump. No new CLI flags.
- `CAP_PROJECT_ROOT` env var becomes the authoritative project_root signal for shell-class workflow steps. Pre-fix shell steps that derived from `CAP_ROOT` keep working through the legacy fallback path; future shell steps should read `CAP_PROJECT_ROOT` first.
- `prior_spec_artifacts` / `prior_implementation_artifacts` are now part of `_INTRINSIC_ARTIFACTS`, so any workflow declaring them resolves automatically. Workflows that wanted to fail when no prior run exists still get a clear missing-input error rather than a silent fallback.
- Phase 5 role/skill attachment from v0.25.0 unchanged. Phase 6 builtin promotion still deferred.

---

## [v0.25.3] - 2026-05-10

> Patch release — **dogfood follow-up to v0.25.2**. Third bug surfaced by the same baseline run on `~/projects/cap-test/component-next-dotnet-stt`. This time `validate_constitution` halted with `missing_input_artifact missing:project_constitution` even though `draft_constitution` had successfully produced the artifact and registered it in `runtime-state.json`. Root cause: `step_runtime.validate_inputs._try_resolve` checked `_INTRINSIC_ARTIFACTS` first and returned `None` when the on-disk `.cap.constitution.yaml` was absent, never consulting the runtime artifact registry. Self-producing workflows like `project-constitution` were therefore unable to see their own draft output.

### Fixed

- `engine/step_runtime.py validate_inputs._try_resolve` resolution order swapped: registry first, intrinsic second. Validated upstream output now wins over the project-level on-disk fallback. Behaviour for cross-workflow consumers (e.g. `project-spec-pipeline` reading `.cap.constitution.yaml` produced by an earlier `project-constitution` run) is unchanged because those runs have no upstream registry entry — the intrinsic branch still fires.

### Added

- `tests/scripts/test-validate-inputs-intrinsic-vs-registry.sh` (new, 7 cases): regression for the v0.25.3 contract. Case 1 registry-only resolution (artifact validated, disk file absent → resolves from registry, source_step=draft_constitution). Case 2 intrinsic-only resolution (registry empty, disk file present → resolves from intrinsic, source_step=`__request__`). Case 3 both present → registry wins. Case 4 neither → missing. Sandbox uses runtime-state.json fixtures plus a synthetic flatten-plan so the test does not require a real workflow execution.
- `scripts/workflows/smoke-layer.sh` runtime suite: append the new fixture.

### Verified

- `test-validate-inputs-intrinsic-vs-registry.sh` **7 / 7** PASS.
- smoke-layer runtime **14 / 14** PASS (13 prior + 1 new).

### Boundary

- One-function behaviour change. No schema bump, no provider surface change.
- `_INTRINSIC_ARTIFACTS` set unchanged — same names still recognised for fallback. Only the precedence between registry and intrinsic was inverted.
- Phase 5 role/skill attachment from v0.25.0 unchanged. Phase 6 builtin promotion still deferred.

---

## [v0.25.2] - 2026-05-10

> Patch release — **dogfood follow-up to v0.25.1**. The constructor-side fix in v0.25.1 was necessary but not sufficient. `RuntimeBinder.__init__` falls back to `project_root = base_dir` when only `base_dir` is provided (intentional for test harnesses that pass an isolated single-dir world). Production CLI paths in `workflow_cli.py` were calling `RuntimeBinder(base_dir=base_dir)` only, so the same `ProjectIdCollisionError` from the v0.25.1 issue still fired on `cap workflow run` from outside the install directory. This release pushes the project_root through to the three production call sites.

### Fixed

- `engine/workflow_cli.py cmd_plan` (line 1588), `cmd_bind` (1639), `cmd_build_bound_plan` (1654): all three now pass `project_root=Path.cwd()` explicitly to `RuntimeBinder`. The user's CWD is the working repo when CAP is invoked through the global wrapper, and we must name it explicitly because the binder constructor's `explicit_base_dir → project_root=base_dir` branch is meant for tests, not production.

### Added

- `tests/scripts/test-binder-project-context-origin.sh` Case 4 (3 sub-cases): regression for the production call path. 4a greps `workflow_cli.py` for any bare `RuntimeBinder(base_dir=base_dir)` call (must be 0) and 4b confirms the threaded form `RuntimeBinder(base_dir=base_dir, project_root=Path.cwd())` appears in all three production sites. 4c invokes `cmd_build_bound_plan` end-to-end from a sandboxed project_root and asserts it does not raise `ProjectIdCollisionError`. The grep checks act as a cheap structural lock so a future refactor reverting to the bare form fails immediately.

### Verified

- `test-binder-project-context-origin.sh` **8 / 8** PASS (5 prior + 3 new for Case 4).
- smoke-layer contracts **7 / 7**, runtime **13 / 13**, project **8 / 8** PASS.

### Boundary

- Three-line behaviour change in `workflow_cli.py` only. No new defaults in `RuntimeBinder.__init__` — keeping the constructor backward-compatible for the one test (`tests/scripts/test-cap-config-namespace-readers.sh`) that passes only `base_dir` for skill registry isolation.
- Phase 5 role/skill attachment from v0.25.0 unchanged. Phase 6 builtin promotion still deferred.

---

## [v0.25.1] - 2026-05-10

> Patch release — **dogfood-discovered** project_id collision fix. When the global `cap` wrapper at `~/.charlie-ai-protocols` was invoked from any working repo other than the dev clone, `RuntimeBinder.bind_semantic_plan` halted with `ProjectIdCollisionError` because `ProjectContextLoader` was anchored at the cap install dir (`base_dir`) rather than the user's working repo (`project_root`). The basename of the install dir collides with the dev repo clone of the same name and the ledger origin mismatch fires every time. Surfaced by attempting the first end-to-end Component Repo dogfood at `~/projects/cap-test/component-next-dotnet-stt`.

### Fixed

- `engine/runtime_binder.py` line 203: `RuntimeBinder.__init__` now passes `self.project_root` to `ProjectContextLoader`, so project identity, ledger origin, and constitution path resolution all track the user's working repo instead of the cap install directory. The fix is one line plus comment; behaviour for in-repo invocations (where `project_root` defaults to `base_dir`) is unchanged.

### Added

- `tests/scripts/test-binder-project-context-origin.sh` (new, 5 cases): regression fixture for the v0.25.1 contract. Case 1 asserts `project_id` derives from the project_root basename, not the install dir's. Case 2 asserts the ledger writes `origin_path = project_root` and a re-verify call from a fresh binder does not raise `ProjectIdCollisionError`. Case 3 asserts the underlying `ProjectContextLoader.base_dir` is wired to `project_root.resolve()` so the wiring cannot silently regress. Sandbox sets `CAP_HOME` to a tmp dir so the test does not pollute the real `~/.cap/projects/`.
- `scripts/workflows/smoke-layer.sh` runtime suite: append the new fixture so smoke-layer / smoke-per-stage cover it automatically.

### Verified

- New: `test-binder-project-context-origin.sh` **5 / 5** PASS.
- Regression baseline (post one-line fix): smoke-layer contracts **7 / 7**, runtime **13 / 13** (12 prior + 1 new), project **8 / 8**. No legacy regressions.

### Boundary

- One-line behaviour change. No schema bump, no provider-side change, no role/skill registry change.
- Pre-fix workarounds (`CAP_PROJECT_ID_OVERRIDE` env var, manual `~/.cap/projects/<id>/.identity.json` cleanup) are no longer required for the common dev-machine layout (cap installed at `~/.charlie-ai-protocols`, dev clone at `~/projects/charlie-ai-protocols`). Existing ledger files for projects already migrated to the bug-stable workaround keep working — the loader still reads them on re-entry, only the resolution path has tightened.
- Phase 5 role/skill attachment behaviour from v0.25.0 remains unchanged. Phase 6 (builtin promotion of shared advisory skills) still deferred.

---

## [v0.25.0] - 2026-05-10

> Minor release — Role / Skill Registry **Phase 4 + Phase 5 land together**: `RuntimeBinder` now selects the executor role and advisory skill attachments through two independent paths, and AI step prompt assembly mounts advisory skills after the role prompt. The post-v0.24.11 "natural dogfood" boundary is closed for advisory attachment; Phase 6 (builtin promotion of shared advisory skills) remains deferred.

### Added

- `schemas/binding-report.schema.yaml` step item: two optional fields anchoring the Phase 5 contract.
  - `selected_role` (object|null): structured snapshot of the chosen executor role; mirrors the legacy `selected_skill_id` / `selected_agent_alias` / `selected_prompt_file` / `selected_cli` / `skill_source` quartet for consumers wanting a single-object view. Schema rejects `kind=skill` in this slot (defence in depth — the binder already filters it from candidates).
  - `attached_skills[]` (array): advisory-skill attachments rendered after the role prompt at AI execution. Each item declares `skill_id`, `prompt_file`, `attach_reason` (enum `attach_to_capabilities | attach_to_roles`), and `skill_source`. Strict-attach contract documented in the field description.
- `engine/runtime_binder.py`: three new helpers driving the role/skill split.
  - `_classify_kind(skill)` — explicit `kind` wins; legacy inference (`agent_alias` present → role; absent → skill) preserved verbatim for pre-v0.24.7 entries.
  - `_find_attached_skills(registry, capability, *, workflow_version, selected_role_alias)` — strict-attach selection that requires either `attach_to_capabilities` containing the step's capability (primary, wins on tie) or `attach_to_roles` containing the chosen role's `agent_alias` (secondary). Returns priority-desc + skill_id-asc-sorted `(skill, attach_reason)` pairs. Auto-fan-in over `provided_capabilities` was rejected — see the ADR-style note in `docs/cap/ROLE-SKILL-REGISTRY-MODEL-MEMO.md`.
  - `_build_selected_role(skill)` / `_build_attached_skill_entry(skill, attach_reason)` — project the registry picks into the binding-report shape; the role builder rejects `kind=skill` and entries missing `prompt_file` so partial picks do not slip through.
- `engine/step_runtime.py attached-prompts` subcommand — emits one TSV line per attachment (`prompt_file<TAB>skill_id<TAB>attach_reason`) for a given step. Tab-delimited so the stream is orthogonal to flatten-steps' pipe format. Empty stdout for no-attach steps and unknown step ids.
- `scripts/cap-workflow-exec.sh build_attached_skills_section` — Bash helper that calls `attached-prompts` and renders an "附加規範指引 (Attached Advisory Skills)" block before the structured contract section. References each advisory skill's `prompt_file` by path (same convention as the role prompt's "請嚴格依照 …" line) so the AI provider mounts both files via its filesystem tools — no inline duplication, prompt-hash duplicate detection in `cap session analyze` stays meaningful. Shell-executor steps never reach `build_step_prompt`, so attachments are injection-only for AI executors.
- `tests/scripts/test-binder-phase5-attachment.sh` (new, 13 cases): drives `_find_candidates` / `_find_attached_skills` / `_build_selected_role` / `_assert_skill_source_allowed` via the `test-user-imported-role.sh` explicit-kwarg sandbox pattern. Asserts kind=skill is filtered out of executor candidates, both attach reasons fire, no auto-fan-in, double-match precedence, priority sort order, source-policy halt with `purpose=attached_skill` + `skill_id` in the message, and the defence-in-depth rejections in `_build_selected_role`.
- `tests/scripts/test-step-runtime-attached-prompts.sh` (new, 9 cases): locks the attached-prompts TSV contract — two attachments in input order, empty stdout for no-attach / unknown step_id, tab sanitization in payload fields, and the flatten-steps `attached_count = len(attached_skills)` invariant plus the 23-field `NF` check so the cap-workflow-exec.sh IFS read stays positional.
- `scripts/workflows/smoke-layer.sh` (new from `chore(devops)`): focused smoke slices for local iteration — `contracts | runtime | project | orchestration | e2e | promote | replay | full`. The runtime suite picks up both new Phase 5 fixtures automatically.
- `docs/cap/DOGFOOD-PROFILES.md` (new from `docs(cap)`): defines repo profiles for dogfood evidence collection so Phase 6 builtin-promotion criteria can land on a stable evidence base.

### Changed

- `engine/runtime_binder.py _find_candidates` filters to `kind=role` only. Advisory skills can no longer silently fill the executor slot via the legacy `agent_alias`-makes-it-selectable path. **This is the Phase 5 contract flip** — previously documented at the post-v0.24.11 boundary as the deliberate behaviour change.
- `engine/runtime_binder.py _find_fallback` also restricts to `kind=role`. An advisory skill cannot quietly fill the executor slot through fallback either.
- `engine/runtime_binder.py _assert_skill_source_allowed` accepts `purpose` (default `"role"`) and `skill_id` kwargs so the `SkillSourcePolicyError` message names the offending pick (role vs attached_skill); each attached skill is gated independently and a violation halts the entire bind, not silently drops the attachment (memo §7.4).
- `engine/runtime_binder.py bind_semantic_plan` writes `selected_role` / `attached_skills` on every step report, including bootstrap-blocked, capability-blocked, shell-executor, and unresolved branches (null role + empty list). `build_bound_execution_phases_from_semantic` propagates both fields to deferred / active / standby steps so flatten_steps and the prompt builder see them.
- `engine/step_runtime.py flatten_steps` appends a 23rd `attached_count` field to each pipe-delimited row. `scripts/cap-workflow-exec.sh` now binds the 23rd variable explicitly so the IFS read stays positional.
- `tests/scripts/test-skill-registry-kind-field.sh` case 5 inverts: was "all three entries remain selectable candidates"; now case 5a "role-shaped entries remain selectable" + case 5b "explicit kind=skill is excluded from executor candidates". This locks the Phase 5 invariant.
- `scripts/workflows/smoke-per-stage.sh` (from `refactor(smoke)`): release gate list is derived from the step inventory rather than hand-maintained, removing the duplication that previously caused additions to drift.
- `docs/cap/ROLE-SKILL-REGISTRY-MODEL-MEMO.md`: ADR-style note added before the boundary section recording the Phase 5 trigger, scope, strict-attach decision, conflict rules, and rollback strategy. Phase 4 + Phase 5 sections marked **landed at v0.25.0** with explicit task-by-task completion notes. Recommended-next-step guidance shifted to Phase 6 dogfood watching.
- `docs/cap/AGENT-SKILLS-CUSTOMIZATION.md` 場景 6 (new section): walkthrough for advisory skill attachment. 6.1 strict-attach contract table, 6.2 shared-layer attach example with `attach_to_capabilities`, 6.3 attach_to_roles narrowing, 6.4 constitution authorisation surface, 6.5 `cap workflow bind` verification snippet, 6.6 decision matrix (replace role / new role / attach advisory / disable).
- `docs/cap/SKILL-RUNTIME-ARCHITECTURE.md` §2 / §3: Phase 5 dual-slot explainer with ASCII diagram (capability → selected_role + attached_skills[]) and the AI step prompt assembly order (role prompt → 「附加規範指引」 → structured sections).
- `TODOLIST.md` (from `docs(cap)`): collapsed into a focus index that points at the per-track docs rather than restating them, keeping the entry surface small.

### Verified

- Full `smoke-per-stage.sh` release gate: **87 / 87 PASS, 0 failed, 0 skipped**.
- `smoke-layer.sh` slices: contracts **7 / 7**, runtime **12 / 12** (includes the two new Phase 5 fixtures), orchestration **6 / 6**, project **8 / 8**, replay **5 / 5**.
- New: `test-binder-phase5-attachment.sh` **13 / 13**, `test-step-runtime-attached-prompts.sh` **9 / 9**.
- Regression baseline: `test-binding-report-schema.sh` **17 / 17** (10 legacy + 7 new), `test-binding-report-validation-hook.sh` **15 / 15**, `test-skill-registry-resolver.sh` **22 / 22**, `test-skill-registry-override.sh` **29 / 29**, `test-skill-registry-kind-field.sh` **11 / 11** (case 5 contract flip), `test-user-imported-role.sh` **19 / 19**, `test-binding-source-metadata.sh` **17 / 17**.

### Boundary

- `binding-report.schema.yaml schema_version` stays at **1**. `selected_role` and `attached_skills[]` are additive optional fields; pre-Phase 5 binding reports validate unchanged.
- Legacy quartet (`selected_skill_id` / `selected_agent_alias` / `selected_prompt_file` / `selected_cli`) keeps writing on every step report. Consumers that have not adopted `selected_role` see the same shape as before.
- `flatten_steps` 23rd field is positional; `cap-workflow-exec.sh` is the only repo-internal consumer and now binds 23 variables. External wrappers iterating only the first 22 fields keep working positionally.
- **One deliberate behavioural break**: `kind=skill` entries can no longer be standalone executors. Real builtin / shared registries today carry no workflow that depended on this; `tests/scripts/test-skill-registry-kind-field.sh` case 5 is rewritten to lock the new contract. Rollback: toggle `_find_attached_skills` to return `[]` and the runtime collapses to single-role behaviour without any schema change (see memo "Rollback strategy").
- **Phase 6 builtin promotion of shared advisory skills** remains deferred. Memo entry/exit criteria unchanged; opens only when a specific shared advisory skill has multi-provider, multi-workflow, multi-task evidence of repeated usefulness.
- Provider global files (`~/.codex/AGENTS.md` / `~/.claude/CLAUDE.md`) and provider sub-agent directories (`~/.claude/agents/`) remain forbidden registration targets; this release does not change provider-side surfaces.

---

## [v0.24.11] - 2026-05-10

> Patch release — Role / Skill Registry Phase 3 user-imported role registration. Pure docs / schema example / resolver tests; runtime selection behaviour is unchanged from v0.24.10. Phase 4 attachment design and Phase 5 runtime attachment remain deferred.

### Added

- `policies/agent-skills-baseline.md` §3.5 (new section): normative registry contract for user-imported NEW roles in project / shared layer. Covers required fields (`skill_id`, `kind`, `agent_alias`, `prompt_file`, `cli`, `provided_capabilities`, `compatible_workflow_versions`), source-layer rules (project auto-allowed, shared requires explicit `allowed_source_roots`), and hard write-boundaries banning `~/.codex/AGENTS.md` / `~/.claude/CLAUDE.md` / `~/.claude/agents/` as registration targets.
- `docs/cap/AGENT-SKILLS-CUSTOMIZATION.md` 場景 5 (new section): user-facing how-to. 5.1 project-layer example with full kind=role entry, 5.2 shared-layer example with project constitution `allowed_source_roots` declaration, 5.3 `cap workflow bind` verification with `selected_skill_id` / `skill_source` jq query, 5.4 forbidden-registration table (provider global files, sub-agent dirs, capability collision), 5.5 promotion-to-builtin pointer.
- `schemas/skill-registry.schema.yaml` Examples block (new, end-of-file): three inline YAML examples anchoring the v0.24.8 `kind` enum in concrete shapes — Example A project-layer user role with `mobile_implementation`, Example B shared-layer user role with priority 90, Example C advisory skill (Karpathy-style) with two capabilities.
- `tests/scripts/test-user-imported-role.sh` (new, 19 cases / 6 case groups): Case 1 project-layer NEW role (`_find_candidates` discovery + `_source_layer=project` tag + `_has_execution_metadata` accept), Case 2 shared-layer NEW role under explicit `allowed_source_roots` (positive source-policy path through `_compute_effective_allowed_roots` + `_assert_skill_source_allowed`), Case 3 shared-layer NEW role without declaration triggers `SkillSourcePolicyError` with `halt_stage=skill_source_policy` (**negative test** for the policy gate), Case 4 project + shared same `skill_id` layer ordering preserved for user roles, Case 5 capability isolation (user role's new capability doesn't surface as builtin candidate; builtin doesn't surface under user capability), Case 6 `kind=role` missing `prompt_file` rejected by `_has_execution_metadata` (same gate applies to user roles as builtin).

### Changed

- `docs/cap/ROLE-SKILL-REGISTRY-MODEL-MEMO.md` Phase 3 section: marked **landed at v0.24.11** with explicit landing artefacts list (5 files modified / created) and boundary statement (docs / schema example / tests only; runtime untouched).

### Verified

- New: user-imported-role **19 / 19** PASS across all 6 case groups.
- Regression baseline (post schema Examples-block addition): skill-registry-resolver **22 / 22**, skill-registry-kind-field **10 / 10**, skill-registry-override **29 / 29**. All green.

### Boundary

- v0.24.11 is **docs + schema example + resolver tests only**. The following are deliberately untouched:
  - `engine/runtime_binder.py` — no candidate ranking change, no kind branching, source-policy hooks unchanged
  - `scripts/cap-workflow-exec.sh` — no prompt assembly change
  - `agent-skills/*-agent.md` builtin prompts — no role prompt change
  - `schemas/skill-registry.schema.yaml` structural fields — only docstring-style Examples block added at end-of-file
- **Phase 4 advisory skill attachment design** and **Phase 5 runtime attachment implementation** remain deferred. The memo entry/exit criteria for those phases are unchanged; they wait for real multi-skill use cases to drive design.
- **Provider global files** (`~/.codex/AGENTS.md` / `~/.claude/CLAUDE.md`) and **provider sub-agent directories** (`~/.claude/agents/`) are explicitly named as forbidden registration targets in normative policy. No provider-side changes shipped.
- After v0.24.11, the project enters **natural dogfood mode** — Phase 4 / 5 will only open when a real user-imported role hits a limitation that requires advisory skill attachment.

---

## [v0.24.10] - 2026-05-10

> Patch release — Karpathy Phase 2 integration-mode evidence consolidation. v0.24.9 promoted the strategy to builtin and added agent-prompt references in 7 candidate agents; v0.24.10 records the first two real-run observations of that integration path and pins the visibility spectrum that production usage should expect.

### Added

- `schemas/workflows/karpathy-integration-smoke-supervisor.yaml`: single-step workflow, capability `prd_generation`. Spawns the `01-supervisor` agent on a feature spec request as the high-visibility end of Phase 2 integration testing. Sister to `karpathy-guardrails-smoke` (binding contract) and `karpathy-real-task-dogfood` (Karpathy-as-role).

### Verified

Phase 2 Integration-Mode Evidence (memo Phase 2 closeout open follow-up #1):

- **Run #8** — `run_20260510040913_bd2a1cb9` (Claude 2.1.137, 74s). Workflow `karpathy-integration-smoke-supervisor`. **High-visibility end**: supervisor's PRD section structure was **explicitly labelled with the four Karpathy rules** — `[Karpathy Rule 1 — 浮現假設]`, `[Rule 2 — 推回投機性 scope]`, `[Rule 3 — 新增項目可逐條追溯]`, `[Rule 4 — 可驗證的成功條件]`. Concrete artefacts: 3 alternative JSON formats surfaced for user choice rather than silently picked (Rule 1), 5 explicit "刻意排除" bullets (Rule 2), traceability table mapping each feature item to a user-prompt phrase (Rule 3), 5 verifiable success criteria + 150-line PR diff cap (Rule 4). Plus surgical scope of dispatch: 4 downstream capabilities recommended, 7 explicitly excluded.

- **Run #9** — `run_20260510041740_cc4b0caf` (Claude 2.1.137, 1568s ≈ 26 min, 6 steps). Workflow `project-code-analysis` (production, not smoke). 4 of 6 steps spawned Karpathy candidate agents: `01-supervisor` (analysis_scope), `02-techlead` (architecture_scan + review_analysis), `10-troubleshoot` (hotspot_diagnostics). **Low-visibility end**: zero explicit `[Karpathy Rule N]` cites across all 4 candidate-agent outputs, but **implicit framing visible in every one** — supervisor's Out-of-Scope table + "現狀夠好不要動" stance + "**非**逐行 review、**非** patch、**非** refactor" exclusions + 5-section deliverable enumeration; techlead's "目的不是 code review、也不是新功能設計" framing; troubleshoot's "**不偽造已讀過上游全文的結論**" Rule-1-pure surface-assumptions discipline.

### Visibility Spectrum (the headline finding from #8 + #9)

Runs #8 and #9 bracket the visibility range of the Phase 2 reference-mounted path:

| Run | Workflow shape | Karpathy framing visibility |
|---|---|---|
| #8 (smoke) | single-step, minimal prompt | **explicit** — all 4 rules named in section headers |
| #9 (production) | 6-step, full repo subsystem analysis | **internalised** — 0 explicit cites, behavioural framing across 4 candidate-agent outputs |

**Both are valid outcomes, not opposite results.** When the agent's task is a small meta-discussion, the agent has spare attention to cite the strategy by name. When the agent's task consumes its full attention (full repo scan, multi-step handoff chain, complex artefact production), the strategy still shapes output but the agent doesn't have surface area to label it. Karpathy becomes ambient discipline rather than visible scaffolding.

**Real failure mode would be**: agent output exhibits **neither** explicit cites **nor** behavioural framing (speculative additions, silent ambiguity, unrelated cleanup, skipped success criteria). Run #9 had **none** of those across 4 candidate-agent step outputs. The reference path works at both ends of the spectrum.

### Changed

- `docs/cap/KARPATHY-GUIDELINES-INTEGRATION-MEMO.md` Phase 2 Integration-Mode Evidence subsection now logs both runs and adds the Visibility Spectrum analysis as a deliberate framing tool for evaluating future Phase 2 evidence.
- Phase 2 Closeout open follow-up #1 ("real-run validation in builtin mode") is now **CLOSED** by run #8. Open follow-up "other six candidate agents have not yet been integration-tested" is **partially closed** by run #9 — techlead (×2) and troubleshoot now have one observation each; frontend / backend / qa / watcher remain untested but the reference shape is identical and absence-of-failure-mode lowers the bar to "no signal would be a surprise".

### Side observation

**No token-cost concern observed**. The original Phase 2 plan flagged "Keep the guidance concise enough to avoid bloating every task prompt". Run #9 (production, 6 steps, full v0.24.9 agent-skills baseline with every candidate agent prompt carrying the Karpathy reference) completed without timeout, token-budget warning, or context-window strain. The ~1 bullet per agent (≤120 chars each) does not measurably affect runtime cost. The Phase 2 token-cost criterion is empirically satisfied.

### Boundary

- v0.24.10 is **integration-mode evidence consolidation only**. No code change, no skill change, no schema change, no runtime branching. Memo updates + one new smoke workflow + tag.
- **Codex parity for run #9** is a deliberate next-round follow-up, not part of this release. The role-mounted Phase 1 path already has Codex evidence (run #5); the reference-mounted Phase 2 path has Claude evidence at both visibility ends — Codex parity at the production end can be collected when a real Codex-driven task naturally exercises the path.
- **Watcher Quality Alert on Karpathy-rule violation** remains the open follow-up from v0.24.9 closeout. That path requires a real violation to fire, not synthetic injection.
- 6 candidate agents not yet integration-tested (frontend / backend / qa / watcher) stay open as "no signal would be a surprise" rather than "must be tested before promotion is safe".

---

## [v0.24.9] - 2026-05-10

> Patch release — Karpathy guidelines Phase 2 builtin promote (shared-layer dogfood graduates to CAP baseline strategy + 7 agent references), `cap-workflow.sh` `CAP_HOME` default follow-up from v0.24.8 dogfood findings, real-task dogfood workflow, and 7 runs of cross-provider evidence supporting the promotion.

### Added

- `agent-skills/strategies/karpathy-guidelines.md`: builtin Karpathy LLM-coding guardrails strategy (think before coding / simplicity first / surgical changes / goal-driven execution). Adapted from the v0.24.7 shared-layer dogfood prompt with CAP-aligned section structure: When To Mount, Four Rules with CAP-corresponding discipline notes, Conflict Resolution Order, Boundary, Cross-Strategy Map, Mount References, Historical Track. Conflict resolution order pinned: user instruction > project constitution > role prompt > other strategies > Karpathy.
- Karpathy strategy references added to 7 candidate agent prompts (`01-supervisor` / `02-techlead` / `04-frontend` / `05-backend` / `07-qa` / `10-troubleshoot` / `90-watcher`), each contextualised to that agent's typical scope-creep vector. `90-watcher` gains an audit-style entry — Karpathy-rule violations now trigger Quality Alerts via the Watcher's strategy audit list. 4 deliberately-excluded agents (`03-ui` / `09-analytics` / `12-figma` / `99-logger`) stay excluded with a fixture test pinning their absence.
- `tests/scripts/test-karpathy-strategy-builtin.sh` (new, 18 cases): asserts strategy file existence, 7 candidate references present, 4 excluded references absent, all 4 rule headers present, conflict resolution order documented.
- `schemas/workflows/karpathy-real-task-dogfood.yaml` (added in v0.24.8 development cycle): single-step workflow exercising the Karpathy guardrail on real input. Sister workflow to `karpathy-guardrails-smoke`.
- `cap-workflow.sh` defaults `CAP_HOME` to `${HOME}/.cap` via the bash `:=` idiom and exports it to subprocesses, so the python binder picks up the shared layer registry without operators having to prefix every `cap workflow` command with `CAP_HOME=$HOME/.cap` (follow-up from v0.24.7 Phase 1 dogfood pain point).
- `tests/scripts/test-cap-workflow-cap-home-default.sh` (new, 6 cases): pins the `:=` semantics for unset / explicit / empty-string and the negative integration that explicit `CAP_HOME` is preserved.
- `docs/cap/ROLE-SKILL-REGISTRY-MODEL-MEMO.md`: gains a Phase 2 Risks subsection capturing the inference-rule misreading observed in dogfood run #3 — when registry entries already carry `agent_alias` for selectability reasons, the legacy "agent_alias present → role" inference reads counterintuitively. Mitigation: explicit `kind` always wins; the existing fixture case 4b pins this contract.
- `docs/cap/KARPATHY-GUIDELINES-INTEGRATION-MEMO.md` Phase 1 Dogfood Evidence Log: 7 real runs across 4 task shapes (smoke / code-review / refactor-proposal / debug) with Claude + Codex cross-provider parity confirmed. Explicit Phase 2 closeout subsection records the promotion, the agent-specific reference rationale, the deliberate non-actions, and the open follow-ups Phase 2 does NOT close.
- `docs/cap/README.md` index: rows for the Karpathy integration memo, the role/skill registry model memo, and the run observability Phase 5 Later memo (backfilling earlier release indexing gaps).

### Changed

- 7 candidate agent prompts (`01-supervisor` / `02-techlead` / `04-frontend` / `05-backend` / `07-qa` / `10-troubleshoot` / `90-watcher`) gain a methodology-strategy reference to `agent-skills/strategies/karpathy-guidelines.md`. Wording is short (1 bullet per agent) and contextualised; the memo's "concise enough to avoid bloating every task prompt" requirement is honoured.
- `~/.cap/shared/skills.yaml` Karpathy entry adopted explicit `kind: skill` (user-local change, NOT in repo) during v0.24.8 dogfood. Schema already supports this in v0.24.8.

### Verified

- New: karpathy-strategy-builtin **18 / 18**, cap-home-default **6 / 6**, skill-registry-kind-field **10 / 10** (from v0.24.8 baseline).
- 7 dogfood real-runs (Claude + Codex) all completed/success, no prompt conflict, all four Phase 2 entry criteria satisfied. Evidence log in `docs/cap/KARPATHY-GUIDELINES-INTEGRATION-MEMO.md`.
- Existing skill-registry suites unchanged: override **29 / 29**, resolver **22 / 22**.
- Run-observability + CLI surface stay green: watch **104 / 104**, logs **63 / 63**, inspect **56 / 56**, ps-tip **9 / 9**, help-topics **43 / 43**, help-surface **71 / 71**, shortcuts **12 / 12**, unknown-command **16 / 16**, namespace-unknown **23 / 23**, mapper-global **14 / 14**.
- Full smoke: `scripts/workflows/smoke-per-stage.sh` — **87 passed / 0 failed / 0 skipped** (parity with v0.24.8 baseline; no regression).

### Boundary

- Phase 2 promotion is **agent-prompt-reference-only**. No `engine/runtime_binder.py` change. No `scripts/cap-workflow-exec.sh` change. No global provider config (`~/.codex/`, `~/.claude/`) touched.
- Shared-layer registry entry (`~/.cap/shared/skills.yaml` + `~/.cap/shared/skills/karpathy-guidelines.md`) is **preserved**, not removed. The two paths coexist: capability-binding workflows still resolve through shared layer; agent-role workflows now reference the builtin strategy directly.
- 4 excluded agents stay excluded by intentional design. Future expansion needs concrete per-role dogfood evidence, not a default rollout.

---

## [v0.24.8] - 2026-05-10

> Patch release — Role / Skill Registry Phase 1 (schema preparation). Adds an optional `kind` discriminator (`role` / `skill`) to the skill-registry schema and the design memo behind it. Schema-only: the runtime does NOT yet branch on `kind`; future runtime work will switch on this enum instead of inferring entry type from `agent_alias` presence.

### Added

- `schemas/skill-registry.schema.yaml`: new optional `kind` field with enum `[role, skill]`. Description spells out the legacy compatibility rule used until the runtime adopts `kind`:
    - `agent_alias` present → `kind = role` (legacy executable role)
    - `agent_alias` absent  → `kind = skill` (legacy mountable strategy)
  Real entries today resolve as expected: all builtin agent-skills implicitly `kind=role`; the Karpathy shared-layer entry implicitly `kind=skill`. Entries can opt into explicit `kind` without changing runtime behaviour.
- `docs/cap/ROLE-SKILL-REGISTRY-MODEL-MEMO.md`: planning memo for the staged separation of executable agent roles from attachable advisory skills / guardrails. Captures the conceptual model, complexity assessment (low-risk schema work vs higher-risk runtime work), phase plan, and entry / exit criteria. Non-goal: no runtime implementation in this memo.
- `tests/scripts/test-skill-registry-kind-field.sh` (new, 10 cases): sandbox layout with three registry shapes (legacy / explicit `kind=role` / explicit `kind=skill`) loaded through `RuntimeBinder.load_skill_registry`. Asserts the loader doesn't reject the new field, all three entries appear with correct source-layer attribution, the legacy compat inference is observable, explicit `kind` beats inference, and Phase 1 boundary holds (none of the three is silently excluded from `_find_candidates`).
- `docs/cap/README.md` index: rows pointing at the new memo plus a backfill row for `KARPATHY-GUIDELINES-INTEGRATION-MEMO.md` (v0.24.7 release missed it).

### Changed

- None. Phase 1 is strictly additive: schema field + memo + fixture. `engine/runtime_binder.py`, `scripts/cap-workflow-exec.sh`, `agent-skills/`, `~/.codex/`, and `~/.claude/` are all untouched.

### Verified

- Dogfood on the live `~/.cap/shared/skills.yaml`: added `kind: skill` to the `shared-karpathy-guidelines` entry. Real bind output:
    ```
    summary: total=1, resolved=1, fallback=0, required_unresolved=0
    mount_guardrails (phase 1) => resolved / skill=shared-karpathy-guidelines / provider=shared
    ```
  Direct `RuntimeBinder.load_skill_registry()` query confirms `kind: skill` round-trips into the loaded dict alongside the existing `agent_alias`, `source_layer`, and `source_path`.
- New: skill-registry-kind-field **10 / 10**.
- Existing fixtures unchanged: skill-registry-override **29 / 29**, skill-registry-resolver **22 / 22**, cap-home-default **6 / 6**.
- Run-observability + CLI surface stay green: watch **104 / 104**, logs **63 / 63**, inspect **56 / 56**, ps-tip **9 / 9**, help-topics **43 / 43**, help-surface **71 / 71**, shortcuts **12 / 12**, unknown-command **16 / 16**, namespace-unknown **23 / 23**, mapper-global **14 / 14**.
- Full smoke: `scripts/workflows/smoke-per-stage.sh` — **87 passed / 0 failed / 0 skipped** (parity with v0.24.7 baseline; no regression).

### Boundary

- Phase 1 is schema-only. No runtime branching on `kind`, no candidate-ranking changes, no prompt-assembly changes, no role + attached-skill composition support. Phase 2 (runtime adoption) and Phase 3 (composition) are gated on dogfood evidence per the model memo.

---

## [v0.24.7] - 2026-05-10

> Patch release — wire the Karpathy guardrails shared-layer skill end-to-end through the RuntimeBinder (Phase 1 dogfood scaffold) and default `CAP_HOME` to `~/.cap` so `cap workflow *` finds the shared layer without manual env prefixing.

### Added

- **Karpathy guardrails Phase 1 dogfood scaffold** — staged integration of the [Andrej Karpathy LLM-coding guidelines](https://x.com/karpathy/status/2015883857489522876) into CAP via the shared layer (does NOT touch builtin `agent-skills/`, does NOT touch global `~/.codex/` or `~/.claude/`).
  - `docs/cap/KARPATHY-GUIDELINES-INTEGRATION-MEMO.md`: planning memo with Phase 1 (shared layer) and Phase 2 (builtin candidate) entry / exit criteria. Phase 2 is gated on Phase 1 dogfood evidence.
  - `schemas/capabilities.yaml`: declares two new advisory capabilities `engineering_guardrails` and `code_review_guardrails`. `allowed_agents` is broad (shell + supervisor + techlead + frontend + backend + qa + troubleshoot + watcher) so any role can mount the guardrail when a workflow asks for it.
  - `schemas/workflows/karpathy-guardrails-smoke.yaml`: single-step smoke workflow that exists only to verify the binder picks the shared skill end-to-end. No real artifacts produced.
  - `.cap/constitution.yaml` + `.cap.constitution.yaml` (synced): `allowed_capabilities` extended with the two guardrail capabilities; `workflow_policy.allowed_source_roots` extended with `~/.cap/shared/skills.yaml` and `~/.cap/shared/skills` as forward-compat opt-in.
  - User-local pieces (intentionally NOT committed): `~/.cap/shared/skills/karpathy-guidelines.md` (CAP-style guardrail distilled from upstream `SKILL.md` plus explicit conflict-resolution priority order) and `~/.cap/shared/skills.yaml` (registry entry binding the skill to the two new capabilities).

- **`CAP_HOME` default in cap-workflow.sh** — `: "${CAP_HOME:=${HOME}/.cap}"; export CAP_HOME` near the dispatcher prelude. The python binder sub-process now finds the shared-layer skill registry without operators having to prefix `CAP_HOME=$HOME/.cap` on every `cap workflow` invocation. Bash `:=` semantics preserve explicit user values; an empty string `CAP_HOME=''` falls back to the default same as unset (intentional — any falsy value triggers the default).

- **New test fixture**: `tests/scripts/test-cap-workflow-cap-home-default.sh` (6 cases) covers the `:=` unit semantics for unset / explicit / empty-string, subprocess inheritance via the dispatcher prelude, and a negative integration confirming `:=` doesn't clobber explicit `CAP_HOME`.

### Verified

- Karpathy Phase 1 real-run dogfood: **2 / 2 PASS** with no prompt conflicts.
  - Claude (2.1.137) — `run_20260510013742_00d4f6e5`, 98s, completed/success.
  - Codex (0.128.0) — `run_20260510014158_f3846a3f`, 50s, completed/success.
  - Both providers correctly resolved `prompt_file: skills/karpathy-guidelines.md` to `~/.cap/shared/skills/karpathy-guidelines.md`, mounted the `karpathy-guidelines` role, applied the Karpathy 4 rules (think before / simplicity / surgical / goal-driven), and emitted advisory output without scope creep.
- New: cap-home-default **6 / 6**.
- Run-observability + CLI surface fixtures unchanged: watch **104 / 104**, logs **63 / 63**, inspect **56 / 56**, ps-tip **9 / 9**, help-topics **43 / 43**, help-surface **71 / 71**, shortcuts **12 / 12**, unknown-command **16 / 16**, namespace-unknown **23 / 23**, mapper-global **14 / 14**.
- Full smoke: `scripts/workflows/smoke-per-stage.sh` — **87 passed / 0 failed / 0 skipped** (parity with v0.24.6 baseline; no regression).

### Boundary

- Phase 1 dogfood: shared-layer-only integration. No changes to `agent-skills/`, `cap-workflow-exec.sh`, AI prompts (other than the new shared skill prompt itself), agent role files, `~/.codex/`, or `~/.claude/`.
- `CAP_HOME` default scope is `cap-workflow.sh` only; generalising to `cap-entry.sh` (which would also help cap-task / cap-replay callees) is deferred until a concrete case demands it.
- Phase 2 builtin promotion (moving the guardrail to `agent-skills/strategies/`) is gated on dogfood evidence per the integration memo; not part of this release.

---

## [v0.24.6] - 2026-05-09

> Patch release — Phase 5 read-only filter wave. Three docker / kubectl-style filters bring `cap workflow watch` and `cap workflow logs` closer to filtering ergonomics seen in production observability tools. Pure render / parse layer.

### Added

- `cap workflow watch --failed-only`: filter steps / sessions / artifacts to failed entries only. Empty filter result renders `(no failed steps)` placeholder so operators see the filter actually ran. Composes with `--compact`, `--json`, `--once`, `--interval`.
- `cap workflow watch --step <step-id>`: focus on a single step's row + its sessions + artifacts produced by it. Missing step exits 1 with Chinese stderr matching the `cap workflow logs --step` error wording. Composes with `--failed-only` (intersection).
- `cap workflow logs --since <value>`: docker-style timestamp filter. Accepts relative duration (`30s` / `5m` / `1h` / `2d`) or absolute timestamp (`YYYY-MM-DD HH:MM:SS` / ISO 8601). Streams `workflow.log` lines whose `[YYYY-MM-DD HH:MM:SS]` glyph is `>=` cutoff; lines without parseable timestamps are dropped (consistent with docker behaviour). Composes with `--step` (filters the resolved step file).
- All three flags surface in dispatcher `--help` (`cap workflow watch --help` / `cap workflow logs --help`), `cap help observe` topic, and `cap help --advanced`.

### Changed

- `cap workflow logs --since` combined with `-f` is rejected up front by the bash dispatcher with a workaround hint pointing at single-shot `--since` or follow-without-filter. Composing follow with the timestamp filter is intentionally deferred — the value-to-complexity ratio is too low for the first `--since` cut.

### Verified

- New: watch **104 / 104** (+25 Phase 5), logs **63 / 63** (+17 Phase 5).
- Other observability + CLI surface fixtures: help-topics **43 / 43**, help-surface **71 / 71**, inspect **56 / 56**, ps-tip **9 / 9**, shortcuts **12 / 12**, unknown-command **16 / 16**, namespace-unknown **23 / 23**, mapper-global **14 / 14** — all PASS.
- Full smoke: `scripts/workflows/smoke-per-stage.sh` — **87 passed / 0 failed / 0 skipped** (parity with v0.24.5 baseline; no regression).

### Boundary

- Pure read-only filter / parse layer. No changes to `cap-workflow-exec.sh`, AI prompts, agent steps, or provider invocation. Zero token cost.

---

## [v0.24.5] - 2026-05-09

> Patch release — help / docs discoverability. After v0.24.3 / v0.24.4 shipped the full observability surface (logs / watch / inspect / ps), users still had to read CHANGELOG or the operations guide to find them. v0.24.5 plants signposts on every help path so the surfaces surface themselves.

### Added

- `cap help workflow` topic page: full cap workflow subcommand index grouped into `[Discover]` / `[Run]` / `[Observe]` / `[Constitution / Task]`. Shorthand documented (`cap workflow <id>` → show / run). Alias `cap help wf`.
- `cap help observe` topic page (alias `observability`): when-to-use-which-surface table covering `logs` / `logs -f` / `logs --tail` / `logs --step` / `watch` (default / `--once` / `--compact` / `--json`) / `inspect` / `ps`. Includes the shared status glyph table (`✓ ok` / `● running` / `○ pending` / `✗ failed` / `⊘ skipped` / `◐ blocked` / `⊠ cancelled` / `? unknown`), the step-output fallback chain (`raw.log` → `md` → `handoff.md`), and the boundary disclaimer.
- `cap help` main page gains an `[Observe Runs]` block (4 lines: `ps` / `logs` / `watch` / `inspect`) so first-time users see the observability surfaces without `--advanced`. A topic-style footer points at the new topic pages.
- `cap workflow logs --help` and `cap workflow watch --help` now print dispatcher-side usage with the FULL flag list. The previous behaviour forwarded to Python's argparse, which couldn't see bash-side flags (`logs --tail` / `-f`) or render the watch behaviour matrix / status glyph notes. Both pages now include usage examples and a See-also block linking to the observe topic.
- README `## Observe / Debug Workflow Runs` gains a 「常見除錯流程」 subsection: three scenario-driven walkthroughs in 繁中 narrative + English commands — failed run triage, live progress check, per-step provider output. Followed by a jump table to `cap help observe` / `cap workflow logs --help` / etc.
- `tests/scripts/test-cap-help-topics.sh` (new, 43 cases): topic page rendering + alias routing (`wf` → workflow, `observability` → observe) + unknown-topic exit 1 with the updated Available list naming all four pages.

### Changed

- `cap help <unknown>` Available list now names all four topic pages: `cap help | cap help --advanced | cap help workflow | cap help observe`.
- The `main help hides workflow inspect` regression assertion was removed: inspect is now an intentional first-screen entry under `[Observe Runs]`.

### Verified

- New: help-topics **43 / 43**.
- Run-observability suites: watch **79 / 79** (+13 dispatcher --help), inspect **56 / 56**, logs **46 / 46** (+9 dispatcher --help), ps-tip **9 / 9**.
- CLI / namespace surface fixtures: help-surface **71 / 71** (+6 P3), shortcuts **12 / 12**, unknown-command **16 / 16**, namespace-unknown **23 / 23**, mapper-global **14 / 14**.
- Full smoke: `scripts/workflows/smoke-per-stage.sh` — **87 passed / 0 failed / 0 skipped** (parity with v0.24.4 baseline; no regression).

### Boundary

- Pure help / docs / dispatcher polish. No changes to `cap-workflow-exec.sh`, AI prompts, agent steps, or provider invocation. Zero token cost.

---

## [v0.24.4] - 2026-05-09

> Patch release — observability dashboard polish (status glyphs, failed-step hints, Next-action footer) plus CLI surface alignment (ps tip, logs `--tail`, fuzzy unknown command, namespace error parity).

### Added

- Status glyphs across `watch` / `inspect`: every step row, session row, and run-state header carries a unicode glyph + normalized label (`✓ ok` / `● running` / `○ pending` / `✗ failed` / `⊘ skipped` / `◐ blocked` / `⊠ cancelled` / `? unknown`). Trailing label keeps rows readable when a font drops the glyph.
- `cap workflow watch` dashboard footer (both compact and verbose): a `Next:` / `# Next` block recommends the next command based on run state. Failed run → `cap workflow logs <run-id> --step <failed-step>` + `cap session inspect --run-id <run-id>`. Running run → `cap workflow watch <run-id>` + `cap workflow logs -f <run-id> --step <running-step>`. Completed run → `cap workflow inspect <run-id>`.
- `cap workflow inspect` Follow-up section gains a `Next:` sub-block driven by the same hint helper. Self-reference filter prevents a completed run from suggesting "inspect <same run>" within its own inspect output.
- `cap workflow ps` tip footer: docker-style trailer line `Tip: cap workflow logs <run-id> | watch <run-id> | inspect <run-id>` beneath the table when there are runs. Suppressed on empty stores.
- `cap workflow logs --tail N`: docker habit. Without `-f`: `tail -n N`. With `-f`: `tail -n N -f`. Non-positive integers rejected up front so the user never sees a confusing tail(1) error.
- `latest_artifact:` label across surfaces: watch verbose / inspect rename `latest:` to `latest_artifact:` (clearer vs run / log timestamps); watch compact adds inline `(latest: <name>)` next to the artifact count.
- Fuzzy unknown-command suggestions: `cap updae` → `Did you mean: cap update?`, `cap hellp` → `Did you mean: cap help?`. Uses python's `difflib.get_close_matches` (cutoff 0.6); unrelated garbage stays silent so weak matches don't nag operators.
- New test fixtures: `test-cap-workflow-ps-tip.sh` (9 cases) and `test-cap-namespace-unknown.sh` (23 cases). `test-cap-workflow-watch.sh` grows to 66 cases (+22 P2); `test-cap-workflow-inspect.sh` to 56 (+6 P2); `test-cap-workflow-logs.sh` to 37 (+12 `--tail`); `test-cap-entry-unknown-command.sh` to 16 (+7 fuzzy).

### Changed

- Namespace unknown-subcommand wording aligned to the v0.24.2 skill / provider format `Unknown <ns> subcommand: <x>` + `Available: <pipe-separated list>`:
  - `scripts/cap-task.sh`, `scripts/cap-replay.sh`, `scripts/cap-project.sh` realigned (legacy lowercase `cap-task: unknown subcommand:` etc. removed).
  - `scripts/cap-workflow.sh` keeps the shorthand fallback (`cap workflow <id>` still routes to `show` / `run`) but adds an `Available subcommands:` hint beneath the `workflow not found:` line so typos surface clearly without breaking the shorthand.
- `cap workflow watch --tail` default sentinel keeps the v0.24.3 verbose=10 / compact=1 split; no behaviour change here, just kept consistent with the new compact dashboard.

### Verified

- Run-observability suites: watch **66 / 66**, inspect **56 / 56**, logs **37 / 37**, ps-tip **9 / 9**.
- Namespace / CLI surface fixtures: namespace-unknown **23 / 23**, help-surface **65 / 65**, shortcuts **12 / 12**, unknown-command **16 / 16**, mapper-global **14 / 14**.
- Full smoke: `scripts/workflows/smoke-per-stage.sh` — **87 passed / 0 failed / 0 skipped** (parity with v0.24.3 baseline; no regression).

### Boundary

- Pure read-only / render layer. No changes to `cap-workflow-exec.sh`, AI prompts, agent steps, or provider invocation. Zero token cost.

---

## [v0.24.3] - 2026-05-09

> Patch release — ship a docker-like run observability surface (`logs` / `watch` / `inspect` follow-up) and translate CLI messages from Chinese to English.

### Added

- `cap workflow logs <run-id>` — print `workflow.log` to stdout (docker-like). `-f` / `--follow` for `tail -f` mode.
- `cap workflow logs <run-id> --step <step-id>` — per-step provider output via the `raw.log → md → handoff.md` fallback chain. Legacy `raw.log` is honoured when present; `<phase>-<step>.md` is the current SSOT; `<phase>-<step>.handoff.md` is the last-resort Type D summary. Operators don't need to know phase numbers — the resolver globs across phases. Also supports `-f --step` to follow the resolved file.
- `cap workflow watch <run-id>` — live snapshot view of run state. tty default loops with ANSI clear-and-redraw every 2s; pipe / redirect auto-falls-back to single-shot so JSON / log redirects stay grep-friendly.
- `cap workflow watch` flags: `--once` (deterministic single-shot), `--json` (always single-shot, full payload for jq pipelines), `--interval N`, `--tail N`, `--compact` (single-screen <15-line view; default `--tail` collapses to 1, override with explicit `--tail N`).
- `cap workflow inspect <run-id>` gains a `# Follow-up` section after Logs Pointer, advertising `cap workflow logs / watch <run-id>` so operators can pivot from a finished run to the live surfaces. Skipped when `run_id` is missing (legacy / corrupt status entries) and absent from `--json` output.
- `--cap-home PATH` flag on every observability surface for cross-repo / sandbox reads.
- `docs/cap/RUN-OBSERVABILITY-GUIDE.md` — user-facing operations guide (TL;DR table, run_dir layout reference, behaviour matrix, `--cap-home` walkthrough).
- `docs/cap/RUN-OBSERVABILITY-MEMO.md` — Phase 1–4 planning memo, kept as historical roadmap alongside the live guide.
- README `## Observe / Debug Workflow Runs` section with one-line use cases for each surface; `docs/cap/README.md` index gains rows for both the guide and the memo so docs entry directs by intent (operate vs design rationale).
- New test suites: `tests/scripts/test-cap-workflow-logs.sh` (25 cases) and `tests/scripts/test-cap-workflow-watch.sh` (44 cases). `tests/scripts/test-cap-workflow-inspect.sh` extended to 50 cases for Phase 4 follow-up assertions.

### Changed

- `cap` CLI user-facing messages translated from Traditional Chinese to English: `install.sh` banner / step prompts, `cap-entry.sh` (main + advanced help, unknown-command errors, skill subcommand errors), `cap-workflow.sh` (usage / `--cli` errors / "workflow not found" / design-source halts), `cap-workflow-exec.sh` (CLI-missing prompts, auth / rate-limit / network / trust hints, shell→AI fallback messaging), `cap-provider.sh`, `mapper.sh` (install / uninstall / sync banners, `CAP_LINK_MODE` errors). Test fixture assertions updated in lockstep. Heads-up: scripts that grep localized CLI output should switch to the English equivalents.
- `cap workflow watch --tail` default sentinel changed from `10` to `None`; verbose mode resolves to `10` (unchanged behaviour), compact mode resolves to `1` so the terse view actually fits in a single screen.

### Verified

- Run-observability suites: logs **25 / 25**, watch **44 / 44**, inspect **50 / 50** PASS.
- CLI surface fixtures: help-surface **65 / 65**, shortcuts **12 / 12**, unknown-command **9 / 9**, mapper-global **14 / 14**.
- Full smoke: `scripts/workflows/smoke-per-stage.sh` — **87 passed / 0 failed / 0 skipped** (parity with v0.24.2 baseline; no regression).

### Boundary

- Pure read-only observability layer. No changes to `cap-workflow-exec.sh`, AI prompts, agent steps, or provider invocation. Zero token cost — every surface consumes existing run_dir files (`workflow.log`, `runtime-state.json`, `agent-sessions.json`, `<phase>-<step>.md` / `.handoff.md`).
- `raw.log` writer **not** revived. Inventory showed `raw.log` was a redundant byte-level dup of `<phase>-<step>.md` and stopped being produced after April 24; Phase 3 reads it when present (legacy runs) but does not reintroduce the writer.

---

## [v0.24.2] - 2026-05-08

> Patch release — add safe CLI shortcuts for common namespaces and read-only version flags.

### Added

- Namespace shortcuts:
  - `cap p ...` / `cap proj ...` as shorthand for `cap project ...`
  - `cap wf ...` as shorthand for `cap workflow ...`
  - `cap prov ...` as shorthand for `cap provider ...`
- Global read-only version flags: `cap -v` and `cap --version`, both equivalent to `cap version`.
- Shortcut regression fixture covering namespace aliases and version flags.

### Changed

- `cap help` now shows the shortcut surface without adding mutating update flags such as `-u`.

### Verified

- Help surface fixture: `tests/scripts/test-cap-entry-help-surface.sh` — **64 passed / 0 failed**.
- Shortcut fixture: `tests/scripts/test-cap-entry-shortcuts.sh` — **10 passed / 0 failed**.
- Unknown-command fixture: `tests/scripts/test-cap-entry-unknown-command.sh` — **9 passed / 0 failed**.
- Full smoke: `scripts/workflows/smoke-per-stage.sh` — **87 passed / 0 failed / 0 skipped**.

---

## [v0.24.1] - 2026-05-08

> Patch release — reduce the default `cap help` surface after the v0.24.0 onboarding checkpoint.

### Changed

- `cap help` now shows only the first-run path: help, version, update, skill/workflow discovery, project init/status/doctor, provider doctor, and workflow run/dry-run.
- Advanced, maintenance, governance, replay, promote, session, and native CLI wrapper entries moved out of the default view and remain discoverable through `cap help --advanced`.

### Verified

- Help surface fixture: `tests/scripts/test-cap-entry-help-surface.sh` — **54 passed / 0 failed**.
- Unknown-command fixture: `tests/scripts/test-cap-entry-unknown-command.sh` — **9 passed / 0 failed**.
- Full smoke: `scripts/workflows/smoke-per-stage.sh` — **86 passed / 0 failed / 0 skipped**.

---

## [v0.24.0] - 2026-05-08

> GA checkpoint — pause the harness line and promote the CAP onboarding / provider readiness improvements into a stable release.

### Added

- `cap provider doctor` as a read-only provider readiness inspector. It checks Claude / Codex CLI availability without attempting login, launching interactive flows, or consuming tokens.
- Provider fail-fast guard for `cap workflow run --cli <provider>` so missing `claude` / `codex` binaries halt before workflow execution with actionable guidance.
- Regression coverage for `cap workflow list` outside a CAP project, unknown command handling, help surface split, provider doctor, and provider fail-fast behavior.
- `policies/test-fixture-authoring.md` documenting shell fixture guidance for `set -o pipefail`, `grep -q`, and early-close `SIGPIPE` hazards.

### Changed

- `cap help` now shows only the common user path; maintenance, diagnostic, planned, deprecated, and legacy entries moved to `cap help --advanced`.
- `cap list` now uses the same unknown-command catch as other unsupported commands instead of printing migration suggestions.
- `cap workflow list` no longer requires a stable project id; static workflow discovery works from `~` or any non-project directory.
- `repo.manifest.yaml` `cap_version` is now `v0.24.0`.

### Fixed

- Codex multi-turn duplicate-output handling in `cap-workflow-exec.sh` now isolates temporary output and avoids leaking duplicated assistant blocks.
- Linux fixture mtime checks prefer `stat -c` before macOS `stat -f`.
- Shell fixtures and smoke harness avoid `printf | grep -q` / `grep | head` patterns that can fail under `set -o pipefail` with exit `141`.

### Verified

- Full smoke: `scripts/workflows/smoke-per-stage.sh` — **86 passed / 0 failed / 0 skipped**.

---

## [v0.23.0-harness.3] - 2026-05-07

> Pre-release — second iteration on `cap update` terminal rendering. Same-version重裝情境也能呈現完整 stat box。

### Changed

- `cap update` 完成畫面整合 (`scripts/cap-release.sh:print_update_summary`)：版本資訊從外層 `Hooray! CAP has been updated to <prev> > <new>` 文字行搬入 stat box，與 Agents / Strategies / Workflows 並列為 `Version` 列；box 頂邊嵌入 `Charlie's AI Protocols` 品牌標識，外層 `Updating Charlie's AI Protocols` 標題刪除以避免重複；`Hooray!` 行簡化為情緒收尾。
- Stat box 改為**動態寬度**：以最長內容列（含長 detached SHA）為基準自動撐寬，不裁切 prev_ref。
- 配色擴充：stat label 改為 cyan、box 標題與 Hooray 行改為 magenta+bold、change-summary 分組標題（Features / Bug fixes / Documentation / Other changes）改為 blue+bold；yellow 外框與 dim/bold/green 的 prev>curr 語意保留。
- 多字節 box-drawing 修正：`repeat_char` 從 `tr`-based 改為純 bash loop，避免 `tr` 以 byte 為單位處理 UTF-8 三字節字元（如 `═`）時產生亂碼。

### Notes

- Plain-text fallback 行為不變：非 TTY 或 <8 色終端會自然退化為純文字。
- 無 schema / validator / CLI surface / workflow contract 異動。

---

## [v0.23.0-harness.2] - 2026-05-07

> Pre-release — UX-only refinement of `cap update` terminal rendering.

### Changed

- `cap update` 完成畫面改寫（`scripts/cap-release.sh:print_update_summary`）：依 prev..new commit subject 自動分組為 Features / Bug fixes / Documentation / Other changes，並新增 RPG 風格 stat box 顯示 Agents / Strategies / Workflows 的 `prev > curr` 數量對比；TTY 偵測支援 ≥8 色時上色，否則降級為純文字。無 schema / validator / CLI surface 異動。

---

## [v0.23.0-harness.1] - 2026-05-07

> Pre-release — Replay Contract H1–H4 與 Agent Skills Baseline (A0) 的封裝點：把「能否安全重播一次舊 run」從口頭承諾變成可機械驗證的 5-axis drift verdict。

### Added

- **`cap replay verify <run_id>` 端到端可重播驗證**（`engine/replay_verifier.py` + `scripts/cap-replay.sh`）：產生 `replayable / drifted_compatible / drifted_incompatible / unverifiable / not_found` 五種判決，對齊 `schemas/replay-verdict.schema.yaml` 與 `policies/replay-contract.md` v1.3。
- **5-axis drift aggregation** — H1（單軸 agent-skills baseline）→ H2（加入 project skill registry drift，`engine/project_skills_snapshot.py`）→ H3（擴至 5 軸：constitution / capability schema / workflow yaml whole-file snapshot，`engine/{constitution,capability_schema,workflow_yaml}_snapshot.py` + `engine/binding_summary.py`）。verdict 從 boolean 升級為「skill_id × override_kind × content_hash」結構化比對。
- **`--strict-unverifiable` opt-in flag**（H4）：把 unverifiable 結果視為失敗，配合 `source_layer` 解析修正以避免誤判。
- **Agent Skills Baseline 政策（A0）** — `policies/agent-skills-baseline.md` 定義 builtin baseline 與 project override 邊界；`schemas/skill-registry.schema.yaml` 新增 `disabled` tombstone 與 `replaces` override 欄位，由 `engine/runtime_binder.py` 在每個 run 紀錄 checksum 作為 replay 比對輸入。
- 使用者文件 `docs/cap/REPLAY-USER-GUIDE.md` 與設計備忘 `docs/cap/REPLAY-CONTRACT-DESIGN.md`。

### Changed

- `engine/runtime_binder.py` 在每個 run 鏡射 baseline checksum 與 5-axis input snapshots 到 run dir，使 verdict 計算可離線重放。
- `schemas/{agent-session,workflow-result,skill-registry}.schema.yaml` 擴充欄位以容納 baseline checksum 與 replay verdict 銜接點。

### Notes

- Harness pre-GA 觀察期；H5/H6/H7 仍進行中（觀察日誌 commit `4a26f47`），尚未進入 v0.23.0 GA。
- 本條 entry 為 governance debt 回填：v0.23.0-harness.1 原打 tag 時未同步 CHANGELOG，於 v0.23.0-harness.2 release 前一併補入以解除 release-check missing-entry。

---

## [v0.22.0] - 2026-05-06

> v0.22.0 GA — promote `v0.22.0-rc18` to the canonical v0.22.0 release. v0.22 is the **Platform Closeout** major: P0-P10 platform-level capabilities all reach steady state across rc1-rc18. The full capability map, before/after diff, dogfood 7-step verification chain, deferred governance debt, and rc1-rc18 對照表 live in `docs/cap/PLATFORM-CLOSEOUT-v0.22.md`. GA = pure promotion of rc18; no commits between rc18 and this tag.

### Highlights (P0-P10)

- **P0** — `cap` CLI baseline、`cap project init / status / doctor`、`.cap/<name>` config namespace SSOT、storage layout policy、provider isolation（`~/.claude` / `~/.codex` 不再被全域改寫）。
- **P1-P3** — project-constitution workflow、project-spec-pipeline、supervisor orchestration envelope schema (`schemas/supervisor-orchestration.schema.yaml`) + drift validation gate。
- **P4-P5** — handoff ticket Type C schema (`schemas/handoff-ticket.schema.yaml`)、agent session runner、provider adapter、prompt snapshot ledger（`cap session analyze` 可看 token / time hotspot）。
- **P6-P8** — governance gate runners (watcher / qa / security / logger)、`schemas/gate-result.schema.yaml`、fail-route consumer、rerun-failed-gate consumer、halt-on-high-risk policy。
- **P9** — three-layer workflow / skill / agent source resolver（project / shared / builtin precedence）、binding-report source metadata、`effective_allowed_roots` enforcement。
- **P10** — `cap promote inspect`、`cap promote project-constitution`、`cap promote workflow` typed CLI + apply / backup / validation / rollback framework + `policies/runtime-promote.md` v1.0 SSOT。

### Verified at GA

- Full smoke (`scripts/workflows/smoke-per-stage.sh`) **72 passed / 0 failed / 0 skipped**（與 rc17 / rc18 baseline 一致零 regression）。
- 17 個 P10 / P9 / P7 dedicated suite 全綠。
- Real Claude live dogfood（`cap workflow run project-constitution`，apples-to-apples vs rc17 prompt）：`<<<CONSTITUTION_JSON_BEGIN>>>` count = 1，`<<<CONSTITUTION_JSON_END>>>` count = 1（rc17 同 prompt 是 2/2 broken；rc18 prompt contract 修補後翻成 1/1 fixed）。

### Notes

- v0.22.0 = rc18 promoted；rc18 → GA 之間無 code change。
- rc14（P8 closeout）與 rc18（prompt contract fix）為 pure-tag release，narrative 以各自 tag annotation 為 SSOT，CHANGELOG 條目只做 cross-reference。
- 後續 deferred items roll over 至 v0.23+；canonical 待辦清單見 `docs/cap/MISSING-IMPLEMENTATION-CHECKLIST.md`。
- v0.22.0 為 v0.22.x 系列首個 tag；目前無 patch。

---

## [v0.22.0-rc18] - 2026-05-06

> Release candidate — close out the rc17 minimal Claude dogfood blocker by hardening the `project_constitution` prompt contract against duplicate `<<<CONSTITUTION_JSON_BEGIN/END>>>` fence pairs. Pure prompt-layer fix — no validator change, no schema change, no CLI surface change. Canonical narrative lives in the `v0.22.0-rc18` annotated tag (commit `efc76d8`).

### Fixed

- **Duplicate constitution fence in `draft_constitution` AI step output** (`schemas/workflows/project-constitution.yaml` + `agent-skills/01-supervisor-agent.md`)：rc17 minimal dogfood 中 AI 先以自由敘事 + fence pair #1 完成回答，再「為了符合 4 固定標題（`## 任務理解` / `## 執行重點` / `## 產出內容` / `## 交接摘要`）」整份重寫並產生 fence pair #2，被 `validate-constitution.sh:multiple_explicit_fences` 正確 halt（exit 41 schema_validation_failed，無 AI fallback）— 是 prompt 契約衝突而非 validator bug。**A**：在 `draft_constitution` step 的 `done_when` 加一條「整份 stdout 只能出現一對 fence」的硬規則並把 anti-pattern 列出（含「不要因為發現自己應該使用 4 個固定標題就重寫整份回答」明文警示）。**C**：`01-supervisor-agent.md` 新增 §2.6 涵蓋 `project_constitution` capability 的 fence 唯一性與 anti-pattern 解釋，鏡射 §2.5 對 `task_constitution` 的嚴格 schema 契約風格。**B**（把 `cap-workflow-exec.sh:structured_sections_for_capability` 從 prompt 末尾提前到開頭）deferred — 會影響所有 AI step prompt 結構，pre-GA 風險過高，留給 v0.23+ 一併 review。

### Verified

- Full smoke (`scripts/workflows/smoke-per-stage.sh`) **72 passed / 0 failed / 0 skipped**（無 deterministic regression vs rc17）。
- Real Claude dogfood, apples-to-apples（同一個 prompt）：rc17 `run_20260506210226_020492d9` fence BEGIN=2 END=2（broken）→ rc18 `run_20260506220841_001a38b9` fence BEGIN=1 END=1（fixed）。

### Notes

- rc18 是 v0.22.0 GA 前最後一個 rc；rc18 → GA 為 pure promotion，無新 commit。
- B 留給 v0.23+ 一起 review prompt 結構是否要做更深層改造（影響面是「所有 AI step prompt」而非「單一 capability」）。
- 本 tag 不取代 `v0.22.0` 正式版（GA 由本 CHANGELOG 上方的 v0.22.0 條目記錄）。

---

## [v0.22.0-rc17] - 2026-05-06

> Release candidate — fix the 11 pre-existing smoke failures inherited by rc16. Smoke goes from **61 pass / 11 fail** (rc16) to **72 pass / 0 fail** (rc17). The fixes are infrastructure-only — no new features, no schema changes, no policy changes; rc17 is the first rc that runs cleanly end-to-end on a fresh checkout.

### Fixed

- **Smoke `+x` regression — 5 product cap-* scripts checked in as `100644`**：`scripts/cap-task.sh` / `cap-workflow.sh` / `cap-promote.sh` / `cap-release.sh` / `cap-registry.sh` 在 git index 是 `100644`（不可執行）但 smoke 假設它們可直接 `bash -c` / `exec`；rc16 closeout 的 chmod 修補（`b32bdee`）只 cover 21 個 test 腳本，product script 漏修。`git update-index --chmod=+x` 一次補齊，去掉 4 個 smoke step 的 `not executable` / `missing` halt。

- **macOS symlink mismatch — Python `.resolve()` 與 bash logical PWD 不一致** (`engine/project_status.py` / `project_doctor.py` / `storage_health.py`)：CLI 入口呼 `args.project_root.resolve()` 跟 `args.cap_home.resolve()`，在 macOS sandbox（`mktemp -d` 路徑落在 `/var/folders/...`，是 `/private/var` 的 symlink）會把 logical path resolve 成 physical path；但 `scripts/cap-paths.sh:find_project_root` 用 `${PWD}`（logical），把 logical path 寫進 `.identity.json:origin_path`。下一次 status / doctor 比對時 `ledger_origin = /var/...` vs `current_origin = /private/var/...` 就誤判 `ledger_origin_mismatch` exit 53。三檔三個入口統一改成 `.absolute()`（純去 `~` 與 relative，不 follow symlink），並在每個 callsite 留 inline comment 解釋 SSOT。生產 repo（`/Users/...`）行為不變；只修正 sandbox false-collision。

- **P0c config namespace 漏網 — storage health 沒走 namespace fallback** (`engine/storage_health.py:run_health_check`)：P0c 把 project config 從 legacy `<root>/.cap.project.yaml` 搬到 namespaced `<root>/.cap/project.yaml`；`ProjectContextLoader.load()` 早就 prefer-namespaced + fallback-legacy（line 71-79），但 `run_health_check` 內 inline `cfg_path = loader.base_dir / loader.DEFAULT_PROJECT_CONFIG`（**只看 legacy 路徑**），跳過了 namespace 檢查。結果 `cap project init` 寫到 namespaced 後，下一次 `cap project status` 找不到 project_id config → 走 git_basename / basename_legacy / fallback fail 路徑。修補後鏡射 `loader.load()` 的 namespace-first lookup（`namespaced_cfg.is_file() ? namespaced : legacy`），與 `cap-paths.sh:read_project_id_from_config` SSOT 對齊。

- **`jsonschema` 缺 declared dep — 4 個 schema test 在沒裝的環境誤觸 fallback** (`engine/requirements.txt`)：`engine/{compiled_workflow,binding_report,project_constitution,supervisor_envelope}_validator.py` 用 `jsonschema.Draft202012Validator`，靠 `try-except ImportError` fallback 到 `fallback_required_only`（純 required-key check）。但 `requirements.txt` 從未 declare `jsonschema` 為 dep；不同機器跑出不同結果（裝過：`'X' is a required property`；沒裝：`missing required field 'X'`）。加 `jsonschema>=4,<5` 為 hard dep。

- **Schema test fixture — 對齊 `jsonschema` 真實錯誤訊息**（4 個 test 檔）：`tests/scripts/test-compiled-workflow-validation-hook.sh` / `test-binding-report-validation-hook.sh` / `test-compiled-workflow-normalization.sh` 的 missing-field 斷言改 `'schema_version' is a required property`（jsonschema 標準訊息）；`triggers minItems error` 接受 `'should be non-empty'`（jsonschema Draft 2020-12 minItems 訊息）。`tests/e2e/test-supervisor-orchestration-release-gate.sh` 的 9-key shape 改 10-key（多了 `preflight_report`，這是 P4 #10 加進去的，rc16 漏更新 fixture）。

### Verified

- Full smoke (`scripts/workflows/smoke-per-stage.sh`) **72 pass / 0 fail / 0 skipped**（rc16 是 61/11/0；rc17 拿掉 11 個 pre-existing fail）。
- 17 個 P10 / P9 / P7 dedicated suite 全綠（與 rc16 一致零 regression）。
- Token-free dogfood：`cap project status` / `cap project doctor` 在當前 repo 上 `health_status=ok` / `errors=0`；`cap promote inspect bogus-id` 正確回 `promote_artifact_not_found` exit 1。

### Notes

- rc17 不引入新功能、不改 policy、不改 schema、不改 CLI surface。所有變動都是把 rc16 closeout review §3 列為 deferred 的「P1/P2/P3/P6/P8 環境依賴 e2e」翻成 PASS。
- rc17 是第一個在 fresh checkout（裝完 `engine/requirements.txt` 後）就能 72/72 通過 smoke 的 rc。**這是把 rc 升 v0.22.0 GA 前的最後 blocker**。
- 升 GA 前還剩兩件人工確認的事：(1) 跑一次 live AI dogfood（`cap workflow run project-constitution` 含 token）→ 證明 spec pipeline 在真實 LLM 下穩定；(2) 至少一週的 user dogfood feedback gathering（rc17 ship 後）。

---

## [v0.22.0-rc16] - 2026-05-06

> Release candidate — close out P10 Detached Runtime and Promote / Publish AND deliver the v0.22 platform-level closeout review covering P0–P10 in one document. Aggregate 7 commits since rc15 (3× docs + 4× feat) into the typed promote surface (`cap promote inspect / project-constitution / workflow`) plus a single SSOT for "what CAP can do now" → `docs/cap/PLATFORM-CLOSEOUT-v0.22.md`. P10 全段 8/8 sub-items 完成；剩下 deferred items（detached runtime / publish / `--smoke` flag）明確列在 closeout review §3.

### Added

- **P10 #1 runtime-promote policy SSOT** (`b99b201`)：新增 `policies/runtime-promote.md` v1.0 共 11 段；定 promote 範圍（`project_constitution` + `compiled_workflow` 兩類，run-only / binding report 不可 promote）、target paths（namespaced 唯一寫入）、conflict 四 enum + backup `<target>.bak.<ISO>` 永不自動清、validation always-on + rollback 三 branch、CLI surface (`inspect` / `project-constitution` / `workflow`)、anti-patterns（不靜默 overwrite、不跳過 validation、不 chained promote）。後續 #2-#8 commit 都 cross-reference 本文件。

- **P10 #2.1 schema migration** (`e8054a5`)：`schemas/workflow-result.schema.yaml.promote_candidates[].items` 從 P0 carried 的 loose `(artifact_name, path, target_repo_path, reason)` 改為 §5.2 嚴格契約：required `[source_path, target_path, artifact_type, reason]` + optional `validation_schema` / `source_layer` / `source_revision`，`artifact_type` enum 限制 `[project_constitution, compiled_workflow]`。`tests/scripts/test-workflow-result-schema.sh` Negative 9 / 10 加 2 case（10 → 12 cases）。

- **P10 #2.2 promote candidate producer** (`7ea621d`)：新模組 `engine/promote_candidate_producer.py:produce_candidates(run_result, *, project_root, cap_home)` 取代 P0 hard-coded `[]`。Pure read-only path-existence check：`task_id` + constitution snapshot 存在 → emit `project_constitution`；`workflow_id` + `final_state=="completed"` + 任一 .json/.yaml/.yml 在 compiled-workflows/<id>/ → emit `compiled_workflow`（取 mtime 最新）；`final_state != completed` 紅線阻擋（policy §5.3）；missing source / `project_id="unknown"` 靜默 no-emit 不 raise。`engine/result_report_builder.py` 加 `project_root` kwarg + thin `_produce_promote_candidates` wrapper（lazy import + degrade-to-`[]`）；`scripts/cap-result-emit.sh` 補 6 個 args。`tests/scripts/test-promote-candidate-producer.sh` 8 cases / 24 assertions。

- **P10 #3 cap promote inspect + shared resolver** (`3d8f352`)：模組三分（producer / resolver / cli），`engine/promote_resolver.py` 引入 `ResolvedPromote` frozen dataclass + `resolve_promote(artifact_id)` 三層查找（task_id → workflow_id → null）+ `conflict_kind` 三 enum (`no_target` / `identical` / `diff`，`filecmp.cmp(shallow=False)` 真比 byte) + `<target>.bak.<ISO>` template + `make_template_backup_path` helper（給 #4 重用）。`engine/promote_cli.py:cmd_inspect` + `scripts/cap-promote.sh inspect` dispatch；text 4 sections + JSON `ok=true` / 不 found 時 `promote_artifact_not_found` exit 1。`tests/scripts/test-cap-promote-inspect.sh` 10 cases / 32 assertions。

- **P10 #4 + #6 cap promote project-constitution + apply framework** (`7361ebe`)：新模組 `engine/promote_apply.py` 是 generic apply primitives — `ApplyResult` 11 個 action enum + `apply_promote(resolved, *, expected_artifact_type, dry_run, force, ...)` 完整 dry-run / backup / write / validate / rollback；`_validate_target_via_step_runtime` inline YAML/JSON loader + `jsonschema.Draft202012Validator`（fallback `step_runtime.validate_jsonschema_fallback`），canonical `{"ok": bool, "errors": list[str]}`；`_rollback_target` 三 branch（unlink fresh / restore from backup / no-backup-fail）。`cmd_project_constitution` + bash dispatch；`tests/scripts/test-cap-promote-project-constitution.sh` 13 cases / 37 assertions。**P10 #6 validation framework** 與本子項共生 — apply_promote 結尾自動串 validate → rollback；P10 #5 共用同路徑跑第二種 artifact_type 完成 framework 驗證。

- **P10 #5 cap promote workflow** (`7506cea`)：`cmd_workflow` 鏡射 `cmd_project_constitution` 結構，差異只 `expected_artifact_type="compiled_workflow"`；apply_promote framework 已在 #4 generic 化所以本子項只做 typed CLI + bash dispatch。Resolver 用 `require_completed=False` (P10 #3) 給 inspect 描述失敗 run 的 snapshot；apply 的 final_state 安全網由 *producer* 端 emit gate 負責，schema validation 是結構性紅線。`tests/scripts/test-cap-promote-workflow.sh` 9 cases / 32 assertions（dry-run / apply fresh / identical skip / conflict halt / force backup / validation rollback / type mismatch / unknown id / bash 對齊）。

### Documentation

- **P10 #7 cap promote 使用者面向文件 + roadmap 同步** (`b32bdee`)：新增 `docs/cap/PROMOTE-LIFECYCLE.md` 12 段使用者操作指南：lifecycle 三步走 ASCII 流程圖 / 三條 typed CLI 用法 + JSON 形狀範例 / generic escape hatch 邊界（明確標**不走 typed validation pipeline**）/ 共用 flag 表 / backup + validation + rollback 三 branch 對應 / 13 個 action enum 速查 / FAQ + 腳本消費穩定欄位清單。`docs/cap/IMPLEMENTATION-ROADMAP.md` Phase 11 promote 段 11 條 `[ ]` 全部翻 `[x]`，每條 cross-reference commit + policy 段落。

- **P10 #8 smoke wiring + chmod 修復**（同 `b32bdee`）：`scripts/workflows/smoke-per-stage.sh` step 37-40 接 4 個 P10-specific test（test-workflow-result-schema 早在 step 18 P0 #5 已接，不重複）；順手 chmod +x 修 21 個 git tracked 但 working-tree 缺 `+x` 的 pre-existing test files（純 file-mode 修復，無功能變動）。修補前 smoke 43 pass / 29 fail，修補後 **61 pass / 11 fail**（+18 全是 chmod 修出的 fixture）；剩 11 fail 為 P1/P2/P3/P6/P8 環境依賴 e2e 與 P10 無關。

- **v0.22 Platform Closeout Review**（本 commit）：新增 `docs/cap/PLATFORM-CLOSEOUT-v0.22.md` — P0-P10 platform-level 收斂文件，回答三件事：(1) 現在 CAP 能做什麼（capability map by phase）；(2) P1-P10 帶來什麼提升（before / after diff table）；(3) 還剩哪些治理債（deferred items / escape hatches / 文件重複來源 / smoke suite 變肥）。包含 dogfood 7-step verification chain（token-free 部分由 17 個 focused suite 共 ~454 assertions 嚴格覆蓋；live AI run 由使用者選擇是否花 token 跑 step 3）+ 關鍵 SSOT 索引（policies / schemas / docs/cap）+ rc1-rc16 對照表。`TODOLIST.md` / `docs/cap/MISSING-IMPLEMENTATION-CHECKLIST.md` 「更新日期」同步 cross-reference 本 closeout 文件。

### Notes

- **v0.22 P0-P10 全段完成**：從「rely on prompt 紀律 + 人工記憶 + agent 自報」走到「schema 為門禁 + runtime 為審計 + promote-validate-rollback 為防線」。詳細 before/after diff 見 closeout review §2。
- **Deferred to a later cycle**（明確未做，不阻塞 v0.22 GA）：detached / background workflow run（Phase 12）、run status polling、publish workflow（cross-repo）、`cap promote workflow --smoke` flag、Codex / Claude 原生 SKILL.md export、plugin / marketplace 安裝流程、shared layer 完整生態（producer 範本）。
- **下一輪 closeout 建議**：先讓 v0.22 P0-P10 在使用者真實環境跑一段時間收 dogfood 反饋，再開 Phase 12（detached runtime）。
- **Smoke 11 個 pre-existing fail**：不是本 P10 closeout 的責任。需各 phase owner（P1 / P2 / P3 / P6 / P8）分別處理 cap install state / project ledger collisions / harness assumptions。建議下一輪 closeout 起一個獨立 cycle 處理這 11 個。
- **本 tag 不取代 `v0.22.0` 正式版**：rc 系列以 P phase 完成度收斂，不是語意化 GA。

### Verified

- 17 個 P10 / P9 / P7 dedicated suite **454 cases passed**：promote (4 suites = 125) + workflow-result-schema (12) + binding-source-metadata (17) + skill-registry-resolver (22) + workflow-source-resolver (14) + source-roots-enforcement (20) + result-report-builder (91) + result-report-wiring (28) + cap-workflow-inspect (46) + cap-config-namespace-readers (27) + workflow-policy-gates (19) + binding-report-validation-hook (15) + binding-report-schema (10) + compiled-workflow-normalization (8)，與 rc15 baseline 一致零 regression。
- Full smoke (`scripts/workflows/smoke-per-stage.sh`) **61 pass / 11 fail**（vs rc15 預估 43/29）；新增 18 pass 全是 chmod 修出的 fixture，0 個 P10 pipeline regression。

---

## [v0.22.0-rc15] - 2026-05-06

> Release candidate — close out P9 Repo-specific Source Resolver. Aggregate 6 commits since rc14 (5× feat + 1× docs) into a layered workflow / skill source resolver with project / shared / builtin precedence, binding-report source metadata, and effective-allowed-roots enforcement. Note: ``v0.22.0-rc14`` (commit ``cd729b2``) closed out P8 Governance Gates as a pure-tag promotion without a CHANGELOG entry; this rc15 narrative therefore covers only the P9 work landed since rc14.

### Added

- **P9 #1 skills method intake — five engineering methodology strategies** (`df0cc73`)：把外部 `engineering/{diagnose,tdd,grill-with-docs,improve-codebase-architecture,to-prd}` 的 SKILL.md 改寫為 5 個 CAP methodology strategy（`agent-skills/strategies/diagnose-loop.md` / `tdd-vertical-slice.md` / `shared-language-and-adr.md` / `architecture-deepening.md` / `vertical-slice-planning.md`），分別蒸餾出六段診斷流程含 Phase 1 feedback loop / 紅綠重構 + tracer bullet + 反 horizontal slice / `CONTEXT.md` SSOT + ADR 三條鐵律 / Module / Interface / Depth / Seam 嚴格 glossary + deletion test / PRD 結構 + module sketch + slice 切分。Mounted on 7 既有 agent prompt（`10-troubleshoot` / `07-qa` / `04-frontend` / `05-backend` / `01-supervisor` / `02-techlead` / `90-watcher`），watcher 是 audit checkpoint 不執行 strategy 本身。**邊界**：純 markdown，不引入 plugin runtime、不新增第二套 skill resolver、`factory.py` glob 不動；deferred items（Codex / Claude 原生 SKILL.md export、mapper 擴充、plugin / marketplace 安裝流程）等 builtin / project / shared source resolver 完成後再做。

- **P9 #2 three-layer workflow resolver** (`a16df2e`)：`engine/workflow_loader.py:WorkflowLoader.__init__` 加 keyword-only `project_root` / `cap_home`（precedence：explicit kwarg > env (`CAP_PROJECT_ROOT` / `CAP_HOME`) > `base_dir`-as-universe（保 pre-P9 caller 契約）> cwd / `~/.cap` fallback；**Python helper，不 shell-out 呼 `cap-paths.sh`**）。新 `_resolve_workflow_path(ref) → (Path, source_layer)` 與 `_infer_source_layer(path)` 純函式：絕對 / cwd-relative 路徑直接 load 後推 layer，否則依序掃 `project` → `shared` → `builtin`，全部 miss 拋 `FileNotFoundError` 列出三個搜過的 dir；source_layer 推斷規則含 `explicit` 處理絕對路徑落在三 layer 之外的情境。`load_workflow` 寫 `_source_layer` 進 normalized dict，既有 `_source_path` 維持。`engine/workflow_cli.py:cmd_resolve_ref` signature 從 `(workflows_dir, raw_ref)` 改為 `(raw_ref, workflows_dir=None)`，parser `workflows_dir` 從 positional 降為 deprecated `--workflows-dir` flag；無旗標時跑三層 layered scan，先試 filename + 4 種 suffix 變體，再 fallback 到 `workflow_id` / `short_id` / stem / 全名比對保 `cap workflow run <workflow_id>` 既有語意。`scripts/cap-workflow.sh:resolve_workflow_ref` **移除 `${WORKFLOWS_DIR}/${raw_ref}` fast-path**（避免 builtin fast-path 偷走 project override，design memo §4.5），保留絕對路徑 short-circuit。`tests/scripts/test-workflow-source-resolver.sh` 8 cases / 14 assertions（同 id override / 新 id extend / shared hit / 三層 miss + error 訊息列三 dir / absolute under project / absolute under builtin / absolute outside three layers→explicit / cap-protocols self-mode 雙路徑共存 / bash 委派與 CLI 結果一致）。

- **P9 #3 three-layer skill registry merge** (`3d5f3e6`)：`RuntimeBinder.__init__` 加同樣 keyword-only `project_root` / `cap_home` kwargs，pass-through 給 `WorkflowLoader`。`load_skill_registry(registry_ref=None)` 改 dispatcher：傳 `registry_ref` 走新 `_load_single_registry`（保 pre-P9 #3 單檔行為，含 legacy `agents` envelope 自動 adapt），未傳走新 `_load_layered_skill_registry`，依 `project` → `shared` → `builtin` 收集每層後合併（priority project > shared > builtin）；三層皆空 fall through 到既有 `_load_legacy_registry_adapter` 維持 backward compat。新 `_resolve_layer_registry(layer_name, layer_dir)` 處理單層輸入：先試 flat `<dir>/skills.{yaml,yml,json}`、否則掃 `<dir>/skills/*.{yaml,yml,json}`；builtin layer 額外保留 `<base_dir>/.cap.skills.yaml` 舊散檔 fallback。`_merge_skill_layers` 以 `skill_id` 為 key 做 first-encountered-wins dedupe，並用 `_deep_merge` 對 `binding_defaults` 做 key-wise 遞迴合併（high layer 任何 key 都贏，含 nested dict；list 整段替換不 element-wise merge）。每個 skill entry 內部標 `_source_layer` / `_source_path`。Self-mode（`project_root.samefile(builtin_dir)`）跳過 project layer 不雙載。`tests/scripts/test-skill-registry-resolver.sh` 8 cases / 22 assertions。

- **P9 #4 binding report source metadata** (`25e6f7e`)：`schemas/binding-report.schema.yaml` 加 3 個 optional 欄位（**不破 backward compat**）：頂層 `workflow_source: {source_layer, source_path}`（layer enum：`project / shared / builtin / explicit`，nullable for synthesized inline plans）；頂層 `effective_allowed_roots: []` placeholder（P9 #4 永遠寫 `[]`，**真實 snapshot 由 P9 #5 替換**）；每 step entry `skill_source: {source_layer, source_path}`（layer enum 多 `fallback`，nullable for unresolved/blocked branches）。`engine/workflow_loader.py:build_semantic_plan_from_workflow` thread `_source_layer` 進 semantic plan（key 名 `source_layer`），讓 binder 拿得到。`engine/runtime_binder.py:bind_semantic_plan` 結尾組裝 binding 加 `workflow_source` / `effective_allowed_roots: []` placeholder / 每 step `skill_source`；新 helper `_skill_source_metadata(skill, *, fallback_when_missing=False)` 把 P9 #3 的 `_source_layer` / `_source_path` 內部 tag 投影成 binding-report shape（`fallback` 標記 adapter / builtin-shell synthetic）。4 個 `step_reports.append({...})` site 都 inject `skill_source`，主 resolution 用新 local `chosen_skill` 追蹤實際選定的 skill dict。`tests/scripts/test-binding-source-metadata.sh` 6 cases / 17 assertions。

- **P9 #5 effective allowed roots + workflow / skill source enforcement** (`525f385`)：新 `SourcePolicyError` 共同基底（`WorkflowSourcePolicyError` 與新 `SkillSourcePolicyError` 都繼承之，**契約不變**）。新 `_compute_effective_allowed_roots(project_context)` 一次計算 effective set：`enforce_allowed_source_roots=False` → 回 `[]`；否則 union user-declared `constitution.workflow_policy.allowed_source_roots` → 隱式 project layer (`<project_root>/.cap/{workflows,skills,skills.yaml,skills.yml,skills.json}`) → 隱式 builtin layer (`<base_dir>/{schemas/workflows,.cap/skills,.cap/skills.yaml,.cap/skills.yml,.cap/skills.json}`) + legacy fallback (`<base_dir>/.cap.skills.{yaml,yml,json}`)，dedupe 保 priority。**修正 design memo §3.1.2 typo**：memo 列 `.cap/skills.json` literal 但 canonical 是 `.cap/skills.yaml`，實作三 extensions 全收避免既有 `enforce=true` 專案被自己 builtin registry 擋死。新 `_path_is_under_any_root` 純函式 helper 集中 `Path.resolve()` + parents 比對。`_assert_workflow_source_allowed` 升級走 effective set。新 `_assert_skill_source_allowed`：每 step append 前 fire（memo §7.3 timing），違反 raise `SkillSourcePolicyError(stage="skill_source_policy")`，**halt 整個 binding 不降級**（memo §7.4：governance redline 優先於可用性）；對 `effective_allowed_roots=[]` / `skill_source=None` / `source_path=None` 三類 fallback 結構性 no-op。`bind_semantic_plan` 頂部 compute 一次 effective set 並用於兩個 hook，4 個 step append site 都 wire skill gate；最後組裝 binding 把 `effective_allowed_roots` 從 P9 #4 的 placeholder `[]` 換成真實 snapshot。`engine/workflow_cli.py:cmd_compile_json` 補 `SkillSourcePolicyError` handler，吐 deterministic JSON `{"ok": false, "error": "skill_source_policy_error", ...}` exit 1。`tests/scripts/test-source-roots-enforcement.sh` 7 cases / 20 assertions。

### Documentation

- **P9 source resolver design memo** (`cc37734`)：新增 `docs/cap/P9-SOURCE-RESOLVER-DESIGN.md` 作為 P9 #2-#5 設計 SSOT；先於實作 commit；包含 §1 pre-P9 baseline / §3 三層 layer 表 / §3.1 預設 allowed_source_roots 展開政策（project + builtin 自動允許、shared 必須顯式宣告） / §4-§7 各 sub-item 設計 / §8 實作順序 / §9 已裁定 + 仍需確認的 open questions。後續 P9 #2-#5 commit 都 cross-reference 本 memo 對應段落。

### Notes

- **P9 全段完成**：5/5 sub-items DONE（#1 / #2 / #3 / #4 / #5）。`docs/cap/MISSING-IMPLEMENTATION-CHECKLIST.md` P9 section 為 per-item 狀態 SSOT，每條都附 commit hash + 範圍邊界 + 踩坑修正紀錄。
- **未動範圍**：P10 promote candidates（schema slot 早在 P0 已加，producer 由 P10 owns）；shared layer 完整生態（producer 範本、共用 skills 收編流程）等真實使用情境再凝固。
- **rc14 釋義**：`v0.22.0-rc14` (commit `cd729b2`) 為 P8 Governance Gates closeout pure-tag，未寫 CHANGELOG / RELEASE-NOTES 條目；本 rc15 narrative 因此只覆蓋 P9 範圍，rc14 的 P8 變動以 tag annotation 為唯一 release 文字 SSOT。
- **下一個排程項目**：P10 Detached Runtime and Promote / Publish — 含 detached / background workflow run、promote candidates producer（會把 P0 早就加的 schema slot 真正寫上）、publish pipeline。
- **此 tag 不取代 `v0.22.0` 正式版**：rc 系列以 P phase 完成度收斂，不是語意化的 GA。

### Verified

- 13 個 P9 + P7 dedicated suite **327 cases passed**：`test-source-roots-enforcement` (20) + `test-binding-source-metadata` (17) + `test-skill-registry-resolver` (22) + `test-workflow-source-resolver` (14) + `test-cap-config-namespace-readers` (27) + `test-workflow-policy-gates` (19) + `test-binding-report-validation-hook` (15) + `test-binding-report-schema` (10) + `test-compiled-workflow-normalization` (8) + `test-result-report-builder` (91) + `test-result-report-wiring` (28) + `test-cap-workflow-inspect` (46) + `test-workflow-result-schema` (10)，與 rc14 baseline 完全一致零 regression。

---

## [v0.22.0-rc13] - 2026-05-05

> Release candidate — close out P7 Result Report and Run Archive. Aggregate 6 commits since rc12 (4× feat + 2× docs) into the structured workflow-result contract: `workflow-result.json` machine artifact, `result.md` human projection, upgraded `cap workflow inspect <run-id>` with three-tier resolution and `--json` flag, new run-archive policy + Logger handoff format, and minimal directory pointers for constitution / compiled workflow / binding (pointer-only, no parsing). All P7 sub-items reach DONE except #5 (promote_candidates schema slot ready; real producer owned by P10 — by design).

### Added

- **P7 #1 result report builder Phase A — read-only library** (`580eace`)：新增 `engine/result_report_builder.py:build_workflow_result(run_dir, *, cap_home, status_file)`，aggregate `<run_dir>/runtime-state.json` + `agent-sessions.json` + `run-summary.md` + 選用 `workflow.log` / `route-history.jsonl` / handoff tickets 為符合 `schemas/workflow-result.schema.yaml` 的 normalized dict。Phase A 刻意 library-only：沒有 CLI subcommand、沒接 `cap-workflow-exec.sh`、`promote_candidates` 永遠 `[]`（P10 owns producer），缺 optional source 全部 degrade 到 `null` / `[]` 不 raise。`status_file → task_id` linkage 標明 best-effort future-compatible — 當前 `step_runtime.update_status` 不寫 `runs[*].task_id`，所以這條 lookup 今天必回 `None`，未來 producer 上線可直接吃。`tests/scripts/test-result-report-builder.sh` 11 cases / 61 assertions（happy / partial / failed / running / blocked / handoff-ticket cross-reference / missing optional sources / future-compatible task_id linkage 8a/8b / malformed runtime-state / 真實 `~/.cap` smoke run dir / missing run_dir → FileNotFoundError 契約）。

- **P7 #1 result report builder Phase B — producer wiring** (`a7f2eb2`)：新增 sourceable helper `scripts/cap-result-emit.sh`，暴露 `cap_result_emit` function：在 mktemp 跑 builder + 新增的純函式 `render_result_md`，把 JSON 透過 `step_runtime.py validate-jsonschema` 驗證，pass 才把 `workflow-result.json` + `result.md` 透過兩段 atomic mv 落地。**兩個 mv 都檢 rc**：JSON mv 失敗清 tmp + 寫 workflow.log fallback log；MD mv 失敗（JSON 已落地時）rollback JSON 維持 atomicity，避免 orphan workflow-result.json 假宣稱 schema-validated。Schema path 可由 `CAP_RESULT_SCHEMA_OVERRIDE` 覆寫（focused write/schema fail tests 用）。`scripts/cap-workflow-exec.sh` 把 run-summary `## Finished` block 移到 result.md 生成前，讓 builder 能從 Finished header 推 `final_state`；legacy hardcoded `result.md` template 保留為 fallback（builder error / schema fail / mv fail 全走 fallback），失敗只 log 不 halt run。`tests/scripts/test-result-report-builder.sh` Case 12 補 `render_result_md` 17 assertions（headings + bullets + Failures 段），總 78 assertions；新增 `tests/scripts/test-result-report-wiring.sh` 5 cases / 28 assertions（happy / schema-fail via `CAP_RESULT_SCHEMA_OVERRIDE` / builder-fail via missing run_dir / 4a write-fail at JSON mv / 4b write-fail at MD mv with JSON rollback）。

- **P7 #7 cap workflow inspect Phase C upgrade** (`3d378e5`)：`engine/workflow_cli.py:cmd_inspect` 改成讀 structured workflow-result，取代舊 status-store `runs[]` flat 視圖。三層 resolution：(1) `<cap_home>/projects/*/reports/workflows/*/<run_id>/workflow-result.json` 直接讀；(2) run_dir 存在但無 JSON → 跑 `result_report_builder.build_workflow_result()` in-memory aggregate；(3) run_dir 不存在 → 沿用舊 status-store 邏輯，pre-P7 entries 仍可 inspect。新 flag：`--json` dump workflow-result JSON、`--cap-home` 覆寫（測試用）。`cap_home` 解析 precedence：`--cap-home` flag > `CAP_HOME` env var > `~/.cap`。`_find_run_dir` 用 `sorted(glob(...))` 確保多項目錄出現同 run_id 時 deterministic 對 alphabetically first match。Text view 6 sections：Run Header / Summary / Failures / Sessions / Artifacts / Logs Pointer。`scripts/cap-workflow.sh inspect` dispatcher 改 `shift` + `"$@"` forward，讓 argparse 處理 flag 與 run_id 任意順序。`tests/scripts/test-cap-workflow-inspect.sh` 6 cases / 40 assertions（workflow-result.json 優先 + 6 sections / `--json` JSON parseable / builder fallback / legacy status-store / not found exit 1 / `CAP_HOME` env var）。

- **P7 #2 minimal input pointers** (`2287deb`)：`workflow-result.json` 新增 optional 頂層 `inputs` object 帶 3 個 nullable directory path，讓 reader 從 result.md 或 `cap workflow inspect` 找到該 run 的 upstream sources。**Pointer-only 邊界**：builder 只記目錄存在性 — 不重新解析、不重新驗證、不讀 schemas (`task-constitution.schema.yaml` 等)、不讀 P3 supervisor orchestration envelope。新增 `engine/result_report_builder.py:_resolve_input_pointers(cap_home, project_id, workflow_id)`：檢查 `<cap_home>/projects/<id>/{constitutions,compiled-workflows/<wf>,bindings/<wf>}/` 是否存在，存在填路徑、否則 `None`。設計理由：今天無從 run_dir 直接對應到具體 binding / compiled-workflow / constitution snapshot 的 stable producer，timestamp 或 workflow_id 配對等於 parsing in disguise；directory pointer 是「reader 可進一步 ls 探索」的入口而非 builder 替使用者推斷。`schemas/workflow-result.schema.yaml` 加 optional `inputs` object（schema description 標明 pointer-only contract）。`render_result_md` + `cmd_inspect._print_inspect_text` 在至少一 pointer 非 null 時 emit `## Inputs` / `# Inputs` 段，全 null 時整段省略。`tests/scripts/test-result-report-builder.sh` Cases 13/14 共 13 assertions（dirs 存在 → pointers 解析 + render；dirs 缺 → all null + section omitted），總 91 assertions；`tests/scripts/test-cap-workflow-inspect.sh` Case 7 共 6 assertions（# Inputs render + Case 1 omission cross-check），總 46 assertions。

### Documentation

- **P7 #6 run archive policy + Logger handoff** (`6c0aa89`)：新增 `policies/run-archive.md` (policy-first，無 archive automation；CLI / cron 等真實使用情境再凝固)，定義三段 lifecycle (`active` 30d → `archived` 180d → `pruned` 永久) for cap workflow `run_dir`s、就地標記 `<run_dir>/.lifecycle` 單行 plain text、archive 必要核心檔案 4 件 (`workflow-result.json` / `result.md` / `archive-summary.md` / `.lifecycle`)、強烈建議保留 (`run-summary.md` / `agent-sessions.json` / `runtime-state.json` / `workflow.log`)、`cap workflow inspect` 三狀態相容性、schema-drift halt 規則（archive 必須 NOT 在 `workflow-result.json` schema validation 失敗時 stamp `.lifecycle archived`）、active-state 最小保證（每 workflow ≥1 completed run + 最近 3 runs 不論 state）。`agent-skills/99-logger-agent.md` 新增 §2.4「結案歸檔摘要」描述 Logger 對 archive 任務的 capability：以 `workflow-result.json` 為唯一資料來源，產出 `archive-summary.md` 7 段必填 (Run Identity / Lifecycle / Summary Metrics / Critical Events / Decision Narrative / Artifact Pointers)，SSOT 殘缺或 schema 驗證失敗時必須 `needs_data` halt 不得偽造 archived 狀態。

- **P7 phase-status checklist update** (`5bb961c`)：`docs/cap/MISSING-IMPLEMENTATION-CHECKLIST.md` P7 section 反映 Phase A/B/C 後狀態 — #1 / #3 / #4 / #7 標 `[x]`、#2 標 `[partial]`（後續被 `2287deb` 升 `[x]`）、#5 標 `[partial]` 註明 P10 owns producer、#6 留 `[ ]`（被 `6c0aa89` 升 `[x]`）。Cross-reference 在 line 3 (P0c snapshot intro) 與 lines 57 / 60 (schema bullets forward-noting "pending P7") 刻意不動，保留歷史脈絡。

### Notes

- **P7 closeout completeness**：6/7 sub-items 完成（#1 / #2 / #3 / #4 / #6 / #7）；#5 `promote_candidates` 維持「schema slot ready, builder always emits `[]`」直到 P10 Detached Runtime and Promote / Publish 把 producer 寫進來，**by design**。`docs/cap/MISSING-IMPLEMENTATION-CHECKLIST.md` P7 section 為 per-item 狀態 SSOT。
- **No archive automation in this tag**：`policies/run-archive.md` 是 policy-first delivery；`cap workflow archive` / `cap workflow prune` CLI 在 policy 中描述但**未實作**，等真實使用情境再 ship。Policy contract 設計足以讓 follow-up tag ship CLI 不需 policy churn。
- **下一個排程項目**：P8 Governance Gates（watcher / security / qa / logger checkpoint runner，消費 `schemas/gate-result.schema.yaml` `result` / `risk_level` / `fail_routing.action` 三 enum）。
- **此 tag 不取代 `v0.22.0` 正式版**：rc 系列以 P phase 完成度收斂，不是語意化的 GA。

### Verified

- 4 個 P7 dedicated suite **175 cases passed**：`test-result-report-builder` (91) + `test-result-report-wiring` (28) + `test-cap-workflow-inspect` (46) + `test-workflow-result-schema` (10)，與 rc12 baseline 完全一致零 regression。

---

## [v0.22.0-rc12] - 2026-05-05

> Release candidate — collect 2 commits since v0.22.0-rc11 into a focused checkpoint that closes the P0c constitution workflow writers (`Batch 2.6`) deferred from rc11. All writes stay non-destructive: legacy `.cap.<name>` flat-file paths still resolve via the dual-path readers shipped in rc11, and `--remove-legacy` continues to be deferred to a follow-up tag.

### Fixed

- **P0c batch 2.6 — constitution workflow writers `.cap` namespace migration** (`b5717d0`)：把 v0.22.0-rc11 「Notes」段刻意延後的 6 個 P2-tested constitution writer 收尾，全部改成「new path 優先 / legacy fallback / non-destructive / 不引入 `--remove-legacy`」，與 rc11 已完成的 4 個 reader dual-path（`9dcbc2a` / `58f7f25`）對齊：(1) **`scripts/workflows/persist-constitution.sh`**：`REPO_TARGET` 改寫到 `.cap/constitution.yaml`；exists / diff / skip 同時辨識 legacy `.cap.constitution.yaml` 以避免覆蓋舊 SSOT；`PROJECT_CONFIG_PATH` 改寫到 `.cap/project.yaml`；payload 內 `constitution_file` / `skill_registry` / `agent_registry` 同步指向 `.cap/<name>`；README scaffold template 反映新路徑；`mkdir -p .cap/` 安全建立。(2) **`scripts/workflows/bootstrap-constitution-defaults.sh`**：`source_of_truth` verbatim 預設 block 改用 `.cap/<name>` 路徑，並加 batch 2.6 dual-path 提醒。(3) **`scripts/workflows/load-constitution-reconcile-inputs.sh`**：`CONSTITUTION_PATH` 與 `read_project_meta()` dual-path；`missing_current_constitution` 錯誤訊息列出兩個路徑。(4) **`scripts/workflows/emit-handoff-ticket.sh`**：`resolve_runtime_project_id` fallback dual-path；ticket `context_payload.project_constitution_path` 用 lambda 解析「new wins / 缺新→legacy / 都缺→預設新路徑」三種情境。(5) **`scripts/workflows/provider-parity-check.sh`**：`design_source.type` 讀取 dual-path。(6) **`scripts/workflows/ingest-design-source.sh`**：僅 docstring 更新（邏輯已透過 `engine/step_runtime.py:_read_constitution_design_source` 走 dual-path，rc11 `58f7f25` 已落地）。**Verified**：6 個 impacted-suite 60 cases passed — `test-persist-constitution-exit-code` (6) + `test-bootstrap-constitution-defaults-exit-code` (4) + `test-load-constitution-reconcile-inputs-exit-code` (2) + `test-emit-handoff-ticket` (19) + `test-design-source-ingest` (21) + `test-provider-parity-check` (8)；4 個 P0c gate 132 cases passed — `test-cap-config-namespace-resolver` (27) + `test-cap-config-namespace-readers` (27) + `test-cap-project-init-namespace` (31) + `test-cap-project-migrate-config` (47)，與 rc11 baseline 一致零 regression。`test-cap-project-constitution.sh` case 4 「validation.json lists errors」64 passed / 1 failed 屬 master pre-existing issue（`git stash` 對照 d34c16a base 同樣 fail），與本批變更無關，後續另開 ticket 處理。**未動執行行為**：legacy 4 個散檔仍在原處（如 `e9bb5ca` dogfooding 後保留），`--remove-legacy` 維持 deferred；本 commit 走 06-devops 版本控制 pipeline (`vc_scan` + `vc_compose` + `vc_apply`) 落地，governed strategy 自動 push 上 `origin/main`。

### Documentation

- **`docs(cap-config-namespace)` release-doc closeout** (`90e37cb`)：把 Batch 2.6 的 closure narrative 補進三個 release-doc surface — `CHANGELOG.md` 新增本段 release block、`docs/cap/RELEASE-NOTES.md` 在 rc11 上方插入 v0.22.0-rc12 條目、`docs/cap/MISSING-IMPLEMENTATION-CHECKLIST.md` 「更新日期」bumped 到 2026-05-05。No executable behavior change；commit 走 06-devops `vc_scan` + `vc_compose` + `vc_apply` pipeline 落地。

### Notes

- **`Batch 2.6` 範圍**：6 writer × dual-path migration（`persist-constitution.sh` 等）；**未做** `--remove-legacy`；本 tag 不取代 `v0.22.0` 正式版。
- **下一個排程項目**：P7 Result Report and Run Archive（result.md builder + final archive + `cap workflow inspect`），SSOT 來源限於 `<run_dir>/runtime-state.json` / `agent-sessions.json` / `workflow.log` / `run-summary.md` / `route-history.jsonl` + `~/.cap/projects/<id>/handoffs/*.ticket.json` + dry-run preflight report。
- **`--remove-legacy` deferred**：rc12 後仍保留 4 個 legacy `.cap.*` 散檔，按計畫等下一輪正常 CAP 操作（含 workflow run / promote / e2e）確認無 reader 漏掉再執行。

### Verified

- 6 個 impacted-suite **60 cases passed**：`test-persist-constitution-exit-code` (6) + `test-bootstrap-constitution-defaults-exit-code` (4) + `test-load-constitution-reconcile-inputs-exit-code` (2) + `test-emit-handoff-ticket` (19) + `test-design-source-ingest` (21) + `test-provider-parity-check` (8)。
- 4 個 P0c gate **132 cases passed**：`test-cap-config-namespace-resolver` (27) + `test-cap-config-namespace-readers` (27) + `test-cap-project-init-namespace` (31) + `test-cap-project-migrate-config` (47)，與 rc11 baseline 完全一致零 regression。
- `test-cap-project-constitution.sh` case 4 「validation.json lists errors」維持 64 passed / 1 failed，屬 master pre-existing issue（`git stash` 對照 `d34c16a` base 同樣 fail）；不在本 tag scope。

---

## [v0.22.0-rc11] - 2026-05-05

> Release candidate — collect 9 commits since v0.22.0-rc10 into a complete checkpoint covering two parallel cleanup tracks: **P0b Provider Isolation** (CAP no longer hijacks bare `claude` / `codex` and no longer overwrites global `~/.claude/CLAUDE.md`) + **P0c CAP Config Namespace Migration** (`.cap.*` repo-root dotfiles consolidate into a `.cap/` namespace; resolver, init, secondary readers all dual-path; this repo dogfooded copy-only). All P0c writes are non-destructive (legacy files preserved); P0c batch 2.6 (6 P2-tested constitution workflow writers) and `--remove-legacy` deliberately deferred to a follow-up tag.

### Added

- **`cap project migrate-config` helper** (`237ac74`)：新模組 `engine/migrate_config.py` 提供 `plan_migration` / `apply_migration` 純函式 + `MigrationPlan / PlanEntry / MigrationResult / ApplyEntry` dataclass + `Action` 4 enum (`skip_no_legacy` / `copy` / `already_migrated` / `conflict`)。CLI `cap project migrate-config [--project-root PATH] [--dry-run] [--force] [--remove-legacy] [--format text|json|yaml]`。預設 non-destructive（保留 legacy）；`--force` 才覆寫 `.cap/<name>` 已存在；`--remove-legacy` 才刪原檔。Idempotent re-run 返回 `already_migrated`。Exit 0 / 1（成功 / conflict 未 force）。`tests/scripts/test-cap-project-migrate-config.sh` 9 cases / 47 passed。
- **`cap-session.sh` 在非 CAP 目錄退回原生 provider** (`35e4e4b`)：`has_cap_project_context()` 偵測 4 條 CAP signal（`CAP_PROJECT_ID_OVERRIDE` / `.cap.project.yaml` / git repo / `CAP_ALLOW_BASENAME_FALLBACK=1`），缺失時 `launch_native_without_cap_context()` exec 原生 binary + stderr 印 fallback hint。覆蓋 P0b 最後一塊：裸 `claude/codex` 已不被劫持（`97a855a`），`cap claude/cap codex` 也優雅 degrade，不再在 `~` 觸發 `cap-paths` strict 錯誤。`tests/scripts/test-cap-session-native-fallback.sh` 3 cases / 14 passed。
- **`.cap/project.yaml` resolver dual-path** (`9dcbc2a`)：4 個 reader 同步加新→legacy 雙路徑（新優先，drift 即 bug）：`scripts/cap-paths.sh:read_project_id_from_config` / `engine/project_constitution_runner.py:resolve_project_id` / `engine/project_context_loader.py:ProjectContextLoader.load` / `engine/step_runtime.py:_project_id_from_config`。Producer flip + 其他 reader 切到 batch 2.5 / 2.6。`tests/scripts/test-cap-config-namespace-resolver.sh` 4 reader × 4 場景 = 27 cases。
- **`cap project init` 寫 `.cap/project.yaml`** (`83ca4b3`)：`scripts/cap-project.sh:cmd_init` 預設寫新路徑；既有 legacy 視為「已初始化」，refusal message 提示用 `cap project migrate-config`；`--force` 在 legacy-only 寫新路徑保留 legacy（不自動刪），在新路徑做 in-place rewrite（保留未知 keys）。`tests/scripts/test-cap-project-init-namespace.sh` 7 cases / 31 passed。`tests/scripts/test-project-init.sh` Case 1 / Case 5 同步更新到新 contract（35 passed）。
- **skills / agents / constitution reader dual-path** (`58f7f25`)：4 個 secondary reader 同樣新→legacy fallback：`engine/runtime_binder.py:load_skill_registry` + `_load_legacy_registry_adapter` / `engine/workflow_loader.py:agents_path` / `scripts/cap-registry.sh:REGISTRY_FILE` / `engine/step_runtime.py:_read_constitution_design_source`。runtime_binder constants 加 `*_NAMESPACED` 兄弟讓 precedence 在 class level 可見。`tests/scripts/test-cap-config-namespace-readers.sh` 4 reader × 3-6 場景 = 27 cases。

### Fixed

- **installer 預設不劫持裸 `claude` / `codex`** (`97a855a`)：`scripts/manage-cap-alias.sh:WRAP_NATIVE_CLI` 預設從 1 翻 0；fresh `make install` 後 `~/.zshrc` CAP block 只裝 `cap()` shell function，裸命令保留原生 provider 行為。`CAP_WRAP_NATIVE_CLI=1 make install` 為 opt-in escape hatch 給依賴舊行為的使用者。`install.sh` + `README.md` + `docs/cap/ARCHITECTURE.md` 同步更新文案；新增 Provider Isolation 段落 + 既有用戶遷移步驟。`tests/scripts/test-manage-cap-alias-defaults.sh` 7 sub-suites / 26 passed。
- **mapper 不再覆寫全域 `~/.claude/CLAUDE.md` / `~/.codex/AGENTS.md`** (`965e09f`)：`scripts/mapper.sh --global` 移除兩個全域檔的寫入路徑（83 行 → 0 行）；`~/.claude/rules/*-agent.md` symlink 仍同步（被動 reference，不會自動載入）。Uninstall 偵測到 legacy auto-gen 檔時印 backup 提示。專案規則改由 repo-local `CLAUDE.md` / `AGENTS.md` 透過 `@` import 載入，不再強塞每個 claude/codex global session。`tests/scripts/test-mapper-global-isolation.sh` 7 cases / 14 passed。

### Changed

- **本 repo 自身 dogfooding 搬檔** (`e9bb5ca`)：跑 `cap project migrate-config` 把 charlie-ai-protocols 自身的 4 個 legacy `.cap.*` 散檔 copy 進 `.cap/`。`cmp -s` 驗證 byte-equal；`cap project status` 顯示 `health_status=ok`；4 個 P0c gates 132 passed / 0 failed；第二次 dry-run 全 `already_migrated`（idempotent）。Legacy 4 檔仍在 root，`--remove-legacy` 等下一輪確認後才執行。
- **Convergence Checkpoint #2** (`c5c956c`)：`docs/cap/ARCHITECTURE.md` 新增 P0–P6 Runtime Module Map 段（15 行 SSOT 表 + P7 應讀的 7 source list + 「不是 SSOT 的東西」警示），確保 P7 開工時不會重新發明 aggregate logic。**未搬檔、未動模組**，純 docs 收斂。

### Notes

- **未動執行行為**：本批所有 commit 都加雙路徑 read / additive helper / opt-in flag；既有 reader 都繼續 fallback legacy，沒有破壞 v0.22.0-rc10 之前安裝的專案。
- **Batch 2.6 deferred**：6 個 P2-tested constitution writer (`scripts/workflows/persist-constitution.sh` / `bootstrap-constitution-defaults.sh` / `load-constitution-reconcile-inputs.sh` / `emit-handoff-ticket.sh` / `provider-parity-check.sh` / `ingest-design-source.sh`) 仍 grep 舊路徑；改它們需要 P2 e2e regression sweep，刻意延後至下一 tag。
- **`--remove-legacy` deferred**：現在 4 個 legacy 散檔保留是設計選擇 — 若任何漏掉的 reader 仍指 legacy，至少還能讀到。等一輪正常 CAP 操作後（含 workflow run / promote / e2e）若無 reader 漏掉再執行 `--remove-legacy`。
- **既有用戶遷移**：升 rc11 後跑 `make uninstall && make install && exec zsh` 才會看到新 `~/.zshrc` block（裸 claude/codex 變回原生）；`~/.claude/CLAUDE.md` 若內含 `charlie-ai-protocols` marker 會被 uninstall 移除（先備份個人 section）。專案內若想搬檔，跑 `cap project migrate-config --dry-run` → `cap project migrate-config`。
- **本 tag** 是「Provider Isolation + CAP Config Namespace 收斂完整 / Batch 2.6 + `--remove-legacy` + P7 Result Report 可開工」的乾淨基線，不取代 `v0.22.0` 正式版。

### Verified

- 所有 P0b 測試 (`test-manage-cap-alias-defaults` 26 / `test-mapper-global-isolation` 14 / `test-cap-session-native-fallback` 14) 與 P0c 測試 (`test-cap-config-namespace-resolver` 27 / `test-cap-project-migrate-config` 47 / `test-cap-project-init-namespace` 31 / `test-cap-config-namespace-readers` 27) 全綠，合計 **186 passed / 0 failed**。
- 既有測試 `test-project-init` 同步更新至新 contract，35 passed。
- 本 repo dogfooding 後 `cap project status` 顯示 `health_status=ok`、`cap version` 印 `v0.22.0-rc10+dev (58f7f25) on main`、`cap project migrate-config --dry-run` 第二次回 `nothing to migrate (all entries skip_no_legacy or already_migrated)`。

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
