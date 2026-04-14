---
paths:
  - "docs/agent-skills/**/*.md"
---

# Agent Skills Editing Rules

- All agent files MUST end with `-agent.md` (e.g. `02-sa-agent.md`). This is how `factory.py` discovers them.
- `00-core-protocol.md` is the only non-agent file — it is the shared constitution, NOT an agent.
- `strategies/` files are framework-specific details, NOT agents. Do not rename them to `*-agent.md`.
- When adding a new agent, also update:
  - `docs/agent-skills/README.md` (architecture blueprint)
  - `docs/agent-skills/01-supervisor-agent.md` (sub-agents registry)
  - `README.md` (project directory structure)
- Role key is parsed from filename: `{number}-{role_key}-agent.md` → `parts[1].upper()`.
- All agent content must be in Traditional Chinese with English technical terms preserved.
