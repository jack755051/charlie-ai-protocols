# Component Repo Dogfood Closeout — 2026-05-10

> Status: closeout report (post-action).
> Subject: ``~/projects/cap-test/component-next-dotnet-stt`` — minimal Component Repo fixture (Next.js + C#/.NET + PostgreSQL + Docker Compose, STT module).
> Driver tag: `dogfood/component-next-dotnet`.
> Goal of the run: prove the full CAP pipeline (`cap project init` → `cap workflow run project-constitution` → `project-spec-pipeline` → `project-implementation-pipeline` → `cap promote inspect`) can stably produce constitution / task constitution / spec artifacts / implementation artifacts / QA evidence / promote candidates against a from-scratch component repo.

## TL;DR

Baseline **cleared** under v0.25.9 after 9 patch releases. Phase A → D ran end-to-end with 36/36 AI sub-agent + shell steps green at the **runtime level**; 6 spec artifacts landed in the cap-test repo via the typed promote pipeline; final commit `b301c70` on cap-test master tracks 10 files / 2934 lines of authoritative artifacts.

Phase F (runtime validation) followed up on 2026-05-10 evening: an operator-authored skeleton (Next.js + .NET 8 + PostgreSQL 16 + Docker Compose) backed by `scripts/runtime-smoke.sh` exercises the full 3-tier stack end-to-end with **8/8 PASS** (compose build, compose up, backend health, backend `/health` contract, backend `/api/transcripts` contract, frontend HTTP serving, frontend → backend wiring, teardown). See `~/projects/cap-test/component-next-dotnet-stt/PHASE-F-runtime-report.md`.

The dogfood discovered **12 latent bugs** in total — 11 path-resolution / artifact-bridging issues that were invisible to in-repo smoke testing (smoke-layer / smoke-per-stage all stayed green pre-fix on every release v0.24.7 through v0.25.0; they only surfaced once cap was driven from a working repo *outside* the cap install dir), plus one structural bug (#12) discovered by Phase F that exposes a fundamental gap in how the workflow runtime interprets AI step results.

## Acceptance criteria — original ask vs delivery

The user's verbatim acceptance list (from the dogfood briefing):

| Criterion | Outcome |
|---|---|
| project constitution produced | ✅ `.cap/constitution.yaml`, 139 lines, schema-validated |
| task constitution produced | ✅ `~/.cap/projects/<id>/constitutions/happy-path-stt-component-formal-spec.json` |
| spec artifacts produced | ✅ 6 markdown SSOTs (PRD / TechPlan / BA / Schema / API / UI), 2778 lines |
| implementation artifacts produced | ⚠️ Phase D ran 15/15 at the runtime level, but the Phase F runtime validation discovered every AI step self-reported a blocked state (bug #12). No actual implementation code landed; the runtime skeleton in `cap-test` is operator-authored per the AI's spec markdown. See Phase F addendum below. |
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
| **12** | **Structural / Critical** | Phase D (`project-implementation-pipeline`) reports `final_state: completed / final_result: success / 15/15 PASS`, but every AI sub-agent step self-reported a blocked state in its markdown body (`blocked_read_only`, `FAIL_BLOCKED_*`, `[BLOCK]`). No actual implementation code landed in the project repo. CAP's `cap promote inspect` then happily emitted spec_artifact candidates against this run as if Phase D had succeeded. | Workflow runtime treats "non-empty stdout from AI step" as `ok` and never parses the AI's self-reported `result:` line. Compounding gap: AI agents discovered at runtime that project_root and `<run_dir>` were both read-only, so they had nowhere to land code; this constraint was not in their initial prompt. | **Deferred to design (post-v0.25.9)** — fix is non-trivial (workflow needs structured AI-result parsing + agents need write contract) |

Pattern observation: **9 of 11 path bugs are path-resolution / cross-pipeline-bridge gaps** invisible to the in-repo smoke suite (which pins `base_dir = REPO_ROOT`, collapsing the bug surface); 2 are AI-output / schema mismatches; and **the 12th is the most consequential — it shows the workflow's success contract is too lax to detect AI-side failure**, which means every "successful" Phase D / Phase E run before this fix lands needs to be re-evaluated against AI self-reports to know whether the implementation actually happened.

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

## Phase F (runtime validation) addendum — 2026-05-10 evening

### Scope

Phase F was added after the original A→D + promote closeout to answer one question: **can the produced Component Repo actually boot as a docker-compose stack and inter-connect, or are the workflow's "PASS" outputs misleading?**

The operator authored a minimum-viable runtime skeleton in `~/projects/cap-test/component-next-dotnet-stt/`:

- `backend/` — ASP.NET Core 8.0 minimal API. Single `Program.cs` with `/health` (probes Postgres connectivity) and `/api/transcripts` (stub returning empty `ApiResponse<T>`). Multi-stage Dockerfile, non-root runtime, curl installed for healthcheck.
- `frontend/` — Next.js 14.2 standalone build. App-router server-side fetch of backend `/health`, single home page with `data-testid="health-status"` for smoke greppability. Multi-stage Dockerfile, non-root runtime.
- `docker-compose.yml` — postgres + backend + frontend on a compose-managed bridge network. `depends_on: service_healthy` chain so backend waits for postgres and frontend waits for backend. Resource limits per cap-protocols DevOps policy 2.2.
- `scripts/runtime-smoke.sh` — 8-step validation harness (prerequisite check, build, up, backend health, `/health` contract, `/api/transcripts` contract, frontend HTTP serving, front-to-back wiring). Auto-teardown via trap. Auto-emits Markdown report to `PHASE-F-runtime-report.tmp.md`.
- `docs/runtime-profile.md` — locks the Component Runtime Profile contract: stack pin (Next.js 14 / .NET 8 / Postgres 16 / Compose v2) + Phase F validation expectations (5 contract points).

### Result

`scripts/runtime-smoke.sh`: **8 / 8 PASS** on first non-flaky run after fixing two skeleton bugs surfaced during smoke (the `server-only` package was not installed; the aspnet:8.0 base image lacks wget so the healthcheck needed curl; both fixed in commit). Cold first run ~3-5 min including npm install + dotnet restore; warm re-run ~80s.

The full report lives at `~/projects/cap-test/component-next-dotnet-stt/PHASE-F-runtime-report.md`. Highlights:

| Question | Answer |
|---|---|
| Can `docker compose up` produce a running 3-tier stack from this repo? | Yes |
| Can backend reach Postgres? | Yes — `/health` returns `db=reachable` |
| Can frontend reach backend? | Yes — server-side render shows `health-status=ok` |
| Is this a complete STT component? | No — runtime skeleton only |
| Did CAP's Phase D produce this code? | **No (bug #12)** |
| Is the Component Runtime Profile contract met? | Yes |

### Why Phase F's skeleton is operator-authored, not CAP-produced

This is the bug #12 surface. CAP's Phase D run (`run_20260510163740_9bea7f25`) ran with read-only filesystem sandboxing for the AI agents. Every AI step (`backend`, `frontend`, `qa_testing`, `security_audit`, `devops_packaging`, `impl_audit`, `archive`) detected at runtime that project_root and the workflow output dir were both unwritable, gracefully self-reported `blocked_read_only` / `FAIL_BLOCKED_*` in their markdown bodies, but emitted those reports to stdout — which CAP's workflow runtime captured as a successful step.

`result.md` then rolled up `15/15 ok / final_state: completed / final_result: success`, even though zero implementation code exists.

This means Phase F could not validate CAP's actual code generation — there was no code to validate. The skeleton in this commit is hand-written by the operator following the spec markdown CAP genuinely produced in Phase C (where markdown output IS the artifact, so the read-only-stdout pattern works).

### What Phase F validates after bug #12

Phase F's contribution is twofold:

1. **The Component Runtime Profile is sound.** A 3-tier docker-compose stack of Next.js + .NET 8 + Postgres 16 boots, inter-connects, and serves the spec-mandated `ApiResponse<T>` envelope. This unblocks future runs from re-deciding the stack.
2. **Bug #12 is real and material.** The discovery elevates dogfood-finding count from 11 to 12 and shifts the post-v0.25.9 deferred list: before Phase F we said "Phase E is expected to inherit v0.25.6 lookups"; after Phase F we have to say "Phase E will likely succeed at the runtime level the same way Phase D did, but the actual deliverable (qa test code, security audit reports) needs the same write-contract fix bug #12 demands before it can be trusted to actually exist."

### Recommended priority for bug #12

The fix is two-part and non-trivial:

1. **Workflow runtime: parse AI step result.** Instead of `non-empty stdout = ok`, the runtime should look for a structured result marker (`result: ok` / `result: blocked_*` / `result: FAIL_*`) in the AI's emitted markdown, and propagate that to `execution_state`. This is a Watcher-style audit added at the step boundary; ~50 LOC in `cap-workflow-exec.sh` plus a regression fixture.
2. **AI agent write contract.** Decide whether agents should: (a) get write access to project_root with a clear no-bypass policy for sensitive paths, (b) get a designated artifact landing dir under `<run_dir>/code/` that promote machinery later moves, or (c) be told upfront "your output is markdown describing the implementation; a separate scaffold step writes files." The AI agent prompts and the workflow YAML's `output_paths` contract both need updating to match the chosen policy.

Either of these on its own is partial; both shipped together close the loop.

This is **not** a v0.25.x patch candidate — it's a v0.26.0 design item.

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

1. **Fix bug #12 — workflow runtime needs structured AI-result parsing + an AI write contract.** This is the highest-leverage item by a wide margin. Until it's fixed, every "successful" implementation pipeline run is suspect; CAP cannot be trusted to actually produce code. Two-part fix sketched in the Phase F addendum above. **Block any further implementation-pipeline-driven work until this lands.**
2. **Add a workflow-driven smoke that runs cap from outside the install dir.** All 11 path bugs survived because in-repo smoke fixtures pin `base_dir = REPO_ROOT`. A fixture that creates a sandbox repo outside the install dir and drives `cap workflow run` against it would have caught bugs #1, #2, #4, #5, #11 immediately. Phase F's `runtime-smoke.sh` is a per-repo template; the cap-side equivalent should run cap end-to-end from a sandbox repo and assert produced artifacts actually exist on disk (not just that workflow result reports `ok`).
3. **Document the path-resolution-bug pattern as a release-gate checklist.** Every shell script that derives a target path from `CAP_ROOT` should be flagged at review time. Pattern is repeating: bug #4 / #11 had nearly identical implementations in different scripts.
4. **Component Runtime Profile lock + smoke as part of CAP's spec output.** `docs/runtime-profile.md` + `scripts/runtime-smoke.sh` proved valuable; they should be templates CAP's spec pipeline emits per project so any consumer of CAP's output can validate the runtime substrate without hand-authoring the smoke harness.
5. **Phase E dry-run from this Component Repo** — but only after bug #12 fix lands. Otherwise Phase E would repeat Phase D's "structural pass / AI bailed" pattern on QA test code generation.

## Provenance

- Dogfood driver: ad-hoc operator run from `~/projects/cap-test/component-next-dotnet-stt`.
- Time: 2026-05-10 13:30 → 17:25 Asia/Taipei (~4 hours including 9 patch releases, AI provider real-money calls, manual cleanup).
- CAP versions exercised: v0.24.7 (initial install) → v0.25.0 (already-shipped) → v0.25.1 → … → v0.25.9 (closeout).
- Cap-test repo: branch `master`, root-commit `b301c70`.
- Charlie-ai-protocols repo: branch `main`, last commit `35216c2`, last tag `v0.25.9`.

This document is the closeout for the Component Repo line. Next dogfood reports (e.g., Product Repo, Phase E) belong in sibling files in this directory.
