# CAP Implementation Roadmap

> Status: reset on 2026-05-15.
> Product boundary: [CAP-POSITIONING.md](../../docs/cap/CAP-POSITIONING.md).
>
> Older phase narratives treated CAP as a full local AI workflow runtime
> that would compile prompts into multi-agent execution plans. That path
> produced useful runtime pieces, but it also made the product too large.
> This roadmap now tracks only the narrowed platform direction.

## Active Direction

CAP should become a small governance layer around existing AI provider
CLIs:

```text
provider readiness
  -> workflow preflight
  -> deterministic gates
  -> run observability
  -> concise evidence records
```

The platform should not optimize for "CAP writes code faster than Claude
Code / Codex." It should optimize for "CAP prevents bad starts and makes
AI runs inspectable."

## Current Priorities

| Priority | Track | Outcome |
|---|---|---|
| P0 | Provider readiness contract | Readiness states and JSON schema are stable. |
| P1 | Provider doctor surface | `cap provider doctor` reports machine-readable readiness without tokens, login, or mutation. |
| P2 | Workflow preflight | AI-backed workflows halt before provider execution when readiness is blocked. |
| P3 | First-run UX | README / install / setup tell the user to verify provider readiness before AI work. |
| P4 | Observability cleanup | `cap session analyze`, workflow inspect, and result reports answer "where did time / token proxy / failure go?" quickly. |
| P5 | Documentation reduction | Old generator / broad multi-agent / profile expansion docs are frozen, archived, or deleted. |

## Done Baseline

The repository already contains useful platform substrate:

- project identity and CAP storage;
- project constitution and binding policy;
- capability registry;
- workflow plan / bind / run surfaces;
- session ledger and run reports;
- run logs / inspect / watch / analyze;
- provider isolation for native `claude` / `codex`;
- provider readiness schema and doctor surface;
- workflow preflight helper and tests.

These pieces remain valuable only if the product stays narrow.

## Frozen Tracks

The following tracks are frozen. They should not receive new feature
work until provider readiness, preflight, and observability are proven in
normal use:

- `component-fast` expansion;
- component template catalogs;
- new stack profiles;
- full product/spec/implementation pipeline expansion;
- broad provider parity dogfood;
- publish / marketplace work;
- background / detached runtime expansion;
- automatic prompt-to-structured-args wrappers.

## What To Delete Or Archive Later

Do not delete code in the same commit as this roadmap reset. Use small
follow-up cleanup commits. Candidate cleanup categories:

- docs that duplicate this roadmap;
- old dogfood runbooks that are not used as evidence;
- profile-specific docs that present component generation as CAP core;
- stale phase lists that no longer match product direction.

Historical records under `development-records/` may stay as evidence,
but should not be treated as active roadmap.

## Decision Gate For Any New Feature

A new CAP feature is allowed only if it answers yes to at least one:

- Does it prevent an AI-backed run from starting in a bad state?
- Does it make an AI run easier to inspect after failure?
- Does it move deterministic work out of AI steps?
- Does it reduce duplicated workflow/runtime logic?
- Does it clarify provider / repo / capability boundaries?

If not, the work belongs outside CAP core.
