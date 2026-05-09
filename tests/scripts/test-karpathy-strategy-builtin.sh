#!/usr/bin/env bash
#
# test-karpathy-strategy-builtin.sh — Phase 2 promote regression pin.
#
# Pins the boundary set when Karpathy guidelines were promoted from
# the shared layer (~/.cap/shared/skills/karpathy-guidelines.md) to a
# CAP builtin methodology strategy in v0.24.9. Three contracts:
#
#   1. The builtin strategy file exists at the canonical path.
#   2. Each of the seven candidate agent prompts references it.
#      (01-supervisor / 02-techlead / 04-frontend / 05-backend /
#       07-qa / 10-troubleshoot / 90-watcher)
#   3. Each of the four deliberately-excluded agent prompts does NOT
#      reference it. This is the boundary safeguard — KARPATHY-
#      GUIDELINES-INTEGRATION-MEMO Phase 2 lists these explicitly.
#      (03-ui / 09-analytics / 12-figma / 99-logger)
#
# This fixture does NOT validate strategy content (the file is
# documentation prose; semantic regression would be caught by dogfood
# runs, not a static check).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

STRATEGY_PATH="${REPO_ROOT}/agent-skills/strategies/karpathy-guidelines.md"
STRATEGY_REF_NEEDLE='agent-skills/strategies/karpathy-guidelines.md'

CANDIDATE_AGENTS=(
  01-supervisor
  02-techlead
  04-frontend
  05-backend
  07-qa
  10-troubleshoot
  90-watcher
)

# Agents intentionally NOT referencing Karpathy strategy in v0.24.9.
# memo §Phase 2 explains why (visual / analytics / asset-sync / pure
# logging are tangential to the four rules).
EXCLUDED_AGENTS=(
  03-ui
  09-analytics
  12-figma
  99-logger
)

pass_count=0
fail_count=0

assert_exists() {
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

assert_grep_present() {
  local desc="$1" pattern="$2" file="$3"
  if [ ! -f "${file}" ]; then
    echo "  FAIL: ${desc} (file missing: ${file})"
    fail_count=$((fail_count + 1))
    return
  fi
  if grep -qF -- "${pattern}" "${file}"; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    pattern: ${pattern}"
    echo "    file:    ${file}"
    fail_count=$((fail_count + 1))
  fi
}

assert_grep_absent() {
  local desc="$1" pattern="$2" file="$3"
  if [ ! -f "${file}" ]; then
    echo "  FAIL: ${desc} (file missing: ${file})"
    fail_count=$((fail_count + 1))
    return
  fi
  if grep -qF -- "${pattern}" "${file}"; then
    echo "  FAIL: ${desc} (unexpected reference)"
    echo "    pattern found in: ${file}"
    fail_count=$((fail_count + 1))
  else
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  fi
}

# ── Case 1: builtin strategy file exists ──────────────────────────────
echo "Case 1: builtin Karpathy strategy file exists"
assert_exists "1. agent-skills/strategies/karpathy-guidelines.md present" "${STRATEGY_PATH}"

# ── Case 2: 7 candidate agents reference the strategy ────────────────
echo "Case 2: 7 candidate agents reference the strategy"
for agent in "${CANDIDATE_AGENTS[@]}"; do
  file="${REPO_ROOT}/agent-skills/${agent}-agent.md"
  assert_grep_present "2.${agent}: references karpathy-guidelines.md" \
    "${STRATEGY_REF_NEEDLE}" "${file}"
done

# ── Case 3: 4 excluded agents do NOT reference the strategy ──────────
echo "Case 3: 4 excluded agents do NOT reference the strategy"
for agent in "${EXCLUDED_AGENTS[@]}"; do
  file="${REPO_ROOT}/agent-skills/${agent}-agent.md"
  assert_grep_absent "3.${agent}: does NOT reference karpathy-guidelines.md" \
    "${STRATEGY_REF_NEEDLE}" "${file}"
done

# ── Case 4: strategy file content sanity (lightweight) ────────────────
# Don't validate prose word-for-word, but pin the four rule headers so
# a refactor of the strategy must be deliberate. memo §Karpathy 4 Rules
# names these four exactly.
echo "Case 4: strategy file contains all four rule headers"
for rule in "Rule 1 — Think Before Coding" \
            "Rule 2 — Simplicity First" \
            "Rule 3 — Surgical Changes" \
            "Rule 4 — Goal-Driven Execution"; do
  assert_grep_present "4. strategy contains: ${rule}" "${rule}" "${STRATEGY_PATH}"
done

# ── Case 5: conflict resolution order documented ─────────────────────
# Phase 2 risk memo flagged that explicit kind > inference must be pinned;
# the analogous discipline at strategy level is "user > constitution >
# role > other strategies > Karpathy". Pin the priority order so a
# future refactor doesn't quietly invert it.
echo "Case 5: conflict resolution order documented in strategy"
assert_grep_present "5a. priority order names user instruction first" \
  "使用者本回合明示指令" "${STRATEGY_PATH}"
assert_grep_present "5b. priority order names Karpathy last" \
  "本 strategy（Karpathy guidelines）" "${STRATEGY_PATH}"

echo ""
total=$((pass_count + fail_count))
echo "karpathy-strategy-builtin: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
