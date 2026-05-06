#!/usr/bin/env bash
#
# cap-task.sh — Subcommand dispatcher for `cap task` (P2 #6).
#
# Mirrors the shape of scripts/cap-project.sh:
#   - cap project ...   long-term repo governance entrypoint
#   - cap task ...      single-prompt / single-execution entrypoint
#
# This split is the user-facing realisation of the boundary memo at
# docs/cap/CONSTITUTION-BOUNDARY.md §4.1: cap task ... is always
# task-scoped (Task Constitution semantics), cap project ... is always
# repo-scoped (Project Constitution semantics).
#
# Subcommands:
#   constitution  Compile a Task Constitution from a free-form prompt.
#                 Currently a thin alias for `cap workflow constitution`
#                 with the deprecation warning suppressed; the underlying
#                 task_scoped_compiler.build_task_constitution call is
#                 unchanged so behaviour matches the legacy entry exactly.
#
# Reserved for future commits (printed as "(planned)" in usage so the
# CLI surface is honest about scope):
#   plan      — task constitution + capability graph preview
#   compile   — task constitution + graph + compiled workflow + binding
#   run       — compile + execute via runtime binder

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CAP_WORKFLOW="${SCRIPT_DIR}/cap-workflow.sh"

usage() {
  cat <<'EOF'
Usage: cap task <subcommand> [options]

Subcommands:
  constitution <request...>
          Compile a Task Constitution from the given free-form prompt.
          Equivalent to (and the recommended replacement for)
          `cap workflow constitution <request...>` — the workflow-scoped
          name is deprecated and will print a deprecation warning unless
          CAP_DEPRECATION_SILENT=1 is set.

Reserved (planned):
  plan <request...>      — task constitution + capability graph preview.
  compile <request...>   — task constitution + graph + compiled workflow
                           + binding bundle.
  run <request...>       — compile + execute via the runtime binder.

Notes:
  - cap task ... is always task-scoped. For repo-level governance use
    cap project constitution instead (see
    docs/cap/CONSTITUTION-BOUNDARY.md §4.1 for the boundary).
  - Reserved subcommands print a clear "(planned)" message and exit 2;
    they do not silently fall through.
EOF
}

die() {
  echo "cap-task: error — $*" >&2
  exit 1
}

[ -x "${CAP_WORKFLOW}" ] || die "scripts/cap-workflow.sh missing or not executable"

# ─────────────────────────────────────────────────────────
# constitution — alias to cap workflow constitution
# ─────────────────────────────────────────────────────────

cmd_constitution() {
  if [ "$#" -lt 1 ]; then
    echo "Usage: cap task constitution <request...>" >&2
    exit 1
  fi
  # Suppress the deprecation warning that the legacy entry now prints —
  # callers who reach this code path are using the new alias and should
  # not see a notice telling them to switch to the new alias.
  CAP_DEPRECATION_SILENT=1 exec bash "${CAP_WORKFLOW}" constitution "$@"
}

# ─────────────────────────────────────────────────────────
# Reserved subcommands (planned)
# ─────────────────────────────────────────────────────────

cmd_planned() {
  local sub="$1"
  echo "cap task ${sub}: (planned) — not implemented yet." >&2
  echo "See docs/cap/CONSTITUTION-BOUNDARY.md §6 for the P2 roadmap." >&2
  exit 2
}

# ─────────────────────────────────────────────────────────
# Dispatcher
# ─────────────────────────────────────────────────────────

main() {
  local sub="${1:-}"
  case "${sub}" in
    constitution)
      shift
      cmd_constitution "$@"
      ;;
    plan|compile|run)
      cmd_planned "${sub}"
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      echo "cap-task: unknown subcommand: ${sub}" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
