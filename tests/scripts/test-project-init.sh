#!/usr/bin/env bash
#
# test-project-init.sh — Smoke test for `cap project init` (P1 #6).
#
# Coverage (10 cases):
#   Case 1:  git repo, no --project-id → derive from basename, exit 0
#   Case 2:  non-git folder + --project-id → ok
#   Case 3:  non-git folder, no --project-id → halt (cannot derive)
#   Case 4:  existing .cap.project.yaml without --force → halt
#   Case 5:  existing .cap.project.yaml + --force → rewrites in place
#   Case 6:  --force preserves the existing project_id when no override
#   Case 7:  --force + --project-id replaces id and creates new storage
#   Case 8:  --format json emits valid JSON envelope
#   Case 9:  --format yaml emits valid YAML envelope
#   Case 10: collision halt (existing ledger origin_path != current root)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CAP_PROJECT="${REPO_ROOT}/scripts/cap-project.sh"
CAP_PATHS="${REPO_ROOT}/scripts/cap-paths.sh"

[ -x "${CAP_PROJECT}" ] || { echo "FAIL: ${CAP_PROJECT} not executable"; exit 1; }
[ -x "${CAP_PATHS}" ]   || { echo "FAIL: ${CAP_PATHS} not executable"; exit 1; }

SANDBOX="$(mktemp -d -t cap-test-project-init.XXXXXX)"
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
    echo "    expected to contain: ${needle}"
    echo "    actual head: $(printf '%s' "${haystack}" | head -3)"
    fail_count=$((fail_count + 1))
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  if [ -f "${path}" ]; then
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc} (missing: ${path})"
    fail_count=$((fail_count + 1))
  fi
}

# Run cap-project.sh init in a sandboxed env. Returns "STDOUT|STDERR|EXIT".
run_init() {
  local project_root="$1" cap_home="$2"
  shift 2
  local out err code tmp_out tmp_err
  tmp_out="$(mktemp)"; tmp_err="$(mktemp)"
  set +e
  CAP_HOME="${cap_home}" bash "${CAP_PROJECT}" init \
    --project-root "${project_root}" \
    "$@" >"${tmp_out}" 2>"${tmp_err}"
  code=$?
  set -e
  out="$(cat "${tmp_out}")"; err="$(cat "${tmp_err}")"
  rm -f "${tmp_out}" "${tmp_err}"
  printf '%s|%s|%s' "${out}" "${err}" "${code}"
}

# ── Case 1 ──────────────────────────────────────────────────────────────
echo "Case 1: git repo, no --project-id"
case1_root="${SANDBOX}/case1-git"
case1_home="${SANDBOX}/cap-case1"
mkdir -p "${case1_root}"
( cd "${case1_root}" && git init --quiet --initial-branch=main )

result="$(run_init "${case1_root}" "${case1_home}")"
out1="${result%%|*}"; rest="${result#*|}"; exit1="${rest##*|}"
assert_eq "case 1 exit 0" "0" "${exit1}"
assert_contains "case 1 result=ok" "result=ok" "${out1}"
assert_contains "case 1 project_id=case1-git" "project_id=case1-git" "${out1}"
assert_contains "case 1 source=git_basename" "project_id_source=git_basename" "${out1}"
assert_file_exists "case 1 .cap.project.yaml created" "${case1_root}/.cap.project.yaml"
assert_file_exists "case 1 ledger created" "${case1_home}/projects/case1-git/.identity.json"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: non-git folder + --project-id"
case2_root="${SANDBOX}/case2-no-git"
case2_home="${SANDBOX}/cap-case2"
mkdir -p "${case2_root}"

result="$(run_init "${case2_root}" "${case2_home}" --project-id manual-id)"
out2="${result%%|*}"; rest="${result#*|}"; exit2="${rest##*|}"
assert_eq "case 2 exit 0" "0" "${exit2}"
assert_contains "case 2 project_id=manual-id" "project_id=manual-id" "${out2}"
assert_contains "case 2 source=flag" "project_id_source=flag" "${out2}"
assert_file_exists "case 2 ledger created" "${case2_home}/projects/manual-id/.identity.json"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: non-git folder, no --project-id → halt"
case3_root="${SANDBOX}/case3-no-id"
case3_home="${SANDBOX}/cap-case3"
mkdir -p "${case3_root}"

result="$(run_init "${case3_root}" "${case3_home}")"
exit3="${result##*|}"; stderr3="${result#*|}"; stderr3="${stderr3%|*}"
[ "${exit3}" -ne 0 ] && assert_eq "case 3 exits non-zero" "non-zero" "non-zero" \
  || assert_eq "case 3 exits non-zero" "non-zero" "zero (got ${exit3})"
assert_contains "case 3 stderr explains derivation failure" "cannot derive project_id" "${stderr3}"

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: existing .cap.project.yaml without --force → halt"
case4_root="${SANDBOX}/case4-existing"
case4_home="${SANDBOX}/cap-case4"
mkdir -p "${case4_root}"
cat > "${case4_root}/.cap.project.yaml" <<'EOF'
project_id: pre-existing-id
EOF

result="$(run_init "${case4_root}" "${case4_home}" --project-id new-id)"
exit4="${result##*|}"; stderr4="${result#*|}"; stderr4="${stderr4%|*}"
[ "${exit4}" -ne 0 ] && assert_eq "case 4 exits non-zero" "non-zero" "non-zero" \
  || assert_eq "case 4 exits non-zero" "non-zero" "zero (got ${exit4})"
assert_contains "case 4 stderr names --force" "--force" "${stderr4}"

# Verify the original config was NOT overwritten.
existing_id="$(grep -E '^project_id:' "${case4_root}/.cap.project.yaml" | head -1)"
assert_contains "case 4 original config preserved" "pre-existing-id" "${existing_id}"

# ── Case 5 ──────────────────────────────────────────────────────────────
echo "Case 5: existing .cap.project.yaml + --force replaces in place"
case5_root="${SANDBOX}/case5-force"
case5_home="${SANDBOX}/cap-case5"
mkdir -p "${case5_root}"
cat > "${case5_root}/.cap.project.yaml" <<'EOF'
project_id: old-id
project_name: Has Other Keys
EOF

result="$(run_init "${case5_root}" "${case5_home}" --project-id replaced-id --force)"
out5="${result%%|*}"; rest="${result#*|}"; exit5="${rest##*|}"
assert_eq "case 5 exit 0" "0" "${exit5}"
assert_contains "case 5 rewrote existing" "config_rewrote_existing=1" "${out5}"

new_id_line="$(grep -E '^project_id:' "${case5_root}/.cap.project.yaml" | head -1)"
assert_contains "case 5 project_id replaced" "replaced-id" "${new_id_line}"
project_name_line="$(grep -E '^project_name:' "${case5_root}/.cap.project.yaml" | head -1)"
assert_contains "case 5 unrelated keys preserved" "Has Other Keys" "${project_name_line}"

# ── Case 6 ──────────────────────────────────────────────────────────────
echo "Case 6: --force without --project-id keeps existing id"
case6_root="${SANDBOX}/case6-keep-id"
case6_home="${SANDBOX}/cap-case6"
mkdir -p "${case6_root}"
cat > "${case6_root}/.cap.project.yaml" <<'EOF'
project_id: keep-this-id
EOF

result="$(run_init "${case6_root}" "${case6_home}" --force)"
out6="${result%%|*}"; rest="${result#*|}"; exit6="${rest##*|}"
assert_eq "case 6 exit 0" "0" "${exit6}"
assert_contains "case 6 source=existing_config" "project_id_source=existing_config" "${out6}"
assert_contains "case 6 project_id=keep-this-id" "project_id=keep-this-id" "${out6}"

# ── Case 7 ──────────────────────────────────────────────────────────────
echo "Case 7: --force + --project-id replaces id and creates new storage"
# Reuse case5 sandbox: it now has replaced-id storage. Init it again with
# yet another id and verify both ledgers exist.
result="$(run_init "${case5_root}" "${case5_home}" --project-id replaced-twice --force)"
out7="${result%%|*}"; rest="${result#*|}"; exit7="${rest##*|}"
assert_eq "case 7 exit 0" "0" "${exit7}"
assert_contains "case 7 new project_id" "project_id=replaced-twice" "${out7}"
assert_file_exists "case 7 new ledger created" "${case5_home}/projects/replaced-twice/.identity.json"

# ── Case 8 ──────────────────────────────────────────────────────────────
echo "Case 8: --format json"
case8_root="${SANDBOX}/case8-json"
case8_home="${SANDBOX}/cap-case8"
mkdir -p "${case8_root}"

result="$(run_init "${case8_root}" "${case8_home}" --project-id json-id --format json)"
out8="${result%%|*}"; rest="${result#*|}"; exit8="${rest##*|}"
assert_eq "case 8 exit 0" "0" "${exit8}"
parsed_id="$(printf '%s' "${out8}" | python3 -c '
import json, sys
print(json.loads(sys.stdin.read()).get("project_id", ""))
')"
assert_eq "case 8 JSON.project_id" "json-id" "${parsed_id}"
parsed_result="$(printf '%s' "${out8}" | python3 -c '
import json, sys
print(json.loads(sys.stdin.read()).get("result", ""))
')"
assert_eq "case 8 JSON.result" "ok" "${parsed_result}"

# ── Case 9 ──────────────────────────────────────────────────────────────
echo "Case 9: --format yaml"
case9_root="${SANDBOX}/case9-yaml"
case9_home="${SANDBOX}/cap-case9"
mkdir -p "${case9_root}"

result="$(run_init "${case9_root}" "${case9_home}" --project-id yaml-id --format yaml)"
out9="${result%%|*}"; rest="${result#*|}"; exit9="${rest##*|}"
assert_eq "case 9 exit 0" "0" "${exit9}"
parsed_id9="$(printf '%s' "${out9}" | python3 -c '
import sys, yaml
print((yaml.safe_load(sys.stdin.read()) or {}).get("project_id", ""))
')"
assert_eq "case 9 YAML.project_id" "yaml-id" "${parsed_id9}"

# ── Case 10 ─────────────────────────────────────────────────────────────
echo "Case 10: collision halt (re-init from a different path with same id)"
case10_home="${SANDBOX}/cap-case10"
case10_root_a="${SANDBOX}/case10-origin-a"
case10_root_b="${SANDBOX}/case10-origin-b"
mkdir -p "${case10_root_a}" "${case10_root_b}"

# First init at root_a — claims the id.
result_a="$(run_init "${case10_root_a}" "${case10_home}" --project-id collision-id)"
exit_a="${result_a##*|}"
assert_eq "case 10 first init exit 0" "0" "${exit_a}"

# Second init at root_b with the same id — must halt with project_id_collision (53).
result_b="$(run_init "${case10_root_b}" "${case10_home}" --project-id collision-id)"
exit_b="${result_b##*|}"; stderr_b="${result_b#*|}"; stderr_b="${stderr_b%|*}"
[ "${exit_b}" -eq 53 ] \
  && { echo "  PASS: case 10 collision halt exit 53"; pass_count=$((pass_count + 1)); } \
  || { echo "  FAIL: case 10 collision halt expected exit 53 (got ${exit_b})"; fail_count=$((fail_count + 1)); }
assert_contains "case 10 stderr names collision" "collision" "${stderr_b}"

echo ""
echo "----------------------------------------------------------------"
echo "Summary: ${pass_count} passed, ${fail_count} failed"
echo "----------------------------------------------------------------"

[ ${fail_count} -eq 0 ]
