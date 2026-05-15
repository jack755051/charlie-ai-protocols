# Component Fast Path — Slice 6b One-Shot Evidence Run Closeout (2026-05-15)

> Status: evidence-only closeout per
> `development-records/closeouts/cap-dogfood-convergence-2026-05-15.md`
> §9 option B + `development-records/decisions/component-fast-core-vs-profile-2026-05-15.md`
> Q6. Result: **fail — halted at Phase 1 before any timed work**.
> Zero AI tokens spent. Freeze line (convergence memo §6) remains
> in force; this closeout classifies the failure and STOPS, per
> the operator's explicit instruction.

## 1. What the run was authorized to do

A single live `cap workflow run --cli claude component-fast` from
the target repo cwd, using the exact baseline prompt from the
2026-05-13 P0b-2 dogfood, with the goal of producing measurements
for the five P1a thresholds and nothing else.

Authorized preflight gates (all green before launch):

- ✅ CAP root clean (only stale `templates/component-fast/feedback-widget/backend/Feedback/obj/` untracked build artifact; ignored).
- ✅ Target repo dirty status acceptable (intentional fixture state: `.cap/`, `README.md`, `docs/` from previous dogfoods).
- ✅ Target repo cwd `cap workflow bind component-fast`: `binding_status: ready`, `total=7, resolved=7, fallback=0, required_unresolved=0` (registry source = framework `.cap/skills.yaml`).
- ✅ Docker daemon up (v29.4.0) + all 4 required images cached locally.
- ✅ Target repo `.cap/constitution.yaml` patched 2026-05-15 to include 6 P1b capabilities (dogfood-fixture-only mutation, not in framework repo).

## 2. Run identity

| Field | Value |
|---|---|
| Run id | `run_20260515100635_e765bd8d` |
| Started | `2026-05-15 10:06:36` |
| Finished | `2026-05-15 10:06:37` |
| Total duration | 1s |
| Final state | `failed` |
| Steps total / completed / failed / blocked | 1 / 0 / 1 / 1 |
| AI sessions invoked | 0 |
| Provider tokens consumed | 0 |
| Files written under landing dirs | 0 |
| Run dir | `~/.cap/projects/component-feedback-widget/reports/workflows/component-fast/run_20260515100635_e765bd8d/` |
| `cap session analyze --run-id …` output | `{"ok": false, "error": "no_sessions_found", "query": {"run_id": "run_20260515100635_e765bd8d"}}` (captured at `/tmp/component-fast-6b-analyze-20260515.txt`) |

## 3. Where it halted

Phase 1 of 7 — `resolve_inputs` (capability:
`component_fast_inputs`, executor: shell wrapper at
`scripts/workflows/component-fast-resolve.sh`).

Halt reason as reported by the runtime:

```
blocked_reason: missing_input_artifact
missing: component_fast_args
```

`workflow.log` excerpt:

```
[2026-05-15 10:06:37][shell:scripts/workflows/component-fast-resolve.sh]
  [phase:1 step:resolve_inputs capability:component_fast_inputs
   blocked_reason:missing_input_artifact missing:component_fast_args]
  [blocked]
```

Phases 2 through 7 (`render_skeleton`, `deterministic_audit`,
`smoke_runtime`, `compact_review`, `fix_or_polish`, `archive`)
never started.

## 4. Five P1a threshold table

| # | Threshold | Target | Observed | Pass? |
|---|---|---|---|---|
| 1 | Wall time | < 10 min (600s) | n/a (halted at 1s before any timed work) | **unmeasured** |
| 2 | AI step count | ≤ 2 | 0 sessions invoked | **unmeasured** |
| 3 | Total prompt bytes | ≤ 30% × baseline | 0 / no baseline comparison possible | **unmeasured** |
| 4 | Required files generated | 100% (23/23) | 0/23 — `render_skeleton` never ran | **unmeasured** |
| 5 | Smoke test exit code | 0 | n/a — `smoke_runtime` never ran | **unmeasured** |

**Verdict**: 0/5 thresholds verified. Per operator rule "don't
relax threshold, don't auto-develop", this closeout records the
unmeasured state and does NOT redefine, soften, or split any of
the five.

`docs/cap/COST-OPTIMIZATION-MEMO.md` P1 row stays at its current
status ("substrate shipped, live validation NOT RUN"). No update
applied by this closeout.

## 5. Failure classification

Using the five-category enum the operator pinned for this run:

| Category | Apply? | Why |
|---|---|---|
| core bug | ❌ | The workflow runtime behaved exactly as designed: `resolve_inputs` declared `inputs: [component_fast_args]` in `schemas/capabilities.yaml`, the upstream artifact was absent, the runtime halted instead of fabricating a default. Halt-on-missing-input is the documented contract from `agent-skills/00-core-protocol.md` §5.3.1 / §5.3.2 era. |
| profile bug | ✅ | **Selected.** The `component-fast` profile defines an input contract that has no operator-facing path to satisfy. The capability declares `inputs: [component_fast_args]` (a structured object: `component_type`, `project_id`, `project_root`, `stack_preset`, `ui_adapter`, `storage_default`, `exclusions`). The operator-facing entry point — `cap workflow run --cli claude component-fast "<prompt>"` — accepts only a free-form prompt string. Nothing in the profile translates the prompt into `component_fast_args`, and no other surface (CLI flag, file, manifest) produces it. This is a profile-internal contract gap, not a runtime bug. |
| target repo drift | ❌ | Target repo `.cap/constitution.yaml` was patched 2026-05-15 to include all six P1b capabilities; bind reported `ready` from target cwd; preflight `cap workflow run --dry-run` exited 0 with `Binding: ready`. The constitution drift that blocked the earlier 09:20 attempt is fully resolved. |
| environment bug | ❌ | Docker daemon up, 4 required images cached, working tree consistent, no network or filesystem error in the log. |
| provider behavior | ❌ | Zero AI sessions were invoked. No Claude / Codex output to evaluate. |

**Classification**: `profile_bug` (single category, per the
operator's "pick exactly one per row" rule).

## 6. Why dry-run did not catch this

The dry-run path (`cap workflow run --dry-run`) prints the bind
report and the seven-phase plan, then exits before any step
executes. Input-artifact resolution happens at *step entry*, not
at plan time, so a missing required input is invisible to
`--dry-run`. The 2026-05-15 preflight §2.2 dry-run reported
green; the live run halted on the first real step.

This is recorded for the future-CAP discussion (out of scope for
this closeout). It is **not** a fix proposal.

## 7. What this closeout deliberately does NOT do

Per convergence memo §6 freeze line + ADR Q6 + the operator's
explicit instruction:

- ❌ Does not open a new component-fast slice to plumb prompt →
  `component_fast_args`.
- ❌ Does not propose a `--component-type` / `--project-id` /
  similar CLI flag on `cap workflow run`.
- ❌ Does not propose a profile-side input adapter.
- ❌ Does not propose a `cap component init` / `cap component
  doctor` to bypass the contract gap.
- ❌ Does not relax any of the five thresholds.
- ❌ Does not authorize a retry of the live run with a different
  invocation shape.
- ❌ Does not update `docs/cap/COST-OPTIMIZATION-MEMO.md`.
- ❌ Does not commit, mutate, or even read the target repo
  beyond the immediate run artifacts under
  `~/.cap/projects/component-feedback-widget/…`.

The classification (§5) is the entire deliverable. Any follow-up
work requires the operator to re-authorize per the freeze
discipline.

## 8. Pointers (for any future re-baseline)

- Run dir: `~/.cap/projects/component-feedback-widget/reports/workflows/component-fast/run_20260515100635_e765bd8d/`
- `workflow-result.json` schema-valid, P7 builder rendered `result.md` cleanly.
- `agent-sessions.json` contains only the six baseline metadata attachments (agent_skills_baseline, project_skill_baseline, binding_summary, workflow_yaml_baseline, constitution_baseline, capability_schema_baseline). No actual AI session bodies.
- Analyze stub: `/tmp/component-fast-6b-analyze-20260515.txt`
- Full live-run log: `/tmp/component-fast-6b-live.log` (28 lines, captures bind + phase 1 halt + artifact listing).
- Capability definition for `component_fast_inputs`:
  `schemas/capabilities.yaml` (declares `inputs: [component_fast_args]` + `outputs: [component_fast_resolved]`).
- Workflow YAML: `schemas/workflows/component-fast.yaml`.
- Operator-facing wrapper (where the contract gap lives):
  `scripts/workflows/component-fast-resolve.sh`.

## 9. Operator decisions still open

Same list as convergence memo §8 / ADR open scope, unchanged by
this closeout:

1. Open the profile-extraction track (preferred per ADR §4).
2. Authorize a *second* one-shot run after a future operator
   patch to the prompt-to-args path (would require lifting the
   "no new component-fast features" freeze line — operator
   decision, not closeout proposal).
3. Pure reduction (always permitted under convergence memo §7).

— end closeout —
