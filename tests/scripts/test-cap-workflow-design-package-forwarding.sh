#!/usr/bin/env bash
#
# test-cap-workflow-design-package-forwarding.sh — Wrapper-layer smoke test
# verifying that scripts/cap-workflow.sh forwards --design-package <name> all
# the way to engine/design_prompt.py via the design augmentation step.
#
# Strategy:
#   - Stand up a sandbox HOME with two packages under ~/.cap/designs so the
#     scenario actually requires explicit selection.
#   - Override PATH so a fake python3 wrapper script intercepts every python3
#     invocation, logs the full argv to a sandbox file, and forwards to the
#     real interpreter so cap-workflow.sh keeps working.
#   - Run cap-workflow.sh run --design-package pkg-a <workflow> "..." in a
#     mode where the augment step is exercised.
#   - grep the log for the design_prompt augment invocation and assert it
#     contains --design-package pkg-a.
#
# This proves the wrapper reaches design_prompt.py with the explicit
# selection regardless of TTY state, closing the gap from v0.20.0 where only
# the engine learned about --design-package.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WRAPPER="${REPO_ROOT}/scripts/cap-workflow.sh"

[ -f "${WRAPPER}" ] || { echo "FAIL: cap-workflow.sh not found"; exit 1; }

SANDBOX="$(mktemp -d -t cap-wf-design-pkg.XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

mkdir -p "${SANDBOX}/home/.cap/designs/pkg-a/project"
mkdir -p "${SANDBOX}/home/.cap/designs/pkg-b/project"
echo "<html></html>" > "${SANDBOX}/home/.cap/designs/pkg-a/project/main.html"
echo "<html></html>" > "${SANDBOX}/home/.cap/designs/pkg-b/project/main.html"

# Real python3 path (so the fake wrapper can forward to it)
REAL_PY3="$(command -v python3)"
[ -x "${REAL_PY3}" ] || { echo "FAIL: python3 not on PATH"; exit 1; }

# Build a fake python3 that logs argv and forwards to real python3
mkdir -p "${SANDBOX}/bin"
LOG_FILE="${SANDBOX}/python-calls.log"
cat > "${SANDBOX}/bin/python3" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${LOG_FILE}"
exec "${REAL_PY3}" "\$@"
EOF
chmod +x "${SANDBOX}/bin/python3"

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

assert_log_contains() {
  local desc="$1" needle="$2"
  if grep -qF -- "${needle}" "${LOG_FILE}" 2>/dev/null; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected log to contain: ${needle}"
    echo "    log content:"
    sed 's/^/      /' "${LOG_FILE}" 2>/dev/null | head -10
    fail_count=$((fail_count + 1))
  fi
}

# Case 1: usage line lists --design-package
echo "Case 1: usage line lists --design-package"
usage_out="$(bash "${WRAPPER}" run 2>&1 || true)"
case "${usage_out}" in
  *"--design-package"*) echo "  PASS: usage line includes --design-package"; pass_count=$((pass_count + 1)) ;;
  *)
    echo "  FAIL: usage line missing --design-package"
    echo "    actual: ${usage_out}"
    fail_count=$((fail_count + 1))
    ;;
esac

# Case 2: wrapper accepts --design-package as a recognized flag (does not
# leave it on the positional arg list, does not error out)
echo "Case 2: wrapper accepts --design-package without 'unknown option' error"
out_2="$(bash "${WRAPPER}" run --design-package pkg-a 2>&1 || true)"
case "${out_2}" in
  *"unknown option"*|*"invalid option"*|*"--design-package: command not found"*)
    echo "  FAIL: wrapper rejected --design-package as unknown"
    echo "    actual: ${out_2}"
    fail_count=$((fail_count + 1))
    ;;
  *)
    echo "  PASS: wrapper accepted --design-package as recognized flag"
    pass_count=$((pass_count + 1))
    ;;
esac

# Case 3: wrapper forwards --design-package to design_prompt.py augment.
# We invoke a workflow id that exercises design augment (project-constitution)
# and then halt early via a non-existent prompt-stdin pipe; what we care about
# is the python3 invocation log having seen --design-package pkg-a in the
# augment arg list.
echo "Case 3: --design-package pkg-a forwards to design_prompt.py augment"
> "${LOG_FILE}"
HOME="${SANDBOX}/home" \
PATH="${SANDBOX}/bin:${PATH}" \
bash "${WRAPPER}" run --dry-run --design-package pkg-a project-constitution "test" \
  > "${SANDBOX}/run-3.out" 2>&1 || true
assert_log_contains "log captured a python3 invocation" "design_prompt.py"
assert_log_contains "augment invocation forwards --design-package" "--design-package pkg-a"

# Case 4: --design-package is the BIND value, not the next positional. Try a
# different package value to make sure the wrapper does not hard-code pkg-a.
echo "Case 4: --design-package pkg-b forwards correctly (no hard-coding)"
> "${LOG_FILE}"
HOME="${SANDBOX}/home" \
PATH="${SANDBOX}/bin:${PATH}" \
bash "${WRAPPER}" run --dry-run --design-package pkg-b project-constitution "test" \
  > "${SANDBOX}/run-4.out" 2>&1 || true
assert_log_contains "augment invocation forwards --design-package pkg-b" "--design-package pkg-b"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ ${fail_count} -eq 0 ]
