# Component Repo Dogfood Closeout — 2026-05-10

> Status: closeout report (post-action).
> Subject: ``~/projects/cap-test/component-next-dotnet-stt`` — minimal Component Repo fixture (Next.js + C#/.NET + PostgreSQL + Docker Compose, STT module).
> Driver tag: `dogfood/component-next-dotnet`.
> Goal of the run: prove the full CAP pipeline (`cap project init` → `cap workflow run project-constitution` → `project-spec-pipeline` → `project-implementation-pipeline` → `cap promote inspect`) can stably produce constitution / task constitution / spec artifacts / implementation artifacts / QA evidence / promote candidates against a from-scratch component repo.

## TL;DR

Baseline **cleared** under v0.25.9 after 9 patch releases. Phase A → D ran end-to-end with 36/36 AI sub-agent + shell steps green; 6 spec artifacts landed in the cap-test repo via the typed promote pipeline; final commit `b301c70` on cap-test master tracks 10 files / 2934 lines of authoritative artifacts.

The dogfood discovered **11 latent path-resolution / artifact-bridging bugs** that were invisible to in-repo smoke testing (smoke-layer / smoke-per-stage all stayed green pre-fix on every release v0.24.7 through v0.25.0). The bugs only surfaced once cap was driven from a working repo *outside* the cap install dir — the actual production usage pattern.

## Acceptance criteria — original ask vs delivery

The user's verbatim acceptance list (from the dogfood briefing):

| Criterion | Outcome |
|---|---|
| project constitution produced | ✅ `.cap/constitution.yaml`, 139 lines, schema-validated |
| task constitution produced | ✅ `~/.cap/projects/<id>/constitutions/happy-path-stt-component-formal-spec.json` |
| spec artifacts produced | ✅ 6 markdown SSOTs (PRD / TechPlan / BA / Schema / API / UI), 2778 lines |
| implementation artifacts produced | ✅ 15-step Phase D run with backend / frontend / qa / security / devops / impl_audit / archive all green; AI-emitted under `<run_dir>/` |
| QA evidence produced | ✅ Watcher spec_audit + impl_audit milestone gates both PASS |
| run logs / inspect output | ✅ `cap promote inspect <name>` resolves all 6 spec_artifact names; identical reports against the committed baseline |
| promote candidates surfaced | ✅ `workflow-result.json:promote_candidates[]` carries 6 spec_artifact entries automatically |

Closing condition the user set ("如果這條小 repo 跑不順，就不要進 Product Repo"): the run finished cleanly, so Product Repo expansion is not blocked by baseline-readiness. (Whether to proceed is a separate decision, not gated by this dogfood.)

## Pipeline trace

| Phase | Workflow | Run dir | Steps | Duration | Result |
|---|---|---|---|---|---|
| A | `cap project init` / `cap project doctor` | n/a | n/a | <1s | overall_status=ok |
| B | `project-constitution` | `run_20260510151948_611b59f6` (re-run under v0.25.4) | 5/5 | 245s | completed / success |
| C | `project-spec-pipeline` | `run_20260510152736_2c71ad26` | 16/16 | 1182s | completed / success |
| D | `project-implementation-pipeline` | `run_20260510163740_9bea7f25` (under v0.25.6) | 15/15 | 1059s | completed / success |
| F | `cap promote` legacy + `cap promote inspect` | n/a | 6 promote ops + 6 inspects | <5s | identical |

Phase E (`project-qa-pipeline`) intentionally not run per user direction after Phase D succeeded.

## Bug ledger

11 dogfood-discovered bugs. Each marked Critical / Blocker / High / Medium per its surfacing impact.

| # | Severity | Symptom | Root cause | Fixed in |
|---|---:|---|---|---|
| 1 | High | `bind_semantic_plan` halted with `ProjectIdCollisionError` whenever cap ran outside the install dir | `RuntimeBinder.__init__` passed `self.base_dir` (cap install) into `ProjectContextLoader` | v0.25.1 |
| 2 | High | v0.25.1 partially fixed — production `workflow_cli.py` still passed only `base_dir`, fallback put `project_root = base_dir` | `cmd_plan` / `cmd_bind` / `cmd_build_bound_plan` did not thread `project_root=Path.cwd()` | v0.25.2 |
| 3 | High | `validate_constitution` halted immediately after a successful `draft_constitution` even though the artifact existed in the registry | `validate_inputs._try_resolve` short-circuited on `_INTRINSIC_ARTIFACTS` membership; never consulted the registry | v0.25.3 |
| 4 | **Critical** | `persist-constitution.sh` wrote `~/<project_id>/.cap/constitution.yaml` (and a full skeleton) to `$HOME/`, polluting the user's home directory | `TARGET_PROJECT_ROOT` derived from `CAP_ROOT` (cap install) plus a scaffold-style join | v0.25.4 |
| 5 | **Critical** | After a successful Phase B, the next pipeline halted with "project constitution is missing" | `ProjectContextLoader.DEFAULT_PROJECT_CONSTITUTION` read legacy `.cap.constitution.yaml`; persist wrote namespaced `.cap/constitution.yaml` | v0.25.4 |
| 6 / 8 | Medium | Spec artifacts from Phase C never landed in repo `docs/`; downstream pipeline AIs over-strictly judged `needs_data` | No producer support for spec markdowns; no resolver lookup by artifact name | v0.25.7 + v0.25.8 |
| 7 | **Blocker** | Phase D step 1 always halted with `missing_input_artifact:prior_spec_artifacts` — no implementation pipeline could ever start | `prior_spec_artifacts` had no resolver — neither registry, intrinsic, nor cross-pipeline | v0.25.4 |
| 9 | High | After v0.25.4 fixes, Phase D step 2 halted on `execution_plan/0/output_paths/0: '...' is not of type 'object'` | Schema requires object-shaped items; supervisor agent doc didn't specify, AI emitted strings | v0.25.5 |
| 10 | **Blocker** | After v0.25.5, Phase D step 4 (backend) halted with `missing:schema_ssot, api_contract, ba_spec` even though Phase C produced them | `validate_inputs._try_resolve` had no cross-pipeline lookup for individual named artifacts | v0.25.6 |
| 11 | High | After v0.25.7 / v0.25.8 wired typed `cap promote inspect`, the legacy `cap promote <src> <dst>` escape hatch silently wrote to the cap install dir | `target_path="${CAP_ROOT}/${repo_rel}"` — same family as #4 | v0.25.9 |

Pattern observation: **9 of 11 bugs are path-resolution / cross-pipeline-bridge gaps** that the in-repo smoke suite cannot exercise because the smoke fixtures pin `base_dir = REPO_ROOT` (single-dir-world) which collapses the bug surface. The remaining 2 are AI-output / schema mismatches.

## Patch ledger

| Tag | Date | Delta | Test fixture(s) added |
|---|---|---|---|
| v0.25.1 | 2026-05-10 | `engine/runtime_binder.py:203` ProjectContextLoader anchored to `project_root` | `test-binder-project-context-origin.sh` (5 cases) |
| v0.25.2 | 2026-05-10 | `engine/workflow_cli.py` 3 production sites pass `project_root=Path.cwd()` | same fixture extended (Case 4, 3 sub-cases) |
| v0.25.3 | 2026-05-10 | `engine/step_runtime.py validate_inputs._try_resolve` registry-first | `test-validate-inputs-intrinsic-vs-registry.sh` (7 cases) |
| v0.25.4 | 2026-05-10 | `cap-workflow-exec.sh run_shell_step` exports `CAP_PROJECT_ROOT/ID/HOME`; `persist-constitution.sh` honors it; `ProjectContextLoader` namespace fallback; `_INTRINSIC_ARTIFACTS` adds `prior_spec_artifacts` / `prior_implementation_artifacts` | `test-cross-pipeline-bridges.sh` (14 cases) |
| v0.25.5 | 2026-05-10 | `persist-task-constitution.sh normalize` converts string `output_paths` items to `{"path": "..."}` | `test-persist-task-constitution-output-paths-norm.sh` (4 cases) |
| v0.25.6 | 2026-05-10 | `validate_inputs._try_resolve` adds 3rd layer scanning prior pipeline `runtime-state.json` for individual named artifacts | `test-cross-pipeline-named-artifacts.sh` (7 cases) |
| v0.25.7 | 2026-05-10 | `promote_candidate_producer._detect_spec_artifact_candidates` + schema enum extension; policy §2 / §3.3 / §5.2 / §5.3 / §6.1 updated | `test-promote-candidate-producer-spec-artifact.sh` (16 cases) |
| v0.25.8 | 2026-05-10 | `detect_spec_artifact_candidate_for_name` + `promote_resolver.resolve_promote` 3rd lookup branch | same fixture extended (Cases 7a–7c, 8a–8b → 21 total) |
| v0.25.9 | 2026-05-10 | `cap-promote.sh` legacy branch reads `cap-paths.sh get project_root` instead of CAP_ROOT | `test-cap-promote-legacy-target-path.sh` (9 cases) |

Total: **9 patch releases, +63 regression test cases, all wired into smoke-layer.**

Cumulative smoke-layer coverage at v0.25.9:

- contracts **7 / 7**
- runtime **17 / 17** (12 prior + 5 new from v0.25.1–v0.25.6)
- project **8 / 8**
- promote **6 / 6** (4 prior + 2 new from v0.25.7–v0.25.9)
- orchestration **6 / 6**
- replay **5 / 5**
- e2e (full smoke-per-stage) **87 / 87**

## Final cap-test commit

```
master b301c70 (root-commit) feat(stt): land Component Repo dogfood baseline artifacts
  10 files changed, 2934 insertions(+)
```

Tracked artifacts:

```
.cap/constitution.yaml                                                139 lines
.cap/project.yaml                                                       5 lines
.gitignore                                                              5 lines
README.md                                                               7 lines
docs/architecture/component-next-dotnet-stt_PRD_v1.md                 192 lines
docs/architecture/component-next-dotnet-stt_TechPlan_v1.md            227 lines
docs/architecture/component-next-dotnet-stt_BA_v1.md                  647 lines
docs/architecture/component-next-dotnet-stt_API_v1.md                 410 lines
docs/architecture/database/component-next-dotnet-stt_schema_v1.md     410 lines
docs/design/component-next-dotnet-stt_UI_v1.md                        892 lines
```

`.gitignore` excludes `project-constitution/` (early Phase B binding snapshots — runtime execution trail, not promotable per policy §2).

`cap promote inspect` reports `conflict=identical` for all 6 spec artifact names against this commit, confirming the byte-equality contract between `<run_dir>/` source and repo target.

## Out-of-scope (deferred, not blockers)

These items were intentionally not exercised in this dogfood. They are next-round candidates, not closeout gaps:

- **Phase E (`project-qa-pipeline`)** — user explicitly stopped after Phase D ("Phase D 跑完就停，不進 Phase E"). Cross-pipeline resolver work is structurally complete; Phase E is expected to inherit the v0.25.6 lookup chain and run cleanly, but real evidence requires a real run.
- **Product Repo dogfood** — gated on this Component Repo baseline being green, which it now is. Whether to proceed is a separate go/no-go decision.
- **Phase 5 role/skill attachment runtime** — shipped in v0.25.0 but not exercised in this baseline (no advisory skill was actually attached to any step). Phase 6 builtin promotion remains gated on accumulated dogfood evidence.
- **Typed `cap promote spec-artifact <name> --apply`** — the apply path for spec_artifact still uses the legacy `cap promote <src> <dst>` escape hatch. Adding a typed surface mirrors `cap promote project-constitution` / `cap promote workflow`; deferred until concrete friction is observed (multi-artifact bulk apply ergonomics).
- **`cap promote workflow <run_id> --spec-artifacts` bulk command** — same rationale as above; deferred until manually applying 6 candidates per run becomes friction.
- **Implementation artifact promote (codebases / unit tests / docker-compose / qa / security audit / devops / impl_audit)** — Phase D produced these under `<run_dir>/` but the dogfood did not promote them to repo. CAP's current policy treats those as AI-emitted-into-project-root rather than promote-managed; whether to add a `code_artifact` artifact_type is its own design conversation.

## Recommendations for next round

Ranked by leverage:

1. **Add a workflow-driven smoke that runs cap from outside the install dir.** All 11 bugs survived because in-repo smoke fixtures pin `base_dir = REPO_ROOT`. A fixture that creates a sandbox repo outside the install dir and drives `cap workflow run` against it would have caught bugs #1, #2, #4, #5, #11 immediately.
2. **Document the path-resolution-bug pattern as a release-gate checklist.** Every shell script that derives a target path from `CAP_ROOT` should be flagged at review time. Pattern is repeating: bug #4 / #11 had nearly identical implementations in different scripts.
3. **Bring the persisted Phase D codebases into git via a typed promote.** Currently the implementation artifacts live only under `<run_dir>/`; a real Component Repo would want them committed. Designing `code_artifact` properly (target path mapping for src/, tests/, docker files) is the next dogfood-driven feature.
4. **Phase E dry-run from this Component Repo** — cheap evidence that the v0.25.6 cross-pipeline resolver also covers QA pipeline inputs (which depend on Phase D outputs analogously to how Phase D depends on Phase C).

## Provenance

- Dogfood driver: ad-hoc operator run from `~/projects/cap-test/component-next-dotnet-stt`.
- Time: 2026-05-10 13:30 → 17:25 Asia/Taipei (~4 hours including 9 patch releases, AI provider real-money calls, manual cleanup).
- CAP versions exercised: v0.24.7 (initial install) → v0.25.0 (already-shipped) → v0.25.1 → … → v0.25.9 (closeout).
- Cap-test repo: branch `master`, root-commit `b301c70`.
- Charlie-ai-protocols repo: branch `main`, last commit `35216c2`, last tag `v0.25.9`.

This document is the closeout for the Component Repo line. Next dogfood reports (e.g., Product Repo, Phase E) belong in sibling files in this directory.
