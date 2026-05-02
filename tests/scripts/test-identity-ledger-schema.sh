#!/usr/bin/env bash
#
# test-identity-ledger-schema.sh — Validate
# schemas/identity-ledger.schema.yaml against positive and negative
# fixtures using step_runtime.py validate-jsonschema.
#
# This is a normalized contract: cap-paths.sh and project_context_loader.py
# are direct producers. v1 ledgers (P1 #2 inline shape) are NOT covered here
# because cap-paths auto-migrates them to v2 before any schema check; v1 is
# never a valid ledger state to schema-validate against.
#
# Coverage:
#   Positive 1: minimal valid v2 (required fields only, optionals null/empty)
#   Positive 2: full v2 with cap_version + migrated_at + previous_versions[]
#   Negative 1: missing required schema_version
#   Negative 2: missing required project_id
#   Negative 3: missing required last_resolved_at
#   Negative 4: schema_version=1 (v1 is auto-migrated, not schema-valid)
#   Negative 5: schema_version=99 (forward-incompat halt)
#   Negative 6: resolved_mode not in enum
#   Negative 7: project_id pattern violation (uppercase)
#   Negative 8: previous_versions[].schema_version missing
#   Negative 9: additionalProperties violation (unknown top-level key)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCHEMA_PATH="${REPO_ROOT}/schemas/identity-ledger.schema.yaml"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"
VENV_PY="${REPO_ROOT}/.venv/bin/python"
if [ -x "${VENV_PY}" ]; then
  PYTHON_BIN="${VENV_PY}"
else
  PYTHON_BIN="python3"
fi

[ -f "${SCHEMA_PATH}" ] || { echo "FAIL: schema not found at ${SCHEMA_PATH}"; exit 1; }
[ -f "${STEP_PY}" ]    || { echo "FAIL: step_runtime.py not found"; exit 1; }

SANDBOX="$(mktemp -d -t cap-identity-ledger.XXXXXX)"
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

validate_fixture() {
  local fixture_path="$1"
  "${PYTHON_BIN}" "${STEP_PY}" validate-jsonschema "${fixture_path}" "${SCHEMA_PATH}" >/dev/null 2>&1
  echo $?
}

write_fixture() {
  local name="$1" payload="$2"
  local path="${SANDBOX}/${name}.json"
  printf '%s\n' "${payload}" > "${path}"
  printf '%s' "${path}"
}

# ── Positive 1: minimal valid v2 ─────────────────────────────────────
echo "Positive 1: minimal valid v2 (required only)"
fixture="$(write_fixture "pos-minimal" '{
  "schema_version": 2,
  "project_id": "minimal-proj",
  "resolved_mode": "config",
  "origin_path": "/abs/path/to/project",
  "created_at": "2026-05-02T10:00:00Z",
  "last_resolved_at": "2026-05-02T10:00:00Z"
}')"
assert_eq "minimal v2 validates" "0" "$(validate_fixture "${fixture}")"

# ── Positive 2: full v2 with all optionals ───────────────────────────
echo "Positive 2: full v2 with cap_version + migrated_at + previous_versions[]"
fixture="$(write_fixture "pos-full" '{
  "schema_version": 2,
  "project_id": "full-proj",
  "resolved_mode": "git_basename",
  "origin_path": "/home/dev/full-proj",
  "created_at": "2026-05-01T08:00:00Z",
  "last_resolved_at": "2026-05-02T11:30:00Z",
  "migrated_at": "2026-05-02T11:30:00Z",
  "cap_version": "v0.22.0-rc1",
  "previous_versions": [
    {
      "schema_version": 1,
      "migrated_to_at": "2026-05-02T11:30:00Z"
    }
  ]
}')"
assert_eq "full v2 validates" "0" "$(validate_fixture "${fixture}")"

# ── Negative 1: missing required schema_version ──────────────────────
echo "Negative 1: missing required schema_version"
fixture="$(write_fixture "neg-no-sv" '{
  "project_id": "neg1",
  "resolved_mode": "config",
  "origin_path": "/p",
  "created_at": "2026-05-02T10:00:00Z",
  "last_resolved_at": "2026-05-02T10:00:00Z"
}')"
assert_eq "missing schema_version rejected" "1" "$(validate_fixture "${fixture}")"

# ── Negative 2: missing required project_id ──────────────────────────
echo "Negative 2: missing required project_id"
fixture="$(write_fixture "neg-no-pid" '{
  "schema_version": 2,
  "resolved_mode": "config",
  "origin_path": "/p",
  "created_at": "2026-05-02T10:00:00Z",
  "last_resolved_at": "2026-05-02T10:00:00Z"
}')"
assert_eq "missing project_id rejected" "1" "$(validate_fixture "${fixture}")"

# ── Negative 3: missing required last_resolved_at ────────────────────
echo "Negative 3: missing required last_resolved_at"
fixture="$(write_fixture "neg-no-lra" '{
  "schema_version": 2,
  "project_id": "neg3",
  "resolved_mode": "config",
  "origin_path": "/p",
  "created_at": "2026-05-02T10:00:00Z"
}')"
assert_eq "missing last_resolved_at rejected" "1" "$(validate_fixture "${fixture}")"

# ── Negative 4: schema_version=1 (must be auto-migrated, not schema-valid) ──
echo "Negative 4: schema_version=1 (auto-migrated by cap-paths, never schema-valid)"
fixture="$(write_fixture "neg-v1" '{
  "schema_version": 1,
  "project_id": "neg4",
  "resolved_mode": "config",
  "origin_path": "/p",
  "created_at": "2026-05-02T10:00:00Z",
  "last_resolved_at": "2026-05-02T10:00:00Z"
}')"
assert_eq "schema_version=1 rejected (forces migration path)" "1" "$(validate_fixture "${fixture}")"

# ── Negative 5: schema_version=99 (forward-incompat halt) ────────────
echo "Negative 5: schema_version=99 (forward-incompat halt)"
fixture="$(write_fixture "neg-v99" '{
  "schema_version": 99,
  "project_id": "neg5",
  "resolved_mode": "config",
  "origin_path": "/p",
  "created_at": "2026-05-02T10:00:00Z",
  "last_resolved_at": "2026-05-02T10:00:00Z"
}')"
assert_eq "schema_version=99 rejected (forward-incompat)" "1" "$(validate_fixture "${fixture}")"

# ── Negative 6: resolved_mode not in enum ────────────────────────────
echo "Negative 6: resolved_mode not in enum"
fixture="$(write_fixture "neg-mode" '{
  "schema_version": 2,
  "project_id": "neg6",
  "resolved_mode": "made_up_mode",
  "origin_path": "/p",
  "created_at": "2026-05-02T10:00:00Z",
  "last_resolved_at": "2026-05-02T10:00:00Z"
}')"
assert_eq "invalid resolved_mode rejected" "1" "$(validate_fixture "${fixture}")"

# ── Negative 7: project_id pattern violation (uppercase) ─────────────
echo "Negative 7: project_id pattern violation (uppercase)"
fixture="$(write_fixture "neg-pid-pattern" '{
  "schema_version": 2,
  "project_id": "Has-Upper",
  "resolved_mode": "config",
  "origin_path": "/p",
  "created_at": "2026-05-02T10:00:00Z",
  "last_resolved_at": "2026-05-02T10:00:00Z"
}')"
assert_eq "uppercase project_id rejected" "1" "$(validate_fixture "${fixture}")"

# ── Negative 8: previous_versions item missing schema_version ────────
echo "Negative 8: previous_versions[] item missing schema_version"
fixture="$(write_fixture "neg-prev-shape" '{
  "schema_version": 2,
  "project_id": "neg8",
  "resolved_mode": "config",
  "origin_path": "/p",
  "created_at": "2026-05-02T10:00:00Z",
  "last_resolved_at": "2026-05-02T10:00:00Z",
  "previous_versions": [
    {"migrated_to_at": "2026-05-02T11:30:00Z"}
  ]
}')"
assert_eq "previous_versions item missing schema_version rejected" "1" "$(validate_fixture "${fixture}")"

# ── Negative 9: additionalProperties violation ───────────────────────
echo "Negative 9: unknown top-level key (additionalProperties=false)"
fixture="$(write_fixture "neg-addl" '{
  "schema_version": 2,
  "project_id": "neg9",
  "resolved_mode": "config",
  "origin_path": "/p",
  "created_at": "2026-05-02T10:00:00Z",
  "last_resolved_at": "2026-05-02T10:00:00Z",
  "rogue_field": "should not pass"
}')"
assert_eq "unknown top-level key rejected" "1" "$(validate_fixture "${fixture}")"

echo
echo "Summary: ${pass_count} passed, ${fail_count} failed"

if [ "${fail_count}" -gt 0 ]; then
  exit 1
fi
exit 0
