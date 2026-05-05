#!/usr/bin/env bash
#
# test-manage-cap-alias-defaults.sh — P0b Provider Isolation gate.
#
# Verifies installer default does NOT hijack bare claude / codex.
#
# Background: prior to v0.22.x, scripts/manage-cap-alias.sh defaulted
# WRAP_NATIVE_CLI=1, which silently re-routed bare claude / codex
# through cap-entry.sh and forced the project_id resolver to fire even
# in $HOME (where no .cap.project.yaml exists). v0.22.x P0b flips the
# default to 0 — only ``cap()`` is registered; CAP-managed sessions are
# the explicit entry points ``cap claude`` / ``cap codex``. Prior
# users can still opt in with ``CAP_WRAP_NATIVE_CLI=1 make install``.
#
# Coverage:
#   Case 1 default install        →  rc has cap() only, no claude()/codex()
#   Case 2 opt-in install         →  rc has cap() + claude() + codex()
#   Case 3 cap claude routing     →  cap-entry.sh routes ``cap claude`` to
#                                    cap-session.sh:claude (CAP-managed entry
#                                    is preserved regardless of flag)
#   Case 4 cap codex routing      →  same as Case 3 for codex
#   Case 5 uninstall is symmetric →  block fully removed (idempotent
#                                    re-install)
#   Case 6 install hint           →  default install message tells the
#                                    user how to opt back in
#   Case 7 default block content  →  emitted block does not contain
#                                    ``codex()`` / ``claude()`` shell
#                                    function definitions

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ALIAS_SH="${REPO_ROOT}/scripts/manage-cap-alias.sh"
ENTRY_SH="${REPO_ROOT}/scripts/cap-entry.sh"

[ -f "${ALIAS_SH}" ] || { echo "FAIL: scripts/manage-cap-alias.sh missing"; exit 1; }
[ -f "${ENTRY_SH}" ] || { echo "FAIL: scripts/cap-entry.sh missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-alias-test.XXXXXX)"
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

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    echo "  FAIL: ${desc}"
    echo "    must NOT contain: ${needle}"
    echo "    actual head: $(printf '%s' "${haystack}" | head -3)"
    fail_count=$((fail_count + 1))
  else
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  fi
}

# ── Case 1 ──────────────────────────────────────────────────────────────
echo "Case 1: default install → rc only has cap() shell function"
RC1="${SANDBOX}/c1_zshrc"
: > "${RC1}"
out1="$(CAP_SHELL_RC="${RC1}" bash "${ALIAS_SH}" install "${REPO_ROOT}" 2>&1)"
content1="$(cat "${RC1}")"
assert_contains "cap() function present"           "cap() {"      "${content1}"
assert_not_contains "claude() function absent"     "claude() {"   "${content1}"
assert_not_contains "codex() function absent"      "codex() {"    "${content1}"
assert_contains "cap-entry.sh path written"        "cap-entry.sh" "${content1}"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: CAP_WRAP_NATIVE_CLI=1 install → rc has all three functions"
RC2="${SANDBOX}/c2_zshrc"
: > "${RC2}"
out2="$(CAP_SHELL_RC="${RC2}" CAP_WRAP_NATIVE_CLI=1 bash "${ALIAS_SH}" install "${REPO_ROOT}" 2>&1)"
content2="$(cat "${RC2}")"
assert_contains "opt-in cap() present"     "cap() {"      "${content2}"
assert_contains "opt-in claude() present"  "claude() {"   "${content2}"
assert_contains "opt-in codex() present"   "codex() {"    "${content2}"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: cap claude routes to cap-session.sh (CAP-managed entry preserved)"
out3="$(grep -nE 'claude\)' "${ENTRY_SH}" 2>&1)"
assert_contains "claude subcommand registered"  "claude)"            "${out3}"
out3b="$(grep -nE 'cap-session\.sh.+claude' "${ENTRY_SH}" 2>&1)"
assert_contains "claude routes to cap-session"   "cap-session.sh"    "${out3b}"
assert_contains "claude routes via session sh"   "claude"            "${out3b}"

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: cap codex routes to cap-session.sh (CAP-managed entry preserved)"
out4="$(grep -nE 'codex\)' "${ENTRY_SH}" 2>&1)"
assert_contains "codex subcommand registered"   "codex)"             "${out4}"
out4b="$(grep -nE 'cap-session\.sh.+codex' "${ENTRY_SH}" 2>&1)"
assert_contains "codex routes to cap-session"    "cap-session.sh"    "${out4b}"
assert_contains "codex routes via session sh"    "codex"             "${out4b}"

# ── Case 5 ──────────────────────────────────────────────────────────────
echo "Case 5: uninstall removes the entire CAP block (idempotent re-install)"
RC5="${SANDBOX}/c5_zshrc"
printf '# user line above\nexport FOO=bar\n' > "${RC5}"
CAP_SHELL_RC="${RC5}" bash "${ALIAS_SH}" install "${REPO_ROOT}" >/dev/null 2>&1
content5_pre="$(cat "${RC5}")"
assert_contains "pre-uninstall has CAP block" "CAP - Charlie AI Protocols [start]" "${content5_pre}"
CAP_SHELL_RC="${RC5}" bash "${ALIAS_SH}" uninstall "${REPO_ROOT}" >/dev/null 2>&1
content5_post="$(cat "${RC5}")"
assert_not_contains "post-uninstall block removed"        "CAP - Charlie AI Protocols [start]" "${content5_post}"
assert_not_contains "post-uninstall cap() removed"        "cap() {"                            "${content5_post}"
assert_contains "user content preserved"                  "export FOO=bar"                     "${content5_post}"

# ── Case 6 ──────────────────────────────────────────────────────────────
echo "Case 6: default install message tells user how to opt back in"
assert_contains "default hint mentions cap codex"          "cap codex"                  "${out1}"
assert_contains "default hint mentions cap claude"         "cap claude"                 "${out1}"
assert_contains "default hint mentions opt-in env"         "CAP_WRAP_NATIVE_CLI=1"      "${out1}"
assert_contains "default install confirms native isolated" "原生 provider 行為"          "${out1}"

# ── Case 7 ──────────────────────────────────────────────────────────────
echo "Case 7: default block bytes contain only cap() definition"
# Belt-and-suspenders against future templating accidents that print the
# claude()/codex() heredoc unconditionally.
block_only="$(awk '/CAP - Charlie AI Protocols \[start\]/,/CAP - Charlie AI Protocols \[end\]/' "${RC1}")"
assert_contains "block opens with [start] tag"   "[start]"           "${block_only}"
assert_contains "block closes with [end] tag"    "[end]"             "${block_only}"
assert_contains "block has cap() body"           'bash "'             "${block_only}"
assert_not_contains "block lacks claude wrapper" "cap-entry.sh claude" "${block_only}"
assert_not_contains "block lacks codex wrapper"  "cap-entry.sh codex"  "${block_only}"

echo ""
echo "manage-cap-alias-defaults: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
