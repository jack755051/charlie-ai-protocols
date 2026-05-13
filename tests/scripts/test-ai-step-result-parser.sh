#!/usr/bin/env bash
#
# test-ai-step-result-parser.sh — Lock the v0.26.0 AI step result
# parser contract documented in docs/cap/AI-STEP-RESULT-CONTRACT.md.
#
# Closes bug #12 from the 2026-05-10 component-repo dogfood: pre-fix,
# cap-workflow-exec.sh treated non-empty stdout as step success, so
# AI agents that self-reported blocked / failed inside their markdown
# bodies still rolled the run up to final_state=completed. The parser
# this fixture exercises is the data layer the workflow uses to
# detect those self-reports and halt honestly.
#
# Coverage matrix (every contract clause has a fixture case):
#
#   Section 1 — primary spellings of each enum value
#     1a success / 1b failed / 1c blocked / 1d needs_data
#
#   Section 2 — alias normalization (case + variant)
#     2a 'OK', '成功', 'completed', 'done', 'pass', 'passed'
#     2b 'FAIL', 'Failure', 'error'
#     2c 'blocked_read_only', 'FAIL_BLOCKED_X', '[BLOCK]', 'read-only'
#     2d 'needs-data', 'requires_data', 'incomplete', 'missing_inputs'
#
#   Section 3 — line-level grammar
#     3a ASCII colon
#     3b CJK fullwidth colon （：）
#     3c bullet `-`
#     3d bullet `*`
#     3e no bullet
#     3f bold markers around value
#     3g backticked value
#     3h trailing comment after value
#     3i bold markers around label
#     3j backticks around label
#
#   Section 4 — last-occurrence wins
#     4a multiple result: lines, the LAST one is authoritative
#
#   Section 5 — fence isolation
#     5a result: inside ```json fence is ignored
#     5b result: inside <<<TASK_CONSTITUTION_JSON_BEGIN>>> fence is ignored
#     5c result: outside fences after fenced ones still wins
#     5d result: inside YAML handoff fence is accepted as compatibility fallback
#     5e result: inside non-handoff YAML fence remains ignored
#
#   Section 6 — failure modes
#     6a no result: line at all → state=unknown
#     6b unparseable value → state=unknown
#     6c missing file → state=unknown
#
#   Section 7 — CLI integration
#     7a step_runtime parse-step-result emits state=, raw_value=,
#        line_number=, reason= as separate stdout lines
#     7b CLI exit 0 even when state=unknown (shell branches on value)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
PARSER_PY="${REPO_ROOT}/engine/ai_step_result_parser.py"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"

[ -f "${PARSER_PY}" ] || { echo "FAIL: ai_step_result_parser.py missing"; exit 1; }
[ -f "${STEP_PY}" ]   || { echo "FAIL: step_runtime.py missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-step-result-test.XXXXXX)"
SANDBOX="$(cd "${SANDBOX}" && pwd -P)"
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

# Helper: write fixture file and call parser, returning the state.
state_for() {
  local fixture_name="$1" content="$2"
  local fixture="${SANDBOX}/${fixture_name}.md"
  printf '%s' "${content}" > "${fixture}"
  PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${fixture}" <<'PY'
import sys
sys.path.insert(0, ".")
from engine.ai_step_result_parser import parse_step_result
print(parse_step_result(sys.argv[1])["state"])
PY
}

# ── Section 1: primary spellings ────────────────────────────────────
echo "Section 1: primary spellings of each enum value"
assert_eq "1a success" "success" "$(state_for s1a 'result: success')"
assert_eq "1b failed"  "failed"  "$(state_for s1b 'result: failed')"
assert_eq "1c blocked" "blocked" "$(state_for s1c 'result: blocked')"
assert_eq "1d needs_data" "needs_data" "$(state_for s1d 'result: needs_data')"

# ── Section 2: alias normalization ──────────────────────────────────
echo ""
echo "Section 2: alias normalization"
assert_eq "2a-OK"        "success" "$(state_for s2a1 'result: OK')"
assert_eq "2a-成功"      "success" "$(state_for s2a2 'result: 成功')"
assert_eq "2a-completed" "success" "$(state_for s2a3 'result: completed')"
assert_eq "2a-done"      "success" "$(state_for s2a4 'result: done')"
assert_eq "2a-pass"      "success" "$(state_for s2a5 'result: pass')"
assert_eq "2a-passed"    "success" "$(state_for s2a6 'result: passed')"

assert_eq "2b-FAIL"     "failed" "$(state_for s2b1 'result: FAIL')"
assert_eq "2b-Failure"  "failed" "$(state_for s2b2 'result: Failure')"
assert_eq "2b-error"    "failed" "$(state_for s2b3 'result: error')"

assert_eq "2c-blocked_read_only"   "blocked" "$(state_for s2c1 'result: blocked_read_only')"
assert_eq "2c-FAIL_BLOCKED_*"      "blocked" "$(state_for s2c2 'result: FAIL_BLOCKED_READ_ONLY_UPSTREAM_IMPLEMENTATION_MISSING')"
assert_eq "2c-[BLOCK]"             "blocked" "$(state_for s2c3 'result: [BLOCK]')"
assert_eq "2c-read-only"           "blocked" "$(state_for s2c4 'result: read-only')"

assert_eq "2d-needs-data"          "needs_data" "$(state_for s2d1 'result: needs-data')"
assert_eq "2d-requires_data"       "needs_data" "$(state_for s2d2 'result: requires_data')"
assert_eq "2d-incomplete"          "needs_data" "$(state_for s2d3 'result: incomplete')"
assert_eq "2d-missing_inputs"      "needs_data" "$(state_for s2d4 'result: missing_inputs')"

# ── Section 3: line-level grammar ──────────────────────────────────
echo ""
echo "Section 3: line-level grammar (colon styles, bullets, decoration)"
assert_eq "3a-ASCII-colon"   "success" "$(state_for s3a 'result: success')"
assert_eq "3b-fullwidth-colon" "success" "$(state_for s3b 'result：success')"
assert_eq "3c-dash-bullet"   "success" "$(state_for s3c '- result: success')"
assert_eq "3d-star-bullet"   "success" "$(state_for s3d '* result: success')"
assert_eq "3e-no-bullet"     "success" "$(state_for s3e 'result: success')"
assert_eq "3f-bold-value"    "success" "$(state_for s3f '- result: **success**')"
# Use printf with explicit ASCII so the test file has literal backticks
# (single-quoted bash strings don't expand backslash escapes; the
# shell-friendly way is to write the file directly).
backtick_fixture="${SANDBOX}/s3g.md"
printf 'result: `success`\n' > "${backtick_fixture}"
state_3g="$(PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${backtick_fixture}" <<'PY'
import sys
sys.path.insert(0, ".")
from engine.ai_step_result_parser import parse_step_result
print(parse_step_result(sys.argv[1])["state"])
PY
)"
assert_eq "3g-backticked"    "success" "${state_3g}"
assert_eq "3h-trailing-comment" "success" "$(state_for s3h 'result: success (auto-generated)')"
assert_eq "3i-bold-label"    "success" "$(state_for s3i '- **result**: 成功')"
assert_eq "3j-backticked-label" "success" "$(state_for s3j '- `result`: success')"

# ── Section 4: last occurrence wins ────────────────────────────────
echo ""
echo "Section 4: last result: occurrence wins"
multiline_content='## reasoning
upstream report has result: failed (we noted but proceeded after fix).

## handoff
- agent_id: 05-Backend
- result: success
'
assert_eq "4a-last-occurrence-wins" "success" "$(state_for s4a "${multiline_content}")"

# ── Section 5: fence isolation ─────────────────────────────────────
echo ""
echo "Section 5: result: inside JSON / code fences is ignored"
fence_json='## intro

```json
{"upstream": {"result": "failed"}}
```

## handoff
- result: success
'
assert_eq "5a-json-fence-ignored" "success" "$(state_for s5a "${fence_json}")"

fence_constitution='## body
<<<TASK_CONSTITUTION_JSON_BEGIN>>>
{"task_id": "x", "result": "blocked"}
<<<TASK_CONSTITUTION_JSON_END>>>

## handoff
- result: success
'
assert_eq "5b-constitution-fence-ignored" "success" "$(state_for s5b "${fence_constitution}")"

# Fenced first, then a real outside-fence result line — outside wins.
fence_then_real='## body
```
result: blocked
```

result: success
'
assert_eq "5c-outside-fence-wins" "success" "$(state_for s5c "${fence_then_real}")"

yaml_handoff_fence='## work summary
files were written.

## 交接摘要

```yaml
agent_id: 05-Backend
task_summary: implemented backend
result: success
```
'
assert_eq "5d-yaml-handoff-fence-fallback" "success" "$(state_for s5d "${yaml_handoff_fence}")"

yaml_non_handoff_fence='## body

```yaml
agent_id: 05-Backend
result: success
```
'
assert_eq "5e-non-handoff-yaml-fence-ignored" "unknown" "$(state_for s5e "${yaml_non_handoff_fence}")"

# ── Section 6: failure modes ───────────────────────────────────────
echo ""
echo "Section 6: failure modes (no line / unparseable / missing file)"
assert_eq "6a-no-result-line" "unknown" \
  "$(state_for s6a '## summary

just a normal markdown body without any result key.
')"

assert_eq "6b-unparseable-value" "unknown" \
  "$(state_for s6b 'result: archive_completed_stdout_closed_with_blockers')"

# Missing file path
missing_state="$(PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" -c '
import sys
sys.path.insert(0, ".")
from engine.ai_step_result_parser import parse_step_result
print(parse_step_result("/nonexistent/path/output.md")["state"])
')"
assert_eq "6c-missing-file" "unknown" "${missing_state}"

# ── Section 7: CLI integration ─────────────────────────────────────
echo ""
echo "Section 7: step_runtime parse-step-result CLI"
cli_fixture="${SANDBOX}/cli.md"
printf 'header\n- result: blocked_read_only\n' > "${cli_fixture}"
cli_out="$(${PYTHON_BIN} "${STEP_PY}" parse-step-result "${cli_fixture}" 2>&1)"
cli_state="$(echo "${cli_out}" | grep -oE '^state=[a-z_]+' | head -1 | cut -d= -f2)"
cli_raw="$(echo "${cli_out}" | grep -oE '^raw_value=[^ ]+' | head -1 | cut -d= -f2)"
cli_line="$(echo "${cli_out}" | grep -oE '^line_number=[0-9]+' | head -1 | cut -d= -f2)"
assert_eq "7a-CLI-state"      "blocked"          "${cli_state}"
assert_eq "7a-CLI-raw_value"  "blocked_read_only" "${cli_raw}"
assert_eq "7a-CLI-line"       "2"                "${cli_line}"

# Even when state=unknown, exit 0 (shell branches on value, not rc).
unknown_fixture="${SANDBOX}/unknown.md"
printf 'no result line here\n' > "${unknown_fixture}"
${PYTHON_BIN} "${STEP_PY}" parse-step-result "${unknown_fixture}" >/dev/null 2>&1
assert_eq "7b-CLI-exit-0-on-unknown" "0" "$?"

echo ""
total=$((pass_count + fail_count))
echo "ai-step-result-parser: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
