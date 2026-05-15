# CAP Run Observability Memo

> Status: planning memo
> Scope: Docker-like workflow logs/watch surfaces for existing CAP run data.

## Goal

Provide a Docker-like observation layer for CAP workflow runs:

```bash
cap workflow logs <run-id>
cap workflow logs -f <run-id>
cap workflow watch <run-id>
```

The first implementation should be read-only. It should not change AI prompts,
add agent steps, call provider CLIs again, or require additional token usage.

## Current Model

During `cap workflow run ...`, the CAP runner already writes process data into
the run directory:

```text
~/.cap/projects/<project_id>/reports/workflows/<workflow_id>/<run_id>/
  workflow.log
  runtime-state.json
  agent-sessions.json
  run-summary.md
  workflow-result.json
  result.md
```

Foreground runs also stream output to the active terminal. The missing layer is
a dedicated CAP command that can read these files from another terminal and
present them as a live operational view.

## Non-Goals

- No web dashboard in the first pass.
- No background run implementation in this memo.
- No token-by-token provider capture requirement.
- No CPU / memory process monitor.
- No rewrite of `scripts/cap-workflow-exec.sh`.
- No change to prompt templates or provider invocation behavior.

## Design Direction

Add a read-only observer layer:

```text
scripts/cap-workflow.sh
  -> dispatch logs/watch

engine/workflow_observer.py
  -> resolve_run_dir(run_id)
  -> print_logs(run_dir, follow=False)
  -> render_watch(run_dir)
  -> read runtime-state / sessions / summary / workflow.log
```

`cap-workflow-exec.sh` remains the runner. The observer only consumes files the
runner already produces.

## Phase 1: Run Log Follow

Goal: ship the smallest Docker-like logs surface.

Commands:

```bash
cap workflow logs <run-id>
cap workflow logs -f <run-id>
cap workflow logs <run-id> --cap-home PATH
```

Tasks:

- Add `logs` to the `cap workflow` dispatcher.
- Resolve `<run-id>` to the canonical run directory.
- Print `workflow.log`.
- Support `-f` / `--follow` using tail-style behavior.
- Support `--cap-home PATH` for tests and cross-repo inspection.
- Return clear errors for missing run directories and missing `workflow.log`.
- Add focused tests for happy path, missing run, missing log, and follow mode.

Acceptance:

```bash
cap workflow logs run_xxx
cap workflow logs -f run_xxx
```

Both commands work without changing workflow execution or token usage.

## Phase 2: Workflow Watch

Goal: show a refreshed run status view.

Commands:

```bash
cap workflow watch <run-id>
cap workflow watch <run-id> --once
cap workflow watch <run-id> --json
cap workflow watch <run-id> --interval 1
```

Data sources:

- `runtime-state.json`
- `agent-sessions.json`
- `run-summary.md`
- `workflow.log`

Text view should include:

- workflow id / name / run id
- current or final state
- step list and execution state
- session lifecycle / result / provider
- artifact count and latest artifact pointer when available
- last workflow log lines

Tasks:

- Implement `watch --once` first for deterministic tests.
- Add refresh loop after `--once` is stable.
- Add `--json` for scripts and future dashboards.
- Keep rendering tolerant of partially written files.

Acceptance:

```bash
cap workflow watch run_xxx --once
```

Shows a useful state snapshot for both running and completed runs.

## Phase 3: Provider Step Logs

Goal: inspect provider or shell output for a specific step.

Commands:

```bash
cap workflow logs <run-id> --step <step-id>
cap workflow logs -f <run-id> --step <step-id>
```

Candidate data sources:

```text
<run_dir>/<step_id>.raw.log
<run_dir>/<step_id>.md
<run_dir>/<step_id>.handoff.md
```

Tasks:

- Inventory which per-step files are already produced reliably.
- Define precedence for `--step` output.
- Add clear errors for missing step logs.
- If raw log coverage is incomplete, make a small runner-side logging
  completeness patch only after Phase 1 and Phase 2 are stable.

Acceptance:

```bash
cap workflow logs run_xxx --step draft_constitution
```

Shows the best available step-level output without re-running the provider.

## Phase 4: Developer Experience Polish

Goal: make observation commands discoverable and convenient.

Tasks:

- Update `cap workflow inspect <run-id>` to show follow-up commands:

```text
logs:  cap workflow logs <run-id>
watch: cap workflow watch <run-id>
```

- Add `--tail N` to `logs`.
- Consider `--since` only if timestamp parsing is stable enough.
- Add `watch --compact`.
- Add README / docs usage examples after the command behavior is stable.

## Recommended Order

1. Phase 1: `cap workflow logs <run-id> [-f]`
2. Phase 2: `cap workflow watch <run-id> --once`
3. Phase 2: refresh loop for `watch`
4. Phase 3: `logs --step`
5. Phase 4: inspect hints, flags, and docs

## Risk Notes

- `logs` and `watch` should not add token cost because they only read local
  files.
- `watch` must tolerate files being updated while read.
- Provider raw output follow should wait until existing per-step log coverage
  is inventoried.
- Background run support is a separate project and should not block this memo.
