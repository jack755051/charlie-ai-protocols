# Provider Readiness Tasks

> Status: active task list.
> Scope: CAP platform readiness for AI provider CLIs and API-backed providers.
> Parent memo: `docs/cap/PROVIDER-ONBOARDING-MEMO.md`.

## Purpose

CAP is not useful as an AI task runner when no provider is available.
Provider authentication and account lifecycle belong to Claude Code,
Codex, DeepSeek, OpenAI, or local model tooling. Provider readiness
belongs to CAP.

This task list keeps that boundary explicit:

- CAP must discover provider availability.
- CAP must fail fast before AI-backed work when the selected provider is
  missing or clearly not ready.
- CAP must not spend tokens just to test readiness.
- CAP must not mutate provider login state.
- Shell-only / deterministic workflows must not require provider auth.

## P0 — Boundary And Contract

- [x] Write provider-readiness boundary ADR.
  - Decision: CAP does not own provider login, but owns provider readiness
    checks and workflow preflight.
  - Decision: provider-to-provider proxying is not the default cost-control
    strategy; CAP routes providers directly.
  - Landed in `development-records/decisions/cap-provider-readiness-boundary-2026-05-15.md`
    (commit `738d1ae`). Five rulings + three probe rules + six-state
    enum + three-layer architecture all ratified there.
- [x] Define provider readiness states.
  - `provider_missing`
  - `installed`
  - `auth_unknown`
  - `auth_required`
  - `auth_ok`
  - `error`
  - Locked as an enum in `schemas/provider-readiness.schema.yaml`
    `properties.providers.items.properties.state.enum` and exercised
    by `tests/scripts/test-provider-readiness-schema.sh` Cases 2 + 10.
- [x] Define provider readiness JSON shape.
  - provider name
  - cli path or API key source
  - version when available
  - auth status
  - readiness status
  - remediation command
  - probe source
  - probe safety level
  - All shipped as `schemas/provider-readiness.schema.yaml` v1 with
    `additionalProperties: false` at both top-level and provider-item
    level so future field drift fails schema validation.
- [x] Define no-token probe rule.
  - Readiness probes must not send a prompt that consumes model quota.
  - Interactive login probes are disallowed in doctor/preflight.
  - Encoded as `probe_policy.{no_token,no_interactive,no_mutation}`
    locked-true booleans in the schema. A report that does not assert
    all three fails validation.
- [x] Define command boundary.
  - Read-only CAP commands never require provider auth.
  - Shell-only workflows never require provider auth.
  - AI-backed workflows preflight the selected provider before the first AI step.
  - Defined in ADR-3 §5 ("Behavior by workflow class"). Schema
    validation is the structural part; CLI / preflight wiring lives in
    P1 + P2.

## P1 — Doctor Surface

- [x] Extend `cap provider doctor`.
  - Show CLI availability and auth readiness separately.
  - Add or preserve `--json`.
  - Keep the command read-only.
  - `--json` output now conforms to `schemas/provider-readiness.schema.yaml`;
    state column reports `provider_missing` (CLI absent) or `auth_unknown`
    (CLI present, no safe no-token auth probe in v1). Text mode unchanged.
- [~] Add provider-specific remediation text.
  - Claude: `cap claude` or `claude`
  - Codex: `cap codex`, `codex`, or `OPENAI_API_KEY`
  - DeepSeek: `DEEPSEEK_API_KEY` when a DeepSeek adapter exists
  - Local model: local server / binary readiness when supported
  - Partial: Claude + Codex CLI providers carry remediation strings
    in v1; DeepSeek API-key adapter and local-model adapter still
    have no doctor surface — out of scope for P1, queued for P3 / P4.
- [x] Add deterministic tests for doctor output.
  - provider missing
  - provider installed / auth unknown
  - default provider override
  - JSON shape
  - no login invocation
  - Lives in `tests/scripts/test-cap-provider-doctor.sh`: 11 cases /
    33 assertions covering both branches (auth_unknown via the real
    PATH, provider_missing via a stripped PATH sandbox) plus
    structural assertions for `probe_policy` locked-true,
    additionalProperties=false, and remediation non-emptiness.

## P2 — Workflow Preflight

- [x] Add shared provider readiness helper.
  - Use the same logic from `cap provider doctor` and workflow preflight.
  - Keep probes non-interactive and no-token.
  - Shipped as `scripts/cap-provider-preflight.sh`, dot-sourced by
    `cap-workflow.sh`. Helper performs zero IO itself — it only
    parses the doctor JSON the caller provides. Reuses the same
    schema (`schemas/provider-readiness.schema.yaml`) that
    `cap provider doctor --json` emits.
- [x] Wire preflight before AI-backed workflow execution.
  - `cap workflow run --cli claude ...`
  - `cap workflow run --cli codex ...`
  - future API-backed providers
  - Wired in `scripts/cap-workflow.sh` between the binding-degraded
    check and the DETACH / exec path (after line ~948). Halts with
    exit 4 when state ∈ {provider_missing, auth_required, error,
    unknown_cli, parse_error}; warns + proceeds when state =
    auth_unknown; silent when state = auth_ok. Halt block follows
    the same WORKFLOW PREFLIGHT BLOCKED — <name> format as the
    binding-blocked block so operator UX stays consistent.
- [x] Ensure shell-only workflows bypass provider readiness.
  - `workflow_has_ai_step` guard inspects `binding.steps[].executor`
    + `fallback.executor`; preflight only runs when at least one
    step (or its fallback) declares `executor: ai`. The CAP default
    for a missing executor is "ai" so legacy plans are gated
    correctly.
- [x] Ensure dry-run / bind / compile do not require provider auth.
  - `cap workflow run --dry-run` exits at the plan-print branch in
    `cap-workflow.sh` (~line 893) BEFORE reaching the preflight.
    `cap workflow bind` lives in a separate `bind` case and never
    enters the run flow. `cap workflow compile` is read-only and
    does not touch the run flow. Regression covered by Cases 15
    and 16 in `tests/scripts/test-workflow-provider-preflight.sh`.
- [x] Add tests.
  - AI workflow + missing provider fails before provider spawn.
  - Shell-only workflow proceeds without provider.
  - Dry-run proceeds without provider.
  - Error message includes remediation.
  - Lives in `tests/scripts/test-workflow-provider-preflight.sh`:
    19 cases / 60 assertions covering helper unit branches
    (workflow_has_ai_step, provider_preflight_check, render_halt,
    render_warn), structural wiring checks (helper sourced, halt
    exits 4, override env hook present), and live-dispatch
    integration with `CAP_PROVIDER_DOCTOR_JSON_OVERRIDE` so the
    test never touches the host's installed Claude / Codex
    binaries and spends zero tokens.

## P3 — First-Run UX

- [ ] Update install/setup completion text.
  - Tell the user to run `cap provider doctor`.
  - Do not imply AI workflows are ready immediately after install.
- [ ] Update README first-use path.
  - install
  - source shell rc
  - provider doctor
  - provider native login via `cap claude` / `cap codex`
  - project init
  - workflow run
- [ ] Add `cap doctor` aggregation if/when a top-level doctor exists.
  - CAP install state
  - agent-skills sync state
  - provider readiness
  - project readiness

## P4 — Provider Routing And Cost Control

- [ ] Define provider routing policy.
  - direct CAP-to-provider routing
  - no hidden provider-to-provider proxying by default
  - explicit second-opinion / model-comparison workflows only when traced
- [ ] Add provider capability metadata.
  - supports repo edit
  - supports non-interactive prompt
  - supports usage reporting
  - supports write-dir / sandbox flags
  - supports API key auth
- [ ] Add cost-aware provider selection later.
  - Not a P0 readiness requirement.
  - Requires reliable usage telemetry and provider metadata.

## First Slice Recommendation

Start with **P0-1: provider readiness boundary ADR**.

Recommended file:

```text
development-records/decisions/cap-provider-readiness-boundary-2026-05-15.md
```

Recommended decision:

```text
CAP does not own provider login.
CAP owns provider readiness.
AI-backed workflow execution must fail fast when the selected provider is missing
or clearly not ready.
Read-only and shell-only CAP commands must not require provider auth.
Provider-to-provider proxying is not the default cost-control strategy; CAP routes
providers directly.
```

Why this comes first:

- It prevents readiness work from becoming a login manager.
- It protects deterministic CAP workflows from unnecessary auth requirements.
- It gives later implementation slices a stable boundary.
- It addresses the core product risk: CAP without an available agent CLI cannot
  complete AI-backed tasks.

Recommended commit subject:

```text
docs(decision): define provider readiness boundary
```

After that ADR lands, implement the first code slice:

```text
feat(provider): report auth readiness in provider doctor
```

That implementation should stay read-only and no-token.
