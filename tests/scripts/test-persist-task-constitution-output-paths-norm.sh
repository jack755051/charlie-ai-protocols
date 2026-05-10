#!/usr/bin/env bash
#
# test-persist-task-constitution-output-paths-norm.sh — Lock the
# v0.25.5 contract for normalize_task_constitution_json's
# output_paths string-to-object normalization.
#
# Pre-fix: schemas/task-constitution.schema.yaml mandates
# execution_plan[].output_paths.items.type = "object", but
# 01-supervisor-agent.md documentation listed output_paths as an
# optional field without specifying item type. Both Codex and Claude
# have repeatedly emitted strings (the bare path) for output_paths
# items. The persist step then halted with
# "execution_plan/0/output_paths/0: '...' is not of type 'object'".
#
# Fix: normalizer auto-converts string items to {"path": "..."}
# objects so the strict schema validates while preserving full path
# information for downstream consumers. Existing object items pass
# through unchanged.
#
# Coverage:
#   Case 1: AI emits output_paths as list of strings → normalizer
#           converts each string to {"path": "..."}.
#   Case 2: AI emits output_paths as list of objects already →
#           items unchanged.
#   Case 3: AI emits empty output_paths → empty list preserved.
#   Case 4: AI emits mixed list (string + object) → strings
#           converted, objects preserved.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
PERSIST_SH="${REPO_ROOT}/scripts/workflows/persist-task-constitution.sh"

[ -f "${PERSIST_SH}" ] || { echo "FAIL: persist-task-constitution.sh missing"; exit 1; }

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

# Helper: source the persist script's normalize_task_constitution_json
# function and invoke it on a JSON payload, returning the normalised
# JSON. The persist script's main path runs setup logic that we don't
# want to trigger; just extract and call the function in a subshell.
run_normalizer() {
  local json_in="$1"
  # Extract the function body from the persist script and eval it in
  # the current shell to avoid running the persist script's main flow
  # (which expects a real workflow context). The exact normalizer
  # code path that production runs is exercised verbatim.
  local func_def
  func_def="$(awk '/^normalize_task_constitution_json\(\)/,/^\}$/' "${PERSIST_SH}")"
  PYTHON_BIN="${PYTHON_BIN:-python3}" \
    CAP_RUNTIME_PROJECT_ID="${CAP_RUNTIME_PROJECT_ID:-test-project}" \
    bash -c "${func_def}
PYTHON_BIN=\"\${PYTHON_BIN:-python3}\"
normalize_task_constitution_json \"\$1\"" _ "${json_in}" 2>/dev/null
}

# Build a minimum valid task constitution skeleton so the normalizer's
# other transforms do not bail out before reaching the output_paths
# pass.
build_payload() {
  local output_paths_json="$1"
  cat <<JSON
{
  "task_id": "norm-test",
  "project_id": "test-project",
  "source_request": "fixture",
  "goal": "test output_paths normalization",
  "goal_stage": "implementation_and_verification",
  "success_criteria": ["fixture-criterion"],
  "non_goals": [],
  "execution_plan": [
    {
      "step_id": "demo_step",
      "capability": "demo_capability",
      "output_paths": ${output_paths_json}
    }
  ]
}
JSON
}

extract_output_paths() {
  local norm_json="$1"
  printf '%s' "${norm_json}" | "${PYTHON_BIN}" -c '
import json, sys
data = json.load(sys.stdin)
plan = data.get("execution_plan", [])
print(json.dumps(plan[0].get("output_paths", []) if plan else []))
'
}

# ── Case 1: list of strings → list of {path: ...} objects ───────────
echo "Case 1: strings auto-converted to {path: ...} objects"
case1_in="$(build_payload '["/tmp/foo.md","/tmp/bar.md"]')"
case1_out="$(run_normalizer "${case1_in}")"
case1_paths="$(extract_output_paths "${case1_out}")"
assert_eq "1. strings normalised to object form" \
  '[{"path": "/tmp/foo.md"}, {"path": "/tmp/bar.md"}]' \
  "${case1_paths}"

# ── Case 2: list of objects already → unchanged ─────────────────────
echo "Case 2: existing objects pass through unchanged"
case2_in="$(build_payload '[{"path":"/tmp/foo.md","note":"primary"},{"path":"/tmp/bar.md"}]')"
case2_out="$(run_normalizer "${case2_in}")"
case2_paths="$(extract_output_paths "${case2_out}")"
assert_eq "2. object items preserved including extra keys" \
  '[{"path": "/tmp/foo.md", "note": "primary"}, {"path": "/tmp/bar.md"}]' \
  "${case2_paths}"

# ── Case 3: empty list → empty list ─────────────────────────────────
echo "Case 3: empty output_paths preserved"
case3_in="$(build_payload '[]')"
case3_out="$(run_normalizer "${case3_in}")"
case3_paths="$(extract_output_paths "${case3_out}")"
assert_eq "3. empty list stays empty" "[]" "${case3_paths}"

# ── Case 4: mixed list → strings normalised, objects preserved ──────
echo "Case 4: mixed list normalised partially"
case4_in="$(build_payload '["/tmp/legacy.md",{"path":"/tmp/structured.md","note":"keep"}]')"
case4_out="$(run_normalizer "${case4_in}")"
case4_paths="$(extract_output_paths "${case4_out}")"
assert_eq "4. mixed list normalised correctly" \
  '[{"path": "/tmp/legacy.md"}, {"path": "/tmp/structured.md", "note": "keep"}]' \
  "${case4_paths}"

echo ""
total=$((pass_count + fail_count))
echo "persist-task-constitution-output-paths-norm: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
