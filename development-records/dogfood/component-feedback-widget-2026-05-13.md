# Component Feedback Widget Dogfood Log — 2026-05-13

> Status: live dogfood log.
> Subject: `~/Desktop/01_private/cap-test/component-feedback-widget`.
> Goal: exercise CAP project-constitution and follow-on component repo workflows against a reusable feedback widget component.

## Target Constitution

The intended project constitution should preserve these inputs:

- `project_id`: `component-feedback-widget`
- repo type: Component Repo, not a full product
- primary stack: Next.js 14, C#/.NET 8, PostgreSQL 16, Docker Compose
- frontend adapter: shadcn-ui + Tailwind CSS + Lucide
- backend core: `IFeedbackStore`
- default storage: `InMemoryFeedbackStore`
- PostgreSQL scope: integration-runtime only
- explicit exclusion: do not add Redis
- all ports and endpoints must be env/config driven, not hardcoded
- component template contract: component-core, component-frontend (`frontend-core`, `frontend-ui`), component-backend, component-demo, integration-runtime; async-runtime optional but unused

## Failure Log

| # | Time | Command / phase | Symptom | Root Cause | Status / Follow-up |
|---:|---|---|---|---|---|
| 1 | 2026-05-13 09:05–09:10 Asia/Taipei | `cap workflow run --cli claude project-constitution ...` pre-run / binding | `cap-paths: project_id collision detected`, resolved id was `project-constitution-bootstrap`, ledger origin was `charlie-ai-protocols`, current origin was `component-feedback-widget` | `scripts/cap-workflow.sh` forced `CAP_PROJECT_ID_OVERRIDE=project-constitution-bootstrap` for every `project-constitution` run when no explicit override was present. That made real dogfood repos collide with a historical bootstrap ledger instead of using their own git basename / config id. | Fixed locally in `scripts/cap-workflow.sh`: only fall back to bootstrap id when `cap-paths get project_id` exits 52. Added regression to `tests/scripts/test-cap-workflow-static-outside-project.sh`. |
| 2 | 2026-05-13 09:19 Asia/Taipei | Phase 2 `normalize_outline` | Claude step was killed after 241s with `step exceeded the hard execution limit of 240s` | Workflow step timeout is too tight for long component-constitution prompts under Claude. This is a runtime tuning / workflow contract issue, not a project_id or constitution-content issue. | Open follow-up: raise `normalize_outline.timeout_seconds` for `project-constitution`, or run dogfood with `CAP_WORKFLOW_STEP_TIMEOUT_SECONDS=600` until the workflow default is tuned. |

## Immediate Workarounds

For the next dogfood attempt, use a higher per-step timeout:

```bash
CAP_WORKFLOW_STEP_TIMEOUT_SECONDS=600 \
cap workflow run --no-design --cli claude project-constitution "<prompt>"
```

If a run leaves partial local output in the dogfood repo, remove only the failed runtime residue after checking it:

```bash
rm -rf project-constitution/
```

## Current CAP Fixes Not Yet Version-Controlled

- `scripts/cap-workflow.sh`
  - Stops forcing the bootstrap project id for `project-constitution` inside real git repos.
- `tests/scripts/test-cap-workflow-static-outside-project.sh`
  - Reproduces a colliding bootstrap ledger and asserts a dogfood git repo uses its own project id.

## Dogfood Policy

Every failed attempt on this repo should append one row to `Failure Log` before retrying. Include:

- timestamp
- command or phase
- observable symptom
- suspected root cause
- whether it is user environment, provider behavior, workflow tuning, or CAP correctness bug
- workaround or required fix
