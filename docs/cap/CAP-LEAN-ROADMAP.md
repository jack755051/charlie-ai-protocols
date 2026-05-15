# CAP Lean Roadmap

> Status: active restructuring task list.
> Positioning SSOT: [CAP-POSITIONING.md](CAP-POSITIONING.md).
>
> Guiding decision:
>
> ```text
> CAP should not be the AI entry point.
> CAP should be the governance and record layer before and after AI use.
> ```

## Target Architecture

CAP keeps the existing three-layer architecture, but narrows each
layer's responsibility.

### 1. Repo Execution Layer

The repo is where real work happens.

Owns:

- project source code;
- tests and build scripts;
- `.cap.project.yaml`;
- `.cap.constitution.yaml`;
- repo-local workflow / policy sources when needed;
- direct Claude Code / Codex edits.

Rule:

```text
The repo remains the source of truth.
CAP must not turn .cap storage into a second product repo.
```

### 2. CAP Platform Layer

CAP is the governance and observability platform around provider CLIs.

Owns:

- CLI surface;
- provider readiness;
- workflow bind / preflight;
- schema validation;
- capability / constitution governance;
- deterministic gates;
- run observability;
- harness verification.

Rule:

```text
CAP checks, gates, records, and analyzes.
CAP does not replace Claude Code / Codex as the default coding interface.
```

### 3. CAP Storage Layer

`~/.cap/projects/<project_id>/` stores runtime evidence.

Owns:

- runs;
- bindings;
- reports;
- sessions;
- traces;
- logs;
- cache.

Rule:

```text
.cap storage is a ledger, not a source repository.
```

## P0 — Positioning And Documentation Lock

Goal: remove product ambiguity before adding more code.

- [x] Rewrite README around governance / observability.
- [x] Add `docs/cap/CAP-POSITIONING.md`.
- [x] Reset `docs/cap/PLATFORM-GOAL.md`.
- [x] Reset `docs/cap/IMPLEMENTATION-ROADMAP.md`.
- [x] Reframe cost work as waste reduction.
- [x] Mark component-fast as historical evidence.
- [x] Remove component-fast runtime surface.
- [ ] Add this lean roadmap as the active restructuring task list.
- [ ] Update docs index to point here as the current roadmap.
- [ ] Add an architecture note: CAP sits beside provider CLIs, not in
  front of them.

Exit criteria:

- New readers can understand CAP without reading dogfood history.
- Docs no longer imply CAP is a component generator or general AI coding
  agent.

## P1 — Provider Readiness And Preflight

Goal: CAP is useful before AI work starts.

- [x] Provider readiness boundary ADR.
- [x] `schemas/provider-readiness.schema.yaml`.
- [x] `cap provider doctor --json` readiness output.
- [x] Shared provider preflight helper.
- [x] Workflow preflight before AI-backed execution.
- [x] Shell-only / dry-run / bind / compile bypass provider auth.
- [ ] Update install/setup completion text to recommend
  `cap provider doctor`.
- [ ] Add top-level first-use checklist:

```bash
cap provider doctor
cap project doctor
cap workflow bind <workflow>
```

Exit criteria:

- Missing provider / auth-required cases halt before the first AI call.
- Read-only and deterministic workflows remain usable with no provider.

## P2 — Skill Model Reclassification

Goal: skills become provider-facing guidance, not CAP's automatic agent
army.

- [ ] Update `agent-skills/README.md` with usage tiers.
- [ ] Define tiers:
  - core governance;
  - execution advisory;
  - deferred / optional.
- [ ] Mark governance skills as CAP-core aligned:
  - supervisor;
  - devops;
  - qa;
  - security;
  - watcher;
  - logger;
  - troubleshoot.
- [ ] Mark execution skills as advisory:
  - frontend;
  - backend;
  - ui;
  - dba;
  - techlead;
  - ba.
- [ ] Mark integration / expansion skills as deferred:
  - figma;
  - analytics;
  - external guardrail packs.
- [ ] Update docs to say:

```text
Skills are prompt / policy material that providers may read.
They are not automatically launched as a CAP default team.
```

Exit criteria:

- CAP docs no longer imply a default multi-agent development crew.
- Direct Claude Code / Codex usage with referenced skills is the normal
  execution path.

## P3 — Workflow Model Reclassification

Goal: workflows become governance / check / record flows by default.

- [ ] Update `workflows/README.md` with workflow tiers.
- [ ] Define tiers:
  - core governance workflows;
  - read-only / deterministic workflows;
  - legacy AI-heavy workflows;
  - frozen / historical workflows.
- [ ] Keep as core:
  - `version-control`;
  - `workflow-smoke-test`;
  - `project-constitution`;
  - `project-constitution-reconcile`;
  - provider readiness / preflight tests;
  - inspect / analyze / archive flows.
- [ ] Mark as legacy / not default:
  - `project-spec-pipeline`;
  - `project-implementation-pipeline`;
  - `project-qa-pipeline`;
  - `supervisor-orchestration`.
- [ ] Remove README examples that suggest CAP is the general prompt
  execution entry.
- [ ] Ensure `cap workflow list` or adjacent docs make AI-heavy workflows
  visibly non-default.

Exit criteria:

- The default workflow story is "check, gate, record," not "generate a
  product."

## P4 — Governance Harness

Goal: prove CAP's boundaries without spending tokens.

Harness is core verification, not a product workflow.

It should validate:

- provider missing fail-fast;
- auth unknown warning;
- shell-only workflow bypass;
- constitution / capability blocking;
- schema validation failure;
- project identity collision;
- run log / result / session artifact creation;
- post-AI dirty worktree audit.

Rules:

- no real provider by default;
- no tokens by default;
- no mutation outside fixture sandboxes;
- fake provider / fake doctor JSON first;
- optional live lane only with explicit opt-in.

Target shape:

```text
tests/harness/
├── README.md
├── run-harness.sh
└── fixtures/
    ├── provider-missing/
    ├── auth-unknown/
    ├── shell-only-workflow/
    ├── blocked-constitution/
    ├── schema-validation-failure/
    └── post-ai-dirty-worktree/
```

Optional live lane:

```bash
CAP_HARNESS_LIVE=1 tests/harness/run-harness.sh
```

Exit criteria:

- CAP core boundaries can be regression-tested without Claude / Codex.
- Harness reports evidence, blocked reason, remediation, and expected
  artifacts per case.

## P5 — Post-AI Record And Audit Flow

Goal: CAP becomes useful after direct Claude Code / Codex work.

- [ ] Define a post-AI checklist:

```bash
cap project doctor
cap workflow run version-control "整理這次變更"
cap session analyze --run-id <run-id>
```

- [ ] Add or refine a `post-ai-change-audit` concept.
- [ ] Record:
  - changed files;
  - test commands and results;
  - commit intent;
  - risk notes;
  - follow-up tasks.
- [ ] Keep all post-AI flows deterministic-first.

Exit criteria:

- A developer can work directly in Claude Code / Codex, then use CAP to
  record and audit the outcome without replaying the whole task.

## P6 — Runtime Surface Reduction

Goal: make the repo match the lean positioning.

- [x] Remove component-fast runtime profile.
- [ ] Remove or clearly mark legacy AI-heavy workflows.
- [ ] Remove stale tests tied only to frozen generator paths.
- [ ] Clean profile-specific capabilities from core schemas.
- [ ] Keep active docs to a small set:
  - positioning;
  - platform goal;
  - lean roadmap;
  - provider readiness;
  - observability;
  - architecture;
  - release notes;
  - historical backlog.
- [ ] Move or mark broad design memos as deferred / historical.

Exit criteria:

- CAP core can be explained in one page.
- Active runtime surfaces match the governance / observability product
  boundary.

## Not In Scope

- Rebuilding component-fast.
- Creating a new component generator.
- Provider-to-provider hidden proxying.
- Automatic prose-to-structured runtime inference.
- Broad live dogfood that spends provider quota before harness coverage.

## Next Slice

Recommended next slice:

```text
docs(skills): classify agent skills by CAP usage tier
```

Then:

```text
docs(workflows): classify workflows by governance tier
```
