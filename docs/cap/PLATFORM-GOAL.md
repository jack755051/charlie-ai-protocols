# CAP Platform Goal

> Status: active goal statement.
> Primary boundary: [CAP-POSITIONING.md](CAP-POSITIONING.md).

## Goal

CAP exists to make local AI CLI work **governed, observable, and
repeatable**.

It does not exist to replace Claude Code, Codex, or any other provider
CLI as the fastest way to write code. For small one-off coding tasks,
direct provider use is expected to be faster and simpler.

CAP should be used when a repo or task needs:

- project identity and constitution boundaries;
- provider readiness checks before AI work;
- workflow binding and capability gates;
- deterministic validation;
- run archives and artifact indexes;
- session analysis for time, prompt size, token availability, and
  failure hotspots.

## Product Posture

The platform posture is:

```text
CAP = AI CLI governance layer + observability ledger + deterministic gates
```

Not:

```text
CAP = universal AI coding agent
CAP = provider replacement
CAP = component generator platform
```

This distinction matters. CAP should not add abstraction unless it
reduces wasted runs, hidden failures, or untraceable provider work.

## Runtime Model

The desired lifecycle is intentionally narrow:

```text
resolve project
  -> load constitution / policy
  -> bind workflow
  -> preflight provider only when AI work is needed
  -> execute deterministic steps first
  -> execute AI steps only for ambiguity / judgement / repair
  -> validate artifacts
  -> archive logs, sessions, and results
  -> analyze run hotspots
```

The platform rule is:

```text
deterministic-first, AI-on-ambiguity, halt-on-risk
```

## Core Ownership

CAP owns:

- repo identity and CAP storage layout;
- project constitution governance;
- workflow binding and capability policy;
- provider readiness boundary;
- run observability and session ledger;
- deterministic workflow execution;
- artifact validation and result reporting.

CAP does not own:

- provider login state;
- provider credentials;
- provider billing or quota policy;
- direct coding performance;
- stack-specific code generation as platform core;
- hidden provider-to-provider routing.

## Current Priority

The active platform priority is provider readiness and workflow
preflight:

1. `cap provider doctor` must explain whether the selected provider is
   visible and what the readiness state is.
2. AI-backed workflows must fail fast before the first provider call
   when the provider is missing or clearly unusable.
3. Read-only, dry-run, bind, compile, and shell-only flows must remain
   usable without provider auth.

After this, CAP should refine observability and remove documentation /
workflow bloat before adding new profile features.

## Frozen Until Reopened

The following are not current platform goals:

- expanding `component-fast`;
- adding new component templates;
- adding more product/spec/implementation pipeline variants;
- broad multi-provider dogfood runs;
- marketplace / publish flows;
- complex background or remote orchestration.

They may remain in the repository as historical work, but they are not
the active direction.
