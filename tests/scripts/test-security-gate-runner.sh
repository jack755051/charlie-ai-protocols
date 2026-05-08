#!/usr/bin/env bash
#
# test-security-gate-runner.sh — P8 #3 security checkpoint runner contract.
#
# Verifies the engine/step_runtime.py run-security-gate subcommand
# (engine/security_gate_runner.py) acts as the second concrete producer
# for schemas/gate-result.schema.yaml. Mirrors test-watcher-gate-runner
# in shape so the two runners' contract gaps are easy to spot in
# review; only the check semantics differ.
#
# Coverage:
#   1. Clean source file                       → result=pass risk=none
#   2. AWS access key (AKIA…) leak             → result=fail risk=critical fail_routing.action=halt
#   3. Private key block                       → result=fail risk=critical halt
#   4. Generic api_key="…" hardcode            → result=fail risk=high escalate
#   5. dangerouslySetInnerHTML usage           → result=fail risk=high (xss_risk_react)
#   6. v-html directive (Vue XSS)              → result=fail risk=high (xss_risk_vue)
#   7. eval(...) usage                         → result=warn risk=medium
#   8. Missing target artifact                 → result=blocked risk=high halt
#   9. Empty target artifact                   → result=pass risk=low (security tolerates empty)
#  10. No --target-artifact                    → result=blocked degenerate input
#  11. Default --output resolves to cwd        → ./<step_id>.gate-result.json written
#  12. Round-trip with validate-gate-result CLI → all envelopes rc 0 reason=ok
#  13. Custom --produced-by / --gate-subtype   → propagate to envelope

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"

[ -f "${STEP_PY}" ] || { echo "FAIL: engine/step_runtime.py missing"; exit 1; }

VENV_PY="${REPO_ROOT}/.venv/bin/python"
if [ -x "${VENV_PY}" ]; then
  PYTHON_BIN="${VENV_PY}"
else
  PYTHON_BIN="python3"
fi

SANDBOX="$(mktemp -d -t cap-security-runner-test.XXXXXX)"
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
  if grep -qF -- "${needle}" <<<"${haystack}"; then
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected substring: ${needle}"
    echo "    actual head: $(printf '%s' "${haystack}" | head -3)"
    fail_count=$((fail_count + 1))
  fi
}

read_field() {
  local path="$1" key="$2"
  "${PYTHON_BIN}" - "${path}" "${key}" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    data = json.loads(open(path, encoding="utf-8").read())
except Exception:
    print("<absent>")
    sys.exit(0)
val = data.get(key, "<absent>")
print(val if isinstance(val, str) else json.dumps(val, ensure_ascii=False))
PY
}

read_nested_field() {
  local path="$1" outer="$2" inner="$3"
  "${PYTHON_BIN}" - "${path}" "${outer}" "${inner}" <<'PY'
import json, sys
path, outer, inner = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    data = json.loads(open(path, encoding="utf-8").read())
except Exception:
    print("<absent>")
    sys.exit(0)
node = data.get(outer, {})
if not isinstance(node, dict):
    print("<absent>")
    sys.exit(0)
val = node.get(inner, "<absent>")
print(val if isinstance(val, str) else json.dumps(val, ensure_ascii=False))
PY
}

# Common identity per case; only target_artifacts and step_id rotate.
GATE_ID="security_scan"
CHECKPOINT="pre_merge"
WORKFLOW_ID="project-implementation-pipeline"
RUN_ID="run_20260505000000_sec00001"
PROJECT_ID="security-runner-test"

run_gate() {
  # Wrapper: run security gate, capture stdout. Caller checks rc + content.
  local step_id="$1" output="$2"; shift 2
  local artifacts=("$@")
  local args=(
    --gate-id "${GATE_ID}"
    --checkpoint "${CHECKPOINT}"
    --workflow-id "${WORKFLOW_ID}"
    --run-id "${RUN_ID}"
    --step-id "${step_id}"
    --project-id "${PROJECT_ID}"
    --output "${output}"
  )
  local a
  for a in "${artifacts[@]}"; do
    args+=(--target-artifact "${a}")
  done
  cd "${REPO_ROOT}" && "${PYTHON_BIN}" "${STEP_PY}" run-security-gate "${args[@]}" 2>&1
}

# ── Case 1: clean source ────────────────────────────────────────────────
echo "Case 1: clean source → result=pass risk=none"
ART_DIR_1="${SANDBOX}/case1"
mkdir -p "${ART_DIR_1}"
cat > "${ART_DIR_1}/clean.js" <<'EOF'
function add(a, b) {
  return a + b;
}
EOF
OUT_1="${ART_DIR_1}/scan.gate-result.json"
out1="$(run_gate scan_clean "${OUT_1}" "${ART_DIR_1}/clean.js")"
rc1=$?
assert_eq        "rc 0 on clean pass"           "0"            "${rc1}"
assert_contains  "stdout result=pass"           "result=pass"   "${out1}"
assert_contains  "stdout risk=none"             "risk=none"     "${out1}"
assert_eq        "envelope gate_type=security"   "security"     "$(read_field "${OUT_1}" gate_type)"
assert_eq        "envelope produced_by=08-Security" "08-Security" "$(read_field "${OUT_1}" produced_by)"
assert_eq        "envelope findings empty"       "[]"           "$(read_field "${OUT_1}" findings)"

# ── Case 2: AWS access key leak → critical / halt ───────────────────────
echo "Case 2: AWS AKIA key → result=fail risk=critical fail_routing.action=halt"
ART_DIR_2="${SANDBOX}/case2"
mkdir -p "${ART_DIR_2}"
cat > "${ART_DIR_2}/aws.py" <<'EOF'
import os
AWS_KEY = "AKIAABCDEFGHIJKLMNOP"
EOF
OUT_2="${ART_DIR_2}/aws_scan.gate-result.json"
out2="$(run_gate scan_aws "${OUT_2}" "${ART_DIR_2}/aws.py")"
rc2=$?
assert_eq        "rc 0 (runner exit 0 even when verdict=fail)" "0" "${rc2}"
assert_contains  "stdout result=fail"            "result=fail"            "${out2}"
assert_contains  "stdout risk=critical"          "risk=critical"          "${out2}"
assert_eq        "envelope result=fail"          "fail"                   "$(read_field "${OUT_2}" result)"
assert_eq        "envelope risk_level=critical"  "critical"                "$(read_field "${OUT_2}" risk_level)"
assert_eq        "fail_routing.action=halt (critical → halt)" "halt"      "$(read_nested_field "${OUT_2}" fail_routing action)"
assert_contains  "finding category=secret_leak_aws_key" "secret_leak_aws_key" "$(cat "${OUT_2}")"

# ── Case 3: private key block → critical / halt ─────────────────────────
echo "Case 3: private key block → result=fail risk=critical halt"
ART_DIR_3="${SANDBOX}/case3"
mkdir -p "${ART_DIR_3}"
cat > "${ART_DIR_3}/keystore.txt" <<'EOF'
some preamble
-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEA0Z9zQ...
-----END RSA PRIVATE KEY-----
trailer
EOF
OUT_3="${ART_DIR_3}/key_scan.gate-result.json"
out3="$(run_gate scan_pkey "${OUT_3}" "${ART_DIR_3}/keystore.txt")"
rc3=$?
assert_eq        "rc 0 on private-key fail"      "0"            "${rc3}"
assert_contains  "stdout risk=critical"          "risk=critical" "${out3}"
assert_contains  "finding category=secret_leak_private_key" "secret_leak_private_key" "$(cat "${OUT_3}")"
assert_eq        "fail_routing.action=halt"       "halt"         "$(read_nested_field "${OUT_3}" fail_routing action)"

# ── Case 4: generic api_key="…" hardcode → high / escalate ──────────────
echo "Case 4: hardcoded api_key='...' → result=fail risk=high escalate"
ART_DIR_4="${SANDBOX}/case4"
mkdir -p "${ART_DIR_4}"
cat > "${ART_DIR_4}/config.js" <<'EOF'
const config = {
  api_key: "abcdef0123456789ZZZZ",
  region: "us-east-1"
};
EOF
OUT_4="${ART_DIR_4}/api_scan.gate-result.json"
out4="$(run_gate scan_apikey "${OUT_4}" "${ART_DIR_4}/config.js")"
rc4=$?
assert_eq        "rc 0 on api_key fail"          "0"            "${rc4}"
assert_contains  "stdout result=fail"            "result=fail"            "${out4}"
assert_contains  "stdout risk=high"              "risk=high"              "${out4}"
assert_eq        "fail_routing.action=escalate (high but not critical)" "escalate" "$(read_nested_field "${OUT_4}" fail_routing action)"
assert_contains  "finding category=secret_leak_api_key" "secret_leak_api_key" "$(cat "${OUT_4}")"

# ── Case 5: dangerouslySetInnerHTML → high (xss_risk_react) ─────────────
echo "Case 5: dangerouslySetInnerHTML → result=fail risk=high (xss_risk_react)"
ART_DIR_5="${SANDBOX}/case5"
mkdir -p "${ART_DIR_5}"
cat > "${ART_DIR_5}/react_view.tsx" <<'EOF'
export const View = ({ html }) => (
  <div dangerouslySetInnerHTML={{ __html: html }} />
);
EOF
OUT_5="${ART_DIR_5}/xss_react.gate-result.json"
out5="$(run_gate scan_xss_react "${OUT_5}" "${ART_DIR_5}/react_view.tsx")"
rc5=$?
assert_eq        "rc 0 on xss_risk_react fail"   "0"            "${rc5}"
assert_contains  "stdout risk=high"              "risk=high"              "${out5}"
assert_contains  "finding category=xss_risk_react" "xss_risk_react"      "$(cat "${OUT_5}")"
assert_eq        "fail_routing.action=escalate"   "escalate"     "$(read_nested_field "${OUT_5}" fail_routing action)"

# ── Case 6: v-html directive → high (xss_risk_vue) ──────────────────────
echo "Case 6: v-html directive → result=fail risk=high (xss_risk_vue)"
ART_DIR_6="${SANDBOX}/case6"
mkdir -p "${ART_DIR_6}"
cat > "${ART_DIR_6}/vue_view.vue" <<'EOF'
<template>
  <div v-html="raw"></div>
</template>
EOF
OUT_6="${ART_DIR_6}/xss_vue.gate-result.json"
out6="$(run_gate scan_xss_vue "${OUT_6}" "${ART_DIR_6}/vue_view.vue")"
rc6=$?
assert_eq        "rc 0 on xss_risk_vue fail"     "0"            "${rc6}"
assert_contains  "stdout risk=high"              "risk=high"    "${out6}"
assert_contains  "finding category=xss_risk_vue" "xss_risk_vue" "$(cat "${OUT_6}")"

# ── Case 7: eval(...) → warn / medium ───────────────────────────────────
echo "Case 7: eval(...) → result=warn risk=medium (code_injection_risk_eval)"
ART_DIR_7="${SANDBOX}/case7"
mkdir -p "${ART_DIR_7}"
cat > "${ART_DIR_7}/eval_only.js" <<'EOF'
function compute(expr) {
  return eval(expr);
}
EOF
OUT_7="${ART_DIR_7}/eval_scan.gate-result.json"
out7="$(run_gate scan_eval "${OUT_7}" "${ART_DIR_7}/eval_only.js")"
rc7=$?
assert_eq        "rc 0 on eval warn"             "0"            "${rc7}"
assert_contains  "stdout result=warn"            "result=warn"  "${out7}"
assert_contains  "stdout risk=medium"            "risk=medium"  "${out7}"
assert_contains  "finding category=code_injection_risk_eval" "code_injection_risk_eval" "$(cat "${OUT_7}")"
# warn verdicts must NOT auto-populate fail_routing
if grep -qF '"fail_routing"' "${OUT_7}"; then
  echo "  FAIL: warn verdict unexpectedly produced fail_routing block"
  fail_count=$((fail_count + 1))
else
  echo "  PASS: warn verdict omits fail_routing"
  pass_count=$((pass_count + 1))
fi

# ── Case 8: missing target → blocked / halt ─────────────────────────────
echo "Case 8: missing artifact → result=blocked risk=high halt"
ART_DIR_8="${SANDBOX}/case8"
mkdir -p "${ART_DIR_8}"
echo "real" > "${ART_DIR_8}/present.py"
OUT_8="${ART_DIR_8}/missing_scan.gate-result.json"
out8="$(run_gate scan_missing "${OUT_8}" "${ART_DIR_8}/present.py" "${ART_DIR_8}/does-not-exist.py")"
rc8=$?
assert_eq        "rc 0 on blocked verdict"       "0"            "${rc8}"
assert_contains  "stdout result=blocked"         "result=blocked" "${out8}"
assert_contains  "stdout risk=high"              "risk=high"      "${out8}"
assert_eq        "fail_routing.action=halt"      "halt"           "$(read_nested_field "${OUT_8}" fail_routing action)"
assert_contains  "finding category=artifact_missing" "artifact_missing" "$(cat "${OUT_8}")"

# ── Case 9: empty file → pass with low finding ──────────────────────────
echo "Case 9: empty file → result=pass risk=low (security tolerates empty)"
ART_DIR_9="${SANDBOX}/case9"
mkdir -p "${ART_DIR_9}"
: > "${ART_DIR_9}/empty.py"
OUT_9="${ART_DIR_9}/empty_scan.gate-result.json"
out9="$(run_gate scan_empty "${OUT_9}" "${ART_DIR_9}/empty.py")"
rc9=$?
assert_eq        "rc 0 on empty-file pass+low"   "0"            "${rc9}"
assert_contains  "stdout result=pass"            "result=pass"  "${out9}"
assert_contains  "stdout risk=low"               "risk=low"     "${out9}"
assert_contains  "finding category=artifact_empty" "artifact_empty" "$(cat "${OUT_9}")"

# ── Case 10: no target_artifacts → blocked degenerate ───────────────────
echo "Case 10: empty target_artifacts → result=blocked"
ART_DIR_10="${SANDBOX}/case10"
mkdir -p "${ART_DIR_10}"
OUT_10="${ART_DIR_10}/empty_target.gate-result.json"
out10="$(cd "${REPO_ROOT}" && "${PYTHON_BIN}" "${STEP_PY}" run-security-gate \
  --gate-id "${GATE_ID}" --checkpoint "${CHECKPOINT}" \
  --workflow-id "${WORKFLOW_ID}" --run-id "${RUN_ID}" \
  --step-id scan_no_target --project-id "${PROJECT_ID}" \
  --output "${OUT_10}" 2>&1)"
rc10=$?
assert_eq        "rc 0 on degenerate blocked"    "0"            "${rc10}"
assert_contains  "stdout result=blocked"         "result=blocked" "${out10}"
assert_eq        "envelope target_artifacts=[]"   "[]"           "$(read_field "${OUT_10}" target_artifacts)"
assert_contains  "finding flags no_target_artifacts" "no_target_artifacts" "$(cat "${OUT_10}")"

# ── Case 11: default --output resolves to cwd ───────────────────────────
echo "Case 11: default --output resolves to cwd/<step_id>.gate-result.json"
ART_DIR_11="${SANDBOX}/case11"
mkdir -p "${ART_DIR_11}"
echo "x = 1" > "${ART_DIR_11}/only.py"
out11="$(cd "${ART_DIR_11}" && "${PYTHON_BIN}" "${STEP_PY}" run-security-gate \
  --gate-id "${GATE_ID}" --checkpoint final \
  --workflow-id "${WORKFLOW_ID}" --run-id "${RUN_ID}" \
  --step-id default_path_security --project-id "${PROJECT_ID}" \
  --target-artifact "${ART_DIR_11}/only.py" 2>&1)"
rc11=$?
DEFAULT_OUT="${ART_DIR_11}/default_path_security.gate-result.json"
assert_eq        "rc 0 default-path"             "0"            "${rc11}"
assert_eq        "default file written"          "yes"          "$([ -f "${DEFAULT_OUT}" ] && echo yes || echo no)"
assert_contains  "stdout path matches cwd default" "${DEFAULT_OUT}" "${out11}"

# ── Case 12: round-trip with validate-gate-result CLI ───────────────────
echo "Case 12: round-trip — every emitted envelope passes validate-gate-result CLI"
for envelope in "${OUT_1}" "${OUT_2}" "${OUT_3}" "${OUT_4}" "${OUT_5}" "${OUT_6}" "${OUT_7}" "${OUT_8}" "${OUT_9}" "${OUT_10}" "${DEFAULT_OUT}"; do
  out_v="$(cd "${REPO_ROOT}" && "${PYTHON_BIN}" "${STEP_PY}" validate-gate-result "${envelope}" 2>&1)"
  rc_v=$?
  assert_eq "rc 0 for $(basename "${envelope}")" "0" "${rc_v}"
  assert_contains "validator says ok for $(basename "${envelope}")" "reason=ok" "${out_v}"
done

# ── Case 13: --produced-by / --gate-subtype propagate ───────────────────
echo "Case 13: --produced-by / --gate-subtype propagate to envelope"
ART_DIR_13="${SANDBOX}/case13"
mkdir -p "${ART_DIR_13}"
echo "x" > "${ART_DIR_13}/x.py"
OUT_13="${ART_DIR_13}/custom.gate-result.json"
"${PYTHON_BIN}" "${STEP_PY}" run-security-gate \
  --gate-id custom_audit --checkpoint always_on \
  --workflow-id "${WORKFLOW_ID}" --run-id "${RUN_ID}" \
  --step-id custom_subtype_security --project-id "${PROJECT_ID}" \
  --target-artifact "${ART_DIR_13}/x.py" \
  --output "${OUT_13}" \
  --gate-subtype idor_scan \
  --produced-by 08-Security-StaticBuild >/dev/null 2>&1
assert_eq "envelope produced_by override"      "08-Security-StaticBuild" "$(read_field "${OUT_13}" produced_by)"
assert_eq "envelope gate_subtype override"     "idor_scan"               "$(read_field "${OUT_13}" gate_subtype)"

echo ""
echo "security-gate-runner: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
