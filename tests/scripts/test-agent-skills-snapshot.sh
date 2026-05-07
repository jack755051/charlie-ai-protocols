#!/usr/bin/env bash
#
# test-agent-skills-snapshot.sh — A0 #4 focused test.
#
# Exercises engine/agent_skills_snapshot.py:
#   * compute_snapshot determinism (same content → same dir_hash + per-file hashes).
#   * compute_snapshot detects content drift (changed file → changed hash).
#   * compute_summary projects only the compact subset (no prompt_files).
#   * attach_to_envelope is idempotent (existing baseline preserved).
#   * CLI subcommand `attach` writes a baseline into a JSON envelope file
#     and is a no-op on the second invocation.
#   * cap-workflow-exec.sh hook (verified indirectly): an empty ledger
#     stamped via `agent_skills_snapshot.py attach` gains the baseline.
#
# Reference SSOT:
#   - policies/agent-skills-baseline.md §7
#   - schemas/agent-session.schema.yaml envelope notes
#   - schemas/workflow-result.schema.yaml agent_skills_baseline
#
# Sandbox: every case builds an isolated agent-skills/ directory with
# fixed content; `--cap-root` defaults to the sandbox so cap_version /
# git_commit reads cleanly fall through to None for deterministic
# fixtures.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
SNAPSHOT_PY="${REPO_ROOT}/engine/agent_skills_snapshot.py"

[ -f "${SNAPSHOT_PY}" ] || {
  echo "FAIL: engine/agent_skills_snapshot.py missing"; exit 1;
}

SANDBOX="$(mktemp -d -t cap-agent-skills-snapshot-test.XXXXXX)"
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

assert_neq() {
  local desc="$1" lhs="$2" rhs="$3"
  if [ "${lhs}" != "${rhs}" ]; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    both values were: ${lhs}"
    fail_count=$((fail_count + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  case "${haystack}" in
    *"${needle}"*)
      echo "  PASS: ${desc}"
      pass_count=$((pass_count + 1)) ;;
    *)
      echo "  FAIL: ${desc}"
      echo "    expected substring: ${needle}"
      fail_count=$((fail_count + 1)) ;;
  esac
}

# ── Common fixture: a small agent-skills/ dir with two markdown files ─

FIXTURE_DIR="${SANDBOX}/agent-skills"
FIXTURE_CAP="${SANDBOX}/cap_root"
mkdir -p "${FIXTURE_DIR}/strategies" "${FIXTURE_CAP}"
cat > "${FIXTURE_DIR}/00-core-protocol.md" <<'EOF'
# Core Protocol fixture
EOF
cat > "${FIXTURE_DIR}/01-supervisor-agent.md" <<'EOF'
# Supervisor fixture
EOF
cat > "${FIXTURE_DIR}/strategies/tdd-vertical-slice.md" <<'EOF'
# TDD vertical slice fixture
EOF

# ── Case 1: snapshot is deterministic ────────────────────────────────

echo "Case 1: snapshot is deterministic for identical content"
SNAP1="$("${PYTHON_BIN}" "${SNAPSHOT_PY}" snapshot \
  --agent-skills-dir "${FIXTURE_DIR}" \
  --cap-root "${FIXTURE_CAP}")"
SNAP2="$("${PYTHON_BIN}" "${SNAPSHOT_PY}" snapshot \
  --agent-skills-dir "${FIXTURE_DIR}" \
  --cap-root "${FIXTURE_CAP}")"

DIR_HASH_1="$(printf '%s' "${SNAP1}" | "${PYTHON_BIN}" -c "import json,sys;print(json.loads(sys.stdin.read())['dir_hash'])")"
DIR_HASH_2="$(printf '%s' "${SNAP2}" | "${PYTHON_BIN}" -c "import json,sys;print(json.loads(sys.stdin.read())['dir_hash'])")"
assert_eq "case1: dir_hash deterministic" "${DIR_HASH_1}" "${DIR_HASH_2}"

FILE_HASH_1="$(printf '%s' "${SNAP1}" | "${PYTHON_BIN}" -c "
import json,sys
data = json.loads(sys.stdin.read())
print(data['prompt_files']['00-core-protocol.md'])")"
case "${FILE_HASH_1}" in
  sha256:*)
    echo "  PASS: case1: per-file hash uses sha256 prefix"
    pass_count=$((pass_count + 1)) ;;
  *)
    echo "  FAIL: case1: per-file hash missing sha256 prefix: ${FILE_HASH_1}"
    fail_count=$((fail_count + 1)) ;;
esac

FILE_COUNT_1="$(printf '%s' "${SNAP1}" | "${PYTHON_BIN}" -c "
import json,sys
data = json.loads(sys.stdin.read())
print(len(data['prompt_files']))")"
assert_eq "case1: file_count covers the 3 fixture files" "3" "${FILE_COUNT_1}"

# ── Case 2: content drift changes the hash ───────────────────────────

echo ""
echo "Case 2: editing a file changes dir_hash + that file's per-file hash"
echo "# Supervisor fixture EDITED" > "${FIXTURE_DIR}/01-supervisor-agent.md"
SNAP3="$("${PYTHON_BIN}" "${SNAPSHOT_PY}" snapshot \
  --agent-skills-dir "${FIXTURE_DIR}" \
  --cap-root "${FIXTURE_CAP}")"
DIR_HASH_3="$(printf '%s' "${SNAP3}" | "${PYTHON_BIN}" -c "import json,sys;print(json.loads(sys.stdin.read())['dir_hash'])")"
FILE_HASH_3="$(printf '%s' "${SNAP3}" | "${PYTHON_BIN}" -c "
import json,sys
data = json.loads(sys.stdin.read())
print(data['prompt_files']['01-supervisor-agent.md'])")"

assert_neq "case2: dir_hash changes after edit" "${DIR_HASH_1}" "${DIR_HASH_3}"
assert_neq "case2: per-file hash for edited file changes" \
  "$(printf '%s' "${SNAP1}" | "${PYTHON_BIN}" -c "
import json,sys
data = json.loads(sys.stdin.read())
print(data['prompt_files']['01-supervisor-agent.md'])")" \
  "${FILE_HASH_3}"

# Per-file hash for the untouched file is unchanged.
UNTOUCHED_BEFORE="$(printf '%s' "${SNAP1}" | "${PYTHON_BIN}" -c "
import json,sys
data = json.loads(sys.stdin.read())
print(data['prompt_files']['00-core-protocol.md'])")"
UNTOUCHED_AFTER="$(printf '%s' "${SNAP3}" | "${PYTHON_BIN}" -c "
import json,sys
data = json.loads(sys.stdin.read())
print(data['prompt_files']['00-core-protocol.md'])")"
assert_eq "case2: untouched file hash stable across edits" \
  "${UNTOUCHED_BEFORE}" "${UNTOUCHED_AFTER}"

# Restore content for downstream cases.
cat > "${FIXTURE_DIR}/01-supervisor-agent.md" <<'EOF'
# Supervisor fixture
EOF

# ── Case 3: summary projection drops prompt_files ────────────────────

echo ""
echo "Case 3: compute_summary CLI drops prompt_files keys, keeps top-level"
SUMMARY="$("${PYTHON_BIN}" "${SNAPSHOT_PY}" summary \
  --agent-skills-dir "${FIXTURE_DIR}" \
  --cap-root "${FIXTURE_CAP}")"

assert_contains "case3: summary contains dir_hash" '"dir_hash"' "${SUMMARY}"
assert_contains "case3: summary contains file_count" '"file_count": 3' "${SUMMARY}"
case "${SUMMARY}" in
  *prompt_files*)
    echo "  FAIL: case3: summary leaked prompt_files key"
    fail_count=$((fail_count + 1)) ;;
  *)
    echo "  PASS: case3: summary excludes prompt_files key"
    pass_count=$((pass_count + 1)) ;;
esac

# ── Case 4: attach is idempotent on an existing envelope ─────────────

echo ""
echo "Case 4: attach is idempotent (existing baseline preserved)"
LEDGER="${SANDBOX}/agent-sessions.json"
cat > "${LEDGER}" <<'EOF'
{
  "version": 1,
  "run_id": "run_test_001",
  "workflow_id": "smoke-test",
  "workflow_name": "smoke",
  "sessions": []
}
EOF

"${PYTHON_BIN}" "${SNAPSHOT_PY}" attach "${LEDGER}" \
  --agent-skills-dir "${FIXTURE_DIR}" \
  --cap-root "${FIXTURE_CAP}" >/dev/null

FIRST_BASELINE_HASH="$("${PYTHON_BIN}" -c "
import json
print(json.load(open('${LEDGER}'))['agent_skills_baseline']['dir_hash'])")"

assert_contains "case4: baseline written on first attach" "sha256:" "${FIRST_BASELINE_HASH}"

# Edit a file; the existing envelope must NOT be re-stamped (idempotent
# preserves the original baseline that the run actually observed).
echo "# late edit after attach" >> "${FIXTURE_DIR}/00-core-protocol.md"
"${PYTHON_BIN}" "${SNAPSHOT_PY}" attach "${LEDGER}" \
  --agent-skills-dir "${FIXTURE_DIR}" \
  --cap-root "${FIXTURE_CAP}" >/dev/null

SECOND_BASELINE_HASH="$("${PYTHON_BIN}" -c "
import json
print(json.load(open('${LEDGER}'))['agent_skills_baseline']['dir_hash'])")"

assert_eq "case4: second attach is no-op (baseline unchanged)" \
  "${FIRST_BASELINE_HASH}" "${SECOND_BASELINE_HASH}"

# Restore for downstream cases.
sed -i.bak '/late edit after attach/d' "${FIXTURE_DIR}/00-core-protocol.md"
rm -f "${FIXTURE_DIR}/00-core-protocol.md.bak"

# ── Case 5: cap_version reads from repo.manifest.yaml ────────────────

echo ""
echo "Case 5: cap_version comes from repo.manifest.yaml when present"
cat > "${FIXTURE_CAP}/repo.manifest.yaml" <<'EOF'
schema_version: 1
name: "fixture"
cap_version: v9.99.0-test
EOF

CAP_VERSION_OUT="$("${PYTHON_BIN}" "${SNAPSHOT_PY}" snapshot \
  --agent-skills-dir "${FIXTURE_DIR}" \
  --cap-root "${FIXTURE_CAP}" \
  | "${PYTHON_BIN}" -c "import json,sys;print(json.loads(sys.stdin.read())['cap_version'])")"
assert_eq "case5: cap_version read from manifest" "v9.99.0-test" "${CAP_VERSION_OUT}"

rm -f "${FIXTURE_CAP}/repo.manifest.yaml"

CAP_VERSION_NONE="$("${PYTHON_BIN}" "${SNAPSHOT_PY}" snapshot \
  --agent-skills-dir "${FIXTURE_DIR}" \
  --cap-root "${FIXTURE_CAP}" \
  | "${PYTHON_BIN}" -c "import json,sys;print(json.loads(sys.stdin.read())['cap_version'])")"
assert_eq "case5: cap_version is None when manifest missing" "None" "${CAP_VERSION_NONE}"

# ── Case 6: missing agent-skills dir → FileNotFoundError exit 1 ──────

echo ""
echo "Case 6: missing agent-skills dir raises FileNotFoundError"
MISSING_DIR="${SANDBOX}/nope"
MISSING_OUT="$("${PYTHON_BIN}" "${SNAPSHOT_PY}" snapshot \
  --agent-skills-dir "${MISSING_DIR}" \
  --cap-root "${FIXTURE_CAP}" 2>&1)"
case "${MISSING_OUT}" in
  *FileNotFoundError*|*"does not exist"*)
    echo "  PASS: case6: missing dir surfaces FileNotFoundError"
    pass_count=$((pass_count + 1)) ;;
  *)
    echo "  FAIL: case6: expected FileNotFoundError, got: ${MISSING_OUT}"
    fail_count=$((fail_count + 1)) ;;
esac

# ── Case 7: CAP_AGENT_SKILLS_DIR env override ────────────────────────

echo ""
echo "Case 7: CAP_AGENT_SKILLS_DIR env var overrides default"
ENV_OUT="$(CAP_AGENT_SKILLS_DIR="${FIXTURE_DIR}" CAP_ROOT="${FIXTURE_CAP}" \
  "${PYTHON_BIN}" "${SNAPSHOT_PY}" snapshot)"
ENV_FILE_COUNT="$(printf '%s' "${ENV_OUT}" | "${PYTHON_BIN}" -c "
import json,sys
data = json.loads(sys.stdin.read())
print(len(data['prompt_files']))")"
assert_eq "case7: env override produces 3-file snapshot" "3" "${ENV_FILE_COUNT}"

ENV_BASELINE_ROOT="$(printf '%s' "${ENV_OUT}" | "${PYTHON_BIN}" -c "
import json,sys
data = json.loads(sys.stdin.read())
print(data['baseline_root'])")"
case "${ENV_BASELINE_ROOT}" in
  *"${FIXTURE_DIR##*/}"*)
    echo "  PASS: case7: baseline_root reflects env override"
    pass_count=$((pass_count + 1)) ;;
  *)
    echo "  FAIL: case7: baseline_root mismatch: ${ENV_BASELINE_ROOT}"
    fail_count=$((fail_count + 1)) ;;
esac

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
