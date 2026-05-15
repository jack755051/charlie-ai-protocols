# CAP Deferred Expansion Audit (2026-05-15)

> Status: pre-removal audit.
> Anchors:
> [`docs/cap/CAP-POSITIONING.md`](../../docs/cap/CAP-POSITIONING.md),
> [`docs/cap/CAP-LEAN-ROADMAP.md`](../../docs/cap/CAP-LEAN-ROADMAP.md) §P6.
> Output: a per-surface decision table that gates the next removal
> slice. Audit only — this commit does NOT remove or rewrite any
> runtime code. Removal commits, if/when authorized, must cite the
> verdict from this file.

## 1. Why an audit before the next removal slice

Batches #4 and #5 retired the two surfaces that most directly
contradicted CAP's lean positioning (agent-skills "agent army"
narrative; provider-parity release-gate pattern). The remaining
expansion candidates are NOT a single coherent class — each has
its own runtime entry, its own test load, and its own degree of
overlap with the governance / observability core. Bundling them
into a single "chore(platform): remove promote design karpathy"
commit would over-trigger and almost certainly break tests
that have nothing to do with the new positioning.

This audit splits the bundle into per-surface verdicts so the
next removal slice opens against an explicit decision — not
against an emotional reading of CAP-POSITIONING.md.

## 2. Method

For each candidate surface, answer five fixed questions:

| # | Question | Why it matters |
|---|---|---|
| Q1 | Runtime entry — CLI / workflow / executor? | Surface size of the public contract. |
| Q2 | AI-entry conflict — does it position CAP as the AI entry point? | Direct test against CAP-POSITIONING.md. |
| Q3 | Governance fit — record / gate / observability? | Confirms whether retention is justified by core mission. |
| Q4 | Removal blast radius — tests / release / docs at risk? | Cost of immediate removal. |
| Q5 | Recommendation — keep / defer / remove. | The actionable output. |

Recommendation enum:

- **keep** — stays in lean core; no slice planned.
- **defer** — leave installed for now; revisit after at least one
  more lean cycle. Optionally docs-only downgrade.
- **remove** — schedule a removal slice with explicit blast-radius
  containment.

## 3. Per-surface verdicts

### 3.1 promote (`cap promote *`)

**Files / surface area**

- CLI: `scripts/cap-promote.sh` + dispatch in `scripts/cap-entry.sh:213-215`
  (`cap promote inspect / project-constitution / workflow`).
- Engine: `engine/promote_apply.py`, `engine/promote_candidate_producer.py`,
  `engine/promote_cli.py`, `engine/promote_resolver.py`.
- Docs: `docs/cap/PROMOTE-LIFECYCLE.md`, `policies/runtime-promote.md`.
- Tests (5+): `test-cap-promote-inspect.sh`,
  `test-cap-promote-legacy-target-path.sh`,
  `test-cap-promote-project-constitution.sh`,
  `test-cap-promote-workflow.sh`,
  `test-promote-candidate-producer.sh`,
  `test-promote-candidate-producer-spec-artifact.sh`.

**Q1** Yes — 3 CLI subcommands + 4 engine modules + 6 tests.
**Q2** No — promote is *post-AI*: it takes runtime artifacts
that already exist under `~/.cap/projects/<id>/` and copies them
back to the repo SSOT. It is a record / handover move, not a
prompt execution entry.
**Q3** **Yes**. Promote is the bridge between runtime artifact
storage and repo-as-SSOT. That is exactly the "post-AI record
and audit flow" the lean roadmap §P5 calls for.
**Q4** Medium. 6 tests gated on promote; CAP-LEAN-ROADMAP §P5
references a `version-control` workflow that pairs with promote
in the post-AI checklist. Removal would also strand
`~/.cap/projects/<id>/` artifacts as one-way (write-only)
storage.
**Q5** → **defer, lean toward keep.** Promote earns its keep
under lean positioning as long as it stays scoped to "move
runtime artifact back to repo" and does not grow into a
publish/marketplace surface. **Action item:** in the next pass,
re-read `PROMOTE-LIFECYCLE.md` for any wording that implies AI
orchestration, and trim if found. Do not touch the engine or
tests.

### 3.2 design source / Figma

**Files / surface area**

- Skill: `agent-skills/12-figma-agent.md` (already Tier 3 / Deferred
  per batch #4).
- Schema: `schemas/design-source-templates.yaml`.
- Engine: `engine/design_prompt.py`.
- Workflow scripts: `scripts/workflows/ingest-design-source.sh`.
- Docs: `docs/cap/DESIGN-SOURCE-RUNTIME.md`.
- Tests: `test-design-source-ingest.sh`,
  `test-design-source-resolution.sh`,
  `test-cap-workflow-design-package-forwarding.sh`.

**Q1** Yes — schema + engine module + ingest shell + 3 tests.
**Q2** **Partially.** The ingest step is invoked inside the
AI-heavy `project-spec-pipeline` (now legacy). On its own,
`design-source` resolution is a deterministic file-stage step —
it copies / validates design assets and does not call a model.
But its main consumer is a workflow that this codebase has
already classified as legacy.
**Q3** **Weak fit.** Deterministic file staging is governance-
adjacent, but the value proposition ("CAP knows how to ingest a
Figma export") is only meaningful when CAP is also running the
downstream AI design steps. After the AI-heavy pipelines were
demoted to legacy, the upstream ingest no longer serves the
lean core.
**Q4** Medium-high. 3 tests gated on design ingestion;
`test-cap-workflow-design-package-forwarding.sh` is wired into
`smoke-per-stage.sh`. Removal would require demoting the
corresponding smoke step and pruning the engine module.
**Q5** → **defer; remove candidate** for a follow-up slice
after promote is settled. Most likely future shape: keep the
skill file as Tier 3 / Deferred (already done in batch #4),
remove the schema + engine + ingest shell as a clean unit, and
update `smoke-per-stage.sh` accordingly.

### 3.3 Karpathy guardrails

**Files / surface area**

- Skill: `agent-skills/strategies/karpathy-guidelines.md` (Tier 3 /
  Deferred per batch #4).
- Memo: `docs/cap/KARPATHY-GUIDELINES-INTEGRATION-MEMO.md`
  (already flagged "deferred advisory skill expansion" in
  `docs/cap/README.md` §二).
- Workflows: `schemas/workflows/karpathy-guardrails-smoke.yaml`,
  `schemas/workflows/karpathy-integration-smoke-supervisor.yaml`,
  `schemas/workflows/karpathy-real-task-dogfood.yaml`.
- Capabilities: 2 guardrail capability blocks in
  `schemas/capabilities.yaml:584+`.
- Tests: `test-karpathy-strategy-builtin.sh`,
  `test-step-runtime-attached-prompts.sh`,
  `test-binding-report-schema.sh` (peripheral mention),
  `test-cap-workflow-cap-home-default.sh` (peripheral mention).

**Q1** Yes — 3 workflows + 2 capabilities + 2 dedicated tests.
**Q2** **Yes.** `karpathy-real-task-dogfood` is exactly the
"CAP as AI execution entry" pattern this restructuring is
moving away from. The other two karpathy workflows are smokes
that prove integration shape, not core gates.
**Q3** **No.** Karpathy guidelines are external engineering
advice (rules-of-thumb for LLM-assisted coding). They sit
at the same conceptual layer as `frontend-angular.md` or
`backend-nestjs.md` — provider-facing guidance, not CAP
governance.
**Q4** Medium. 2 dedicated tests + 3 workflows. None of these
are in the lean core's hot path; removing the workflows would
require auditing `smoke-per-stage.sh` and `smoke-layer.sh`.
The skill file itself stays untouched (it's already a Tier 3
optional skill).
**Q5** → **defer; remove candidate** for the same slice that
handles design source. Concrete suggested split:
- Keep `karpathy-guidelines.md` as Tier 3 / Deferred skill
  (already classified). Providers MAY still load it.
- Remove the 3 karpathy workflows (already AI-entry shaped).
- Remove the 2 guardrail capabilities from
  `schemas/capabilities.yaml`.
- Remove or merge the 2 dedicated tests.
- Demote `KARPATHY-GUIDELINES-INTEGRATION-MEMO.md` to a
  development-records archive note (already pointed at by
  README §二 as "deferred").

### 3.4 replay (`cap replay *`)

**Files / surface area**

- CLI: `scripts/cap-replay.sh`.
- Engine: `engine/replay_verifier.py`.
- Schema: `schemas/replay-verdict.schema.yaml`.
- Docs: `docs/cap/REPLAY-CONTRACT-DESIGN.md`,
  `docs/cap/REPLAY-USER-GUIDE.md`.
- Tests: `test-replay-verdict-schema.sh`,
  `test-replay-verifier.sh`,
  `test-replay-verifier-dual-axis.sh`.

**Q1** Yes — CLI + engine + schema + 3 tests.
**Q2** **No.** Replay is the inverse direction of AI execution:
it takes an *existing* `~/.cap/projects/<id>/` run and verifies
whether the rendered behavior matches what was recorded. No
provider call.
**Q3** **Yes — direct governance / observability fit.** Replay
is exactly the audit primitive the lean core needs. A workflow
run that left ledger artifacts can be re-played to confirm the
ledger is faithful, without re-spending quota.
**Q4** Low-medium. 3 tests gated on replay; the
`replay-verdict.schema.yaml` is a stable contract; the schema
test is part of the contracts smoke layer (`smoke-layer.sh
contracts` 7/7 includes the replay verdict schema).
**Q5** → **keep.** Replay is one of the cleanest fits for the
lean positioning. **Action item:** verify
`docs/cap/REPLAY-CONTRACT-DESIGN.md` and the user guide do not
imply CAP orchestrates AI runs (they should describe replay
strictly as a post-run governance tool). Otherwise no slice
needed.

### 3.5 detached / background run

**Files / surface area**

- Flag: `cap workflow run -d` / `cap workflow run-task -d`
  parsed in `scripts/cap-workflow.sh:704, 759, 792, 1004`.
- Current behavior: creates a runtime entry with state=detached
  then **prints** "Background mode is not yet implemented." and
  exits 0 without executing.

**Q1** Yes (flag exists), but no real runtime — the body is a
no-op stub.
**Q2** **No** directly, but it's a vestige from the era when
CAP planned to run long AI tasks in background.
**Q3** **No** — detached/background is an execution
orchestration concern. Governance + observability do not need
their executor to fork.
**Q4** Tiny. The flag is parsed but immediately short-circuits;
no test exercises the detached branch end-to-end.
**Q5** → **remove (low-risk).** Concrete slice: delete the
4 `-d` / `--detach` flag-parse cases + the no-op `if [
"${DETACH}" -eq 1 ]; then ...` blocks in `cap-workflow.sh`,
and remove any help-text mention. This is a 20-line cleanup.
**Action item:** can be folded into the design/Karpathy
removal slice OR done first as a standalone `chore(workflow):
remove detached run stub` micro-slice. Recommend doing it
**first** because the blast radius is essentially zero.

### 3.6 marketplace / publish

**Files / surface area**

- Active code: none.
- Aspirational mentions only:
  - `docs/cap/PLATFORM-GOAL.md:110` ("- marketplace / publish flows;")
  - `docs/cap/IMPLEMENTATION-ROADMAP.md:66` ("- publish / marketplace work;")
  - `docs/cap/ARCHITECTURE.md:245` ("skill marketplace 與 LangGraph backend")

**Q1** **No** — zero runtime entry. No CLI, no engine, no
workflow, no test.
**Q2** **Yes** — marketplace framing is exactly the "CAP
expansion ambition" the lean positioning narrows away from.
**Q3** **No** — selling / distributing skills is not governance.
**Q4** Trivial. No tests gated on marketplace. Removal is
text-only edits in 3 doc files.
**Q5** → **remove (docs only).** Edit the 3 mentions to either
remove the bullet entirely or mark explicitly "out of scope for
lean CAP". Concrete slice: `docs(cap): drop marketplace /
publish aspiration from active docs`. Risk: zero.

## 4. Summary table

| Surface | Q1 entry | Q2 AI-entry conflict | Q3 governance fit | Q4 blast radius | Verdict |
|---|---|---|---|---|---|
| 3.1 promote | yes | no | **yes** | medium | **defer / lean keep** |
| 3.2 design source / Figma | yes | partial | weak | medium-high | **defer; remove candidate** |
| 3.3 Karpathy guardrails | yes | yes (1 workflow) | no | medium | **defer; remove candidate** |
| 3.4 replay | yes | no | **yes** | low-medium | **keep** |
| 3.5 detached / background | flag only | vestige | no | tiny | **remove (low-risk)** |
| 3.6 marketplace / publish | no | yes | no | trivial | **remove (docs only)** |

## 5. Implied next slices (in priority order)

Per the verdict column, the post-audit removal queue is:

1. **`docs(cap): drop marketplace / publish aspiration from
   active docs`** — text-only in 3 docs. Zero test impact.
   Smallest possible "lean direction" signal.
2. **`chore(workflow): remove detached run stub`** — 20-line
   cleanup in `cap-workflow.sh`, no tests broken. Low risk,
   removes vestigial surface.
3. **`chore(skills): remove karpathy workflows + capabilities`**
   — retires `karpathy-real-task-dogfood` (AI-entry shaped)
   plus the two karpathy smoke workflows and the 2 guardrail
   capability blocks. Keeps the skill file as Tier 3 /
   deferred. Demotes the integration memo to historical.
4. **`chore(workflows): remove design source runtime`** —
   retires `ingest-design-source.sh` + `engine/design_prompt.py`
   + `schemas/design-source-templates.yaml` + 3 tests + smoke
   wiring. The Figma skill stays at Tier 3.

Slices 1 and 2 are safe to do back-to-back as small cleanups.
Slices 3 and 4 should each be their own commit because they
touch live tests in `smoke-per-stage.sh` / `smoke-layer.sh` and
need verification.

## 6. What this audit explicitly does NOT do

- Does not remove any runtime code.
- Does not edit any schema beyond mentioning what would be
  removed in slice 3/4.
- Does not modify any test.
- Does not authorize any of the slices in §5 — each one needs
  the operator's explicit go.
- Does not revisit the verdicts on promote / replay (keep / defer);
  those are stable until evidence to the contrary surfaces.

## 7. Verdict freshness

This audit reflects the codebase at commit `3ed5f64`
("chore(dogfood): remove provider parity runtime surface"). If
material changes land between this commit and the next removal
slice, re-read the §3 entries for the affected surfaces before
acting.

— end audit —
