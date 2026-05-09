#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKFLOWS_DIR="${CAP_ROOT}/schemas/workflows"
VENV_PYTHON="${CAP_ROOT}/.venv/bin/python"
PATH_HELPER="${SCRIPT_DIR}/cap-paths.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  cap workflow list
  cap workflow ps [--all]
  cap workflow show <id>
  cap workflow inspect <run-id>
  cap workflow logs [-f|--follow] [--tail N] <run-id> [--step STEP_ID] [--cap-home PATH]
  cap workflow watch [--once] [--json] [--compact] [--interval SEC] [--tail N] <run-id> [--cap-home PATH]
  cap workflow plan <id>
  cap workflow bind <id> [registry]
  cap workflow constitution <request...>
  cap workflow compile <request...> [--registry path]
  cap workflow run-task [--dry-run] [--cli codex|claude] [--registry path] <request...>
  cap workflow run [--dry-run] [--cli codex|claude] [--strategy fast|governed|strict|auto] <id> [prompt...]
  cap workflow <id> "<prompt>"            (shorthand for run)

Default CLI: claude (override with --cli codex, or set the CAP_DEFAULT_AGENT_CLI environment variable)
Legacy --mode remains as an alias for --strategy.
EOF
  exit 1
}

resolve_python() {
  if [ -n "${CAP_PYTHON_BIN:-}" ]; then
    printf '%s\n' "${CAP_PYTHON_BIN}"
    return 0
  fi
  if [ -x "${VENV_PYTHON}" ]; then
    printf '%s\n' "${VENV_PYTHON}"
  else
    printf '%s\n' "python3"
  fi
}

PYTHON_BIN="$(resolve_python)"
CLI_PY="${CAP_ROOT}/engine/workflow_cli.py"

# ---------------------------------------------------------------------------
# Thin wrapper functions — delegate to workflow_cli.py subcommands
# ---------------------------------------------------------------------------

resolve_workflow_ref() {
  local raw_ref="${1:-}"
  [ -n "${raw_ref}" ] || return 1

  case "${raw_ref}" in
    version-control-private|version-control-quick|version-control-company)
      raw_ref="version-control"
      ;;
  esac

  # Absolute / cwd-relative path short-circuit: no layered resolver needed.
  if [ -f "${raw_ref}" ]; then
    printf '%s\n' "${raw_ref}"
    return 0
  fi

  # P9 #2: delegate layered resolution (project → shared → builtin) to
  # workflow_cli.py. The previous bash fast-path that scanned
  # ${WORKFLOWS_DIR}/${raw_ref}{,.yaml,.yml,.json} was removed because
  # the builtin fast-path would steal project layer overrides — the
  # exact bug docs/cap/P9-SOURCE-RESOLVER-DESIGN.md §4.5 calls out.
  "${PYTHON_BIN}" "${CLI_PY}" resolve-ref "${raw_ref}"
  return $?
}

collect_repo_change_files() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi

  {
    git diff --name-only --cached 2>/dev/null || true
    git diff --name-only 2>/dev/null || true
    git ls-files --others --exclude-standard 2>/dev/null || true
  } | sed '/^[[:space:]]*$/d' | sort -u
}

resolve_run_execution_mode() {
  local workflow_ref="$1"
  local requested_mode="$2"
  local user_prompt="$3"
  local changed_files

  changed_files="$(collect_repo_change_files || true)"

  "${PYTHON_BIN}" "${CLI_PY}" resolve-mode "${CAP_ROOT}" "${workflow_ref}" "${requested_mode}" "${user_prompt}" "${changed_files}"
}

ensure_status_store() {
  bash "${PATH_HELPER}" ensure >/dev/null
}

# Print a unified "workflow not found" message that doubles as a hint
# when the user's input is actually a typo of a subcommand. The shorthand
# fallback (`cap workflow <id>` -> show <id> / run <id>) means typos
# like `cap workflow updae` get routed through resolve_workflow_ref and
# would otherwise just say "workflow not found: updae" without telling
# the user that updae isn't a subcommand either. Both surfaces share
# this helper so future subcommand additions only need a single edit.
workflow_not_found() {
  local arg="$1"
  echo "workflow not found: ${arg}" >&2
  echo "" >&2
  echo "Hint: '${arg}' is neither a registered workflow id nor a known subcommand." >&2
  echo "Available subcommands: list | ps | show | inspect | logs | watch | run | plan | bind | constitution | compile | run-task" >&2
  echo "Run 'cap workflow list' to see registered workflow ids." >&2
}

fallback_status_store() {
  printf '%s\n' "${CAP_ROOT}/workspace/history/workflow-runs.json"
}

get_status_store() {
  local cache_dir
  local preferred
  local fallback
  fallback="$(fallback_status_store)"

  if ! cache_dir="$(bash "${PATH_HELPER}" get cache_dir 2>/dev/null)"; then
    mkdir -p "$(dirname "${fallback}")" >/dev/null 2>&1 || true
    printf '%s\n' "${fallback}"
    return
  fi

  preferred="${cache_dir}/workflow-runs.json"

  mkdir -p "${cache_dir}" "$(dirname "${fallback}")" >/dev/null 2>&1 || true

  if [ -f "${fallback}" ]; then
    printf '%s\n' "${fallback}"
    return
  fi

  if { [ -f "${preferred}" ] && [ -w "${preferred}" ]; } || { [ ! -f "${preferred}" ] && [ -d "${cache_dir}" ] && [ -w "${cache_dir}" ]; }; then
    printf '%s\n' "${preferred}"
    return
  fi

  printf '%s\n' "${fallback}"
}

create_workflow_run() {
  local workflow_id="$1"
  local workflow_name="$2"
  local state="$3"
  local result="$4"
  local mode="$5"
  local cli_name="$6"
  local prompt="$7"
  local status_file
  status_file="$(get_status_store)"

  "${PYTHON_BIN}" "${CLI_PY}" create-run "${status_file}" "${workflow_id}" "${workflow_name}" "${state}" "${result}" "${mode}" "${cli_name}" "${prompt}"
}

persist_constitution_artifact() {
  local constitution_json="$1"
  local request="$2"
  local origin="$3"
  local constitution_dir

  bash "${PATH_HELPER}" ensure >/dev/null
  constitution_dir="$(bash "${PATH_HELPER}" get constitution_dir)"

  "${PYTHON_BIN}" "${CLI_PY}" persist-constitution "${constitution_dir}" "${request}" "${origin}" "${constitution_json}"
}

persist_binding_snapshot() {
  local binding_json="$1"
  local workflow_id="$2"
  local workflow_name="$3"
  local workflow_ref="$4"
  local origin="$5"
  local binding_dir
  local augmented_json

  bash "${PATH_HELPER}" ensure >/dev/null
  binding_dir="$(bash "${PATH_HELPER}" get binding_dir)"

  # Inject workflow_name, workflow_ref, origin into the binding JSON
  # so the CLI can extract them (it reads these from the JSON payload).
  augmented_json="$(printf '%s' "${binding_json}" | "${PYTHON_BIN}" -c "
import json, sys
d = json.load(sys.stdin)
d['workflow_name'] = sys.argv[1]
d['workflow_ref'] = sys.argv[2]
d['origin'] = sys.argv[3]
print(json.dumps(d, ensure_ascii=False))
" "${workflow_name}" "${workflow_ref}" "${origin}")"

  "${PYTHON_BIN}" "${CLI_PY}" persist-binding "${binding_dir}" "${workflow_id}" "${augmented_json}"
}

persist_task_compile_bundle() {
  local compiled_json="$1"
  local request="$2"
  local registry_ref="$3"
  local origin="$4"
  local constitution_dir
  local compiled_workflow_dir
  local binding_dir

  bash "${PATH_HELPER}" ensure >/dev/null
  constitution_dir="$(bash "${PATH_HELPER}" get constitution_dir)"
  compiled_workflow_dir="$(bash "${PATH_HELPER}" get compiled_workflow_dir)"
  binding_dir="$(bash "${PATH_HELPER}" get binding_dir)"

  "${PYTHON_BIN}" "${CLI_PY}" persist-compile-bundle "${constitution_dir}" "${compiled_workflow_dir}" "${binding_dir}" "${request}" "${registry_ref}" "${origin}" "${compiled_json}"
}

update_workflow_run() {
  local run_id="$1"
  local state="$2"
  local result="$3"
  local status_file
  status_file="$(get_status_store)"

  "${PYTHON_BIN}" "${CLI_PY}" update-run "${status_file}" "${run_id}" "${state}" "${result}"
}

workflow_summary_field() {
  local workflow_id="$1"
  local field="$2"
  local status_file
  status_file="$(get_status_store)"

  "${PYTHON_BIN}" "${CLI_PY}" summary-field "${status_file}" "${workflow_id}" "${field}"
}

# Layer 3 fail-fast: validate the requested provider CLI before we expand the
# workflow / build the binding / spawn the runner. Same boundary as
# ensure_provider_cli in cap-workflow-exec.sh — CAP does not install or login
# providers, so an unresolvable --cli choice should halt at the entry point
# rather than surface as a confusing "command not found" deep inside execution.
validate_run_cli_choice() {
  local cli="$1"
  case "${cli}" in
    claude|codex)
      if command -v "${cli}" >/dev/null 2>&1; then
        return 0
      fi
      echo "" >&2
      echo "✗ provider CLI not on PATH: ${cli}" >&2
      echo "  CAP does not install or authenticate providers; please install it first and retry." >&2
      case "${cli}" in
        claude)
          echo "    Claude Code: https://docs.claude.com/claude-code" >&2
          ;;
        codex)
          echo "    Codex CLI:   https://developers.openai.com/codex" >&2
          ;;
      esac
      echo "  You can also run 'cap provider doctor' to inspect provider status." >&2
      return 1
      ;;
    auto|"")
      # auto resolution: at least one provider should be reachable; defer the
      # final pick to runner / binder logic. If neither is found, halt now.
      if command -v claude >/dev/null 2>&1 || command -v codex >/dev/null 2>&1; then
        return 0
      fi
      echo "" >&2
      echo "✗ No provider CLI available (neither claude nor codex is on PATH)" >&2
      echo "  CAP does not install providers; please install at least one before running." >&2
      echo "  Run 'cap provider doctor' to see full status." >&2
      return 1
      ;;
    *)
      echo "" >&2
      echo "✗ Unsupported --cli value: ${cli}" >&2
      echo "  Supported values: claude | codex | auto" >&2
      return 1
      ;;
  esac
}

COMMAND="${1:-}"
if [ -n "${COMMAND}" ] && [[ "${COMMAND}" != "list" && "${COMMAND}" != "ps" && "${COMMAND}" != "show" && "${COMMAND}" != "inspect" && "${COMMAND}" != "logs" && "${COMMAND}" != "watch" && "${COMMAND}" != "plan" && "${COMMAND}" != "bind" && "${COMMAND}" != "constitution" && "${COMMAND}" != "compile" && "${COMMAND}" != "run-task" && "${COMMAND}" != "run" && "${COMMAND}" != "update-run-status" ]]; then
  # cap workflow <id> "prompt" → run <id> "prompt"
  # cap workflow <id>          → show <id>
  if [ "$#" -ge 2 ]; then
    set -- run "$@"
  else
    set -- show "$@"
  fi
fi

case "${1:-}" in
  list)
    [ "$#" -eq 1 ] || usage
    "${PYTHON_BIN}" "${CLI_PY}" list "${WORKFLOWS_DIR}" "$(get_status_store)"
    ;;
  ps)
    shift || true
    PS_FILTER="active"
    if [ "${1:-}" = "--all" ] || [ "${1:-}" = "-a" ]; then
      PS_FILTER="all"
      shift || true
    fi
    "${PYTHON_BIN}" "${CLI_PY}" ps "$(get_status_store)" "${PS_FILTER}"
    ;;
  show)
    [ "$#" -eq 2 ] || usage
    WORKFLOW_REF="$(resolve_workflow_ref "$2")" || {
      workflow_not_found "$2"
      exit 1
    }
    "${PYTHON_BIN}" "${CLI_PY}" show "${CAP_ROOT}" "${WORKFLOW_REF}" "$(get_status_store)"
    ;;
  inspect)
    shift
    [ "$#" -ge 1 ] || usage
    # Forward all remaining args (run_id + optional --json / --cap-home);
    # argparse on the Python side does the parsing.
    "${PYTHON_BIN}" "${CLI_PY}" inspect "$(get_status_store)" "$@"
    ;;
  logs)
    # Phase 1 (Run Log Follow): docker-like view of workflow.log.
    # Bash owns IO (cat / tail -f); the Python side only resolves the
    # log path so follow semantics stay in POSIX shell tooling.
    shift
    # P3: dispatcher-side --help so users see ALL flags including the
    # bash-resolved ones (-f / --tail). Forwarding to Python --help
    # would print an incomplete list (Python only owns --step / --cap-home).
    case "${1:-}" in
      -h|--help)
        cat <<'LOGS_HELP'
cap workflow logs — print or follow a run's workflow.log (docker-like)

Usage:
  cap workflow logs [-f|--follow] [--tail N] [--since VALUE] <run-id> [--step STEP_ID] [--cap-home PATH]

Flags:
  -f, --follow             Follow appends live (tail -f). Without this flag, prints once and exits.
  --tail N                 Print only the last N lines (positive integer required).
  --since VALUE            Stream only lines whose [YYYY-MM-DD HH:MM:SS] timestamp is >= the cutoff.
                           Accepts relative duration (30s / 5m / 1h / 2d) or absolute timestamp
                           (YYYY-MM-DD HH:MM:SS). Cannot combine with -f.
  --step STEP_ID           Show a specific step's output instead of workflow.log.
                           Resolves via raw.log -> md -> handoff.md fallback.
  --cap-home PATH          Override CAP_HOME / ~/.cap for cross-repo or sandbox reads.

Examples:
  cap workflow logs run_xxx                       # entire workflow.log
  cap workflow logs -f run_xxx                    # follow workflow.log
  cap workflow logs --tail 50 run_xxx             # last 50 lines
  cap workflow logs -f --tail 20 run_xxx          # last 20 lines + follow
  cap workflow logs --since 30s run_xxx           # only lines from the last 30 seconds
  cap workflow logs --since "2026-05-09 10:00:00" run_xxx
  cap workflow logs run_xxx --step draft_constitution
  cap workflow logs -f run_xxx --step draft_constitution

See also:
  cap workflow watch <run-id>     live state snapshot
  cap workflow inspect <run-id>   one-shot run details
  cap help observe                full observability topic
LOGS_HELP
        exit 0
        ;;
    esac
    LOGS_FOLLOW=0
    LOGS_TAIL=""
    LOGS_SINCE=""
    LOGS_RUN_ID=""
    LOGS_FORWARD=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -f|--follow)
          LOGS_FOLLOW=1
          shift
          ;;
        --tail)
          [ -n "${2:-}" ] || { echo "--tail requires a positive integer" >&2; exit 1; }
          LOGS_TAIL="$2"
          shift 2
          ;;
        --tail=*)
          LOGS_TAIL="${1#--tail=}"
          shift
          ;;
        --since)
          [ -n "${2:-}" ] || { echo "--since requires a value (e.g., 30s / 5m / 1h / YYYY-MM-DD HH:MM:SS)" >&2; exit 1; }
          LOGS_SINCE="$2"
          shift 2
          ;;
        --since=*)
          LOGS_SINCE="${1#--since=}"
          shift
          ;;
        --cap-home|--step)
          [ -n "${2:-}" ] || { echo "$1 requires a value" >&2; exit 1; }
          LOGS_FORWARD+=("$1" "$2")
          shift 2
          ;;
        --cap-home=*|--step=*)
          LOGS_FORWARD+=("$1")
          shift
          ;;
        --)
          shift
          break
          ;;
        -*)
          echo "Unknown logs option: $1" >&2
          echo "Usage: cap workflow logs [-f|--follow] [--tail N] [--since VALUE] <run-id> [--step STEP_ID] [--cap-home PATH]" >&2
          exit 1
          ;;
        *)
          if [ -n "${LOGS_RUN_ID}" ]; then
            echo "logs accepts a single run-id; got extra arg: $1" >&2
            exit 1
          fi
          LOGS_RUN_ID="$1"
          shift
          ;;
      esac
    done
    if [ -z "${LOGS_RUN_ID}" ]; then
      echo "Usage: cap workflow logs [-f|--follow] [--tail N] [--since VALUE] <run-id> [--step STEP_ID] [--cap-home PATH]" >&2
      exit 1
    fi
    if [ -n "${LOGS_TAIL}" ]; then
      # Reject non-positive integers up-front so we don't pass garbage to
      # `tail -n` and surface a confusing tail(1) error instead.
      if ! [[ "${LOGS_TAIL}" =~ ^[1-9][0-9]*$ ]]; then
        echo "--tail requires a positive integer (got: ${LOGS_TAIL})" >&2
        exit 1
      fi
    fi
    if [ -n "${LOGS_SINCE}" ] && [ "${LOGS_FOLLOW}" -eq 1 ]; then
      # Phase 5: follow + --since composition is intentionally rejected.
      # The Python streamer is single-shot; supporting follow would mean
      # interleaving filter logic with tail -f's stream and the value-
      # to-complexity ratio is too low for the first --since cut.
      echo "--since cannot be combined with -f / --follow yet" >&2
      echo "  Workaround: cap workflow logs --since <value> <run-id>   (single-shot)" >&2
      echo "              cap workflow logs -f <run-id>                (follow without filter)" >&2
      exit 1
    fi
    if [ -n "${LOGS_SINCE}" ]; then
      # Python streams the filtered content directly; bash skips its
      # cat / tail wiring entirely. --tail is ignored in this mode
      # (the cutoff already bounds the output).
      exec "${PYTHON_BIN}" "${CLI_PY}" logs "${LOGS_FORWARD[@]}" --since "${LOGS_SINCE}" "${LOGS_RUN_ID}"
    fi
    LOGS_PATH="$("${PYTHON_BIN}" "${CLI_PY}" logs "${LOGS_FORWARD[@]}" "${LOGS_RUN_ID}")" || exit $?
    if [ "${LOGS_FOLLOW}" -eq 1 ]; then
      # docker logs habit: --tail N + -f shows last N lines then follows;
      # without --tail, follow shows full history then live (-n +1).
      if [ -n "${LOGS_TAIL}" ]; then
        exec tail -n "${LOGS_TAIL}" -f "${LOGS_PATH}"
      else
        exec tail -n +1 -f "${LOGS_PATH}"
      fi
    else
      if [ -n "${LOGS_TAIL}" ]; then
        exec tail -n "${LOGS_TAIL}" "${LOGS_PATH}"
      else
        exec cat "${LOGS_PATH}"
      fi
    fi
    ;;
  watch)
    # Phase 2 (Workflow Watch): live snapshot of run state. The Python
    # side owns the loop / clear-screen logic; bash here is just an arg
    # forwarder so we keep one source of truth for snapshot rendering.
    shift
    # P3: dispatcher-side --help. Python's argparse output is technically
    # complete here (all flags live on the Python side) but we keep the
    # intercept symmetric with logs and add usage examples + see-also.
    case "${1:-}" in
      -h|--help)
        cat <<'WATCH_HELP'
cap workflow watch — live snapshot of a workflow run

Usage:
  cap workflow watch [--once] [--json] [--compact] [--interval SEC] [--tail N]
                     [--failed-only] [--step STEP_ID] <run-id> [--cap-home PATH]

Flags:
  --once                   Render a single snapshot and exit (deterministic; for CI / scripts).
  --json                   Emit a JSON snapshot. Always single-shot — jq pipelines stay clean.
                           Full payload regardless of --compact (filters still applied).
  --compact                Single-screen terse view (<15 lines). Default --tail collapses to 1.
  --interval SEC           Refresh interval in seconds (default 2.0).
  --tail N                 Number of trailing workflow.log lines to show
                           (default: 10 verbose / 1 compact).
  --failed-only            Filter steps / sessions / artifacts to failed entries only.
                           Empty result renders "(no failed steps)" so the filter is visibly applied.
  --step STEP_ID           Focus on a single step's row + its sessions + artifacts.
                           Missing step exits 1 with a clear error.
  --cap-home PATH          Override CAP_HOME / ~/.cap for cross-repo or sandbox reads.

Behaviour:
  - tty default loops with ANSI clear-and-redraw every --interval seconds.
  - pipe / redirect auto-falls-back to single-shot so output stays grep-friendly.
  - Ctrl-C exits the loop cleanly (exit 0).
  - Header / step rows / session rows carry status glyphs (✓/●/○/✗/...).
  - "Next:" footer suggests the next command based on run state.

Examples:
  cap workflow watch run_xxx
  cap workflow watch --once run_xxx
  cap workflow watch --compact run_xxx
  cap workflow watch --failed-only run_xxx              # focus on failures
  cap workflow watch --step draft_constitution run_xxx  # single-step focus
  cap workflow watch --json run_xxx | jq .summary
  cap workflow watch --interval 1 --tail 20 run_xxx

See also:
  cap workflow logs <run-id>      print / follow workflow.log
  cap workflow inspect <run-id>   one-shot run details
  cap help observe                full observability topic
WATCH_HELP
        exit 0
        ;;
    esac
    WATCH_RUN_ID=""
    WATCH_FORWARD=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --once|--json|--compact|--failed-only)
          WATCH_FORWARD+=("$1")
          shift
          ;;
        --interval|--tail|--cap-home|--step)
          [ -n "${2:-}" ] || { echo "$1 requires a value" >&2; exit 1; }
          WATCH_FORWARD+=("$1" "$2")
          shift 2
          ;;
        --interval=*|--tail=*|--cap-home=*|--step=*)
          WATCH_FORWARD+=("$1")
          shift
          ;;
        --)
          shift
          break
          ;;
        -*)
          echo "Unknown watch option: $1" >&2
          echo "Usage: cap workflow watch [--once] [--json] [--compact] [--interval SEC] [--tail N] [--failed-only] [--step STEP_ID] <run-id> [--cap-home PATH]" >&2
          exit 1
          ;;
        *)
          if [ -n "${WATCH_RUN_ID}" ]; then
            echo "watch accepts a single run-id; got extra arg: $1" >&2
            exit 1
          fi
          WATCH_RUN_ID="$1"
          shift
          ;;
      esac
    done
    if [ -z "${WATCH_RUN_ID}" ]; then
      echo "Usage: cap workflow watch [--once] [--json] [--compact] [--interval SEC] [--tail N] [--failed-only] [--step STEP_ID] <run-id> [--cap-home PATH]" >&2
      exit 1
    fi
    exec "${PYTHON_BIN}" "${CLI_PY}" watch "${WATCH_FORWARD[@]}" "${WATCH_RUN_ID}"
    ;;
  plan)
    [ "$#" -eq 2 ] || usage
    WORKFLOW_REF="$(resolve_workflow_ref "$2")" || {
      workflow_not_found "$2"
      exit 1
    }
    "${PYTHON_BIN}" "${CLI_PY}" plan "${CAP_ROOT}" "${WORKFLOW_REF}"
    ;;
  bind)
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
    WORKFLOW_REF="$(resolve_workflow_ref "$2")" || {
      workflow_not_found "$2"
      exit 1
    }
    REGISTRY_REF="${3:-}"
    BINDING_JSON="$("${PYTHON_BIN}" "${CLI_PY}" bind "${CAP_ROOT}" "${WORKFLOW_REF}" "${REGISTRY_REF}")"
    BINDING_WORKFLOW_ID="$(printf '%s' "${BINDING_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["workflow_id"])')"
    BINDING_WORKFLOW_NAME="$(basename "${WORKFLOW_REF}")"
    BINDING_SNAPSHOT_JSON="$(persist_binding_snapshot "${BINDING_JSON}" "${BINDING_WORKFLOW_ID}" "${BINDING_WORKFLOW_NAME}" "${WORKFLOW_REF}" "bind")"
    "${PYTHON_BIN}" "${CLI_PY}" print-bind-report "${BINDING_JSON}" "${BINDING_SNAPSHOT_JSON}"
    ;;
  constitution)
    shift || true
    # P2 #6: this CLI surface is being phased out — `cap task constitution`
    # is the canonical name. Behaviour and exit code are unchanged so the
    # alias is a transparent rename. CAP_DEPRECATION_SILENT=1 suppresses the
    # notice (the cap-task.sh wrapper sets it; smoke fixtures may also opt
    # out when warning text would pollute fixture diffs).
    #
    # Emitted before the usage check so even users who reach this branch
    # by accident learn the new name; suppressing the check would risk
    # masking the deprecation entirely from anyone running the legacy
    # form without arguments to remind themselves of the syntax.
    if [ "${CAP_DEPRECATION_SILENT:-}" != "1" ]; then
      echo "[deprecated] cap workflow constitution is deprecated; use cap task constitution" >&2
    fi
    [ "$#" -ge 1 ] || {
      echo "Usage: cap workflow constitution <request...>" >&2
      exit 1
    }
    REQUEST="$*"
    CONSTITUTION_JSON="$("${PYTHON_BIN}" "${CLI_PY}" constitution-json "${CAP_ROOT}" "${REQUEST}")"
    CONSTITUTION_SNAPSHOT_JSON="$(persist_constitution_artifact "${CONSTITUTION_JSON}" "${REQUEST}" "constitution")"
    "${PYTHON_BIN}" "${CLI_PY}" print-constitution-report "${CONSTITUTION_JSON}" "${CONSTITUTION_SNAPSHOT_JSON}"
    ;;
  compile)
    shift || true
    REGISTRY_REF=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --registry) REGISTRY_REF="$2"; shift 2 ;;
        *) break ;;
      esac
    done
    [ "$#" -ge 1 ] || {
      echo "Usage: cap workflow compile <request...> [--registry path]" >&2
      exit 1
    }
    REQUEST="$*"
    COMPILED_JSON="$("${PYTHON_BIN}" "${CLI_PY}" compile-json "${CAP_ROOT}" "${REQUEST}" "${REGISTRY_REF}")"
    COMPILE_SNAPSHOT_JSON="$(persist_task_compile_bundle "${COMPILED_JSON}" "${REQUEST}" "${REGISTRY_REF}" "compile")"
    "${PYTHON_BIN}" "${CLI_PY}" print-compile-report "${COMPILED_JSON}" "${COMPILE_SNAPSHOT_JSON}"
    ;;
  run-task)
    shift || true

    DETACH=0
    DRY_RUN=0
    RUN_CLI="${CAP_DEFAULT_AGENT_CLI:-auto}"
    CLI_OVERRIDE=0
    REGISTRY_REF=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -d) DETACH=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --cli) RUN_CLI="$2"; CLI_OVERRIDE=1; shift 2 ;;
        --registry) REGISTRY_REF="$2"; shift 2 ;;
        *) break ;;
      esac
    done

    [ "$#" -ge 1 ] || {
      echo "Usage: cap workflow run-task [--dry-run] [-d] [--cli codex|claude] [--registry path] <request...>" >&2
      exit 1
    }

    USER_PROMPT="$*"
    COMPILED_JSON="$("${PYTHON_BIN}" "${CLI_PY}" compile-json "${CAP_ROOT}" "${USER_PROMPT}" "${REGISTRY_REF}")"

    PLAN_JSON="$(printf '%s' "${COMPILED_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["plan"], ensure_ascii=False))')"
    CONSTITUTION_JSON="$(printf '%s' "${COMPILED_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["task_constitution"], ensure_ascii=False))')"
    POLICY_JSON="$(printf '%s' "${COMPILED_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["unresolved_policy"], ensure_ascii=False))')"
    PREFLIGHT_JSON="$(printf '%s' "${COMPILED_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["preflight_report"], ensure_ascii=False))')"
    WORKFLOW_ID="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["workflow_id"])')"
    WORKFLOW_NAME="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
    BINDING_JSON="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["binding"], ensure_ascii=False))')"
    BINDING_STATUS="$(printf '%s' "${BINDING_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["binding_status"])')"
    COMPILE_SNAPSHOT_JSON="$(persist_task_compile_bundle "${COMPILED_JSON}" "${USER_PROMPT}" "${REGISTRY_REF}" "run-task")"

    if [ "${DRY_RUN}" -eq 1 ]; then
      echo ""
      echo "COMPILED WORKFLOW DRY RUN — ${WORKFLOW_NAME}"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      "${PYTHON_BIN}" "${CLI_PY}" print-compiled-dry-run \
        "${CONSTITUTION_JSON}" "${POLICY_JSON}" "${PLAN_JSON}" "${COMPILE_SNAPSHOT_JSON}" \
        --preflight-json "${PREFLIGHT_JSON}" --binding-json "${BINDING_JSON}"
      echo ""
      exit 0
    fi

    if [ "${BINDING_STATUS}" = "blocked" ]; then
      echo ""
      echo "COMPILED WORKFLOW PREFLIGHT BLOCKED — ${WORKFLOW_NAME}"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      "${PYTHON_BIN}" "${CLI_PY}" print-compiled-blocked "${CONSTITUTION_JSON}" "${POLICY_JSON}" "${BINDING_JSON}" "${COMPILE_SNAPSHOT_JSON}"
      echo ""
      exit 2
    fi

    if [ "${BINDING_STATUS}" = "degraded" ]; then
      echo ""
      echo "COMPILED WORKFLOW PREFLIGHT DEGRADED — ${WORKFLOW_NAME}"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      "${PYTHON_BIN}" "${CLI_PY}" print-compiled-degraded "${POLICY_JSON}" "${COMPILE_SNAPSHOT_JSON}"
      echo ""
    fi

    if [ "${DETACH}" -eq 1 ]; then
      RUN_ID="$(create_workflow_run "${WORKFLOW_ID}" "${WORKFLOW_NAME}" "detached" "background_start" "detached" "${RUN_CLI}" "${USER_PROMPT}")"
      echo "Background mode is not yet implemented."
      echo "RUN ID: ${RUN_ID}"
      exit 0
    fi

    validate_run_cli_choice "${RUN_CLI}" || exit 1

    RUN_ID="$(create_workflow_run "${WORKFLOW_ID}" "${WORKFLOW_NAME}" "executing" "foreground_start" "foreground" "${RUN_CLI}" "${USER_PROMPT}")"
    bash "${SCRIPT_DIR}/trace-log.sh" append "Workflow" "compiled_workflow:${WORKFLOW_ID} run:${RUN_ID} 啟動 (${WORKFLOW_NAME})" "成功" >/dev/null 2>&1 || true
    "${PYTHON_BIN}" "${CLI_PY}" print-compile-start "${COMPILE_SNAPSHOT_JSON}" "${RUN_ID}"
    if [ "${CLI_OVERRIDE}" -eq 1 ]; then
      CAP_WORKFLOW_REQUESTED_STRATEGY="auto" CAP_WORKFLOW_SELECTED_STRATEGY="fixed" CAP_WORKFLOW_REQUESTED_MODE="auto" CAP_WORKFLOW_SELECTED_MODE="fixed" exec bash "${SCRIPT_DIR}/cap-workflow-exec.sh" "${PLAN_JSON}" "${USER_PROMPT}" --cli "${RUN_CLI}" --run-id "${RUN_ID}"
    fi
    CAP_WORKFLOW_REQUESTED_STRATEGY="auto" CAP_WORKFLOW_SELECTED_STRATEGY="fixed" CAP_WORKFLOW_REQUESTED_MODE="auto" CAP_WORKFLOW_SELECTED_MODE="fixed" exec bash "${SCRIPT_DIR}/cap-workflow-exec.sh" "${PLAN_JSON}" "${USER_PROMPT}" --run-id "${RUN_ID}"
    ;;
  run)
    shift || true

    DETACH=0
    DRY_RUN=0
    RUN_CLI="${CAP_DEFAULT_AGENT_CLI:-auto}"
    CLI_OVERRIDE=0
    EXECUTION_STRATEGY="auto"
    DESIGN_SOURCE=""
    DESIGN_URL=""
    DESIGN_PATH=""
    DESIGN_PACKAGE=""
    DESIGN_FIGMA_TARGET=""
    DESIGN_SCRIPT=""
    DESIGN_NO=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -d)       DETACH=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --cli)    RUN_CLI="$2"; CLI_OVERRIDE=1; shift 2 ;;
        --strategy) EXECUTION_STRATEGY="$2"; shift 2 ;;
        --mode)   EXECUTION_STRATEGY="$2"; shift 2 ;;
        --design-source) DESIGN_SOURCE="$2"; shift 2 ;;
        --design-url) DESIGN_URL="$2"; shift 2 ;;
        --design-path) DESIGN_PATH="$2"; shift 2 ;;
        --design-package) DESIGN_PACKAGE="$2"; shift 2 ;;
        --design-figma-target) DESIGN_FIGMA_TARGET="$2"; shift 2 ;;
        --design-script) DESIGN_SCRIPT="$2"; shift 2 ;;
        --no-design) DESIGN_NO=1; shift ;;
        *)        break ;;
      esac
    done

    [ "$#" -ge 1 ] || {
      echo "Usage: cap workflow run [--dry-run] [-d] [--cli codex|claude] [--strategy fast|governed|strict|auto] [--design-source TYPE] [--design-url URL] [--design-path PATH] [--design-package NAME] [--design-figma-target NAME] [--design-script PATH] [--no-design] <workflow> [prompt...]" >&2
      exit 1
    }
    case "${EXECUTION_STRATEGY}" in
      fast|quick|governed|strict|company|auto) ;;
      *)
        echo "Unsupported --strategy: ${EXECUTION_STRATEGY}. Accepted values: fast | governed | strict | auto" >&2
        exit 1
        ;;
    esac

    WORKFLOW_ARG="$1"
    if [ "${EXECUTION_STRATEGY}" = "auto" ]; then
      case "${WORKFLOW_ARG}" in
        version-control-quick) EXECUTION_STRATEGY="fast" ;;
        version-control-private) EXECUTION_STRATEGY="governed" ;;
        version-control-company) EXECUTION_STRATEGY="strict" ;;
      esac
    fi

    WORKFLOW_REF="$(resolve_workflow_ref "${WORKFLOW_ARG}")" || {
      workflow_not_found "${WORKFLOW_ARG}"
      exit 1
    }
    shift
    USER_PROMPT="$*"

    # Design-source augment (only effective for planning workflows; helper
    # short-circuits with exit 10 for everything else and prints the prompt
    # unchanged). exit 20 = user aborted interactive prompt; exit 30 = bad
    # flag combination. Anything else passes through untouched.
    DESIGN_TEMPLATES_PATH="${CAP_ROOT}/schemas/design-source-templates.yaml"
    if [ -f "${DESIGN_TEMPLATES_PATH}" ]; then
      DESIGN_AUGMENT_ARGS=( augment
        --templates "${DESIGN_TEMPLATES_PATH}"
        --workflow-id "${WORKFLOW_ARG}"
        --prompt-stdin )
      [ -n "${DESIGN_SOURCE}" ] && DESIGN_AUGMENT_ARGS+=( --design-source "${DESIGN_SOURCE}" )
      [ -n "${DESIGN_URL}" ] && DESIGN_AUGMENT_ARGS+=( --design-url "${DESIGN_URL}" )
      [ -n "${DESIGN_PATH}" ] && DESIGN_AUGMENT_ARGS+=( --design-path "${DESIGN_PATH}" )
      [ -n "${DESIGN_PACKAGE}" ] && DESIGN_AUGMENT_ARGS+=( --design-package "${DESIGN_PACKAGE}" )
      [ -n "${DESIGN_FIGMA_TARGET}" ] && DESIGN_AUGMENT_ARGS+=( --design-figma-target "${DESIGN_FIGMA_TARGET}" )
      [ -n "${DESIGN_SCRIPT}" ] && DESIGN_AUGMENT_ARGS+=( --design-script "${DESIGN_SCRIPT}" )
      [ "${DESIGN_NO}" -eq 1 ] && DESIGN_AUGMENT_ARGS+=( --no-design )

      DESIGN_RC=0
      DESIGN_OUT="$(printf '%s' "${USER_PROMPT}" | "${PYTHON_BIN}" "${CAP_ROOT}/engine/design_prompt.py" "${DESIGN_AUGMENT_ARGS[@]}")" || DESIGN_RC=$?
      case "${DESIGN_RC}" in
        0|10) USER_PROMPT="${DESIGN_OUT}" ;;
        20) echo "[cap] design-source prompt aborted; workflow was not executed." >&2; exit 20 ;;
        30) echo "[cap] invalid design-source flag combination; see 'cap workflow run' usage for details." >&2; exit 30 ;;
        *) echo "[cap] design-source handling failed unexpectedly (rc=${DESIGN_RC}); keeping the original prompt." >&2 ;;
      esac
    fi

    PLAN_JSON="$("${PYTHON_BIN}" "${CLI_PY}" build-bound-plan "${CAP_ROOT}" "${WORKFLOW_REF}")"

    WORKFLOW_ID="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["workflow_id"])')"
    WORKFLOW_NAME="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
    BINDING_JSON="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["binding"], ensure_ascii=False))')"
    BINDING_STATUS="$(printf '%s' "${BINDING_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["binding_status"])')"

    WORKFLOW_PROJECT_ID_OVERRIDE=""
    if [ "${WORKFLOW_ID}" = "project-constitution" ]; then
      WORKFLOW_PROJECT_ID_OVERRIDE="project-constitution-bootstrap"
    fi
    export CAP_PROJECT_ID_OVERRIDE="${WORKFLOW_PROJECT_ID_OVERRIDE}"

    BINDING_SNAPSHOT_JSON="$(persist_binding_snapshot "${BINDING_JSON}" "${WORKFLOW_ID}" "${WORKFLOW_NAME}" "${WORKFLOW_REF}" "run")"

    if [ -z "${USER_PROMPT}" ]; then
      if [ -t 0 ]; then
        printf 'Enter workflow task description (press Enter to show plan only): ' >&2
        read -r USER_PROMPT || true
      fi
    fi

    STRATEGY_RESOLUTION_JSON="$(resolve_run_execution_mode "${WORKFLOW_REF}" "${EXECUTION_STRATEGY}" "${USER_PROMPT}")"
    SELECTOR_APPLIED="$(printf '%s' "${STRATEGY_RESOLUTION_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["selector_applied"])')"
    SELECTED_STRATEGY="$(printf '%s' "${STRATEGY_RESOLUTION_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["selected_strategy"])')"
    STRATEGY_REASON="$(printf '%s' "${STRATEGY_RESOLUTION_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["reason"])')"
    STRATEGY_CONFIDENCE="$(printf '%s' "${STRATEGY_RESOLUTION_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["confidence"])')"
    SELECTED_WORKFLOW_REF="$(printf '%s' "${STRATEGY_RESOLUTION_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["selected_workflow_ref"])')"
    if [ "${SELECTOR_APPLIED}" = "True" ]; then
      WORKFLOW_REF="${SELECTED_WORKFLOW_REF}"
      PLAN_JSON="$("${PYTHON_BIN}" "${CLI_PY}" build-bound-plan "${CAP_ROOT}" "${WORKFLOW_REF}")"
      WORKFLOW_ID="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["workflow_id"])')"
      WORKFLOW_NAME="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
      BINDING_JSON="$(printf '%s' "${PLAN_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["binding"], ensure_ascii=False))')"
      BINDING_STATUS="$(printf '%s' "${BINDING_JSON}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["binding_status"])')"
      BINDING_SNAPSHOT_JSON="$(persist_binding_snapshot "${BINDING_JSON}" "${WORKFLOW_ID}" "${WORKFLOW_NAME}" "${WORKFLOW_REF}" "run")"
    fi

    if [ -z "${USER_PROMPT}" ] || [ "${DRY_RUN}" -eq 1 ]; then
      echo ""
      if [ "${DRY_RUN}" -eq 1 ]; then
        echo "WORKFLOW DRY RUN — ${WORKFLOW_NAME}"
      else
        echo "WORKFLOW PLAN — ${WORKFLOW_NAME}"
      fi
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo ""
      if [ "${SELECTOR_APPLIED}" = "True" ]; then
        echo "  Strategy: ${SELECTED_STRATEGY} (${EXECUTION_STRATEGY})"
        echo "  Reason: ${STRATEGY_REASON}"
        echo "  Confidence: ${STRATEGY_CONFIDENCE}"
        echo ""
      fi
      "${PYTHON_BIN}" "${CLI_PY}" print-workflow-plan "${PLAN_JSON}"
      echo ""
      "${PYTHON_BIN}" "${CLI_PY}" print-binding-summary "${BINDING_JSON}" "${BINDING_SNAPSHOT_JSON}"
      echo ""
      if [ "${DRY_RUN}" -eq 1 ]; then
        echo "  Dry run only — no step was executed."
      else
        echo "  To execute: cap workflow run ${WORKFLOW_ID} \"<prompt>\""
      fi
      echo ""
      exit 0
    fi

    if [ "${BINDING_STATUS}" = "blocked" ]; then
      echo ""
      echo "WORKFLOW PREFLIGHT BLOCKED — ${WORKFLOW_NAME}"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      if [ "${SELECTOR_APPLIED}" = "True" ]; then
        echo "strategy: ${SELECTED_STRATEGY} (${EXECUTION_STRATEGY})"
        echo "reason: ${STRATEGY_REASON}"
        echo ""
      fi
      "${PYTHON_BIN}" "${CLI_PY}" print-binding-blocked "${BINDING_JSON}" "${BINDING_SNAPSHOT_JSON}"
      echo ""
      echo "Workflow halted. Please establish a Project Constitution first, or fix the skill registry / adjust the binding policy."
      exit 2
    fi

    if [ "${BINDING_STATUS}" = "degraded" ]; then
      echo ""
      echo "WORKFLOW PREFLIGHT DEGRADED — ${WORKFLOW_NAME}"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      if [ "${SELECTOR_APPLIED}" = "True" ]; then
        echo "strategy: ${SELECTED_STRATEGY} (${EXECUTION_STRATEGY})"
        echo "reason: ${STRATEGY_REASON}"
        echo ""
      fi
      "${PYTHON_BIN}" "${CLI_PY}" print-binding-degraded "${BINDING_JSON}" "${BINDING_SNAPSHOT_JSON}"
      echo ""
      echo "Continuing in degraded mode."
    fi

    if [ "${DETACH}" -eq 1 ]; then
      RUN_ID="$(create_workflow_run "${WORKFLOW_ID}" "${WORKFLOW_NAME}" "detached" "background_start" "detached" "${RUN_CLI}" "${USER_PROMPT}")"
      bash "${SCRIPT_DIR}/trace-log.sh" append "Workflow" "workflow:${WORKFLOW_ID} run:${RUN_ID} 啟動背景執行 (${WORKFLOW_NAME})" "成功" >/dev/null 2>&1 || true
      echo "Background mode is not yet implemented."
      echo "RUN ID: ${RUN_ID}"
      echo "Use foreground: cap workflow run ${WORKFLOW_ID} \"<prompt>\""
      exit 0
    fi

    validate_run_cli_choice "${RUN_CLI}" || exit 1

    RUN_ID="$(create_workflow_run "${WORKFLOW_ID}" "${WORKFLOW_NAME}" "executing" "foreground_start" "foreground" "${RUN_CLI}" "${USER_PROMPT}")"
    bash "${SCRIPT_DIR}/trace-log.sh" append "Workflow" "workflow:${WORKFLOW_ID} run:${RUN_ID} 啟動 (${WORKFLOW_NAME})" "成功" >/dev/null 2>&1 || true
    if [ "${SELECTOR_APPLIED}" = "True" ]; then
      echo "  Strategy: ${SELECTED_STRATEGY} (${EXECUTION_STRATEGY})"
      echo "  Reason: ${STRATEGY_REASON}"
      echo "  Confidence: ${STRATEGY_CONFIDENCE}"
    fi
    "${PYTHON_BIN}" "${CLI_PY}" print-binding-start "${BINDING_SNAPSHOT_JSON}" "${RUN_ID}"
    if [ "${CLI_OVERRIDE}" -eq 1 ]; then
      CAP_WORKFLOW_REQUESTED_STRATEGY="${EXECUTION_STRATEGY}" CAP_WORKFLOW_SELECTED_STRATEGY="${SELECTED_STRATEGY}" CAP_WORKFLOW_REQUESTED_MODE="${EXECUTION_STRATEGY}" CAP_WORKFLOW_SELECTED_MODE="${SELECTED_STRATEGY}" CAP_PROJECT_ID_OVERRIDE="${CAP_PROJECT_ID_OVERRIDE:-}" exec bash "${SCRIPT_DIR}/cap-workflow-exec.sh" "${PLAN_JSON}" "${USER_PROMPT}" --cli "${RUN_CLI}" --run-id "${RUN_ID}"
    fi
    CAP_WORKFLOW_REQUESTED_STRATEGY="${EXECUTION_STRATEGY}" CAP_WORKFLOW_SELECTED_STRATEGY="${SELECTED_STRATEGY}" CAP_WORKFLOW_REQUESTED_MODE="${EXECUTION_STRATEGY}" CAP_WORKFLOW_SELECTED_MODE="${SELECTED_STRATEGY}" CAP_PROJECT_ID_OVERRIDE="${CAP_PROJECT_ID_OVERRIDE:-}" exec bash "${SCRIPT_DIR}/cap-workflow-exec.sh" "${PLAN_JSON}" "${USER_PROMPT}" --run-id "${RUN_ID}"
    ;;
  update-run-status)
    [ "$#" -eq 4 ] || usage
    update_workflow_run "$2" "$3" "$4"
    ;;
  *)
    usage
    ;;
esac
