#!/usr/bin/env bash
#
# test-cap-project-init-namespace.sh — P0c Config Namespace Migration
# batch 2.5 producer gate.
#
# Verifies cap project init now writes .cap/project.yaml (the new namespace
# introduced in P0c batch 1) instead of the legacy .cap.project.yaml flat
# file. Legacy projects keep working because the resolver still falls back,
# and existing legacy files are recognised as "already initialised" so re-init
# without --force still refuses.
#
# Coverage:
#   Case 1 fresh init in git repo
#          → .cap/project.yaml created with given project_id; .cap/ dir exists;
#            no .cap.project.yaml leaked.
#   Case 2 re-init refused without --force (new path exists)
#          → exit non-zero, message names new path + suggests migrate-config.
#   Case 3 re-init refused without --force (legacy path exists, no new path)
#          → exit non-zero, message names legacy path + suggests migrate-config.
#   Case 4 --force on legacy-only project preserves id, writes new path
#          → new path content has the legacy project_id verbatim;
#            legacy file untouched (no auto-delete).
#   Case 5 --force on new path rewrites in place
#          → unknown keys preserved; project_id line replaced.
#   Case 6 --project-id override wins over both existing files
#          → new path content has the override id, not legacy/existing.
#   Case 7 init reports config_path = new namespace path in text output

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CAP_PROJECT_SH="${REPO_ROOT}/scripts/cap-project.sh"

[ -f "${CAP_PROJECT_SH}" ] || { echo "FAIL: scripts/cap-project.sh missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-init-ns-test.XXXXXX)"
SANDBOX_HOMES="${SANDBOX}/homes"
mkdir -p "${SANDBOX_HOMES}"
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

# Bring up an isolated git repo + dedicated CAP_HOME for one test case.
build_case_root() {
  local name="$1"
  local root="${SANDBOX}/${name}"
  mkdir -p "${root}"
  ( cd "${root}" && git init -q && git commit --allow-empty -q -m init )
  printf '%s\n' "${root}"
}

run_init() {
  local root="$1"; shift
  local cap_home="${SANDBOX_HOMES}/${root##*/}"
  mkdir -p "${cap_home}"
  CAP_HOME="${cap_home}" bash "${CAP_PROJECT_SH}" init --project-root "${root}" "$@" 2>&1
  return $?
}

# ── Case 1 ──────────────────────────────────────────────────────────────
echo "Case 1: fresh init writes .cap/project.yaml in git repo"
C1="$(build_case_root c1)"
out_c1="$(run_init "${C1}" --project-id case1-id)"
rc_c1=$?
assert_eq "rc 0"                              "0"   "${rc_c1}"
assert_present "new path created"             "${C1}/.cap/project.yaml"
assert_absent  "no legacy file leaked"        "${C1}/.cap.project.yaml"
assert_contains "config_path is new namespace" ".cap/project.yaml" "${out_c1}"
assert_contains "project_id_source=flag"      "project_id_source=flag" "${out_c1}"
content_c1="$(grep '^project_id:' "${C1}/.cap/project.yaml")"
assert_eq "id matches override" "project_id: case1-id" "${content_c1}"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: re-init refused when new path exists (no --force)"
out_c2="$(run_init "${C1}" --project-id rebellion 2>&1)"
rc_c2=$?
case "${rc_c2}" in
  0) echo "  FAIL: expected non-zero, got 0"; fail_count=$((fail_count + 1)) ;;
  *) echo "  PASS: rc non-zero (${rc_c2})"; pass_count=$((pass_count + 1)) ;;
esac
assert_contains "names new path"              ".cap/project.yaml"          "${out_c2}"
assert_contains "suggests migrate-config"     "migrate-config"             "${out_c2}"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: re-init refused when legacy path exists alone (no --force)"
C3="$(build_case_root c3)"
echo 'project_id: legacy-only-id' > "${C3}/.cap.project.yaml"
out_c3="$(run_init "${C3}" --project-id different-id 2>&1)"
rc_c3=$?
case "${rc_c3}" in
  0) echo "  FAIL: expected non-zero, got 0"; fail_count=$((fail_count + 1)) ;;
  *) echo "  PASS: rc non-zero (${rc_c3})"; pass_count=$((pass_count + 1)) ;;
esac
assert_contains "names legacy path"           ".cap.project.yaml"  "${out_c3}"
assert_contains "suggests migrate-config"     "migrate-config"     "${out_c3}"
assert_absent  "no .cap/project.yaml created in refused run" "${C3}/.cap/project.yaml"

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: --force on legacy-only project preserves id and writes new path"
C4="$(build_case_root c4)"
echo 'project_id: legacy-c4-id' > "${C4}/.cap.project.yaml"
out_c4="$(run_init "${C4}" --force)"
rc_c4=$?
assert_eq "rc 0"                              "0"   "${rc_c4}"
assert_present "new path created"             "${C4}/.cap/project.yaml"
assert_present "legacy preserved (no auto-delete)" "${C4}/.cap.project.yaml"
assert_contains "project_id_source=existing_config" "project_id_source=existing_config" "${out_c4}"
new_id_c4="$(grep '^project_id:' "${C4}/.cap/project.yaml")"
assert_eq "preserved legacy id in new path" "project_id: legacy-c4-id" "${new_id_c4}"
legacy_id_c4="$(grep '^project_id:' "${C4}/.cap.project.yaml")"
assert_eq "legacy file content unchanged"    "project_id: legacy-c4-id" "${legacy_id_c4}"

# ── Case 5 ──────────────────────────────────────────────────────────────
echo "Case 5: --force on new path rewrites in place, preserves unknown keys"
C5="$(build_case_root c5)"
mkdir -p "${C5}/.cap"
cat > "${C5}/.cap/project.yaml" <<'EOF'
project_id: original-c5
extra_field: keep-me
project_name: pre-existing
EOF
out_c5="$(run_init "${C5}" --project-id replaced-c5 --force)"
rc_c5=$?
assert_eq "rc 0"                              "0"   "${rc_c5}"
new_content_c5="$(cat "${C5}/.cap/project.yaml")"
assert_contains "id replaced"                 "project_id: replaced-c5" "${new_content_c5}"
assert_contains "extra_field preserved"       "extra_field: keep-me"    "${new_content_c5}"
assert_contains "project_name preserved"      "project_name: pre-existing" "${new_content_c5}"
case "${new_content_c5}" in
  *original-c5*) echo "  FAIL: original id leaked"; fail_count=$((fail_count + 1)) ;;
  *)             echo "  PASS: original id replaced"; pass_count=$((pass_count + 1)) ;;
esac
assert_contains "config_rewrote_existing=1"   "config_rewrote_existing=1" "${out_c5}"

# ── Case 6 ──────────────────────────────────────────────────────────────
echo "Case 6: --project-id override wins over legacy + existing files"
C6="$(build_case_root c6)"
echo 'project_id: legacy-c6' > "${C6}/.cap.project.yaml"
mkdir -p "${C6}/.cap"
echo 'project_id: existing-new-c6' > "${C6}/.cap/project.yaml"
out_c6="$(run_init "${C6}" --project-id override-wins-c6 --force)"
rc_c6=$?
assert_eq "rc 0"                              "0"   "${rc_c6}"
final_id_c6="$(grep '^project_id:' "${C6}/.cap/project.yaml")"
assert_eq "override wins"                     "project_id: override-wins-c6" "${final_id_c6}"
assert_contains "project_id_source=flag"      "project_id_source=flag"  "${out_c6}"

# ── Case 7 ──────────────────────────────────────────────────────────────
echo "Case 7: init text output reports new-namespace config_path"
C7="$(build_case_root c7)"
out_c7="$(run_init "${C7}" --project-id case7-id --format text)"
rc_c7=$?
assert_eq "rc 0"                              "0"   "${rc_c7}"
assert_contains "text format reports config_path"  "config_path"          "${out_c7}"
assert_contains "config_path is new namespace path" ".cap/project.yaml"   "${out_c7}"

echo ""
echo "cap-project-init-namespace: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
