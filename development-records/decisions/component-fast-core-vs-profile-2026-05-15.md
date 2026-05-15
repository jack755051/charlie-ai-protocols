# Decision: classify component-fast as a reference profile, not CAP core

> Status: **accepted** (operator-ratified 2026-05-15).
> Type: architectural decision record (first ADR in
> `development-records/decisions/`).
> Triggered by:
> `development-records/closeouts/cap-dogfood-convergence-2026-05-15.md`
> §8 question 1 + §9 option A.
> Anchors: `docs/cap/COMPONENT-FAST-PATH-MEMO.md` (P1a design),
> `docs/cap/COST-OPTIMIZATION-MEMO.md` (cost driver),
> `agent-skills/00-core-protocol.md` §5.3 (write contract /
> result contract — both core).

## 1. Context

The 2026-05-15 P1b slice 6b live dogfood was halted at preflight
because the target repo's project constitution drifted from the
framework's. The natural follow-up patches — target-constitution
sync, `cap component doctor`, profile installer, more component
types, more capability registry entries, more audit layers — are
each individually defensible. Together they are a platform-bloat
trajectory.

The convergence memo froze new surface area and surfaced one
load-bearing question whose answer governs all the rest:

> Is `component-fast` a CAP core feature or the first profile
> package?

This ADR answers that question and the five sub-questions that
collapse to the same axis.

## 2. Decision

### Q1. What stays in CAP core?

The capabilities every CAP user benefits from and that have no
sensible per-profile variant:

- **Workflow runtime.** `cap workflow compile / bind / run`, step
  executor, AI write contract, AI step result enum (`§5.3.1` +
  `§5.3.2`), handoff ticket schema.
- **Constitution governance.** Project constitution loading,
  `binding_policy` evaluation, allowed-capabilities enforcement,
  `binding_status` reporting.
- **Skill registry.** Project / shared / builtin layered resolver
  + role + attached-skills model (phase 5).
- **Observability.** `cap session analyze`, workflow result JSON,
  run archive summary, route history.
- **Provider abstraction.** `claude` / `codex` adapter, CLI flag
  wiring (landing dir, sandbox, permission mode).
- **Generic deterministic-substrate framework.** The *concept and
  shape* of a registry → render → audit → smoke chain, plus the
  `executor: shell` step type. The framework lives in core; any
  *specific* registry / template / audit ruleset is a profile
  payload, not a core entry.
- **Profile loading mechanism.** A core-level rule for how the
  workflow runtime discovers and binds against an installed
  profile. Shape (in-repo `profiles/` vs separate repo vs
  `cap profile add`) is out of scope here — see Q5 + §6.

### Q2. What in component-fast is reclassified as profile?

The pieces that exist because `feedback-widget` exists, not
because every CAP user needs them:

- `schemas/component-types/feedback-widget.yaml` — one specific
  registry entry.
- `templates/component-fast/feedback-widget/**` — 23 template
  files.
- `schemas/workflows/component-fast.yaml` — the seven-phase
  workflow definition (workflow YAML can ship from profiles via
  `workflow_policy.allowed_source_roots`).
- `scripts/workflows/component-fast-*.sh` — render / audit /
  resolve / smoke wrappers, in their current
  feedback-widget-shaped form. The *generic* render and audit
  *engines* can be extracted to core later; the four scripts as
  written today are profile.
- Four of the six P1b capabilities — `component_fast_inputs`,
  `deterministic_scaffold`, `component_repo_compact_review`,
  `component_repo_repair`. These are feedback-widget-shaped and
  belong to the profile.

### Q3. Is the feedback-widget registry / templates only a reference profile?

**Yes.** `feedback-widget` is the first and currently only
reference profile. It is allowed to live inside the CAP repo as a
built-in profile package so the repo remains self-contained for
dogfood, but it does **not** define the contract every future
profile must imitate. Future profiles MAY:

- Use a different stack preset.
- Use a different storage default.
- Use a different audit ruleset.
- Decline to ship some template categories.

If a future profile shape conflicts with the
feedback-widget-shaped scripts, the **scripts** get generalized
(or split per-profile), not the profile contract.

### Q4. Should `_CODE_EMITTING_CAPABILITIES` accept profile-declared write capabilities?

**Yes** — this is a core-shape change, but a small one. Today
`engine/step_runtime.py` hardcodes the whitelist. After this ADR,
the contract is:

- Core ships the whitelist for the universal capabilities
  (`backend_implementation`, `frontend_implementation`,
  `qa_testing`, `devops_delivery`).
- Profiles register their own write-emitting capabilities through
  the profile loading mechanism. The runtime takes a union of
  core + active profiles.

The two feedback-widget-specific entries
(`deterministic_scaffold`, `component_repo_repair`) move from
core whitelist to profile declaration **once the loading
mechanism exists**. Until then they stay in the core whitelist
under the explicit caveat "to be migrated to profile manifest" —
this avoids breaking the substrate before the migration target
is built.

### Q5. Is target-repo constitution sync a core doctor or a profile installer concern?

**Core doctor.** The drift problem is generic: any workflow with
required capabilities can outpace any target repo's constitution.
Solving it once per profile would re-bloat in exactly the way
this ADR is meant to prevent.

Concretely:

- The diff logic ("workflow X requires caps A,B,C; target repo
  constitution allows A,B,D") is core.
- The promote action ("append C to target repo's
  `allowed_capabilities`") is core, surfaced via a generic
  subcommand (working name `cap doctor` — exact CLI shape is
  out of scope here; see §6).
- A profile installer, if it exists at all, only configures
  *profile-specific* state (binding fallbacks, profile-owned
  skill mappings, profile-owned workflow registration). It MUST
  NOT carry constitution-sync logic.

### Q6. Is the P1b live dogfood permanently re-scoped to evidence-only?

**Yes, with a single explicit allowance.** Per convergence memo
§9 option B, the operator may authorize **exactly one** live
dogfood run whose sole purpose is to fill the five unmeasured
P1a thresholds (wall < 10 min, AI ≤ 2, prompt bytes ≤ 30%
baseline, 23/23 catalog, smoke exit 0). That run:

- Produces an evidence appendix to the convergence memo.
- MUST NOT open any follow-up P1b slice.
- MUST NOT trigger feature work in response to whatever drift it
  surfaces; instead, any drift it surfaces becomes input to the
  profile-extraction track defined in §3.
- Is authorized only after this ADR is committed; it is not
  authorized by this ADR alone (operator must give an explicit
  "go" per the established freeze discipline).

## 3. Consequences

### Positive

- The repo can keep its current files in place — no immediate
  code motion required. The decision is about **trajectory**:
  what direction the next slice is allowed to point.
- Future operator instinct "the next slice is X" gets a clean
  pre-check: does X belong to core (per Q1) or to a profile
  (per Q2)? If profile, X is in scope only after the profile
  extraction track is open.
- The five bloat-risk items in convergence memo §4 that touch
  profiles (component_type registry growth, doctor, profile
  routing, init, persona tuning) are now decisively re-routed
  out of core.

### Negative / acknowledged costs

- `feedback-widget` lives in a halfway state until the profile
  loading mechanism (Q1 last bullet) actually exists. During
  this interim, the repo keeps two feedback-widget-specific
  capabilities in the core whitelist with a "to be migrated"
  caveat (Q4).
- The five P1a thresholds remain unmeasured under this ADR
  alone; the convergence memo's evidence gap is **not** closed
  by this decision. Closing it requires the one-shot run
  authorized in Q6.
- Any future profile package will pay a one-time integration
  cost (binding into the profile loading mechanism) instead of
  a zero-cost direct check-in.

### Out of scope (intentionally not decided here)

- The exact filesystem layout for profiles (`profiles/<name>/`
  vs separate repo vs `cap profile add` registry).
- The exact CLI surface for the doctor subcommand
  (`cap doctor`, `cap workflow doctor`, `cap constitution
  promote`, or a flag on `cap workflow bind`).
- Whether `runtime_smoke` and `deterministic_compliance_checklist`
  stay generic-core or eventually split into core-interface +
  profile-impl. Convergence memo §5.2 noted both as candidates
  for "stay in core"; this ADR neither confirms nor refutes
  that, pending the loading mechanism design.
- Any retroactive renaming of existing capabilities. The four
  profile-bound capability names (Q2) keep their current
  identifiers; migration only changes their declaration site.
- Live dogfood execution itself (Q6 conditional only).

## 4. Freeze status (unchanged from convergence memo)

The freeze line declared in
`development-records/closeouts/cap-dogfood-convergence-2026-05-15.md`
§6 remains in force after this ADR. The allow-list in §7 remains
in force. The only change this ADR makes to the freeze is
clarifying that **the next track is profile extraction**, not
more component-fast features.

The next operator decision is one of:

- **Open the profile-extraction track.** Smallest first slice
  would be the loading mechanism shape (Q1 last bullet + Q5),
  not the migration of feedback-widget itself.
- **Authorize the one-shot evidence run** (Q6) before opening
  any track, so the unmeasured thresholds get measured against
  the substrate as it stands today.
- **Pure reduction** as already permitted by convergence memo
  §7.

Recommend the **one-shot evidence run first**, then profile
extraction. Rationale: the evidence is cheaper to collect now
(substrate is fresh in mind, target repo constitution is already
patched) than after profile extraction starts moving files
around, and the resulting numbers give the loading-mechanism
design a concrete target.

— end ADR —
