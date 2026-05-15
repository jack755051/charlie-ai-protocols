# CAP Run Observability — Phase 5 Later Memo

> Status: planning memo (deferred items)
> Scope: Phase 5 backlog items #4–#6 — provider raw output capture, background `run -d`, TUI / dashboard.
> Sibling docs:
> - [`RUN-OBSERVABILITY-MEMO.md`](RUN-OBSERVABILITY-MEMO.md) — original 4-phase roadmap (Phase 1–4 shipped v0.24.3 → v0.24.5).
> - [`RUN-OBSERVABILITY-GUIDE.md`](../../docs/cap/RUN-OBSERVABILITY-GUIDE.md) — user-facing operations guide for what is currently shipped.
> - [`CHANGELOG.md`](../../CHANGELOG.md) §v0.24.6 — Phase 5 read-only filters that *did* ship.

## Recap

The original `RUN-OBSERVABILITY-MEMO.md` listed four Phases. Phases 1–4 shipped in `v0.24.3` → `v0.24.5`:

- Phase 1: `cap workflow logs <run-id> [-f]` — docker-like log view.
- Phase 2: `cap workflow watch <run-id>` — live snapshot view.
- Phase 3: `cap workflow logs --step <step-id>` — per-step provider output via `raw.log → md → handoff.md` fallback.
- Phase 4: status glyphs, `Next:` dashboard footer, `--compact`, `inspect` follow-up hints.

After Phase 4 the discovered backlog grew six items (the user numbering from the Phase 5 brief):

| # | Item | Status as of v0.24.6 |
|---|---|---|
| 1 | `watch --failed-only` | ✓ shipped (v0.24.6) |
| 2 | `watch --step <step-id>` | ✓ shipped (v0.24.6) |
| 3 | `logs --since <value>` | ✓ shipped (v0.24.6) |
| 4 | Provider raw output capture (stderr) | **deferred — this memo** |
| 5 | Background run `-d` | **deferred — this memo** |
| 6 | TUI / web dashboard | **deferred — this memo** |

Items 1–3 were classified as "read-only filter" — low risk, render / parse layer only. Items 4–6 touch `cap-workflow-exec.sh` runner, the process model, or pull a UI framework into the CAP repo. They are *not* the same shape as the first three, so they live here in their own memo instead of being lumped in.

This memo captures the design discussion **without committing to implementation**. Implementation requires either a real dogfood pain point (#4, #5) or a deliberate scope expansion of CAP itself (#6).

## Item #4 — Provider raw output capture (stderr)

### Background

Phase 3 inventoried the v0.22+ run directory layout and found `<phase>-<step>.raw.log` files were stale: identical byte size to `<phase>-<step>.md`, last produced around April 24. The `cap-workflow-exec.sh` writer that emitted them had been removed during a runtime simplification. v0.24.3 chose **not** to revive the writer — the inventory showed `raw.log` was a redundant byte-level dup of `.md`, providing no extra information.

The Phase 3 fallback chain (`raw.log → md → handoff.md`) honours legacy `raw.log` files when present but does not regenerate them.

### What's actually missing today

The `.md` files capture the provider CLI's **stdout** stream (via `materialize_step_output`). What is *not* captured anywhere stable:

- Provider CLI **stderr** — reasoning traces, schema validation warnings, "still thinking..." progress lines, transient HTTP 429 / network retry messages.
- Schema validation context — when `validate-constitution.sh` halts at `multiple_explicit_fences`, the operator sees the exit code and `error_type` summary in `workflow.log` but not the raw stderr lines that explain why the fence count was 2/2.
- Provider-specific debug output — for example Codex's `--debug` mode writes additional protocol details to stderr that today vanish.

When debugging schema validation halts, fence-shape regressions, or unexpected fallback behaviour, this missing stderr stream is the single biggest gap in observability.

### Options

| Option | Description | Outcome |
|---|---|---|
| A | Capture stdout only and write to `<phase>-<step>.raw.log` | **0 net value** — same content as `.md`. Already rejected in v0.24.3. |
| **B** | **Capture stdout + stderr separately to `<phase>-<step>.stdout.log` and `<phase>-<step>.stderr.log`** | **High value** — closes the stderr gap. Cost: edit `run_step_claude` / `run_step_codex` / `run_shell_step` in `cap-workflow-exec.sh` to use `2> >(tee ...)` process substitution. |
| C | Combined stream `<phase>-<step>.raw.log` (stdout + stderr interleaved with `2>&1`) | Medium value but throws away stdout/stderr distinction. Harder to debug stderr-only patterns. |

### Recommendation

**Option B, gated by dogfood.**

Reasons to wait:
- Touching `cap-workflow-exec.sh` violates the v0.24.x line's explicit "no runner changes" boundary. Crossing the boundary should be triggered by a concrete pain point, not speculation.
- Disk pressure: provider stderr can be very chatty (especially Codex `--debug`); we may want to gate this behind `CAP_CAPTURE_STDERR=1` rather than make it default.
- Bash portability: `2> >(tee path)` works on macOS / Linux bash 3.2+, but interaction with the existing `STEP_TMP` capture and `output_has_executor_fallback_marker` validators needs care.

Reasons to do it eventually:
- Schema-validation halts (`exit 41`) currently leak no provider stderr. The operator must re-run the workflow with extra logging.
- The Phase 4 `# Follow-up` hints already point operators at `cap session inspect`, but the session ledger doesn't carry stderr either.

### Trigger conditions

Any one of the following would justify implementing Option B:

1. A real failed run where the operator could not diagnose the failure from `inspect` / `logs` and needed to re-run with manual stderr redirection.
2. A schema-validation halt where the upstream prompt contract change was not visible in any captured artifact.
3. A repeated request from a CAP user dogfooding a workflow that loses provider warnings.

When triggered, write a design doc covering:
- Process substitution pattern for each `run_step_*` path.
- File naming: `<phase>-<step_id>.stderr.log` (sibling to `.md`).
- Update `_STEP_LOG_FALLBACK_SUFFIXES` in `engine/workflow_cli.py` to include `stderr.log` (probably as a separate flag, not in the default chain — operators ask for it explicitly).
- Add `cap workflow logs --step <id> --stderr` flag.
- Update tests, docs, and the Phase 3 inventory commentary in `RUN-OBSERVABILITY-GUIDE.md`.

## Item #5 — Background run `-d`

### Background

`cap workflow run <id> [prompt]` runs in the foreground. Long workflows (project-spec-pipeline, project-implementation-pipeline) can take many minutes. Operators currently:

- Open a separate terminal to keep using the shell.
- Or wait, blocking the terminal.
- Or use shell-level `&` plus manual `disown` / `nohup` — but lose the run_id / log path attribution because the foreground output is the only place the run identifier surfaces.

The Phase 1–4 observability surfaces (`logs` / `watch` / `inspect`) are designed for an external observer — they read run_dir files and don't depend on the foreground process. So the missing piece is a deliberate `-d` flag that:

1. Detaches the runner.
2. Returns the new `run_id` to stdout immediately.
3. Lets the operator follow up with `cap workflow watch <run-id>` / `cap workflow logs -f <run-id>`.

### Options

| Option | Description | Outcome |
|---|---|---|
| **A** | **`nohup ... & disown`, return run_id; no PID file** | Simple. Works on macOS / Linux. No `cap workflow stop` semantics. Zombies handled by shell. Good first-cut. |
| B | Add `~/.cap/projects/<id>/runs/<run_id>.pid` + `cap workflow stop <run-id>` + `cap workflow ps` flag for backgrounded runs | Full. Needs signal-handling design (SIGTERM cascade to children, SIGHUP, atexit cleanup). |
| C | Use `systemd-run` (Linux) / `launchctl` (macOS) | Over-engineered. Cross-platform is brittle. Rejected. |

### Recommendation

**Option A first, B reserved.**

A is small enough to ship in a single commit:

```bash
case "$1" in
  -d|--detach)
    DETACH=1
    shift
    ;;
esac
# ... resolve workflow + create run entry as today ...
if [ "${DETACH}" -eq 1 ]; then
  nohup bash "${SCRIPT_DIR}/cap-workflow-exec.sh" "${PLAN_JSON}" "${USER_PROMPT}" --run-id "${RUN_ID}" \
    >/dev/null 2>&1 < /dev/null &
  disown
  echo "${RUN_ID}"  # so operators can pipe: RUN=$(cap workflow run -d ...)
  echo "Detached. Follow with: cap workflow watch ${RUN_ID}"
  exit 0
fi
```

But A leaves three known gaps:
- No `cap workflow stop` — operators must `kill -TERM <pid>` themselves.
- No backgrounded-run highlight in `cap workflow ps` — the `state` column shows `running` either way; no `-d` marker.
- No PID file means restart-after-reboot detection is impossible.

When B is needed (any operator hitting the gaps above), upgrade by:
- Writing `~/.cap/projects/<id>/runs/<run_id>.pid` from the detached child.
- Adding `cap workflow stop <run-id>` that reads the PID file and sends SIGTERM (with SIGKILL fallback after a timeout).
- Adding `--detached` column / glyph to `cap workflow ps`.
- Cleaning the PID file on graceful exit (atexit hook in `cap-workflow-exec.sh`).

### Pre-requisite

**Option A should ship _after or with_ Item #4 Option B.** A backgrounded run that loses provider stderr is harder to debug than a foreground run that loses stderr — at least the foreground operator can read the terminal in real time. If we ship `run -d` first without stderr capture, we measurably worsen the debug experience for the same set of bugs that motivate #4.

So the sequence is: **#4 → #5(A) → #5(B) when needed**.

### Trigger conditions

1. A specific operator pain — "I keep opening new terminals because my workflow takes 10 minutes."
2. A CI / scripting use case — "I want to fire a workflow from a hook and not block."
3. Provider stderr capture (#4) shipped, so backgrounded runs don't lose information.

## Item #6 — TUI / web dashboard

### Background

Once `watch --json` exposes a structured snapshot per refresh and `inspect --json` emits a schema-conforming workflow-result object, an obvious next ask is: "where's the dashboard?"

### Decision

**Not in CAP repo.**

### Rationale

| Option | Why not |
|---|---|
| A. Built-in TUI (textual / blessed) | Drags a GUI framework dep into a Python+bash CLI repo. UX maintenance ties into terminal compatibility matrix (tmux, iTerm2, Windows Terminal, WSL). Out of CAP's scope. |
| B. Bundled web dashboard (FastAPI + frontend) | Conflicts with EBE / Tauri tooling already in the user's stack. CAP would have two GUI surfaces to maintain. |
| **C. Third-party consumes `--json`** | **Right answer.** v0.24.3+ exposes everything a dashboard needs through `cap workflow watch --json`, `cap workflow inspect --json`, plus the stable `runtime-state.json` / `agent-sessions.json` / `workflow-result.json` schemas. Anyone (including the user's own EBE / Tauri tooling) can build a dashboard that reads these files without CAP shipping a UI. |

### What CAP commits to (for dashboard authors)

- `cap workflow watch --json` payload shape (top-level `workflow_id` / `run_id` / `final_state` / `summary` / `steps` / `sessions` / `artifacts` / `last_log_lines` / `_filter_failed_only` / `_filter_step_id`).
- `runtime-state.json`, `agent-sessions.json`, `workflow-result.json` schema (validated against `schemas/workflow-result.schema.yaml`).
- Status glyph mapping (`✓ ok` / `● running` / `○ pending` / `✗ failed` / `⊘ skipped` / `◐ blocked` / `⊠ cancelled` / `? unknown`) — documented in `cap help observe` and `RUN-OBSERVABILITY-GUIDE.md`.
- `--cap-home PATH` for cross-repo / sandbox observation.

These are stable surfaces; breaking changes go through CHANGELOG / RELEASE-NOTES / annotated tag like every other release.

### What CAP does NOT commit to

- Bundled GUI of any kind.
- A WebSocket / SSE push channel for live updates (the json polling cadence is the intended consumption pattern).
- Authentication / multi-user dashboard primitives.

### Trigger that could revisit this decision

Practically: **none currently planned.** If a future change makes consuming `--json` for a dashboard clearly impossible (e.g., we add a streaming-only payload that can't be polled), the decision is automatically revisited then. Until then, defer.

## Next-step trigger summary

| Trigger | Implements |
|---|---|
| Real stderr-only debug pain on a failed run | #4 (Option B) |
| Long-workflow-blocks-terminal pain + #4 done | #5 Option A |
| #5 Option A operators can't `stop` a runaway run | #5 Option B |
| GUI need from operators | **Build outside CAP** using `--json` surface |

## Why no ADR yet

ADRs in this repo (`docs/cap/adr/...`) record **architectural decisions that are hard to reverse**. The decisions in this memo are:

- #4 / #5: deliberately *deferred*, not decided. Implementation is pending a real trigger; the memo captures the candidate options so future-us doesn't re-derive them.
- #6: a "not now" decision. If we wanted to make "no TUI in CAP repo" architectural-and-binding, an ADR would be appropriate. But the third-party `--json` path makes the boundary self-policing — a TUI PR would have to argue why `--json` is insufficient, and that argument can happen at PR review time without a pre-emptive ADR.

If a future PR proposes adding `textual` / `blessed` / `fastapi` as a dependency for a built-in dashboard, **that** would be the moment to write the ADR (declining the change).

## Cross-links

- [`RUN-OBSERVABILITY-MEMO.md`](RUN-OBSERVABILITY-MEMO.md) — Phase 1–4 planning history.
- [`RUN-OBSERVABILITY-GUIDE.md`](../../docs/cap/RUN-OBSERVABILITY-GUIDE.md) — operations guide for shipped surfaces.
- [`ARCHITECTURE.md`](../../docs/cap/ARCHITECTURE.md) — runtime module map (where `cap-workflow-exec.sh` and the run_dir live).
- [`SUPERVISOR-ORCHESTRATION-BOUNDARY.md`](SUPERVISOR-ORCHESTRATION-BOUNDARY.md) — handoff ticket / agent session storage rules (the schemas a dashboard would consume).
