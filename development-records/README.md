# Development Records

This directory stores tracked working records that are useful for CAP development but are not stable CAP documentation.

Use this directory for:

- live dogfood logs
- temporary investigation notes
- failure ledgers
- operator run notes that may later become docs, issues, or release notes

Suggested subdirectories:

- `dogfood/` — live or completed dogfood run logs and evidence.
- `closeouts/` — historical phase / round closeout reports.
- `findings/` — baseline findings, investigation snapshots, parity findings.
- `observations/` — ongoing observation ledgers and watchlists.

Do not use this directory for:

- stable architecture decisions; use `docs/cap/`
- runtime artifacts; use `~/.cap/projects/<project_id>/`
- repo configuration; use `.cap/`

When a record becomes a stable contract or user-facing guide, promote the durable part into `docs/cap/` and leave the raw investigation here.
