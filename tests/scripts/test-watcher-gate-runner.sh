#!/usr/bin/env bash
#
# test-watcher-gate-runner.sh — P8 #2 watcher checkpoint runner contract.
#
# Verifies the engine/step_runtime.py run-watcher-gate subcommand acts as
# the first concrete producer for schemas/gate-result.schema.yaml. The gate
# is exercised against five distinct verdict shapes plus the round-trip
# integrity check that the emitted file is consumable by P8 #1's
# validate-gate-result CLI.
#
# Coverage:
#   1. All artifacts present + non-empty       → result=pass, risk=none, no findings
#   2. One artifact missing                    → result=blocked, risk=high, fail_routing.action=halt
#   3. One artifact empty                      → result=warn, risk=medium, finding category=artifact_empty
#   4. No --target-artifact given              → result=blocked (degenerate input)
#   5. Default --output path resolves to cwd   → ./<step_id>.gate-result.json written
#   6. Round-trip integrity: emit → validate-gate-result returns rc 0 reason=ok
#   7. Identity round-trip: stdout status line carries result + risk + path
#   8. Custom --produced-by / --gate-subtype propagate to envelope
#
# Boundary:
#   * This file pins the **runner contract**, not the underlying check
#     library; the check library is exercised in-process via the CLI to
#     match how cap-workflow-exec.sh will invoke it later. New mechanical
#     checks added under engine/watcher_gate_runner.py SHOULD bring their
#     own fixture cases here.

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

SANDBOX="$(mktemp -d -t cap-watcher-runner-test.XXXXXX)"
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

# Tiny jq-free JSON field extractor: relies on Python so we don't add
# a new dep. Returns the value at $2 (top-level key) inside the JSON
# envelope file at $1; prints "<absent>" if missing or unreadable so
# assertions fail loudly rather than silently match an empty string.
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

# Common identity used by every case; only the artifact list and step_id
# rotate per case so output paths are easy to inspect.
GATE_ID="spec_audit"
CHECKPOINT="spec_phase"
WORKFLOW_ID="project-spec-pipeline"
RUN_ID="run_20260505000000_aaaaaaaa"
PROJECT_ID="watcher-runner-test"

# ── Case 1: all artifacts present + non-empty → result=pass ─────────────
echo "Case 1: all-present artifacts → result=pass risk=none"
ART_DIR_1="${SANDBOX}/case1"
mkdir -p "${ART_DIR_1}"
echo "# BA spec body" > "${ART_DIR_1}/ba.md"
echo "# API spec body" > "${ART_DIR_1}/api.md"
OUT_1="${ART_DIR_1}/spec_audit.gate-result.json"
out1="$(cd "${REPO_ROOT}" && "${PYTHON_BIN}" "${STEP_PY}" run-watcher-gate \
  --gate-id "${GATE_ID}" \
  --checkpoint "${CHECKPOINT}" \
  --workflow-id "${WORKFLOW_ID}" \
  --run-id "${RUN_ID}" \
  --step-id spec_audit \
  --project-id "${PROJECT_ID}" \
  --target-artifact "${ART_DIR_1}/ba.md" \
  --target-artifact "${ART_DIR_1}/api.md" \
  --output "${OUT_1}" 2>&1)"
rc1=$?
assert_eq        "rc 0 on clean pass"           "0"            "${rc1}"
assert_contains  "stdout status=ok"             "status=ok"     "${out1}"
assert_contains  "stdout result=pass"           "result=pass"   "${out1}"
assert_contains  "stdout risk=none"             "risk=none"     "${out1}"
assert_eq        "envelope result=pass"          "pass"         "$(read_field "${OUT_1}" result)"
assert_eq        "envelope risk_level=none"      "none"         "$(read_field "${OUT_1}" risk_level)"
assert_eq        "envelope findings empty"       "[]"           "$(read_field "${OUT_1}" findings)"

# ── Case 2: one artifact missing → result=blocked ───────────────────────
echo "Case 2: one missing artifact → result=blocked risk=high fail_routing.action=halt"
ART_DIR_2="${SANDBOX}/case2"
mkdir -p "${ART_DIR_2}"
echo "# present" > "${ART_DIR_2}/present.md"
OUT_2="${ART_DIR_2}/missing_audit.gate-result.json"
out2="$(cd "${REPO_ROOT}" && "${PYTHON_BIN}" "${STEP_PY}" run-watcher-gate \
  --gate-id missing_audit \
  --checkpoint impl_phase \
  --workflow-id "${WORKFLOW_ID}" \
  --run-id "${RUN_ID}" \
  --step-id missing_audit \
  --project-id "${PROJECT_ID}" \
  --target-artifact "${ART_DIR_2}/present.md" \
  --target-artifact "${ART_DIR_2}/does-not-exist.md" \
  --output "${OUT_2}" 2>&1)"
rc2=$?
assert_eq        "rc 0 (runner exit 0 even when verdict=blocked)" "0" "${rc2}"
assert_contains  "stdout result=blocked"        "result=blocked"        "${out2}"
assert_contains  "stdout risk=high"             "risk=high"             "${out2}"
assert_eq        "envelope result=blocked"       "blocked"              "$(read_field "${OUT_2}" result)"
assert_eq        "envelope risk_level=high"      "high"                  "$(read_field "${OUT_2}" risk_level)"
assert_eq        "fail_routing.action=halt"      "halt"                  "$(read_nested_field "${OUT_2}" fail_routing action)"
assert_contains  "finding surfaces missing path" "does-not-exist.md"     "$(cat "${OUT_2}")"
assert_contains  "finding category=artifact_missing" "artifact_missing"  "$(cat "${OUT_2}")"

# ── Case 3: empty artifact → result=warn ────────────────────────────────
echo "Case 3: empty artifact → result=warn risk=medium category=artifact_empty"
ART_DIR_3="${SANDBOX}/case3"
mkdir -p "${ART_DIR_3}"
echo "# good" > "${ART_DIR_3}/good.md"
: > "${ART_DIR_3}/empty.md"  # touch then truncate
OUT_3="${ART_DIR_3}/empty_audit.gate-result.json"
out3="$(cd "${REPO_ROOT}" && "${PYTHON_BIN}" "${STEP_PY}" run-watcher-gate \
  --gate-id empty_audit \
  --checkpoint final \
  --workflow-id "${WORKFLOW_ID}" \
  --run-id "${RUN_ID}" \
  --step-id empty_audit \
  --project-id "${PROJECT_ID}" \
  --target-artifact "${ART_DIR_3}/good.md" \
  --target-artifact "${ART_DIR_3}/empty.md" \
  --output "${OUT_3}" 2>&1)"
rc3=$?
assert_eq        "rc 0 on warn verdict"          "0"            "${rc3}"
assert_contains  "stdout result=warn"           "result=warn"   "${out3}"
assert_contains  "stdout risk=medium"           "risk=medium"   "${out3}"
assert_eq        "envelope result=warn"          "warn"         "$(read_field "${OUT_3}" result)"
assert_eq        "envelope risk_level=medium"    "medium"        "$(read_field "${OUT_3}" risk_level)"
assert_contains  "finding category=artifact_empty" "artifact_empty" "$(cat "${OUT_3}")"
if grep -qF '"fail_routing"' "${OUT_3}"; then
  echo "  FAIL: warn verdict unexpectedly produced fail_routing block"
  fail_count=$((fail_count + 1))
else
  echo "  PASS: warn verdict omits fail_routing (consumer falls back to workflow YAML)"
  pass_count=$((pass_count + 1))
fi

# ── Case 4: no --target-artifact → result=blocked degenerate input ──────
echo "Case 4: empty target_artifacts → result=blocked"
ART_DIR_4="${SANDBOX}/case4"
mkdir -p "${ART_DIR_4}"
OUT_4="${ART_DIR_4}/empty_target.gate-result.json"
out4="$(cd "${REPO_ROOT}" && "${PYTHON_BIN}" "${STEP_PY}" run-watcher-gate \
  --gate-id empty_target \
  --checkpoint spec_phase \
  --workflow-id "${WORKFLOW_ID}" \
  --run-id "${RUN_ID}" \
  --step-id empty_target \
  --project-id "${PROJECT_ID}" \
  --output "${OUT_4}" 2>&1)"
rc4=$?
assert_eq        "rc 0 on degenerate-input blocked verdict" "0" "${rc4}"
assert_contains  "stdout result=blocked"      "result=blocked"           "${out4}"
assert_eq        "envelope target_artifacts=[]" "[]"                     "$(read_field "${OUT_4}" target_artifacts)"
assert_contains  "finding flags no_target_artifacts" "no_target_artifacts" "$(cat "${OUT_4}")"

# ── Case 5: default --output resolves to cwd/<step_id>.gate-result.json ─
echo "Case 5: default --output path resolves to cwd/<step_id>.gate-result.json"
ART_DIR_5="${SANDBOX}/case5"
mkdir -p "${ART_DIR_5}"
echo "# present" > "${ART_DIR_5}/only.md"
out5="$(cd "${ART_DIR_5}" && "${PYTHON_BIN}" "${STEP_PY}" run-watcher-gate \
  --gate-id default_path_audit \
  --checkpoint final \
  --workflow-id "${WORKFLOW_ID}" \
  --run-id "${RUN_ID}" \
  --step-id default_path_audit \
  --project-id "${PROJECT_ID}" \
  --target-artifact "${ART_DIR_5}/only.md" 2>&1)"
rc5=$?
DEFAULT_OUT="${ART_DIR_5}/default_path_audit.gate-result.json"
assert_eq        "rc 0 on default path"          "0"            "${rc5}"
assert_eq        "default file written"          "yes"          "$([ -f "${DEFAULT_OUT}" ] && echo yes || echo no)"
assert_contains  "stdout path matches cwd default" "${DEFAULT_OUT}" "${out5}"

# ── Case 6: round-trip with validate-gate-result CLI ────────────────────
echo "Case 6: round-trip — emitted file passes validate-gate-result CLI"
out6="$(cd "${REPO_ROOT}" && "${PYTHON_BIN}" "${STEP_PY}" validate-gate-result "${OUT_1}" 2>&1)"
rc6=$?
assert_eq        "rc 0 (case 1 envelope still valid)" "0"          "${rc6}"
assert_contains  "validator says ok"             "reason=ok"      "${out6}"
out6b="$(cd "${REPO_ROOT}" && "${PYTHON_BIN}" "${STEP_PY}" validate-gate-result "${OUT_2}" 2>&1)"
rc6b=$?
assert_eq        "rc 0 (case 2 envelope still valid)" "0"          "${rc6b}"
out6c="$(cd "${REPO_ROOT}" && "${PYTHON_BIN}" "${STEP_PY}" validate-gate-result "${OUT_3}" 2>&1)"
rc6c=$?
assert_eq        "rc 0 (case 3 envelope still valid)" "0"          "${rc6c}"
out6d="$(cd "${REPO_ROOT}" && "${PYTHON_BIN}" "${STEP_PY}" validate-gate-result "${OUT_4}" 2>&1)"
rc6d=$?
assert_eq        "rc 0 (case 4 envelope still valid)" "0"          "${rc6d}"

# ── Case 7: stdout status line shape ────────────────────────────────────
echo "Case 7: stdout status line carries result + risk + path"
assert_contains  "case 1 stdout has path="      "path="          "${out1}"
assert_contains  "case 2 stdout has path="      "path="          "${out2}"
assert_contains  "case 3 stdout has status=ok"  "status=ok"      "${out3}"

# ── Case 8: --produced-by / --gate-subtype propagation ──────────────────
echo "Case 8: custom --produced-by and --gate-subtype propagate to envelope"
ART_DIR_8="${SANDBOX}/case8"
mkdir -p "${ART_DIR_8}"
echo "# x" > "${ART_DIR_8}/x.md"
OUT_8="${ART_DIR_8}/custom.gate-result.json"
"${PYTHON_BIN}" "${STEP_PY}" run-watcher-gate \
  --gate-id custom_subtype_audit \
  --checkpoint always_on \
  --workflow-id "${WORKFLOW_ID}" \
  --run-id "${RUN_ID}" \
  --step-id custom_subtype_audit \
  --project-id "${PROJECT_ID}" \
  --target-artifact "${ART_DIR_8}/x.md" \
  --output "${OUT_8}" \
  --gate-subtype framework_strategy_audit \
  --produced-by 90-Watcher-CustomBuild >/dev/null 2>&1
assert_eq "envelope produced_by override"      "90-Watcher-CustomBuild"     "$(read_field "${OUT_8}" produced_by)"
assert_eq "envelope gate_subtype override"     "framework_strategy_audit"   "$(read_field "${OUT_8}" gate_subtype)"

echo ""
echo "watcher-gate-runner: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
