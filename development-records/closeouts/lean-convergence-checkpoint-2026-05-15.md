# Lean Convergence Checkpoint (2026-05-15)

> Status: pause-and-read snapshot.
> Anchors:
> [`docs/cap/CAP-POSITIONING.md`](../../docs/cap/CAP-POSITIONING.md),
> [`docs/cap/CAP-LEAN-ROADMAP.md`](../../docs/cap/CAP-LEAN-ROADMAP.md),
> [`development-records/findings/cap-deferred-expansion-audit-2026-05-15.md`](../findings/cap-deferred-expansion-audit-2026-05-15.md).
>
> Purpose: take stock after a multi-slice removal cycle, name what
> CAP is now, and decide whether to continue removing or stop.

## 1. What landed (chronological)

```text
ce2576d chore(workflow): remove detached run stub                            (slice #2)
329441f docs(cap): drop marketplace publish aspiration from active docs      (slice #1)
4817706 docs(cap): audit deferred expansion surfaces
3ed5f64 chore(dogfood): remove provider parity runtime surface
5cb3cb6 docs(skills): classify agent skills by CAP usage tier
a1b4851 docs(workflows): classify AI-heavy workflows as legacy
040f33a docs(cap): add lean roadmap and surface in indexes
5ebf3f0 chore(component-fast): remove frozen runtime profile
```

Eight commits, net effect:

- ~7000 lines of runtime code / templates / tests / docs removed
  (component-fast alone was 6398 deletions).
- One generator surface retired (`component-fast`).
- One release-gate pattern retired (`provider-parity`).
- One AI-orchestration narrative retired (agent-skills "agent army").
- One execution-orchestration stub retired (`run -d` / detached).
- One aspiration surface retired (marketplace / publish).
- Four AI-heavy multi-agent workflows reclassified as legacy
  (`project-spec-pipeline` / `project-implementation-pipeline` /
  `project-qa-pipeline` / `supervisor-orchestration`).

## 2. What CAP core IS now

The three-layer architecture from ADR-3 / CAP-POSITIONING.md is
intact and concretely populated:

### Layer 1 — CAP Platform

- **Workflow runtime**: `cap workflow compile / bind / run / plan
  / inspect`, step executor, AI write contract, AI step result
  enum, handoff ticket schema.
- **Constitution governance**: project constitution loading,
  `binding_policy` evaluation, allowed-capabilities enforcement,
  `binding_status` reporting.
- **Skill registry**: project / shared / builtin layered
  resolver + role + attached-skills model.
- **Provider readiness** (P0–P2 shipped this cycle):
  - `schemas/provider-readiness.schema.yaml` v1
  - `cap provider doctor [--json]` → schema-conforming readiness
    report
  - `cap workflow run` preflight that halts AI-backed workflows
    before any token spend when provider state is
    `provider_missing` / `auth_required` / `error` / unknown CLI
    / parse error; warns + proceeds on `auth_unknown`; silent on
    `auth_ok`.
- **Observability**: `cap session analyze`, `cap workflow
  inspect`, `cap session inspect`, workflow result JSON, run
  archive summary, route history.
- **Post-AI handover**: `cap promote inspect / project-
  constitution / workflow`, `cap replay` verification.

### Layer 2 — Provider CLI (CAP does NOT own)

- Claude Code, Codex, future DeepSeek / OpenAI / local model
  adapters. Auth, sessions, prompt → text remain provider-side.

### Layer 3 — Repo / Profile

- `agent-skills/` (now tiered: governance / advisory / deferred).
- `schemas/workflows/` (4 AI-heavy legacy + lean active set).
- `schemas/capabilities.yaml`, project constitution, runtime
  binder skill mappings.

## 3. What CAP core is NOT (after this cycle)

Explicit out-of-scope:

- AI orchestration engine that automatically launches a
  multi-agent pipeline.
- Stack-specific code generator (`component-fast` retired).
- Cross-provider release-gate pattern (`provider-parity`
  retired).
- Background / detached runtime executor (stub retired).
- Marketplace / publish / distribution surface (aspiration
  retired).
- Prose-to-structured-args inference at runtime (ADR-2 ratified
  structured-first input boundary).

## 4. Remaining audit candidates (deferred, not authorized)

Per [`cap-deferred-expansion-audit-2026-05-15.md`](../findings/cap-deferred-expansion-audit-2026-05-15.md):

| Surface | Audit verdict | Status |
|---|---|---|
| 3.1 promote | keep | retained — post-AI record / SSOT bridge |
| 3.2 design source / Figma | defer; remove candidate | **pending decision (slice #4 if authorized)** |
| 3.3 Karpathy runtime | defer; remove candidate | **pending decision (slice #3 if authorized)** |
| 3.4 replay | keep | retained — post-run audit primitive |
| 3.5 detached / background | remove | landed (`ce2576d`) |
| 3.6 marketplace / publish | remove (docs) | landed (`329441f`) |

The two remaining candidates touch:

- **Karpathy** — 3 workflow YAMLs + 2 capability blocks +
  2 dedicated tests + smoke wiring. Skill file stays Tier 3.
- **Design source** — schema + engine module + ingest shell +
  3 tests + smoke wiring. Figma skill stays Tier 3.

Both are higher-risk than #1 / #2 because removal interacts with
tests, capabilities, and smoke layer configuration.

## 5. Decision framework for continuing

Use these four questions for each remaining candidate **before**
authorizing a slice. If all four lean toward "remove", proceed;
if any one is ambiguous, pause again.

1. **Active workflow reference** — is this surface still
   referenced by a non-legacy workflow YAML, a non-legacy
   capability default_agent, or by an active CLI subcommand?
2. **Smoke / release-gate dependency** — does CI / smoke-layer /
   smoke-per-stage exercise this surface as part of the lean
   release definition (vs. as a fixture that just needs
   removal too)?
3. **Provider-facing vs. CAP runtime** — does this exist
   primarily as guidance a provider may load (provider-facing),
   or as code CAP itself runs (runtime)? Provider-facing
   guidance can stay as Tier 3 skill; CAP-runtime expansion
   surfaces are the actual deletion target.
4. **Positioning fit** — does removal move CAP closer to
   "governance + record before / after AI work"? If neutral or
   worsens the positioning, don't remove.

Applying these to the two remaining candidates:

### 5.1 Karpathy runtime (slice #3 candidate)

| Q | Answer |
|---|---|
| Q1 active workflow ref | Yes — 3 dedicated YAMLs + 2 capabilities in `schemas/capabilities.yaml:584+`. |
| Q2 smoke dependency | Yes (2 dedicated tests + peripheral mentions in 2 other tests). |
| Q3 provider-facing? | **Skill file is provider-facing** (Tier 3 advisory). The runtime workflows are CAP-side AI orchestration. Clean separation. |
| Q4 positioning fit | Yes — `karpathy-real-task-dogfood` is exactly the "CAP as AI execution entry" pattern the lean restructuring moves away from. |

Verdict still leans **remove**, but executing this needs care
on Q2 (the smoke layer references). Plan: remove runtime
workflows + capabilities + 2 dedicated tests + smoke wiring;
keep the skill file as Tier 3 / Deferred.

### 5.2 Design source runtime (slice #4 candidate)

| Q | Answer |
|---|---|
| Q1 active workflow ref | Yes — but primary consumer (`project-spec-pipeline`) is already legacy. Standalone `ingest-design-source.sh` lives. |
| Q2 smoke dependency | Yes — 3 tests in smoke-per-stage. Higher dependency footprint than Karpathy. |
| Q3 provider-facing? | Figma skill (Tier 3) is provider-facing. Schema + engine + ingest shell are runtime. |
| Q4 positioning fit | Partial. Deterministic file staging is governance-adjacent; the runtime mostly served the now-legacy AI-heavy pipelines. |

Verdict still leans **remove**, but Q2's blast radius is
strictly larger than Karpathy's. Per audit §5,
this slice should run **after** Karpathy so each is its own
clean commit and verification cycle.

## 6. Recommendation

**Pause as the default.** The eight commits above are a real
restructuring. Each one altered an operator-facing surface or
narrative. Before doing two more removal slices, let the new
shape be the working assumption for at least one round of
real use (dogfood / regression / operator review). The audit
verdicts on Karpathy and design source are stable; they will
not change in the next week.

**If the operator wants to continue immediately**, the
recommended next slice is **#3 (Karpathy runtime)** because:

- Karpathy is advisory guidance whose value sits at the skill
  layer, not the runtime layer.
- Removing the runtime workflows leaves the
  provider-facing guidance fully intact (skill file Tier 3
  unchanged).
- Smaller smoke / test footprint than #4.
- `karpathy-real-task-dogfood` is the most explicitly "CAP as
  AI entry" surface remaining.

**Slice #4 (design source) should remain last** because:

- Larger smoke footprint (3 tests).
- Touches schema + engine module + ingest shell + constitution
  forwarding, which spans more files.
- Risk of unintended interaction with the legacy AI-heavy
  pipelines (whose YAMLs reference design ingest steps as
  upstream).

## 7. What this checkpoint deliberately does NOT do

- Does not remove any runtime code.
- Does not authorize slice #3 or #4.
- Does not modify CAP-POSITIONING / CAP-LEAN-ROADMAP / ADRs.
- Does not declare lean restructuring "done". It declares one
  cycle of removal "done", with the explicit option to either
  stop or proceed.
- Does not re-audit `promote` or `replay`; those remain **keep**
  per the audit and this checkpoint.

— end checkpoint —
