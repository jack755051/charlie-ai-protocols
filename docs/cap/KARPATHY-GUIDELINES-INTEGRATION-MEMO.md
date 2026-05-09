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
| 6 | `run_20260510033543_cf1c5900` | Claude 2.1.137 | karpathy-real-task-dogfood | refactor-proposal evaluation (extract cap-workflow.sh logs/watch dispatchers); explicit "do NOT write patch" constraint | ✓ 216s | **Scope-creep-resistance test.** Claude resisted the temptation to write the patch, surfaced 5 specific re-evaluation triggers + 5 operationalised "extraction succeeded" criteria, and called out a hidden classification question in the proposal itself ("why logs/watch but not inspect/ps/show?"). See A/B note below. |
| 7 | `run_20260510034413_46f2cef5` | Claude 2.1.137 | karpathy-real-task-dogfood | hidden-assumption debug (real v0.24.8 bug: bash heredoc inside `git tag -m "$(cat <<EOF...)"` silently dropped `` `kind: skill` `` from the annotation body); explicit "do NOT propose fix" constraint | ✓ 235s | **Single-root-cause-speculation resistance test.** Claude listed 8 mental-model assumptions (A1–A8) and 5 root-cause hypotheses (RC1–RC5) ordered by evidence-fit. RC1 (unquoted heredoc body + markdown backticks triggering command substitution) cleanly closes all three pieces of evidence (stderr text + double-space substitution + "actual command was longer"). Claude also surfaced RC5 specifically to **rule out** an incorrect inference path (A8: outer `"..."` swallowed mid-body) — exactly the Karpathy Rule 1 "if multiple interpretations exist, present them" discipline. |

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

#### Scope-creep-resistance evidence (run #6)

The refactor-proposal scenario is harder than code review because the
default failure mode of an LLM facing "should I refactor X?" is to
just write the refactor. Run #6 was deliberately constructed to test
that:

- The user prompt asked four advisory questions (worth-doing? missed
  tradeoffs? do-nothing alternative? success criteria?) and explicitly
  forbade a patch / target file structure / exec wiring.
- Claude lean: **"do not extract right now"** — concrete enough to
  act on, not handwavy.
- Five re-evaluation triggers are operationalised (e.g. "logs or
  watch case body grows past 200 lines", "third observe-class verb
  appears so the extraction names a real category"); none are
  speculative "maybe someday".
- Five "extraction succeeded" criteria push back on `tests pass` as a
  vanity metric and demand byte-level help-text equivalence,
  CAP_HOME-SSOT preservation, a 30–60 day post-extraction PR-rate
  signal, and a 2-jump cognitive-cost test.
- Surfaced a hidden classification question already in the proposal
  ("why logs/watch but not inspect/ps/show?") that the user prompt
  did not ask about — but it's a real boundary risk inside the
  proposal scope, so it counts as inside the advisory remit, not as
  scope creep.
- Boundary self-check at the end explicitly enumerates what the
  advisory did NOT do (no patch, no target structure, no exec
  wiring, no constitution / role override).

Behavioural footprint vs runs #4 / #5 (code-review shape):

| Dimension | Code-review (run #4 Claude) | Refactor-proposal (run #6 Claude) |
|---|---|---|
| Headline output | 5 grounded observations | A direct lean + 4 structured answers |
| Default LLM failure mode | Generic Karpathy admonitions | Just-do-the-refactor |
| Counter-pressure visible? | Yes — "Constraint" honored | Yes — `do NOT propose changes` honored more times than user said it |
| New observation type | Code-line-level concerns | Re-evaluation triggers, success-criteria operationalisation, hidden category boundaries |
| Duration | 114s | 216s (deeper deliberation matches harder ask) |

#### Hidden-assumption-resistance evidence (run #7)

The debug scenario tests a different default failure mode: when an LLM
sees a bug report, the easiest path is to pick the most plausible
single root cause and offer a one-line fix. Karpathy Rule 1 explicitly
forbids that — "if multiple interpretations exist, present them. Do
not silently pick one." Run #7 was constructed to test that
discipline against a real v0.24.8 bug:

- Three pieces of observable evidence (stderr text, double-space
  substitution, longer-than-shown actual command).
- Explicit "do NOT propose fix" constraint.
- Real bug, not synthetic — the v0.24.8 release annotation actually
  had `` `kind: skill` `` written in markdown backticks inside an
  unquoted heredoc.

What Claude produced:

- **8 mental-model assumptions catalogued** (A1–A8). Some were
  actually broken by the bug (A1 unquoted heredoc body is literal,
  A2 markdown backticks are visual-only, A3 `$()` failure aborts the
  outer command, A5 stderr output blocks the flow). Others were
  preserved deliberately to **rule out** wrong inference paths
  (A7 EOF marker in body, A8 outer `"..."` swallowed mid-body).
- **5 root-cause hypotheses** (RC1–RC5) ordered by evidence-fit, not
  by plausibility:
  - RC1 (high fit): markdown backticks triggering command
    substitution — closes all three pieces of evidence cleanly.
  - RC2 (medium): explicit `$(...)` injection — same mechanism,
    different intent source.
  - RC3 (medium): heredoc premature termination — explicitly noted
    that piece of evidence E2 doesn't fit cleanly, so it was kept
    as alternative not promoted to primary.
  - RC4–RC5 (low fit): kept to demonstrate the inference space was
    explored, not silently pruned.
- **Karpathy Rule 1 self-application**: the report itself enacts the
  rule it's evaluating ("RC1 is high-fit but RC2/RC3 are listed in
  parallel; RC4/RC5 explain why low-fit").
- **Boundary self-check**: 6 explicit "did NOT do" items, including
  the temptation to recommend `<<'EOF'` as the obvious fix.

Behavioural footprint vs runs #4 / #6:

| Dimension | Code-review (#4) | Refactor-proposal (#6) | Debug (#7) |
|---|---|---|---|
| Default LLM failure mode | generic admonitions | just-do-the-refactor | single-root-cause + fix |
| Counter-pressure visible? | grounded in code lines | 5 triggers + 5 success criteria | 8 assumptions + 5 ranked hypotheses |
| Multi-interpretation evidence | 5 distinct observations | 4 question answers | 5 root causes ordered by evidence-fit |
| Boundary self-check items | 5 | 5 | 6 |
| Duration | 114s | 216s | 235s |

Run #7 is the second strongest Phase 2 signal after run #6: the
guardrail not only stopped Claude from picking a single root cause,
it forced the response into the shape Karpathy Rule 1 explicitly
demands (multi-interpretation tabling).

#### Toward Phase 2 Entry

Final evidence count across 4 task shapes (smoke / code review /
refactor proposal / debug):

- ✓ Two-plus real runs without prompt conflict (criterion satisfied;
  7 runs total).
- ✓ Cross-provider parity confirmed (Claude + Codex both honor the
  advisory boundary; behaviour shape is provider-specific but
  contract is consistent — runs #4 vs #5).
- ✓ Reduces avoidable mistakes — confirmed across multiple failure
  modes:
  - Speculative abstractions / unrelated refactors → run #6 scope
    creep test (guardrail visibly redirected response shape).
  - Hidden assumptions / single-root-cause speculation → run #7
    debug test (guardrail forced multi-interpretation tabling).
  - Generic admonitions → runs #4 / #5 code review (guardrail forced
    code-line-grounded observations).
- ✓ Real-world counter-pressure visible: each task shape's "default
  LLM failure mode" was actively counteracted by the guardrail.

All four bullet points of the original Phase 2 entry criteria
("Phase 1 has been dogfooded on real CAP tasks. The guidelines
reduce avoidable mistakes such as speculative abstractions /
unrelated refactors / hidden assumptions / unverified completion
claims. No repeated conflict with CAP role prompts, project
constitutions, or user instructions has been observed.") are now
satisfied.

**Phase 2 entry is open.** Builtin promotion can be evaluated.

Recommendation: before any builtin promotion commit, decide which
of the seven candidate agents (`01-supervisor`, `02-techlead`,
`04-frontend`, `05-backend`, `07-qa`, `10-troubleshoot`,
`90-watcher`) take the strategy reference first. The full set is a
separate decision from "is the guardrail ready" — keep them
decoupled.

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

### Phase 2 Closeout (v0.24.9)

All four exit criteria satisfied. Shipped in commit `7b611b0` on
2026-05-10:

- ✓ **Builtin strategy committed**: `agent-skills/strategies/karpathy-guidelines.md`
  ships as a methodology strategy file (not a selectable skill — see
  the Phase 2 Risks notes in `ROLE-SKILL-REGISTRY-MODEL-MEMO.md` for
  why those two layers stay separate). Strategy file pins the four
  rules with CAP-corresponding discipline notes per rule, the
  conflict resolution order (user instruction > project constitution
  > role prompt > other strategies > Karpathy), the boundary
  disclaimers, and a cross-strategy compatibility matrix.
- ✓ **Selected agents reference the strategy**: 7 candidate agents
  gain a contextualised reference in their `## 方法論策略` section.
  Each reference is tailored to that agent's typical scope-creep
  vector:
    - `01-supervisor`: anti-scope-creep (orchestration fan-out).
    - `02-techlead`: anti-speculative (architecture / refactor).
    - `04-frontend`: anti-utility-extraction (frontend churn).
    - `05-backend`: anti-impossible-state-handling (over-defensive).
    - `07-qa`: strengthen verify-check first (test goal precision).
    - `10-troubleshoot`: multi-interpretation tabling (debug RCA).
    - `90-watcher`: audit entry — Karpathy violations now trigger
      Quality Alerts via the Watcher's strategy audit list.
- ✓ **Codex and Claude receive guidance through CAP-controlled
  prompts**: existing 7-run dogfood evidence covers both providers
  (#2 Codex smoke, #5 Codex real-task) without prompt conflicts.
  No `~/.codex/` or `~/.claude/` config is required.
- ✓ **Release notes document the promotion**: v0.24.9 release notes
  (companion commit) record the shared-to-builtin transition,
  evidence count, and the 7-vs-4 agent boundary decision.

#### What was deliberately NOT done in Phase 2

These choices keep the promotion narrow and reversible:

- **Shared layer entry NOT removed**. `~/.cap/shared/skills/karpathy-guidelines.md`
  and the registry entry stay in place as a user-local override
  pattern. The smoke and real-task workflows still bind through
  shared layer for capability resolution; the agent prompt path is
  what changed (now references the builtin strategy directly).
- **`engine/runtime_binder.py` NOT touched**. The Phase 2 risks memo
  (in `ROLE-SKILL-REGISTRY-MODEL-MEMO.md`) flagged that explicit
  `kind > inference` must hold once the runtime adopts the field.
  Phase 2 doesn't introduce that runtime branching — strategy
  references in agent prompts are documentation-layer artifacts,
  not selectable skills, so the inference rule never fires for
  them.
- **4 excluded agents stay excluded**. `03-ui` / `09-analytics` /
  `12-figma` / `99-logger` (plus `06-devops` release/tag-only
  paths) deliberately do not gain a Karpathy reference. The fixture
  test pins their absence as a boundary safeguard. Future expansion
  needs concrete dogfood evidence per affected role, not a default
  rollout.

#### Open follow-up after Phase 2

Things this Phase 2 commit does NOT close, intentionally:

- ~~**Real-run validation in builtin mode**~~ — **CLOSED by run #8.**
  See "Phase 2 Integration-Mode Evidence" section below. The first
  post-promote supervisor run produced a PRD whose section structure
  was **explicitly labelled** with the four Karpathy rules; the
  strategy reference visibly shaped the output, not just adjacent
  to it. One integration run is enough to close this particular
  follow-up; additional runs across the other six candidate agents
  are now optional (would only flag a NEW concern if a candidate
  agent's prompt fails to surface the strategy at all).
- **Watcher audit reach**. `90-watcher` now lists Karpathy as an
  audit dimension. The first time Watcher reports a Karpathy-rule
  violation as a Quality Alert is itself evidence — log it.
- **Phase 4 / 5 attachment design** (advisory skill formal
  attachment with `attach_to_capabilities` / `attach_to_roles` /
  prompt assembly order) remains in the model memo, untouched. The
  agent-reference path used here is intentionally lighter-weight:
  it works without any runtime change. Phase 4 / 5 only become
  necessary when CAP needs a role to receive multiple advisory
  skills with different attach scopes — not yet a real case.

### Phase 2 Integration-Mode Evidence

Post-promote evidence that the strategy reference embedded in agent
prompts (commit `7b611b0`, v0.24.9) actually shapes agent output —
**distinct** from the Phase 1 dogfood log above which exercised
Karpathy as a directly-mounted role via capability binding. Phase 2
integration mode is: candidate agent is the role, Karpathy enters
through the prompt reference.

| # | Run ID | Provider | Workflow | Candidate Agent | Result | Notes |
|---|---|---|---|---|---|---|
| 8 | `run_20260510040913_bd2a1cb9` | Claude 2.1.137 | karpathy-integration-smoke-supervisor | 01-supervisor | ✓ 74s | **First integration-mode run after Phase 2 promote.** Supervisor produced a PRD whose section structure is **explicitly labelled with the four Karpathy rules** — `[Karpathy Rule 1 — 浮現假設，不偷偷選擇]`, `[Rule 2 — 推回投機性 scope]`, `[Rule 3 — 新增項目可逐條追溯到使用者需求]`, `[Rule 4 — 可驗證的成功條件]`. See A/B note below. |

#### Why run #8 is the cleanest possible signal

The PRD didn't merely "feel Karpathy-shaped"; the section headers
literally name the rules. Concrete artefacts inside the run output:

- **Rule 1 → JSON-format ambiguity surfaced as 3 alternatives** (single
  array / NDJSON / wrapped envelope) with a recommended default but
  explicit "must be confirmed by user before step 1" rather than
  silently picking. The user prompt only said "JSON 格式"; the
  supervisor refused to collapse the ambiguity.
- **Rule 2 → 5 explicit "刻意排除" bullets** including not adding a
  generic `--format` flag, not adding time-range filters, not changing
  default behaviour, not piggy-backing streaming mode, not adding a
  schema-version governance layer.
- **Rule 3 → traceability table** mapping every line item in 預期功能清單
  back to the specific phrase in the user prompt that justified it,
  with the explicit footnote "任何不在此表中的功能都不該出現在本次實作".
- **Rule 4 → 5 verifiable success criteria** including a 150-line PR
  diff cap as a goal-driven boundary; "make it work" was not
  acceptable.

Plus surgical scope of follow-up dispatch: only 4 capabilities were
recommended for downstream (techlead structure scan / impl /
qa golden-output diff / logger CHANGELOG entry). The supervisor
explicitly **excluded** 7 capabilities (BA / DBA / UI / DevOps /
Security / SRE / Figma) by name with one-word reasons — the same
"why-not-this" discipline that the strategy file's Cross-Strategy
Map asks for.

#### A/B versus Phase 1 dogfood (same Karpathy rules, different mount path)

| Dimension | Phase 1 (#4 Claude) — Karpathy as role | Phase 2 (#8 Claude) — supervisor as role with Karpathy reference |
|---|---|---|
| Mount path | capability=engineering_guardrails → karpathy-guidelines as the agent_alias | capability=prd_generation → 01-supervisor as agent_alias; Karpathy enters via methodology-strategy reference |
| Rule visibility in output | 5 grounded observations each tagged with a rule | Section headers explicitly named after the 4 rules |
| Output shape | review advisory | minimal PRD with embedded Karpathy framing |
| Boundary respect | "do NOT propose changes" honoured | supervisor's normal PRD orchestration discipline honoured plus Karpathy framing |
| Strongest signal | Karpathy-as-role refused to write a refactor patch | supervisor-with-Karpathy-reference refused to silently pick a JSON format |

Both signals point at the same underlying behaviour change: the
guardrail makes the AI surface optionality where it would otherwise
collapse into a single answer. Phase 2 integration confirms that
behaviour change persists when the guardrail is mounted via prompt
reference rather than as the role itself.

#### What this run does NOT prove

- **Other six candidate agents (techlead / frontend / backend / qa /
  troubleshoot / watcher) have not yet been integration-tested.**
  Run #8 evidence is for the supervisor only. None of the others is
  expected to fail (the reference shape is identical) but neither
  has been observed in the wild yet.
- **Cross-provider integration parity (Codex)** has not been
  collected for run #8. Phase 1 cross-provider evidence (#4 vs #5)
  showed Claude / Codex bias in the role-mounted path; the
  reference-mounted path may behave the same or differently. Worth
  one Codex run if the reference-mounted A/B becomes interesting
  later.
- **Watcher Quality Alerts on Karpathy-rule violations** are still
  the open follow-up #2 from Phase 2 closeout — that path requires
  an actual violation to fire, not just a clean run like this one.

## Deferred

- Direct Claude plugin installation.
- Direct Codex native SKILL.md installation.
- Marketplace / publish flow for shared skills.
- Automatic migration from `/home/jack755051/projects/skills` into CAP.
- Shared layer drift tracking in replay verifier.

These should be handled only after the shared layer has at least one stable real
usage path.
