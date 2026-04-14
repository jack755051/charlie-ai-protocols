# Charlie's AI Protocols

AI multi-agent collaboration system with 11 specialized agents, powered by CrewAI.

## Core Protocol

See `docs/agent-skills/00-core-protocol.md` for the global constitution that all agents must follow.

## Git Workflow

See `docs/policies/git-workflow.md` for Conventional Commits, branching strategy, and PR conventions.

## Project Structure

- `docs/agent-skills/*-agent.md` — Agent system prompts (SSOT), picked up by `factory.py`.
- `docs/agent-skills/00-core-protocol.md` — Global constitution (NOT an agent), injected as shared preamble.
- `docs/agent-skills/strategies/` — Framework-specific tactics (NOT agents).
- `docs/policies/` — Cross-tool policies, readable by any AI CLI.
- `engine/` — Python 3.10+ CrewAI >= 1.14 execution engine.
- `workspace/` — Gitignored agent output sandbox.

## Agent Skills

Available agent skills in `.agents/skills/` (symlinked from `docs/agent-skills/`):

| Skill Prefix | Agent | Role |
|---|---|---|
| `$supervisor` | 01 | Orchestrator & PM |
| `$sa` | 02 | System Architect |
| `$ui` | 03 | UI/UX Designer |
| `$frontend` | 04 | Frontend Engineer |
| `$backend` | 05 | Backend Engineer |
| `$devops` | 06 | DevOps & CI/CD |
| `$qa` | 07 | QA Engineer |
| `$security` | 08 | Security Auditor |
| `$sre` | 11 | SRE & Performance |
| `$watcher` | 90 | Quality Watcher |
| `$logger` | 99 | Technical Writer |

## Conventions

- All communication with the user must be in **Traditional Chinese (繁體中文)**.
- Agent files must use `*-agent.md` naming to be instantiated by CrewAI.
- Commit messages follow Conventional Commits: `<type>(<scope>): <subject>`.
