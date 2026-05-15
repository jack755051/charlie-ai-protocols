# Component Fast Path — Slice 6b Live Dogfood Runbook (2026-05-15)

> Status: pre-run runbook. Owner runs the live dogfood by hand;
> CAP analysis (closeout + threshold judgement) comes after the
> operator pastes back the `cap workflow run` summary and the
> `cap session analyze` output.
> Predecessors landed: P1b slices 1-5 + 6a + 6b-0 + 6b-1 + 6b-2 +
> 6b-prep (all on `main`, last commit `3d64abd`).

## 1. Goal

Validate the Component Fast Path against the five P1a thresholds
laid out in [`docs/cap/COMPONENT-FAST-PATH-MEMO.md`](../../docs/cap/COMPONENT-FAST-PATH-MEMO.md):

| Threshold | Target | Source / measurement |
|---|---|---|
| Wall time | **< 10 min total** | `cap session analyze --run-id <fast-run>` Summary `duration:` line |
| AI step count | **<= 2** | `cap session analyze --json` lifecycle counts for `executor=ai` sessions, or per-step inspection in `result.md` |
| Total prompt bytes | **<= 30% of full pipeline baseline** | `cap session analyze` Summary `total_prompt_bytes:` line. Baseline = the P0b-2 measurement on `run_20260513212143_defe3f1c` (the same `component-feedback-widget` fixture under `project-spec-pipeline` + `project-implementation-pipeline`) |
| Required files generated | **100% match against catalog** | `component-fast-audit.sh` reports `rendered_files_checked: 23` and `result: success` |
| Smoke test exit code | **0** | `scripts/runtime-smoke.sh` last line; recorded as the `smoke_runtime` step's `result` in the workflow log |

Pass on all five = component-fast graduates from "designed and
wired" to "default loop for component dogfood".

Fail on any single one = stop, file under §6 failure log, do not
paper over.

## 2. Preflight checks

All preflight commands are **deterministic / zero token**. None of
them should be skipped on the day of the run.

### 2.1 Binding stays ready (regression guard)

```bash
cap workflow bind component-fast
```

Expected:

```
binding_status: ready
summary: total=7, resolved=7, fallback=0, required_unresolved=0
```

If anything other than `ready` shows up — STOP, go investigate
slice 6b-1 / 6b-0 regressions before running. The corresponding
deterministic test:

```bash
bash tests/scripts/test-component-fast-binding.sh
```

should still print `45 passed, 0 failed`.

### 2.2 Dry-run path stays zero-token

```bash
cap workflow run --dry-run --cli claude component-fast "preflight smoke"
```

Expected: exit 0 + `Binding: ready` block + 7 phases listed +
trailer `Dry run only — no step was executed.`

If dry-run halts or prints `binding_status: degraded` — STOP.

### 2.3 Docker daemon up

```bash
docker info
```

Expected: command exits 0 and the output reports a running daemon
(does NOT print `Cannot connect to the Docker daemon`).

### 2.4 Image pulls (do them BEFORE the timed run)

These pulls can each take minutes and are NOT part of the
component-fast cost we are measuring. Pull them ahead of time so
the timed run sees warm images.

```bash
docker pull postgres:16
docker pull node:20-alpine
docker pull mcr.microsoft.com/dotnet/sdk:8.0
docker pull mcr.microsoft.com/dotnet/aspnet:8.0
```

Image notes:
- `postgres:16` — slice-2 compose has it under the `postgres` profile (gated; only pulled if `--profile postgres` is passed at compose-up time). Pulling pre-emptively is safe; the smoke today does not enable the profile.
- `node:20-alpine` — frontend Dockerfile base image.
- `mcr.microsoft.com/dotnet/sdk:8.0` — backend Dockerfile build stage.
- `mcr.microsoft.com/dotnet/aspnet:8.0` — backend Dockerfile runtime stage.

### 2.5 Target repo state

```bash
cd ~/Desktop/01_private/cap-test/component-feedback-widget
git status
```

Expected: clean working tree (no uncommitted edits that could
confuse the rendered output).

If the repo has earlier `project-spec-pipeline` /
`project-implementation-pipeline` artifacts you want to keep, copy
them to a `dogfood-baseline-2026-05-13/` subdir before the run so
the new fast-path render does not collide with them.

### 2.6 Confirm CAP root state

```bash
cd ~/Desktop/01_private/charlie-ai-protocols
git log --oneline -3
git status
```

Expected: working tree clean, HEAD at `3d64abd` (or later) so
slice 6b-prep templates are present.

```bash
bash tests/scripts/test-component-fast-binding.sh   # 45/45
bash tests/scripts/test-component-fast-dry-run.sh   # 28/28
```

If any deterministic gate fails locally, do NOT proceed to live
dogfood. Fix or revert the offending change first.

## 3. Live run

Once §2.1 through §2.6 are all green, run the live dogfood:

```bash
cd ~/Desktop/01_private/cap-test/component-feedback-widget

cap workflow run --cli claude component-fast \
  "<the same component-feedback-widget prompt used in the
   2026-05-13 baseline dogfood — see
   development-records/dogfood/component-feedback-widget-2026-05-13.md
   for the canonical text>"
```

Use the **same prompt** the P0b baseline used. If the prompt is
different, the prompt-bytes threshold is not directly comparable.

The CLI will print a run id when the run begins. Capture it; you
need it for §4 analysis.

While the run is in flight: leave the terminal alone. The
`smoke_runtime` step runs `docker compose up -d --build`, so the
first time on a host it will take 30-90s while docker assembles
the backend + frontend images from the rendered Dockerfiles.

Expected step sequence (matches slice 5 workflow YAML):

```
Phase 1/7   resolve_inputs      shell
Phase 2/7   render_skeleton     shell    (writes 23 files)
Phase 3/7   deterministic_audit shell    (audit on rendered tree)
Phase 4/7   smoke_runtime       shell    (docker compose up + probes + down)
Phase 5/7   compact_review      ai (watcher)
Phase 6/7   fix_or_polish       ai (backend) — skipped if compact_review verdict=pass
Phase 7/7   archive             shell    (result.md + workflow-result.json)
```

## 4. Post-run analysis

Replace `<fast-run>` with the run id you captured.

### 4.1 Quick view

```bash
cap workflow inspect <fast-run>
```

Look at the Summary / Failures / Steps blocks. Note the wall time
on the run header.

### 4.2 Cost report

```bash
cap session analyze --run-id <fast-run>
```

This is the P0b-2 sparse view. It emits the Summary / Hotspots /
Decision Signals sections. Capture stdout into a file:

```bash
cap session analyze --run-id <fast-run> > \
  /tmp/component-fast-6b-analyze-$(date +%Y%m%d-%H%M%S).txt
```

Paste that file path back into the closeout so the threshold
table can be filled in.

### 4.3 Per-step verbose (only if a threshold fails)

```bash
cap session analyze --run-id <fast-run> --verbose
```

Surfaces the original detailed tables (lifecycle / by_provider /
by_capability / Top Steps By X / etc.) so a failure root cause can
be traced to a specific phase.

## 5. Threshold table (fill in after run)

| Threshold | Target | Observed | Pass? | Source |
|---|---|---|---|---|
| Wall time | < 10 min (600s) | _____ | _____ | Summary `duration:` line |
| AI step count | <= 2 | _____ | _____ | Summary `sessions:` + lifecycle breakdown |
| Total prompt bytes | <= 30% × <baseline> = _____ | _____ | Summary `total_prompt_bytes:` line |
| Required files | 100% (23/23) | _____ | _____ | audit step `rendered_files_checked:` |
| Smoke exit | 0 | _____ | _____ | `smoke_runtime` step `smoke_exit_code:` |

Baseline numbers (from `development-records/dogfood/component-feedback-widget-2026-05-13.md`
+ commit `e7ca9ad`-era P0b-2 reports):

- Full pipeline implementation alone: **44m 25s (2665s)** wall.
- Full pipeline AI step count: roughly **10** AI sessions.
- Full pipeline prompt bytes: pull from
  `cap session analyze --run-id run_20260513212143_defe3f1c` if
  the run dir still exists; otherwise re-baseline from the latest
  `run_20260513*` artifact.

If any cell in the table is missing data (e.g. baseline run was
already archived / pruned), say so explicitly in the closeout
instead of guessing.

## 6. Failure log

If anything halts or any threshold misses, append rows BEFORE
attempting any fix. The log row IS the unit of work for the next
slice.

| Phase | Symptom | Root cause | Classification | Next fix |
|---|---|---|---|---|
| _____ | _____ | _____ | _____ | _____ |

Classification enum (pick exactly one per row):

- `cap_bug` — CAP itself wrote the wrong shape (workflow / capability / runtime).
- `template_bug` — Component Fast Path templates need a fix (registry / source files).
- `environment_bug` — host docker / port / image issue.
- `provider_behavior` — Claude / Codex emitted something the contract did not anticipate.
- `prompt_drift` — operator passed a different prompt from the baseline (invalidates threshold comparison; not a CAP failure).

## 7. Stop conditions

Do NOT proceed past a section if any of the following hits:

1. `cap workflow bind component-fast` does not print `binding_status: ready` — STOP at §2.1.
2. `cap workflow run --dry-run` exits non-zero or shows `binding_status: degraded` — STOP at §2.2.
3. `docker info` reports "Cannot connect to the Docker daemon" — STOP at §2.3.
4. Target repo at `~/Desktop/01_private/cap-test/component-feedback-widget` has uncommitted edits you have NOT acknowledged — STOP at §2.5 and decide whether to stash, commit, or copy aside.
5. Image pull from §2.4 hangs (no progress for > 60s on the same layer) — STOP, do not let the timed run absorb the pull time. Re-run the pull separately, then resume.
6. `cap session analyze --run-id <fast-run>` shows `total_duration_seconds` close to the timeout limit of any single step — this is a hint the step is being killed by `timeout_seconds:` rather than completing; treat as a §6 row before reading the threshold table.

## 8. After the run

Whether the dogfood passes or fails, the closeout slice writes:

1. A new `development-records/dogfood/component-fast-6b-closeout-2026-05-15.md`
   (or whatever the actual run date is — use the day the run completed)
   carrying:
   - The filled §5 threshold table.
   - Any §6 failure log rows.
   - A one-paragraph verdict: did component-fast graduate to default loop, or which threshold blocked.
   - Pointers to the run dir (`~/.cap/projects/<id>/reports/workflows/component-fast/<run-id>/`)
     so future analyses can re-read the same artifacts.

2. If the dogfood passes all five thresholds, the closeout also:
   - Updates `docs/cap/COST-OPTIMIZATION-MEMO.md` P1 row from
     "implementation pending" to "shipped" with the run date.
   - Opens the discussion of switching the default Component Repo
     dogfood loop from `project-spec-pipeline` +
     `project-implementation-pipeline` to `component-fast` (a
     separate slice; not assumed by this runbook).

3. If the dogfood fails on any threshold, the closeout:
   - Documents the failure mode in plain text.
   - Lists the smallest next slice that closes it.
   - Does NOT relax the threshold without explicit operator
     decision in writing.

## 9. Out of scope for this runbook

- Multi-component combinations (multi-feedback-widget per repo).
- Codex parity (only Claude exercised today).
- Skill registry tightening beyond the slice 6b-1 mapping.
- Provider real-token extraction (still gated to P0d).
- Phase progress-bar token aggregate display.

These all stay deferred until the first successful 6b dogfood
proves the substrate, after which their priorities can be
re-weighted against real cost evidence.
