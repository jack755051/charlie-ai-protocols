#!/usr/bin/env bash
#
# test-cap-project-migrate-config.sh — P0c Config Namespace Migration
# batch 2 producer gate (Batch C).
#
# Verifies engine/migrate_config.py + cap project migrate-config dispatch:
#
#   * Default behavior is non-destructive copy (legacy preserved).
#   * --dry-run never writes.
#   * --force overrides conflicts; refuses to write without it.
#   * --remove-legacy deletes legacy source after a successful copy
#     (or after an idempotent already_migrated entry).
#   * Idempotent re-run does not flap (same plan + no writes).
#   * --format json emits structured payload identical to the dataclass shape.
#   * cap-project.sh dispatcher routes ``migrate-config`` to the Python module.
#
# Coverage:
#   Case 1  dry-run all-legacy       → plan shows 4 actions, no writes
#   Case 2  default apply all-legacy → 4 copies, legacy preserved
#   Case 3  partial legacy           → only present files migrate
#   Case 4  conflict without --force → exit 1, target untouched, legacy intact
#   Case 5  conflict with --force    → target overwritten, legacy intact
#   Case 6  --remove-legacy + copy   → legacy deleted after copy, exit 0
#   Case 7  idempotent re-run        → already_migrated, no flap, exit 0
#   Case 8  --format json shape      → JSON contains expected keys + actions
#   Case 9  cap-project.sh dispatch  → cap project migrate-config routes to module

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MIGRATE_PY="${REPO_ROOT}/engine/migrate_config.py"
CAP_PROJECT_SH="${REPO_ROOT}/scripts/cap-project.sh"

[ -f "${MIGRATE_PY}" ]       || { echo "FAIL: engine/migrate_config.py missing"; exit 1; }
[ -f "${CAP_PROJECT_SH}" ]   || { echo "FAIL: scripts/cap-project.sh missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-migrate-test.XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

pass_count=0
fail_count=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected: ${expected}"
    echo "    actual:   ${actual}"
    fail_count=$((fail_count + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected substring: ${needle}"
    echo "    actual head: $(printf '%s' "${haystack}" | head -3)"
    fail_count=$((fail_count + 1))
  fi
}

assert_present() {
  local desc="$1" path="$2"
  if [ -e "${path}" ]; then
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected to exist: ${path}"
    fail_count=$((fail_count + 1))
  fi
}

assert_absent() {
  local desc="$1" path="$2"
  if [ ! -e "${path}" ]; then
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    must NOT exist: ${path}"
    fail_count=$((fail_count + 1))
  fi
}

# Build a sandbox project root with the requested combination.
# Args: $1 sandbox subdir; $2 = csv of legacy file kinds to seed
#       (project,constitution,skills,agents)
build_project() {
  local name="$1" kinds="$2"
  local root="${SANDBOX}/${name}"
  mkdir -p "${root}"
  case ",${kinds}," in *",project,"*)
    echo "project_id: demo-${name}" > "${root}/.cap.project.yaml" ;;
  esac
  case ",${kinds}," in *",constitution,"*)
    echo "constitution_id: ${name}-cons" > "${root}/.cap.constitution.yaml" ;;
  esac
  case ",${kinds}," in *",skills,"*)
    echo "skills: []" > "${root}/.cap.skills.yaml" ;;
  esac
  case ",${kinds}," in *",agents,"*)
    echo '{"version":1,"agents":[]}' > "${root}/.cap.agents.json" ;;
  esac
  printf '%s\n' "${root}"
}

run_migrate() {
  python3 "${MIGRATE_PY}" "$@" 2>&1
}

# ── Case 1 ──────────────────────────────────────────────────────────────
echo "Case 1: dry-run all-legacy → plan shows 4 actions, no writes"
C1_ROOT="$(build_project c1 project,constitution,skills,agents)"
out_c1="$(run_migrate --project-root "${C1_ROOT}" --dry-run)"
rc_c1=$?
assert_eq "rc 0"                       "0"          "${rc_c1}"
assert_contains "plan header"          "migration plan for"  "${out_c1}"
assert_contains "project copy planned" "[copy"               "${out_c1}"
assert_contains "summary 4 copies"     "4 copy, 0 conflict"  "${out_c1}"
assert_absent "no .cap/ created"       "${C1_ROOT}/.cap"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: default apply all-legacy → 4 copies, legacy preserved"
C2_ROOT="$(build_project c2 project,constitution,skills,agents)"
out_c2="$(run_migrate --project-root "${C2_ROOT}")"
rc_c2=$?
assert_eq "rc 0"                       "0"   "${rc_c2}"
assert_present "new project.yaml"      "${C2_ROOT}/.cap/project.yaml"
assert_present "new constitution.yaml" "${C2_ROOT}/.cap/constitution.yaml"
assert_present "new skills.yaml"       "${C2_ROOT}/.cap/skills.yaml"
assert_present "new agents.json"       "${C2_ROOT}/.cap/agents.json"
assert_present "legacy project kept"   "${C2_ROOT}/.cap.project.yaml"
assert_present "legacy constitution kept" "${C2_ROOT}/.cap.constitution.yaml"
assert_contains "OK marker"            "[OK"                "${out_c2}"
# Byte-equality check: copied content matches
new_id="$(grep '^project_id:' "${C2_ROOT}/.cap/project.yaml" | head -n 1)"
old_id="$(grep '^project_id:' "${C2_ROOT}/.cap.project.yaml" | head -n 1)"
assert_eq "byte-equal project_id"      "${old_id}"  "${new_id}"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: partial legacy → only present files migrate"
C3_ROOT="$(build_project c3 project,constitution)"
out_c3="$(run_migrate --project-root "${C3_ROOT}")"
rc_c3=$?
assert_eq "rc 0"                       "0"   "${rc_c3}"
assert_present "new project.yaml"      "${C3_ROOT}/.cap/project.yaml"
assert_present "new constitution.yaml" "${C3_ROOT}/.cap/constitution.yaml"
assert_absent "skills not created"     "${C3_ROOT}/.cap/skills.yaml"
assert_absent "agents not created"     "${C3_ROOT}/.cap/agents.json"
assert_contains "skip marker for skills" "[SKIP" "${out_c3}"

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: conflict without --force → exit 1, target untouched"
C4_ROOT="$(build_project c4 project)"
mkdir -p "${C4_ROOT}/.cap"
echo "project_id: TARGET-WAS-HERE" > "${C4_ROOT}/.cap/project.yaml"
out_c4="$(run_migrate --project-root "${C4_ROOT}")"
rc_c4=$?
assert_eq "rc 1 (conflict refused)"    "1"   "${rc_c4}"
assert_contains "BLOCK marker"         "[BLOCK"                "${out_c4}"
assert_contains "refused message"      "re-run with --force"   "${out_c4}"
target_after="$(cat "${C4_ROOT}/.cap/project.yaml")"
assert_eq "target untouched"           "project_id: TARGET-WAS-HERE"  "${target_after}"
assert_present "legacy still intact"   "${C4_ROOT}/.cap.project.yaml"

# ── Case 5 ──────────────────────────────────────────────────────────────
echo "Case 5: conflict with --force → target overwritten, legacy intact"
C5_ROOT="$(build_project c5 project)"
mkdir -p "${C5_ROOT}/.cap"
echo "project_id: TARGET-WAS-HERE" > "${C5_ROOT}/.cap/project.yaml"
out_c5="$(run_migrate --project-root "${C5_ROOT}" --force)"
rc_c5=$?
assert_eq "rc 0 (forced)"              "0"   "${rc_c5}"
target_after="$(grep '^project_id:' "${C5_ROOT}/.cap/project.yaml")"
assert_eq "target was overwritten with legacy bytes" "project_id: demo-c5"  "${target_after}"
assert_present "legacy still intact after force"     "${C5_ROOT}/.cap.project.yaml"

# ── Case 6 ──────────────────────────────────────────────────────────────
echo "Case 6: --remove-legacy + copy → legacy deleted after copy, exit 0"
C6_ROOT="$(build_project c6 project,constitution)"
out_c6="$(run_migrate --project-root "${C6_ROOT}" --remove-legacy)"
rc_c6=$?
assert_eq "rc 0"                                "0"   "${rc_c6}"
assert_present "new project.yaml"               "${C6_ROOT}/.cap/project.yaml"
assert_present "new constitution.yaml"          "${C6_ROOT}/.cap/constitution.yaml"
assert_absent "legacy project removed"          "${C6_ROOT}/.cap.project.yaml"
assert_absent "legacy constitution removed"     "${C6_ROOT}/.cap.constitution.yaml"
assert_contains "legacy_removed flag in output" "legacy_removed"  "${out_c6}"

# ── Case 7 ──────────────────────────────────────────────────────────────
echo "Case 7: idempotent re-run → already_migrated, no flap, exit 0"
C7_ROOT="$(build_project c7 project,constitution)"
run_migrate --project-root "${C7_ROOT}" >/dev/null   # first apply
out_c7="$(run_migrate --project-root "${C7_ROOT}")"  # second apply
rc_c7=$?
assert_eq "rc 0"                            "0"   "${rc_c7}"
assert_present "new project.yaml present"   "${C7_ROOT}/.cap/project.yaml"
# Action should now be already_migrated, not copy:
out_dry="$(run_migrate --project-root "${C7_ROOT}" --dry-run)"
assert_contains "second-run action is already_migrated" "[already_migrated" "${out_dry}"
# When every entry is already_migrated or skip_no_legacy, format_plan emits a
# dedicated "nothing to migrate" line instead of the copy/conflict counter.
assert_contains "second-run summary states nothing-to-do" "nothing to migrate" "${out_dry}"

# ── Case 8 ──────────────────────────────────────────────────────────────
echo "Case 8: --format json → structured payload"
C8_ROOT="$(build_project c8 project)"
json_c8="$(run_migrate --project-root "${C8_ROOT}" --dry-run --format json)"
rc_c8=$?
assert_eq "rc 0"                                "0"   "${rc_c8}"
assert_contains "json has project_root key"     '"project_root":'  "${json_c8}"
assert_contains "json has entries key"          '"entries":'       "${json_c8}"
assert_contains "json action enum value"        '"action":'        "${json_c8}"
assert_contains "json shows copy action"        '"copy"'           "${json_c8}"
assert_contains "json shows skip_no_legacy"     '"skip_no_legacy"' "${json_c8}"

# ── Case 9 ──────────────────────────────────────────────────────────────
echo "Case 9: cap-project.sh dispatcher routes migrate-config"
C9_ROOT="$(build_project c9 project)"
out_c9="$(bash "${CAP_PROJECT_SH}" migrate-config --project-root "${C9_ROOT}" --dry-run 2>&1)"
rc_c9=$?
assert_eq "rc 0"                       "0"   "${rc_c9}"
assert_contains "dispatcher reaches plan output" "migration plan for" "${out_c9}"
# Help text should advertise the new subcommand:
help_out="$(bash "${CAP_PROJECT_SH}" help 2>&1)"
assert_contains "help lists migrate-config"   "migrate-config" "${help_out}"

echo ""
echo "cap-project-migrate-config: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
