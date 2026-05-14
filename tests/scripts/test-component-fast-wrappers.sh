#!/usr/bin/env bash
#
# test-component-fast-wrappers.sh — P1b slice 6a gate.
#
# Validates the two workflow wrappers slice 5 referenced but did not
# create:
#   scripts/workflows/component-fast-resolve.sh
#   scripts/workflows/component-fast-smoke.sh
#
# This test is intentionally deterministic — it stubs the rendered
# smoke script so docker is never invoked. The full compose-up smoke
# is exercised only at workflow-run time (slice 6b dogfood), not
# inside this gate.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RESOLVE="${REPO_ROOT}/scripts/workflows/component-fast-resolve.sh"
SMOKE="${REPO_ROOT}/scripts/workflows/component-fast-smoke.sh"

[ -f "${RESOLVE}" ] || { echo "FAIL: ${RESOLVE} missing"; exit 1; }
[ -f "${SMOKE}" ]   || { echo "FAIL: ${SMOKE} missing";   exit 1; }

SANDBOX="$(mktemp -d -t cap-wrappers-test.XXXXXX)"
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

# ── Case 1: both wrappers exist + executable ─────────────────────────
echo "Case 1: both wrappers exist + have executable bit"
for path in "${RESOLVE}" "${SMOKE}"; do
  if [ -x "${path}" ]; then
    echo "  PASS: ${path} executable"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${path} NOT executable"
    fail_count=$((fail_count + 1))
  fi
done

# ── Case 2: resolve happy path exits 0 + emits resolved tokens ───────
echo ""
echo "Case 2: resolve --component-type feedback-widget happy path"
out2="$(bash "${RESOLVE}" \
  --component-type feedback-widget \
  --project-id component-feedback-widget \
  --project-root "${SANDBOX}/proj" 2>&1)"
rc2=$?
assert_eq        "resolve exit 0 on valid inputs"          "0"                                            "${rc2}"
assert_contains "resolve emits condition: ok"               "${out2}"  "condition: ok"
assert_contains "resolve emits result: success"             "${out2}"  "result: success"
assert_contains "resolve echoes component_type"             "${out2}"  "component_type: feedback-widget"
assert_contains "resolve echoes project_id"                 "${out2}"  "project_id: component-feedback-widget"
assert_contains "resolve derives PROJECT_NAME_PASCAL"       "${out2}"  "project_name_pascal: ComponentFeedbackWidget"
assert_contains "resolve derives STORE_DEFAULT"             "${out2}"  "store_default: InMemoryFeedbackStore"
assert_contains "resolve emits api_base_url default"        "${out2}"  "api_base_url: http://localhost:8080"
assert_contains "resolve echoes hard_exclusions"            "${out2}"  "hard_exclusions: redis"
assert_contains "resolve echoes catalog_count"              "${out2}"  "catalog_count: 23"

# ── Case 3: resolve rejects unknown component type with exit 3 ───────
echo ""
echo "Case 3: resolve --component-type unknown-thing fails with exit 3"
out3="$(bash "${RESOLVE}" \
  --component-type unknown-thing \
  --project-id component-feedback-widget \
  --project-root "${SANDBOX}/proj" 2>&1)"
rc3=$?
assert_eq        "resolve exit 3 on missing registry"  "3"                                "${rc3}"
assert_contains "resolve error names the registry"      "${out3}"  "registry not found"

# Also confirm the standard arg/value checks land at exit 2.
echo ""
echo "Case 3b: resolve rejects missing required flag with exit 2"
out3b="$(bash "${RESOLVE}" \
  --component-type feedback-widget \
  --project-root "${SANDBOX}/proj" 2>&1)"
rc3b=$?
assert_eq        "resolve exit 2 on missing --project-id"  "2"                          "${rc3b}"
assert_contains "resolve error mentions --project-id"       "${out3b}"  "--project-id required"

echo ""
echo "Case 3c: resolve rejects non-kebab project_id with exit 2"
out3c="$(bash "${RESOLVE}" \
  --component-type feedback-widget \
  --project-id NotKebabCase \
  --project-root "${SANDBOX}/proj" 2>&1)"
rc3c=$?
assert_eq        "resolve exit 2 on non-kebab project_id"  "2"                          "${rc3c}"
assert_contains "resolve error mentions kebab-case"         "${out3c}"  "kebab-case"

# ── Case 4: smoke fails when project_root lacks runtime-smoke.sh ────
echo ""
echo "Case 4: smoke fails clearly when scripts/runtime-smoke.sh is missing"
PROJ_NO_SMOKE="${SANDBOX}/no-smoke"
mkdir -p "${PROJ_NO_SMOKE}"
out4="$(bash "${SMOKE}" --project-root "${PROJ_NO_SMOKE}" 2>&1)"
rc4=$?
assert_eq        "smoke exit 4 when smoke missing"          "4"                                       "${rc4}"
assert_contains "smoke error names the missing path"        "${out4}"  "rendered smoke script missing"
assert_contains "smoke emits component_fast_smoke_failed"   "${out4}"  "condition: component_fast_smoke_failed"
assert_contains "smoke emits result: failed"                 "${out4}"  "result: failed"

echo ""
echo "Case 4b: smoke fails when --project-root not a directory"
out4b="$(bash "${SMOKE}" --project-root "${SANDBOX}/does-not-exist" 2>&1)"
rc4b=$?
assert_eq        "smoke exit 2 when project_root missing"         "2"                              "${rc4b}"
assert_contains "smoke error mentions not a directory"             "${out4b}"  "not a directory"

echo ""
echo "Case 4c: smoke rejects when smoke script not executable (chmod -x)"
PROJ_NOEXEC="${SANDBOX}/no-exec"
mkdir -p "${PROJ_NOEXEC}/scripts"
echo "exit 0" > "${PROJ_NOEXEC}/scripts/runtime-smoke.sh"
chmod a-x "${PROJ_NOEXEC}/scripts/runtime-smoke.sh"
out4c="$(bash "${SMOKE}" --project-root "${PROJ_NOEXEC}" 2>&1)"
rc4c=$?
assert_eq        "smoke exit 4 when smoke not +x"           "4"                                       "${rc4c}"
assert_contains "smoke error mentions not executable"        "${out4c}"  "not executable"

# ── Case 5: smoke cd's to project_root + forwards exit code ─────────
#
# Two sub-cases share the same fake smoke pattern: each fake asserts
# its working directory matches the project root by listing a file
# the wrapper expects (scripts/runtime-smoke.sh itself). If the
# wrapper did not cd, `ls` would fail and the fake would exit 99
# instead of the intended code (0 / 7).
echo ""
echo "Case 5a: fake smoke exit 0 → wrapper exits 0 and forwards summary"
PROJ_OK="${SANDBOX}/ok"
mkdir -p "${PROJ_OK}/scripts"
cat > "${PROJ_OK}/scripts/runtime-smoke.sh" <<'EOF'
#!/usr/bin/env bash
# Wrapper must cd into project_root before exec'ing this — if PWD
# does not contain scripts/runtime-smoke.sh, fail with exit 99 so
# the test can detect the missing cd separately from a real probe
# failure.
test -f scripts/runtime-smoke.sh || exit 99
echo "fake smoke ran from cwd=${PWD}"
exit 0
EOF
chmod +x "${PROJ_OK}/scripts/runtime-smoke.sh"
out5a="$(bash "${SMOKE}" --project-root "${PROJ_OK}" 2>&1)"
rc5a=$?
assert_eq        "smoke exit 0 when fake smoke succeeded"         "0"                              "${rc5a}"
assert_contains "wrapper emits result: success"                    "${out5a}"  "result: success"
assert_contains "wrapper emits smoke_exit_code: 0"                 "${out5a}"  "smoke_exit_code: 0"
assert_contains "fake smoke confirms it saw scripts/runtime-smoke.sh" "${out5a}" "fake smoke ran from cwd="
# rc=99 would mean cd never happened; we already asserted rc=0 above,
# but echo the wrapper's emitted project_root path so a future failure
# is easy to read.
assert_contains "wrapper echoes project_root in summary"           "${out5a}"  "project_root: ${PROJ_OK}"

echo ""
echo "Case 5b: fake smoke exit 7 → wrapper exits 7 (exit code forwarded)"
PROJ_FAIL="${SANDBOX}/fail"
mkdir -p "${PROJ_FAIL}/scripts"
cat > "${PROJ_FAIL}/scripts/runtime-smoke.sh" <<'EOF'
#!/usr/bin/env bash
test -f scripts/runtime-smoke.sh || exit 99
echo "fake smoke about to fail with rc=7" >&2
exit 7
EOF
chmod +x "${PROJ_FAIL}/scripts/runtime-smoke.sh"
out5b="$(bash "${SMOKE}" --project-root "${PROJ_FAIL}" 2>&1)"
rc5b=$?
assert_eq        "smoke wrapper forwards rc=7 unchanged"          "7"                              "${rc5b}"
assert_contains "wrapper emits result: failed"                     "${out5b}"  "result: failed"
assert_contains "wrapper emits smoke_exit_code: 7"                 "${out5b}"  "smoke_exit_code: 7"
assert_contains "wrapper emits condition: component_fast_smoke_failed" "${out5b}" "condition: component_fast_smoke_failed"

# ── Case 6: no Claude / Codex / ~/.cap state dependency ──────────────
#
# A hostile audit of the wrapper source: if either script grew an AI
# provider call, a ~/.cap state read, or a claude/codex CLI shell-out,
# slice 6a's "deterministic, no quota" guarantee silently breaks.
# This case scans the source for those substrings (case-insensitive).
echo ""
echo "Case 6: wrappers do not reference Claude / Codex / CAP runtime state"
for path in "${RESOLVE}" "${SMOKE}"; do
  hits="$(grep -iE 'claude|codex|cap_home|CAP_HOME|\.cap/' "${path}" || true)"
  if [ -z "${hits}" ]; then
    echo "  PASS: $(basename "${path}") has no Claude/Codex/.cap references"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: $(basename "${path}") references AI / cap-state surface:"
    echo "${hits}" | sed 's/^/    /'
    fail_count=$((fail_count + 1))
  fi
done

echo ""
total=$((pass_count + fail_count))
echo "component-fast-wrappers: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
