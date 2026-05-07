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

# H3 #4 fix: use a local SCRIPT_REPO variable for the path to the
# cap-protocols repo where this wrapper lives, so we don't clobber the
# env CAP_ROOT (which downstream snapshot helpers like
# capability_schema_snapshot.py honour to locate the project's
# cap_root). Previously this script overwrote CAP_ROOT, masking the
# caller's value before forking python.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"
PATH_HELPER="${SCRIPT_DIR}/cap-paths.sh"
VERIFIER_PY="${SCRIPT_REPO}/engine/replay_verifier.py"

usage() {
  cat <<'EOF' >&2
Usage:
  cap replay verify <run_id_or_run_dir> [--json] [--no-write] [--project-id <id>] [--strict-unverifiable]

Examples:
  cap replay verify run_20260507120304_aabbccdd
  cap replay verify ~/.cap/projects/<id>/reports/workflows/<wf>/run_xxx/
  cap replay verify run_xxx --json
  cap replay verify run_xxx --project-id project-constitution-bootstrap
  cap replay verify run_xxx --strict-unverifiable

Behaviour:
  * Looks up <run_id> under the active project's workflow_report_dir
    (<workflow_report_dir>/*/<run_id>) when the argument is not a
    filesystem path.
  * --project-id <id>: glob under <CAP_HOME>/projects/<id>/reports/
    workflows/ instead of the cwd-resolved project. Useful for
    bootstrap-mode runs (project-constitution writes to
    project-constitution-bootstrap regardless of cwd) or for
    inspecting runs in another project from outside its repo.
  * --strict-unverifiable: opt-in (H4 minimal). When the top-level
    verdict is `unverifiable`, escalate exit code from 0 to 4 so CI
    treats unverifiable runs as block-worthy. Default OFF preserves
    H1+H2+H3 behaviour where unverifiable is a soft signal.
  * Writes <run_dir>/replay-verdict.json and <run_dir>/snapshots/
    {agent-skills,project-skills,binding-summary,workflow-yaml,
    constitution,capability-schema}.json by default; pass --no-write
    to print only.
  * Exit codes: 0 (replayable / drifted_compatible / unverifiable),
    4 (drifted_incompatible; with --strict-unverifiable, also
    unverifiable), 2 (not_found), 1 (internal error).
EOF
  exit 1
}

resolve_python() {
  if [ -x "${SCRIPT_REPO}/.venv/bin/python" ]; then
    printf '%s\n' "${SCRIPT_REPO}/.venv/bin/python"
  else
    printf '%s\n' "python3"
  fi
}

PYTHON_BIN="$(resolve_python)"

# resolve_run_dir <arg> [<project_id_override>] → prints absolute
# run_dir to stdout, exits 2 on miss. When project_id_override is
# non-empty, glob under <CAP_HOME>/projects/<override>/reports/
# workflows/ instead of the cwd-resolved project (H2.5 #1: bootstrap /
# cross-project run support).
resolve_run_dir() {
  local arg="$1"
  local project_override="${2:-}"

  # Already a path (absolute or contains /) → use as-is, ignoring
  # project_id override (an explicit path is unambiguous).
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
  if [ -n "${project_override}" ]; then
    # Build path directly from CAP_HOME + project_id override; do not
    # consult cap-paths.sh since the override may name a project that
    # the current cwd does not host (e.g., bootstrap projects).
    local cap_home_resolved="${CAP_HOME:-${HOME}/.cap}"
    report_dir="${cap_home_resolved}/projects/${project_override}/reports/workflows"
  else
    if ! report_dir="$(bash "${PATH_HELPER}" get workflow_report_dir 2>/dev/null)"; then
      printf 'cap replay: failed to resolve workflow_report_dir; ensure cap project context is set or pass --project-id.\n' >&2
      return 1
    fi
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
PROJECT_ID_OVERRIDE=""
STRICT_UNVERIFIABLE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON_MODE=1; shift ;;
    --no-write) WRITE_MODE=0; shift ;;
    --strict-unverifiable) STRICT_UNVERIFIABLE=1; shift ;;
    --project-id)
      [ $# -ge 2 ] || { printf 'cap replay: --project-id requires a value\n' >&2; usage; }
      PROJECT_ID_OVERRIDE="$2"
      shift 2
      ;;
    *)
      printf 'cap replay: unknown flag: %s\n' "$1" >&2
      usage
      ;;
  esac
done

# ── Resolve run_dir ─────────────────────────────────────────────────

set +e
RUN_DIR="$(resolve_run_dir "${RAW_ARG}" "${PROJECT_ID_OVERRIDE}")"
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

# Human-readable summary: pull verdict + reason from the JSON.
VERDICT="$(printf '%s' "${VERIFY_OUT}" | "${PYTHON_BIN}" -c "
import json, sys
try:
    print(json.loads(sys.stdin.read())['verdict'])
except Exception:
    print('unknown')
")"

# H4 #2: apply --strict-unverifiable BEFORE --json branch so JSON
# consumers also see the escalated exit code.
if [ "${STRICT_UNVERIFIABLE}" -eq 1 ] && [ "${VERDICT}" = "unverifiable" ]; then
  VERIFY_RC=4
fi

if [ "${JSON_MODE}" -eq 1 ]; then
  printf '%s\n' "${VERIFY_OUT}"
  exit "${VERIFY_RC}"
fi
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
        was_recorded = psd.get('was_recorded', False)
        if ax == 'drifted_incompatible':
            print('  project: drifted_incompatible (' + str(len(sc)) + ' changed, ' + str(len(sr)) + ' removed, ' + str(len(sm)) + ' masked)')
        elif ax == 'drifted_compatible':
            # H2.5 #2: when was_recorded=false skills_used is [] not because
            # zero skills were affected but because binding_summary was
            # missing — distinguish the two cases textually.
            if was_recorded:
                print('  project: drifted_compatible (dir_hash differs, ' + str(len(su)) + ' skills used unaffected)')
            else:
                print('  project: drifted_compatible (dir_hash differs, skills_used unknown — binding_summary missing)')
        elif ax == 'replayable':
            print('  project: replayable')
        elif ax == 'unverifiable_axis':
            print('  project: unverifiable (no project_skill_baseline recorded)')
    # H3 #4: three new whole-file-hash axes (workflow_yaml /
    # constitution / capability_schema). Per design memo §6, each
    # axis can only emit replayable / drifted_compatible /
    # unverifiable_axis (drifted_incompatible is precision-blocked
    # for whole-file hash).
    for axis_name, key in (('workflow', 'workflow_yaml_diff'),
                           ('constitution', 'constitution_diff'),
                           ('capability_schema', 'capability_schema_diff')):
        body = drift.get(key)
        if not body:
            continue
        ax = body.get('axis_verdict', '')
        if ax == 'drifted_compatible':
            print('  ' + axis_name + ': drifted_compatible (content_hash differs)')
        elif ax == 'replayable':
            print('  ' + axis_name + ': replayable')
        elif ax == 'unverifiable_axis':
            print('  ' + axis_name + ': unverifiable (no baseline recorded)')
except Exception:
    pass
")"
[ -n "${AXES_LINE}" ] && printf '%s\n' "${AXES_LINE}"

if [ "${WRITE_MODE}" -eq 1 ] && [ "${VERDICT}" != "not_found" ]; then
  printf '  verdict file: %s/replay-verdict.json\n' "${RUN_DIR}"
  first_mirror=1
  for mirror in agent-skills.json project-skills.json binding-summary.json \
                workflow-yaml.json constitution.json capability-schema.json; do
    if [ -f "${RUN_DIR}/snapshots/${mirror}" ]; then
      if [ "${first_mirror}" -eq 1 ]; then
        printf '  snapshot mirror: %s/snapshots/%s\n' "${RUN_DIR}" "${mirror}"
        first_mirror=0
      else
        printf '                   %s/snapshots/%s\n' "${RUN_DIR}" "${mirror}"
      fi
    fi
  done
fi

# H4 #2: --strict-unverifiable already applied above (before the
# --json branch). Add a one-line trail so the human-readable
# output mentions the escalation when it fires.
if [ "${STRICT_UNVERIFIABLE}" -eq 1 ] && [ "${VERDICT}" = "unverifiable" ]; then
  printf '  strict-unverifiable: escalating exit code to 4\n'
fi

exit "${VERIFY_RC}"
