#!/usr/bin/env bash
#
# test-cap-project-constitution-prompt.sh — Deterministic e2e for prompt mode
# of `cap project constitution` (P2 #8 release gate).
#
# What we cover (4 cases / 16+ assertions):
#   Case 1 happy:           stub writes valid draft with canonical fence →
#                           runner extracts, validates, status=ok, four-part
#                           snapshot lands on disk.
#   Case 2 missing-fence:   draft has no JSON fence → runner reports the
#                           extraction error in validation.json, status=failed,
#                           snapshot dir still exists with all four artefacts
#                           (so doctor / status can observe partial state).
#   Case 3 invalid-schema:  draft fence parses but JSON misses required
#                           blocks → runner runs jsonschema, status=failed,
#                           validation.json status=failed, four-part snapshot
#                           still on disk.
#   Case 4 nonzero-exit:    stub mimics a workflow halt → runner notes the
#                           non-zero workflow exit code, status=failed,
#                           workflow_run_id still recorded.
#
# Determinism: zero AI calls. The CAP_PROJECT_CONSTITUTION_WORKFLOW_STUB env
# variable in engine/project_constitution_runner.py:_invoke_workflow swaps
# in tests/e2e/fixtures/project-constitution-stub.sh, which writes a
# canonical run-dir layout and returns the requested exit code. No network,
# no installed `cap`, no AI provider keys required.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUNNER="${REPO_ROOT}/engine/project_constitution_runner.py"
STUB="${SCRIPT_DIR}/fixtures/project-constitution-stub.sh"

[ -f "${RUNNER}" ] || { echo "FAIL: ${RUNNER} missing"; exit 1; }
[ -x "${STUB}" ]   || { echo "FAIL: ${STUB} not executable"; exit 1; }

SANDBOX="$(mktemp -d -t cap-test-prompt-mode.XXXXXX)"
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

# Initialise a fresh repo + cap-home pair per case so cross-case state never
# leaks. We also point CAP_HOME at the sandbox so the bootstrap project's
# stub-written run dir lands where the runner will find it.
init_case() {
  local case_id="$1"
  local case_root="${SANDBOX}/${case_id}-repo"
  local case_home="${SANDBOX}/${case_id}-cap"
  mkdir -p "${case_root}"
  cat > "${case_root}/.cap.project.yaml" <<EOF
project_id: smoke
EOF
  printf '%s|%s' "${case_root}" "${case_home}"
}

run_runner() {
  local mode="$1" case_root="$2" case_home="$3" stamp="$4"
  shift 4
  local out err code tmp_out tmp_err
  tmp_out="$(mktemp)"; tmp_err="$(mktemp)"
  set +e
  CAP_HOME="${case_home}" \
    CAP_STUB_MODE="${mode}" \
    CAP_PROJECT_CONSTITUTION_WORKFLOW_STUB="${STUB}" \
    python3 "${RUNNER}" \
      --prompt "deterministic e2e ${mode}" \
      --project-root "${case_root}" \
      --cap-home "${case_home}" \
      --stamp "${stamp}" \
      "$@" >"${tmp_out}" 2>"${tmp_err}"
  code=$?
  set -e
  out="$(cat "${tmp_out}")"; err="$(cat "${tmp_err}")"
  rm -f "${tmp_out}" "${tmp_err}"
  printf '%s|%s|%s' "${out}" "${err}" "${code}"
}

# ── Case 1 ──────────────────────────────────────────────────────────────
echo "Case 1: prompt-mode happy path → status=ok, four-part snapshot"
case1_pair="$(init_case c1)"
c1_root="${case1_pair%|*}"; c1_home="${case1_pair#*|}"
STAMP1="20260503T120000Z"

result="$(run_runner happy "${c1_root}" "${c1_home}" "${STAMP1}")"
out1="${result%%|*}"; rest="${result#*|}"; exit1="${rest##*|}"

assert_eq "case 1 exit 0" "0" "${exit1}"
assert_contains "case 1 status=ok" "status=ok" "${out1}"
assert_contains "case 1 mode=prompt" "mode=prompt" "${out1}"
assert_contains "case 1 validation ok=True" "validation: ok=True" "${out1}"
# A workflow_run_id should be recorded since the stub created a run dir.
assert_contains "case 1 workflow_run_id present" "workflow_run_id=run_" "${out1}"

c1_dir="${c1_home}/projects/smoke/constitutions/project/${STAMP1}"
assert_file_exists "case 1 markdown" "${c1_dir}/project-constitution.md"
assert_file_exists "case 1 json" "${c1_dir}/project-constitution.json"
assert_file_exists "case 1 validation" "${c1_dir}/validation.json"
assert_file_exists "case 1 source-prompt" "${c1_dir}/source-prompt.txt"

v1="$(cat "${c1_dir}/validation.json")"
assert_contains "case 1 validation.json status=ok" '"status": "ok"' "${v1}"
sp1="$(cat "${c1_dir}/source-prompt.txt")"
assert_contains "case 1 source-prompt records workflow exit" \
  "workflow_exit_code=0" "${sp1}"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: missing-fence draft → status=failed, all four artefacts present"
case2_pair="$(init_case c2)"
c2_root="${case2_pair%|*}"; c2_home="${case2_pair#*|}"
STAMP2="20260503T120000Z"

result="$(run_runner missing-fence "${c2_root}" "${c2_home}" "${STAMP2}")"
out2="${result%%|*}"; rest="${result#*|}"; exit2="${rest##*|}"

assert_eq "case 2 exit 1" "1" "${exit2}"
assert_contains "case 2 status=failed" "status=failed" "${out2}"
# The runner wraps the extraction failure into the verdict's first error so
# the standard --format text "validation_errors" block surfaces it.
assert_contains "case 2 names canonical fence in errors" \
  "<<<CONSTITUTION_JSON_BEGIN/END>>>" "${out2}"

c2_dir="${c2_home}/projects/smoke/constitutions/project/${STAMP2}"
assert_file_exists "case 2 markdown still written" "${c2_dir}/project-constitution.md"
assert_file_exists "case 2 json still written" "${c2_dir}/project-constitution.json"
assert_file_exists "case 2 validation still written" "${c2_dir}/validation.json"
assert_file_exists "case 2 source-prompt still written" "${c2_dir}/source-prompt.txt"

v2="$(cat "${c2_dir}/validation.json")"
assert_contains "case 2 validation.json status=failed" '"status": "failed"' "${v2}"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: invalid-schema draft → status=failed, jsonschema errors recorded"
case3_pair="$(init_case c3)"
c3_root="${case3_pair%|*}"; c3_home="${case3_pair#*|}"
STAMP3="20260503T120000Z"

result="$(run_runner invalid-schema "${c3_root}" "${c3_home}" "${STAMP3}")"
out3="${result%%|*}"; rest="${result#*|}"; exit3="${rest##*|}"

assert_eq "case 3 exit 1" "1" "${exit3}"
assert_contains "case 3 status=failed" "status=failed" "${out3}"
# Real schema verdict (vs extraction error) — names a missing required block.
assert_contains "case 3 reports missing required" "is a required property" "${out3}"

c3_dir="${c3_home}/projects/smoke/constitutions/project/${STAMP3}"
assert_file_exists "case 3 four-part: markdown" "${c3_dir}/project-constitution.md"
assert_file_exists "case 3 four-part: json" "${c3_dir}/project-constitution.json"
assert_file_exists "case 3 four-part: validation" "${c3_dir}/validation.json"
assert_file_exists "case 3 four-part: source-prompt" "${c3_dir}/source-prompt.txt"

v3="$(cat "${c3_dir}/validation.json")"
assert_contains "case 3 validation.json status=failed" '"status": "failed"' "${v3}"
assert_contains "case 3 validation.json names required field" \
  "is a required property" "${v3}"

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: workflow non-zero exit → status=failed, workflow_run_id recorded"
case4_pair="$(init_case c4)"
c4_root="${case4_pair%|*}"; c4_home="${case4_pair#*|}"
STAMP4="20260503T120000Z"

result="$(run_runner nonzero-exit "${c4_root}" "${c4_home}" "${STAMP4}")"
out4="${result%%|*}"; rest="${result#*|}"; exit4="${rest##*|}"

assert_eq "case 4 exit 1" "1" "${exit4}"
assert_contains "case 4 status=failed" "status=failed" "${out4}"
# The runner coerces a non-zero workflow exit to failure even when the
# extracted payload would have validated cleanly.
assert_contains "case 4 records workflow exit code" "workflow_exit=1" "${out4}"
assert_contains "case 4 workflow_run_id still present" "workflow_run_id=run_" "${out4}"

c4_dir="${c4_home}/projects/smoke/constitutions/project/${STAMP4}"
assert_file_exists "case 4 four-part: markdown" "${c4_dir}/project-constitution.md"
assert_file_exists "case 4 four-part: json" "${c4_dir}/project-constitution.json"
assert_file_exists "case 4 four-part: validation" "${c4_dir}/validation.json"
assert_file_exists "case 4 four-part: source-prompt" "${c4_dir}/source-prompt.txt"

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "----------------------------------------------------------------"
echo "Summary: ${pass_count} passed, ${fail_count} failed"
echo "----------------------------------------------------------------"

[ ${fail_count} -eq 0 ]
