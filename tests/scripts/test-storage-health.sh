#!/usr/bin/env bash
#
# test-storage-health.sh — Smoke test for the P1 #4 storage health-check
# core (engine/storage_health.py + scripts/cap-storage-health.sh).
#
# Coverage (10 cases + 1 conditional unwritable case):
#   Case 1:  healthy storage (cap-paths ensure already ran) → ok / exit 0
#   Case 2:  missing storage root (never ensured) → error / exit 1
#   Case 3:  missing required subdirectory → error / exit 1
#   Case 4:  missing ledger file → error / exit 1
#   Case 5:  malformed ledger JSON → error / exit 41 (schema-class)
#   Case 6:  forward-incompat schema_version → error / exit 41
#   Case 7:  legacy v1 ledger → warning / exit 0 (cap-paths will migrate)
#   Case 8:  ledger schema drift (missing required field) → error / exit 41
#   Case 9:  origin_path collision → error / exit 53
#   Case 10: cap_version mismatch (manifest vs ledger) → warning / exit 0
#   Case 11: unwritable storage → error / exit 1 (skipped when uid=0)
#
# Each case runs the wrapper in a hermetic CAP_HOME so concurrent runs
# don't pollute each other.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CAP_PATHS="${REPO_ROOT}/scripts/cap-paths.sh"
HEALTH_WRAPPER="${REPO_ROOT}/scripts/cap-storage-health.sh"

if [ ! -x "${CAP_PATHS}" ]; then
  echo "FAIL: ${CAP_PATHS} not executable"
  exit 1
fi
if [ ! -x "${HEALTH_WRAPPER}" ]; then
  echo "FAIL: ${HEALTH_WRAPPER} not executable"
  exit 1
fi

SANDBOX="$(mktemp -d -t cap-test-storage-health.XXXXXX)"
trap 'chmod -R u+w "${SANDBOX}" 2>/dev/null; rm -rf "${SANDBOX}"' EXIT

pass_count=0
fail_count=0

report_pass() { echo "  PASS: $1"; pass_count=$((pass_count + 1)); }
report_fail() {
  echo "  FAIL: $1"
  [ -n "${2:-}" ] && echo "    detail: $2"
  fail_count=$((fail_count + 1))
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    report_pass "${desc}"
  else
    report_fail "${desc}" "expected=${expected} actual=${actual}"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    report_pass "${desc}"
  else
    report_fail "${desc}" "needle=${needle} | haystack head: $(printf '%s' "${haystack}" | head -3)"
  fi
}

# Run the health wrapper in a sandbox; emits stdout|stderr|exit.
run_health() {
  local project_root="$1"
  local cap_home="$2"
  local extra_args="${3:-}"

  local out err code
  local tmp_out tmp_err
  tmp_out="$(mktemp)"
  tmp_err="$(mktemp)"

  set +e
  CAP_HOME="${cap_home}" \
    bash "${HEALTH_WRAPPER}" \
      --project-root "${project_root}" \
      --cap-home "${cap_home}" \
      --format json \
      ${extra_args} \
      >"${tmp_out}" 2>"${tmp_err}"
  code=$?
  set -e

  out="$(cat "${tmp_out}")"
  err="$(cat "${tmp_err}")"
  rm -f "${tmp_out}" "${tmp_err}"
  printf '%s|%s|%s' "${out}" "${err}" "${code}"
}

# Initialise a fresh project + cap-home using cap-paths ensure so the
# storage starts in the canonical "healthy" shape; subsequent cases
# mutate selectively.
ensure_initialized() {
  local project_root="$1"
  local cap_home="$2"
  ( cd "${project_root}" && CAP_HOME="${cap_home}" bash "${CAP_PATHS}" ensure ) >/dev/null
}

# Helper to read JSON field from health output.
json_field() {
  local payload="$1" path="$2"
  printf '%s' "${payload}" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
keys = sys.argv[1].split('.')
cur = data
for k in keys:
    if k.isdigit():
        cur = cur[int(k)]
    else:
        cur = cur.get(k) if isinstance(cur, dict) else None
    if cur is None:
        break
print(cur if cur is not None else '')
" "${path}"
}

# Find an issue kind in the JSON issues[].
has_issue_kind() {
  local payload="$1" kind="$2"
  printf '%s' "${payload}" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
target = sys.argv[1]
for issue in data.get('issues', []):
    if issue.get('kind') == target:
        print('yes'); break
else:
    print('no')
" "${kind}"
}

# ───────────────────────────────────────────────────────────────────────
# Case 1: healthy storage
# ───────────────────────────────────────────────────────────────────────
echo "Case 1: healthy storage"
case1_root="${SANDBOX}/case1-healthy"
case1_home="${SANDBOX}/cap-case1"
mkdir -p "${case1_root}"
cat > "${case1_root}/.cap.project.yaml" <<'EOF'
project_id: case1-healthy
EOF
ensure_initialized "${case1_root}" "${case1_home}"

result="$(run_health "${case1_root}" "${case1_home}")"
out1="${result%%|*}"; rest="${result#*|}"; exit1="${rest##*|}"
assert_eq "case 1 exit 0" "0" "${exit1}"
assert_eq "case 1 overall ok" "ok" "$(json_field "${out1}" "overall_status")"
assert_eq "case 1 zero issues" "0" "$(json_field "${out1}" "summary.total")"

# ───────────────────────────────────────────────────────────────────────
# Case 2: missing storage root
# ───────────────────────────────────────────────────────────────────────
echo "Case 2: missing storage root (never ensured)"
case2_root="${SANDBOX}/case2-no-store"
case2_home="${SANDBOX}/cap-case2"
mkdir -p "${case2_root}"
cat > "${case2_root}/.cap.project.yaml" <<'EOF'
project_id: case2-no-store
EOF
# Deliberately skip ensure — storage dir does not exist.

result="$(run_health "${case2_root}" "${case2_home}")"
out2="${result%%|*}"; rest="${result#*|}"; exit2="${rest##*|}"
assert_eq "case 2 exit 1 (generic error)" "1" "${exit2}"
assert_eq "case 2 overall error" "error" "$(json_field "${out2}" "overall_status")"
assert_eq "case 2 issue: missing_storage_root" "yes" "$(has_issue_kind "${out2}" "missing_storage_root")"

# ───────────────────────────────────────────────────────────────────────
# Case 3: missing required subdirectory
# ───────────────────────────────────────────────────────────────────────
echo "Case 3: missing required subdirectory"
case3_root="${SANDBOX}/case3-missing-subdir"
case3_home="${SANDBOX}/cap-case3"
mkdir -p "${case3_root}"
cat > "${case3_root}/.cap.project.yaml" <<'EOF'
project_id: case3-missing-subdir
EOF
ensure_initialized "${case3_root}" "${case3_home}"
rm -rf "${case3_home}/projects/case3-missing-subdir/traces"

result="$(run_health "${case3_root}" "${case3_home}")"
out3="${result%%|*}"; rest="${result#*|}"; exit3="${rest##*|}"
assert_eq "case 3 exit 1" "1" "${exit3}"
assert_eq "case 3 issue: missing_directory" "yes" "$(has_issue_kind "${out3}" "missing_directory")"

# ───────────────────────────────────────────────────────────────────────
# Case 4: missing ledger
# ───────────────────────────────────────────────────────────────────────
echo "Case 4: missing ledger file"
case4_root="${SANDBOX}/case4-no-ledger"
case4_home="${SANDBOX}/cap-case4"
mkdir -p "${case4_root}"
cat > "${case4_root}/.cap.project.yaml" <<'EOF'
project_id: case4-no-ledger
EOF
ensure_initialized "${case4_root}" "${case4_home}"
rm -f "${case4_home}/projects/case4-no-ledger/.identity.json"

result="$(run_health "${case4_root}" "${case4_home}")"
out4="${result%%|*}"; rest="${result#*|}"; exit4="${rest##*|}"
assert_eq "case 4 exit 1" "1" "${exit4}"
assert_eq "case 4 issue: missing_ledger" "yes" "$(has_issue_kind "${out4}" "missing_ledger")"

# ───────────────────────────────────────────────────────────────────────
# Case 5: malformed ledger JSON → exit 41 schema-class
# ───────────────────────────────────────────────────────────────────────
echo "Case 5: malformed ledger JSON"
case5_root="${SANDBOX}/case5-malformed"
case5_home="${SANDBOX}/cap-case5"
mkdir -p "${case5_root}"
cat > "${case5_root}/.cap.project.yaml" <<'EOF'
project_id: case5-malformed
EOF
ensure_initialized "${case5_root}" "${case5_home}"
printf '{not valid json' > "${case5_home}/projects/case5-malformed/.identity.json"

result="$(run_health "${case5_root}" "${case5_home}")"
out5="${result%%|*}"; rest="${result#*|}"; exit5="${rest##*|}"
assert_eq "case 5 exit 41 (schema-class)" "41" "${exit5}"
assert_eq "case 5 issue: malformed_ledger" "yes" "$(has_issue_kind "${out5}" "malformed_ledger")"

# ───────────────────────────────────────────────────────────────────────
# Case 6: forward-incompat ledger schema_version
# ───────────────────────────────────────────────────────────────────────
echo "Case 6: forward-incompat ledger schema_version"
case6_root="${SANDBOX}/case6-forward-incompat"
case6_home="${SANDBOX}/cap-case6"
mkdir -p "${case6_root}"
cat > "${case6_root}/.cap.project.yaml" <<'EOF'
project_id: case6-forward-incompat
EOF
ensure_initialized "${case6_root}" "${case6_home}"
ledger6="${case6_home}/projects/case6-forward-incompat/.identity.json"
python3 -c "
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
d['schema_version'] = 99
with open(p, 'w') as f: json.dump(d, f, indent=2)
" "${ledger6}"

result="$(run_health "${case6_root}" "${case6_home}")"
out6="${result%%|*}"; rest="${result#*|}"; exit6="${rest##*|}"
assert_eq "case 6 exit 41 (forward-incompat)" "41" "${exit6}"
assert_eq "case 6 issue: forward_incompat_ledger" "yes" "$(has_issue_kind "${out6}" "forward_incompat_ledger")"

# ───────────────────────────────────────────────────────────────────────
# Case 7: legacy v1 ledger → warning
# ───────────────────────────────────────────────────────────────────────
echo "Case 7: legacy v1 ledger (warning)"
case7_root="${SANDBOX}/case7-legacy-v1"
case7_home="${SANDBOX}/cap-case7"
mkdir -p "${case7_root}"
cat > "${case7_root}/.cap.project.yaml" <<'EOF'
project_id: case7-legacy-v1
EOF
ensure_initialized "${case7_root}" "${case7_home}"
ledger7="${case7_home}/projects/case7-legacy-v1/.identity.json"
# Hand-write a v1-shaped ledger (P1 #2 inline shape: 4 fields only).
cat > "${ledger7}" <<EOF
{
  "schema_version": 1,
  "project_id": "case7-legacy-v1",
  "resolved_mode": "config",
  "origin_path": "${case7_root}",
  "created_at": "2026-04-01T00:00:00Z"
}
EOF

result="$(run_health "${case7_root}" "${case7_home}")"
out7="${result%%|*}"; rest="${result#*|}"; exit7="${rest##*|}"
assert_eq "case 7 exit 0 (warning only)" "0" "${exit7}"
assert_eq "case 7 overall warning" "warning" "$(json_field "${out7}" "overall_status")"
assert_eq "case 7 issue: legacy_ledger_pending_migration" "yes" \
  "$(has_issue_kind "${out7}" "legacy_ledger_pending_migration")"

# ───────────────────────────────────────────────────────────────────────
# Case 8: ledger schema drift (missing required field)
# ───────────────────────────────────────────────────────────────────────
echo "Case 8: ledger schema drift (missing required field)"
case8_root="${SANDBOX}/case8-drift"
case8_home="${SANDBOX}/cap-case8"
mkdir -p "${case8_root}"
cat > "${case8_root}/.cap.project.yaml" <<'EOF'
project_id: case8-drift
EOF
ensure_initialized "${case8_root}" "${case8_home}"
ledger8="${case8_home}/projects/case8-drift/.identity.json"
python3 -c "
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
d.pop('last_resolved_at', None)
with open(p, 'w') as f: json.dump(d, f, indent=2)
" "${ledger8}"

result="$(run_health "${case8_root}" "${case8_home}")"
out8="${result%%|*}"; rest="${result#*|}"; exit8="${rest##*|}"
assert_eq "case 8 exit 41 (schema drift)" "41" "${exit8}"
assert_eq "case 8 issue: ledger_schema_drift" "yes" "$(has_issue_kind "${out8}" "ledger_schema_drift")"

# ───────────────────────────────────────────────────────────────────────
# Case 9: origin_path collision → exit 53
# ───────────────────────────────────────────────────────────────────────
echo "Case 9: origin_path collision"
case9_root="${SANDBOX}/case9-origin-mismatch"
case9_home="${SANDBOX}/cap-case9"
mkdir -p "${case9_root}"
cat > "${case9_root}/.cap.project.yaml" <<'EOF'
project_id: case9-origin-mismatch
EOF
ensure_initialized "${case9_root}" "${case9_home}"
ledger9="${case9_home}/projects/case9-origin-mismatch/.identity.json"
python3 -c "
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
d['origin_path'] = '/some/other/path/that/does/not/match'
with open(p, 'w') as f: json.dump(d, f, indent=2)
" "${ledger9}"

result="$(run_health "${case9_root}" "${case9_home}")"
out9="${result%%|*}"; rest="${result#*|}"; exit9="${rest##*|}"
assert_eq "case 9 exit 53 (collision)" "53" "${exit9}"
assert_eq "case 9 issue: ledger_origin_mismatch" "yes" "$(has_issue_kind "${out9}" "ledger_origin_mismatch")"

# ───────────────────────────────────────────────────────────────────────
# Case 10: cap_version mismatch (warning)
# ───────────────────────────────────────────────────────────────────────
echo "Case 10: cap_version mismatch (warning)"
case10_root="${SANDBOX}/case10-cap-version"
case10_home="${SANDBOX}/cap-case10"
mkdir -p "${case10_root}"
cat > "${case10_root}/.cap.project.yaml" <<'EOF'
project_id: case10-cap-version
EOF
cat > "${case10_root}/repo.manifest.yaml" <<'EOF'
schema_version: 1
repo_id: case10
cap_version: v0.99.0-future
EOF
ensure_initialized "${case10_root}" "${case10_home}"
ledger10="${case10_home}/projects/case10-cap-version/.identity.json"
python3 -c "
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
d['cap_version'] = 'v0.10.0-old'
with open(p, 'w') as f: json.dump(d, f, indent=2)
" "${ledger10}"

result="$(run_health "${case10_root}" "${case10_home}")"
out10="${result%%|*}"; rest="${result#*|}"; exit10="${rest##*|}"
assert_eq "case 10 exit 0 (warning only)" "0" "${exit10}"
assert_eq "case 10 overall warning" "warning" "$(json_field "${out10}" "overall_status")"
assert_eq "case 10 issue: cap_version_mismatch" "yes" "$(has_issue_kind "${out10}" "cap_version_mismatch")"

# ───────────────────────────────────────────────────────────────────────
# Case 11: unwritable storage (skipped if running as root)
# ───────────────────────────────────────────────────────────────────────
echo "Case 11: unwritable storage"
if [ "$(id -u)" -eq 0 ]; then
  echo "  SKIP: cannot test write-permission behaviour as root"
else
  case11_root="${SANDBOX}/case11-unwritable"
  case11_home="${SANDBOX}/cap-case11"
  mkdir -p "${case11_root}"
  cat > "${case11_root}/.cap.project.yaml" <<'EOF'
project_id: case11-unwritable
EOF
  ensure_initialized "${case11_root}" "${case11_home}"
  store11="${case11_home}/projects/case11-unwritable"
  chmod -w "${store11}"

  result="$(run_health "${case11_root}" "${case11_home}")"
  out11="${result%%|*}"; rest="${result#*|}"; exit11="${rest##*|}"
  # Restore write before any other assertion can affect cleanup.
  chmod u+w "${store11}"

  # Read-only storage may also incidentally break sub-checks (ledger
  # reads via a non-writable parent still succeed on Linux), so the only
  # invariant we assert is that the unwritable signal surfaces. exit_code
  # may be 1 (generic error).
  assert_eq "case 11 exit 1" "1" "${exit11}"
  assert_eq "case 11 issue: unwritable_storage" "yes" "$(has_issue_kind "${out11}" "unwritable_storage")"
fi

echo ""
echo "----------------------------------------------------------------"
echo "Summary: ${pass_count} passed, ${fail_count} failed"
echo "----------------------------------------------------------------"

[ ${fail_count} -eq 0 ]
