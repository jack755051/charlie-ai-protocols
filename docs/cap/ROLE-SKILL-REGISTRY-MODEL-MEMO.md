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

### Phase 3: User-Imported Role Registration

Goal: make user-owned roles first-class through shared / project registries.

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

### Phase 4: Advisory Skill Attachment Design

Goal: design, not yet implement, how one executable role can receive one or
more advisory skills.

Tasks:

- Define attachment policy fields, for example:
  - `attach_to_capabilities`
  - `attach_to_roles`
  - `attachment_mode: advisory`
- Define conflict rules:
  - explicit user request wins
  - project constitution wins
  - role prompt owns task identity
  - advisory skill cannot override role boundaries
- Define prompt assembly order.
- Define binding report shape for attached skills.

Exit criteria:

- CAP can describe a future bound step as role + advisory skills.
- No executor implementation is required yet.

### Phase 5: Runtime Attachment Implementation

Goal: implement advisory skill attachment only after Phase 4 is accepted.

Tasks:

- Extend RuntimeBinder to select executor role and advisory skills.
- Extend execution plan schema with `attached_skill_ids`.
- Update `cap-workflow-exec.sh` prompt assembly carefully.
- Add dry-run and real-run tests with both Claude and Codex.

Exit criteria:

- Existing single-role workflows still run.
- Advisory skill prompt is visible through CAP-controlled prompt assembly.
- No prompt conflict appears in representative real runs.

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

Do Phase 1 only:

- add optional `kind`
- preserve all current behavior
- add resolver/schema tests

Do not start Phase 5 runtime attachment yet. That is the part that can become a
real refactor.
