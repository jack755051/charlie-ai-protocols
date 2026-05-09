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

### Phase 1 Dogfood Evidence Log

Real runs collected against the shared `shared-karpathy-guidelines`
entry (priority 90, `kind: skill` since v0.24.8). All runs cite their
`run_id` so artifacts are traceable from this log.

| # | Run ID | Provider | Workflow | Input shape | Result | Notes |
|---|---|---|---|---|---|---|
| 1 | `run_20260510013742_00d4f6e5` | Claude 2.1.137 | karpathy-guardrails-smoke | meta (validate prompt resolution) | ✓ 98s | First real run; guardrail behaved per role; binding contract confirmed end-to-end. |
| 2 | `run_20260510014158_f3846a3f` | Codex 0.128.0 | karpathy-guardrails-smoke | meta (validate prompt resolution) | ✓ 50s | Codex parity on smoke; same binding outcome as Claude. |
| 3 | `run_20260510031125_51290ea5` | Claude 2.1.137 | karpathy-guardrails-smoke | meta (with explicit `kind: skill` metadata visible) | ✓ 122s | Claude observed the explicit `kind: skill` and self-declared advisory boundary. Surfaced the inference-rule misreading captured in ROLE-SKILL-REGISTRY-MODEL-MEMO §Phase 2 Risks. |
| 4 | `run_20260510032244_3b28eddb` | Claude 2.1.137 | karpathy-real-task-dogfood | real Python helper (`engine/workflow_cli.py:_filter_log_since`, 11 lines) | ✓ 114s | First real-task run; 5 grounded observations all citing specific lines / comments; respected "do NOT propose changes" user constraint. |
| 5 | `run_20260510032846_ea97f727` | Codex 0.128.0 | karpathy-real-task-dogfood | same prompt as #4 (Claude-Codex parity) | ✓ 54s | Codex parity on real-task; **complementary** observation set vs Claude. |

#### Cross-provider parity — same input, different observation profile

A/B between runs #4 (Claude) and #5 (Codex), same prompt and same
shared skill:

| Observation type | Claude #4 | Codex #5 |
|---|---|---|
| TOCTOU comment framing imprecise | ✓ | — |
| try/except ValueError might be defence-against-impossible-state | ✓ | — |
| Multi-line log entry: traceback continuation lines silently dropped | ✓ | — |
| `errors="replace"` swallows decode-failure signal | ✓ | — |
| **Naive-vs-aware datetime comparison risk** | — | ✓ (primary concern) |
| **Sub-second cutoff vs second-precision strptime boundary** | — | ✓ |
| Function scope is clean (positive observation) | ✓ | ✓ |
| docstring-vs-implementation alignment confirmed | — | ✓ |

Rough characterisation:

- **Claude bias**: framing / wording / contract-alignment / soft concerns.
- **Codex bias**: type / runtime correctness / hard concerns
  (the naive-vs-aware datetime issue is a real production-class bug
  that would actually fire if a caller passed a tz-aware `cutoff`).
- **Common ground**: both respected the advisory boundary
  ("do NOT propose changes"), both produced grounded observations
  citing specific code lines, both included a positive observation
  on scope cleanliness.

The provider-specific bias is a feature, not a bug — Phase 2 promotion
should be evaluated against the union of what both providers catch,
not the intersection. This also informs Phase 4 / 5 attachment work:
mounting this guardrail on top of role prompts will surface
provider-dependent observation profiles, which downstream consumers
should expect.

#### Side observation (not blocking Phase 2)

Both Codex runs (#2, #5) note in stdout that the expected skill
prompt path (e.g. `agent-skills/skills/karpathy-guidelines.md`) is
absent in the working directory; both fall back to the prompt
material delivered through the binding metadata. No prompt conflict
results, but this confirms that providers do attempt a
builtin-shaped lookup before honoring the shared-layer prompt
delivery — useful context for the future Phase 4 prompt-assembly
design.

### Toward Phase 2 Entry

Provisional evidence count after the runs above:

- ✓ Two-plus real runs without prompt conflict (criterion satisfied).
- ✓ Cross-provider parity confirmed (Claude + Codex both honor the
  advisory boundary; behaviour shape is provider-specific but
  contract is consistent).
- ⏳ "Reduces avoidable mistakes such as speculative abstractions /
  unrelated refactors / hidden assumptions / unverified completion
  claims" — needs more runs against varied inputs (refactor target,
  test plan, design review, debug task) before Phase 2 can confirm.

Recommendation: collect 1–2 more dogfood runs on different task
shapes before considering builtin promotion. Suggested next inputs
in the "scope creep risk" and "hidden assumption" categories so the
evidence covers more than just code review.

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
