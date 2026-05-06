#!/usr/bin/env bash
#
# test-provider-parity-check.sh — Smoke tests for provider parity artifact
# checks that do not require a real AI provider run.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CHECKER="${REPO_ROOT}/scripts/workflows/provider-parity-check.sh"

[ -x "${CHECKER}" ] || { echo "FAIL: provider parity checker not executable"; exit 1; }

SANDBOX="$(mktemp -d -t cap-provider-parity-test.XXXXXX)"
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

prepare_case() {
  local case_name="$1"
  local root="${SANDBOX}/${case_name}"
  local run_dir="${root}/cap/projects/parity-proj/reports/workflows/field-contract/run_001"
  local constitution_dir="${root}/cap/projects/parity-proj/constitutions"
  local handoffs_dir="${root}/cap/projects/parity-proj/handoffs"

  mkdir -p "${run_dir}" "${constitution_dir}" "${handoffs_dir}"
  touch \
    "${run_dir}/run-summary.md" \
    "${run_dir}/result.md" \
    "${run_dir}/agent-sessions.json" \
    "${run_dir}/workflow.log" \
    "${run_dir}/runtime-state.json"
}

write_constitution() {
  local case_name="$1"
  local json_payload="$2"
  local path="${SANDBOX}/${case_name}/cap/projects/parity-proj/constitutions/parity-task.json"
  printf '%s\n' "${json_payload}" > "${path}"
}

run_checker() {
  local case_name="$1"
  local root="${SANDBOX}/${case_name}"
  bash "${CHECKER}" \
    --run-dir "${root}/cap/projects/parity-proj/reports/workflows/field-contract/run_001" \
    --task-id parity-task \
    --project-id parity-proj \
    --workflow field-contract \
    --cap-home "${root}/cap" \
    2>&1
}

valid_json_with() {
  local non_goals="$1"
  local success_criteria="${2:-[\"criterion is present\"]}"
  printf '{"task_id":"parity-task","project_id":"parity-proj","source_request":"request","goal":"goal","goal_stage":"formal_specification","success_criteria":%s,"non_goals":%s,"execution_plan":[{"step_id":"prd","capability":"prd_generation"}]}' "${success_criteria}" "${non_goals}"
}

echo "Case A: non_goals=[] is accepted"
prepare_case "empty-non-goals"
write_constitution "empty-non-goals" "$(valid_json_with "[]")"
out="$(run_checker "empty-non-goals")"
rc=$?
assert_eq "exit code 0 when non_goals is empty array" "0" "${rc}"
assert_contains "non_goals present check passes" "PASS: Type B has required field: non_goals" "${out}"

echo "Case B: missing non_goals fails"
prepare_case "missing-non-goals"
write_constitution "missing-non-goals" '{"task_id":"parity-task","project_id":"parity-proj","source_request":"request","goal":"goal","goal_stage":"formal_specification","success_criteria":["criterion is present"],"execution_plan":[{"step_id":"prd","capability":"prd_generation"}]}'
out="$(run_checker "missing-non-goals")"
rc=$?
assert_eq "exit code 1 when non_goals is missing" "1" "${rc}"
assert_contains "missing non_goals reported" "FAIL: Type B missing required field: non_goals" "${out}"

echo "Case C: non_goals=null fails"
prepare_case "null-non-goals"
write_constitution "null-non-goals" "$(valid_json_with "null")"
out="$(run_checker "null-non-goals")"
rc=$?
assert_eq "exit code 1 when non_goals is null" "1" "${rc}"
assert_contains "null non_goals reported" "FAIL: Type B missing required field: non_goals" "${out}"

echo "Case D: success_criteria=[] still fails"
prepare_case "empty-success-criteria"
write_constitution "empty-success-criteria" "$(valid_json_with "[]" "[]")"
out="$(run_checker "empty-success-criteria")"
rc=$?
assert_eq "exit code 1 when success_criteria is empty" "1" "${rc}"
assert_contains "empty success_criteria reported" "FAIL: Type B missing required field: success_criteria" "${out}"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ ${fail_count} -eq 0 ]
