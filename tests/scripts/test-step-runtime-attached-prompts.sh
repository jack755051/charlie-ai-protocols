#!/usr/bin/env bash
#
# test-step-runtime-attached-prompts.sh — Phase 5 step_runtime
# attached-prompts subcommand contract.
#
# Coverage:
#   Case 1: a step with two attached_skills emits two TSV lines, in
#           input order (the binder is the SSOT for ordering; this
#           subcommand must not reorder).
#   Case 2: a step with no attached_skills emits empty stdout.
#   Case 3: an unknown step_id emits empty stdout (the dispatcher
#           treats this as a no-op — flatten-steps is the
#           authoritative listing of step ids).
#   Case 4: tabs in input fields are sanitized into spaces so the
#           consumer's IFS=$'\t' read stays robust.
#   Case 5: flatten-steps trailing 23rd field (attached_count) is
#           an integer matching len(attached_skills).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"

[ -f "${STEP_PY}" ] || { echo "FAIL: step_runtime.py missing"; exit 1; }

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

# Plan with one step that has two attachments.
PLAN_TWO='{
  "phases": [
    {
      "phase": 1,
      "steps": [
        {
          "step_id": "implement",
          "phase": 1,
          "capability": "frontend_implementation",
          "agent_alias": "frontend",
          "prompt_file": "agent-skills/04-frontend-agent.md",
          "cli": "claude",
          "attached_skills": [
            {"skill_id": "shared-karpathy", "prompt_file": "agent-skills/strategies/karpathy-guidelines.md", "attach_reason": "attach_to_capabilities"},
            {"skill_id": "shared-second", "prompt_file": "agent-skills/strategies/second.md", "attach_reason": "attach_to_roles"}
          ]
        }
      ]
    }
  ]
}'

# Plan with one step that has no attachments.
PLAN_NONE='{
  "phases": [
    {
      "phase": 1,
      "steps": [
        {
          "step_id": "draft",
          "phase": 1,
          "capability": "drafting",
          "agent_alias": "supervisor",
          "prompt_file": "agent-skills/01-supervisor-agent.md",
          "cli": "claude"
        }
      ]
    }
  ]
}'

# Plan with tabs in attached prompt_file path (should be sanitized).
PLAN_TABS='{
  "phases": [
    {
      "phase": 1,
      "steps": [
        {
          "step_id": "implement",
          "phase": 1,
          "capability": "frontend_implementation",
          "agent_alias": "frontend",
          "prompt_file": "agent-skills/04-frontend-agent.md",
          "cli": "claude",
          "attached_skills": [
            {"skill_id": "shared\tnasty", "prompt_file": "skills/path\twith\ttabs.md", "attach_reason": "attach_to_capabilities"}
          ]
        }
      ]
    }
  ]
}'

# ── Case 1: two attachments emit two TSV lines, order preserved ─────
echo "Case 1: two attachments → two TSV lines in input order"
out1="$("${PYTHON_BIN}" "${STEP_PY}" attached-prompts "${PLAN_TWO}" implement)"
line_count="$(printf '%s' "${out1}" | grep -c '^.')"
assert_eq "1a. line count" "2" "${line_count}"
first_line="$(printf '%s\n' "${out1}" | sed -n '1p')"
second_line="$(printf '%s\n' "${out1}" | sed -n '2p')"
assert_eq "1b. first line is karpathy / attach_to_capabilities" \
  "agent-skills/strategies/karpathy-guidelines.md	shared-karpathy	attach_to_capabilities" \
  "${first_line}"
assert_eq "1c. second line is second / attach_to_roles" \
  "agent-skills/strategies/second.md	shared-second	attach_to_roles" \
  "${second_line}"

# ── Case 2: no attachments emits empty stdout ───────────────────────
echo "Case 2: step without attachments → empty stdout"
out2="$("${PYTHON_BIN}" "${STEP_PY}" attached-prompts "${PLAN_NONE}" draft)"
assert_eq "2. empty output" "" "${out2}"

# ── Case 3: unknown step_id emits empty stdout ──────────────────────
echo "Case 3: unknown step_id → empty stdout"
out3="$("${PYTHON_BIN}" "${STEP_PY}" attached-prompts "${PLAN_TWO}" nonexistent_step)"
assert_eq "3. empty output for unknown step_id" "" "${out3}"

# ── Case 4: tabs in payload are sanitized to spaces ─────────────────
echo "Case 4: tabs in payload sanitized into spaces"
out4="$("${PYTHON_BIN}" "${STEP_PY}" attached-prompts "${PLAN_TABS}" implement)"
# Expect: skill_id=shared nasty, prompt_file=skills/path with tabs.md
assert_eq "4a. tab-sanitized line" \
  "skills/path with tabs.md	shared nasty	attach_to_capabilities" \
  "${out4}"

# ── Case 5: flatten-steps emits 23rd field (attached_count) ─────────
echo "Case 5: flatten-steps appends attached_count as 23rd pipe-field"
flat_two="$("${PYTHON_BIN}" "${STEP_PY}" flatten-steps "${PLAN_TWO}")"
flat_none="$("${PYTHON_BIN}" "${STEP_PY}" flatten-steps "${PLAN_NONE}")"
count_two="$(printf '%s' "${flat_two}" | awk -F'|' '{print $23}')"
count_none="$(printf '%s' "${flat_none}" | awk -F'|' '{print $23}')"
assert_eq "5a. attached_count=2 for two-attachment plan" "2" "${count_two}"
assert_eq "5b. attached_count=0 for no-attachment plan" "0" "${count_none}"
field_count_two="$(printf '%s' "${flat_two}" | awk -F'|' '{print NF}')"
assert_eq "5c. flatten-steps row has exactly 23 fields" "23" "${field_count_two}"

echo ""
total=$((pass_count + fail_count))
echo "step-runtime-attached-prompts: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
