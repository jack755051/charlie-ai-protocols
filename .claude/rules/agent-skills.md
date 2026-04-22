---
paths:
  - "docs/agent-skills/**/*.md"
---

# Agent Skills Editing Rules

- All agent files MUST end with `-agent.md` (e.g. `02-techlead-agent.md`). This is how `factory.py` discovers them.
- `00-core-protocol.md` is the only non-agent file — it is the shared constitution, NOT an agent.
- `strategies/` files are framework-specific details, NOT agents. Do not rename them to `*-agent.md`.
- When adding a new agent, also update:
  - `docs/agent-skills/README.md` (architecture blueprint)
  - `README.md` (project directory structure)
- Agent prompts must NOT contain orchestration logic (routing rules, trigger conditions, quality gates). These belong in `schemas/workflows/`. Agent prompts define ONLY capability, methodology, and output format.
- Role key is parsed from filename: `{number}-{role_key}-agent.md` → `parts[1].upper()`.
- All agent content must be in Traditional Chinese with English technical terms preserved.
