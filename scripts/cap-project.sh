#!/usr/bin/env bash
#
# cap-project.sh — Subcommand dispatcher for `cap project` (P1 #5/#6/#7 + P2 #2).
#
# Subcommands:
#   init          Bootstrap a project: write .cap.project.yaml + initialise CAP storage.
#   status        Read-only project summary: id, paths, ledger, constitution, latest run.
#   doctor        Read-only diagnostic with remediation suggestions.
#   constitution  Generate or import a Project Constitution snapshot under
#                 ~/.cap/projects/<id>/constitutions/project/<stamp>/.
#
# Design boundaries:
#   - init is pure shell (writes .cap.project.yaml, delegates to cap-paths.sh
#     ensure for storage + ledger creation; never duplicates ledger logic).
#   - status / doctor / constitution delegate to Python helpers; we never
#     re-implement health, validation or workflow-orchestration logic in
#     shell, per the consumer/producer contract in
#     policies/cap-storage-metadata.md §6.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CAP_PATHS="${SCRIPT_DIR}/cap-paths.sh"
STATUS_MODULE="${REPO_ROOT}/engine/project_status.py"
DOCTOR_MODULE="${REPO_ROOT}/engine/project_doctor.py"
CONSTITUTION_MODULE="${REPO_ROOT}/engine/project_constitution_runner.py"

usage() {
  cat <<'EOF'
Usage: cap project <subcommand> [options]

Subcommands:
  init    [--project-id ID] [--force] [--format text|json|yaml]
          Initialise .cap.project.yaml and the matching CAP storage.

  status  [--project-root PATH] [--format text|json|yaml]
          Read-only project summary (id, storage path, ledger, constitution
          snapshot, latest run, health-check issues).

  doctor  [--project-root PATH] [--format text|json|yaml]
          Read-only diagnostic with remediation suggestions for every
          HealthIssueKind reported by the storage health check.

  constitution  (--prompt "<text>" | --from-file PATH | --promote STAMP | --latest)
                [--project-root PATH] [--cap-home PATH] [--project-id ID]
                [--stamp YYYYMMDDTHHMMSSZ] [--schema-path PATH]
                [--dry-run] [--format text|json|yaml]
                Generate, import, or promote a Project Constitution.

                  --prompt    runs the project-constitution workflow and
                              writes a four-part snapshot under
                              ~/.cap/projects/<id>/constitutions/project/<stamp>/.
                  --from-file validates an existing JSON/YAML payload and
                              writes the same four-part snapshot.
                  --promote STAMP
                              re-validates the snapshot at <STAMP> and
                              writes its YAML form back to
                              <project_root>/.cap.constitution.yaml. An
                              existing repo SSOT is backed up to
                              .cap.constitution.yaml.backup-<TIMESTAMP>.
                  --latest    same as --promote with the most recent
                              snapshot under the project sub-tree; never
                              applied implicitly.

                Validation failure leaves snapshot artefacts on disk for
                --prompt / --from-file (exit 1) but never writes the repo
                SSOT for --promote / --latest.

Common notes:
  - storage health logic is single-sourced in engine/storage_health.py;
    status and doctor never re-implement health checks.
  - init delegates storage / ledger creation to scripts/cap-paths.sh ensure.
  - constitution requires `cap project init` to have written
    .cap.project.yaml first (the runner refuses to invent an id).
EOF
}

die() {
  echo "cap-project: error — $*" >&2
  exit 1
}

# Required tooling check.
[ -x "${CAP_PATHS}" ] || die "scripts/cap-paths.sh missing or not executable"

# ─────────────────────────────────────────────────────────
# init
# ─────────────────────────────────────────────────────────

cmd_init() {
  local project_id_override=""
  local force=0
  local format="text"
  local project_root="$(pwd)"

  while [ $# -gt 0 ]; do
    case "$1" in
      --project-id)
        [ $# -ge 2 ] || die "--project-id requires a value"
        project_id_override="$2"; shift 2
        ;;
      --project-id=*)
        project_id_override="${1#--project-id=}"; shift
        ;;
      --force)
        force=1; shift
        ;;
      --format)
        [ $# -ge 2 ] || die "--format requires a value"
        format="$2"; shift 2
        ;;
      --format=*)
        format="${1#--format=}"; shift
        ;;
      --project-root)
        [ $# -ge 2 ] || die "--project-root requires a value"
        project_root="$2"; shift 2
        ;;
      --project-root=*)
        project_root="${1#--project-root=}"; shift
        ;;
      -h|--help)
        usage; exit 0
        ;;
      *)
        die "unknown init flag: $1"
        ;;
    esac
  done

  case "${format}" in
    text|json|yaml) ;;
    *) die "invalid --format: ${format} (allowed: text|json|yaml)";;
  esac

  [ -d "${project_root}" ] || die "project_root does not exist: ${project_root}"
  project_root="$(cd "${project_root}" && pwd)"

  local config_file="${project_root}/.cap.project.yaml"
  local config_existed=0
  if [ -f "${config_file}" ]; then
    config_existed=1
    if [ "${force}" -ne 1 ]; then
      die "${config_file} already exists; pass --force to overwrite"
    fi
  fi

  # Decide project_id:
  #   1. --project-id flag (highest)
  #   2. existing .cap.project.yaml project_id when --force
  #   3. git basename when inside a git repo
  #   4. fail with explicit guidance (mirrors cap-paths strict mode)
  local effective_project_id=""
  local id_source=""
  if [ -n "${project_id_override}" ]; then
    effective_project_id="${project_id_override}"
    id_source="flag"
  elif [ "${config_existed}" -eq 1 ] && [ "${force}" -eq 1 ]; then
    # Preserve the previously chosen id unless user explicitly overrides.
    effective_project_id="$(sed -n -E 's/^project_id:[[:space:]]*"?([^"#]+)"?[[:space:]]*$/\1/p' "${config_file}" | head -n 1)"
    if [ -n "${effective_project_id}" ]; then
      id_source="existing_config"
    fi
  fi
  if [ -z "${effective_project_id}" ]; then
    if git -C "${project_root}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      effective_project_id="$(basename "${project_root}")"
      id_source="git_basename"
    else
      die "cannot derive project_id; pass --project-id <id> or run inside a git repo"
    fi
  fi

  # Sanitize against the same rule as cap-paths.sh sanitize_project_id.
  effective_project_id="$(printf '%s' "${effective_project_id}" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"

  if [ -z "${effective_project_id}" ]; then
    die "sanitised project_id is empty; provide a stable identifier via --project-id"
  fi

  # Write .cap.project.yaml. Preserve unknown keys when --force re-runs by
  # only rewriting the project_id line; if the file does not exist or has
  # no project_id field, write a minimal new file.
  local rewrote_existing=0
  if [ "${config_existed}" -eq 1 ] && [ "${force}" -eq 1 ] \
     && grep -qE '^project_id:' "${config_file}"; then
    # Replace the existing project_id line in-place. Use a temp file so a
    # mid-write crash never leaves a half-edited config on disk.
    local tmp
    tmp="$(mktemp)"
    awk -v new_id="${effective_project_id}" '
      BEGIN { replaced = 0 }
      /^project_id:/ {
        if (!replaced) {
          print "project_id: " new_id
          replaced = 1
          next
        }
      }
      { print }
      END {
        if (!replaced) print "project_id: " new_id
      }
    ' "${config_file}" > "${tmp}"
    mv "${tmp}" "${config_file}"
    rewrote_existing=1
  else
    cat > "${config_file}" <<EOF
# Created by \`cap project init\` on $(date -u '+%Y-%m-%dT%H:%M:%SZ').
# This file pins the CAP project_id so storage at \`~/.cap/projects/<id>/\` stays
# stable across machines, branches, and basename renames. See
# policies/cap-storage-metadata.md §1 for the SSOT contract.
project_id: ${effective_project_id}
EOF
  fi

  # Delegate storage + ledger creation to cap-paths.sh ensure. We export
  # CAP_PROJECT_ID_OVERRIDE so the resolver picks our chosen id even
  # before .cap.project.yaml is read on the next call.
  #
  # Propagate identity-class exit codes (41 schema_validation_failed /
  # 52 project_id_unresolvable / 53 project_id_collision) verbatim so
  # downstream automation can branch on them. Other failures collapse to
  # exit 1 with a generic wrapper message.
  local ensure_out ensure_rc=0
  set +e
  ensure_out="$( cd "${project_root}" \
       && CAP_PROJECT_ID_OVERRIDE="${effective_project_id}" \
          bash "${CAP_PATHS}" ensure 2>&1 )"
  ensure_rc=$?
  set -e
  if [ "${ensure_rc}" -ne 0 ]; then
    echo "${ensure_out}" >&2
    case "${ensure_rc}" in
      41|52|53)
        echo "cap-project: cap-paths.sh ensure halted with exit ${ensure_rc}; .cap.project.yaml may have been written but storage was not initialised" >&2
        exit "${ensure_rc}"
        ;;
      *)
        die "cap-paths.sh ensure failed (rc=${ensure_rc}); .cap.project.yaml may have been written but storage was not initialised"
        ;;
    esac
  fi

  # Capture canonical storage paths for the report.
  local project_store ledger_file cap_home
  project_store="$( cd "${project_root}" \
    && CAP_PROJECT_ID_OVERRIDE="${effective_project_id}" \
       bash "${CAP_PATHS}" get project_store )"
  ledger_file="$( cd "${project_root}" \
    && CAP_PROJECT_ID_OVERRIDE="${effective_project_id}" \
       bash "${CAP_PATHS}" get ledger_file )"
  cap_home="$( cd "${project_root}" \
    && CAP_PROJECT_ID_OVERRIDE="${effective_project_id}" \
       bash "${CAP_PATHS}" get cap_home )"

  case "${format}" in
    json)
      python3 - "${effective_project_id}" "${id_source}" "${project_root}" \
              "${project_store}" "${ledger_file}" "${cap_home}" \
              "${config_file}" "${rewrote_existing}" <<'PY'
import json, sys
(pid, src, root, store, ledger, home, cfg, rewrote) = sys.argv[1:9]
print(json.dumps({
    "subcommand": "init",
    "project_id": pid,
    "project_id_source": src,
    "project_root": root,
    "project_store": store,
    "ledger_file": ledger,
    "cap_home": home,
    "config_path": cfg,
    "config_rewrote_existing": bool(int(rewrote)),
    "result": "ok",
}, indent=2, ensure_ascii=False))
PY
      ;;
    yaml)
      python3 - "${effective_project_id}" "${id_source}" "${project_root}" \
              "${project_store}" "${ledger_file}" "${cap_home}" \
              "${config_file}" "${rewrote_existing}" <<'PY'
import sys, yaml
(pid, src, root, store, ledger, home, cfg, rewrote) = sys.argv[1:9]
print(yaml.safe_dump({
    "subcommand": "init",
    "project_id": pid,
    "project_id_source": src,
    "project_root": root,
    "project_store": store,
    "ledger_file": ledger,
    "cap_home": home,
    "config_path": cfg,
    "config_rewrote_existing": bool(int(rewrote)),
    "result": "ok",
}, sort_keys=False, allow_unicode=True), end="")
PY
      ;;
    text|*)
      cat <<EOF
result=ok
project_id=${effective_project_id}
project_id_source=${id_source}
project_root=${project_root}
project_store=${project_store}
ledger_file=${ledger_file}
cap_home=${cap_home}
config_path=${config_file}
config_rewrote_existing=${rewrote_existing}
EOF
      ;;
  esac
}

# ─────────────────────────────────────────────────────────
# status / doctor — delegate to Python
# ─────────────────────────────────────────────────────────

cmd_status() {
  [ -f "${STATUS_MODULE}" ] || die "engine/project_status.py missing"
  exec python3 "${STATUS_MODULE}" "$@"
}

cmd_doctor() {
  [ -f "${DOCTOR_MODULE}" ] || die "engine/project_doctor.py missing"
  exec python3 "${DOCTOR_MODULE}" "$@"
}

cmd_constitution() {
  [ -f "${CONSTITUTION_MODULE}" ] \
    || die "engine/project_constitution_runner.py missing"
  exec python3 "${CONSTITUTION_MODULE}" "$@"
}

# ─────────────────────────────────────────────────────────
# Dispatcher
# ─────────────────────────────────────────────────────────

main() {
  local sub="${1:-}"
  case "${sub}" in
    init)
      shift
      cmd_init "$@"
      ;;
    status)
      shift
      cmd_status "$@"
      ;;
    doctor)
      shift
      cmd_doctor "$@"
      ;;
    constitution)
      shift
      cmd_constitution "$@"
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      echo "cap-project: unknown subcommand: ${sub}" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
