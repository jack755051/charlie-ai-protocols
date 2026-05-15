# Decision: CAP Provider Readiness Boundary

> Status: **accepted** (operator-ratified 2026-05-15).
> Type: architectural decision record (third ADR in
> `development-records/decisions/`).
> Triggered by: discussion that surfaced after ADR-2 — CAP without
> an available provider CLI reduces to deterministic substrate +
> docs, which is real value but does not complete AI-backed tasks.
> Live dogfood patterns and the 2026-05-15 one-shot evidence run
> (where preflight gates were all green but the run halted on a
> profile contract gap) made clear that provider readiness sits
> *upstream* of every workflow-level concern and is currently
> implicit.
> Anchors:
> [`docs/cap/PROVIDER-ONBOARDING-MEMO.md`](../../docs/cap/PROVIDER-ONBOARDING-MEMO.md)
> (design surface — first-run UX, probe contract, login failure
> handling),
> [`docs/cap/PROVIDER-READINESS-TASKS.md`](../../docs/cap/PROVIDER-READINESS-TASKS.md)
> (active task list — P0–P4 implementation order),
> [`development-records/decisions/component-fast-core-vs-profile-2026-05-15.md`](component-fast-core-vs-profile-2026-05-15.md)
> (ADR-1, core / profile / doctor split),
> [`development-records/decisions/cap-input-boundary-prompt-vs-structured-2026-05-15.md`](cap-input-boundary-prompt-vs-structured-2026-05-15.md)
> (ADR-2, structured-first input boundary).

## 1. Decision

The CAP platform binds **provider readiness** as a first-class
responsibility but **provider authentication** as someone else's.
Five rulings, applied together:

1. **CAP does not own provider login.** Claude Code, Codex,
   DeepSeek, OpenAI, local-model tooling, and any future
   provider CLI keep ownership of their own account, auth flow,
   credential storage, and session lifecycle. CAP MUST NOT
   mutate provider login state, MUST NOT cache tokens, MUST NOT
   re-implement provider auth.

2. **CAP owns provider readiness.** Before any AI-backed
   workflow runs, CAP MUST know whether the selected provider
   is available (CLI present, version sane, auth plausibly
   usable). Readiness checks are CAP's job; CAP is the layer
   the operator turns to when "is this thing going to work?"
   needs an answer.

3. **AI-backed workflows MUST fail fast on missing or
   not-ready providers.** When the selected provider is in
   `provider_missing` / `auth_required` / `error`, the workflow
   runtime MUST halt before the first AI step, write a
   `blocked_reason` that names the provider state, and emit
   provider-specific remediation text. Long runs that discover
   auth failure mid-flight are a regression and must not be
   accepted as the cost of "convenience".

4. **Read-only and shell-only commands MUST NOT require
   provider auth.** `cap help`, `cap version`, `cap skill
   list`, `cap workflow list`, `cap workflow plan`, `cap
   workflow bind`, `cap workflow run --dry-run`,
   `cap project doctor`, and any workflow whose steps are all
   `executor: shell` continue to work without any provider CLI
   being installed. CAP is useful as a deterministic substrate
   even when no AI is reachable.

5. **CAP routes providers directly; provider-to-provider
   proxying is not the default cost strategy.** When the
   operator picks `--cli claude`, CAP talks to the Claude
   provider, not to a Claude that talks to DeepSeek. Indirection
   is allowed only as explicitly authorized comparison /
   second-opinion workflows whose provider trace is fully
   visible. Hidden proxying breaks cost telemetry, breaks
   provider attribution in `cap session analyze`, and breaks
   the "reduce loss" goal of ADR-2.

## 2. Context

### 2.1 What surfaced the question

CAP currently has several layers in place — `cap workflow run`,
binding governance, AI write contract, AI step result enum,
agent-skills sync, deterministic substrates (component-fast),
artifact / session / result observability. None of them
explicitly answer "is the chosen provider going to be usable
when this workflow gets to its first AI step?".

The dogfood pattern is therefore:

- Operator runs `install.sh` → exit 0.
- Operator runs `cap workflow bind` → `binding_status: ready`.
- Operator runs `cap workflow run --dry-run` → green.
- Operator runs `cap workflow run --cli claude …` → wait
  several minutes → discover `claude` is not logged in / not
  installed → halt mid-flight with a half-emitted artifact set
  and an unclear next step.

Each gate above is real and useful. None of them is sized to
catch "provider not ready". The result is a silent class of
"CAP installed cleanly but cannot actually do AI work" that the
operator only finds out about by paying real time.

The 2026-05-15 one-shot evidence run did *not* fail this way —
it failed at a different layer (profile contract gap, classified
in the closeout as `profile_bug`). But the failure shape is the
same: a gate the substrate did not know to check.

### 2.2 Why a separate ADR (and not just an extension to ADR-1 or ADR-2)

- ADR-1 (core vs profile) decided which CAP capabilities live in
  core vs which are profile payloads. It did not decide which
  *external* dependencies CAP takes responsibility for.
- ADR-2 (input boundary) decided how *operator inputs* enter
  the runtime. It did not decide how *infrastructure inputs*
  (provider CLIs, API keys, login state) are checked.
- The provider readiness boundary is a third axis: not core vs
  profile, not prose vs structured, but **CAP-owned vs
  CAP-adjacent**. It deserves its own decision so the boundary
  is not muddled with the other two.

### 2.3 Why this comes before any more component-fast work

The convergence memo (§9 option B + ADR-1 Q6) authorized exactly
one live evidence run for the unmeasured P1a thresholds. That
run halted on a profile gap. A *second* one-shot run would also
need the provider to be ready for at least one AI step
(`compact_review`) to produce useful evidence. Without an
explicit readiness boundary, that second run is just as exposed
to silent mid-flight failure as the first was. The cheapest way
to reduce that exposure is to make readiness a known boundary
*before* re-authorizing any live run.

## 3. Three-layer architecture

This ADR ratifies the three-layer model the operator named:

```text
┌──────────────────────────────────────────────────────────────┐
│ Layer 1 — CAP platform                                       │
│                                                              │
│  workflow compile / bind / run                               │
│  constitution governance                                     │
│  skill registry                                              │
│  observability (cap session analyze, run archive, …)         │
│  provider discovery / readiness / routing / cost guard ←NEW  │
│  deterministic-substrate framework                           │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ Layer 2 — Provider CLI                                       │
│                                                              │
│  Claude Code         account, login, session, prompt → text  │
│  Codex               account, login, session, prompt → text  │
│  DeepSeek API        API key, request → text                 │
│  Local model         binary / server, prompt → text          │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ Layer 3 — Repo / Profile                                     │
│                                                              │
│  workflow YAML, skills, capabilities, templates              │
│  project constitution                                        │
│  component_type registries (per ADR-1, profile payload)      │
└──────────────────────────────────────────────────────────────┘
```

Each layer owns its own contract. The CAP platform layer
**probes** Layer 2 but does not **manage** Layer 2's account
state. The CAP platform layer **executes** Layer 3 but does not
**author** Layer 3's profile content.

## 4. What "readiness" must answer

The readiness boundary, when implemented, MUST be able to
answer these six operator questions without spending model
quota and without invoking interactive login:

| # | Question | Required outcome |
|---|---|---|
| 1 | Which providers does CAP know about? | A finite, declared list (CLI names + future API-backed adapters). |
| 2 | Is each provider's CLI / API surface present? | A clear yes/no per provider, with source path or API-key env var name when yes. |
| 3 | If present, is it plausibly authed? | A best-effort state in `{auth_ok, auth_required, auth_unknown, error}`. `auth_unknown` is acceptable; silent guessing is not. |
| 4 | What is the next step to make it ready? | Concrete, copy-pasteable remediation text per provider (e.g. `cap claude`, `claude`, `OPENAI_API_KEY`, `DEEPSEEK_API_KEY`). |
| 5 | Will this workflow need a provider at all? | Yes for any workflow with at least one `executor: ai` step; no for `executor: shell`-only workflows. |
| 6 | Should this run start? | Fail-fast halt if (5) is yes and any required provider is not in `auth_ok` (or `auth_unknown` for commands whose risk profile accepts unknown). |

Probe rules (binding):

- **No-token rule.** Readiness probes MUST NOT send a prompt
  that consumes model quota. If a provider exposes no
  no-token health probe, the resolved state is
  `auth_unknown`, not "spend a few tokens to find out".
- **No-interactive rule.** Readiness probes MUST NOT trigger
  interactive login. `cap doctor` is a read-only diagnostic;
  `cap claude` / `cap codex` are the operator's explicit
  login surfaces.
- **No-mutation rule.** Readiness probes MUST NOT write to
  provider state, config files, or credential stores.

State enum:

- `provider_missing` — CLI / API surface not present at all.
- `installed` — binary or API surface present, auth not yet
  probed (intermediate state, doctor should resolve).
- `auth_required` — probe clearly reports missing / invalid
  credentials.
- `auth_unknown` — probe cannot determine without violating
  the three rules above.
- `auth_ok` — non-interactive no-token probe confirms usable.
- `error` — probe failed in a way that doesn't fit the above
  (timeout, partial state, etc).

These are the same enum values listed in
`PROVIDER-READINESS-TASKS.md` P0 and `PROVIDER-ONBOARDING-MEMO.md`
§"Auth Probe Contract"; this ADR ratifies them so both files
stop being design proposals and become contract.

## 5. Behavior by workflow class

### 5.1 Deterministic / shell-only workflows

If every step in a workflow has `executor: shell` (and no
fallback to AI), the workflow MUST run without any provider
readiness check. Operators who only ever use deterministic
substrates should not be forced to install or log in to any
AI CLI.

### 5.2 AI-backed workflows

If any step has `executor: ai` (or `executor: <provider>`
forms once those exist), the workflow MUST preflight the
selected provider's readiness immediately after binding
resolves and before the first step begins. Preflight is the
provider analogue of binding resolution — same fail-fast
discipline, same artifact (the run halts before any AI is
invoked, the run dir captures the halt reason).

### 5.3 Mixed workflows

If a workflow has both shell and AI steps but the AI step is
gated (skipped under some condition), the readiness preflight
MUST still run for the *possible* AI invocation. CAP does not
let an "AI step might run" workflow start without the operator
knowing the AI side could fail.

### 5.4 Dry-run / bind / compile

`--dry-run`, `cap workflow bind`, `cap workflow plan`, `cap
workflow compile`, `cap workflow show` MUST NOT require
provider readiness. They are design-time / configuration-time
operations; their job is to surface workflow shape, not to
gate the run.

## 6. Consequences

### 6.1 Positive

- Provider readiness becomes a known boundary, not a
  silent assumption. Future provider additions (DeepSeek,
  OpenAI direct, local models) inherit the same six
  questions and three probe rules; no per-provider
  bespoke onboarding logic creeps in.
- The "CAP installed cleanly but cannot do AI" dogfood
  failure mode is moved from "discovered mid-run" to
  "caught at preflight", which is exactly the ADR-2
  pattern (structured-first inputs surface drift early).
- Convergence memo §4 bloat catalog item #5 ("provider
  readiness gate") is now a sized, decided track instead
  of an ambient bloat risk.
- The eventual second one-shot evidence run for the P1a
  thresholds gets a sane precondition — provider must be
  in `auth_ok` before any wall-time measurement starts.
- The three-layer architecture (platform / provider / repo)
  gets named language that subsequent ADRs / memos can
  cite without re-litigating.

### 6.2 Acknowledged costs

- CAP must maintain a small provider-capability table:
  which probes are safe per provider, which remediation
  text per provider, which provider state map per
  provider. This is shared infrastructure, not per-profile.
- Probe correctness is best-effort. `auth_unknown` is a
  legitimate terminal state for providers without a
  no-token health surface. Operators may still hit
  mid-run failures when running under `auth_unknown` —
  this is documented behavior, not a regression to fix
  by relaxing the probe rules.
- Provider adapter additions (DeepSeek, OpenAI direct,
  etc.) now have a higher initial cost: they need a
  readiness probe + remediation text before they can be
  used as a real provider, not just an experimental
  flag. This is intentional.

## 7. What this ADR explicitly does NOT decide

- **CLI surface.** Whether the readiness command is `cap
  doctor`, `cap provider doctor`, both, or something else,
  is design surface — see
  `PROVIDER-ONBOARDING-MEMO.md` §"Target First-Run UX"
  and `PROVIDER-READINESS-TASKS.md` P1.
- **State storage.** Whether readiness results are cached
  on disk, recomputed every run, or both, is implementation
  detail.
- **Probe implementations per provider.** The probe rules
  bind the behavior space; the per-provider probe code
  (e.g. how exactly Claude or Codex is asked "are you
  authed?") is downstream work tracked in
  `PROVIDER-READINESS-TASKS.md` P2.
- **First-run UX wording.** Installer completion text,
  README first-use path, doctor output format — all
  tracked in `PROVIDER-READINESS-TASKS.md` P3.
- **Cost-aware provider selection.** Routing by
  cheapest-suitable-provider, fallback policies, usage
  budgets — explicitly deferred per
  `PROVIDER-READINESS-TASKS.md` P4 ("Not a P0 readiness
  requirement.").
- **The eventual second one-shot evidence run.** This ADR
  raises a precondition for that run; it does not
  authorize the run.
- **Any retroactive renaming.** `cap provider doctor`
  exists today (`scripts/cap-provider.sh:5`); its
  current behavior is `PATH`-only. Extending it is in
  scope for the implementation track; renaming it is
  not.

## 8. Freeze status

Convergence memo §6 freeze line remains in force. ADR-1
remains in force. ADR-2 remains in force. This ADR adds:

- A new **priority ranking**: provider readiness work
  (the `PROVIDER-READINESS-TASKS.md` track) is sized
  *above* component-fast follow-up. Specifically, the
  second one-shot evidence run authorized in ADR-1 Q6
  should NOT be exercised before the readiness boundary
  is implemented at least to the level of
  `PROVIDER-READINESS-TASKS.md` P1 + P2 (doctor +
  workflow preflight).
- A note that the `PROVIDER-READINESS-TASKS.md` track,
  once authorized, may produce code commits that touch
  `scripts/cap-provider.sh`, `scripts/cap-workflow-exec.sh`,
  and possibly `engine/` — but only under separate
  operator authorization per the allow-list. **This ADR
  does NOT authorize any of those code commits.** It
  only ratifies the boundary.

The next operator decision is one of:

- **Open `PROVIDER-READINESS-TASKS.md` P1** — extend
  `cap provider doctor` to report auth readiness
  (read-only, no-token). Smallest first code slice
  compatible with this ADR.
- **Open `PROVIDER-READINESS-TASKS.md` P0 remainder** —
  formalize the readiness JSON shape + state enum as a
  schema artifact (pure docs/schema, no CLI). Mirrors
  ADR-2's args-schema slice pattern.
- **Pure reduction** as always permitted under
  convergence memo §7.

Recommend the P0 remainder first (schema artifact),
mirroring the ADR-2 → P1b-input-1 pattern. That gives
the doctor surface a stable contract to validate against
before any executable code is written, and keeps the
first measurable progress entirely within the docs +
deterministic test allow-list.

— end ADR —
