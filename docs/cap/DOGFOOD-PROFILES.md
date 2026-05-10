# CAP Dogfood Profiles

> Status: active boundary for practical CAP testing.
> Purpose: keep runtime work grounded in a small set of repeatable repo shapes.

## Decision

CAP dogfood starts with **dockerized frontend/backend software repos**. The first full automation target is one primary stack, while other common stacks are compatibility targets until real evidence justifies expansion.

```text
Primary stack:
  Next.js + C#/.NET + PostgreSQL + Docker Compose

Compatibility stack A:
  Nuxt + Node/NestJS

Compatibility stack B:
  Angular + Java/Spring Boot
```

This does not mean CAP will never support other stacks. It means Phase-level runtime changes must first prove they work on the primary stack before adding framework-specific branches.

## Primary Component Runtime Profile

Component Repo dogfood defaults to a single golden path until the
implementation pipeline can reliably produce code and tests:

```yaml
profile: component-repo
stack: primary
frontend:
  framework: nextjs
  version_floor: "14"
backend:
  framework: dotnet
  version_floor: "8"
database:
  engine: postgresql
  version_floor: "16"
runtime:
  orchestrator: docker-compose
  compose_spec: "v2"
```

The default is intentionally narrow. Specification, implementation, QA,
DevOps, and runtime-smoke prompts should assume this stack unless the task
constitution explicitly selects a supported compatibility stack. A
compatibility stack may be used for intake, diagnosis, or planning, but it
does not replace the primary stack until it has equivalent dogfood evidence.

Runtime validation for this profile must prove, at minimum:

- `docker compose build` succeeds.
- `docker compose up` launches PostgreSQL, backend, and frontend services.
- Backend exposes a health endpoint that proves database reachability.
- Backend exposes at least one API contract endpoint from the generated spec.
- Frontend serves HTTP from the host and can reach the backend server-side.
- A repo-local smoke script records the checks and exits non-zero on failure.

## Profiles

### 1. Component Repo

Goal: small reusable feature / component repo.

Initial stack:

```text
Next.js frontend component
C#/.NET backend package or small API module
PostgreSQL persistence when backend state exists
Docker Compose runtime
```

Acceptance:

- `cap project init`
- `cap project doctor`
- `cap workflow run project-constitution`
- `cap workflow run project-spec-pipeline`
- `cap workflow run project-implementation-pipeline`
- `cap workflow run project-qa-pipeline`
- `cap promote inspect`
- repo-local runtime smoke for the Primary Component Runtime Profile

Use this first because failures are easier to attribute.

Current gate after the 2026-05-10 Component Repo closeout:

- Frontend / Backend implementation steps must apply the Component Repo
  sections in `agent-skills/04-frontend-agent.md` and
  `agent-skills/05-backend-agent.md`.
- Do not advance a Component Repo run from Phase D to Phase E only because
  `project-implementation-pipeline` reports `completed / success`.
- Phase D must prove actual implementation artifacts exist on disk, not only
  non-empty AI stdout. This depends on the AI step result contract and the
  separate AI write contract.
- Phase F runtime smoke may validate an operator-authored skeleton, but that
  does not count as CAP-produced implementation evidence.
- Re-run Phase E only after Phase D has produced real frontend, backend,
  deployment, and test artifacts under the agreed write contract.

### 2. Maintenance Repo

Goal: existing repo intake for bugfix / feature / refactor work.

Allowed stacks:

```text
Primary stack
Nuxt + Node/NestJS
Angular + Java/Spring Boot
```

Acceptance:

- detect stack
- summarize architecture
- identify build / test commands
- create task constitution
- plan minimal change
- run discovered tests when safe

Non-goal: full autonomous implementation across every framework. Maintenance dogfood should prove CAP can understand and plan safely before it edits broadly.

### 3. Product Repo

Goal: complete frontend/backend product repo.

Initial stack:

```text
Next.js + C#/.NET + PostgreSQL + Docker Compose
```

Acceptance:

- project constitution
- spec pipeline
- implementation pipeline
- QA pipeline
- Dockerized local run
- promote candidate inspection
- release-gate smoke before tagging

Use this after Component Repo and Maintenance Repo expose enough baseline evidence.

## Scope

In scope for first dogfood cycle:

- web software repos
- frontend + backend
- Dockerized local development
- task-driven maintenance and feature work
- monorepo or split repo, if the primary stack remains recognizable

Out of scope until explicit dogfood evidence appears:

- mobile apps
- data pipelines
- plugin marketplace / extension platform
- non-web desktop apps
- first-class full implementation for every framework

## Runtime Implication

Do not start broad runtime work, including Role / Skill attachment runtime, unless the change can be validated against at least one dogfood profile above.

Phase 5 Role / Skill attachment may start only when its first vertical slice is scoped to:

```text
Component Repo or Product Repo
Primary stack
capability -> selected role -> attached skills
legacy binding fields preserved
no agent-skills directory move
```

Compatibility stacks should remain intake / diagnosis / planning targets until the primary stack path is stable.
