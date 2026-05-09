#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

show_help() {
  cat <<'EOF'
Charlie's AI Protocols (CAP) - Start Here

COMMAND                            DESCRIPTION
─────────────────────────────────  ──────────────────────────────────────────────

[Start]
  cap help | -h | --help           Show common commands
  cap help --advanced              Show maintenance, diagnostics, and legacy commands
  cap version | -v | --version     Show version, ref, and latest release tag
  cap update [target]              Update to latest / main / a tag / a branch

[Discover]
  cap skill list                   List all Agent Skills
  cap workflow list                List all workflows (static catalog)

[Repo Setup]
  cap project init [--project-id ID] [--force]   Connect the current repo to CAP and create project_id / storage / ledger
  cap project status [--format text|json|yaml]  Show the current repo's CAP identity and storage state
  cap project doctor [--format text|json|yaml]  Check CAP project configuration and storage health

[Run Workflows]
  cap workflow run <id> [prompt]   Run a workflow in a CAP-enabled repo (default CLI: claude)
  cap workflow run --dry-run <id> [prompt]  Preview the workflow execution plan without calling AI

[Provider]
  cap provider doctor [--json]     Check claude / codex CLI availability (read-only; no login)

[Shortcuts]
  cap p init/status/doctor         shorthand for cap project init/status/doctor
  cap proj ...                     shorthand for cap project ...
  cap wf ...                       shorthand for cap workflow ...
  cap prov doctor                  shorthand for cap provider doctor

More maintenance, diagnostic, and legacy commands:
  cap help --advanced
EOF
}

show_advanced_help() {
  cat <<'EOF'
Charlie's AI Protocols (CAP) - Advanced / Maintenance

COMMAND                            DESCRIPTION
─────────────────────────────────  ──────────────────────────────────────────────

[Setup & Install]
  cap setup                        Create the venv and install dependencies (usually handled by the installer)
  cap sync                         Rebuild local Agent Skills symlinks
  cap install                      Install Agent Skills globally and register the shell wrapper
  cap uninstall                    Remove the global install and shell wrapper
  cap release-check [--all|--recent N]  Check release metadata for low-signal entries
  cap paths                        Show CAP local storage paths (diagnostic)

[Skill & Registry]
  cap skill registry               Show the agent registry
  cap skill check-aliases          Validate alias mappings

[Project]
  cap project constitution (--prompt "<request>" | --from-file PATH | --promote STAMP | --latest)
                                                   Generate, import, or promote a Project Constitution snapshot to the repo SSOT

[Task / Compiler]
  cap task constitution "<request>"     Generate a Task Constitution from a one-line request
  cap task plan "<request>"             (planned) Preview task constitution + capability graph
  cap task compile "<request>"          (planned) task constitution + graph + compiled workflow + binding bundle
  cap task run "<request>"              (planned) compile + execute via runtime binder
  cap workflow constitution "<request>"   [DEPRECATED] Generate a task constitution; use cap task constitution
  cap workflow compile "<request>"        Compile a minimal workflow from a one-line request
  cap workflow run-task "<request>"       Compile and run directly from a one-line request
  cap workflow <id> "<prompt>"        Shorthand for run

[Workflow Runtime]
  cap workflow ps                  List running workflow runs
  cap workflow ps --all            List all historical workflow runs
  cap workflow run --strategy auto <id> [prompt]  Auto-select fast / governed / strict strategy
  cap workflow run --cli codex <id> [prompt]      Run with codex
  cap workflow run --design-package <name> <id> [prompt]  Use a ~/.cap/designs/<name> design package
  cap workflow show <id>           Show workflow summary
  cap workflow plan <id>           Show semantic plan, phases, and binding summary
  cap workflow bind <id> [registry]  Show skill binding report
  cap workflow inspect <run-id>    Show details for one workflow run
  cap workflow logs <run-id>       Print the run's workflow.log (docker-like)
  cap workflow logs -f <run-id>    Follow the run's workflow.log live (tail -f)
  cap workflow logs <run-id> --step <step-id>     Print a step's output (raw.log/md/handoff.md)
  cap workflow logs -f <run-id> --step <step-id>  Follow a step's output live
  cap workflow watch <run-id>      Live snapshot of run state (refreshes on tty)
  cap workflow watch --once <run-id>  Single-shot snapshot (deterministic for CI)
  cap workflow watch --compact <run-id>  Terse single-screen view (<15 lines)
  cap workflow watch --json <run-id>  JSON snapshot for scripts / dashboards

[Execution]
  cap codex [ARGS...]              Record trace inside CAP projects; fall back to native Codex outside CAP dirs
  cap claude [ARGS...]             Record trace inside CAP projects; fall back to native Claude outside CAP dirs
  cap session inspect <session_id> [--json]  Inspect agent session ledger (read-only)
  cap session analyze [--top N] [--json]    Analyze token / time hotspots (read-only)

[Promote]
  cap promote inspect <id>         Inspect a promotable runtime artifact
  cap promote project-constitution <task_id>  Promote Project Constitution back to the repo SSOT
  cap promote workflow <workflow_id>          Promote workflow artifact back to the repo SSOT

[Replay]
  cap replay verify <run_id>       Check whether an old run's builtin agent-skills baseline is still replayable

[Supervisor Orchestration]
  cap workflow bind supervisor-orchestration       envelope schema + drift gate
  -> runtime dispatcher (halt / retry / route_back / escalate) is not wired yet; see docs/cap/ARCHITECTURE.md

[Legacy / Debug]
  cap run                          Start the CrewAI engine (FRAMEWORK=nextjs|angular|nuxt)
  cap agent <agent> [prompt]       Start an interactive session for a specific agent
  cap artifact list / inspect / by-step      Inspect the runtime-state.json artifact registry
  cap promote list                 List promotable drafts / reports (legacy generic mode)
  cap promote <src> <dst>          Promote a local artifact to a formal repo path (legacy generic mode)
EOF
}

unknown_command() {
  local command="$1"
  echo "Unknown cap command: ${command}" >&2
  echo "Run 'cap help' to see available commands." >&2
  exit 1
}

COMMAND="${1:-help}"

case "${COMMAND}" in
  help|-h|--help)
    shift || true
    case "${1:-}" in
      ""|-h|--help)
        show_help
        ;;
      --advanced|advanced)
        show_advanced_help
        ;;
      *)
        echo "Unknown help option: $1" >&2
        echo "Available: cap help | cap help --advanced" >&2
        exit 1
        ;;
    esac
    ;;
  codex)
    shift
    exec bash "${SCRIPT_DIR}/cap-session.sh" codex "$@"
    ;;
  claude)
    shift
    exec bash "${SCRIPT_DIR}/cap-session.sh" claude "$@"
    ;;
  session)
    shift || true
    exec bash "${SCRIPT_DIR}/cap-session.sh" "$@"
    ;;
  artifact)
    shift || true
    exec bash "${SCRIPT_DIR}/cap-artifact.sh" "$@"
    ;;
  -v|--version)
    exec bash "${SCRIPT_DIR}/cap-release.sh" version
    ;;
  version|update|rollback|release-check)
    exec bash "${SCRIPT_DIR}/cap-release.sh" "$@"
    ;;
  skill)
    shift || true
    SUB="${1:-list}"
    case "${SUB}" in
      list)
        shift || true
        exec make -C "${CAP_ROOT}" skill-list "$@"
        ;;
      registry)
        shift || true
        exec bash "${SCRIPT_DIR}/cap-registry.sh" show "$@"
        ;;
      check-aliases)
        shift || true
        exec make -C "${CAP_ROOT}" check-aliases "$@"
        ;;
      *)
        echo "Unknown skill subcommand: ${SUB}" >&2
        echo "Available: cap skill list | registry | check-aliases" >&2
        exit 1
        ;;
    esac
    ;;
  check-aliases|registry)
    exec "$0" skill "${COMMAND}" "$@"
    ;;
  workflow|wf)
    shift || true
    exec bash "${SCRIPT_DIR}/cap-workflow.sh" "$@"
    ;;
  project|p|proj)
    shift || true
    exec bash "${SCRIPT_DIR}/cap-project.sh" "$@"
    ;;
  task)
    shift || true
    exec bash "${SCRIPT_DIR}/cap-task.sh" "$@"
    ;;
  promote)
    shift || true
    exec bash "${SCRIPT_DIR}/cap-promote.sh" "$@"
    ;;
  replay)
    shift || true
    exec bash "${SCRIPT_DIR}/cap-replay.sh" "$@"
    ;;
  agent)
    shift
    exec bash "${SCRIPT_DIR}/cap-agent.sh" "$@"
    ;;
  provider|prov)
    shift || true
    exec bash "${SCRIPT_DIR}/cap-provider.sh" "$@"
    ;;
  *)
    if [ "${COMMAND}" = "paths" ]; then
      shift || true
      exec bash "${SCRIPT_DIR}/cap-paths.sh" show "$@"
    fi
    unknown_command "${COMMAND}"
    ;;
esac
