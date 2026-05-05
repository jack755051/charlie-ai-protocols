#!/usr/bin/env bash
#
# test-cap-session-native-fallback.sh — P0b Provider Isolation regression.
#
# Explicit `cap claude` / `cap codex` should be CAP-managed only when a
# stable CAP project identity is available. In a plain non-git directory with
# no .cap.project.yaml and no CAP_PROJECT_ID_OVERRIDE, the wrapper must fall
# back to the native provider instead of surfacing cap-paths strict resolver
# errors.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CAP_ENTRY="${REPO_ROOT}/scripts/cap-entry.sh"

[ -f "${CAP_ENTRY}" ] || { echo "FAIL: scripts/cap-entry.sh missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-session-fallback.XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

BIN_DIR="${SANDBOX}/bin"
mkdir -p "${BIN_DIR}"

cat > "${BIN_DIR}/claude" <<'EOF'
#!/usr/bin/env bash
echo "native-claude:$*"
EOF
chmod +x "${BIN_DIR}/claude"

cat > "${BIN_DIR}/codex" <<'EOF'
#!/usr/bin/env bash
echo "native-codex:$*"
EOF
chmod +x "${BIN_DIR}/codex"

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
    echo "    actual: ${haystack}"
    fail_count=$((fail_count + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    echo "  FAIL: ${desc}"
    echo "    unexpected substring: ${needle}"
    echo "    actual: ${haystack}"
    fail_count=$((fail_count + 1))
  else
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  fi
}

assert_absent() {
  local desc="$1" path="$2"
  if [ ! -e "${path}" ]; then
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    must not exist: ${path}"
    fail_count=$((fail_count + 1))
  fi
}

run_from_dir() {
  local dir="$1"
  local cap_home="$2"
  local subcommand="$3"
  shift 3

  (
    cd "${dir}" || exit 99
    PATH="${BIN_DIR}:${PATH}" HOME="${SANDBOX}/home" CAP_HOME="${cap_home}" \
      bash "${CAP_ENTRY}" "${subcommand}" "$@"
  ) 2>&1
}

PLAIN_DIR="${SANDBOX}/plain"
mkdir -p "${PLAIN_DIR}" "${SANDBOX}/home"

echo "Case 1: cap claude outside any CAP project falls back to native claude"
out1="$(run_from_dir "${PLAIN_DIR}" "${SANDBOX}/cap-home-1" claude --version)"
rc1=$?
assert_eq "claude fallback exits 0" "0" "${rc1}"
assert_contains "native claude invoked" "native-claude:--version" "${out1}"
assert_contains "fallback message printed" "no CAP project detected; launching native claude" "${out1}"
assert_not_contains "cap-paths strict error hidden" "cap-paths: error" "${out1}"
assert_absent "fallback does not create CAP project store" "${SANDBOX}/cap-home-1/projects"

echo "Case 2: cap codex outside any CAP project falls back to native codex"
out2="$(run_from_dir "${PLAIN_DIR}" "${SANDBOX}/cap-home-2" codex --version)"
rc2=$?
assert_eq "codex fallback exits 0" "0" "${rc2}"
assert_contains "native codex invoked" "native-codex:--version" "${out2}"
assert_contains "fallback message printed" "no CAP project detected; launching native codex" "${out2}"
assert_not_contains "cap-paths strict error hidden" "cap-paths: error" "${out2}"
assert_absent "fallback does not create CAP project store" "${SANDBOX}/cap-home-2/projects"

echo "Case 3: CAP_PROJECT_ID_OVERRIDE preserves CAP-managed trace path"
out3="$(
  cd "${PLAIN_DIR}" || exit 99
  PATH="${BIN_DIR}:${PATH}" HOME="${SANDBOX}/home" CAP_HOME="${SANDBOX}/cap-home-3" \
    CAP_PROJECT_ID_OVERRIDE="fallback-test" bash "${CAP_ENTRY}" claude --print-ok
) 2>&1"
rc3=$?
assert_eq "override path exits 0" "0" "${rc3}"
assert_contains "native provider still invoked after trace" "native-claude:--print-ok" "${out3}"
assert_not_contains "override path does not fallback" "no CAP project detected" "${out3}"
assert_contains "trace project store created" "fallback-test" "$(find "${SANDBOX}/cap-home-3/projects" -maxdepth 2 -type d 2>/dev/null | sort)"

echo ""
if [ "${fail_count}" -eq 0 ]; then
  echo "cap-session-native-fallback: ${pass_count} passed, 0 failed"
  exit 0
fi

echo "cap-session-native-fallback: ${pass_count} passed, ${fail_count} failed"
exit 1
