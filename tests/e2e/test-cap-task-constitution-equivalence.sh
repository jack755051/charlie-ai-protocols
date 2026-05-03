#!/usr/bin/env bash
#
# test-cap-task-constitution-equivalence.sh — Deterministic e2e proving
# `cap task constitution "<prompt>"` and
# `CAP_DEPRECATION_SILENT=1 cap workflow constitution "<prompt>"` are
# behaviourally equivalent (P2 #8 release gate).
#
# What we cover (1 setup + 4 invocation comparisons / 8+ assertions):
#   1. Both entries succeed (exit 0).
#   2. Stdout outside the timestamp-bearing `stored:` block is byte-equal.
#      The `stored:` block contains stamp-suffixed snapshot paths that
#      change per second, so we strip those two lines before the diff and
#      then assert byte equality on what remains.
#   3. The deterministic JSON dict printed under `raw_json:` is identical.
#      We extract everything after the `raw_json:` marker and compare as
#      canonical (sorted-key, separator-stable) JSON for an extra-strong
#      guarantee that the alias is a transparent rename.
#   4. The legacy entry emits the deprecation banner unless
#      CAP_DEPRECATION_SILENT=1 is set, and the alias never emits it.
#
# Why this is deterministic without AI:
#   `cap workflow constitution` (and therefore the alias) routes through
#   engine/workflow_cli.py:cmd_constitution_json →
#   engine/task_scoped_compiler.build_task_constitution. That function is
#   pure: it derives task_id from a SHA-1 of the request and then maps
#   tokens through fixed dictionaries. No model call, no clock reads in
#   the constitution dict body — only `stored:` paths embed a stamp.
#
# Why we do not skip on missing `cap` binary:
#   We invoke `scripts/cap-workflow.sh` and `scripts/cap-task.sh` directly.
#   Both ship in this repo and run under any system bash; no installer
#   step required.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CAP_TASK="${REPO_ROOT}/scripts/cap-task.sh"
CAP_WORKFLOW="${REPO_ROOT}/scripts/cap-workflow.sh"

[ -x "${CAP_TASK}" ]     || { echo "FAIL: ${CAP_TASK} not executable"; exit 1; }
[ -x "${CAP_WORKFLOW}" ] || { echo "FAIL: ${CAP_WORKFLOW} not executable"; exit 1; }

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

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if ! printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc} (forbidden substring present)"
    echo "    forbidden: ${needle}"
    fail_count=$((fail_count + 1))
  fi
}

# Strip the only two non-deterministic lines from stdout so byte-equality
# becomes a meaningful check. The `stored:` block looks like:
#
#   stored:
#     - json: <CAP_HOME>/.../constitutions/<task>/constitution-<stamp>.json
#     - markdown: <CAP_HOME>/.../constitutions/<task>/constitution-<stamp>.md
#
# Both paths embed a wall-clock stamp issued by
# engine/workflow_cli.py:cmd_persist_constitution, so two back-to-back
# invocations differ there even when the constitution dict is identical.
strip_stored_block() {
  # Drop the literal `stored:` header and its two indented continuation
  # lines (json/markdown paths). Anything else stays byte-for-byte.
  awk '
    BEGIN { in_stored = 0 }
    /^stored:[[:space:]]*$/ { in_stored = 1; next }
    in_stored == 1 && /^  - (json|markdown):/ { next }
    in_stored == 1 { in_stored = 0 }
    { print }
  '
}

# Extract everything after the literal `raw_json:` marker — that is the
# canonical task constitution body, deterministic by construction.
extract_raw_json() {
  awk '
    /^raw_json:[[:space:]]*$/ { take = 1; next }
    take == 1 { print }
  '
}

PROMPT="P2 #8 equivalence smoke prompt: minimal CLI utility"

# ── Setup ───────────────────────────────────────────────────────────────
SANDBOX="$(mktemp -d -t cap-test-task-eq.XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT
# Both invocations share the same CAP_HOME so they land their snapshots
# under the same project store. We do not care that the stamps differ —
# that is precisely what strip_stored_block + extract_raw_json filter.
export CAP_HOME="${SANDBOX}/cap-home"

# ── Invocation A: cap task constitution ─────────────────────────────────
A_OUT="$(mktemp)"; A_ERR="$(mktemp)"
set +e
bash "${CAP_TASK}" constitution "${PROMPT}" >"${A_OUT}" 2>"${A_ERR}"
A_RC=$?
set -e
A_STDOUT="$(cat "${A_OUT}")"
A_STDERR="$(cat "${A_ERR}")"

# ── Invocation B: legacy + silent ──────────────────────────────────────
B_OUT="$(mktemp)"; B_ERR="$(mktemp)"
set +e
CAP_DEPRECATION_SILENT=1 bash "${CAP_WORKFLOW}" constitution "${PROMPT}" \
  >"${B_OUT}" 2>"${B_ERR}"
B_RC=$?
set -e
B_STDOUT="$(cat "${B_OUT}")"
B_STDERR="$(cat "${B_ERR}")"

# ── Invocation C: legacy WITHOUT silent — must emit deprecation ────────
C_OUT="$(mktemp)"; C_ERR="$(mktemp)"
set +e
bash "${CAP_WORKFLOW}" constitution "${PROMPT}" >"${C_OUT}" 2>"${C_ERR}"
C_RC=$?
set -e
C_STDERR="$(cat "${C_ERR}")"
rm -f "${C_OUT}" "${C_ERR}"

# ── Assertions ─────────────────────────────────────────────────────────
echo "Compare exit codes"
assert_eq "task / silent-workflow exit 0" "0" "${A_RC}"
assert_eq "silent-workflow exit 0" "0" "${B_RC}"
assert_eq "task and silent-workflow exit codes match" "${A_RC}" "${B_RC}"

echo "Compare stdout with timestamped paths stripped"
A_STRIPPED="$(printf '%s' "${A_STDOUT}" | strip_stored_block)"
B_STRIPPED="$(printf '%s' "${B_STDOUT}" | strip_stored_block)"
if [ "${A_STRIPPED}" = "${B_STRIPPED}" ]; then
  echo "  PASS: byte-equal stdout outside stored: block"
  pass_count=$((pass_count + 1))
else
  echo "  FAIL: byte-equal stdout outside stored: block"
  echo "    diff (cap task < / cap workflow >):"
  diff <(printf '%s' "${A_STRIPPED}") <(printf '%s' "${B_STRIPPED}") | head -30
  fail_count=$((fail_count + 1))
fi

echo "Compare canonical JSON body under raw_json:"
A_JSON="$(printf '%s' "${A_STDOUT}" | extract_raw_json)"
B_JSON="$(printf '%s' "${B_STDOUT}" | extract_raw_json)"
A_CANON="$(printf '%s' "${A_JSON}" | python3 -c '
import json, sys
print(json.dumps(json.loads(sys.stdin.read()), sort_keys=True, separators=(",", ":")))
')"
B_CANON="$(printf '%s' "${B_JSON}" | python3 -c '
import json, sys
print(json.dumps(json.loads(sys.stdin.read()), sort_keys=True, separators=(",", ":")))
')"
assert_eq "canonical raw_json equal" "${A_CANON}" "${B_CANON}"
# Sanity: the body must include the deterministic SHA-1-derived task_id.
assert_contains "raw_json carries task_id (deterministic)" '"task_id"' "${A_CANON}"

echo "Deprecation gating"
# A used the alias, so the wrapper exported CAP_DEPRECATION_SILENT=1; the
# legacy banner must not have leaked through.
assert_not_contains "alias path emits no deprecation banner" \
  "[deprecated] cap workflow constitution" "${A_STDERR}"
# B explicitly silenced it.
assert_not_contains "silent legacy path emits no deprecation banner" \
  "[deprecated] cap workflow constitution" "${B_STDERR}"
# C did not set the silencer, so the banner must be present.
assert_contains "noisy legacy path still emits deprecation banner" \
  "[deprecated] cap workflow constitution is deprecated" "${C_STDERR}"

rm -f "${A_OUT}" "${A_ERR}" "${B_OUT}" "${B_ERR}"

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "----------------------------------------------------------------"
echo "Summary: ${pass_count} passed, ${fail_count} failed"
echo "----------------------------------------------------------------"

[ ${fail_count} -eq 0 ]
