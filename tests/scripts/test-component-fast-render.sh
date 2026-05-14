#!/usr/bin/env bash
#
# test-component-fast-render.sh — P1b slice 3 gate.
#
# Renders the feedback-widget catalog into a sandbox project root
# and asserts the contract:
#   * machine-readable summary line shape;
#   * every catalog target exists, non-empty, no ${CAP_TOKEN} residue;
#   * `executable: true` entries actually have +x;
#   * `hard_exclusions` / `forbidden_core_import_patterns` respected
#     in the RENDERED output (not just the templates — slice 2 tested
#     templates; slice 3 tests the substituted product);
#   * PROJECT_NAME_PASCAL substituted (kebab-to-pascal) into namespace
#     references;
#   * STORE_DEFAULT substituted into the Program.cs DI registration;
#   * bad inputs (missing required arg, non-kebab project_id, unknown
#     stack preset) exit with the documented code 2.
#
# Slice 3 boundaries (not tested here):
#   - render does NOT run the smoke script (slice 4 / runtime own it).
#   - render does NOT validate compiler / type-checker pass on the
#     rendered code (that's a P1c+ concern).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RENDER="${REPO_ROOT}/scripts/workflows/component-fast-render.sh"
REGISTRY="${REPO_ROOT}/schemas/component-types/feedback-widget.yaml"
PYTHON_BIN="${PYTHON_BIN:-python3}"

[ -x "${RENDER}" ]   || { echo "FAIL: ${RENDER} not executable"; exit 1; }
[ -f "${REGISTRY}" ] || { echo "FAIL: ${REGISTRY} missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-render-test.XXXXXX)"
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

# ── Render the canonical fixture once; subsequent cases inspect it. ───
PROJECT_ROOT="${SANDBOX}/render-happy"
echo "Case 1: render exit 0 + machine-readable summary"
render_out="$(bash "${RENDER}" \
  --component-type feedback-widget \
  --project-id component-feedback-widget \
  --project-root "${PROJECT_ROOT}" 2>&1)"
render_rc=$?
assert_eq        "render exit 0"                "0"                                "${render_rc}"
assert_contains "summary result line"          "${render_out}"                     "result: success"
assert_contains "summary rendered_count line"  "${render_out}"                     "rendered_count: 20"
assert_contains "summary project_root line"    "${render_out}"                     "project_root: ${PROJECT_ROOT}"

# ── Case 2: every catalog target exists in sandbox ────────────────────
echo ""
echo "Case 2: every catalog target_path exists in the sandbox project"
missing="$("${PYTHON_BIN}" - "${REGISTRY}" "${PROJECT_ROOT}" <<'PY'
import os, sys, yaml
registry, project_root = sys.argv[1], sys.argv[2]
data = yaml.safe_load(open(registry, encoding="utf-8")) or {}
missing = []
for entry in data.get("catalog") or []:
    target = entry.get("target_path") or ""
    abs_path = os.path.join(project_root, target)
    if not os.path.isfile(abs_path):
        missing.append(target)
print(",".join(missing))
PY
)"
assert_eq "no missing catalog target in sandbox" "" "${missing}"

# ── Case 3: every rendered file is non-empty ──────────────────────────
echo ""
echo "Case 3: every rendered file is non-empty"
empty_files="$(find "${PROJECT_ROOT}" -type f -empty | sort | tr '\n' ',')"
assert_eq "no empty rendered file" "" "${empty_files%,}"

# ── Case 4: zero residue for the five CAP substitution tokens ─────────
#
# These five MUST be fully substituted. Shell scripts may still have
# their own ${VAR} forms (PROBE_RETRIES / SCRIPT_DIR / etc.) and
# docker-compose interpolations like ${BACKEND_PORT:-8080} stay
# untouched by design — the renderer only replaces tokens declared
# in the registry's `substitutions` table.
echo ""
echo "Case 4: zero residue for declared substitution tokens"
for token in PROJECT_ID PROJECT_NAME_PASCAL COMPONENT_TYPE STORE_DEFAULT API_BASE_URL; do
  residue_hits="$(grep -rl "\${${token}}" "${PROJECT_ROOT}" 2>/dev/null | sort | tr '\n' ',')"
  assert_eq "no \${${token}} residue" "" "${residue_hits%,}"
done

# ── Case 5: runtime-smoke.sh has executable bit ───────────────────────
echo ""
echo "Case 5: rendered scripts/runtime-smoke.sh is executable"
smoke="${PROJECT_ROOT}/scripts/runtime-smoke.sh"
if [ -x "${smoke}" ]; then
  echo "  PASS: ${smoke} is executable"
  pass_count=$((pass_count + 1))
else
  echo "  FAIL: ${smoke} is NOT executable"
  fail_count=$((fail_count + 1))
fi

# ── Case 6: rendered tree contains no forbidden_terms (redis) ─────────
echo ""
echo "Case 6: no forbidden_terms appear in the rendered tree"
redis_hits="$(grep -ril 'redis' "${PROJECT_ROOT}" 2>/dev/null | sort | tr '\n' ',')"
assert_eq "no 'redis' in rendered tree" "" "${redis_hits%,}"

# ── Case 7: frontend/lib/feedback/ has no UI adapter leakage ──────────
echo ""
echo "Case 7: frontend/lib/feedback/ has no shadcn / tailwind / lucide"
for forbidden in shadcn tailwind lucide; do
  forbidden_hits="$(grep -ril "${forbidden}" "${PROJECT_ROOT}/frontend/lib/feedback/" 2>/dev/null | sort | tr '\n' ',')"
  assert_eq "no '${forbidden}' under lib/feedback/" "" "${forbidden_hits%,}"
done

# ── Case 8: backend Application layer has no Npgsql leakage ───────────
#
# Domain/ directory is intentionally absent from the slice-2 catalog
# (Domain types live alongside Application for this minimal slice),
# so the Domain glob asserts vacuously. Application glob is the
# active check.
echo ""
echo "Case 8: backend Application/Domain layers have no Npgsql"
for layer in Application Domain; do
  layer_dir="${PROJECT_ROOT}/backend/Feedback/${layer}"
  if [ -d "${layer_dir}" ]; then
    npgsql_hits="$(grep -ril 'Npgsql' "${layer_dir}" 2>/dev/null | sort | tr '\n' ',')"
    assert_eq "no Npgsql under backend/Feedback/${layer}/" "" "${npgsql_hits%,}"
  else
    echo "  PASS: backend/Feedback/${layer}/ absent (vacuous)"
    pass_count=$((pass_count + 1))
  fi
done

# ── Case 9: PROJECT_NAME_PASCAL substituted to ComponentFeedbackWidget ─
echo ""
echo "Case 9: PROJECT_NAME_PASCAL substituted via kebab_to_pascal"
csproj="${PROJECT_ROOT}/backend/Feedback/Feedback.csproj"
program="${PROJECT_ROOT}/backend/Feedback/Program.cs"
if grep -q '<RootNamespace>ComponentFeedbackWidget</RootNamespace>' "${csproj}"; then
  echo "  PASS: .csproj RootNamespace = ComponentFeedbackWidget"
  pass_count=$((pass_count + 1))
else
  echo "  FAIL: .csproj RootNamespace did not substitute"
  fail_count=$((fail_count + 1))
fi
if grep -q 'using ComponentFeedbackWidget.Application;' "${program}"; then
  echo "  PASS: Program.cs imports ComponentFeedbackWidget.Application"
  pass_count=$((pass_count + 1))
else
  echo "  FAIL: Program.cs namespace did not substitute"
  fail_count=$((fail_count + 1))
fi

# ── Case 10: STORE_DEFAULT substituted to InMemoryFeedbackStore ───────
echo ""
echo "Case 10: STORE_DEFAULT substituted via in_memory_store_class"
if grep -q 'IFeedbackStore, InMemoryFeedbackStore' "${program}"; then
  echo "  PASS: Program.cs DI registers IFeedbackStore -> InMemoryFeedbackStore"
  pass_count=$((pass_count + 1))
else
  echo "  FAIL: STORE_DEFAULT substitution missed in Program.cs"
  fail_count=$((fail_count + 1))
fi

# ── Case 11: API_BASE_URL substituted to the registry default ─────────
echo ""
echo "Case 11: API_BASE_URL substituted to registry default URL"
api_client="${PROJECT_ROOT}/frontend/lib/feedback/api-client.ts"
if grep -q 'const DEFAULT_BASE_URL = "http://localhost:8080";' "${api_client}"; then
  echo "  PASS: api-client.ts DEFAULT_BASE_URL = http://localhost:8080"
  pass_count=$((pass_count + 1))
else
  echo "  FAIL: API_BASE_URL substitution missed in api-client.ts"
  fail_count=$((fail_count + 1))
fi

# ── Case 12: rejects missing required arg with exit 2 ─────────────────
echo ""
echo "Case 12: missing --project-id rejected with exit 2"
bad_out="$(bash "${RENDER}" \
  --component-type feedback-widget \
  --project-root "${SANDBOX}/should-not-exist" 2>&1)"
bad_rc=$?
assert_eq "exit 2 on missing --project-id" "2" "${bad_rc}"
assert_contains "error mentions --project-id" "${bad_out}" "--project-id required"

# ── Case 13: rejects non-kebab project_id with exit 2 ─────────────────
echo ""
echo "Case 13: non-kebab project_id rejected with exit 2"
bad_out="$(bash "${RENDER}" \
  --component-type feedback-widget \
  --project-id NotKebabCase \
  --project-root "${SANDBOX}/should-not-exist" 2>&1)"
bad_rc=$?
assert_eq "exit 2 on non-kebab project_id" "2" "${bad_rc}"
assert_contains "error mentions kebab" "${bad_out}" "kebab-case"

# ── Case 14: rejects non-default --stack-preset with exit 2 ───────────
echo ""
echo "Case 14: non-default --stack-preset rejected with exit 2"
bad_out="$(bash "${RENDER}" \
  --component-type feedback-widget \
  --project-id component-feedback-widget \
  --project-root "${SANDBOX}/should-not-exist" \
  --stack-preset some-other-preset 2>&1)"
bad_rc=$?
assert_eq "exit 2 on bad stack-preset" "2" "${bad_rc}"
assert_contains "error mentions registry default" "${bad_out}" "registry default"

# ── Case 15: missing registry exits 3 ─────────────────────────────────
echo ""
echo "Case 15: missing registry file exits 3"
bad_out="$(bash "${RENDER}" \
  --component-type does-not-exist \
  --project-id component-feedback-widget \
  --project-root "${SANDBOX}/should-not-exist" 2>&1)"
bad_rc=$?
assert_eq "exit 3 on missing registry" "3" "${bad_rc}"
assert_contains "error mentions registry not found" "${bad_out}" "registry not found"

echo ""
total=$((pass_count + fail_count))
echo "component-fast-render: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
