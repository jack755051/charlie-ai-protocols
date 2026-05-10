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

## Profiles

### 1. Component Repo

Goal: small reusable feature / component repo.

Initial stack:

```text
Next.js frontend component
C# backend package or small API module
Docker / devcontainer optional, Docker Compose preferred when backend exists
```

Acceptance:

- `cap project init`
- `cap project doctor`
- `cap workflow run project-constitution`
- `cap workflow run project-spec-pipeline`
- `cap workflow run project-implementation-pipeline`
- `cap workflow run project-qa-pipeline`
- `cap promote inspect`

Use this first because failures are easier to attribute.

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
