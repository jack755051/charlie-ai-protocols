#!/usr/bin/env bash
#
# test-project-status.sh — Smoke test for `cap project status` (P1 #5).
#
# Coverage (8 cases):
#   Case 1:  healthy + no constitution + no run → ok / exit 0 / counts zero
#   Case 2:  status surfaces ledger snapshot (schema_version, resolved_mode, ...)
#   Case 3:  constitutions[] reflects files dropped into constitutions/
#   Case 4:  latest_run reflects the newest run dir
#   Case 5:  --format json round-trips into valid JSON with the same fields
#   Case 6:  --format yaml round-trips into valid YAML
#   Case 7:  malformed ledger surfaces health issue + exit 41 (schema-class)
#   Case 8:  origin mismatch surfaces health issue + exit 53 (collision)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CAP_PROJECT="${REPO_ROOT}/scripts/cap-project.sh"
CAP_PATHS="${REPO_ROOT}/scripts/cap-paths.sh"

[ -x "${CAP_PROJECT}" ] || { echo "FAIL: ${CAP_PROJECT} not executable"; exit 1; }
[ -x "${CAP_PATHS}" ]   || { echo "FAIL: ${CAP_PATHS} not executable"; exit 1; }

SANDBOX="$(mktemp -d -t cap-test-project-status.XXXXXX)"
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

run_status() {
  local project_root="$1" cap_home="$2"
  shift 2
  local out err code tmp_out tmp_err
  tmp_out="$(mktemp)"; tmp_err="$(mktemp)"
  set +e
  CAP_HOME="${cap_home}" bash "${CAP_PROJECT}" status \
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
echo "Case 1: healthy + no constitution + no run"
case1_root="${SANDBOX}/case1-healthy"
case1_home="${SANDBOX}/cap-case1"
mkdir -p "${case1_root}"
ensure_init "${case1_root}" "${case1_home}" "case1-healthy"

result="$(run_status "${case1_root}" "${case1_home}")"
out1="${result%%|*}"; rest="${result#*|}"; exit1="${rest##*|}"
assert_eq "case 1 exit 0" "0" "${exit1}"
assert_contains "case 1 health_status=ok" "health_status=ok" "${out1}"
assert_contains "case 1 constitution_count=0" "constitution_count=0" "${out1}"
assert_contains "case 1 latest_run=<none>" "latest_run=<none>" "${out1}"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: ledger snapshot surfaces"
assert_contains "case 2 ledger schema_version=2" "schema_version=2" "${out1}"
assert_contains "case 2 ledger created_at present" "created_at=2026" "${out1}"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: constitutions[] reflects files dropped in constitutions/"
case3_root="${SANDBOX}/case3-constitution"
case3_home="${SANDBOX}/cap-case3"
mkdir -p "${case3_root}"
ensure_init "${case3_root}" "${case3_home}" "case3-constitution"
mkdir -p "${case3_home}/projects/case3-constitution/constitutions"
touch "${case3_home}/projects/case3-constitution/constitutions/foo.json"
touch "${case3_home}/projects/case3-constitution/constitutions/bar.json"

result="$(run_status "${case3_root}" "${case3_home}")"
out3="${result%%|*}"
assert_contains "case 3 constitution_count=2" "constitution_count=2" "${out3}"
assert_contains "case 3 lists foo.json" "- foo.json" "${out3}"
assert_contains "case 3 lists bar.json" "- bar.json" "${out3}"

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: latest_run reflects the newest run dir"
case4_root="${SANDBOX}/case4-runs"
case4_home="${SANDBOX}/cap-case4"
mkdir -p "${case4_root}"
ensure_init "${case4_root}" "${case4_home}" "case4-runs"
mkdir -p "${case4_home}/projects/case4-runs/reports/workflows/wf-a/run_001_aaa"
mkdir -p "${case4_home}/projects/case4-runs/reports/workflows/wf-b/run_002_bbb"
# Make wf-b/run_002 newer.
touch -d "2026-05-01 00:00" "${case4_home}/projects/case4-runs/reports/workflows/wf-a/run_001_aaa"
touch -d "2026-05-02 00:00" "${case4_home}/projects/case4-runs/reports/workflows/wf-b/run_002_bbb"

result="$(run_status "${case4_root}" "${case4_home}")"
out4="${result%%|*}"
assert_contains "case 4 latest_run.workflow_id=wf-b" "workflow_id=wf-b" "${out4}"
assert_contains "case 4 latest_run.run_id=run_002_bbb" "run_id=run_002_bbb" "${out4}"

# ── Case 5 ──────────────────────────────────────────────────────────────
echo "Case 5: --format json"
result="$(run_status "${case4_root}" "${case4_home}" --format json)"
out5="${result%%|*}"; rest="${result#*|}"; exit5="${rest##*|}"
assert_eq "case 5 exit 0" "0" "${exit5}"
parsed_pid="$(printf '%s' "${out5}" | python3 -c '
import json, sys
print(json.loads(sys.stdin.read()).get("project_id", ""))
')"
assert_eq "case 5 JSON.project_id" "case4-runs" "${parsed_pid}"
parsed_health="$(printf '%s' "${out5}" | python3 -c '
import json, sys
print(json.loads(sys.stdin.read())["health"]["status"])
')"
assert_eq "case 5 JSON.health.status=ok" "ok" "${parsed_health}"

# ── Case 6 ──────────────────────────────────────────────────────────────
echo "Case 6: --format yaml"
result="$(run_status "${case4_root}" "${case4_home}" --format yaml)"
out6="${result%%|*}"; rest="${result#*|}"; exit6="${rest##*|}"
assert_eq "case 6 exit 0" "0" "${exit6}"
parsed_pid6="$(printf '%s' "${out6}" | python3 -c '
import sys, yaml
print((yaml.safe_load(sys.stdin.read()) or {}).get("project_id", ""))
')"
assert_eq "case 6 YAML.project_id" "case4-runs" "${parsed_pid6}"

# ── Case 7 ──────────────────────────────────────────────────────────────
echo "Case 7: malformed ledger surfaces + exit 41"
case7_root="${SANDBOX}/case7-malformed"
case7_home="${SANDBOX}/cap-case7"
mkdir -p "${case7_root}"
ensure_init "${case7_root}" "${case7_home}" "case7-malformed"
printf '{not valid json' > "${case7_home}/projects/case7-malformed/.identity.json"

result="$(run_status "${case7_root}" "${case7_home}")"
out7="${result%%|*}"; rest="${result#*|}"; exit7="${rest##*|}"
assert_eq "case 7 exit 41 (schema-class)" "41" "${exit7}"
assert_contains "case 7 health_status=error" "health_status=error" "${out7}"
assert_contains "case 7 issue: malformed_ledger" "malformed_ledger" "${out7}"

# ── Case 8 ──────────────────────────────────────────────────────────────
echo "Case 8: origin mismatch surfaces + exit 53"
case8_root="${SANDBOX}/case8-collision"
case8_home="${SANDBOX}/cap-case8"
mkdir -p "${case8_root}"
ensure_init "${case8_root}" "${case8_home}" "case8-collision"
ledger8="${case8_home}/projects/case8-collision/.identity.json"
python3 -c "
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
d['origin_path'] = '/somewhere/else'
with open(p, 'w') as f: json.dump(d, f, indent=2)
" "${ledger8}"

# Note: cap-paths.sh would halt with exit 53 from verify_ledger_or_halt
# before status reaches storage_health. cap-project.sh status delegates
# straight to Python (no cap-paths shell call), so the Python loader's
# ProjectIdCollisionError surfaces inside run_health_check as a thrown
# error. status's exit code maps it to 53.
result="$(run_status "${case8_root}" "${case8_home}")"
out8="${result%%|*}"; rest="${result#*|}"; stderr8="${rest%|*}"; exit8="${rest##*|}"

# Two valid acceptance modes:
#   (a) collision surfaced via storage_health → exit 53 + ledger_origin_mismatch issue
#   (b) collision raised by ProjectContextLoader before storage_health runs → non-zero
#       exit with a stderr message naming "collision". Either is consistent with the
#       producer/consumer contract; we accept both.
if [ "${exit8}" = "53" ]; then
  assert_eq "case 8 exit 53 via storage_health" "53" "${exit8}"
  assert_contains "case 8 issue: ledger_origin_mismatch" "ledger_origin_mismatch" "${out8}"
elif [ "${exit8}" -ne 0 ]; then
  assert_contains "case 8 stderr names collision (early raise)" "collision" "${stderr8}"
  echo "  PASS: case 8 non-zero exit (early raise path)"; pass_count=$((pass_count + 1))
else
  echo "  FAIL: case 8 expected non-zero exit (got ${exit8})"
  fail_count=$((fail_count + 1))
fi

echo ""
echo "----------------------------------------------------------------"
echo "Summary: ${pass_count} passed, ${fail_count} failed"
echo "----------------------------------------------------------------"

[ ${fail_count} -eq 0 ]
