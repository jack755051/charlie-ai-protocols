<h1 align="center">CAP</h1>

<p align="center">
  <strong>Charlie&apos;s AI Protocols</strong>
</p>

<p align="center">
  <code>provider readiness</code> · <code>workflow preflight</code> · <code>run observability</code> · <code>deterministic gates</code>
</p>

<p align="center">
  CAP is an AI CLI governance and observability layer for Claude Code,
  Codex, and other local provider tools.
</p>

<p align="center">
  <a href="docs/cap/CAP-POSITIONING.md">Positioning</a>
  ·
  <a href="docs/cap/README.md">Docs Index</a>
  ·
  <a href="docs/cap/PROVIDER-READINESS-TASKS.md">Provider Readiness</a>
  ·
  <a href="docs/cap/RUN-OBSERVABILITY-GUIDE.md">Run Observability</a>
</p>

## Position

CAP is **not** a replacement for Claude Code or Codex.

For small one-off coding tasks, direct provider use is expected to be
faster and simpler. CAP is valuable when a repo or task needs governance
and evidence:

- provider readiness before AI-backed work;
- repo identity and constitution boundaries;
- workflow binding and capability checks;
- deterministic shell / schema / smoke gates;
- run logs, artifacts, and session analysis;
- clear halt reasons before wasting provider quota.

The current product boundary is documented in
[docs/cap/CAP-POSITIONING.md](docs/cap/CAP-POSITIONING.md).

## Current Direction

The active CAP direction is narrow:

```text
install / sync
  -> provider doctor
  -> project init / doctor
  -> workflow bind / dry-run
  -> provider preflight before AI steps
  -> deterministic checks first
  -> AI only when ambiguity / judgement / repair is needed
  -> inspect / analyze the run
```

Frozen until reopened:

- component-fast expansion;
- new stack-specific templates;
- broad product/spec/implementation pipeline dogfood;
- marketplace / publish work;
- hidden provider-to-provider routing.

## Install

```bash
bash install.sh
source ~/.zshrc

cap setup
cap sync
```

Install only sets up CAP and syncs skills. It does not log you into
Claude Code, Codex, or any provider.

## First Use

```bash
# 1. Check provider visibility / readiness.
cap provider doctor
cap provider doctor --json

# 2. If needed, enter the native provider login/session flow.
cap claude
cap codex

# 3. Attach a repo to CAP.
cd /path/to/repo
cap project init
cap project doctor

# 4. Inspect workflow binding before any AI work.
cap workflow list
cap workflow bind version-control
cap workflow run --dry-run --cli claude version-control "版本更新"

# 5. Run only when readiness and binding are acceptable.
cap workflow run --cli claude version-control "版本更新"
```

Read-only commands, dry-run, bind, compile, and shell-only workflows
must remain usable without provider auth. AI-backed workflows should
preflight provider readiness before the first provider call.

## Common Commands

```bash
# Provider readiness
cap provider doctor
cap provider doctor --json

# Repo identity / health
cap project init
cap project status
cap project doctor

# Workflow planning / execution
cap workflow list
cap workflow show version-control
cap workflow bind version-control
cap workflow run --dry-run --cli claude version-control "版本更新"
cap workflow run --cli claude version-control "版本更新"

# Run observability
cap workflow inspect <run-id>
cap workflow logs <run-id>
cap workflow logs <run-id> --step <step-id>
cap workflow watch <run-id>
cap session inspect --run-id <run-id>
cap session analyze --run-id <run-id>

# Native-provider sessions with CAP trace when inside a CAP project
cap claude [ARGS...]
cap codex [ARGS...]
```

## Provider Isolation

CAP does not hijack bare provider commands.

- `claude` and `codex` remain native provider CLIs.
- `cap claude` and `cap codex` are explicit CAP-managed entry points.
- CAP readiness checks must not consume tokens, trigger interactive
  login, or mutate provider state.

Provider auth and account lifecycle belong to the provider. CAP only
checks readiness and records CAP-managed runs.

## What CAP Stores

CAP separates repo source from runtime output.

```text
project repo
├── .cap.project.yaml
├── .cap.constitution.yaml
├── .cap.skills.yaml
└── optional workflow / policy sources

~/.cap/projects/<project_id>/
├── bindings/
├── reports/workflows/<workflow_id>/<run_id>/
├── traces/
├── sessions/
├── logs/
└── cache/
```

Runtime reports may include `workflow.log`, `runtime-state.json`,
`agent-sessions.json`, result files, step outputs, and artifact indexes.

## When To Use CAP

Use CAP when:

- the task must be auditable;
- workflow gates matter;
- provider readiness should be checked before AI work;
- you need run evidence for later debugging;
- deterministic validation can remove unnecessary AI calls.

Use Claude Code / Codex directly when:

- the task is small and local;
- you only need quick code edits;
- no long-term workflow evidence is needed;
- CAP would add more explanation than value.

## Project Structure

```text
charlie-ai-protocols/
├── agent-skills/             # role prompts and guardrails
├── policies/                 # cross-tool policies
├── schemas/                  # workflow / runtime / readiness contracts
├── engine/                   # loaders, binders, validators, inspectors
├── scripts/                  # cap CLI wrappers and workflow scripts
├── workflows/                # workflow templates
├── docs/cap/                 # active docs and frozen reference memos
├── development-records/      # ADRs, dogfood logs, closeouts
└── tests/                    # shell / python / e2e fixtures
```

## Links

- Current positioning: [docs/cap/CAP-POSITIONING.md](docs/cap/CAP-POSITIONING.md)
- Docs index: [docs/cap/README.md](docs/cap/README.md)
- Platform goal: [docs/cap/PLATFORM-GOAL.md](docs/cap/PLATFORM-GOAL.md)
- Lean roadmap: [docs/cap/CAP-LEAN-ROADMAP.md](docs/cap/CAP-LEAN-ROADMAP.md)
- Provider readiness: [docs/cap/PROVIDER-READINESS-TASKS.md](docs/cap/PROVIDER-READINESS-TASKS.md)
- Run observability: [docs/cap/RUN-OBSERVABILITY-GUIDE.md](docs/cap/RUN-OBSERVABILITY-GUIDE.md)
- Architecture reference: [docs/cap/ARCHITECTURE.md](docs/cap/ARCHITECTURE.md)
- Release history: [docs/cap/RELEASE-NOTES.md](docs/cap/RELEASE-NOTES.md)

## License

UNLICENSED — Portfolio 專用，保留一切權利。
