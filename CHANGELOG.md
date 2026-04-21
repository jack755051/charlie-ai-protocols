# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and the release versions in this file
follow the git tags currently present in this repository.

## [Unreleased]

### Added
- Pending next tagged release.

## [v0.4.1] - 2026-04-21

### Fixed
- Unaliased `cap`, `codex`, and `claude` before shell wrapper installation to
  avoid zsh function-definition conflicts after `cap update`.

## [v0.4.0] - 2026-04-21

### Added
- Added runtime-local CAP storage under `~/.cap/projects/<project_id>/`.
- Added tag-aware release controls with `cap version`, `cap update [target]`,
  and `cap rollback <tag>`.
- Added promote flow with `cap promote list` and `cap promote <src> <dst>`.
- Added agent registry support via `.cap.agents.json`.

### Changed
- Moved default trace and report outputs from repo-local `workspace/history` to
  local CAP storage.
- Updated install and CLI documentation to reflect runtime storage and release
  management.

## [v0.3.0] - 2026-04-20

### Added
- Added trace-aware CLI session wrappers for `cap`, `codex`, and `claude`.

## [v0.2.1] - 2026-04-20

### Changed
- Routed troubleshoot flow back through supervisor for formal dispatch control.

## [v0.2.0] - 2026-04-17

### Added
- Enforced DDD tactical patterns across BA, DBA/API, Backend, and Watcher
  agents.

## [v0.1.0] - 2026-04-17

### Fixed
- Fixed stale SA/schema references across agent-skill documents.

### Added
- Added `check-aliases` validation script for generated agent aliases.

## [v0.0.2] - 2026-04-17

### Changed
- Split legacy SA responsibilities into separate BA and DBA/API agents.

## [v0.0.1] - 2026-04-15

### Changed
- Updated Makefile help output to display `cap` prefix instead of `make`.

## [v0.0.0-rc] - 2026-04-14

### Changed
- Preserved legacy `workspace/` directory structure via `.gitkeep`.

## [v0.0.0-beta] - 2026-04-13

### Added
- Added logger execution trace format documentation.

## [v0.0.0-alpha] - 2026-04-04

### Changed
- Refined engine execution and self-check rules.
