#!/usr/bin/env bash
#
# test-design-source-resolution.sh — Smoke test for the design source
# resolution chain introduced in v0.20.x.
#
# Covers:
#   A. ~/.cap/designs/ absent or empty            → engine falls back to legacy
#   B. Exactly one package present                 → auto-select picks it
#   C. Multiple packages, non-interactive          → halt with clear error
#   D. Multiple packages, --design-package <name>  → explicit pick succeeds
#   E. Multiple packages, --design-package missing → halt listing candidates
#   F. constitution.design_source.source_path set  → engine resolves via that
#   G. constitution.design_source.type == none     → engine falls back to legacy
#   H. constitution.design_source.{root, package}  → engine joins them
#
# A-E exercise engine/design_prompt.py (workflow prompt augmentation entry).
# F-H exercise engine/step_runtime.py _design_source_path (workflow runtime
# resolution entry). Both must agree on the same constitution semantics.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DESIGN_PROMPT="${REPO_ROOT}/engine/design_prompt.py"
TEMPLATES="${REPO_ROOT}/schemas/design-source-templates.yaml"

[ -f "${DESIGN_PROMPT}" ] || { echo "FAIL: design_prompt.py missing"; exit 1; }
[ -f "${TEMPLATES}" ]     || { echo "FAIL: templates missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-design-test.XXXXXX)"
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
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected to contain: ${needle}"
    echo "    actual: ${haystack}"
    fail_count=$((fail_count + 1))
  fi
}

run_augment() {
  local extra_args="$1"
  HOME="${SANDBOX}/home" python3 "${DESIGN_PROMPT}" augment \
    --templates "${TEMPLATES}" \
    --workflow-id project-constitution \
    --prompt 'test' ${extra_args} < /dev/null 2>&1
}

# ─────────────────────────────────────────────────────────
# A. designs registry absent or empty
# ─────────────────────────────────────────────────────────

echo "Case A: designs registry empty / missing"
mkdir -p "${SANDBOX}/home"
out="$(run_augment "")"
assert_contains "fallback to no-design when registry missing" "非互動環境且未指定 --design-source" "${out}"

# ─────────────────────────────────────────────────────────
# B. Exactly one package — auto-select
# ─────────────────────────────────────────────────────────

echo "Case B: exactly one package → auto-select"
mkdir -p "${SANDBOX}/home/.cap/designs/single-pkg/project"
echo "<html></html>" > "${SANDBOX}/home/.cap/designs/single-pkg/project/main.html"
out="$(run_augment "")"
assert_contains "auto-pick path renders" "design_snapshot_path: ~/.cap/designs/single-pkg" "${out}"
assert_contains "auto-pick package name renders" "design_package_name: single-pkg" "${out}"
assert_contains "constitution block templated for the package" "package: single-pkg" "${out}"

# ─────────────────────────────────────────────────────────
# C-E. Multiple packages
# ─────────────────────────────────────────────────────────

echo "Case C: multiple packages, non-interactive → no design fallback"
mkdir -p "${SANDBOX}/home/.cap/designs/pkg-a/project"
echo "<html></html>" > "${SANDBOX}/home/.cap/designs/pkg-a/project/main.html"
mkdir -p "${SANDBOX}/home/.cap/designs/pkg-b/project"
echo "<html></html>" > "${SANDBOX}/home/.cap/designs/pkg-b/project/main.html"
out="$(run_augment "")"
assert_contains "multi-package non-interactive falls back to no-design" "非互動環境且未指定 --design-source" "${out}"

echo "Case D: multiple packages, explicit --design-package pkg-a"
out="$(run_augment "--design-package pkg-a")"
assert_contains "explicit selection renders pkg-a path" "design_snapshot_path: ~/.cap/designs/pkg-a" "${out}"
assert_contains "explicit selection records package name" "package: pkg-a" "${out}"
out_b="$(run_augment "--design-package pkg-b")"
assert_contains "explicit selection renders pkg-b path" "design_snapshot_path: ~/.cap/designs/pkg-b" "${out_b}"

echo "Case E: multiple packages, --design-package <missing>"
out="$(run_augment "--design-package non-existent-pkg")"
assert_contains "missing package name surfaces in stderr" "not found under" "${out}"
assert_contains "available packages listed in stderr" "pkg-a" "${out}"
assert_contains "available packages listed in stderr (b)" "pkg-b" "${out}"

# ─────────────────────────────────────────────────────────
# F-H. step_runtime _design_source_path constitution resolution
# ─────────────────────────────────────────────────────────

cleanup_workdir() { cd "${REPO_ROOT}"; }
trap 'cleanup_workdir; rm -rf "${SANDBOX}"' EXIT

run_resolve() {
  cd "${SANDBOX}/work"
  python3 -c "
import sys
sys.path.insert(0, '${REPO_ROOT}/engine')
import step_runtime
print(step_runtime._design_source_path())
" 2>&1
  cleanup_workdir
}

mkdir -p "${SANDBOX}/work"

echo "Case F: constitution.design_source.source_path set"
cat > "${SANDBOX}/work/.cap.constitution.yaml" <<EOF
design_source:
  type: local_design_package
  source_path: /tmp/explicit-design-source
EOF
out="$(run_resolve)"
assert_contains "explicit source_path resolved" "/tmp/explicit-design-source" "${out}"

echo "Case G: constitution.design_source.type == none → fallback"
cat > "${SANDBOX}/work/.cap.constitution.yaml" <<EOF
design_source:
  type: none
EOF
out="$(run_resolve)"
assert_contains "type none falls back to ~/.cap/designs" ".cap/designs" "${out}"

echo "Case H: design_root + package join"
cat > "${SANDBOX}/work/.cap.constitution.yaml" <<EOF
design_source:
  type: local_design_package
  design_root: /tmp/registry
  package: derived
EOF
out="$(run_resolve)"
assert_contains "root + package joined to /tmp/registry/derived" "/tmp/registry/derived" "${out}"

echo "Case I: no constitution at all → fallback"
rm -f "${SANDBOX}/work/.cap.constitution.yaml"
out="$(run_resolve)"
assert_contains "no constitution falls back to ~/.cap/designs" ".cap/designs" "${out}"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ ${fail_count} -eq 0 ]
