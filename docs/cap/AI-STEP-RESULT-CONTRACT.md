# AI Step Result Contract (v0.26.0)

> Status: normative.
> Scope: defines the structured `result:` marker every AI sub-agent step must
> emit at the end of its handoff summary, and the parser / workflow runtime's
> contract for interpreting it.
> SSOT for: `engine/ai_step_result_parser.py`,
> `scripts/cap-workflow-exec.sh` (post-step parse hook), and
> `agent-skills/00-core-protocol.md` §5.3 (handoff format requirements).

## Why this contract exists

Pre-v0.26.0 the workflow runtime treated **non-empty stdout** as a successful
step. AI agents that detected at runtime they could not complete their
deliverable (read-only filesystem, missing upstream artifact, schema fence
violations) would gracefully self-report a blocked / failed state inside their
markdown body, but the runtime did not parse that report — `final_state`
rolled up to `completed / success` regardless. See bug #12 in
`docs/cap/COMPONENT-REPO-DOGFOOD-2026-05-10.md`.

This contract closes that gap: AI agents emit one machine-readable line; the
parser maps it to a normalized state enum; the workflow halts on anything
other than success.

## The contract

Every AI sub-agent step MUST end its captured stdout with a handoff summary
that includes a `result:` line as one of its required fields. The line:

- Appears in the step's captured stdout (which the runtime writes to
  `<run_dir>/<phase>-<step_id>.md`).
- Is on its own line.
- Uses either an ASCII colon (`:`) or a CJK fullwidth colon (`：`).
- May or may not be prefixed with `-` / `* ` (markdown list bullet) or
  with whitespace.
- Carries one of the **four normalized values** defined below; aliases are
  accepted and normalized at parse time.

### Normalized values

| Normalized | Aliases (case-insensitive) | Workflow behaviour |
|---|---|---|
| `success` | `success`, `ok`, `成功`, `completed`, `done`, `pass`, `passed` | step OK; continue to next step |
| `failed` | `failed`, `failure`, `fail`, `error` | step failed; record_blocked_step + break loop (existing failure handling) |
| `blocked` | `blocked`, `blocked_*` (any suffix), `[BLOCK]` (any content), `FAIL_BLOCKED*`, `read_only`, `read-only` | step blocked by environment / contract / upstream; record_blocked_step + break loop |
| `needs_data` | `needs_data`, `needs-data`, `requires_data`, `incomplete`, `missing_inputs` | step refused to produce output because inputs were insufficient; record_blocked_step + break loop |

Anything that does not match one of these aliases (case-insensitive,
substring-tolerant for `blocked_*` / `[BLOCK]` / `FAIL_BLOCKED*` patterns)
is normalized to **`unknown`**. `unknown` is treated as `failed` by the
workflow — the step did not honor the contract, and a non-honored contract
is itself a failure signal.

### The line-level grammar

```
result_line  := bullet? whitespace* "result" colon whitespace* value comment?
bullet       := ("-" | "*") whitespace+
colon        := ":" | "："
value        := non-whitespace token (may contain underscore, hyphen, brackets)
comment      := whitespace* (any trailing text — ignored by parser)
```

Parser scans the file from end to beginning to find the **last** `result_line`
occurrence (some agents emit `result:` keys inside upstream-artifact tables in
their reasoning section; only the trailing handoff summary's `result:` is
authoritative).

### Examples

All of these parse to `success`:

```
result: success
- result: success
- result：成功
result：ok
- result: completed
*  result: passed
```

All of these parse to `blocked`:

```
result: blocked_read_only
- result：blocked
result: [BLOCK] FAIL_BLOCKED_UPSTREAM
- result: FAIL_BLOCKED_READ_ONLY_UPSTREAM_IMPLEMENTATION_MISSING
result：read-only
```

All of these parse to `failed`:

```
result: failed
- result: FAIL
- result：failure
result: error
```

These parse to `needs_data`:

```
result: needs_data
- result: needs-data
- result：incomplete
```

These parse to `unknown` (treated as `failed`):

```
result: archive_completed_stdout_closed_with_blockers
- result: maybe_ok
result：??
(no result line at all)
```

## Workflow runtime behaviour

`scripts/cap-workflow-exec.sh` calls
`engine/step_runtime.py parse-step-result <step_output_path>` immediately
after each AI step's stdout is captured. The parser writes one of:

```
state=success
state=failed
state=blocked
state=needs_data
state=unknown
```

to stdout (single-line, key=value form for shell consumption).

The shell wrapper then:

| Parsed state | Action |
|---|---|
| `success` | `step_status ok`, `register_step_runtime_state validated`, continue loop |
| `failed` | `record_blocked_step "ai_self_reported_failure"`, `register_step_runtime_state failed`, break loop |
| `blocked` | `record_blocked_step "ai_self_reported_blocked"`, `register_step_runtime_state blocked`, break loop |
| `needs_data` | `record_blocked_step "ai_self_reported_needs_data"`, `register_step_runtime_state blocked`, break loop |
| `unknown` | `record_blocked_step "ai_step_result_unparseable"` (with detail of last 3 lines of stdout), `register_step_runtime_state failed`, break loop |

The break-loop branches surface a deterministic, non-zero exit at the
workflow level, so `final_state` rolls up to `failed` instead of the
pre-fix `completed`.

## What this contract does NOT do

- **It does not enable AI write access to project_root.** That is a
  separate design item (Round 2 of the v0.26.x series — the "AI write
  contract"). The result contract here only fixes the **runtime's
  perception of step outcome**; it does not change what AI can or cannot
  produce. After the result contract lands, an AI step that cannot write
  code due to read-only filesystem will correctly report `blocked` and
  the workflow will correctly halt — instead of the current "everything
  PASSes but no code exists" hallucination.
- **It does not relax `ApiResponse<T>`-style structured outputs.** AI
  agents that emit JSON / YAML inside their markdown (e.g., task
  constitution drafts, project constitution drafts) keep the existing
  fence rules (`<<<TASK_CONSTITUTION_JSON_BEGIN>>>` etc.). The result
  marker is one additional line at the end of the markdown, not a
  replacement for any existing structured emission.
- **It does not change handoff ticket validation.** The Type C / Type D
  handoff schemas remain authoritative for the cross-step contract; the
  result contract is specifically for the **single-step outcome
  signalling** the workflow runtime needs to halt on.

## Test coverage

`tests/scripts/test-ai-step-result-parser.sh` (added in v0.26.0):

- Each normalized value's primary spelling parses correctly.
- Each declared alias parses to the expected normalized value.
- Both colon styles (`:` / `：`) parse identically.
- `-` / `*` / no-bullet line styles all parse.
- Multi-line files: only the last `result:` occurrence wins.
- Files with `result:` inside `<<<...JSON...>>>` fences are not picked
  up by the parser (parser scans outside JSON fences).
- Files with no `result:` line return `state=unknown`.
- Trailing comments after the value are ignored.
- Workflow integration smoke: a sandboxed `cap workflow run` whose AI
  step emits `result: blocked_read_only` results in `final_state=failed`
  + a `record_blocked_step` entry — not the pre-fix `final_state=completed`.

## Migration path for existing AI agents

Agents already follow the handoff format documented in
`agent-skills/00-core-protocol.md` §5.3. The v0.26.0 update to that file
locks the `result:` enum; existing agents that emit `result: success`
(the most common spelling) keep working unchanged. Agents that emit
non-aliased values now correctly surface as `unknown` (which the workflow
treats as `failed`) — this is a behavioural break, but it is the **fix**
to bug #12, not a regression. The original Phase D run that exposed bug
#12 had every step emit a non-aliased `result:` value (e.g.
`blocked_read_only`); the new parser maps those to `blocked`, and the
workflow now halts honestly.

## Design rationale

- **Why scan from end of file?** Agents emit `result:` in reasoning tables
  earlier in their markdown (e.g. "the upstream's `result: ok` field
  shows..."). The handoff summary's `result:` is the last one and is
  authoritative.
- **Why allow both colons?** Agents working in zh-Hant alternate between
  ASCII and fullwidth punctuation; locking to one would force a churn pass
  across the agent prompt corpus that adds zero signal.
- **Why normalize aliases instead of locking to one spelling?** Agents
  trained / prompted in different stages emit different spellings; the
  observed value space already includes `success` / `成功` / `ok`. A
  strict-spelling lock would just regress to "AI emits the wrong word →
  workflow says failed even though step succeeded". Aliases give us
  forgiveness on the success path; the failure path is intentionally
  permissive (any `blocked_*` etc. maps to `blocked`) because false
  positives there are safe (workflow halts, operator inspects).
- **Why is `unknown` treated as `failed`?** A step that did not honor the
  contract is itself a contract violation. Better to halt than to silently
  treat a missing result line as success — exactly the bug #12 trap.
