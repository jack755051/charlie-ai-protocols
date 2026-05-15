# CAP Positioning

> Status: active product boundary.
> Updated: 2026-05-15.
>
> This document supersedes older wording that described CAP as a
> general-purpose multi-agent development runner.

## Position

CAP is an **AI CLI governance and observability layer**.

CAP is not a replacement for Claude Code, Codex, or any other provider
CLI. It should not try to beat a provider on direct coding speed,
single-prompt convenience, or one-off component generation.

CAP is useful when the operator needs:

- provider readiness before spending quota;
- repo identity and constitution boundaries;
- repeatable workflow gates;
- run logs, artifacts, and session analysis;
- deterministic checks before or after AI work;
- explicit records of why a run halted.

For small one-off implementation tasks, use Claude Code or Codex
directly. CAP may be used beside them for checks and records, but it
should not be the default execution path unless governance or
repeatability matters.

## Non-Goals

CAP does not aim to:

- become a better coding agent than Claude Code or Codex;
- hide provider choice behind another provider;
- parse arbitrary prose into runtime contracts inside workflow core;
- turn every feature request into a multi-agent pipeline;
- ship stack-specific component generators as platform core;
- require provider auth for read-only or shell-only work.

## Core Surfaces

The platform keeps three core surfaces.

### 1. Provider Readiness

CAP owns readiness, not login.

CAP should discover whether a selected provider is visible and safe to
use before the first AI-backed step. Readiness probes must be:

- no-token;
- non-interactive;
- non-mutating.

Provider account state, login flows, credentials, and billing remain
owned by the provider CLI or API tooling.

### 2. Run Observability

CAP should make AI work inspectable after the fact:

- run id;
- workflow id;
- provider and model metadata when available;
- per-step duration;
- prompt and output byte proxies;
- token usage when providers expose it;
- failed step and blocked reason;
- artifact locations.

This is the main difference between running a provider directly and
running a CAP-governed workflow.

### 3. Deterministic Workflow Support

CAP should prefer deterministic work before AI work:

- shell checks;
- schema validation;
- repo identity checks;
- audit scripts;
- smoke tests;
- artifact indexing;
- result rendering.

AI steps should be reserved for ambiguity, judgement, review, or repair.

## Frozen Surfaces

The following surfaces are frozen until the core surfaces above are
boring and proven:

- new component-fast features;
- new stack-specific templates;
- new broad workflow profiles;
- new multi-agent decomposition flows;
- new provider comparison workflows;
- new marketplace / publishing flows.

Frozen does not mean deleted. It means no new feature work unless a
separate decision document reopens the surface with evidence.

## Component-Fast Status

`component-fast` is historical evidence, not CAP core.

It proved that deterministic generation can reduce repeated AI work in
principle, but it has not yet proven better real-world outcome, lower
operator friction, or lower total cost than direct Claude Code / Codex
for component creation.

Therefore:

- its runtime workflow, templates, schema, scripts, tests, and capability
  mappings have been removed from active CAP core;
- do not use component-fast as the default CAP success metric;
- keep development records as historical evidence;
- focus platform work on provider readiness and observability first.

## Practical Rule

Before adding a CAP feature, ask:

```text
Does this reduce wrong starts, hidden failures, repeated runs, or
unobservable AI work?
```

If the answer is no, it likely belongs outside CAP core.
