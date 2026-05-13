# CAP Cost Optimization Memo

> Source dogfood: `component-feedback-widget`, successful implementation run `run_20260513212143_defe3f1c`.
> Purpose: define the runtime cost visibility and component fast-path work required before broad live dogfood.

## Problem

The first complete `component-feedback-widget` implementation dogfood proved that CAP can now push a small Component Repo through the implementation pipeline, but the cost profile is not acceptable:

- Total implementation duration: 2665s (44m25s).
- Result: 15/15 steps completed successfully.
- Operator-observed provider pressure: Claude reached 87% of the rolling 5-hour usage limit.
- The run covered implementation only; the preceding spec pipeline took 1902s (31m42s). Spec + implementation therefore cost roughly 76 minutes before human review / verification intervention.

The current system primarily optimizes correctness, governance, traceability, and failure recovery. It does not yet optimize wall time or token usage.

## Implementation Cost Breakdown

Top implementation steps by wall time:

| Rank | Step | Capability | Duration | Share of run |
|---:|---|---|---:|---:|
| 1 | `backend` | `backend_implementation` | 619s | 23.2% |
| 2 | `frontend` | `frontend_implementation` | 553s | 20.8% |
| 3 | `devops_packaging` | `devops_delivery` | 377s | 14.1% |
| 4 | `qa_testing` | `qa_testing` | 326s | 12.2% |
| 5 | `security_audit` | `security_audit` | 272s | 10.2% |
| 6 | `impl_audit` | `code_structure_audit` | 176s | 6.6% |
| 7 | `archive` | `technical_logging` | 176s | 6.6% |
| 8 | `draft_task_constitution` | `task_constitution_planning` | 149s | 5.6% |

Interpretation:

- The top five steps consume roughly 80.5% of the implementation run.
- `backend` + `frontend` alone consume roughly 44% of the run.
- The cost is not one isolated slow step. The fixed multi-agent workflow treats a small reusable component like a full product delivery cycle.
- CAP did not persist per-step provider token usage for this run, so token hotspots cannot be ranked directly. Wall time plus prompt/output size is only a proxy.

## Cost Optimization Decisions

1. **P0: Provider token telemetry before further optimization.**
   CAP needs first-class per-step usage telemetry in `agent-sessions.json`, `workflow-result.json`, and rendered `result.md`: prompt bytes, output bytes, provider input tokens, provider output tokens, cache tokens when available, total tokens, approximate cost or quota pressure, and provider/model identifiers. Without this, CAP can only guess from duration and artifact size, which is not good enough for cost engineering.

2. **P1: Add a single-step component dogfood path.**
   Future component dogfood should not start with the full `project-spec-pipeline` + `project-implementation-pipeline` chain. Add a one-step workflow/profile for known Component Repo fixtures: deterministic template generation + required files + runtime-smoke script + compact AI review. The goal is to test CAP's component repo contract without spending a full multi-agent product lifecycle.

3. **P1: Add component fast path / deterministic templates.**
   For known stacks such as Next.js + .NET + PostgreSQL + Docker Compose, generate the skeleton, design assets, store abstraction, `InMemoryFeedbackStore`, compose file, and smoke script deterministically. Use AI for ambiguous deltas, contract repair, and final review only.

4. **P2: Keep full governance as an explicit strict mode.**
   The current full workflow is still useful for product-scale or ambiguous systems, but it should not be the default dogfood loop for a small component. Profiles should be explicit: `component-fast`, `component-governed`, and `product-strict`.

## Telemetry Contract

Every session should carry a normalized `usage` object. Provider-specific adapters may populate exact token counts; when a provider does not expose usage, the runtime must still persist byte-count proxies.

```json
{
  "available": false,
  "source": "runtime_byte_counts",
  "provider": "claude",
  "provider_cli": "claude",
  "model": null,
  "input_tokens": null,
  "output_tokens": null,
  "cache_read_tokens": null,
  "cache_write_tokens": null,
  "total_tokens": null,
  "prompt_size_bytes": 5624,
  "output_size_bytes": 20430,
  "quota_pressure": null,
  "reason": "provider did not expose token usage; byte counts recorded"
}
```

CLI progress should surface the same truth without inventing token values:

```text
✓ draft_task_constitution (149s · tokens unavailable · prompt 5624B · out 20430B)
```

When provider token usage is available, the same display can become:

```text
✓ frontend (553s · 62.8k tokens · in 41.0k / out 12.6k / cache 9.2k)
```

## Provider Parity

Codex and Claude will not expose usage identically. CAP should normalize shared fields while preserving provider-specific source metadata:

- `provider`
- `provider_cli`
- `model`
- `source`
- `input_tokens`
- `output_tokens`
- `cache_read_tokens`
- `cache_write_tokens`
- `total_tokens`
- `quota_pressure`
- `reason`

This allows later comparisons such as "same workflow under Codex vs Claude" without losing each provider's native reporting limitations.
