#!/usr/bin/env bash
#
# test-cap-config-namespace-resolver.sh — CAP Config Namespace Migration
# batch 1 gate (read-only compat layer).
#
# Verifies all four project_id readers honor the dual-path resolution:
#
#   Resolution order (per scripts/cap-paths.sh:read_project_id_from_config):
#     1. <project_root>/.cap/project.yaml   (new canonical namespace)
#     2. <project_root>/.cap.project.yaml   (legacy flat-file)
#     3. → caller-specific fallback (git basename / cwd basename / error)
#
#   When both files exist, **new path wins**.
#
# Coverage:
#   Reader A (shell SSOT): scripts/cap-paths.sh
#     A1. .cap/project.yaml only        →  resolves new path
#     A2. .cap.project.yaml only        →  resolves legacy path
#     A3. both present                  →  new path wins
#     A4. neither + git repo            →  git_basename mode (existing fallback)
#     A5. neither + no git              →  exit 52 (strict halt, existing)
#
#   Reader B: engine/project_constitution_runner.py:resolve_project_id
#     B1. .cap/project.yaml only        →  resolves
#     B2. .cap.project.yaml only        →  resolves
#     B3. both present                  →  new path wins
#     B4. neither                       →  raises ProjectConstitutionRunnerError
#
#   Reader C: engine/project_context_loader.py:ProjectContextLoader
#     C1. .cap/project.yaml only        →  load() returns project_id from new
#     C2. .cap.project.yaml only        →  load() returns project_id from legacy
#     C3. both present                  →  new path wins
#
#   Reader D: engine/step_runtime.py:_project_id_from_config
#     D1. .cap/project.yaml only        →  picks new
#     D2. .cap.project.yaml only        →  picks legacy
#     D3. both present                  →  new path wins
#     D4. neither                       →  cwd basename fallback (existing)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CAP_PATHS="${REPO_ROOT}/scripts/cap-paths.sh"
RUNNER_PY="${REPO_ROOT}/engine/project_constitution_runner.py"
LOADER_PY="${REPO_ROOT}/engine/project_context_loader.py"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"

[ -f "${CAP_PATHS}" ] || { echo "FAIL: scripts/cap-paths.sh missing"; exit 1; }
[ -f "${RUNNER_PY}" ] || { echo "FAIL: engine/project_constitution_runner.py missing"; exit 1; }
[ -f "${LOADER_PY}" ] || { echo "FAIL: engine/project_context_loader.py missing"; exit 1; }
[ -f "${STEP_PY}" ]   || { echo "FAIL: engine/step_runtime.py missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-cfg-ns-test.XXXXXX)"
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

assert_neq() {
  local desc="$1" forbidden="$2" actual="$3"
  if [ "${forbidden}" = "${actual}" ]; then
    echo "  FAIL: ${desc}"
    echo "    must not equal: ${forbidden}"
    echo "    actual:         ${actual}"
    fail_count=$((fail_count + 1))
  else
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  fi
}

# Helpers ---------------------------------------------------------------

# Build a sandbox project root with the requested config combo.
# Args: $1 sandbox subdir name; $2 = "new"|"legacy"|"both"|"none"
#       $3 = project_id for new file (or empty); $4 = same for legacy
build_project_root() {
  local name="$1" combo="$2" new_id="$3" legacy_id="$4"
  local root="${SANDBOX}/${name}"
  mkdir -p "${root}"
  case "${combo}" in
    new|both)
      mkdir -p "${root}/.cap"
      printf 'project_id: %s\n' "${new_id}" > "${root}/.cap/project.yaml"
      ;;
  esac
  case "${combo}" in
    legacy|both)
      printf 'project_id: %s\n' "${legacy_id}" > "${root}/.cap.project.yaml"
      ;;
  esac
  printf '%s\n' "${root}"
}

# Run cap-paths.sh and capture project_id deterministically. Need a fresh
# CAP_HOME per case so verify_ledger_or_halt does not collide. Force
# CAP_PROJECT_ID_OVERRIDE empty so .cap/project.yaml vs .cap.project.yaml
# is what actually drives the read.
cap_paths_get_id() {
  local root="$1"
  local cap_home="${SANDBOX}/cap-home-$(basename "${root}")"
  mkdir -p "${cap_home}"
  ( cd "${root}" && CAP_HOME="${cap_home}" CAP_PROJECT_ID_OVERRIDE="" \
      bash "${CAP_PATHS}" get project_id 2>&1 )
}

# Capture the strict-halt error path (exit 52) — combine stdout+stderr
# so assertions can reach the user-facing diagnostic message.
cap_paths_get_id_expect_halt() {
  local root="$1"
  local cap_home="${SANDBOX}/cap-home-$(basename "${root}")"
  mkdir -p "${cap_home}"
  ( cd "${root}" && CAP_HOME="${cap_home}" CAP_PROJECT_ID_OVERRIDE="" \
      bash "${CAP_PATHS}" get project_id 2>&1; echo "rc=$?" )
}

# ── Reader A: scripts/cap-paths.sh ──────────────────────────────────────

echo "Reader A: scripts/cap-paths.sh:read_project_id_from_config"

echo "Case A1: .cap/project.yaml only"
A1_ROOT="$(build_project_root "a1" new "alpha-new" "")"
out_a1="$(cap_paths_get_id "${A1_ROOT}")"
assert_contains "A1 resolves new id" "alpha-new" "${out_a1}"

echo "Case A2: .cap.project.yaml only"
A2_ROOT="$(build_project_root "a2" legacy "" "alpha-legacy")"
out_a2="$(cap_paths_get_id "${A2_ROOT}")"
assert_contains "A2 resolves legacy id" "alpha-legacy" "${out_a2}"

echo "Case A3: both present → new wins"
A3_ROOT="$(build_project_root "a3" both "winner-new" "loser-legacy")"
out_a3="$(cap_paths_get_id "${A3_ROOT}")"
assert_contains "A3 picks new path"           "winner-new" "${out_a3}"
case "${out_a3}" in
  *loser-legacy*) echo "  FAIL: A3 legacy leaked"; fail_count=$((fail_count + 1)) ;;
  *)              echo "  PASS: A3 legacy does not leak"; pass_count=$((pass_count + 1)) ;;
esac

echo "Case A4: neither + git repo → git_basename mode preserved"
A4_ROOT="${SANDBOX}/a4-git"
mkdir -p "${A4_ROOT}"
( cd "${A4_ROOT}" && git init -q && git commit --allow-empty -q -m init 2>/dev/null )
out_a4="$(cap_paths_get_id "${A4_ROOT}")"
assert_contains "A4 falls back to git_basename" "a4-git" "${out_a4}"

echo "Case A5: neither + no git → exit 52 strict halt preserved"
A5_ROOT="${SANDBOX}/a5"
mkdir -p "${A5_ROOT}"
out_a5="$(cap_paths_get_id_expect_halt "${A5_ROOT}")"
assert_contains "A5 exits 52"                   "rc=52"                 "${out_a5}"
assert_contains "A5 mentions new path"          ".cap/project.yaml"     "${out_a5}"
assert_contains "A5 mentions legacy path"       ".cap.project.yaml"     "${out_a5}"
assert_contains "A5 mentions override env var"  "CAP_PROJECT_ID_OVERRIDE" "${out_a5}"

# ── Reader B: engine/project_constitution_runner.py:resolve_project_id ──

echo ""
echo "Reader B: engine/project_constitution_runner.py:resolve_project_id"

run_resolver_b() {
  local root="$1"
  ( cd "${REPO_ROOT}" && python3 -c "
from pathlib import Path
import sys
sys.path.insert(0, 'engine')
from project_constitution_runner import resolve_project_id, ProjectConstitutionRunnerError
try:
    print(resolve_project_id(Path('${root}')))
except ProjectConstitutionRunnerError as exc:
    print(f'ERROR: {exc}')
" 2>&1 )
}

echo "Case B1: .cap/project.yaml only"
B1_ROOT="$(build_project_root "b1" new "beta-new" "")"
out_b1="$(run_resolver_b "${B1_ROOT}")"
assert_eq "B1 resolves new id"  "beta-new"  "${out_b1}"

echo "Case B2: .cap.project.yaml only"
B2_ROOT="$(build_project_root "b2" legacy "" "beta-legacy")"
out_b2="$(run_resolver_b "${B2_ROOT}")"
assert_eq "B2 resolves legacy id"  "beta-legacy"  "${out_b2}"

echo "Case B3: both present → new wins"
B3_ROOT="$(build_project_root "b3" both "beta-winner" "beta-loser")"
out_b3="$(run_resolver_b "${B3_ROOT}")"
assert_eq "B3 picks new"   "beta-winner"  "${out_b3}"
assert_neq "B3 not legacy" "beta-loser"   "${out_b3}"

echo "Case B4: neither → raises ProjectConstitutionRunnerError"
B4_ROOT="${SANDBOX}/b4"
mkdir -p "${B4_ROOT}"
out_b4="$(run_resolver_b "${B4_ROOT}")"
assert_contains "B4 ERROR prefix"            "ERROR:"                "${out_b4}"
assert_contains "B4 mentions both candidates" ".cap/project.yaml"     "${out_b4}"
assert_contains "B4 mentions legacy"          ".cap.project.yaml"     "${out_b4}"

# ── Reader C: engine/project_context_loader.py:ProjectContextLoader ─────

echo ""
echo "Reader C: engine/project_context_loader.py:ProjectContextLoader.load"

run_loader_c() {
  local root="$1"
  # ProjectContextLoader expects a base_dir; we sandbox CAP_HOME so the
  # ledger write inside _verify_or_write_ledger does not pollute the real
  # ~/.cap. Suppress the ledger by passing a unique CAP_HOME per case.
  ( cd "${REPO_ROOT}" && CAP_HOME="${SANDBOX}/loader-cap-home-$(basename ${root})" python3 -c "
from pathlib import Path
import sys
sys.path.insert(0, 'engine')
from project_context_loader import ProjectContextLoader
ctx = ProjectContextLoader(base_dir=Path('${root}')).load()
print(f\"id={ctx['project_id']}\")
print(f\"path={ctx['project_config_path']}\")
" 2>&1 )
}

echo "Case C1: .cap/project.yaml only"
C1_ROOT="$(build_project_root "c1" new "gamma-new" "")"
out_c1="$(run_loader_c "${C1_ROOT}")"
assert_contains "C1 id matches"    "id=gamma-new"               "${out_c1}"
assert_contains "C1 path is new"   ".cap/project.yaml"          "${out_c1}"

echo "Case C2: .cap.project.yaml only"
C2_ROOT="$(build_project_root "c2" legacy "" "gamma-legacy")"
out_c2="$(run_loader_c "${C2_ROOT}")"
assert_contains "C2 id matches"      "id=gamma-legacy"           "${out_c2}"
assert_contains "C2 path is legacy"  ".cap.project.yaml"         "${out_c2}"

echo "Case C3: both present → new wins"
C3_ROOT="$(build_project_root "c3" both "gamma-winner" "gamma-loser")"
out_c3="$(run_loader_c "${C3_ROOT}")"
assert_contains "C3 id is new"          "id=gamma-winner"          "${out_c3}"
assert_contains "C3 path is new"        ".cap/project.yaml"        "${out_c3}"
case "${out_c3}" in
  *gamma-loser*) echo "  FAIL: C3 legacy leaked"; fail_count=$((fail_count + 1)) ;;
  *)             echo "  PASS: C3 legacy does not leak"; pass_count=$((pass_count + 1)) ;;
esac

# ── Reader D: engine/step_runtime.py:_project_id_from_config ────────────

echo ""
echo "Reader D: engine/step_runtime.py:_project_id_from_config"

run_step_d() {
  local root="$1"
  ( cd "${root}" && python3 -c "
import sys
sys.path.insert(0, '${REPO_ROOT}/engine')
from step_runtime import _project_id_from_config
print(_project_id_from_config())
" 2>&1 )
}

echo "Case D1: .cap/project.yaml only"
D1_ROOT="$(build_project_root "d1" new "delta-new" "")"
out_d1="$(run_step_d "${D1_ROOT}")"
assert_eq "D1 resolves new"   "delta-new"   "${out_d1}"

echo "Case D2: .cap.project.yaml only"
D2_ROOT="$(build_project_root "d2" legacy "" "delta-legacy")"
out_d2="$(run_step_d "${D2_ROOT}")"
assert_eq "D2 resolves legacy" "delta-legacy" "${out_d2}"

echo "Case D3: both present → new wins"
D3_ROOT="$(build_project_root "d3" both "delta-winner" "delta-loser")"
out_d3="$(run_step_d "${D3_ROOT}")"
assert_eq "D3 picks new"      "delta-winner" "${out_d3}"

echo "Case D4: neither → cwd basename fallback preserved"
D4_ROOT="${SANDBOX}/d4-fallback"
mkdir -p "${D4_ROOT}"
out_d4="$(run_step_d "${D4_ROOT}")"
assert_eq "D4 falls back to cwd name" "d4-fallback" "${out_d4}"

echo ""
echo "cap-config-namespace-resolver: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
