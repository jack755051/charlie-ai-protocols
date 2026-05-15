# Provider Readiness / Onboarding Memo

> Status: active boundary memo; implementation tracked in
> [PROVIDER-READINESS-TASKS.md](PROVIDER-READINESS-TASKS.md).
> Scope: first-run CAP UX for Claude Code / Codex provider readiness.
> Trigger: dogfood showed that users can install CAP successfully, then only discover missing provider login after `cap workflow run` reaches an AI step.

## Problem

CAP currently has no explicit provider readiness / onboarding layer. The result is a broken first-run experience: a user may install CAP, sync agent-skills, start a workflow, and only then learn that Claude Code or Codex is not logged in.

This is not an agent-skill problem. Agent-skills are CAP prompt / role assets and can be installed, listed, and inspected without provider auth. Provider login is only required when CAP actually asks Claude Code or Codex to execute an AI task.

## Responsibility Split

CAP should keep three separate gates:

1. `install.sh` / `cap setup`
   - Install CAP.
   - Sync agent-skills.
   - Register the shell wrapper.
   - Do not require Claude Code / Codex login.

2. `cap doctor` or `cap provider doctor`
   - Check provider CLI availability.
   - Check whether the provider appears usable.
   - Best-effort detect missing login / auth.
   - Give next-step instructions without mutating provider state.

3. `cap workflow run` / `cap agent` / `cap claude` / `cap codex`
   - Before a command actually calls AI, run a fast-fail provider preflight.
   - If auth is missing, stop before launching a long workflow and print explicit login instructions.
   - `cap claude` / `cap codex` may still launch the native provider as the login path.

## Original Repo State

- Earlier CAP versions only checked whether `claude` / `codex` were on `PATH`; login/auth readiness was not surfaced as a first-class state.
- Earlier workflow execution classified auth failures only after a provider step had already failed.
- `cap claude` / `cap codex` launch the native CLI through `cap-session.sh`, so interactive provider login can happen there: `scripts/cap-session.sh:128`.
- README already defines the right provider isolation boundary: bare `claude` / `codex` are not hijacked by CAP by default: `README.md:229`.

## Current Direction

Provider readiness is now a CAP core surface:

- readiness schema: `schemas/provider-readiness.schema.yaml`
- doctor surface: `cap provider doctor --json`
- preflight helper: `scripts/cap-provider-preflight.sh`
- task list: [PROVIDER-READINESS-TASKS.md](PROVIDER-READINESS-TASKS.md)

Readiness remains read-only: no token, no interactive login, no mutation.

## Target First-Run UX

```bash
cap install
source ~/.zshrc

cap doctor
# or:
cap provider doctor
```

The doctor output should make provider readiness explicit:

```text
CAP installed: yes
agent-skills synced: yes

claude:
  cli: installed
  auth: unknown | required | ok

codex:
  cli: installed
  auth: unknown | required | ok

next:
  run `cap claude` or `cap codex` once to complete provider login.
```

Then the login path stays native:

```bash
cap claude
# Enter Claude Code native login / interactive session.

cap codex
# Enter Codex native login / trust / API key setup.

cap project init
cap workflow run project-constitution "..."
```

## Auth Probe Contract

Do not assume every provider exposes a stable machine-readable auth API. The first version should be best-effort and conservative.

Recommended provider states:

| State | Meaning |
|---|---|
| `provider_missing` | CLI is not installed or not on `PATH`. |
| `auth_required` | CLI exists and a safe probe clearly reports missing login / missing key / unauthorized. |
| `auth_unknown` | CLI exists, but CAP cannot determine auth status without risky or interactive behavior. |
| `auth_ok` | CLI exists and a safe non-interactive probe confirms it is usable. |

`auth_unknown` should not block read-only CAP commands. For commands that call AI, CAP can either warn and proceed or fail fast depending on the command's risk. The default for long workflow execution should prefer a clear preflight prompt / halt over discovering auth failure deep inside a run.

## Login Failure Handling

CAP should not try to log in on behalf of the user. On auth failure, print provider-specific next steps:

```text
Provider authentication is required before CAP can run AI steps.

Claude Code:
  cap claude
  or claude

Codex:
  cap codex
  or codex
  or set OPENAI_API_KEY

After login, rerun:
  cap provider doctor
  cap workflow run ...
```

## Implementation Order

1. Extend `cap provider doctor`.
   - Add `--auth`, or make auth status visible in the default text output.
   - JSON output should expose `auth_status` per provider.

2. Add a shared provider preflight helper.
   - Reuse it from `cap workflow run` and `cap agent`.
   - Keep `cap help`, `cap version`, `cap skill list`, `cap workflow list`, `cap project doctor`, and other read-only commands free of auth requirements.

3. Update installer completion text.
   - Tell users to run `cap provider doctor`.
   - Do not imply CAP is ready to execute AI workflows immediately after install.

4. Document the first-use path.
   - `install` -> `source shell rc` -> `provider doctor` -> `cap claude` / `cap codex` login -> `project init` -> `workflow run`.

## Design Decision

CAP owns installation, governance, workflow orchestration, agent-skill sync, and fast-fail readiness checks. Claude Code / Codex own authentication. The bridge between them should be explicit provider readiness, not hidden failure inside the first AI workflow step.
