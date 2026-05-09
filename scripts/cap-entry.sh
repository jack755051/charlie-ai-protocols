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

[Observe Runs]
  cap workflow ps                  List active workflow runs (-a / --all for history)
  cap workflow logs <run-id>       Print or follow workflow.log (docker-like)
  cap workflow watch <run-id>      Live state snapshot (refreshes on tty)
  cap workflow inspect <run-id>    One-shot run details with follow-up hints

[Provider]
  cap provider doctor [--json]     Check claude / codex CLI availability (read-only; no login)

[Shortcuts]
  cap p init/status/doctor         shorthand for cap project init/status/doctor
  cap proj ...                     shorthand for cap project ...
  cap wf ...                       shorthand for cap workflow ...
  cap prov doctor                  shorthand for cap provider doctor

Topic-style help:
  cap help workflow                full cap workflow subcommand index
  cap help observe                 deep dive into logs / watch / inspect / ps
  cap help --advanced              maintenance, diagnostics, and legacy commands
EOF
}

show_help_workflow() {
  cat <<'EOF'
cap workflow — Full subcommand index

USAGE
  cap workflow <subcommand> [options]
  cap workflow <id> [prompt]              shorthand for `cap workflow run <id> [prompt]`
  cap workflow <id>                       shorthand for `cap workflow show <id>` (no prompt)

[Discover]
  cap workflow list                      List registered workflows (static catalog)
  cap workflow show <id>                 Print workflow definition + binding summary
  cap workflow plan <id>                 Show semantic + bound execution plan
  cap workflow bind <id> [registry]      Run capability binding and print report

[Run]
  cap workflow run <id> [prompt]         Execute a workflow (default CLI: claude)
  cap workflow run --dry-run <id> [prompt]      Preview plan without calling AI
  cap workflow run --strategy auto <id> [prompt]  Auto-select fast / governed / strict
  cap workflow run --cli codex <id> [prompt]      Force a specific provider CLI
  cap workflow run --design-package <name> <id>   Inject ~/.cap/designs/<name>
  cap workflow run-task "<request>"       Compile then execute from a one-line request
  cap workflow compile "<request>"        Compile-only (no execution)

[Observe]
  cap workflow ps [--all]                Active runs (--all for history)
  cap workflow logs <run-id>             Print or follow workflow.log
  cap workflow watch <run-id>            Live snapshot view
  cap workflow inspect <run-id>          One-shot run details

[Constitution / Task]
  cap workflow constitution "<request>"   [DEPRECATED] use cap task constitution
  cap task constitution "<request>"       Generate a Task Constitution

For deeper observability flags (`-f`, `--tail`, `--step`, `--compact`, `--json`, `--cap-home`),
run:
  cap help observe
  cap workflow logs --help
  cap workflow watch --help

Architecture / SSOT pointers:
  docs/cap/ARCHITECTURE.md                runtime module map
  docs/cap/RUN-OBSERVABILITY-GUIDE.md     observation operations guide
EOF
}

show_help_observe() {
  cat <<'EOF'
cap workflow observability — read-only views over a CAP run

When to use which surface:
  - Full line stream (entire workflow.log)         → cap workflow logs <run-id>
  - Live tail of new log lines                     → cap workflow logs -f <run-id>
  - Last N log lines (docker habit)                → cap workflow logs --tail N <run-id>
  - One specific step's provider output            → cap workflow logs <run-id> --step <step-id>
  - Live state snapshot (auto-refresh on tty)      → cap workflow watch <run-id>
  - Single-shot snapshot for CI / scripts          → cap workflow watch --once <run-id>
  - Terse single-screen status (<15 lines)         → cap workflow watch --compact <run-id>
  - JSON snapshot for dashboards / jq pipelines    → cap workflow watch --json <run-id>
  - Final run details (six sections)               → cap workflow inspect <run-id>
  - List active or historical runs                 → cap workflow ps [--all]
  - Cross-repo / sandbox observation               → any of the above + --cap-home PATH

State glyphs (shared across watch / inspect):
  ✓ ok        completed / validated / success
  ●  running   in flight
  ○  pending   queued / waiting
  ✗ failed    explicit failure
  ⊘ skipped
  ◐ blocked
  ⊠ cancelled
  ?  unknown   not recognised (legacy / partial run)

Step-output fallback chain (cap workflow logs --step):
  1. <run_dir>/*-<step_id>.raw.log       (legacy runs only)
  2. <run_dir>/*-<step_id>.md            (current SSOT)
  3. <run_dir>/*-<step_id>.handoff.md    (last-resort: Type D summary)

Boundary:
  - Pure read-only. No AI calls, no token cost, no run state mutation.
  - All flags work without provider login.

Per-command --help:
  cap workflow logs --help
  cap workflow watch --help

Operations guide:
  docs/cap/RUN-OBSERVABILITY-GUIDE.md
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
  cap workflow logs --tail N <run-id>   Print only the last N lines (docker-like)
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

# Top-level commands the dispatcher recognises. Source of truth for the
# unknown_command fuzzy-match suggester. Kept in sync manually with the
# main case in this file — small enough to spot-check at review time.
KNOWN_COMMANDS=(
  help -h --help
  -v --version version update rollback release-check
  skill registry check-aliases
  workflow wf
  project p proj
  task
  promote
  replay
  agent
  provider prov
  codex claude session
  artifact
  paths
  setup sync install uninstall
  run
)

unknown_command() {
  local command="$1"
  echo "Unknown cap command: ${command}" >&2

  # Fuzzy match via difflib (cutoff 0.6 mirrors python's default).
  # Falls through silently when no close match — we don't want to nag
  # users with weak suggestions ("did you mean xyz?" for unrelated
  # typos is worse than no suggestion).
  local suggestion
  suggestion="$(printf '%s\n' "${KNOWN_COMMANDS[@]}" \
    | CAP_FUZZY_INPUT="${command}" python3 -c "
import os, sys, difflib
words = [w.strip() for w in sys.stdin if w.strip()]
target = os.environ.get('CAP_FUZZY_INPUT', '')
matches = difflib.get_close_matches(target, words, n=1, cutoff=0.6)
if matches:
    print(matches[0])
" 2>/dev/null)"

  if [ -n "${suggestion}" ]; then
    echo "Did you mean: cap ${suggestion}?" >&2
  fi
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
      workflow|wf)
        show_help_workflow
        ;;
      observe|observability)
        show_help_observe
        ;;
      *)
        echo "Unknown help option: $1" >&2
        echo "Available: cap help | cap help --advanced | cap help workflow | cap help observe" >&2
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
