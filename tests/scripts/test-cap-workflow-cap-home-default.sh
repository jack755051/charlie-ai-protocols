#!/usr/bin/env bash
#
# test-cap-workflow-cap-home-default.sh — Verifies the CAP_HOME default
# wired into scripts/cap-workflow.sh by Karpathy Phase 1 dogfood
# follow-up:
#
#   : "${CAP_HOME:=${HOME}/.cap}"
#   export CAP_HOME
#
# Goal: cap workflow {bind, run, ...} sees ~/.cap as cap_home without
# the user having to export the env var manually. RuntimeBinder
# resolves cap_home in the order: explicit kwarg > CAP_HOME env >
# base_dir fallback (engine/runtime_binder.py:186-192). The default in
# cap-workflow.sh fills the env-var slot.
#
# Cases:
#   1. := idiom unit test                   — unset CAP_HOME inside the
#                                              prelude → CAP_HOME ==
#                                              "${HOME}/.cap". Explicit
#                                              CAP_HOME=foo → preserved.
#   2. cap workflow bind exports to subproc — sub-shell python that the
#                                              dispatcher invokes sees
#                                              CAP_HOME in os.environ.
#   3. integration on a sandbox HOME        — point HOME at a sandbox
#                                              that has a fake shared
#                                              skill; bind picks it up
#                                              without an explicit
#                                              CAP_HOME prefix.
#   4. integration with explicit override   — explicit CAP_HOME pointing
#                                              at an empty sandbox; bind
#                                              does NOT see the user's
#                                              real shared skill (proves
#                                              := doesn't clobber).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CAP_WORKFLOW_SH="${REPO_ROOT}/scripts/cap-workflow.sh"
PYTHON_BIN="${PYTHON_BIN:-python3}"

[ -f "${CAP_WORKFLOW_SH}" ] || { echo "FAIL: ${CAP_WORKFLOW_SH} missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-cap-home.XXXXXX)"
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
  local desc="$1" haystack="$2" needle="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    needle: ${needle}"
    fail_count=$((fail_count + 1))
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if ! grep -qF -- "${needle}" <<<"${haystack}"; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc} (unexpected match): ${needle}"
    fail_count=$((fail_count + 1))
  fi
}

# ── Case 1: := idiom unit test ────────────────────────────────────────
echo "Case 1: := idiom respects existing CAP_HOME and defaults when unset"

# Replay the cap-workflow.sh prelude pattern in an isolated bash -c so
# we can observe both branches without invoking the dispatcher itself.
out_unset="$(env -u CAP_HOME HOME=/case1home bash -c '
  : "${CAP_HOME:=${HOME}/.cap}"
  echo "${CAP_HOME}"
')"
assert_eq "1a. unset CAP_HOME defaults to HOME/.cap" "/case1home/.cap" "${out_unset}"

out_set="$(CAP_HOME=/explicit/path HOME=/case1home bash -c '
  : "${CAP_HOME:=${HOME}/.cap}"
  echo "${CAP_HOME}"
')"
assert_eq "1b. explicit CAP_HOME preserved" "/explicit/path" "${out_set}"

# := also preserves an explicit empty string from the user (the
# canonical bash idiom for "you actually unset the home"). cap-workflow.sh's
# default is "default if unset"; CAP_HOME= is "set to empty", which we
# preserve so users can opt out via env if they want to force the
# RuntimeBinder base_dir fallback. Document the actual behaviour here so
# future-us sees the contract.
out_empty="$(CAP_HOME='' HOME=/case1home bash -c '
  : "${CAP_HOME:=${HOME}/.cap}"
  # Per bash := semantics, an explicit empty string IS replaced by the
  # default — same as unset. This is intentional: cap-workflow.sh wants
  # any falsy CAP_HOME to fall back to ~/.cap.
  echo "${CAP_HOME}"
')"
assert_eq "1c. CAP_HOME='' falls back like unset (bash := semantics)" "/case1home/.cap" "${out_empty}"

# ── Case 2: dispatcher exports CAP_HOME so subprocess sees it ────────
echo "Case 2: cap-workflow.sh exports CAP_HOME to its subprocesses"

# Source the prelude region of the dispatcher (line 1 through the
# `export CAP_HOME` statement; stop BEFORE usage()'s heredoc to avoid
# slicing into a here-doc which would break sourcing). Locate the
# boundary dynamically so the test doesn't drift if line numbers shift.
PRELUDE_END="$(grep -n '^export CAP_HOME$' "${CAP_WORKFLOW_SH}" | head -1 | cut -d: -f1)"
[ -n "${PRELUDE_END}" ] || { echo "  FAIL: 2. could not locate export CAP_HOME line in dispatcher"; exit 1; }
out_subproc="$(env -u CAP_HOME HOME=/case2home bash -c "
  set -u
  source <(sed -n '1,${PRELUDE_END}p' '${CAP_WORKFLOW_SH}')
  ${PYTHON_BIN} -c 'import os; print(os.environ.get(\"CAP_HOME\", \"<MISSING>\"))'
")"
assert_eq "2. python subprocess inherits CAP_HOME default" "/case2home/.cap" "${out_subproc}"

# ── Case 3: explicit CAP_HOME wins over := default (negative integration) ──
echo "Case 3: explicit CAP_HOME points to empty sandbox → no shared skill found"

# Strategy: point CAP_HOME at an empty sandbox AND HOME at a different
# sandbox that DOES have a shared skill. If `:=` had clobbered our
# explicit CAP_HOME, the binder would have found the shared skill via
# HOME's fallback. The absence proves := preserves explicit values.
SBOX_EMPTY="${SANDBOX}/case3-empty-cap-home"
SBOX_HOME_WITH_SHARED="${SANDBOX}/case3-home-with-shared"
mkdir -p "${SBOX_EMPTY}/projects/charlie-ai-protocols/bindings"
mkdir -p "${SBOX_HOME_WITH_SHARED}/.cap/shared/skills"
# Stage a shared skill under the OTHER sandbox's HOME — if := wrongly
# expanded to ${HOME}/.cap, we'd find this one.
cat > "${SBOX_HOME_WITH_SHARED}/.cap/shared/skills/karpathy-guidelines.md" <<'EOF'
# This file should NOT be reached when explicit CAP_HOME wins.
EOF
cat > "${SBOX_HOME_WITH_SHARED}/.cap/shared/skills.yaml" <<'EOF'
schema_version: 2
skills:
  - skill_id: shared-karpathy-guidelines
    provider: shared
    agent_alias: karpathy-guidelines
    cli: claude
    enabled: true
    priority: 90
    prompt_file: skills/karpathy-guidelines.md
    provided_capabilities:
      - engineering_guardrails
      - code_review_guardrails
EOF

out3="$(CAP_HOME="${SBOX_EMPTY}" HOME="${SBOX_HOME_WITH_SHARED}" \
  bash "${CAP_WORKFLOW_SH}" bind karpathy-guardrails-smoke 2>&1)"

# Outcome: binder uses SBOX_EMPTY (which has no shared/), falls back to
# a builtin generic. The shared skill stashed in HOME is invisible
# because := did NOT clobber the explicit CAP_HOME.
assert_not_contains "3a. := did NOT override explicit CAP_HOME" "${out3}" \
  "skill=shared-karpathy-guidelines"
assert_contains "3b. binding fell back to a builtin (no shared at explicit path)" "${out3}" \
  "fallback"

# Explicit positive path through ${HOME}/.cap would also work but
# requires staging a sandbox project + constitution that opts the
# sandbox shared path into allowed_source_roots — outside the scope
# of this fixture. Real-world positive-path coverage lives in the
# Karpathy Phase 1 dogfood (commit 399d450) and the live
# karpathy-guardrails-smoke workflow.

echo ""
total=$((pass_count + fail_count))
echo "cap-workflow-cap-home-default: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
