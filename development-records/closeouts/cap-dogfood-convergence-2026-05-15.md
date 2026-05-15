# CAP Dogfood Convergence Memo — 2026-05-15

> Status: convergence checkpoint. Written **before** the P1b slice
> 6b live dogfood is allowed to consume real Claude tokens. Owner:
> operator. Purpose: stop adding features; decide what stays in CAP
> core and what should be re-classified as profile / template /
> doctor surface before the next slice is opened.
> Precedents: `docs/cap/COST-OPTIMIZATION-MEMO.md`,
> `docs/cap/COMPONENT-FAST-PATH-MEMO.md`,
> `development-records/closeouts/round-3-closeout-2026-05-10.md`,
> `development-records/closeouts/platform-closeout-v0.22.md`,
> `development-records/dogfood/component-fast-6b-runbook-2026-05-15.md`.

## 1. Why this memo (now)

The 2026-05-15 attempt to launch the P1b slice 6b live dogfood was
halted at preflight by `binding_status: blocked` because the target
repo's `.cap/constitution.yaml:binding_policy.allowed_capabilities`
predated P1b and was missing the six new component-fast capabilities.
The failure was real but the lesson is bigger than the failure:

- The fix is trivial (add six lines to one yaml).
- The class of failure is not. It is a **drift between framework-owned
  constitution and target-owned constitution** with no diff tool, no
  doctor, no promote step. The framework added capabilities in slice
  6b-0; the target repo had no way to know.
- A live dogfood will keep surfacing one-line drifts like this — each
  individually trivial, each demanding a new doctor / sync / audit /
  CLI surface. Pursuing all of them in-line keeps CAP shipping, but
  every patch widens the platform.

This memo declares a **freeze on new CAP surface area** until the
operator decides which dimensions of growth belong in core and
which should live elsewhere (profile, template, doctor, plugin).

## 2. P1b track — what shipped, what didn't

12 commits on `main` between `e8b4891` (P1a memo) and `bc1f14d`
(this runbook clarification). All P1b slices 1 through 6b-prep
landed deterministic substrate; slice 6b dogfood **did not run**.

| Slice | Commit | Subsystem | State |
|---|---|---|---|
| P1a memo | `e8b4891` | design | shipped |
| Slice 1 — registry | `87b6bcb` | `schemas/component-types/feedback-widget.yaml` | shipped, 16/16 test |
| Slice 2 — templates | `cc92ef6` | `templates/component-fast/feedback-widget/**` | shipped, 6/6 test |
| Slice 3 — render | `7dbad1f` | `scripts/workflows/component-fast-render.sh` | shipped, 30/30 test |
| Slice 4 — audit | `2fcc36a` | `scripts/workflows/component-fast-audit.sh` | shipped, 27/27 test |
| Slice 5 — workflow + caps | `06966ac` | `schemas/workflows/component-fast.yaml` + 6 new caps in `schemas/capabilities.yaml` + `_CODE_EMITTING_CAPABILITIES` patch | shipped, 21/21 test |
| Slice 6a — wrappers | `59be764` | `component-fast-resolve.sh` + `component-fast-smoke.sh` | shipped, 37/37 test |
| Slice 6b-0 — bind sanity | `18aba59` + constitution allowlist patch | binding regression guard | shipped, 35→44/44 test |
| Slice 6b-1 — skill mapping | `6117bfd` | `.cap/skills.yaml` + legacy `.cap.skills.yaml` | shipped, 44/44 test |
| Slice 6b-2 — dry-run | `5208c6a` | `tests/scripts/test-component-fast-dry-run.sh` | shipped, 28/28 test |
| Slice 6b-prep — smoke Dockerfiles | `3d64abd` | 3 new templates (frontend Dockerfile, frontend index.html, backend Dockerfile) | shipped, all regression tests still green |
| Slice 6b-plan — runbook | `a0f711a` + `bc1f14d` | live-run runbook + cwd discipline patch | shipped |
| **Slice 6b — live dogfood** | (none) | live Claude run + cost analyze + 5 threshold judgement | **NOT RUN. Frozen by this memo.** |

Deterministic substrate is therefore complete. The five P1a
thresholds (wall < 10 min, AI steps ≤ 2, prompt bytes ≤ 30%
baseline, 23/23 catalog rendered, smoke exit 0) **remain
unmeasured** because the live run never started.

## 3. P0 / P1 status snapshot

| Track | Status | Evidence |
|---|---|---|
| P0a — workflow contract + AI step result enum + AI write contract | shipped | commits `76ecc70` / `e7ca9ad` / §5.3.1 / §5.3.2 in `agent-skills/00-core-protocol.md` |
| P0b — `cap session analyze` cost telemetry | shipped | commit `4a7cdc0`; sparse Summary / Hotspots / Decision Signals view live |
| P1a — component-fast design memo | shipped | `docs/cap/COMPONENT-FAST-PATH-MEMO.md` |
| P1b — component-fast implementation | substrate shipped, live validation NOT RUN | this memo §2 |
| P1 — stop product-strict as default component dogfood loop | blocked on P1b live evidence | `docs/cap/COST-OPTIMIZATION-MEMO.md` line 63 |
| P2 — multi-preset support / additional component types | not started | intentionally deferred per P1a memo |
| P3 — resume broad multi-provider dogfood | not started | gated by P0/P1 per cost memo |

## 4. Bloat risk catalog (what would have come next if we didn't stop)

Every item below is real and would have been a defensible "next
slice". Together they are the platform-bloat trajectory.

1. **`cap workflow bind` target-constitution diff** — surface
   missing capabilities + suggest promote. *Why bloat:* introduces
   new CLI sub-surface (`--check-constitution` flag or doctor
   subcommand) that overlaps with constitution governance code.
2. **`cap component doctor` subcommand** — health-check target repo
   against current framework component-fast version. *Why bloat:*
   first instance of a per-profile doctor; pulls component-fast
   logic deeper into CLI; every future profile will want its own.
3. **`cap component init`** — scaffold a fresh Component Repo with
   constitution + skills + dirs pre-populated. *Why bloat:* core
   CLI now embeds a profile-specific scaffolding flow.
4. **Workflow profile routing** — `cap workflow run component-fast`
   auto-selects fast path when `component_type` resolves. *Why
   bloat:* dispatch logic in workflow CLI starts to know about
   specific profiles by name.
5. **Provider readiness gate** — pre-flight check that the chosen
   provider CLI can satisfy the bound roles' permission policy.
   *Why bloat:* a third governance layer beside binding + write
   contract; useful but expands the preflight surface.
6. **`cap-paths.sh` nested-project support** — handle component
   repos that live inside a host product repo. *Why bloat:* nested
   project identity is a real ask but doubles the SSOT chain
   complexity.
7. **Prompt file externalization** — let operators feed prompts
   from files instead of single-line shell args. *Why bloat:*
   ergonomics but introduces another input contract surface.
8. **Handoff summary normalizer** — auto-fix `result:` enum
   misuses, fenced-block edge cases beyond §5.3.1. *Why bloat:*
   tighter parser is good; but each new tolerance becomes a long-
   term contract.
9. **Additional `component_type` registry entries** — eg
   `auth-widget`, `pricing-widget`. *Why bloat:* every new type
   doubles template maintenance load while feedback-widget is
   still unproven against live thresholds.
10. **Compact-review AI persona tuning** — push the watcher
    role's compact-review skill toward a smaller / cheaper model.
    *Why bloat:* introduces provider-specific tuning in CAP core
    when it belongs at the skill layer.

Pattern: the items above are not wrong. They are individually
small, individually well-motivated. The risk is **scope drift by
accretion** — each slice is justifiable in isolation, none of
them is justifiable as the next priority.

## 5. Proposed core vs. profile boundary

This is the operator's call. The memo records the proposal so
the next slice can be opened against an explicit decision rather
than against a tacit assumption.

### 5.1 Proposed CAP core (stays)

The properties that every CAP user benefits from and that have no
sensible per-profile variant:

- **Workflow runtime**: `cap workflow compile / bind / run`,
  step executor, AI write contract, AI step result enum, handoff
  ticket schema.
- **Constitution governance**: project constitution loading,
  binding policy evaluation, allowed-capabilities enforcement,
  `binding_status` reporting.
- **Skill registry**: project / shared / builtin layered resolver,
  role + attached skills model (phase 5).
- **Observability**: `cap session analyze`, workflow result JSON,
  run archive summary, route history.
- **Provider abstraction**: `claude` / `codex` adapter, CLI flag
  wiring (landing dir, sandbox, permission mode).
- **Deterministic substrate hooks**: `executor: shell` workflow
  step type, deterministic_compliance_checklist capability shape,
  the *concept* of a registry + template + render + audit chain.

### 5.2 Proposed profile / template / plugin surface (leaves core)

Things that exist because feedback-widget exists, not because
every CAP user needs them:

- **`schemas/component-types/feedback-widget.yaml`** — registry for
  one specific component type. Belongs in a `feedback-widget`
  profile package, with the registry schema (not the entry) staying
  in core.
- **`templates/component-fast/feedback-widget/**`** — 23 templates.
  Profile package.
- **`scripts/workflows/component-fast-*.sh`** — render / audit /
  resolve / smoke wrappers. The four scripts are arguably *partly*
  generic (render and audit are template-driven), but as written
  they are feedback-widget-shaped. Recommend: split a generic
  `component-render.sh` + `component-audit.sh` into core, leave
  `component-fast-resolve.sh` + `component-fast-smoke.sh` in profile.
- **`schemas/workflows/component-fast.yaml`** — the seven-phase
  workflow definition. Profile package (workflow YAML can ship from
  profiles via `workflow_policy.allowed_source_roots`).
- **6 new capabilities in `schemas/capabilities.yaml`** —
  `component_fast_inputs`, `deterministic_scaffold`,
  `deterministic_compliance_checklist`, `runtime_smoke`,
  `component_repo_compact_review`, `component_repo_repair`. Mixed:
  `runtime_smoke` and `deterministic_compliance_checklist` are
  reusable across profiles and should stay in core. The remaining
  four are feedback-widget-shaped and should move to profile.
- **`_CODE_EMITTING_CAPABILITIES` entries** for the two
  profile-specific capabilities (`deterministic_scaffold`,
  `component_repo_repair`) should be registered by the profile
  package, not hardcoded in `engine/step_runtime.py`.

### 5.3 Proposed doctor / sync surface (NEW track, not new feature)

If the constitution-drift problem is going to be solved, it needs
to be solved once for all profiles, not per-profile:

- A generic `cap doctor` subcommand that takes a workflow id and
  diffs the workflow's required capabilities against the current
  project constitution's `allowed_capabilities`, with a clear
  "promote suggestion" output.
- The `cap workflow bind` report could carry the same diff as a
  warning block (non-halting if all caps resolve, halting if any
  blocked_by_constitution).

Either path is **out of scope for this memo**. Recording the
shape so the next operator decision is informed.

## 6. Freeze line (until the operator adjudicates §5)

The following are **paused** as of this memo:

- ❄️ New `component-fast` slices (no slice 6c, 6d, 7, etc.).
- ❄️ Live dogfood of P1b slice 6b (no Claude tokens spent on
  measuring the five thresholds yet).
- ❄️ New workflow profiles (no Component Repo variants, no other
  fast paths, no product-strict refactor).
- ❄️ New `component_type` registry entries (no `auth-widget`,
  `pricing-widget`, etc.).
- ❄️ New CLI subcommands (no `cap component init`, no
  `cap component doctor`, no constitution promote flags).
- ❄️ New audit / governance layers (no per-profile validators,
  no extended `cap session analyze` columns).
- ❄️ New template types or template-engine features.
- ❄️ New AI persona tuning / capability model swaps.

## 7. Allow-list (what is still permitted while frozen)

To stay actionable without re-opening growth:

- ✅ Closeout-level documentation (this memo; future
  `cap-core-vs-profile-decision.md` once operator decides).
- ✅ Pure reduction / removal (deleting unused code, retiring
  superseded paths, simplifying overlapping config).
- ✅ Explicit blocker fixes — a *blocker* meaning "a real green
  test failed today" or "a real user-facing command is broken".
  The 2026-05-15 binding drift was a blocker; the fix landed in
  the target repo only (not framework) and in `bc1f14d` as
  documentation. Future blocker fixes follow the same shape:
  smallest patch, dedicated commit, no scope creep.
- ✅ Operator-initiated re-baseline of any single P0/P1 evidence
  (eg re-run `cap session analyze` against an existing archived
  run to confirm it still parses).

## 8. Open questions for the operator

These are the decisions this memo wants to surface but does not
make:

1. **Is `component-fast` a CAP core feature or the first profile
   package?** This is the load-bearing question; everything in §5
   collapses to one answer or the other.
2. **If profile package: where do profiles live?** In-repo under
   `profiles/`? Separate git repo? Installable via `cap profile add`?
3. **Do we want a `cap doctor` track at all?** Or is target-repo
   constitution sync the operator's manual responsibility?
4. **Should the unmeasured P1a thresholds block any further P1
   work?** The thresholds are the whole point of P1; without the
   live measurement we are shipping fast-path substrate on faith.
   Options: (a) run the live dogfood once under the existing
   substrate, accepting the cost, before any §5 decision; (b)
   re-classify thresholds as P1c after the core-vs-profile split.
5. **What is the next *anchor* — a measurement or a decision?**
   Anchoring on a measurement (run the live dogfood) gives concrete
   evidence but burns quota. Anchoring on a decision (write the
   core-vs-profile split memo) gives clarity but defers evidence.

## 9. Suggested next single action

One of:

- **A — Decision anchor.** Operator drafts (or asks for) the
  `cap-core-vs-profile-decision.md` answering §8 q1 + q2. Live
  dogfood remains frozen. Outcome: clear core boundary; next P1
  slice is "extract profile" not "add features".
- **B — One-shot evidence anchor.** Operator authorizes ONE live
  dogfood run (≤ 1 Claude session) **without** committing to any
  follow-up slice. Outcome: measured thresholds; closeout
  appended; freeze remains until §8 q1 is answered.
- **C — Pure reduction.** Operator picks one currently-overlapping
  surface (eg the dual `.cap/skills.yaml` + `.cap.skills.yaml`
  paths) and instructs the codebase to retire the legacy side.
  Outcome: smaller surface area, no new evidence, no quota cost.

Recommend **A then B**: deciding the core boundary first means the
eventual live dogfood measures something whose lifecycle is
already understood.

## 10. Out of scope for this memo

- Picking between A / B / C in §9 (operator decision).
- Refactoring any of the substrate that already shipped.
- Mutating any target repo (the 2026-05-15 constitution patch on
  `~/Desktop/01_private/cap-test/component-feedback-widget/.cap/constitution.yaml`
  is dogfood-fixture-only and stays out of the framework repo).
- Re-opening the question of whether P0/P1 priorities themselves
  are right — they are reaffirmed by `COST-OPTIMIZATION-MEMO.md`.

— end memo —
