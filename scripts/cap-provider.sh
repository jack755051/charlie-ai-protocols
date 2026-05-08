#!/usr/bin/env bash
#
# cap provider — read-only inspection for AI provider CLI availability.
#
# Boundary: CAP does not install, login, or wrap provider CLIs. This script
# only reports what CAP would resolve at runtime if a workflow step asked for
# claude/codex. Auto-fix and login are explicitly out of scope; the user is
# directed to the native CLI for those.
#
# Usage:
#   cap provider doctor          human-readable status
#   cap provider doctor --json   machine-readable status

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: cap provider <subcommand>

Subcommands:
  doctor [--json]    Inspect claude / codex availability and CAP default CLI
EOF
}

# Resolve the CLI CAP would default to for AI workflow steps. Mirror of the
# logic in cap-workflow.sh: explicit CAP_DEFAULT_AGENT_CLI wins; otherwise
# claude is the documented default.
resolve_default_cli() {
  if [ -n "${CAP_DEFAULT_AGENT_CLI:-}" ]; then
    printf '%s\n' "${CAP_DEFAULT_AGENT_CLI}"
    return
  fi
  printf '%s\n'  "claude"
}

probe_provider() {
  local name="$1"
  local path
  local version
  if path="$(command -v "${name}" 2>/dev/null)"; then
    # Some CLIs print version on stderr; merge streams and take the first
    # non-empty line so we have a stable single-line summary.
    version="$("${name}" --version 2>&1 | head -1 || true)"
    printf 'found\t%s\t%s\n' "${path}" "${version:-(version unavailable)}"
  else
    printf 'missing\t-\t-\n'
  fi
}

cmd_doctor() {
  local format="text"
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --json)
        format="json"
        ;;
      -h|--help)
        cat <<'EOF'
Usage: cap provider doctor [--json]

Inspect claude / codex CLI availability and the CAP default agent CLI.
Read-only: CAP will not install, login, or modify any provider CLI state.
EOF
        return 0
        ;;
      *)
        echo "未知的 doctor 選項: ${arg}" >&2
        return 1
        ;;
    esac
  done

  local default_cli claude_row codex_row
  default_cli="$(resolve_default_cli)"
  claude_row="$(probe_provider claude)"
  codex_row="$(probe_provider codex)"

  local claude_status claude_path claude_version
  IFS=$'\t' read -r claude_status claude_path claude_version <<<"${claude_row}"
  local codex_status codex_path codex_version
  IFS=$'\t' read -r codex_status codex_path codex_version <<<"${codex_row}"

  if [ "${format}" = "json" ]; then
    # Hand-roll JSON to avoid pulling in python for a 3-field report; values
    # are CLI paths and version strings, both already shell-safe in practice
    # but we still escape backslashes and double-quotes defensively.
    local escape='s/\\/\\\\/g; s/"/\\"/g'
    printf '{"default_cli":"%s","providers":{' "$(printf '%s' "${default_cli}" | sed "${escape}")"
    printf '"claude":{"status":"%s","path":"%s","version":"%s"},' \
      "${claude_status}" \
      "$(printf '%s' "${claude_path}" | sed "${escape}")" \
      "$(printf '%s' "${claude_version}" | sed "${escape}")"
    printf '"codex":{"status":"%s","path":"%s","version":"%s"}' \
      "${codex_status}" \
      "$(printf '%s' "${codex_path}" | sed "${escape}")" \
      "$(printf '%s' "${codex_version}" | sed "${escape}")"
    printf '}}\n'
    return 0
  fi

  # Text mode (default)
  printf 'CAP PROVIDER DOCTOR\n'
  printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
  printf '  default cli:   %s%s\n' \
    "${default_cli}" \
    "$([ -n "${CAP_DEFAULT_AGENT_CLI:-}" ] && echo " (from CAP_DEFAULT_AGENT_CLI)" || echo " (built-in default)")"
  printf '\n'
  printf '  claude:        %s\n' "${claude_status}"
  if [ "${claude_status}" = "found" ]; then
    printf '    path:        %s\n' "${claude_path}"
    printf '    version:     %s\n' "${claude_version}"
  fi
  printf '  codex:         %s\n' "${codex_status}"
  if [ "${codex_status}" = "found" ]; then
    printf '    path:        %s\n' "${codex_path}"
    printf '    version:     %s\n' "${codex_version}"
  fi
  printf '\n'

  # If the resolved default cli is missing, surface it loud.
  case "${default_cli}" in
    claude)
      if [ "${claude_status}" = "missing" ]; then
        printf '  ⚠ default cli (claude) is missing on PATH.\n' >&2
        printf '    Install Claude Code or set CAP_DEFAULT_AGENT_CLI=codex if you prefer codex.\n' >&2
      fi
      ;;
    codex)
      if [ "${codex_status}" = "missing" ]; then
        printf '  ⚠ default cli (codex) is missing on PATH.\n' >&2
        printf '    Install Codex CLI or set CAP_DEFAULT_AGENT_CLI=claude if you prefer claude.\n' >&2
      fi
      ;;
    *)
      printf '  ⚠ default cli (%s) is not a recognised provider.\n' "${default_cli}" >&2
      printf '    Supported values: claude | codex.\n' >&2
      ;;
  esac

  if [ "${claude_status}" = "missing" ] && [ "${codex_status}" = "missing" ]; then
    printf '  ⚠ no provider CLI is available. cap workflow run will fail-fast on AI steps.\n' >&2
    printf '    CAP does not install or login providers. See the upstream CLIs:\n' >&2
    printf '      Claude Code: https://docs.claude.com/claude-code\n' >&2
    printf '      Codex CLI:   https://developers.openai.com/codex\n' >&2
    return 1
  fi
  return 0
}

COMMAND="${1:-}"
case "${COMMAND}" in
  ""|-h|--help)
    usage
    ;;
  doctor)
    shift
    cmd_doctor "$@"
    ;;
  *)
    echo "未知的 provider 子指令: ${COMMAND}" >&2
    echo "可用: cap provider doctor" >&2
    exit 1
    ;;
esac
