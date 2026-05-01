#!/usr/bin/env bash
#
# test-design-source-ingest.sh — Smoke for the v0.21.0
# scripts/workflows/ingest-design-source.sh deterministic step.
#
# Six cases:
#   1. No constitution + empty legacy fallback              → no_design_source no-op
#   2. constitution.design_source.type: none                → no-op
#   3. Real source_path with two files                      → rebuilt + 3 artifacts + sentinel
#   4. Re-run unchanged                                     → cached, sentinel preserved
#   5. Modify a file                                        → rebuilt, hash changes
#   6. source_path declared but missing on disk             → halt at exit 41

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
INGEST="${REPO_ROOT}/scripts/workflows/ingest-design-source.sh"

[ -x "${INGEST}" ] || { echo "FAIL: ingest script not executable"; exit 1; }

SANDBOX="$(mktemp -d -t cap-ingest-test.XXXXXX)"
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

assert_file_exists() {
  local desc="$1" path="$2"
  if [ -f "${path}" ]; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    missing: ${path}"
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

file_mtime() {
  if stat -c %Y "$1" >/dev/null 2>&1; then
    stat -c %Y "$1"
    return
  fi
  stat -f %m "$1"
}

run_ingest() {
  local workdir="$1"
  # Subshell so the cd does not leak; explicit exit so the function's
  # return code reflects the ingest exit, not the implicit cd that would
  # otherwise mask exit 41 with 0.
  (cd "${workdir}" && HOME="${SANDBOX}/home" bash "${INGEST}" 2>&1)
}

mkdir -p "${SANDBOX}/home/.cap"

# ─────────────────────────────────────────────────────────
# Case 1: no constitution at all + no legacy fallback content
# ─────────────────────────────────────────────────────────

echo "Case 1: no constitution → no_design_source no-op"
WD1="${SANDBOX}/case1"
mkdir -p "${WD1}"
out="$(run_ingest "${WD1}")"
assert_contains "outcome=no_design_source" "outcome: no_design_source" "${out}"
[ ! -d "${WD1}/docs/design" ]
assert_eq "docs/design not created on no-op" "0" "$?"

# ─────────────────────────────────────────────────────────
# Case 2: constitution declares type none
# ─────────────────────────────────────────────────────────

echo "Case 2: design_source.type: none → no-op"
WD2="${SANDBOX}/case2"
mkdir -p "${WD2}"
cat > "${WD2}/.cap.constitution.yaml" <<'EOF'
design_source:
  type: none
EOF
out="$(run_ingest "${WD2}")"
assert_contains "outcome=no_design_source" "outcome: no_design_source" "${out}"

# ─────────────────────────────────────────────────────────
# Case 3: real source_path, two files → rebuilt
# ─────────────────────────────────────────────────────────

echo "Case 3: real source_path → rebuilt with three artifacts"
WD3="${SANDBOX}/case3"
SRC3="${SANDBOX}/src3"
mkdir -p "${WD3}" "${SRC3}/project"
echo "<html>v1</html>" > "${SRC3}/project/main.html"
echo "# README v1" > "${SRC3}/README.md"
cat > "${WD3}/.cap.constitution.yaml" <<EOF
design_source:
  type: local_design_package
  source_path: ${SRC3}
  package: case3-pkg
  mode: read_only_reference
EOF
out="$(run_ingest "${WD3}")"
assert_contains "outcome=rebuilt" "outcome: rebuilt" "${out}"
assert_contains "files_count=2" "files_count: 2" "${out}"
assert_file_exists "source-summary.md exists" "${WD3}/docs/design/source-summary.md"
assert_file_exists "source-tree.txt exists" "${WD3}/docs/design/source-tree.txt"
assert_file_exists "design-source.yaml exists" "${WD3}/docs/design/design-source.yaml"
assert_file_exists ".source-hash.txt sentinel exists" "${WD3}/docs/design/.source-hash.txt"
hash3="$(cat "${WD3}/docs/design/.source-hash.txt")"
[ -n "${hash3}" ] && [ ${#hash3} -eq 64 ]
assert_eq "sentinel contains 64-char hex hash" "0" "$?"

# Tree contents deterministic
tree_content="$(cat "${WD3}/docs/design/source-tree.txt")"
assert_contains "tree includes README.md" "README.md" "${tree_content}"
assert_contains "tree includes project/main.html" "project/main.html" "${tree_content}"

# Metadata yaml has key fields
yaml_content="$(cat "${WD3}/docs/design/design-source.yaml")"
assert_contains "yaml carries package: case3-pkg" "package: case3-pkg" "${yaml_content}"
assert_contains "yaml carries source_path" "${SRC3}" "${yaml_content}"

# ─────────────────────────────────────────────────────────
# Case 4: re-run unchanged → cached
# ─────────────────────────────────────────────────────────

echo "Case 4: re-run unchanged → cached"
mtime_before="$(file_mtime "${WD3}/docs/design/source-summary.md")"
sleep 1
out="$(run_ingest "${WD3}")"
assert_contains "outcome=cached on rerun" "outcome: cached" "${out}"
mtime_after="$(file_mtime "${WD3}/docs/design/source-summary.md")"
assert_eq "summary mtime unchanged on cache hit" "${mtime_before}" "${mtime_after}"
hash3_after="$(cat "${WD3}/docs/design/.source-hash.txt")"
assert_eq "hash unchanged on cache hit" "${hash3}" "${hash3_after}"

# ─────────────────────────────────────────────────────────
# Case 5: modify source → rebuild + hash changes
# ─────────────────────────────────────────────────────────

echo "Case 5: source modified → rebuilt with new hash"
echo "<html>v2 changed</html>" > "${SRC3}/project/main.html"
out="$(run_ingest "${WD3}")"
assert_contains "outcome=rebuilt after modification" "outcome: rebuilt" "${out}"
hash3_v2="$(cat "${WD3}/docs/design/.source-hash.txt")"
[ "${hash3}" != "${hash3_v2}" ]
assert_eq "hash changed after source modification" "0" "$?"

# ─────────────────────────────────────────────────────────
# Case 6: source_path declared but missing on disk
# ─────────────────────────────────────────────────────────

echo "Case 6: source_path missing → halt at exit 41"
WD6="${SANDBOX}/case6"
mkdir -p "${WD6}"
cat > "${WD6}/.cap.constitution.yaml" <<EOF
design_source:
  type: local_design_package
  source_path: ${SANDBOX}/this-path-does-not-exist
EOF
out="$(run_ingest "${WD6}")"
rc=$?
assert_eq "exit code 41 when source_path missing (schema_validation_failed)" "41" "${rc}"
assert_contains "ingest_failed reported" "ingest_failed" "${out}"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ ${fail_count} -eq 0 ]
