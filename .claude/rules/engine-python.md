---
paths:
  - "engine/**/*.py"
---

# Engine Python Rules

- Use Python 3.10+ syntax. Type hints on all public functions.
- `factory.py` only instantiates files matching `*-agent.md` glob. `00-core-protocol.md` is loaded separately as shared preamble.
- CrewAI >= 1.14: no LangChain dependency. `Crew.kickoff()` returns `CrewOutput` — access `.raw` for text.
- Keep `requirements.txt` with loose version pins (`>=X.Y,<Z`) to allow patch updates.
- All user-facing print messages must be in Traditional Chinese.
