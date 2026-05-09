# Karpathy Guidelines Integration Memo

> Status: planning memo
> Scope: staged integration of `/home/jack755051/projects/skills/andrej-karpathy-skills`
> into CAP without breaking provider isolation.

## Current State

Source skill:

```text
/home/jack755051/projects/skills/andrej-karpathy-skills/
  skills/karpathy-guidelines/SKILL.md
  CLAUDE.md
  .claude-plugin/plugin.json
```

Observed status:

- The skill is not referenced by CAP builtin `agent-skills/strategies/`.
- The skill is not listed in CAP builtin `.cap/skills.yaml`.
- The skill is not installed as a Codex skill under `~/.codex/skills/`.
- The skill is not installed as a Claude Code rule/plugin under `~/.claude/`.
- CAP workflows do not currently load it.

## Integration Principle

Use CAP's layered model:

```text
project > shared > builtin
```

Start with `shared` because this is a personal / cross-project engineering
guardrail, not yet a CAP official baseline. Promote to `builtin` only after
dogfooding shows it consistently improves CAP workflow quality.

Do not write to:

```text
~/.codex/AGENTS.md
~/.claude/CLAUDE.md
```

Global provider files are user-owned and must not be used as the integration
path for CAP-specific behavior.

## Phase 1: Shared Layer Integration

Goal: make the guidelines available to CAP projects through the shared layer,
without changing CAP builtin prompts or global provider configuration.

Target files:

```text
~/.cap/shared/skills/karpathy-guidelines.md
~/.cap/shared/skills.yaml
```

Tasks:

- Distill `skills/karpathy-guidelines/SKILL.md` into a CAP-style guardrail
  document.
- Preserve the core rules:
  - think before coding
  - simplicity first
  - surgical changes
  - goal-driven execution
- Add CAP-specific boundaries:
  - does not replace agent role prompts
  - does not override project constitution
  - does not override explicit user requests
  - applies lightly to trivial tasks
- Add or merge a shared registry entry in `~/.cap/shared/skills.yaml`.
- Do not modify `agent-skills/strategies/` in this phase.
- Do not modify global Codex / Claude files.

Suggested registry shape:

```yaml
schema_version: 1

skills:
  - skill_id: shared-karpathy-guidelines
    provider: shared
    enabled: true
    priority: 90
    prompt_file: skills/karpathy-guidelines.md
    provided_capabilities:
      - engineering_guardrails
      - code_review_guardrails
```

Validation:

- Run a binding command on a representative workflow.
- Confirm the binding report can show `source_layer: shared` when the shared
  skill is selected or inspected.
- If source policy blocks the shared path, opt in through the project
  constitution `allowed_source_roots`; do not bypass the source policy.
- Run at least one Codex-backed CAP workflow and one Claude-backed CAP workflow
  after opt-in, confirming behavior comes through CAP prompts rather than global
  provider files.

Exit criteria:

- Shared skill is available to opted-in CAP projects.
- No builtin CAP prompt changed.
- No global provider file changed.
- At least two real runs are observed without prompt conflicts.

## Phase 2: Builtin Candidate

Goal: decide whether the shared guardrail should become an official CAP
baseline strategy.

Entry criteria:

- Phase 1 has been dogfooded on real CAP tasks.
- The guidelines reduce avoidable mistakes such as:
  - speculative abstractions
  - unrelated refactors
  - hidden assumptions
  - unverified completion claims
- No repeated conflict with CAP role prompts, project constitutions, or user
  instructions has been observed.

Target file:

```text
agent-skills/strategies/karpathy-guidelines.md
```

Candidate agent attachments:

- `01-supervisor-agent.md`
- `02-techlead-agent.md`
- `04-frontend-agent.md`
- `05-backend-agent.md`
- `07-qa-agent.md`
- `10-troubleshoot-agent.md`
- `90-watcher-agent.md`

Agents to avoid in the first builtin pass unless a concrete need appears:

- `03-ui-agent.md`
- `09-analytics-agent.md`
- `12-figma-agent.md`
- `99-logger-agent.md`
- release/tag-only paths in `06-devops-agent.md`

Tasks:

- Convert the shared document into a CAP builtin strategy.
- Add explicit references from selected agent prompts.
- Keep the guidance concise enough to avoid bloating every task prompt.
- Add tests or static checks that references point to an existing strategy.
- Update docs describing when this strategy is active.

Validation:

- Run focused binding / source resolver tests.
- Run representative workflow dry-runs.
- Run at least one real workflow with Codex and one with Claude before release.
- Confirm no global provider configuration is required.

Exit criteria:

- Builtin strategy is committed to CAP.
- Selected agents reference the strategy.
- Codex and Claude CAP workflows receive the guidance through CAP-controlled
  prompts.
- Release notes document the promotion from shared dogfood to builtin baseline.

## Deferred

- Direct Claude plugin installation.
- Direct Codex native SKILL.md installation.
- Marketplace / publish flow for shared skills.
- Automatic migration from `/home/jack755051/projects/skills` into CAP.
- Shared layer drift tracking in replay verifier.

These should be handled only after the shared layer has at least one stable real
usage path.
