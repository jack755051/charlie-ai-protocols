# Component Fast Path Memo (P1a)

> Status: P1a — design + contract sketch only. Implementation deferred to P1b.
> Source evidence: P0b-2 `cap session analyze` output on
> `run_20260513212143_defe3f1c` (component-feedback-widget implementation,
> 44m 25s wall, 87% of Claude 5h quota).
> Parent track: see `docs/cap/COST-OPTIMIZATION-MEMO.md` "Prioritized
> Follow-up Roadmap" → P1 row.

## Why a fast path

The first full `component-feedback-widget` dogfood proved the
implementation pipeline can take a small reusable Component Repo
end-to-end. It also proved the cost profile is unacceptable as the
default loop for component work:

- Implementation alone: 44m 25s (2665s).
- Spec + implementation: ~76 minutes.
- Provider quota: 87% of the Claude rolling 5h limit after one run.
- `cap session analyze` top hotspots: backend (23.2%) + frontend
  (20.8%) consume ~44% of wall time, with audit / packaging /
  testing / archive together accounting for most of the rest.
- The cost is **not one isolated slow step**. The fixed multi-agent
  workflow treats a small reusable component like a full product
  delivery cycle.

Component repos have repeating, predictable structure: known stack
preset, known store abstraction shape, known UI adapter, known
docker-compose layout. AI agents currently re-derive that structure
from scratch every time. A deterministic fast path turns that
repeated derivation into template instantiation + minimal review.

## P1a inputs

`component-fast` accepts a small structured config (target shape;
exact runtime binding deferred to P1b):

| Field | Type | Example | Notes |
|---|---|---|---|
| `project_id` | string (kebab-case) | `component-feedback-widget` | Resolved via `cap-paths.sh` SSOT chain. |
| `component_type` | enum | `feedback-widget` | Looked up against the type registry (see Catalog below). |
| `stack_preset` | enum | `nextjs14_dotnet8_postgres16` | One preset for now; multi-preset support is a P2 split. |
| `ui_adapter` | enum | `shadcn_ui` | Locks `shadcn-ui + Tailwind CSS + Lucide` per Component Repo profile (agent-skills/04-frontend-agent.md §3.6.1). |
| `storage_default` | enum | `in_memory` | Drives `InMemoryFeedbackStore` (or equivalent) as the default; PostgreSQL adapter is integration-runtime only. |
| `exclusions` | string[] | `["redis"]` | Hard-excludes optional stacks. Catalog must not reference excluded technologies. |

Validation contract: any input outside the registry rejects with
`needs_data` at the resolve step. No silent fallback to
`project-spec-pipeline` from inside fast path — operator must
explicitly switch profiles.

### P1b-input-1 structured args schema

The fields above are formalized in
[`schemas/component-fast-args.schema.yaml`](../../schemas/component-fast-args.schema.yaml).
The schema is the **single artifact contract** the workflow's
`resolve_inputs` step requires; per
[ADR-2 (CAP Input Boundary: Prompt vs Structured Args)](../../development-records/decisions/cap-input-boundary-prompt-vs-structured-2026-05-15.md)
the runtime never accepts a free-form prose prompt as a
substitute. Validate any candidate args file with:

```bash
python3 engine/step_runtime.py validate-jsonschema \
  /path/to/args.json \
  schemas/component-fast-args.schema.yaml
```

Returns `{"ok": true, "errors": []}` on a passing args file and
`{"ok": false, "errors": [...]}` (exit 1) on a failing one. The
regression matrix lives in
[`tests/scripts/test-component-fast-args-schema.sh`](../../tests/scripts/test-component-fast-args-schema.sh)
(10 cases, 21 assertions).

Canonical minimum-required payload:

```json
{
  "schema_version": 1,
  "project_id": "component-feedback-widget",
  "component_type": "feedback-widget",
  "stack_preset": "nextjs14_dotnet8_postgres16",
  "ui_adapter": "shadcn_ui",
  "storage_default": "in_memory",
  "exclusions": ["redis"]
}
```

Optional fields (`target_root`, `api_base_url`, `env`) may be set
when a fixture or dogfood scenario needs to override registry
defaults. Anything else is rejected by `additionalProperties:
false`.

**Out of scope for this slice (P1b-input-1):** no CLI surface
consumes the args file yet. `cap workflow run component-fast`
still expects the upstream `component_fast_args` artifact to be
produced through some operator-controlled mechanism; defining
that mechanism is a later slice and must respect ADR-2
("wrappers may produce structured args; runtime never interprets
prose").

## P1a deterministic file catalog

The first first-class component_type is `feedback-widget` (because it
is the dogfood subject). Its catalog:

| Path | Purpose | Template source (P1b) |
|---|---|---|
| `.env.example` | Env contract: API base URL, port, feature flags. No real secrets. | `templates/component-fast/feedback-widget/.env.example` |
| `frontend/lib/feedback/` | DTOs, mappers, HTTP client, ApiResponse / PaginatedResponse types. No UI imports. | `templates/component-fast/feedback-widget/frontend/lib/feedback/*` |
| `frontend/components/feedback/` | shadcn-ui primitives + adapter layer; binds against `frontend/lib/feedback`. | `templates/component-fast/feedback-widget/frontend/components/feedback/*` |
| `design/tokens.json` | Color / spacing / typography tokens for shadcn-ui adapter. | `templates/component-fast/feedback-widget/design/tokens.json` |
| `design/theme.css` | Applied theme tokens. | `templates/component-fast/feedback-widget/design/theme.css` |
| `backend/Feedback/` | Clean Architecture: Domain (Aggregate + Value Objects) / Application (UnitOfWork) / Infrastructure (`InMemoryFeedbackStore`, optional `PostgresFeedbackStore`) / WebAPI (Controllers). | `templates/component-fast/feedback-widget/backend/Feedback/*` |
| `docker-compose.yml` | Compose stack: PostgreSQL 16, backend, frontend. All ports & connection strings env-driven. | `templates/component-fast/feedback-widget/docker-compose.yml` |
| `scripts/runtime-smoke.sh` | `compose up -d`, curl probe `/api/health` + `/api/feedback`, teardown on exit. Exit non-zero if any probe fails. | `templates/component-fast/feedback-widget/scripts/runtime-smoke.sh` |

Catalog format (P1b): `schemas/component-types/<type>.yaml` declares
each entry's `source_template_path` / `target_path` / required
env_vars / `contract_version`. Registry is loaded by the new
`scripts/workflows/component-fast-render.sh`.

Token substitution scope (deterministic; no AI):

- `${PROJECT_ID}` → the kebab-case slug
- `${PROJECT_NAME_PASCAL}` → PascalCase derivation (for .NET namespaces)
- `${STORE_DEFAULT}` → `InMemoryFeedbackStore` (or registered alternative)
- `${API_BASE_URL}` → env-driven, default `http://localhost:8080`
- `${COMPONENT_TYPE}` → the enum value

Substitutions are pure text replacement; no template engine
complexity. Anything more sophisticated (conditional sections,
loops) is a sign the template should be split.

## P1a AI-backed steps

After the deterministic skeleton lands, run **at most 2** AI steps:

1. **`compact_review`** (mandatory):
   - Input: rendered skeleton dirs + project_constitution excerpt +
     the catalog's contract version.
   - Capability: `component_repo_compact_review` (new in P1b).
   - Expected output: a short `verdict: pass | repairs_needed` plus
     a repair list (file path + the contract gap detected).
   - Timeout: 240s. Heavy lifting was done deterministically; this is
     a sanity gate, not a re-implementation.

2. **`fix_or_polish`** (conditional — only when `compact_review`
   returns `repairs_needed`):
   - Input: `compact_review` repair list + skeleton.
   - Capability: `component_repo_repair` (new in P1b).
   - Output: edited files (small diffs).
   - Timeout: 240s. If repair scope is too large, fast path is the
     wrong loop — operator should switch to `component-governed`
     instead of letting this AI step expand into a full re-implementation.

Optional UX polish: the maintainer may decide to enable a third AI
step (e.g. accessibility / copy-deck refinement) as a `--polish`
flag. P1a treats this as out of scope; default fast path is 2 AI
steps maximum.

## P1a compressed governance

| Surface | Default pipeline cost | Fast path approach |
|---|---|---|
| Project Constitution | `project-constitution` workflow ~3 min | Reuse existing project_constitution OR template-fill from inputs (deterministic). |
| Task Constitution | `task_constitution_planning` AI ~150s | Deterministic stub (template-fill from inputs). |
| BA spec | `business_analysis` AI ~250s+ | Skipped (template embeds the spec). |
| API design | `database_api_design` AI ~250s+ | Skipped (template embeds the API contract). |
| UI design | `ui_design` AI ~250s+ | Skipped (tokens.json + theme.css ship in template). |
| Backend implementation | `backend_implementation` AI ~619s | Template + 1 optional AI repair step. |
| Frontend implementation | `frontend_implementation` AI ~553s | Template + 1 optional AI repair step. |
| QA testing | `qa_testing` AI ~326s | Deterministic checklist (file existence + smoke script run) + optional AI audit. |
| Security audit | `security_audit` AI ~272s | Deterministic checklist (no secret in committed `.env`, `.gitignore` covers `.env`, no hardcoded `localhost` in core, no Redis import when excluded, etc.) + optional AI audit. |
| Impl audit | `code_structure_audit` AI ~176s | Skipped (contract enforced by the deterministic templates themselves). |
| Archive | `technical_logging` AI ~176s | Deterministic `result.md` emit (reuse P7 `result_report_builder.render_result_md`). |

The deterministic checklist contracts (QA + security) live in
`scripts/workflows/component-fast-audit.sh` (P1b). They emit
machine-readable results in the same shape that current QA / security
gates use, so downstream observability (workflow.log, result.md) does
not branch.

## P1a success thresholds

These are the "is fast path even useful?" gates. Falling short on any
single threshold means P1a is unsuccessful and requires re-design
before P1b implementation.

| Metric | Target | Source / measurement |
|---|---|---|
| Wall time | **< 10 min total** | `cap session analyze --run-id <fast-run>` Summary `duration:` line. P0b baseline: 44m 25s for implementation alone → target is roughly 4.5× faster. |
| AI step count | **<= 2** | `cap session analyze` JSON `lifecycle_counts` for ai-executor sessions, or per-step inspection in result.md. P0b baseline: ~10 AI steps. |
| Total prompt bytes | **<= 30% of full pipeline** | `cap session analyze` Summary `total_prompt_bytes:` line. Direct comparison against the same-component-type full pipeline run. |
| Required files generated | **100% match against catalog** | Deterministic file-existence assertion in `component-fast-audit.sh`. |
| Smoke test exit code | **0** | `scripts/runtime-smoke.sh` last line; recorded as the audit step's `result`. |

P0b-2 already provides the measurement surface (`cap session analyze`
sparse view's Summary / Hotspots / Decision Signals); no new
observability tooling is needed to validate the thresholds.

## P1a workflow skeleton (design only, P1b implements)

`schemas/workflows/component-fast.yaml` target shape:

```yaml
workflow_id: component-fast
name: Component Fast Path
description: |
  Deterministic Component Repo bootstrap + minimal AI review.
  Replaces the default full-pipeline flow for known component types.
  See docs/cap/COMPONENT-FAST-PATH-MEMO.md for inputs / contracts /
  thresholds.

# Phase plan — most phases are shell, two AI steps maximum.
phases:
  - phase: 1
    steps:
      - step_id: resolve_inputs
        executor: shell
        capability: component_fast_inputs   # NEW (P1b)
        script: scripts/workflows/component-fast-resolve.sh
        # Validates project_id / component_type / stack_preset /
        # ui_adapter / storage_default / exclusions against the
        # registry. Halts with `needs_data` on unknown values.

  - phase: 2
    steps:
      - step_id: render_skeleton
        executor: shell
        capability: deterministic_scaffold  # NEW (P1b)
        script: scripts/workflows/component-fast-render.sh
        # Reads catalog for component_type, copies templates with
        # token substitution. Writes to project_root (CAP write
        # contract — capability is on the code-emitting whitelist).

  - phase: 3
    steps:
      - step_id: deterministic_audit
        executor: shell
        capability: deterministic_compliance_checklist  # NEW (P1b)
        script: scripts/workflows/component-fast-audit.sh
        # File existence per catalog. .env safety. No hardcoded
        # localhost / port in core. Exclusions respected. Smoke
        # script is executable.

  - phase: 4
    steps:
      - step_id: smoke_runtime
        executor: shell
        capability: runtime_smoke           # NEW (P1b)
        script: scripts/runtime-smoke.sh
        # docker compose up -d; health probe; teardown. Exit 0
        # required; non-zero halts the workflow.

  - phase: 5
    steps:
      - step_id: compact_review
        executor: ai
        capability: component_repo_compact_review  # NEW (P1b)
        timeout_seconds: 240
        on_fail: route_back_to
        route_back_to: render_skeleton
        # Input: skeleton dirs + catalog contract version +
        # project_constitution excerpt. Output: pass | repairs_needed.

  - phase: 6
    steps:
      - step_id: fix_or_polish
        executor: ai
        capability: component_repo_repair         # NEW (P1b)
        timeout_seconds: 240
        on_fail: halt
        # Skipped when compact_review verdict=pass. Edits files in
        # place; output_paths must list every modified file.

  - phase: 7
    steps:
      - step_id: archive
        executor: shell
        capability: result_report_emit            # reuse P7 (existing)
        # Single deterministic step; no AI archive.
```

New capabilities (`schemas/capabilities.yaml`, P1b):
`component_fast_inputs`, `deterministic_scaffold`,
`deterministic_compliance_checklist`, `runtime_smoke`,
`component_repo_compact_review`, `component_repo_repair`.

Code-emit whitelist (`engine/step_runtime.py:_CODE_EMITTING_CAPABILITIES`):
`deterministic_scaffold` and `component_repo_repair` must be added so
the AI Write Contract (§5.3.2) wires the landing dir correctly. The
other new capabilities are read-only / audit / smoke and do not need
write access.

## Out of scope for P1a

- Actual `.yaml` workflow file (P1b).
- `scripts/workflows/component-fast-*.sh` generators (P1b).
- Template registry `schemas/component-types/<type>.yaml` (P1b).
- New `schemas/capabilities.yaml` entries (P1b).
- `cap component init <type>` CLI surface (P1c, if needed; until then
  fast path runs via `cap workflow run component-fast`).
- Multi-component combinations in one repo (multi-widget per repo).
  Today the fast path expects a one-repo / one-component_type
  invocation.
- Migration path for existing Component Repos created via full
  pipeline. Existing repos stay on whatever path they were created
  with; fast path is a new-entry default, not a retroactive rewrite.
- Multi-provider fallback for the two AI steps. Claude is the
  default; Codex compatibility is a P1c follow-up.
- Provider real token extraction (still gated to P0d / P0+ regardless
  of which workflow runs).

## P1b implementation order

Recommended sequence once P1a is approved:

1. Write `schemas/component-types/feedback-widget.yaml` (the canonical
   first registry entry).
2. Write `templates/component-fast/feedback-widget/` (the actual
   template files referenced by the registry).
3. Add the 6 new capabilities to `schemas/capabilities.yaml`.
4. Update `engine/step_runtime.py:_CODE_EMITTING_CAPABILITIES` with
   `deterministic_scaffold` + `component_repo_repair`.
5. Write `scripts/workflows/component-fast-resolve.sh` /
   `component-fast-render.sh` / `component-fast-audit.sh`.
6. Write `schemas/workflows/component-fast.yaml` (the workflow
   skeleton above, fully populated).
7. Add regression tests: file existence checklist, token substitution
   determinism, smoke script exit-code contract.
8. Run fast path against the same `component-feedback-widget`
   maintainer fixture used in P0b dogfood. Validate the five P1a
   success thresholds (< 10 min / <= 2 AI / <= 30% prompt bytes /
   100% catalog files / smoke exit 0).
9. Only after the thresholds pass: update
   `docs/cap/COST-OPTIMIZATION-MEMO.md` P1 row to mark fast path as
   shipped, and switch the default Component Repo dogfood loop from
   `project-spec-pipeline` + `project-implementation-pipeline` to
   `component-fast`.

If any threshold misses, return to this memo and re-scope before
trying again. Do not paper over a missed threshold with "good enough"
language — the whole point of P1a is to make the decision
quantifiable.
