# Charlie's AI Protocols

AI multi-agent collaboration system with 13 specialized agents, powered by CrewAI.

## Core Protocol

@agent-skills/00-core-protocol.md

## Git Workflow

@policies/git-workflow.md

## Project Structure

- `agent-skills/*-agent.md` — Agent system prompts (SSOT), picked up by `factory.py`.
- `agent-skills/00-core-protocol.md` — Global constitution (NOT an agent), injected as shared preamble.
- `agent-skills/strategies/` — Framework-specific tactics (NOT agents).
- `policies/` — Cross-tool policies, readable by any AI CLI.
- `schemas/` — Machine-readable contracts (workflows, capabilities, handoff schema).
- `engine/` — Python 3.10+ CrewAI >= 1.14 execution engine (no LangChain).
- `workspace/` — Gitignored agent output sandbox (gitkeep-preserved, do not modify structure).

## Conventions

- All communication with the user must be in **Traditional Chinese (繁體中文)**.
- Agent files must use `*-agent.md` naming to be instantiated.
- `factory.py` globs `*-agent.md` and prepends `00-core-protocol.md` as backstory.
- Commit messages follow Conventional Commits: `<type>(<scope>): <subject>`.
