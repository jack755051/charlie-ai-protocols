#!/usr/bin/env bash
#
# test-project-id-resolver.sh — Smoke test for scripts/cap-paths.sh project_id
# resolution: strict-mode fallback policy (P1 #1) and identity ledger
# collision detection (P1 #2).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CAP_PATHS="${REPO_ROOT}/scripts/cap-paths.sh"

if [ ! -f "${CAP_PATHS}" ]; then
  echo "FAIL: ${CAP_PATHS} not found" >&2
  exit 1
fi

SANDBOX="$(mktemp -d -t cap-test-resolver.XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

pass_count=0
fail_count=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
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
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected to contain: ${needle}"
    echo "    actual: ${haystack}"
    fail_count=$((fail_count + 1))
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  if [ -f "${path}" ]; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected file: ${path}"
    fail_count=$((fail_count + 1))
  fi
}

# Run cap-paths.sh in a sandboxed working directory.
# Args: <case-dir> <subcommand> [extra env=val ...]
# Echoes "STDOUT|STDERR|EXIT".
run_cap_paths() {
  local case_dir="$1"
  local subcmd="$2"
  shift 2

  # Default sandboxed env; override via positional args (env=val).
  local cap_home="${SANDBOX}/cap"
  local override=""
  local allow_fallback=""

  for kv in "$@"; do
    case "${kv}" in
      CAP_HOME=*) cap_home="${kv#CAP_HOME=}" ;;
      CAP_PROJECT_ID_OVERRIDE=*) override="${kv#CAP_PROJECT_ID_OVERRIDE=}" ;;
      CAP_ALLOW_BASENAME_FALLBACK=*) allow_fallback="${kv#CAP_ALLOW_BASENAME_FALLBACK=}" ;;
    esac
  done

  local stdout stderr exit_code
  local tmp_out tmp_err
  tmp_out="$(mktemp)"
  tmp_err="$(mktemp)"

  set +e
  ( cd "${case_dir}" \
    && CAP_HOME="${cap_home}" \
       CAP_PROJECT_ID_OVERRIDE="${override}" \
       CAP_ALLOW_BASENAME_FALLBACK="${allow_fallback}" \
       bash "${CAP_PATHS}" "${subcmd}" project_id ) \
    >"${tmp_out}" 2>"${tmp_err}"
  exit_code=$?
  set -e

  stdout="$(cat "${tmp_out}")"
  stderr="$(cat "${tmp_err}")"
  rm -f "${tmp_out}" "${tmp_err}"

  printf '%s|%s|%s' "${stdout}" "${stderr}" "${exit_code}"
}

# ---------------------------------------------------------------------------
# Case 1: git folder, no config, no override → mode=git_basename, exit 0
# ---------------------------------------------------------------------------
echo "Case 1: git folder, no config, no override"
case1_dir="${SANDBOX}/case1-git-bare"
mkdir -p "${case1_dir}"
( cd "${case1_dir}" && git init --quiet --initial-branch=main )

result="$(run_cap_paths "${case1_dir}" get)"
stdout1="${result%%|*}"
rest1="${result#*|}"
exit1="${rest1##*|}"
assert_eq "case 1 exit 0" "0" "${exit1}"
assert_eq "case 1 stdout = basename" "case1-git-bare" "${stdout1}"

# ---------------------------------------------------------------------------
# Case 2: git folder + .cap.project.yaml → mode=config, id from config
# ---------------------------------------------------------------------------
echo "Case 2: git folder + .cap.project.yaml"
case2_dir="${SANDBOX}/case2-git-with-config"
mkdir -p "${case2_dir}"
( cd "${case2_dir}" && git init --quiet --initial-branch=main )
cat > "${case2_dir}/.cap.project.yaml" <<'EOF'
project_id: my-stable-id
project_name: Case 2
EOF

result="$(run_cap_paths "${case2_dir}" get)"
stdout2="${result%%|*}"
rest2="${result#*|}"
exit2="${rest2##*|}"
assert_eq "case 2 exit 0" "0" "${exit2}"
assert_eq "case 2 stdout = config id" "my-stable-id" "${stdout2}"

# ---------------------------------------------------------------------------
# Case 3: non-git folder + .cap.project.yaml → ok via config
# ---------------------------------------------------------------------------
echo "Case 3: non-git folder + .cap.project.yaml"
case3_dir="${SANDBOX}/case3-no-git-config"
mkdir -p "${case3_dir}"
cat > "${case3_dir}/.cap.project.yaml" <<'EOF'
project_id: nogit-with-config
EOF

result="$(run_cap_paths "${case3_dir}" get)"
stdout3="${result%%|*}"
rest3="${result#*|}"
exit3="${rest3##*|}"
assert_eq "case 3 exit 0" "0" "${exit3}"
assert_eq "case 3 stdout = config id" "nogit-with-config" "${stdout3}"

# ---------------------------------------------------------------------------
# Case 4: non-git folder + override → ok via override
# ---------------------------------------------------------------------------
echo "Case 4: non-git folder + CAP_PROJECT_ID_OVERRIDE"
case4_dir="${SANDBOX}/case4-no-git-override"
mkdir -p "${case4_dir}"

result="$(run_cap_paths "${case4_dir}" get CAP_PROJECT_ID_OVERRIDE=nogit-from-override)"
stdout4="${result%%|*}"
rest4="${result#*|}"
exit4="${rest4##*|}"
assert_eq "case 4 exit 0" "0" "${exit4}"
assert_eq "case 4 stdout = override id" "nogit-from-override" "${stdout4}"

# ---------------------------------------------------------------------------
# Case 5: non-git folder, no config, no override, no fallback → exit 52
# ---------------------------------------------------------------------------
echo "Case 5: non-git folder with nothing → strict halt (exit 52)"
case5_dir="${SANDBOX}/case5-no-git-strict"
mkdir -p "${case5_dir}"

result="$(run_cap_paths "${case5_dir}" get)"
stdout5="${result%%|*}"
rest5="${result#*|}"
stderr5="${rest5%|*}"
exit5="${rest5##*|}"
assert_eq "case 5 exit 52 (project_id_unresolvable)" "52" "${exit5}"
assert_contains "case 5 stderr names .cap.project.yaml fix" ".cap.project.yaml" "${stderr5}"
assert_contains "case 5 stderr names override fix" "CAP_PROJECT_ID_OVERRIDE" "${stderr5}"

# ---------------------------------------------------------------------------
# Case 6: non-git folder + CAP_ALLOW_BASENAME_FALLBACK=1 → ok with warning,
# resolved_mode=basename_legacy, ledger still written
# ---------------------------------------------------------------------------
echo "Case 6: non-git folder + CAP_ALLOW_BASENAME_FALLBACK=1"
case6_dir="${SANDBOX}/case6-fallback-flag"
mkdir -p "${case6_dir}"
cap_home6="${SANDBOX}/cap-case6"

result="$(run_cap_paths "${case6_dir}" ensure \
  CAP_HOME="${cap_home6}" \
  CAP_ALLOW_BASENAME_FALLBACK=1)"
stdout6="${result%%|*}"
rest6="${result#*|}"
stderr6="${rest6%|*}"
exit6="${rest6##*|}"
assert_eq "case 6 exit 0 (legacy fallback allowed)" "0" "${exit6}"
assert_contains "case 6 stderr warns legacy fallback" "legacy" "${stderr6}"
assert_contains "case 6 stderr names env flag" "CAP_ALLOW_BASENAME_FALLBACK" "${stderr6}"

# Verify ledger was still written under the legacy fallback path.
ledger6="${cap_home6}/projects/case6-fallback-flag/.identity.json"
assert_file_exists "case 6 ledger written under legacy fallback" "${ledger6}"

if [ -f "${ledger6}" ]; then
  mode6="$(python3 -c '
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    print(json.load(f).get("resolved_mode", ""))
' "${ledger6}")"
  assert_eq "case 6 ledger.resolved_mode = basename_legacy" "basename_legacy" "${mode6}"
fi

# ---------------------------------------------------------------------------
# Case 7: first-time `ensure` writes ledger; re-entry from same origin passes
# ---------------------------------------------------------------------------
echo "Case 7: first-time ensure writes ledger; re-entry idempotent"
case7_dir="${SANDBOX}/case7-first-time"
mkdir -p "${case7_dir}"
cat > "${case7_dir}/.cap.project.yaml" <<'EOF'
project_id: first-time-proj
EOF
cap_home7="${SANDBOX}/cap-case7"

result="$(run_cap_paths "${case7_dir}" ensure CAP_HOME="${cap_home7}")"
exit7a="${result##*|}"
assert_eq "case 7a first-time ensure exit 0" "0" "${exit7a}"
ledger7="${cap_home7}/projects/first-time-proj/.identity.json"
assert_file_exists "case 7a ledger created on first-time ensure" "${ledger7}"

# Re-entry: same origin path, ensure again → still 0, ledger unchanged.
ledger7_before="$(cat "${ledger7}" 2>/dev/null || true)"
result="$(run_cap_paths "${case7_dir}" ensure CAP_HOME="${cap_home7}")"
exit7b="${result##*|}"
ledger7_after="$(cat "${ledger7}" 2>/dev/null || true)"
assert_eq "case 7b re-entry exit 0" "0" "${exit7b}"
assert_eq "case 7b ledger unchanged on re-entry" "${ledger7_before}" "${ledger7_after}"

# ---------------------------------------------------------------------------
# Case 8: collision — same project_id from a different origin path → exit 53
# ---------------------------------------------------------------------------
echo "Case 8: collision via override-shared project_id from a different origin"
case8a_dir="${SANDBOX}/case8a-origin-a"
case8b_dir="${SANDBOX}/case8b-origin-b"
mkdir -p "${case8a_dir}" "${case8b_dir}"
cap_home8="${SANDBOX}/cap-case8"

# First origin claims project_id "shared-id".
result="$(run_cap_paths "${case8a_dir}" ensure \
  CAP_HOME="${cap_home8}" \
  CAP_PROJECT_ID_OVERRIDE=shared-id)"
exit8a="${result##*|}"
assert_eq "case 8a first-claim exit 0" "0" "${exit8a}"

# Second origin tries to use the same project_id from a different path.
result="$(run_cap_paths "${case8b_dir}" ensure \
  CAP_HOME="${cap_home8}" \
  CAP_PROJECT_ID_OVERRIDE=shared-id)"
exit8b="${result##*|}"
rest8b="${result#*|}"
stderr8b="${rest8b%|*}"
assert_eq "case 8b collision exit 53" "53" "${exit8b}"
assert_contains "case 8b stderr says collision" "collision" "${stderr8b}"
assert_contains "case 8b stderr names recorded origin" "${case8a_dir}" "${stderr8b}"
assert_contains "case 8b stderr names current origin" "${case8b_dir}" "${stderr8b}"

echo
echo "Summary: ${pass_count} passed, ${fail_count} failed"

if [ "${fail_count}" -gt 0 ]; then
  exit 1
fi
exit 0
