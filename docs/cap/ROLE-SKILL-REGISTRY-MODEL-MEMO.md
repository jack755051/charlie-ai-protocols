# Role / Skill Registry Model Memo

> Status: planning memo
> Scope: define a staged model for separating executable agent roles from
> attachable skills / guardrails in CAP registries.
> Non-goal: no runtime implementation in this memo.

## Why This Exists

CAP originally used `agent-skills/` mostly as role prompts for development
agents such as frontend, backend, QA, security, and DevOps. Recent shared-layer
work introduced a different kind of entry: advisory skills such as Karpathy
guardrails. These are useful, but they are not full agent roles.

Without a clearer model, the registry has to overload one word, `skill`, for
two different things:

- executable agent personas
- attachable guidance, checklists, and guardrails

The goal is to make CAP more abstract and decoupled without breaking current
workflow binding.

## Complexity Assessment

This should be treated as a moderate refactor, not a large rewrite, if staged
carefully.

Low-risk parts:

- write down the conceptual model
- add optional schema fields such as `kind`
- keep legacy `skills:` entries valid
- add resolver tests for role-like and skill-like entries

Higher-risk parts:

- changing RuntimeBinder candidate ranking
- changing execution prompt assembly
- allowing one role plus multiple advisory skills per step
- promoting user/shared entries into builtin defaults

The safe path is to first make the registry more expressive while preserving
the current single selected skill behavior.

## Target Concepts

### Capability

A workflow-facing contract. Workflows should continue to depend on
capabilities, not file names, roles, or providers.

Examples:

- `frontend_implementation`
- `qa_testing`
- `security_audit`
- `engineering_guardrails`

### Role

An executable agent persona. A role can own a task and produce artifacts.

Examples:

- `$frontend`
- `$backend`
- `$qa`
- `$security`
- `$devops`

Role-shaped entries usually have:

- stable alias
- prompt file
- CLI / runtime
- provided capabilities
- output expectations

### Skill

An attachable capability module, checklist, strategy, or guardrail. A skill may
influence how work is done, but it does not necessarily own the step.

Examples:

- Karpathy engineering guardrails
- code review checklist
- API compatibility checklist
- SQL migration safety guide

Skill-shaped entries usually have:

- prompt or rule file
- provided advisory capabilities
- priority
- source layer
- optional attachment policy

## Proposed Registry Shape

Keep the existing `skills:` list for compatibility, but allow each entry to
declare a `kind`.

```yaml
schema_version: 2

skills:
  - kind: role
    skill_id: builtin-frontend-agent
    agent_alias: frontend
    provider: builtin
    prompt_file: agent-skills/04-frontend-agent.md
    cli: claude
    provided_capabilities:
      - frontend_implementation

  - kind: skill
    skill_id: shared-karpathy-guidelines
    provider: shared
    prompt_file: skills/karpathy-guidelines.md
    provided_capabilities:
      - engineering_guardrails
      - code_review_guardrails
```

Compatibility rule:

- missing `kind` means `role` when `agent_alias` is present
- missing `kind` means `skill` when no `agent_alias` is present
- existing registries should keep working without migration

## Binding Model

Short term:

```text
workflow capability -> selected registry entry
```

This is the current behavior. A role-like entry and a skill-like entry are both
still selectable as the single bound implementation.

Medium term:

```text
workflow capability -> selected role
                    -> attached advisory skills
```

This lets CAP choose one executor role while also mounting extra guardrails.

Example:

```text
frontend_implementation
  executor role: builtin-frontend-agent
  advisory skills:
    - shared-karpathy-guidelines
    - project-react-performance-checklist
```

This medium-term model should not be implemented until the schema and resolver
tests prove the distinction is stable.

## Source Layers

The existing layer order remains the right direction:

```text
project > shared > builtin
```

Responsibilities:

- `builtin`: CAP-maintained baseline roles and official strategies
- `shared`: user-owned cross-project roles / skills
- `project`: repo-specific overrides, additions, and masks

User-imported agent roles should register through shared or project registries,
not by editing CAP builtin prompts and not by writing directly into provider
global files.

Suggested user role entry:

```yaml
skills:
  - kind: role
    skill_id: shared-mobile-agent
    provider: shared
    agent_alias: mobile
    prompt_file: skills/mobile-agent.md
    cli: claude
    provided_capabilities:
      - mobile_implementation
```

Suggested user advisory skill entry:

```yaml
skills:
  - kind: skill
    skill_id: shared-api-review-checklist
    provider: shared
    prompt_file: skills/api-review-checklist.md
    provided_capabilities:
      - api_contract_review
```

## Invariants

- Workflows continue to reference capabilities only.
- Provider global files remain user-owned and are not CAP registry targets.
- Builtin role prompts are not changed by user-imported shared skills.
- Project and shared layers can add, replace, or disable entries through the
  registry contract.
- A user skill becoming builtin requires dogfood evidence, but the registry
  model itself does not need dogfood before design.

## Phased Task List

### Phase 0: Memo Only

Goal: capture the model and avoid ad-hoc terminology.

Tasks:

- Add this memo.
- Do not change RuntimeBinder.
- Do not change schemas.
- Do not change builtin prompts.

Exit criteria:

- Role, skill, capability, and source layer terms are documented.
- Follow-up implementation tasks are explicit.

### Phase 1: Schema Preparation

Goal: make the current registry able to express the distinction without
changing runtime selection behavior.

Tasks:

- Add optional `kind` to `schemas/skill-registry.schema.yaml`.
- Allowed values: `role`, `skill`.
- Document compatibility inference for entries without `kind`.
- Add schema examples for both role and skill entries.
- Add focused schema / resolver tests that prove old registries still pass.

Exit criteria:

- Existing `.cap.skills.yaml`, project registries, and shared registries remain
  valid.
- Tests cover explicit `kind: role`, explicit `kind: skill`, and legacy entries.

### Phase 2: Resolver Semantics

Goal: let RuntimeBinder classify entries internally while preserving the
current selected-skill output.

Tasks:

- Add internal helper to classify registry entries.
- Surface `entry_kind` in diagnostic / binding report only if low-risk.
- Keep existing `selected_skill_id`, `agent_alias`, `prompt_file`, and `cli`
  fields stable.
- Add tests for project > shared > builtin ordering across role and skill
  entries.

Exit criteria:

- Binder can explain whether an entry is role-like or skill-like.
- Existing workflow run behavior is unchanged.

#### Risks (from v0.24.8 dogfood)

Captured from real-run `run_20260510031125_51290ea5` (Claude smoke run after
the live `~/.cap/shared/skills.yaml` Karpathy entry adopted explicit
`kind: skill`):

- **The legacy inference rule reads counterintuitively to AI consumers.**
  Claude wrote in its advisory: "依 schema 推論規則 `agent_alias absent →
  kind = skill` 等價" — but the Karpathy entry *has* `agent_alias:
  karpathy-guidelines`, so the correct legacy mapping is
  `agent_alias present → kind = role`. The model still produced the right
  behaviour because explicit `kind: skill` overrides the inference; but the
  AI itself reasoned about the rule in the wrong direction.

  Root cause: `RuntimeBinder._has_execution_metadata` requires every
  selectable entry to carry `agent_alias` + `prompt_file` + `cli`. So
  advisory skills today **must** carry `agent_alias` even though the
  field's name implies "this is an executable agent". The presence of
  `agent_alias` is therefore a weak signal for "is this entry a role?" —
  in practice it's true for both roles and currently-selectable skills.

- **Phase 2 implementation must keep explicit `kind` strictly above
  inference.** The schema description already says so; this risk pins the
  contract by code-level requirement. Tests should assert: `kind: skill`
  on an entry that *also* has `agent_alias` is classified as `skill`,
  not coerced to `role` by inference.

- **Phase 4 attachment design should revisit `_has_execution_metadata`.**
  If advisory skills no longer need to be "selectable in the same slot as
  a role" once attachment is implemented (Phase 5), the metadata
  requirement can relax. A separate field (e.g. `mountable: true`) might
  carry the "this entry is consumable as a guardrail attachment" signal
  more cleanly than `agent_alias` does today.

- **Documentation hazard.** The schema description's compat rule reads
  `agent_alias present → role`. Anyone reading it without context may
  conclude "all current advisory entries are role-misclassified", which
  is technically true under inference and false under explicit `kind`.
  When Phase 2 ships, the rule should be re-stated in
  `schemas/skill-registry.schema.yaml` with an explicit caveat: "explicit
  `kind` always wins; inference is a soft fallback only".

Mitigation already in place (v0.24.8):

- Schema description spells out "explicit `kind` beats inference" in
  prose.
- `tests/scripts/test-skill-registry-kind-field.sh` case 4b asserts
  `explicit kind=skill wins over agent_alias-based inference` —
  if Phase 2 implementation regresses this, that test fails.

### Phase 3: User-Imported Role Registration

> Status: **landed at v0.24.11** — docs / schema example / resolver tests only.
> Runtime attachment behaviour is unchanged (still single selected entry per
> capability); advisory skill attachment remains deferred to Phase 5.

Tasks:

- Document how a user registers a shared role in `~/.cap/shared/skills.yaml`.
- Document how a project registers a repo-local role.
- Add `cap workflow bind` examples showing source layer and entry kind.
- Add negative tests for blocked source roots.
- Avoid writing to `~/.codex/AGENTS.md` or `~/.claude/CLAUDE.md`.

Exit criteria:

- A user role can be discovered by CAP through shared / project registry.
- Source policy remains enforced.
- No provider global files are modified.

Landing artefacts (v0.24.11):

- `policies/agent-skills-baseline.md` §3.5 — normative registry contract,
  source-layer rules, hard write-boundaries.
- `docs/cap/AGENT-SKILLS-CUSTOMIZATION.md` 場景 5 — user-facing how-to
  with project-layer + shared-layer examples and `cap workflow bind`
  verification flow.
- `schemas/skill-registry.schema.yaml` Examples block — three inline
  examples (project role, shared role, advisory skill).
- `tests/scripts/test-user-imported-role.sh` — six resolver / source-policy
  cases including the negative test for unauthorised shared layer.

Boundary kept (still untouched in v0.24.11):

- `engine/runtime_binder.py` not modified.
- `scripts/cap-workflow-exec.sh` not modified.
- `agent-skills/*-agent.md` builtin prompts not modified.
- No new schema fields added (only docstring-style examples).

### Post-v0.24.11 Safe Completion Boundary

Phase 3 intentionally stops at documentation, schema examples, and resolver /
source-policy tests. There is **no formal "user role dry-run" phase** in this
roadmap. A dry-run cookbook can be useful as an optional operator exercise, but
it is not a required lifecycle phase and should not be treated as a blocker for
Phase 3 completion.

The following CAP work lines have reached a "safe completion point" that does
not touch runtime execution:

| Work line | Safe completion point | Why this is the boundary |
|---|---|---|
| Run Observability | `logs` / `watch` / `inspect` / `ps` and read-only filters shipped | These surfaces read existing run directories and do not change provider invocation or step execution. |
| Run Observability Phase 5 Later | stderr capture, background `run -d`, and TUI / dashboard are documented as deferred | The remaining items touch `cap-workflow-exec.sh`, process detaching, or UI framework scope. |
| Karpathy shared → builtin | shared dogfood, 7-run evidence, builtin promote, and integration evidence are recorded | Further coverage should accumulate naturally; forced matrix completion would be costly and low signal. |
| Role / Skill Registry | Phase 4 + Phase 5 landed at v0.25.0 — selected_role / attached_skills binding-report fields, role/skill split in `_find_candidates`, strict-attach `_find_attached_skills`, and prompt assembly all shipped | Registry can now bind role + advisory attachments end-to-end. Phase 6 (builtin promotion of shared advisory skills) is the next deferred line. |
| User-imported roles | project/shared registration rules, source-policy tests, precedence tests, forbidden provider-global paths documented; advisory skill attachment now usable through the same registration channel (kind=skill with attach_to_*) | User roles + user advisory skills can both be registered and discovered. Future deferred work: Phase 6 promotion criteria for shared advisory skills. |
| CLI UX / Help | shortcuts, help topics, observe section, and unknown-command handling are shipped | Remaining work is polish unless a concrete discoverability issue appears. |
| CAP_HOME default | workflow dispatcher defaults `CAP_HOME=${HOME}/.cap` without overriding explicit user values | Generalising to every namespace should wait for a real non-workflow shared-layer case. |
| Provider/global isolation | provider global files are explicitly user-owned and not CAP registry targets | Native provider installation would be a separate high-risk integration path. |

Deferred runtime work should be opened only when a concrete use case appears:

- `role + attached skills` — a real workflow needs one executable role plus one
  or more advisory skills, and copying guidance into the role prompt becomes
  visibly wrong or duplicative.
- provider stdout/stderr capture — a real failed run cannot be diagnosed from
  existing `logs` / `inspect` artifacts.
- background `cap workflow run -d` — a real long workflow repeatedly blocks the
  operator's shell and needs first-class detach semantics.
- deeper harness / replay work — a real regression requires runtime-level
  evidence beyond current resolver and artifact tests.

Until one of those triggers occurs, the recommended state is natural dogfood:
use the shipped registry path in real work, record friction, and avoid adding
runtime abstractions proactively.

### ADR-style note: opening Phase 5 after v0.24.11

> Status: decision recorded before code lands.
> Trigger date: 2026-05-10.
> Context: this section justifies leaving the post-v0.24.11 "natural dogfood"
> state and entering Phase 4 + Phase 5 in a single coordinated change.

**Why now (the trigger).** Two converging signals:

1. The registry already carries `kind: role | skill` (v0.24.7) plus the
   v0.24.11 user-imported role registration story, but `_find_candidates`
   still treats every entry — including `kind: skill` — as a potential
   executor. In practice this means an advisory skill (e.g. shared
   Karpathy guardrails) **must** carry an `agent_alias` purely to
   satisfy `_has_execution_metadata`, even though the entry's purpose
   is guardrail-only. The `agent_alias` field is doing double duty and
   the schema doc already flags this as a Phase 4 risk
   (see §"Phase 2: Resolver Semantics — Risks (from v0.24.8 dogfood)").
2. Operators who try to layer a guardrail on top of an existing
   builtin role today have only two options: (a) duplicate the role
   prompt and edit it (fragile, divergent from upstream), or (b) accept
   that the guardrail entry replaces the role entirely (loses the
   role's identity). Neither matches the model the memo already
   describes (capability → role + advisory skills).

The strict-mode attachment design (see decision below) is therefore
not premature abstraction; it is the minimum coupling that lets
`kind: skill` stop pretending to be a role.

**What changes (scope).** This delivery folds Phase 4 design and Phase 5
runtime implementation into one coordinated change rather than landing
schema-only design first. Rationale: the binding report shape, binder
selection, and prompt assembly form one closed loop — splitting them
across releases would leave the registry expressive about something
the runtime cannot honor, which is exactly the trap the memo's
"Phase 5 only after Phase 4 is accepted" note was trying to avoid.

The five concrete edits:

- `schemas/binding-report.schema.yaml`: add optional `selected_role`
  and `attached_skills[]` step fields; keep `selected_skill_id` /
  `selected_agent_alias` / `selected_prompt_file` / `selected_cli`
  writing for legacy consumers.
- `engine/runtime_binder.py`: split candidate ranking into role-only
  selection + a separate attached-skill selection step; enforce source
  policy for both halves; emit both halves to the binding report.
- `engine/step_runtime.py` + `scripts/cap-workflow-exec.sh`: extend
  `flatten_steps` and `build_step_prompt` to mount attached skill
  prompts after the role prompt; shell executors do not receive
  attachments.
- Tests: flip `tests/scripts/test-skill-registry-kind-field.sh` case 5
  (kind=skill is no longer a standalone executor); add binder cases
  for role-only happy path, role + attached skill, attach blocked
  outside `attach_to_capabilities`, shared attached skill blocked
  without `allowed_source_roots`.
- Docs: update this memo (mark Phase 4 / 5 landed),
  `docs/cap/AGENT-SKILLS-CUSTOMIZATION.md` (worked example for
  `kind: skill` attach), and
  `docs/cap/SKILL-RUNTIME-ARCHITECTURE.md` (capability → role +
  attached skills picture).

**Decision: strict attachment policy (not auto-fan-in).** A `kind: skill`
entry is attached to a step only when:

1. The skill explicitly lists the step's capability in
   `attach_to_capabilities`, or lists the step's selected role's
   `agent_alias` in `attach_to_roles`, **and**
2. The skill's source layer is honored by the project constitution
   (`allowed_source_roots` enforcement still applies, identical to the
   role-side gate that v0.24.11 shipped).

Auto-fan-in (every `kind: skill` whose `provided_capabilities`
intersects the step capability gets attached) was considered and
rejected: the failure mode is silent — a shared advisory skill could
attach to every project that happens to share a capability name,
without the project owner seeing the dependency. Strict mode forces
the attaching skill to opt in, which makes the dependency reviewable
in the registry diff. Roles are never auto-attached — they own task
identity and cannot be silently demoted to advisory.

Conflict rules (kept from the original Phase 4 task list):

- Explicit user request wins (a step that names an attached skill in
  the workflow YAML beats both registry attach declarations).
- Project constitution wins (project layer can disable / replace an
  attached skill via the v0.22.0+ override contract).
- Role prompt owns task identity (the executor role's prompt is
  rendered first and always; attached skills cannot relabel the role).
- Advisory skill cannot override role boundaries (an attached skill
  may add guardrails, but the binding report's `selected_role`,
  `selected_provider`, and `selected_cli` are owned by the role).

**Rollback strategy.** If the change breaks real runs:

1. Revert at the binder level by toggling a single `_find_attached_skills`
   call site to return `[]` — `selected_role` keeps writing,
   `attached_skills` becomes empty, and prompt assembly falls back to
   single-role behaviour without any schema change.
2. The schema additions are optional, so old `binding-report.json`
   files written before this change still validate after the change;
   no migration needed.
3. If the strict-attach contract proves too tight in practice, the
   forward path is to add an opt-in `attachment_mode: capability_match`
   field rather than reverting to auto-fan-in — it keeps the strict
   default and lets specific projects relax case by case.

**Out of scope for this delivery.** Phase 6 (builtin promotion policy
for attached skills) is unchanged: a `kind: skill` entry in shared /
project layer still goes through the same dogfood evidence bar before
it can move into builtin. Phase 5 only changes how the runtime treats
existing entries; it does not promote anything.

### Phase 4: Advisory Skill Attachment Design

> Status: **landed at v0.25.0** alongside Phase 5 — see the ADR-style
> note above for why Phases 4 and 5 shipped as one coordinated change
> rather than two separate releases.

Tasks (all landed):

- Attachment policy fields (`attach_to_capabilities`, `attach_to_roles`)
  enforced by `RuntimeBinder._find_attached_skills`.
- `attachment_mode: advisory` is implicit — every `kind: skill` entry
  selected through this path is advisory by definition; the role
  prompt owns task identity. No explicit mode field is needed.
- Conflict rules implemented as documented:
  - Explicit workflow request wins (a step that names an advisory
    in workflow YAML beats registry attach declarations) —
    contract surface defined; consumer not yet wired (deferred to
    Phase 6 if a real workflow needs it).
  - Project constitution wins via the v0.22.0+ override contract
    (`disabled` / `replaces`) plus the source-policy gate, which
    halts attachments from unauthorised layers.
  - Role prompt owns task identity — `selected_role` is rendered
    first; advisory `attached_skills[]` follow.
  - Advisory skill cannot override role boundaries — schema rejects
    `selected_role.kind=skill`; binder filters `kind=skill` out of
    `_find_candidates` and `_find_fallback`.
- Prompt assembly order: role file (via the existing
  「請嚴格依照 ${SKILLS_DIR}/${prompt_file}」 line) → 「附加規範指引
  (Attached Advisory Skills)」 block listing advisory prompt paths →
  structured sections / contract / handoff template.
- Binding-report shape for attached skills: `selected_role` (object|null)
  + `attached_skills[]` (array, items carry `skill_id`,
  `prompt_file`, `attach_reason`, `skill_source`).

Exit criteria — **met**:

- ✅ CAP describes a bound step as role + advisory skills via
  `binding-report.schema.yaml` v1 (selected_role + attached_skills
  optional fields, additive — pre-Phase 5 reports still validate).
- ✅ Executor implementation landed at the same time as the design
  documentation; design and runtime no longer drift.

### Phase 5: Runtime Attachment Implementation

> Status: **landed at v0.25.0**.

Tasks (all landed):

- ✅ `RuntimeBinder` selects executor role and advisory skills via
  separate paths (`_find_candidates` for kind=role only;
  `_find_attached_skills` for kind=skill with strict opt-in).
- ✅ Execution plan carries `attached_skills` per step
  (`build_bound_execution_phases_from_semantic` propagates the
  field to active / deferred / standby steps).
- ✅ `engine/step_runtime.py` exposes the `attached-prompts`
  subcommand (TSV: prompt_file<TAB>skill_id<TAB>attach_reason);
  `flatten-steps` appends a 23rd `attached_count` field.
- ✅ `scripts/cap-workflow-exec.sh build_step_prompt` calls
  `attached-prompts` and renders an Attached Advisory Skills
  section before the structured contract block. Shell-executor
  steps don't reach `build_step_prompt`, so attachments are
  injection-only for AI executors.
- ✅ Tests: `tests/scripts/test-binder-phase5-attachment.sh`
  (13 cases) + `tests/scripts/test-step-runtime-attached-prompts.sh`
  (9 cases) added to the smoke-layer runtime suite.

Exit criteria — **met**:

- ✅ Existing single-role workflows still run unchanged. Only behaviour
  flip: `kind=skill` entries are no longer accepted as executors —
  documented at the post-v0.24.11 boundary as the deliberate Phase 5
  contract change. Real builtin / shared registries today have no
  workflow that depended on a `kind=skill` entry filling the
  executor slot.
- ✅ Advisory skill prompt is mounted through CAP-controlled prompt
  assembly (via `cap-workflow-exec.sh build_step_prompt`); the AI
  provider reads both files via its filesystem tools, no inline
  duplication.
- ✅ No prompt conflict in representative test fixtures. Real-run
  monitoring continues through natural dogfood (see Phase 6).

### Phase 6: Builtin Promotion Policy

Goal: define when shared roles / skills may become CAP builtin.

Tasks:

- Require dogfood evidence before builtin promotion.
- Track real tasks, provider, workflow, prompt conflict, useful effect, and
  negative side effects.
- Promote only entries that repeatedly improve workflow quality.
- Update release notes when a shared entry becomes builtin.

Exit criteria:

- Builtin CAP remains conservative.
- Shared / project experimentation stays easy.
- Promotion is evidence-based, not accidental.

## Recommended Next Step

> Status update: this section's earlier guidance ("Do Phase 1 only,
> do not start Phase 5") was the recommendation **before v0.25.0**.
> Phases 1 through 5 have all landed; the recommended next step has
> shifted to:

Watch dogfood evidence accumulate for Phase 6 (builtin promotion
policy):

- Track which shared advisory skills get attached repeatedly across
  real workflows.
- Track whether the role + attached_skills prompt assembly produces
  visible quality improvements in representative AI runs.
- Note any prompt-conflict signals — cases where the role prompt
  and an advisory skill disagree and the AI picks the wrong side.
- Open Phase 6 only when a specific shared advisory skill has
  enough evidence to justify promotion to builtin (the bar is the
  same as user-role promotion: multi-provider, multi-workflow,
  multi-task, repeatedly useful, no negative side effects).

Until Phase 6 opens, the recommended state is natural dogfood: use
`kind: skill` advisory skills in real workflows, accumulate evidence,
and avoid promoting anything proactively.
