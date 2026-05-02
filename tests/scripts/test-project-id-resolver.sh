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
# Case 7: first-time `ensure` writes a v2 ledger with all required fields;
# re-entry preserves immutable fields and refreshes last_resolved_at.
# ---------------------------------------------------------------------------
echo "Case 7: first-time ensure writes v2 ledger; re-entry preserves immutables"
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

# v2 contract: schema_version=2, last_resolved_at present, cap_version null
# in this sandbox (no repo.manifest.yaml), previous_versions=[].
if [ -f "${ledger7}" ]; then
  read_field() {
    python3 -c '
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    print(json.load(f).get(sys.argv[2]) if sys.argv[2] in json.load(open(sys.argv[1])) else "")
' "${ledger7}" "$1" 2>/dev/null || true
  }
  v2_dump="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("schema_version"))
print(d.get("created_at"))
print(d.get("last_resolved_at"))
print("null" if d.get("cap_version") is None else d.get("cap_version"))
print("null" if d.get("migrated_at") is None else d.get("migrated_at"))
print(len(d.get("previous_versions", [])))
print(d.get("project_id"))
print(d.get("resolved_mode"))
print(d.get("origin_path"))
' "${ledger7}")"
  v2_sv="$(printf '%s' "${v2_dump}" | sed -n '1p')"
  v2_created="$(printf '%s' "${v2_dump}" | sed -n '2p')"
  v2_last_resolved="$(printf '%s' "${v2_dump}" | sed -n '3p')"
  v2_cap_version="$(printf '%s' "${v2_dump}" | sed -n '4p')"
  v2_migrated="$(printf '%s' "${v2_dump}" | sed -n '5p')"
  v2_prev_count="$(printf '%s' "${v2_dump}" | sed -n '6p')"
  v2_pid="$(printf '%s' "${v2_dump}" | sed -n '7p')"
  v2_mode="$(printf '%s' "${v2_dump}" | sed -n '8p')"
  v2_origin="$(printf '%s' "${v2_dump}" | sed -n '9p')"

  assert_eq "case 7a ledger.schema_version = 2" "2" "${v2_sv}"
  assert_eq "case 7a ledger.cap_version = null (no manifest)" "null" "${v2_cap_version}"
  assert_eq "case 7a ledger.migrated_at = null (fresh write)" "null" "${v2_migrated}"
  assert_eq "case 7a ledger.previous_versions empty (fresh write)" "0" "${v2_prev_count}"
  if [ -n "${v2_last_resolved}" ]; then
    echo "  PASS: case 7a ledger.last_resolved_at present"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: case 7a ledger.last_resolved_at present"
    fail_count=$((fail_count + 1))
  fi
fi

# Sleep 1s so the second ensure's UTC second timestamp differs.
sleep 1

# Re-entry: same origin → exit 0; immutable fields stay; last_resolved_at MAY refresh.
result="$(run_cap_paths "${case7_dir}" ensure CAP_HOME="${cap_home7}")"
exit7b="${result##*|}"
assert_eq "case 7b re-entry exit 0" "0" "${exit7b}"

if [ -f "${ledger7}" ]; then
  v2_dump_after="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("schema_version"))
print(d.get("created_at"))
print(d.get("last_resolved_at"))
print(d.get("project_id"))
print(d.get("resolved_mode"))
print(d.get("origin_path"))
print(len(d.get("previous_versions", [])))
' "${ledger7}")"
  after_sv="$(printf '%s' "${v2_dump_after}" | sed -n '1p')"
  after_created="$(printf '%s' "${v2_dump_after}" | sed -n '2p')"
  after_last_resolved="$(printf '%s' "${v2_dump_after}" | sed -n '3p')"
  after_pid="$(printf '%s' "${v2_dump_after}" | sed -n '4p')"
  after_mode="$(printf '%s' "${v2_dump_after}" | sed -n '5p')"
  after_origin="$(printf '%s' "${v2_dump_after}" | sed -n '6p')"
  after_prev_count="$(printf '%s' "${v2_dump_after}" | sed -n '7p')"

  assert_eq "case 7b schema_version stable" "${v2_sv}" "${after_sv}"
  assert_eq "case 7b created_at immutable" "${v2_created}" "${after_created}"
  assert_eq "case 7b project_id immutable" "${v2_pid}" "${after_pid}"
  assert_eq "case 7b resolved_mode immutable" "${v2_mode}" "${after_mode}"
  assert_eq "case 7b origin_path immutable" "${v2_origin}" "${after_origin}"
  assert_eq "case 7b previous_versions stays empty (no migration on re-entry)" "0" "${after_prev_count}"
  if [ "${after_last_resolved}" != "${v2_last_resolved}" ]; then
    echo "  PASS: case 7b last_resolved_at refreshed on re-entry"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: case 7b last_resolved_at refreshed on re-entry"
    echo "    before: ${v2_last_resolved}"
    echo "    after:  ${after_last_resolved}"
    fail_count=$((fail_count + 1))
  fi
fi

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

# ---------------------------------------------------------------------------
# Case 9: v1 ledger auto-migrates to v2 on `ensure` (P1 #3 migration path).
# Manually plant a v1-shape ledger and verify the next `ensure` upgrades it.
# ---------------------------------------------------------------------------
echo "Case 9: v1 ledger auto-migrates to v2 on ensure"
case9_dir="${SANDBOX}/case9-v1-migrate"
mkdir -p "${case9_dir}"
cat > "${case9_dir}/.cap.project.yaml" <<'EOF'
project_id: v1-legacy-proj
EOF
cap_home9="${SANDBOX}/cap-case9"
mkdir -p "${cap_home9}/projects/v1-legacy-proj"
ledger9="${cap_home9}/projects/v1-legacy-proj/.identity.json"

# Plant v1 shape (P1 #2 inline ledger): no last_resolved_at, no cap_version,
# no migrated_at, no previous_versions.
cat > "${ledger9}" <<EOF
{
  "schema_version": 1,
  "project_id": "v1-legacy-proj",
  "resolved_mode": "config",
  "origin_path": "${case9_dir}",
  "created_at": "2026-04-30T08:00:00Z"
}
EOF

result="$(run_cap_paths "${case9_dir}" ensure CAP_HOME="${cap_home9}")"
exit9="${result##*|}"
assert_eq "case 9 v1 → v2 migration exit 0" "0" "${exit9}"

if [ -f "${ledger9}" ]; then
  v9_dump="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("schema_version"))
print(d.get("created_at"))
print("null" if d.get("migrated_at") is None else "set")
print(len(d.get("previous_versions", [])))
print(d.get("previous_versions", [{}])[0].get("schema_version") if d.get("previous_versions") else "")
' "${ledger9}")"
  v9_sv="$(printf '%s' "${v9_dump}" | sed -n '1p')"
  v9_created="$(printf '%s' "${v9_dump}" | sed -n '2p')"
  v9_migrated="$(printf '%s' "${v9_dump}" | sed -n '3p')"
  v9_prev_count="$(printf '%s' "${v9_dump}" | sed -n '4p')"
  v9_prev_first_sv="$(printf '%s' "${v9_dump}" | sed -n '5p')"

  assert_eq "case 9 schema_version bumped to 2" "2" "${v9_sv}"
  assert_eq "case 9 created_at preserved across migration" "2026-04-30T08:00:00Z" "${v9_created}"
  assert_eq "case 9 migrated_at stamped" "set" "${v9_migrated}"
  assert_eq "case 9 previous_versions has 1 entry" "1" "${v9_prev_count}"
  assert_eq "case 9 previous_versions[0].schema_version = 1" "1" "${v9_prev_first_sv}"
fi

# ---------------------------------------------------------------------------
# Case 10: ledger schema_version=99 → exit 41 (forward-incompat halt).
# ---------------------------------------------------------------------------
echo "Case 10: ledger schema_version=99 halts with exit 41"
case10_dir="${SANDBOX}/case10-future-schema"
mkdir -p "${case10_dir}"
cat > "${case10_dir}/.cap.project.yaml" <<'EOF'
project_id: future-proj
EOF
cap_home10="${SANDBOX}/cap-case10"
mkdir -p "${cap_home10}/projects/future-proj"
cat > "${cap_home10}/projects/future-proj/.identity.json" <<EOF
{
  "schema_version": 99,
  "project_id": "future-proj",
  "resolved_mode": "config",
  "origin_path": "${case10_dir}",
  "created_at": "2027-01-01T00:00:00Z",
  "last_resolved_at": "2027-01-01T00:00:00Z"
}
EOF

result="$(run_cap_paths "${case10_dir}" get CAP_HOME="${cap_home10}")"
exit10="${result##*|}"
rest10="${result#*|}"
stderr10="${rest10%|*}"
assert_eq "case 10 forward-incompat exit 41" "41" "${exit10}"
assert_contains "case 10 stderr names schema_version=99" "schema_version=99" "${stderr10}"
assert_contains "case 10 stderr suggests upgrade" "upgrade CAP" "${stderr10}"

# ---------------------------------------------------------------------------
# Case 11: read-only `get` does NOT update last_resolved_at (P1 #3 §4).
# ---------------------------------------------------------------------------
echo "Case 11: read-only get does not mutate ledger"
case11_dir="${SANDBOX}/case11-readonly"
mkdir -p "${case11_dir}"
cat > "${case11_dir}/.cap.project.yaml" <<'EOF'
project_id: readonly-proj
EOF
cap_home11="${SANDBOX}/cap-case11"

# Establish ledger via ensure first.
run_cap_paths "${case11_dir}" ensure CAP_HOME="${cap_home11}" >/dev/null
ledger11="${cap_home11}/projects/readonly-proj/.identity.json"
ledger11_before="$(cat "${ledger11}")"

# Sleep 1s so any timestamp update would be observable.
sleep 1

# Read-only call: must not touch ledger.
run_cap_paths "${case11_dir}" get CAP_HOME="${cap_home11}" >/dev/null
ledger11_after="$(cat "${ledger11}")"

assert_eq "case 11 read-only get leaves ledger byte-identical" "${ledger11_before}" "${ledger11_after}"

# ---------------------------------------------------------------------------
# Case 12: cap_version is read from repo.manifest.yaml top-level only,
# never from commands.version (which is a CLI command name) and never
# from the manifest's own schema_version (which is the manifest schema, not cap).
# ---------------------------------------------------------------------------
echo "Case 12: cap_version sourced from manifest top-level cap_version field"
case12_dir="${SANDBOX}/case12-manifest-version"
mkdir -p "${case12_dir}"
cat > "${case12_dir}/.cap.project.yaml" <<'EOF'
project_id: manifest-version-proj
EOF
# Plant a manifest with: top-level cap_version (the SSOT), an indented
# commands.version (must NOT be used), and a top-level schema_version (must
# NOT be confused with cap version).
cat > "${case12_dir}/repo.manifest.yaml" <<'EOF'
schema_version: 1
repo_id: manifest-version-proj
cap_version: v9.9.9-test
commands:
  version: cap version
EOF
cap_home12="${SANDBOX}/cap-case12"

run_cap_paths "${case12_dir}" ensure CAP_HOME="${cap_home12}" >/dev/null
ledger12="${cap_home12}/projects/manifest-version-proj/.identity.json"

if [ -f "${ledger12}" ]; then
  v12_cap_version="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1])).get("cap_version"))
' "${ledger12}")"
  assert_eq "case 12 ledger.cap_version reads top-level cap_version" "v9.9.9-test" "${v12_cap_version}"
fi

echo
echo "Summary: ${pass_count} passed, ${fail_count} failed"

if [ "${fail_count}" -gt 0 ]; then
  exit 1
fi
exit 0
