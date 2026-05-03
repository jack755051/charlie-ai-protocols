#!/usr/bin/env bash
#
# test-project-doctor.sh — Smoke test for `cap project doctor` (P1 #7).
#
# Coverage (10 cases):
#   Case 1:  healthy → exit 0, no issues, no remediation
#   Case 2:  missing storage root → exit 1 + remediation references `cap project init`
#   Case 3:  missing required subdirectory → exit 1 + remediation
#   Case 4:  missing ledger → exit 1 + remediation
#   Case 5:  malformed ledger → exit 41 + remediation
#   Case 6:  forward-incompat ledger → exit 41 + remediation references upgrade
#   Case 7:  origin mismatch → exit 53 + remediation references collision
#   Case 8:  legacy v1 ledger → exit 0 (warning) + remediation references migration
#   Case 9:  --format json round-trip with structured remediation[]
#   Case 10: --fix is read-only (sets fix_requested=true, fix_applied=false, fix_notes[])

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CAP_PROJECT="${REPO_ROOT}/scripts/cap-project.sh"
CAP_PATHS="${REPO_ROOT}/scripts/cap-paths.sh"

[ -x "${CAP_PROJECT}" ] || { echo "FAIL: ${CAP_PROJECT} not executable"; exit 1; }
[ -x "${CAP_PATHS}" ]   || { echo "FAIL: ${CAP_PATHS} not executable"; exit 1; }

SANDBOX="$(mktemp -d -t cap-test-project-doctor.XXXXXX)"
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
    fail_count=$((fail_count + 1))
  fi
}

run_doctor() {
  local project_root="$1" cap_home="$2"
  shift 2
  local out err code tmp_out tmp_err
  tmp_out="$(mktemp)"; tmp_err="$(mktemp)"
  set +e
  CAP_HOME="${cap_home}" bash "${CAP_PROJECT}" doctor \
    --project-root "${project_root}" "$@" >"${tmp_out}" 2>"${tmp_err}"
  code=$?
  set -e
  out="$(cat "${tmp_out}")"; err="$(cat "${tmp_err}")"
  rm -f "${tmp_out}" "${tmp_err}"
  printf '%s|%s|%s' "${out}" "${err}" "${code}"
}

ensure_init() {
  local project_root="$1" cap_home="$2" project_id="$3"
  CAP_HOME="${cap_home}" bash "${CAP_PROJECT}" init \
    --project-root "${project_root}" --project-id "${project_id}" \
    --format text >/dev/null 2>&1
}

# ── Case 1 ──────────────────────────────────────────────────────────────
echo "Case 1: healthy"
case1_root="${SANDBOX}/case1-healthy"; case1_home="${SANDBOX}/cap-case1"
mkdir -p "${case1_root}"; ensure_init "${case1_root}" "${case1_home}" "case1-healthy"

result="$(run_doctor "${case1_root}" "${case1_home}")"
out1="${result%%|*}"; rest="${result#*|}"; exit1="${rest##*|}"
assert_eq "case 1 exit 0" "0" "${exit1}"
assert_contains "case 1 overall_status=ok" "overall_status=ok" "${out1}"
assert_contains "case 1 issues: <none>" "issues: <none>" "${out1}"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: missing storage root"
case2_root="${SANDBOX}/case2-no-store"; case2_home="${SANDBOX}/cap-case2"
mkdir -p "${case2_root}"
cat > "${case2_root}/.cap.project.yaml" <<'EOF'
project_id: case2-no-store
EOF
# Skip ensure → storage missing.

result="$(run_doctor "${case2_root}" "${case2_home}")"
out2="${result%%|*}"; rest="${result#*|}"; exit2="${rest##*|}"
assert_eq "case 2 exit 1" "1" "${exit2}"
assert_contains "case 2 issue: missing_storage_root" "missing_storage_root" "${out2}"
assert_contains "case 2 remediation references cap project init" "cap project init" "${out2}"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: missing subdirectory"
case3_root="${SANDBOX}/case3-missing-subdir"; case3_home="${SANDBOX}/cap-case3"
mkdir -p "${case3_root}"
ensure_init "${case3_root}" "${case3_home}" "case3-missing-subdir"
rm -rf "${case3_home}/projects/case3-missing-subdir/traces"

result="$(run_doctor "${case3_root}" "${case3_home}")"
out3="${result%%|*}"; rest="${result#*|}"; exit3="${rest##*|}"
assert_eq "case 3 exit 1" "1" "${exit3}"
assert_contains "case 3 issue: missing_directory" "missing_directory" "${out3}"
assert_contains "case 3 remediation references cap-paths.sh ensure" "cap-paths.sh ensure" "${out3}"

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: missing ledger"
case4_root="${SANDBOX}/case4-no-ledger"; case4_home="${SANDBOX}/cap-case4"
mkdir -p "${case4_root}"
ensure_init "${case4_root}" "${case4_home}" "case4-no-ledger"
rm -f "${case4_home}/projects/case4-no-ledger/.identity.json"

result="$(run_doctor "${case4_root}" "${case4_home}")"
out4="${result%%|*}"; rest="${result#*|}"; exit4="${rest##*|}"
assert_eq "case 4 exit 1" "1" "${exit4}"
assert_contains "case 4 issue: missing_ledger" "missing_ledger" "${out4}"
assert_contains "case 4 remediation references identity ledger" "identity ledger" "${out4}"

# ── Case 5 ──────────────────────────────────────────────────────────────
echo "Case 5: malformed ledger"
case5_root="${SANDBOX}/case5-malformed"; case5_home="${SANDBOX}/cap-case5"
mkdir -p "${case5_root}"
ensure_init "${case5_root}" "${case5_home}" "case5-malformed"
printf '{not json' > "${case5_home}/projects/case5-malformed/.identity.json"

result="$(run_doctor "${case5_root}" "${case5_home}")"
out5="${result%%|*}"; rest="${result#*|}"; exit5="${rest##*|}"
assert_eq "case 5 exit 41 (schema-class)" "41" "${exit5}"
assert_contains "case 5 issue: malformed_ledger" "malformed_ledger" "${out5}"
assert_contains "case 5 remediation says back up" "back" "${out5}"

# ── Case 6 ──────────────────────────────────────────────────────────────
echo "Case 6: forward-incompat ledger"
case6_root="${SANDBOX}/case6-future"; case6_home="${SANDBOX}/cap-case6"
mkdir -p "${case6_root}"
ensure_init "${case6_root}" "${case6_home}" "case6-future"
ledger6="${case6_home}/projects/case6-future/.identity.json"
python3 -c "
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
d['schema_version'] = 99
with open(p, 'w') as f: json.dump(d, f, indent=2)
" "${ledger6}"

result="$(run_doctor "${case6_root}" "${case6_home}")"
out6="${result%%|*}"; rest="${result#*|}"; exit6="${rest##*|}"
assert_eq "case 6 exit 41" "41" "${exit6}"
assert_contains "case 6 issue: forward_incompat_ledger" "forward_incompat_ledger" "${out6}"
assert_contains "case 6 remediation references upgrade" "upgrade CAP" "${out6}"

# ── Case 7 ──────────────────────────────────────────────────────────────
echo "Case 7: origin mismatch"
case7_root="${SANDBOX}/case7-collision"; case7_home="${SANDBOX}/cap-case7"
mkdir -p "${case7_root}"
ensure_init "${case7_root}" "${case7_home}" "case7-collision"
ledger7="${case7_home}/projects/case7-collision/.identity.json"
python3 -c "
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
d['origin_path'] = '/somewhere/else'
with open(p, 'w') as f: json.dump(d, f, indent=2)
" "${ledger7}"

result="$(run_doctor "${case7_root}" "${case7_home}")"
out7="${result%%|*}"; rest="${result#*|}"; stderr7="${rest%|*}"; exit7="${rest##*|}"
# Same dual-acceptance as test-project-status case 8: collision can surface
# either via storage_health (exit 53 with issue) or via early
# ProjectIdCollisionError raised by ProjectContextLoader (non-zero with
# stderr message). Both honor the producer/consumer contract.
if [ "${exit7}" = "53" ]; then
  assert_eq "case 7 exit 53 via storage_health" "53" "${exit7}"
  assert_contains "case 7 issue: ledger_origin_mismatch" "ledger_origin_mismatch" "${out7}"
  assert_contains "case 7 remediation references collision" "collision" "${out7}"
elif [ "${exit7}" -ne 0 ]; then
  assert_contains "case 7 stderr names collision (early raise)" "collision" "${stderr7}"
  echo "  PASS: case 7 non-zero exit (early raise path)"; pass_count=$((pass_count + 1))
else
  echo "  FAIL: case 7 expected non-zero exit (got ${exit7})"
  fail_count=$((fail_count + 1))
fi

# ── Case 8 ──────────────────────────────────────────────────────────────
echo "Case 8: legacy v1 ledger"
case8_root="${SANDBOX}/case8-legacy"; case8_home="${SANDBOX}/cap-case8"
mkdir -p "${case8_root}"
ensure_init "${case8_root}" "${case8_home}" "case8-legacy"
ledger8="${case8_home}/projects/case8-legacy/.identity.json"
cat > "${ledger8}" <<EOF
{
  "schema_version": 1,
  "project_id": "case8-legacy",
  "resolved_mode": "override",
  "origin_path": "${case8_root}",
  "created_at": "2026-04-01T00:00:00Z"
}
EOF

result="$(run_doctor "${case8_root}" "${case8_home}")"
out8="${result%%|*}"; rest="${result#*|}"; exit8="${rest##*|}"
assert_eq "case 8 exit 0 (warning only)" "0" "${exit8}"
assert_contains "case 8 issue: legacy_ledger_pending_migration" "legacy_ledger_pending_migration" "${out8}"
assert_contains "case 8 remediation references migration" "migrate" "${out8}"

# ── Case 9 ──────────────────────────────────────────────────────────────
echo "Case 9: --format json round-trip"
result="$(run_doctor "${case5_root}" "${case5_home}" --format json)"
out9="${result%%|*}"; rest="${result#*|}"; exit9="${rest##*|}"
assert_eq "case 9 exit 41" "41" "${exit9}"
parsed_status="$(printf '%s' "${out9}" | python3 -c '
import json, sys
print(json.loads(sys.stdin.read()).get("overall_status", ""))
')"
assert_eq "case 9 JSON.overall_status=error" "error" "${parsed_status}"
parsed_remed_len="$(printf '%s' "${out9}" | python3 -c '
import json, sys
issues = json.loads(sys.stdin.read()).get("issues", [])
print(0 if not issues else len(issues[0].get("remediation", [])))
')"
[ "${parsed_remed_len}" -ge 1 ] \
  && { echo "  PASS: case 9 JSON.issues[0].remediation populated (${parsed_remed_len} steps)"; pass_count=$((pass_count + 1)); } \
  || { echo "  FAIL: case 9 JSON.issues[0].remediation empty"; fail_count=$((fail_count + 1)); }

# ── Case 10 ─────────────────────────────────────────────────────────────
echo "Case 10: --fix is read-only (P1 #7 brief)"
result="$(run_doctor "${case1_root}" "${case1_home}" --fix --format json)"
out10="${result%%|*}"; rest="${result#*|}"; exit10="${rest##*|}"
assert_eq "case 10 exit 0 (healthy)" "0" "${exit10}"
parsed_fix_req="$(printf '%s' "${out10}" | python3 -c '
import json, sys
print(json.loads(sys.stdin.read()).get("fix_requested", ""))
')"
parsed_fix_app="$(printf '%s' "${out10}" | python3 -c '
import json, sys
print(json.loads(sys.stdin.read()).get("fix_applied", ""))
')"
parsed_fix_notes="$(printf '%s' "${out10}" | python3 -c '
import json, sys
print(len(json.loads(sys.stdin.read()).get("fix_notes", [])))
')"
assert_eq "case 10 fix_requested=True" "True" "${parsed_fix_req}"
assert_eq "case 10 fix_applied=False" "False" "${parsed_fix_app}"
[ "${parsed_fix_notes}" -ge 1 ] \
  && { echo "  PASS: case 10 fix_notes carries read-only guidance"; pass_count=$((pass_count + 1)); } \
  || { echo "  FAIL: case 10 fix_notes empty"; fail_count=$((fail_count + 1)); }

echo ""
echo "----------------------------------------------------------------"
echo "Summary: ${pass_count} passed, ${fail_count} failed"
echo "----------------------------------------------------------------"

[ ${fail_count} -eq 0 ]
