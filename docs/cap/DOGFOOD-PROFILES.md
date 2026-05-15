# CAP Dogfood Profiles

> Status: reset on 2026-05-15.
> Product boundary: [CAP-POSITIONING.md](CAP-POSITIONING.md).

## Purpose

Dogfood should test CAP's current product value:

- readiness;
- preflight;
- deterministic gates;
- observability;
- failure clarity.

Dogfood should not use CAP as a default code generator or force every
small task through a product-scale multi-agent pipeline.

## Active Dogfood Profiles

### 1. Provider Readiness

Goal: prove CAP fails before AI work when the provider is missing or not
ready.

Acceptance:

- `cap provider doctor` has human and JSON output;
- JSON validates against `schemas/provider-readiness.schema.yaml`;
- missing provider is reported clearly;
- installed-but-auth-unknown is reported conservatively;
- remediation is visible;
- no token, login, or provider state mutation occurs.

### 2. Workflow Preflight

Goal: prove AI-backed workflow execution checks provider readiness before
the first AI step.

Acceptance:

- AI-backed workflow halts before provider spawn when readiness is
  blocked;
- shell-only workflow bypasses provider readiness;
- dry-run / bind / compile remain provider-independent;
- halt output includes provider, readiness state, blocked reason, and
  remediation.

### 3. Observability

Goal: prove an operator can understand a run without reading the whole
CAP repo.

Acceptance:

- `cap workflow inspect <run-id>` identifies final state and failed step;
- `cap workflow logs <run-id> --step <step>` finds the relevant output;
- `cap session analyze --run-id <run-id>` shows duration hotspots and
  token availability / byte proxies;
- failure records are written even when the workflow halts early.

### 4. Deterministic Workflow

Goal: prove CAP adds value without requiring AI inference.

Acceptance:

- schema validation;
- repo identity checks;
- shell audits;
- smoke scripts;
- artifact indexing;
- result rendering.

## Frozen Dogfood Profiles

### Component Repo / Component-Fast

Frozen.

The historical component dogfood remains useful evidence, but it should
not drive the next platform cycle. It tested too many things at once:
project constitution, spec pipeline, implementation pipeline, templates,
structured inputs, smoke runtime, provider cost, and profile design.

Future component dogfood requires a separate reopen decision.

### Product-Strict Pipeline

Frozen as default dogfood.

Use only when explicitly testing product-scale governance. It is not a
normal regression target.

## Rule

Prefer the smallest dogfood that can prove the platform boundary.

If a dogfood run needs more than one paragraph to explain why it is
necessary, it is probably too broad for the current CAP direction.
