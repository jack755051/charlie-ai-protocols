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
        echo "Unknown doctor option: ${arg}" >&2
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
    # Emit a report conforming to schemas/provider-readiness.schema.yaml.
    # Python3 already powers every CAP validator path; using it here keeps
    # the conditional-field / array-of-objects shape readable instead of
    # hand-rolled. Inputs are passed positionally so the heredoc body
    # carries no shell interpolation.
    #
    # State mapping (P1 conservative — no_token / no_interactive /
    # no_mutation are all respected):
    #   - CLI missing on PATH                → state=provider_missing
    #   - CLI present, no safe auth probe    → state=auth_unknown
    # No login is invoked. No model token is spent. Provider state is
    # never mutated. A future slice may upgrade `auth_unknown` to
    # `auth_required` / `auth_ok` per-provider where a safe no-token
    # probe is feasible.
    "${PYTHON_BIN:-python3}" - \
      "${claude_status}" "${claude_path}" "${claude_version}" \
      "${codex_status}"  "${codex_path}"  "${codex_version}" <<'PY'
import json
import sys
from datetime import datetime, timezone

(claude_status, claude_path, claude_version,
 codex_status, codex_path, codex_version) = sys.argv[1:7]

REMEDIATION_MISSING = {
    "claude": "Install Claude Code: see https://docs.claude.com/claude-code",
    "codex": "Install Codex CLI: see https://developers.openai.com/codex",
}

def provider_entry(name, status, path, version):
    if status == "missing":
        return {
            "name": name,
            "source": "cli",
            "state": "provider_missing",
            "remediation": REMEDIATION_MISSING.get(
                name, "install the provider CLI before retrying"
            ),
            "probe_source": "cap-provider-doctor-v1",
        }
    entry = {
        "name": name,
        "source": "cli",
        "cli_path": path,
        "state": "auth_unknown",
        "remediation": (
            f"run `cap {name}` once to complete provider login if not yet "
            "done; CAP does not probe auth state to respect the no-token "
            "and no-interactive readiness rules"
        ),
        "probe_source": "cap-provider-doctor-v1",
    }
    if version and version != "(version unavailable)":
        entry["version"] = version
    return entry

report = {
    "schema_version": 1,
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "probe_policy": {
        "no_token": True,
        "no_interactive": True,
        "no_mutation": True,
    },
    "providers": [
        provider_entry("claude", claude_status, claude_path, claude_version),
        provider_entry("codex", codex_status, codex_path, codex_version),
    ],
}
json.dump(report, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
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
    echo "Unknown provider subcommand: ${COMMAND}" >&2
    echo "Available: cap provider doctor" >&2
    exit 1
    ;;
esac
