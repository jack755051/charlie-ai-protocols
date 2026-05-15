# CAP Cost And Waste Reduction Memo

> Status: reframed on 2026-05-15.
> Product boundary: [CAP-POSITIONING.md](../../docs/cap/CAP-POSITIONING.md).

## Reframe

The goal is not generic "token saving." The goal is **waste
reduction**.

Waste means:

- starting a workflow when the provider is missing or not ready;
- discovering auth failure only after setup work has run;
- using a full product pipeline for a small direct coding task;
- asking AI to re-derive deterministic structure;
- retrying because the run output is not inspectable;
- hiding provider choice or cost behind another layer.

CAP should reduce those losses. It should not claim that it will beat
direct Claude Code / Codex for small implementation tasks.

## Evidence

The `component-feedback-widget` dogfood showed:

- direct component work through full CAP pipelines was too slow;
- a small component paid product-scale workflow cost;
- provider quota pressure was high;
- correctness and observability improved, but operator value did not
  clearly beat direct provider use.

That evidence changes the product direction:

```text
Stop expanding component generation.
Keep provider readiness, preflight, deterministic gates, and run analysis.
```

## Active Waste-Reduction Tracks

| Track | Status | Why it remains core |
|---|---|---|
| Provider readiness | Active | Prevents AI-backed work from starting when no usable provider exists. |
| Workflow preflight | Active | Moves failure before the first provider call. |
| Run observability | Active | Makes time, prompt bytes, token availability, and failure hotspots visible. |
| Deterministic gates | Active | Keeps checks, schema validation, and smoke tests out of AI inference. |

## Frozen Tracks

| Track | Status | Reason |
|---|---|---|
| Component fast path | Runtime removed; records retained | Did not prove better real-world outcome than direct provider use. |
| Product-strict dogfood as default | Frozen | Too expensive for ordinary regression and component testing. |
| More templates / stack catalogs | Frozen | Expands CAP into a generator instead of a governance layer. |
| Cost-aware provider routing | Deferred | Requires trustworthy provider metadata and token telemetry first. |

## Measurement Rule

Future CAP work should be judged by:

- fewer bad starts;
- earlier halt points;
- clearer remediation;
- fewer repeated runs;
- clearer session analysis;
- less AI use for deterministic work.

It should not be judged by whether CAP can generate a small component
faster than a direct Claude Code / Codex session.
