# Component Fast Path Memo

> Status: runtime removed; evidence memo retained.
> Product boundary: [CAP-POSITIONING.md](../../docs/cap/CAP-POSITIONING.md).
>
> This file is retained as historical evidence and as a possible future
> profile reference. It is not an active CAP core roadmap item.

## Current Decision

`component-fast` runtime has been removed from CAP core.

The work proved that deterministic templates, audit scripts, smoke
scripts, and compact AI review can be modeled in CAP. It did not prove
that CAP is a better default path than direct Claude Code / Codex for
creating a small component.

Therefore:

- no component-fast workflow is exposed in `schemas/workflows/`;
- no component-fast capabilities are exposed in `schemas/capabilities.yaml`;
- no component-fast templates or scripts are shipped as active runtime;
- no live dogfood retry until provider readiness and workflow preflight
  are stable;
- no claim that component-fast represents CAP core.

## What Was Removed

The active runtime surface was removed:

- `schemas/component-fast-args.schema.yaml`;
- `schemas/workflows/component-fast.yaml`;
- `templates/component-fast/feedback-widget/**`;
- `scripts/workflows/component-fast-*.sh`;
- component-fast tests;
- component-fast capability and skill mappings.

Development records for the 2026-05 dogfood sequence remain as evidence.

## Why It Froze

The component dogfood exposed a useful product lesson:

```text
CAP should reduce bad starts and unobservable runs.
CAP should not become a stack-specific generator.
```

The failed one-shot evidence run also clarified the input boundary:
runtime inputs are structured-first. Free-form prose can be handled by a
future wrapper, but workflow core must not infer structured args from
operator prose.

## Reopen Criteria

Reopen component-fast only if all are true:

- provider readiness and workflow preflight are already stable;
- a real operator task requires this profile;
- the task cannot be handled more simply by direct Claude Code / Codex;
- the profile has a structured args file at entry;
- the run can be evaluated against wall time, AI step count, prompt byte
  proxy, catalog completeness, and smoke result.

Until then, component-fast remains evidence, not direction.
