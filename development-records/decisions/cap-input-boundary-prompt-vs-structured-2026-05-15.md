# Decision: CAP Input Boundary — Prompt vs. Structured Args

> Status: **accepted** (operator-ratified 2026-05-15).
> Type: architectural decision record (second ADR in
> `development-records/decisions/`; first was
> `component-fast-core-vs-profile-2026-05-15.md`).
> Triggered by:
> `development-records/closeouts/component-fast-6b-closeout-2026-05-15.md`
> §5 classification (`profile_bug` for the prompt-vs-args gap)
> and §6 (dry-run does not catch missing structured inputs).
> Anchors: `agent-skills/00-core-protocol.md` §5.3.1 (AI step
> result enum), §5.3.2 (AI write contract),
> `schemas/handoff-ticket.schema.yaml`,
> `docs/cap/COST-OPTIMIZATION-MEMO.md` (cost driver framing —
> "reduce loss" not "be convenient").

## 1. Decision

CAP workflow / capability / step inputs are **structured-first**.
The runtime contract is satisfied by structured artifacts or
structured args, never by free-form prose. Free-form prose
prompts may exist at the *outermost* operator-facing layer, but
they MUST be turned into structured inputs by a separate
operator-controlled step before the runtime is entered, and the
runtime MUST fast-fail when a required structured input is
absent.

The one-shot evidence run on 2026-05-15
(`run_20260515100635_e765bd8d`) halted at Phase 1 with
`missing_input_artifact: component_fast_args`. **That halt is
the policy working, not a bug.** The closeout's
`profile_bug` classification points at the profile's missing
contract surface, not at the runtime's refusal to fabricate.

## 2. Context

### 2.1 What surfaced the question

The Component Fast Path workflow declares
`resolve_inputs.inputs: [component_fast_args]`. The
operator-facing CLI today is
`cap workflow run --cli claude component-fast "<prompt>"`. That
trailing string is a prose user prompt, not a `component_fast_args`
artifact. Nothing in the profile (or anywhere else) translates
prompt → args, so any live run halts before the first AI call.

Two competing patches were obvious-looking and both wrong:

- **Patch A** — write a prompt parser that infers
  `component_type` / `project_id` / `stack_preset` / etc from
  the user prompt. This re-introduces an AI step, brings
  parsing ambiguity, breaks repeatability, and destroys the
  cost-comparability that motivated the fast path in the first
  place (`docs/cap/COST-OPTIMIZATION-MEMO.md`).
- **Patch B** — silently default the missing args from the
  registry. This hides drift, hides operator intent, and turns
  the workflow into a "guess what I meant" loop. It is the
  opposite of the governance the constitution / write-contract /
  result-contract layers were built to enforce.

### 2.2 The deeper question

The pattern recurs whenever a fast path or deterministic
substrate is added. The choice is structural, not local to
component-fast:

> Is the workflow runtime's input contract a structured
> artifact / args object, or a prose prompt the runtime
> interprets?

Picking one and applying it consistently is more important than
the specifics of `component_fast_args`.

### 2.3 Prior precedent already in the codebase

CAP has already chosen structured-first at every other
contract boundary, even if it has not named the policy:

- **AI step result enum** (`§5.3.1`) — `result:` value must be
  one of the documented enum strings, parsed from a structured
  position in the handoff summary. The runtime does not
  interpret free-form sentiment.
- **AI write contract** (`§5.3.2`) — landing dir is a literal
  filesystem path injected via provider flags; emit-gate scans
  the dir, not the AI's verbal claim of having written files.
- **Handoff ticket schema** — `acceptance_criteria`,
  `failure_routing`, `output_expectations` are all required
  structured fields; ticket is a JSON file on disk, not a
  prompt sentence.
- **Task constitution schema** — `task_id`, `goal_stage`,
  `execution_plan[].step_id`, `execution_plan[].capability`
  are all strictly typed; alias normalization is being phased
  out in v0.22.0+.
- **Project constitution `allowed_capabilities`** — a list of
  identifiers, not a description of what is allowed.

The component-fast contract gap is therefore not a new problem
that needs a new answer; it is the first place the existing
implicit policy collides with an operator-facing CLI surface
that drew the wrong default.

## 3. Why structured-first

### 3.1 Failure should be loud and early

Structured inputs surface drift at the boundary:

- Missing field → halt at step entry, before any AI is invoked.
- Unknown enum value → halt at registry validation.
- Constitution disallows a capability → halt at bind time.

Prose inputs hide drift behind interpretation:

- Did the prompt actually mean `feedback-widget` or
  `feedback-page`?
- Did "no Redis" mean `exclusions: [redis]` or just "we
  don't currently use Redis"?
- Did "use Postgres" mean `storage_default: postgres` or
  "Postgres is acceptable as an adapter"?

Every one of those is one extra round of inference. Each round
is a place CAP starts paying cost it cannot account for.

### 3.2 The goal is reduce loss, not be convenient

`COST-OPTIMIZATION-MEMO.md` framed the fast path as a response
to a 44-minute, 87%-of-quota dogfood. The optimization target
was never "make the CLI easier to type" — it was "stop paying
multi-agent inference cost for things that are deterministic".

Prose inputs reintroduce inference at exactly the boundary the
fast path was built to remove. Structured inputs are a small
amount of operator typing in exchange for:

- Repeatability (the same args file gives the same run).
- Cost comparability (no prompt parser to vary across runs).
- Auditability (the args file is a diff-able artifact).
- Testability (deterministic gates can assert on the args
  shape, not on prose).

### 3.3 The runtime already paid this cost in §5.3.x

CAP `00-core-protocol.md` §5.3.1 / §5.3.2 spent significant
design budget making AI *outputs* structured (result enum,
write-contract emit gate) — explicitly to surface drift early
instead of trusting AI prose. The same logic applied to AI
*inputs* (and capability inputs in general) is just the
symmetric move.

## 4. What prompt-first becomes

Prompt-first does not disappear. It is **demoted from runtime
contract to operator convenience wrapper**.

### 4.1 Where prose may live

- The outermost human-facing entry point (e.g. a hypothetical
  `cap component init "<prompt>"`).
- Documentation, runbooks, ADRs, and per-run notes that
  describe operator intent in plain language.
- Free-text fields inside structured args themselves, when the
  schema explicitly types a field as free text (e.g. a
  `summary:` string on a constitution).

### 4.2 Where prose may NOT live

- `cap workflow run` input position. The trailing string today
  is treated by some workflows as a user prompt and by others
  as ignored noise. That ambiguity is itself part of the
  problem; resolving the ambiguity is out of scope for this
  ADR but the direction is "shrink the prose surface, not
  expand it".
- Inside any structured input field that is typed as an enum,
  identifier, or path.
- As a workaround for a missing structured args file ("just
  describe it in the prompt, the system will figure it out").

### 4.3 Convenience wrapper shape (illustrative, not authorized)

A prose-to-args wrapper, *if* it is ever built, would look like
two clearly separate stages:

```text
operator prose prompt
   │
   ▼  (outer wrapper, may use AI, lives outside runtime core)
structured args file (.yaml / .json, schema-validated)
   │
   ▼  (workflow runtime, never sees the prose)
cap workflow run component-fast --args <file>
```

The wrapper is allowed to use AI; the runtime is not allowed to
treat the wrapper's output as anything other than a validated
structured artifact. **Building this wrapper is NOT authorized
by this ADR.** The shape is recorded only to show that
structured-first does not foreclose ergonomics — it just sites
the ergonomics outside the cost-sensitive runtime.

## 5. Fast-fail is the contract

A fast-path workflow whose required structured input is absent
MUST:

- Halt at step entry, not at AI invocation.
- Report `blocked_reason: missing_input_artifact` (the existing
  shape, already emitted by the 2026-05-15 one-shot run).
- Cost zero AI tokens.
- Cost zero file writes under landing dirs.

This is already the runtime's behavior. The ADR ratifies it as
intentional, not accidental. Future operators encountering this
halt should classify it as "policy working", not as a
regression.

## 6. Consequences

### 6.1 Positive

- The 2026-05-15 one-shot evidence run's halt is correctly
  named: profile-level contract gap, not runtime bug. Closeout
  classification stands without revision.
- The convergence memo §4 bloat catalog gets one of its
  largest items (`cap component init`, prompt parsers, prompt
  routing) re-routed permanently out of core. Those things are
  allowed to exist someday, but only outside the runtime, and
  not as the next slice.
- Future fast paths (any profile, not just component-fast) get
  a single canonical answer to "how do I take user input?":
  define a structured args schema, validate at step entry,
  fast-fail on absence.
- Existing structured boundaries (`§5.3.1`, `§5.3.2`, handoff
  ticket schema, task constitution schema, constitution
  allowed_capabilities) get a named umbrella policy. Future
  schema work can cite this ADR instead of re-litigating.

### 6.2 Acknowledged costs

- Operators using component-fast (or any future fast-path
  workflow) must produce a structured args file or args block
  before invoking the runtime. This is a real ergonomic ask
  during the period before any wrapper exists.
- The five P1a thresholds for component-fast remain unmeasured.
  Closing that gap now requires an authorized track to define
  the args schema + an authorized track to teach the operator
  CLI how to consume it. Both are deferred per §7 below.
- Convenience-driven contributors may push back on the policy.
  The policy stands; convenience tooling goes in wrappers.

### 6.3 No-op for already-shipped code

The 2026-05-15 substrate (slices 1–6b-prep) already encodes
structured inputs in the registry, capabilities, and workflow
YAML. No code, schema, or template change is required by this
ADR to make the substrate compliant — it already is. The gap is
between the runtime's correct structured-first contract and the
operator-facing CLI's prose-shaped entry point.

## 7. What this ADR explicitly does NOT decide

- **The schema for `component_fast_args`.** Not authored by
  this ADR. Convergence memo freeze line still in force. If
  the operator later authorizes a "structured args contract"
  track, that track produces e.g.
  `schemas/component-fast-args.schema.yaml` and re-runs the
  one-shot evidence run; this ADR only fixes the policy
  direction.
- **The CLI surface for passing structured args.** Not
  authored here. Candidates exist (`--args <file>`,
  `--component-type foo --project-id bar`, args embedded in
  `.cap/` per project, etc); choice is out of scope.
- **Whether `cap workflow run "<prompt>"` should accept a prose
  string at all.** Today it does (some workflows use it, some
  ignore it). Shrinking that surface is a separate decision.
- **Building any prose-to-args wrapper.** §4.3 shows the
  shape; building it requires its own authorization.
- **Re-running the one-shot evidence run.** Per closeout §7
  and ADR-1 Q6, retry needs explicit operator authorization;
  this ADR does not provide it.
- **`docs/cap/COST-OPTIMIZATION-MEMO.md` P1 row update.** The
  five P1a thresholds are still unmeasured; ADR does not
  change that.
- **Touching any target repo.** Target repo at
  `~/Desktop/01_private/cap-test/component-feedback-widget/`
  remains a dogfood fixture and outside framework commits.

## 8. Freeze status (unchanged)

Convergence memo §6 freeze line and §7 allow-list remain in
force. ADR-1 (core-vs-profile) remains in force. This ADR adds
exactly one piece of new doctrine — structured-first input
boundary — and reuses existing freeze + allow-list to govern
what may follow.

The next operator decision is one of:

- **Author the `component_fast_args` structured schema** (a
  small, deterministic, doc-grade artifact; would unlock a
  second one-shot evidence run).
- **Open the profile-extraction track** (per ADR-1 §4
  preferred path; bigger scope).
- **Pure reduction** (always permitted).

Recommend authoring the args schema first — it is the smallest
deterministic step compatible with this ADR and gives the
unmeasured thresholds a path to measurement without lifting any
existing freeze.

— end ADR —
