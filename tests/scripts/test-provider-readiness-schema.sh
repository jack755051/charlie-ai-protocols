#!/usr/bin/env bash
#
# test-provider-readiness-schema.sh — P0-readiness-1 gate.
#
# Validates schemas/provider-readiness.schema.yaml against a
# matrix of fixture readiness reports using
# `engine/step_runtime.py validate-jsonschema`.
#
# Scope-limited per ADR-3 + PROVIDER-READINESS-TASKS.md P0:
#   - Schema-only exercise; no CLI, no probe, no runtime.
#   - No invocation of cap provider doctor or scripts/cap-provider.sh.
#   - No mutation of provider state, no network calls.
#
# Cases:
#   1.  Valid minimum payload passes.
#   2.  Valid full payload with all 6 states represented passes.
#   3.  Missing schema_version fails.
#   4.  Wrong schema_version (2) fails.
#   5.  Missing probe_policy fails.
#   6.  probe_policy.no_token=false fails (locked-true enum).
#   7.  probe_policy.no_interactive=false fails (locked-true enum).
#   8.  probe_policy.no_mutation=false fails (locked-true enum).
#   9.  providers=[] fails (minItems 1).
#  10. Unknown state ("logged_out") fails (enum).
#  11. Non-kebab provider name fails (pattern).
#  12. Missing required provider field (state) fails.
#  13. Unknown top-level field fails (additionalProperties).
#  14. Unknown provider field fails (additionalProperties).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCHEMA="${REPO_ROOT}/schemas/provider-readiness.schema.yaml"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"
PYTHON_BIN="${PYTHON_BIN:-python3}"

[ -f "${SCHEMA}" ] || { echo "FAIL: ${SCHEMA} missing"; exit 1; }
[ -f "${STEP_PY}" ] || { echo "FAIL: ${STEP_PY} missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-provider-readiness-test.XXXXXX)"
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

run_validate() {
  local json_path="$1"
  local stdout rc
  stdout="$("${PYTHON_BIN}" "${STEP_PY}" validate-jsonschema "${json_path}" "${SCHEMA}" 2>&1)"
  rc=$?
  printf '%s|%s' "${rc}" "${stdout}"
}

write_payload() {
  local target="$1" payload="$2"
  "${PYTHON_BIN}" - "${target}" "${payload}" <<'PY'
import json, sys
out_path, payload_json = sys.argv[1], sys.argv[2]
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(json.loads(payload_json), fh, indent=2)
PY
}

# Canonical minimum-valid report.
VALID_MIN='{
  "schema_version": 1,
  "generated_at": "2026-05-15T12:00:00Z",
  "probe_policy": {
    "no_token": true,
    "no_interactive": true,
    "no_mutation": true
  },
  "providers": [
    {
      "name": "claude",
      "source": "cli",
      "state": "auth_ok",
      "remediation": "provider ready; no action needed"
    }
  ]
}'

# Full report — every state represented at least once + every
# allowed source. Used by Case 2 to confirm the enums are wired
# end-to-end.
VALID_FULL='{
  "schema_version": 1,
  "generated_at": "2026-05-15T12:00:00Z",
  "probe_policy": {
    "no_token": true,
    "no_interactive": true,
    "no_mutation": true
  },
  "providers": [
    {
      "name": "claude",
      "source": "cli",
      "cli_path": "/usr/local/bin/claude",
      "state": "auth_ok",
      "remediation": "provider ready; no action needed",
      "version": "1.0.0",
      "probe_source": "cap-provider-doctor-claude-v1"
    },
    {
      "name": "codex",
      "source": "cli",
      "state": "installed",
      "remediation": "run `cap codex` once to complete login"
    },
    {
      "name": "openai",
      "source": "api_key",
      "api_key_env": "OPENAI_API_KEY",
      "state": "auth_required",
      "remediation": "export OPENAI_API_KEY=..."
    },
    {
      "name": "deepseek",
      "source": "api_key",
      "api_key_env": "DEEPSEEK_API_KEY",
      "state": "provider_missing",
      "remediation": "DeepSeek adapter not configured; set DEEPSEEK_API_KEY"
    },
    {
      "name": "local_llama",
      "source": "local_runtime",
      "state": "auth_unknown",
      "remediation": "local runtime endpoint reachable; auth probe unsafe under no-token rule"
    },
    {
      "name": "future_provider",
      "source": "cli",
      "state": "error",
      "remediation": "see failure_reason; reinstall provider CLI",
      "failure_reason": "version probe timed out after 5s"
    }
  ]
}'

# ── Case 1: valid minimum payload passes ─────────────────────────
echo "Case 1: valid minimum-required payload validates ok"
FX1="${SANDBOX}/case1.json"
write_payload "${FX1}" "${VALID_MIN}"
res1="$(run_validate "${FX1}")"
rc1="${res1%%|*}"
out1="${res1#*|}"
assert_eq        "validator exits 0 on valid minimum"  "0"                                          "${rc1}"
assert_contains "stdout includes ok: true"              "${out1}"  "\"ok\": true"
assert_contains "no errors emitted"                      "${out1}"  "\"errors\": []"

# ── Case 2: valid full report covering all 6 states passes ─────
echo ""
echo "Case 2: full report with all 6 states represented validates ok"
FX2="${SANDBOX}/case2.json"
write_payload "${FX2}" "${VALID_FULL}"
res2="$(run_validate "${FX2}")"
rc2="${res2%%|*}"
out2="${res2#*|}"
assert_eq        "validator exits 0 on valid full report"  "0"                                      "${rc2}"
assert_contains "no errors on full report"                  "${out2}"  "\"errors\": []"

# ── Case 3: missing schema_version fails ───────────────────────
echo ""
echo "Case 3: missing schema_version rejected"
FX3="${SANDBOX}/case3.json"
"${PYTHON_BIN}" - "${FX3}" "${VALID_MIN}" <<'PY'
import json, sys
data = json.loads(sys.argv[2])
data.pop("schema_version")
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
res3="$(run_validate "${FX3}")"
rc3="${res3%%|*}"
out3="${res3#*|}"
assert_eq        "validator exits 1 on missing schema_version"  "1"                                "${rc3}"
assert_contains "error mentions schema_version"                  "${out3}"  "schema_version"

# ── Case 4: wrong schema_version (2) fails ─────────────────────
echo ""
echo "Case 4: schema_version=2 rejected (enum)"
FX4="${SANDBOX}/case4.json"
"${PYTHON_BIN}" - "${FX4}" "${VALID_MIN}" <<'PY'
import json, sys
data = json.loads(sys.argv[2])
data["schema_version"] = 2
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
res4="$(run_validate "${FX4}")"
rc4="${res4%%|*}"
out4="${res4#*|}"
assert_eq        "validator exits 1 on schema_version=2"  "1"                                      "${rc4}"
assert_contains "error mentions schema_version"            "${out4}"  "schema_version"

# ── Case 5: missing probe_policy fails ─────────────────────────
echo ""
echo "Case 5: missing probe_policy rejected"
FX5="${SANDBOX}/case5.json"
"${PYTHON_BIN}" - "${FX5}" "${VALID_MIN}" <<'PY'
import json, sys
data = json.loads(sys.argv[2])
data.pop("probe_policy")
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
res5="$(run_validate "${FX5}")"
rc5="${res5%%|*}"
out5="${res5#*|}"
assert_eq        "validator exits 1 on missing probe_policy"  "1"                                 "${rc5}"
assert_contains "error mentions probe_policy"                  "${out5}"  "probe_policy"

# ── Case 6: probe_policy.no_token=false fails ──────────────────
echo ""
echo "Case 6: probe_policy.no_token=false rejected (locked-true enum)"
FX6="${SANDBOX}/case6.json"
"${PYTHON_BIN}" - "${FX6}" "${VALID_MIN}" <<'PY'
import json, sys
data = json.loads(sys.argv[2])
data["probe_policy"]["no_token"] = False
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
res6="$(run_validate "${FX6}")"
rc6="${res6%%|*}"
out6="${res6#*|}"
assert_eq        "validator exits 1 when no_token=false"  "1"                                     "${rc6}"
assert_contains "error mentions no_token"                  "${out6}"  "no_token"

# ── Case 7: probe_policy.no_interactive=false fails ────────────
echo ""
echo "Case 7: probe_policy.no_interactive=false rejected"
FX7="${SANDBOX}/case7.json"
"${PYTHON_BIN}" - "${FX7}" "${VALID_MIN}" <<'PY'
import json, sys
data = json.loads(sys.argv[2])
data["probe_policy"]["no_interactive"] = False
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
res7="$(run_validate "${FX7}")"
rc7="${res7%%|*}"
out7="${res7#*|}"
assert_eq        "validator exits 1 when no_interactive=false"  "1"                              "${rc7}"
assert_contains "error mentions no_interactive"                  "${out7}"  "no_interactive"

# ── Case 8: probe_policy.no_mutation=false fails ──────────────
echo ""
echo "Case 8: probe_policy.no_mutation=false rejected"
FX8="${SANDBOX}/case8.json"
"${PYTHON_BIN}" - "${FX8}" "${VALID_MIN}" <<'PY'
import json, sys
data = json.loads(sys.argv[2])
data["probe_policy"]["no_mutation"] = False
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
res8="$(run_validate "${FX8}")"
rc8="${res8%%|*}"
out8="${res8#*|}"
assert_eq        "validator exits 1 when no_mutation=false"  "1"                                 "${rc8}"
assert_contains "error mentions no_mutation"                  "${out8}"  "no_mutation"

# ── Case 9: empty providers array fails ───────────────────────
echo ""
echo "Case 9: providers=[] rejected (minItems)"
FX9="${SANDBOX}/case9.json"
"${PYTHON_BIN}" - "${FX9}" "${VALID_MIN}" <<'PY'
import json, sys
data = json.loads(sys.argv[2])
data["providers"] = []
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
res9="$(run_validate "${FX9}")"
rc9="${res9%%|*}"
out9="${res9#*|}"
assert_eq        "validator exits 1 on empty providers"  "1"                                      "${rc9}"
assert_contains "error mentions providers"                "${out9}"  "providers"

# ── Case 10: unknown state ("logged_out") fails ────────────────
echo ""
echo "Case 10: provider state='logged_out' rejected (enum)"
FX10="${SANDBOX}/case10.json"
"${PYTHON_BIN}" - "${FX10}" "${VALID_MIN}" <<'PY'
import json, sys
data = json.loads(sys.argv[2])
data["providers"][0]["state"] = "logged_out"
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
res10="$(run_validate "${FX10}")"
rc10="${res10%%|*}"
out10="${res10#*|}"
assert_eq        "validator exits 1 on unknown state"  "1"                                       "${rc10}"
assert_contains "error mentions the bad state"          "${out10}"  "logged_out"

# ── Case 11: non-kebab provider name fails ────────────────────
echo ""
echo "Case 11: provider name='ClaudeCode' rejected (pattern)"
FX11="${SANDBOX}/case11.json"
"${PYTHON_BIN}" - "${FX11}" "${VALID_MIN}" <<'PY'
import json, sys
data = json.loads(sys.argv[2])
data["providers"][0]["name"] = "ClaudeCode"
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
res11="$(run_validate "${FX11}")"
rc11="${res11%%|*}"
out11="${res11#*|}"
assert_eq        "validator exits 1 on non-kebab provider name"  "1"                              "${rc11}"
assert_contains "error mentions name"                              "${out11}"  "name"

# ── Case 12: missing required provider field (state) fails ────
echo ""
echo "Case 12: provider entry missing 'state' rejected"
FX12="${SANDBOX}/case12.json"
"${PYTHON_BIN}" - "${FX12}" "${VALID_MIN}" <<'PY'
import json, sys
data = json.loads(sys.argv[2])
data["providers"][0].pop("state")
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
res12="$(run_validate "${FX12}")"
rc12="${res12%%|*}"
out12="${res12#*|}"
assert_eq        "validator exits 1 on provider missing state"  "1"                              "${rc12}"
assert_contains "error mentions state"                           "${out12}"  "state"

# ── Case 13: unknown top-level field fails ─────────────────────
echo ""
echo "Case 13: unknown top-level field rejected (additionalProperties)"
FX13="${SANDBOX}/case13.json"
"${PYTHON_BIN}" - "${FX13}" "${VALID_MIN}" <<'PY'
import json, sys
data = json.loads(sys.argv[2])
data["mystery_flag"] = True
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
res13="$(run_validate "${FX13}")"
rc13="${res13%%|*}"
out13="${res13#*|}"
assert_eq        "validator exits 1 on unknown top-level field"  "1"                              "${rc13}"
assert_contains "error mentions the unknown field"                "${out13}"  "mystery_flag"

# ── Case 14: unknown provider field fails ─────────────────────
echo ""
echo "Case 14: unknown provider entry field rejected (additionalProperties)"
FX14="${SANDBOX}/case14.json"
"${PYTHON_BIN}" - "${FX14}" "${VALID_MIN}" <<'PY'
import json, sys
data = json.loads(sys.argv[2])
data["providers"][0]["mystery_provider_field"] = "huh"
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
res14="$(run_validate "${FX14}")"
rc14="${res14%%|*}"
out14="${res14#*|}"
assert_eq        "validator exits 1 on unknown provider field"  "1"                               "${rc14}"
assert_contains "error mentions the unknown provider field"      "${out14}"  "mystery_provider_field"

echo ""
total=$((pass_count + fail_count))
echo "provider-readiness-schema: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
