#!/bin/bash
#
# cap-replay.sh — H1 #4 shell wrapper for `cap replay verify <run_id>`.
#
# Resolves a run_id (or absolute run_dir path) to a CAP run directory
# under the active project's workflow_report_dir, invokes
# engine/replay_verifier.py with --write to materialise both
# replay-verdict.json and snapshots/agent-skills.json, then prints a
# one-line human-readable summary and propagates the verifier's exit
# code per docs/cap/REPLAY-CONTRACT-DESIGN.md §6.2:
#   replayable / drifted_compatible / unverifiable → 0
#   drifted_incompatible → 4 (block — sibling of P8 governance gate)
#   not_found → 2

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PATH_HELPER="${SCRIPT_DIR}/cap-paths.sh"
VERIFIER_PY="${CAP_ROOT}/engine/replay_verifier.py"

usage() {
  cat <<'EOF' >&2
Usage:
  cap replay verify <run_id_or_run_dir> [--json] [--no-write]

Examples:
  cap replay verify run_20260507120304_aabbccdd
  cap replay verify ~/.cap/projects/<id>/reports/workflows/<wf>/run_xxx/
  cap replay verify run_xxx --json

Behaviour:
  * Looks up <run_id> under the active project's workflow_report_dir
    (<workflow_report_dir>/*/<run_id>) when the argument is not a
    filesystem path.
  * Writes <run_dir>/replay-verdict.json and <run_dir>/snapshots/
    agent-skills.json by default; pass --no-write to print only.
  * Exit codes: 0 (replayable / drifted_compatible / unverifiable),
    4 (drifted_incompatible), 2 (not_found), 1 (internal error).
EOF
  exit 1
}

resolve_python() {
  if [ -x "${CAP_ROOT}/.venv/bin/python" ]; then
    printf '%s\n' "${CAP_ROOT}/.venv/bin/python"
  else
    printf '%s\n' "python3"
  fi
}

PYTHON_BIN="$(resolve_python)"

# resolve_run_dir <arg> → prints absolute run_dir to stdout, exits 2 on miss.
resolve_run_dir() {
  local arg="$1"

  # Already a path (absolute or contains /) → use as-is.
  case "${arg}" in
    /*|*"/"*)
      if [ -d "${arg}" ]; then
        # canonicalise via cd / pwd -P (no realpath dependency).
        ( cd "${arg}" && pwd -P )
        return 0
      fi
      printf 'cap replay: run dir not found: %s\n' "${arg}" >&2
      return 2
      ;;
  esac

  # Treat as run_id → glob under workflow_report_dir.
  local report_dir
  if ! report_dir="$(bash "${PATH_HELPER}" get workflow_report_dir 2>/dev/null)"; then
    printf 'cap replay: failed to resolve workflow_report_dir; ensure cap project context is set.\n' >&2
    return 1
  fi
  if [ -z "${report_dir}" ] || [ ! -d "${report_dir}" ]; then
    printf 'cap replay: workflow_report_dir does not exist: %s\n' "${report_dir}" >&2
    return 2
  fi

  local matches=()
  while IFS= read -r -d '' candidate; do
    matches+=("${candidate}")
  done < <(find "${report_dir}" -mindepth 2 -maxdepth 2 -type d -name "${arg}" -print0 2>/dev/null || true)

  case "${#matches[@]}" in
    0)
      printf 'cap replay: run_id not found under %s: %s\n' "${report_dir}" "${arg}" >&2
      return 2
      ;;
    1)
      printf '%s\n' "${matches[0]}"
      return 0
      ;;
    *)
      printf 'cap replay: ambiguous run_id %s — multiple matches:\n' "${arg}" >&2
      printf '  %s\n' "${matches[@]}" >&2
      return 1
      ;;
  esac
}

# ── Argument parsing ────────────────────────────────────────────────

[ $# -ge 1 ] || usage

SUBCOMMAND="$1"
shift

case "${SUBCOMMAND}" in
  verify) ;;
  -h|--help) usage ;;
  *)
    printf 'cap replay: unknown subcommand: %s\n' "${SUBCOMMAND}" >&2
    usage
    ;;
esac

[ $# -ge 1 ] || usage

RAW_ARG="$1"
shift

JSON_MODE=0
WRITE_MODE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON_MODE=1 ;;
    --no-write) WRITE_MODE=0 ;;
    *)
      printf 'cap replay: unknown flag: %s\n' "$1" >&2
      usage
      ;;
  esac
  shift
done

# ── Resolve run_dir ─────────────────────────────────────────────────

set +e
RUN_DIR="$(resolve_run_dir "${RAW_ARG}")"
RESOLVE_RC=$?
set -e
if [ "${RESOLVE_RC}" -ne 0 ]; then
  exit "${RESOLVE_RC}"
fi

# ── Run verifier ────────────────────────────────────────────────────

VERIFY_ARGS=(verify "${RUN_DIR}")
if [ "${WRITE_MODE}" -eq 1 ]; then
  VERIFY_ARGS+=(--write)
fi

set +e
VERIFY_OUT="$("${PYTHON_BIN}" "${VERIFIER_PY}" "${VERIFY_ARGS[@]}")"
VERIFY_RC=$?
set -e

if [ "${JSON_MODE}" -eq 1 ]; then
  printf '%s\n' "${VERIFY_OUT}"
  exit "${VERIFY_RC}"
fi

# Human-readable summary: pull verdict + reason from the JSON.
VERDICT="$(printf '%s' "${VERIFY_OUT}" | "${PYTHON_BIN}" -c "
import json, sys
try:
    print(json.loads(sys.stdin.read())['verdict'])
except Exception:
    print('unknown')
")"
REASON="$(printf '%s' "${VERIFY_OUT}" | "${PYTHON_BIN}" -c "
import json, sys
try:
    print(json.loads(sys.stdin.read()).get('reason', ''))
except Exception:
    print('')
")"

printf 'cap replay: %s — %s\n' "${VERDICT}" "${RUN_DIR}"
[ -n "${REASON}" ] && printf '  reason: %s\n' "${REASON}"

# H2 #4: print per-axis summary lines when both axes have signal so
# the user can see why the aggregate verdict landed where it did.
AXES_LINE="$(printf '%s' "${VERIFY_OUT}" | "${PYTHON_BIN}" -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    drift = d.get('drift_details') or {}
    psd = drift.get('project_skill_diff') or {}
    builtin_used = drift.get('prompt_files_used') or []
    builtin_changed = drift.get('prompt_files_changed') or []
    builtin_removed = drift.get('prompt_files_removed') or []
    builtin_match = drift.get('dir_hash_match', False)
    if builtin_changed or builtin_removed:
        print('  builtin: drifted_incompatible (' + str(len(builtin_changed)) + ' changed, ' + str(len(builtin_removed)) + ' removed)')
    elif not builtin_match and d.get('baseline_observed'):
        print('  builtin: drifted_compatible (dir_hash differs, ' + str(len(builtin_used)) + ' files used unaffected)')
    elif d.get('baseline_observed'):
        print('  builtin: replayable')
    if psd:
        ax = psd.get('axis_verdict', '')
        sc = psd.get('skills_changed') or []
        sr = psd.get('skills_removed') or []
        sm = psd.get('skills_added_masked') or []
        su = psd.get('skills_used') or []
        if ax == 'drifted_incompatible':
            print('  project: drifted_incompatible (' + str(len(sc)) + ' changed, ' + str(len(sr)) + ' removed, ' + str(len(sm)) + ' masked)')
        elif ax == 'drifted_compatible':
            print('  project: drifted_compatible (dir_hash differs, ' + str(len(su)) + ' skills used unaffected)')
        elif ax == 'replayable':
            print('  project: replayable')
        elif ax == 'unverifiable_axis':
            print('  project: unverifiable (no project_skill_baseline recorded)')
except Exception:
    pass
")"
[ -n "${AXES_LINE}" ] && printf '%s\n' "${AXES_LINE}"

if [ "${WRITE_MODE}" -eq 1 ] && [ "${VERDICT}" != "not_found" ]; then
  printf '  verdict file: %s/replay-verdict.json\n' "${RUN_DIR}"
  if [ -f "${RUN_DIR}/snapshots/agent-skills.json" ]; then
    printf '  snapshot mirror: %s/snapshots/agent-skills.json\n' "${RUN_DIR}"
  fi
  if [ -f "${RUN_DIR}/snapshots/project-skills.json" ]; then
    printf '                   %s/snapshots/project-skills.json\n' "${RUN_DIR}"
  fi
  if [ -f "${RUN_DIR}/snapshots/binding-summary.json" ]; then
    printf '                   %s/snapshots/binding-summary.json\n' "${RUN_DIR}"
  fi
fi

exit "${VERIFY_RC}"
