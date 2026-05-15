#!/usr/bin/env bash
#
# test-component-fast-args-schema.sh — P1b-input-1 gate.
#
# Validates schemas/component-fast-args.schema.yaml against a
# matrix of fixture args JSON files using
# `engine/step_runtime.py validate-jsonschema`.
#
# This test is intentionally scope-limited per ADR-2 and the
# P1b-input-1 slice authorization:
#   - It exercises the schema only.
#   - It does NOT invoke any CLI surface that consumes the args.
#   - It does NOT touch the workflow runtime, the resolver shell,
#     or any project under ~/.cap.
#
# Cases (per the slice authorization):
#   1. Valid feedback-widget args pass.
#   2. Missing component_type fails.
#   3. Unknown component_type ("feedback-page") fails.
#   4. Unsupported stack_preset ("svelte_postgres") fails.
#   5. exclusions missing "redis" fails (item enum violation).
#   6. exclusions empty array fails (minItems violation).
#   7. Non-kebab project_id ("ComponentFeedback") fails.
#   8. Extra unknown top-level field fails (additionalProperties=false).
#
# Plus extra coverage for the optional surface:
#   9. Optional fields (target_root / api_base_url / env) accepted.
#  10. api_base_url with bad scheme ("ftp://...") fails.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCHEMA="${REPO_ROOT}/schemas/component-fast-args.schema.yaml"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"
PYTHON_BIN="${PYTHON_BIN:-python3}"

[ -f "${SCHEMA}" ] || { echo "FAIL: ${SCHEMA} missing"; exit 1; }
[ -f "${STEP_PY}" ] || { echo "FAIL: ${STEP_PY} missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-args-schema-test.XXXXXX)"
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

# Run the validator against a fixture JSON file. Echoes "<rc>|<stdout>".
run_validate() {
  local json_path="$1"
  local stdout rc
  stdout="$("${PYTHON_BIN}" "${STEP_PY}" validate-jsonschema "${json_path}" "${SCHEMA}" 2>&1)"
  rc=$?
  printf '%s|%s' "${rc}" "${stdout}"
}

# Helper to write a JSON fixture from a Python literal so the test
# can keep the matrix readable without escaping curly braces in
# bash heredocs.
write_fixture() {
  local target="$1"; shift
  "${PYTHON_BIN}" - "${target}" "$@" <<'PY'
import json, sys
out_path, payload_json = sys.argv[1], sys.argv[2]
data = json.loads(payload_json)
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
}

# Canonical minimum-valid payload — every required field set.
VALID_MIN='{
  "schema_version": 1,
  "project_id": "component-feedback-widget",
  "component_type": "feedback-widget",
  "stack_preset": "nextjs14_dotnet8_postgres16",
  "ui_adapter": "shadcn_ui",
  "storage_default": "in_memory",
  "exclusions": ["redis"]
}'

# Canonical full payload — every required + optional field set.
VALID_FULL='{
  "schema_version": 1,
  "project_id": "component-feedback-widget",
  "component_type": "feedback-widget",
  "stack_preset": "nextjs14_dotnet8_postgres16",
  "ui_adapter": "shadcn_ui",
  "storage_default": "in_memory",
  "exclusions": ["redis"],
  "target_root": ".",
  "api_base_url": "http://localhost:8080",
  "env": {"BACKEND_PORT": "8080", "FRONTEND_PORT": "3000"}
}'

# ── Case 1: valid minimum payload passes ─────────────────────────
echo "Case 1: valid minimum-required payload validates ok"
FX1="${SANDBOX}/case1.json"
write_fixture "${FX1}" "${VALID_MIN}"
res1="$(run_validate "${FX1}")"
rc1="${res1%%|*}"
out1="${res1#*|}"
assert_eq        "validator exits 0 on valid args"   "0"                                            "${rc1}"
assert_contains "stdout includes ok: true"            "${out1}"  "\"ok\": true"
assert_contains "no errors emitted"                    "${out1}"  "\"errors\": []"

# ── Case 2: missing component_type fails ─────────────────────────
echo ""
echo "Case 2: missing component_type rejected"
FX2="${SANDBOX}/case2.json"
"${PYTHON_BIN}" - "${FX2}" "${VALID_MIN}" <<'PY'
import json, sys
out_path, payload = sys.argv[1], sys.argv[2]
data = json.loads(payload)
data.pop("component_type")
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
res2="$(run_validate "${FX2}")"
rc2="${res2%%|*}"
out2="${res2#*|}"
assert_eq        "validator exits 1 on missing component_type"  "1"                                "${rc2}"
assert_contains "error mentions component_type"                  "${out2}"  "component_type"

# ── Case 3: unknown component_type fails ─────────────────────────
echo ""
echo "Case 3: unknown component_type ('feedback-page') rejected"
FX3="${SANDBOX}/case3.json"
"${PYTHON_BIN}" - "${FX3}" "${VALID_MIN}" <<'PY'
import json, sys
data = json.loads(sys.argv[2])
data["component_type"] = "feedback-page"
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
res3="$(run_validate "${FX3}")"
rc3="${res3%%|*}"
out3="${res3#*|}"
assert_eq        "validator exits 1 on unknown component_type"  "1"                                "${rc3}"
assert_contains "error names the bad component_type"             "${out3}"  "feedback-page"

# ── Case 4: unsupported stack_preset fails ──────────────────────
echo ""
echo "Case 4: unsupported stack_preset rejected"
FX4="${SANDBOX}/case4.json"
"${PYTHON_BIN}" - "${FX4}" "${VALID_MIN}" <<'PY'
import json, sys
data = json.loads(sys.argv[2])
data["stack_preset"] = "svelte_postgres"
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
res4="$(run_validate "${FX4}")"
rc4="${res4%%|*}"
out4="${res4#*|}"
assert_eq        "validator exits 1 on unsupported stack_preset"  "1"                              "${rc4}"
assert_contains "error names the bad stack_preset"                 "${out4}"  "svelte_postgres"

# ── Case 5: exclusions missing redis fails ──────────────────────
echo ""
echo "Case 5: exclusions without 'redis' rejected (items.enum)"
FX5="${SANDBOX}/case5.json"
"${PYTHON_BIN}" - "${FX5}" "${VALID_MIN}" <<'PY'
import json, sys
data = json.loads(sys.argv[2])
data["exclusions"] = ["kafka"]
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
res5="$(run_validate "${FX5}")"
rc5="${res5%%|*}"
out5="${res5#*|}"
assert_eq        "validator exits 1 when exclusions item != redis"  "1"                            "${rc5}"
assert_contains "error mentions exclusions"                          "${out5}"  "exclusions"

# ── Case 6: exclusions empty array fails ────────────────────────
echo ""
echo "Case 6: exclusions=[] rejected (minItems)"
FX6="${SANDBOX}/case6.json"
"${PYTHON_BIN}" - "${FX6}" "${VALID_MIN}" <<'PY'
import json, sys
data = json.loads(sys.argv[2])
data["exclusions"] = []
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
res6="$(run_validate "${FX6}")"
rc6="${res6%%|*}"
out6="${res6#*|}"
assert_eq        "validator exits 1 on empty exclusions array"   "1"                                "${rc6}"
assert_contains "error mentions exclusions"                       "${out6}"  "exclusions"

# ── Case 7: non-kebab project_id fails ──────────────────────────
echo ""
echo "Case 7: non-kebab project_id ('ComponentFeedback') rejected"
FX7="${SANDBOX}/case7.json"
"${PYTHON_BIN}" - "${FX7}" "${VALID_MIN}" <<'PY'
import json, sys
data = json.loads(sys.argv[2])
data["project_id"] = "ComponentFeedback"
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
res7="$(run_validate "${FX7}")"
rc7="${res7%%|*}"
out7="${res7#*|}"
assert_eq        "validator exits 1 on non-kebab project_id"  "1"                                  "${rc7}"
assert_contains "error mentions project_id"                    "${out7}"  "project_id"

# ── Case 8: extra unknown top-level field fails ────────────────
echo ""
echo "Case 8: unknown top-level field rejected (additionalProperties=false)"
FX8="${SANDBOX}/case8.json"
"${PYTHON_BIN}" - "${FX8}" "${VALID_MIN}" <<'PY'
import json, sys
data = json.loads(sys.argv[2])
data["mystery_flag"] = True
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
res8="$(run_validate "${FX8}")"
rc8="${res8%%|*}"
out8="${res8#*|}"
assert_eq        "validator exits 1 on unknown field"  "1"                                          "${rc8}"
assert_contains "error mentions the unknown field"      "${out8}"  "mystery_flag"

# ── Case 9: full payload with all optional fields passes ────────
echo ""
echo "Case 9: full payload (with target_root / api_base_url / env) passes"
FX9="${SANDBOX}/case9.json"
write_fixture "${FX9}" "${VALID_FULL}"
res9="$(run_validate "${FX9}")"
rc9="${res9%%|*}"
out9="${res9#*|}"
assert_eq        "validator exits 0 on valid full payload"  "0"                                    "${rc9}"
assert_contains "no errors emitted on full payload"          "${out9}"  "\"errors\": []"

# ── Case 10: api_base_url with bad scheme fails ────────────────
echo ""
echo "Case 10: api_base_url='ftp://example/' rejected (pattern)"
FX10="${SANDBOX}/case10.json"
"${PYTHON_BIN}" - "${FX10}" "${VALID_MIN}" <<'PY'
import json, sys
data = json.loads(sys.argv[2])
data["api_base_url"] = "ftp://example/"
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
res10="$(run_validate "${FX10}")"
rc10="${res10%%|*}"
out10="${res10#*|}"
assert_eq        "validator exits 1 on bad api_base_url scheme"  "1"                              "${rc10}"
assert_contains "error mentions api_base_url"                     "${out10}"  "api_base_url"

echo ""
total=$((pass_count + fail_count))
echo "component-fast-args-schema: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
