#!/usr/bin/env bash
#
# test-cap-help-topics.sh — P3 (help / docs discoverability) coverage.
#
# Topic-style help pages added in v0.24.5:
#   - cap help workflow   (full cap workflow subcommand index)
#   - cap help observe    (deep dive into logs / watch / inspect / ps)
#
# Plus the existing dispatcher routing edge cases:
#   - cap help <unknown>  exits 1 + lists Available
#
# Cases:
#   1. cap help workflow renders the index sections + key entries.
#   2. cap help observe renders the use-case table + state glyphs.
#   3. Unknown help topic exits 1 with Available list naming the new topics.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CAP_ENTRY="${REPO_ROOT}/scripts/cap-entry.sh"

[ -f "${CAP_ENTRY}" ] || { echo "FAIL: ${CAP_ENTRY} missing"; exit 1; }

pass_count=0
fail_count=0

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

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc} — expected '${expected}' got '${actual}'"
    fail_count=$((fail_count + 1))
  fi
}

# Case 1: cap help workflow ─────────────────────────────────────────────
echo "Case 1: cap help workflow renders index"
out_wf="$(bash "${CAP_ENTRY}" help workflow 2>&1)"
rc_wf=$?
assert_eq "1a. exit 0" "0" "${rc_wf}"
assert_contains "1b. title present" "${out_wf}" "Full subcommand index"
assert_contains "1c. usage block" "${out_wf}" "USAGE"
assert_contains "1d. shorthand documented" "${out_wf}" "shorthand for"
assert_contains "1e. discover section" "${out_wf}" "[Discover]"
assert_contains "1f. run section" "${out_wf}" "[Run]"
assert_contains "1g. observe section" "${out_wf}" "[Observe]"
assert_contains "1h. constitution section" "${out_wf}" "[Constitution / Task]"
assert_contains "1i. lists workflow run" "${out_wf}" "cap workflow run <id>"
assert_contains "1j. lists workflow run-task" "${out_wf}" "cap workflow run-task"
assert_contains "1k. lists workflow logs" "${out_wf}" "cap workflow logs"
assert_contains "1l. lists workflow watch" "${out_wf}" "cap workflow watch"
assert_contains "1m. lists workflow inspect" "${out_wf}" "cap workflow inspect"
assert_contains "1n. cross-links cap help observe" "${out_wf}" "cap help observe"
assert_contains "1o. cross-links architecture doc" "${out_wf}" "ARCHITECTURE.md"
assert_contains "1p. cross-links observability guide" "${out_wf}" "RUN-OBSERVABILITY-GUIDE.md"

# Also accept the alias "cap help wf" as a synonym (matches cap wf alias).
out_wf_alias="$(bash "${CAP_ENTRY}" help wf 2>&1)"
rc_wf_alias=$?
assert_eq "1q. cap help wf exit 0" "0" "${rc_wf_alias}"
assert_contains "1r. cap help wf renders same topic" "${out_wf_alias}" "Full subcommand index"

# Case 2: cap help observe ──────────────────────────────────────────────
echo "Case 2: cap help observe renders use-case table"
out_obs="$(bash "${CAP_ENTRY}" help observe 2>&1)"
rc_obs=$?
assert_eq "2a. exit 0" "0" "${rc_obs}"
assert_contains "2b. title present" "${out_obs}" "observability"
assert_contains "2c. read-only banner" "${out_obs}" "read-only views"
assert_contains "2d. when-to-use header" "${out_obs}" "When to use which surface"
assert_contains "2e. lists logs full stream" "${out_obs}" "cap workflow logs <run-id>"
assert_contains "2f. lists logs follow" "${out_obs}" "cap workflow logs -f <run-id>"
assert_contains "2g. lists logs --tail" "${out_obs}" "cap workflow logs --tail N <run-id>"
assert_contains "2h. lists logs --step" "${out_obs}" "cap workflow logs <run-id> --step <step-id>"
assert_contains "2i. lists watch live" "${out_obs}" "cap workflow watch <run-id>"
assert_contains "2j. lists watch --once" "${out_obs}" "cap workflow watch --once <run-id>"
assert_contains "2k. lists watch --compact" "${out_obs}" "cap workflow watch --compact <run-id>"
assert_contains "2l. lists watch --json" "${out_obs}" "cap workflow watch --json <run-id>"
assert_contains "2m. lists inspect" "${out_obs}" "cap workflow inspect <run-id>"
assert_contains "2n. lists ps" "${out_obs}" "cap workflow ps"
assert_contains "2o. mentions --cap-home for cross-repo" "${out_obs}" "--cap-home PATH"
assert_contains "2p. state glyph table" "${out_obs}" "State glyphs"
assert_contains "2q. fallback chain table" "${out_obs}" "Step-output fallback chain"
assert_contains "2r. boundary disclaimer" "${out_obs}" "Pure read-only"
assert_contains "2s. zero token cost" "${out_obs}" "no token cost"
assert_contains "2t. cross-links guide" "${out_obs}" "RUN-OBSERVABILITY-GUIDE.md"

# Accept alias "observability" as synonym
out_obs_alias="$(bash "${CAP_ENTRY}" help observability 2>&1)"
rc_obs_alias=$?
assert_eq "2u. cap help observability exit 0" "0" "${rc_obs_alias}"
assert_contains "2v. observability alias renders same topic" "${out_obs_alias}" "When to use which surface"

# Case 3: unknown help topic ────────────────────────────────────────────
echo "Case 3: unknown help topic exits 1 + lists topics"
out_bad="$(bash "${CAP_ENTRY}" help garbage-topic 2>&1)"
rc_bad=$?
assert_eq "3a. exit 1 on unknown topic" "1" "${rc_bad}"
assert_contains "3b. names rejected topic" "${out_bad}" "Unknown help option: garbage-topic"
assert_contains "3c. lists Available with new topics" "${out_bad}" "cap help workflow | cap help observe"

echo ""
total=$((pass_count + fail_count))
echo "cap-help-topics: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
