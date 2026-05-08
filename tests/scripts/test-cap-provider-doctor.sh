#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CAP_PROVIDER="${REPO_ROOT}/scripts/cap-provider.sh"
CAP_ENTRY="${REPO_ROOT}/scripts/cap-entry.sh"

failures=0
checks=0

pass() {
  checks=$((checks + 1))
}

fail() {
  checks=$((checks + 1))
  failures=$((failures + 1))
  echo "FAIL: $*" >&2
}

assert_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if printf '%s' "${haystack}" | grep -Fq "${needle}"; then
    pass
  else
    fail "${label}: expected to contain '${needle}'"
    echo "  --- haystack ---" >&2
    printf '%s\n' "${haystack}" | head -10 >&2
  fi
}

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    pass
  else
    fail "${label}: expected '${expected}', got '${actual}'"
  fi
}

# ── Case 1: text mode lists both providers and resolves default cli ─────
echo "Case 1: cap provider doctor (text) reports default cli + provider rows"
OUT="$(bash "${CAP_PROVIDER}" doctor 2>&1)"
assert_contains "header present" "CAP PROVIDER DOCTOR" "${OUT}"
assert_contains "default cli line" "default cli:" "${OUT}"
assert_contains "claude row" "claude:" "${OUT}"
assert_contains "codex row" "codex:" "${OUT}"

# ── Case 2: --json emits well-formed JSON with required fields ──────────
echo "Case 2: cap provider doctor --json"
JSON="$(bash "${CAP_PROVIDER}" doctor --json 2>/dev/null)"
DEFAULT_CLI="$(printf '%s' "${JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["default_cli"])')"
case "${DEFAULT_CLI}" in
  claude|codex) pass ;;
  *) fail "default_cli must be claude or codex, got: ${DEFAULT_CLI}" ;;
esac
CLAUDE_STATUS="$(printf '%s' "${JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["providers"]["claude"]["status"])')"
case "${CLAUDE_STATUS}" in
  found|missing) pass ;;
  *) fail "claude.status must be found|missing, got: ${CLAUDE_STATUS}" ;;
esac
CODEX_STATUS="$(printf '%s' "${JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["providers"]["codex"]["status"])')"
case "${CODEX_STATUS}" in
  found|missing) pass ;;
  *) fail "codex.status must be found|missing, got: ${CODEX_STATUS}" ;;
esac

# ── Case 3: respects CAP_DEFAULT_AGENT_CLI override ─────────────────────
echo "Case 3: CAP_DEFAULT_AGENT_CLI override propagates to default_cli"
OVERRIDE_JSON="$(CAP_DEFAULT_AGENT_CLI=codex bash "${CAP_PROVIDER}" doctor --json 2>/dev/null)"
OVERRIDE_DEFAULT="$(printf '%s' "${OVERRIDE_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["default_cli"])')"
assert_eq "CAP_DEFAULT_AGENT_CLI=codex respected" "codex" "${OVERRIDE_DEFAULT}"

# ── Case 4: cap-entry routes `provider doctor` to cap-provider.sh ───────
echo "Case 4: cap-entry routes 'provider doctor' subcommand"
ENTRY_OUT="$(bash "${CAP_ENTRY}" provider doctor 2>&1)"
assert_contains "entry route header" "CAP PROVIDER DOCTOR" "${ENTRY_OUT}"

# ── Case 5: unknown provider subcommand exits non-zero ──────────────────
echo "Case 5: unknown subcommand under provider exits non-zero"
set +e
bash "${CAP_PROVIDER}" bogus 2>/dev/null
RC=$?
set -e
if [ "${RC}" -ne 0 ]; then
  pass
else
  fail "unknown subcommand should exit non-zero, got ${RC}"
fi

# ── Case 6: doctor never tries to login (no claude/codex login invocation) ─
echo "Case 6: doctor body contains no login keyword"
PROVIDER_BODY="$(cat "${CAP_PROVIDER}")"
if printf '%s' "${PROVIDER_BODY}" | grep -qE 'claude[[:space:]]+login|codex[[:space:]]+login|--login'; then
  fail "cap-provider.sh must not invoke provider login"
else
  pass
fi

# ── Summary ─────────────────────────────────────────────────────────────
PASSED=$((checks - failures))
echo "Summary: ${PASSED} passed, ${failures} failed"
[ "${failures}" -eq 0 ]
