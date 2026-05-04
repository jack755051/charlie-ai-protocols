#!/usr/bin/env bash
#
# test-shell-prompt-snapshot.sh — gate for the production shell
# executor's prompt snapshot / hash wiring (cap-workflow-exec.sh
# write_prompt_snapshot helper + step_runtime upsert-session
# --prompt-hash / --prompt-snapshot-path / --prompt-size-bytes flags).
#
# Goal: close the observability gap revealed by `cap session analyze`
# on the real ledger (largest_prompts / duplicate_prompts both empty
# because production runs go through scripts/cap-workflow-exec.sh,
# not through engine.agent_session_runner). We test the helpers in
# isolation here — running cap-workflow-exec.sh end-to-end would
# spawn a real provider and is out of scope.
#
# Coverage:
#   Case 1 helper output shape:   write_prompt_snapshot echoes
#                                 'hash|path|size' for a known prompt.
#   Case 2 sha256 correctness:    hash matches python's sha256 of the
#                                 same byte string.
#   Case 3 path layout:           snapshot lands at
#                                 <base>/prompts/<hash[:2]>/<hash>.txt
#                                 with the prompt content.
#   Case 4 dedupe idempotency:    two calls with identical prompt return
#                                 the same path and don't overwrite.
#   Case 5 distinct prompts:      different prompts produce distinct
#                                 paths (no collision).
#   Case 6 step_runtime CLI flags: upsert-session with the three new
#                                  --prompt-* flags persists the fields
#                                  to agent-sessions.json.
#   Case 7 legacy 18-positional:  upsert-session called without the new
#                                 flags still writes a ledger entry
#                                 (back-compat preserved).
#   Case 8 analyzer surfaces data: a fixture ledger built with
#                                  prompt_hash / prompt_size_bytes
#                                  populates largest_prompts and
#                                  duplicate_prompts in `cap session
#                                  analyze --json`.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

[ -f "${REPO_ROOT}/scripts/cap-workflow-exec.sh" ] || {
  echo "FAIL: scripts/cap-workflow-exec.sh missing"; exit 1;
}
[ -f "${REPO_ROOT}/engine/step_runtime.py" ] || {
  echo "FAIL: engine/step_runtime.py missing"; exit 1;
}

SANDBOX="$(mktemp -d -t cap-shell-snapshot-test.XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

PYTHON_BIN="python3"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"

pass_count=0
fail_count=0

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

# Source write_prompt_snapshot from cap-workflow-exec.sh (extract just
# the helper definition so we don't run the whole script).
HELPER_SRC="${SANDBOX}/helper.sh"
sed -n '/^write_prompt_snapshot()/,/^}$/p' "${REPO_ROOT}/scripts/cap-workflow-exec.sh" > "${HELPER_SRC}"
[ -s "${HELPER_SRC}" ] || { echo "FAIL: could not extract write_prompt_snapshot"; exit 1; }

run_helper() {
  local prompt="$1" base_dir="$2"
  bash -c "
    source '${HELPER_SRC}'
    write_prompt_snapshot '${prompt}' '${base_dir}'
  "
}

# ── Case 1 ──────────────────────────────────────────────────────────────
echo "Case 1: write_prompt_snapshot echoes hash|path|size"
PROMPT="hello world prompt"
META="$(run_helper "${PROMPT}" "${SANDBOX}")"
assert_contains "meta has pipe separators" "|" "${META}"
HASH="$(printf '%s' "${META}" | cut -d'|' -f1)"
SNAP_PATH="$(printf '%s' "${META}" | cut -d'|' -f2)"
SIZE="$(printf '%s' "${META}" | cut -d'|' -f3)"
assert_eq "hash length 64 (sha256 hex)" "64" "${#HASH}"
assert_eq "size matches byte length"     "$(printf '%s' "${PROMPT}" | wc -c | tr -d ' ')" "${SIZE}"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: hash matches python sha256 of same byte string"
PY_HASH="$(printf '%s' "${PROMPT}" | python3 -c "import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode()).hexdigest())")"
assert_eq "shell sha256 == python sha256" "${PY_HASH}" "${HASH}"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: snapshot path layout <base>/prompts/<hash[:2]>/<hash>.txt"
EXPECTED_PATH="${SANDBOX}/prompts/${HASH:0:2}/${HASH}.txt"
assert_eq "snapshot path matches layout"  "${EXPECTED_PATH}" "${SNAP_PATH}"
assert_eq "snapshot file exists"          "yes"              "$([ -f "${SNAP_PATH}" ] && echo yes || echo no)"
WRITTEN="$(cat "${SNAP_PATH}")"
assert_eq "snapshot file content matches" "${PROMPT}" "${WRITTEN}"

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: identical prompt → same path, idempotent (no rewrite)"
ORIG_MTIME="$(stat -f '%m' "${SNAP_PATH}" 2>/dev/null || stat -c '%Y' "${SNAP_PATH}" 2>/dev/null)"
sleep 1
META2="$(run_helper "${PROMPT}" "${SANDBOX}")"
SNAP_PATH2="$(printf '%s' "${META2}" | cut -d'|' -f2)"
NEW_MTIME="$(stat -f '%m' "${SNAP_PATH2}" 2>/dev/null || stat -c '%Y' "${SNAP_PATH2}" 2>/dev/null)"
assert_eq "same path on rerun"     "${SNAP_PATH}" "${SNAP_PATH2}"
assert_eq "mtime unchanged (idempotent)" "${ORIG_MTIME}" "${NEW_MTIME}"

# ── Case 5 ──────────────────────────────────────────────────────────────
echo "Case 5: distinct prompts produce distinct paths"
META3="$(run_helper "different prompt body" "${SANDBOX}")"
SNAP_PATH3="$(printf '%s' "${META3}" | cut -d'|' -f2)"
[ "${SNAP_PATH3}" != "${SNAP_PATH}" ] && echo "  PASS: distinct path" && pass_count=$((pass_count + 1)) || { echo "  FAIL: distinct prompts collided to same path"; fail_count=$((fail_count + 1)); }
SNAPSHOT_FILE_COUNT="$(find "${SANDBOX}/prompts" -type f -name '*.txt' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "two snapshot files on disk" "2" "${SNAPSHOT_FILE_COUNT}"

# ── Case 6 ──────────────────────────────────────────────────────────────
echo "Case 6: step_runtime upsert-session new --prompt-* flags persist"
SESSIONS="${SANDBOX}/agent-sessions.json"
"${PYTHON_BIN}" "${STEP_PY}" upsert-session \
  "${SESSIONS}" "r1" "wf" "WF" "sess-A" "step1" "cap_x" "alias_x" \
  "" "shell" "shell" "running" "pending" "" "" "" "" "" \
  --prompt-hash "${HASH}" --prompt-snapshot-path "${SNAP_PATH}" --prompt-size-bytes "${SIZE}"
parsed6="$(python3 -c "
import json
s = json.load(open('${SESSIONS}'))['sessions'][0]
print('hash=' + str(s.get('prompt_hash')))
print('path=' + str(s.get('prompt_snapshot_path')))
print('size=' + str(s.get('prompt_size_bytes')))
")"
assert_contains "ledger has prompt_hash"    "hash=${HASH}"          "${parsed6}"
assert_contains "ledger has snapshot_path"   "path=${SNAP_PATH}"    "${parsed6}"
assert_contains "ledger has size_bytes"      "size=${SIZE}"         "${parsed6}"

# ── Case 7 ──────────────────────────────────────────────────────────────
echo "Case 7: legacy 18-positional upsert (no new flags) still works"
LEGACY_LEDGER="${SANDBOX}/legacy-sessions.json"
"${PYTHON_BIN}" "${STEP_PY}" upsert-session \
  "${LEGACY_LEDGER}" "r1" "wf" "WF" "sess-L" "step1" "cap_x" "alias_x" \
  "" "shell" "shell" "running" "pending" "" "" "" "" ""
parsed7="$(python3 -c "
import json
data = json.load(open('${LEGACY_LEDGER}'))
print('count=' + str(len(data['sessions'])))
s = data['sessions'][0]
print('legacy_id=' + s['session_id'])
print('hash_present=' + str('prompt_hash' in s))
")"
assert_contains "legacy ledger has 1 session"   "count=1"           "${parsed7}"
assert_contains "legacy session id preserved"   "legacy_id=sess-L"  "${parsed7}"
assert_contains "no prompt_hash field written"  "hash_present=False" "${parsed7}"

# ── Case 8 ──────────────────────────────────────────────────────────────
echo "Case 8: cap session analyze surfaces largest_prompts + duplicate_prompts"
ANALYZER_LEDGER="${SANDBOX}/analyzer-sessions.json"
cat > "${ANALYZER_LEDGER}" <<EOF
{
  "sessions": [
    {"session_id":"sA","run_id":"r","workflow_id":"wf","step_id":"s1","capability":"cap_x",
     "lifecycle":"completed","result":"passed","provider":"shell","provider_cli":"shell","executor":"shell",
     "duration_seconds":1,"prompt_hash":"${HASH}","prompt_snapshot_path":"${SNAP_PATH}","prompt_size_bytes":${SIZE}},
    {"session_id":"sB","run_id":"r","workflow_id":"wf","step_id":"s2","capability":"cap_x",
     "lifecycle":"completed","result":"passed","provider":"shell","provider_cli":"shell","executor":"shell",
     "duration_seconds":1,"prompt_hash":"${HASH}","prompt_snapshot_path":"${SNAP_PATH}","prompt_size_bytes":${SIZE}}
  ]
}
EOF
ANALYZE_OUT="$(bash "${REPO_ROOT}/scripts/cap-session.sh" analyze --sessions-path "${ANALYZER_LEDGER}" --json 2>&1)"
parsed8="$(printf '%s' "${ANALYZE_OUT}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('largest_count=' + str(len(d['largest_prompts'])))
print('largest_top_size=' + str(d['largest_prompts'][0]['prompt_size_bytes']))
print('duplicate_count=' + str(len(d['duplicate_prompts'])))
print('duplicate_occ=' + str(d['duplicate_prompts'][0]['occurrences']))
")"
assert_contains "analyzer largest_prompts non-empty" "largest_count=2"       "${parsed8}"
assert_contains "analyzer top size matches"           "largest_top_size=${SIZE}" "${parsed8}"
assert_contains "analyzer duplicate detected"         "duplicate_count=1"     "${parsed8}"
assert_contains "duplicate occurrence count = 2"      "duplicate_occ=2"       "${parsed8}"

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "shell-prompt-snapshot: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
