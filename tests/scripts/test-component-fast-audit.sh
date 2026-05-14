#!/usr/bin/env bash
#
# test-component-fast-audit.sh — P1b slice 4 gate.
#
# Renders the feedback-widget catalog once into a sandbox, then
# clones the rendered tree per case and mutates it to exercise each
# failure mode the audit script must catch.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RENDER="${REPO_ROOT}/scripts/workflows/component-fast-render.sh"
AUDIT="${REPO_ROOT}/scripts/workflows/component-fast-audit.sh"

[ -x "${RENDER}" ] || { echo "FAIL: ${RENDER} not executable"; exit 1; }
[ -x "${AUDIT}" ]  || { echo "FAIL: ${AUDIT} not executable";  exit 1; }

SANDBOX="$(mktemp -d -t cap-audit-test.XXXXXX)"
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

# Render the canonical fixture once; each case clones from this base.
BASE_PROJECT="${SANDBOX}/base"
bash "${RENDER}" \
  --component-type feedback-widget \
  --project-id component-feedback-widget \
  --project-root "${BASE_PROJECT}" >/dev/null

# Per-case clone helper.
clone_base() {
  local target="$1"
  cp -R "${BASE_PROJECT}" "${target}"
}

# ── Case 1: happy path → exit 0, condition: ok ───────────────────────
echo "Case 1: happy path passes audit"
out1="$(bash "${AUDIT}" \
  --component-type feedback-widget \
  --project-root "${BASE_PROJECT}" 2>&1)"
rc1=$?
assert_eq        "audit exit 0 on happy path"   "0"                          "${rc1}"
assert_contains "summary condition: ok"          "${out1}"  "condition: ok"
assert_contains "summary rendered_files_checked" "${out1}"  "rendered_files_checked: 23"
assert_contains "summary result: success"        "${out1}"  "result: success"

# ── Case 2: missing required file ────────────────────────────────────
echo ""
echo "Case 2: missing required file fails audit"
DIR2="${SANDBOX}/case2-missing"
clone_base "${DIR2}"
rm "${DIR2}/backend/Feedback/Program.cs"
out2="$(bash "${AUDIT}" \
  --component-type feedback-widget \
  --project-root "${DIR2}" 2>&1)"
rc2=$?
assert_eq        "audit exit 5 on missing file"  "5"                                       "${rc2}"
assert_contains "summary condition fail"          "${out2}"  "condition: component_fast_audit_failed"
assert_contains "summary result: failed"          "${out2}"  "result: failed"
assert_contains "failure mentions Program.cs"     "${out2}"  "Program.cs"
assert_contains "failure mentions 'missing'"      "${out2}"  "missing"

# ── Case 3: forbidden term 'redis' ───────────────────────────────────
echo ""
echo "Case 3: forbidden term 'redis' fails audit"
DIR3="${SANDBOX}/case3-redis"
clone_base "${DIR3}"
echo "# uses redis" >> "${DIR3}/.env.example"
out3="$(bash "${AUDIT}" \
  --component-type feedback-widget \
  --project-root "${DIR3}" 2>&1)"
rc3=$?
assert_eq        "audit exit 5 on forbidden term"      "5"                          "${rc3}"
assert_contains "forbidden_term failure shows term"    "${out3}"  "forbidden_term 'redis'"
assert_contains "forbidden_term failure shows file"    "${out3}"  ".env.example"

# ── Case 4: UI adapter leaks into lib/feedback (lucide) ──────────────
echo ""
echo "Case 4: forbidden_core_import_pattern violation fails audit"
DIR4="${SANDBOX}/case4-lucide"
clone_base "${DIR4}"
echo "import { Star } from 'lucide-react';" >> "${DIR4}/frontend/lib/feedback/types.ts"
out4="$(bash "${AUDIT}" \
  --component-type feedback-widget \
  --project-root "${DIR4}" 2>&1)"
rc4=$?
assert_eq        "audit exit 5 on core import leak"        "5"                                      "${rc4}"
assert_contains "core import pattern failure header"        "${out4}"  "forbidden_core_import_pattern"
assert_contains "core import failure names the file"        "${out4}"  "frontend/lib/feedback/types.ts"
assert_contains "core import failure names the term"        "${out4}"  "lucide"

# ── Case 5: executable bit stripped from runtime-smoke.sh ────────────
echo ""
echo "Case 5: missing executable bit on runtime-smoke.sh fails audit"
DIR5="${SANDBOX}/case5-no-exec"
clone_base "${DIR5}"
chmod a-x "${DIR5}/scripts/runtime-smoke.sh"
out5="$(bash "${AUDIT}" \
  --component-type feedback-widget \
  --project-root "${DIR5}" 2>&1)"
rc5=$?
assert_eq        "audit exit 5 on missing +x"        "5"                                  "${rc5}"
assert_contains "exec failure names smoke script"     "${out5}"  "scripts/runtime-smoke.sh"
assert_contains "exec failure mentions executable"    "${out5}"  "executable"

# ── Case 6: hardcoded env-driven port in docker-compose.yml ──────────
echo ""
echo "Case 6: hardcoded env-driven port (8080:8080) fails audit"
DIR6="${SANDBOX}/case6-hardcoded-port"
clone_base "${DIR6}"
python3 - "${DIR6}/docker-compose.yml" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
# Replace the backend service's env-driven port with a hardcoded pair.
text = text.replace(
    '"${BACKEND_PORT:-8080}:${BACKEND_PORT:-8080}"',
    '"8080:8080"',
)
open(path, "w", encoding="utf-8").write(text)
PY
out6="$(bash "${AUDIT}" \
  --component-type feedback-widget \
  --project-root "${DIR6}" 2>&1)"
rc6=$?
assert_eq        "audit exit 5 on hardcoded env-driven port"  "5"                            "${rc6}"
assert_contains "hardcoded-port failure mentions service"      "${out6}"  "service 'backend'"
assert_contains "hardcoded-port failure mentions the pair"     "${out6}"  "8080:8080"
assert_contains "hardcoded-port failure mentions env hint"     "${out6}"  "env-driven"

# ── Case 7: missing required arg → exit 2 ────────────────────────────
echo ""
echo "Case 7: missing --project-root → exit 2"
out7="$(bash "${AUDIT}" --component-type feedback-widget 2>&1)"
rc7=$?
assert_eq        "audit exit 2 on missing --project-root"   "2"                              "${rc7}"
assert_contains "arg error mentions --project-root"          "${out7}"  "--project-root required"

# ── Case 8: registry not found → exit 3 ──────────────────────────────
echo ""
echo "Case 8: unknown component_type → exit 3"
out8="$(bash "${AUDIT}" \
  --component-type does-not-exist \
  --project-root "${BASE_PROJECT}" 2>&1)"
rc8=$?
assert_eq        "audit exit 3 on missing registry"   "3"                              "${rc8}"
assert_contains "registry-not-found error message"     "${out8}"  "registry not found"

echo ""
total=$((pass_count + fail_count))
echo "component-fast-audit: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
